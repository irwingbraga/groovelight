import Foundation
import LibraryKit
import os
import WirelessSync

/// The songs of a sync, downloaded by the system: with a background configuration (the app's) they go on after the app
/// leaves the screen or is suspended, and the app is woken when they are done. Each file is checked against the Mac's
/// SHA-256, put in place and recorded in the music folder's manifest as soon as it arrives, so a file that arrives
/// while no sync is waiting for it (the app was ended and launched again) still counts, and the next sync leaves it be.
/// A download cut off (Wi-Fi dropped) resumes from where it stopped, with the Mac's ETag.
public final class FileDownloads: NSObject, @unchecked Sendable {
    /// One file of a plan, carried in its task's description so it survives the app being ended.
    struct Job: Codable, Sendable {
        var path: String
        var entry: DeviceManifest.Entry
        var attempt = 1
    }

    /// How one file went: its size, or why it failed.
    public typealias Outcome = Result<Int64, MacError>

    public let musicFolder: URL
    private var session: URLSession!
    private let state = OSAllocatedUnfairLock(initialState: State())
    /// Moves files in place and writes the manifest one at a time.
    private let placing = NSLock()

    private struct State {
        var fingerprint: String?
        /// Waiting for each task, by its identifier.
        var waiting: [Int: CheckedContinuation<Outcome, Never>] = [:]
        /// Outcomes that arrived before anyone waited.
        var early: [Int: Outcome] = [:]
        var finishedEvents: (@Sendable () -> Void)?
    }

    static let maximumAttempts = 3
    static let log = Logger(subsystem: "dev.irwingbraga.groovelight", category: "downloads")

    /// `configuration`: `.background(withIdentifier:)` in the app (one session per identifier for the app's life), any
    /// other in tests.
    public init(configuration: URLSessionConfiguration, musicFolder: URL) {
        self.musicFolder = musicFolder
        super.init()
        configuration.timeoutIntervalForRequest = 120
        // The Mac keeps a sync's files for 6 hours.
        configuration.timeoutIntervalForResource = 6 * 3600
        configuration.httpMaximumConnectionsPerHost = 2
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    /// The app's: songs keep downloading when it is not on screen.
    public static func background(identifier: String, musicFolder: URL) -> FileDownloads {
        FileDownloads(configuration: .background(withIdentifier: identifier), musicFolder: musicFolder)
    }

    /// The Mac's pinned certificate, for downloads of an earlier sync that the system delivers after a launch.
    public func pin(_ fingerprint: String?) {
        state.withLock { $0.fingerprint = fingerprint }
    }

    /// Called once the system has delivered everything for a background session (the app was woken for it).
    public func onFinishedEvents(_ handler: @escaping @Sendable () -> Void) {
        state.withLock { $0.finishedEvents = handler }
    }

    /// Stops every download (of this sync or an earlier one).
    public func cancelAll() async {
        for task in await session.allTasks { task.cancel() }
    }

    /// Downloads the plan's files and waits for all of them; `progress` gets how many are done. Files of an earlier
    /// sync still on their way are stopped first.
    func download(_ writes: [WirelessProtocol.SyncPlan.Write], client: MacClient, session sync: String, token: String,
                  progress: @escaping @Sendable (Int, String) -> Void) async throws -> [String: Outcome] {
        await cancelAll()
        state.withLock { state in
            state.fingerprint = client.tls?.fingerprint
            state.early = [:]
        }
        var tasks: [(Int, String)] = []
        for write in writes {
            let request = try client.downloadRequest(session: sync, index: write.index, token: token)
            let task = session.downloadTask(with: request)
            task.taskDescription = Self.describe(Job(path: write.path, entry: write.entry))
            task.countOfBytesClientExpectsToReceive = write.size
            tasks.append((task.taskIdentifier, write.path))
            task.resume()
        }
        return try await withTaskCancellationHandler {
            var outcomes: [String: Outcome] = [:]
            for (identifier, path) in tasks {
                // A retry is a new task: follow it until the file is done.
                var current = identifier
                var outcome: Outcome
                repeat {
                    outcome = await wait(for: current)
                    if case .failure(let error) = outcome, error.status == Self.retried, let next = Int(error.message) { current = next } else { break }
                } while true
                outcomes[path] = outcome
                progress(outcomes.count, (path as NSString).lastPathComponent)
            }
            try Task.checkCancellation()
            return outcomes
        } onCancel: {
            Task { await self.cancelAll() }
        }
    }

    /// A failure that is not final: the file is being tried again as the task named in the message.
    private static let retried = -1

    private func wait(for identifier: Int) async -> Outcome {
        await withCheckedContinuation { continuation in
            let early: Outcome? = state.withLock { state in
                if let outcome = state.early.removeValue(forKey: identifier) { return outcome }
                state.waiting[identifier] = continuation
                return nil
            }
            if let early { continuation.resume(returning: early) }
        }
    }

    private func report(_ outcome: Outcome, for identifier: Int) {
        let continuation: CheckedContinuation<Outcome, Never>? = state.withLock { state in
            if let continuation = state.waiting.removeValue(forKey: identifier) { return continuation }
            state.early[identifier] = outcome
            return nil
        }
        continuation?.resume(returning: outcome)
    }

    // MARK: - Placing files

    /// Checks the arrived file, moves it in place and records it in the manifest. Runs while the system's file still
    /// exists (inside the delegate call).
    private func place(_ location: URL, job: Job, response: HTTPURLResponse?) -> Outcome {
        guard let response, response.statusCode == 200 || response.statusCode == 206 else {
            let status = response?.statusCode ?? 0
            return .failure(MacError("Download failed (\(status))", status: status))
        }
        if let expected = response.value(forHTTPHeaderField: WirelessProtocol.Header.sha256), MacClient.sha256(file: location) != expected {
            return .failure(MacError("The copy did not match the Mac's"))
        }
        let fileManager = FileManager.default
        let destination = musicFolder.appendingPathComponent(job.path)
        // The music folder is the app's own, so whatever is there is Groovelight's: a file not in the manifest is one
        // whose recording was cut short (the app ended between the two), and is replaced.
        return placing.withLock {
            var manifest = DeviceManifest.read(from: musicFolder)
            do {
                try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fileManager.removeItem(at: destination)
                try fileManager.moveItem(at: location, to: destination)
                let size = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? job.entry.size
                var entry = job.entry
                entry.size = size
                manifest.entries[job.path] = entry
                try manifest.write(to: musicFolder)
                return .success(size)
            } catch {
                return .failure(MacError(error.localizedDescription))
            }
        }
    }

    static func describe(_ job: Job) -> String {
        (try? String(decoding: JSONEncoder().encode(job), as: UTF8.self)) ?? ""
    }

    static func job(of task: URLSessionTask) -> Job? {
        task.taskDescription.flatMap { try? JSONDecoder().decode(Job.self, from: Data($0.utf8)) }
    }
}

extension FileDownloads: URLSessionDownloadDelegate {
    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let job = Self.job(of: downloadTask) else { return }
        let outcome = place(location, job: job, response: downloadTask.response as? HTTPURLResponse)
        if case .failure(let error) = outcome { Self.log.error("\(job.path, privacy: .public): \(error.message, privacy: .public)") }
        report(outcome, for: downloadTask.taskIdentifier)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        // Success was reported when the file arrived.
        guard let error, let job = Self.job(of: task) else { return }
        let nsError = error as NSError
        if nsError.code == NSURLErrorCancelled, nsError.userInfo[NSURLSessionDownloadTaskResumeData] == nil {
            report(.failure(MacError("Stopped")), for: task.taskIdentifier)
            return
        }
        // Wi-Fi dropped or the Mac went away: again, from where it stopped when the Mac allows it.
        guard job.attempt < Self.maximumAttempts else {
            report(.failure(MacError(error.localizedDescription)), for: task.taskIdentifier)
            return
        }
        let retry: URLSessionDownloadTask
        if let data = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            retry = session.downloadTask(withResumeData: data)
            Self.log.info("Resuming \(job.path, privacy: .public)")
        } else if let request = task.originalRequest {
            retry = session.downloadTask(with: request)
        } else {
            report(.failure(MacError(error.localizedDescription)), for: task.taskIdentifier)
            return
        }
        var next = job
        next.attempt += 1
        retry.taskDescription = Self.describe(next)
        retry.countOfBytesClientExpectsToReceive = job.entry.size
        report(.failure(MacError("\(retry.taskIdentifier)", status: Self.retried)), for: task.taskIdentifier)
        retry.resume()
    }

    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let handler = state.withLock { $0.finishedEvents }
        handler?()
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge) async
        -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        PinningDelegate.evaluate(challenge, fingerprint: state.withLock { $0.fingerprint })
    }
}
