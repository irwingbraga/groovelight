import AppKit
import ArgumentParser
import ControlKit
import Foundation

/// Reaching the app: starting it when needed, giving it access to files, sending a request and printing the reply.
enum Runner {
    /// The app around this tool (Groovelight.app/Contents/Helpers/groovelight), else the installed one.
    static var appURL: URL? {
        let executable = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()
        let bundle = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        if bundle.pathExtension == "app" { return bundle }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: ControlPort.appBundleIdentifier)
    }

    /// The version of the app this tool belongs to.
    static var appVersion: String? {
        appURL.flatMap(Bundle.init(url:))?.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    static var version: String { "groovelight \(appVersion ?? "(Groovelight not found)")" }

    /// Starts the app in the background when it is not running, and waits until it listens.
    static func ensureRunning() throws {
        if ControlClient.isAvailable() { return }
        guard let app = appURL else { throw ToolError("Groovelight is not installed (looked for \(ControlPort.appBundleIdentifier)).") }
        printError("Starting Groovelight…")
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        let failure = wait { done in
            NSWorkspace.shared.openApplication(at: app, configuration: configuration) { _, error in done(error) }
        }
        if let failure { throw failure }
        let deadline = Date().addingTimeInterval(30)
        while !ControlClient.isAvailable() {
            guard Date() < deadline else { throw ToolError("Groovelight did not start (or its command line support is off).") }
            Thread.sleep(forTimeInterval: 0.2)
        }
    }

    /// Opens the files with the app, which gives the sandboxed app access to them (as opening them in Finder would);
    /// the app takes them in silently because it is told first.
    static func grantAccess(to paths: [String]) throws {
        guard let app = appURL else { return }
        try ImportPaths.check(paths)
        _ = try ControlClient.send(.expectFiles(paths))
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        let failure = wait { done in
            NSWorkspace.shared.open(paths.map { URL(fileURLWithPath: $0) }, withApplicationAt: app, configuration: configuration) { _, error in
                done(error)
            }
        }
        if let failure { printError("Warning: macOS could not hand the files to Groovelight (\(failure.localizedDescription)); it may not be able to read them.") }
    }

    /// Sends the request, shows a job's progress, and prints the result (or its JSON).
    static func execute(_ request: ControlRequest, output: OutputOptions) throws {
        try ensureRunning()
        let progress = ProgressLine()
        let reply = try ControlClient.run(request) { update in
            for message in update.messages { progress.print(message) }
            if let current = update.progress { progress.show(current) }
        }
        progress.clear()
        for message in reply.messages { printError(message) }
        if output.json {
            var object: [String: JSONValue] = ["data": reply.data ?? .null]
            if let error = reply.error { object["error"] = .string(error) }
            print(reply.error == nil ? (reply.data ?? .null).prettyPrinted : JSONValue.object(object).prettyPrinted)
        } else if let summary = reply.summary {
            print(summary)
        }
        if let error = reply.error {
            // After the result (stdout is buffered when piped, stderr is not).
            fflush(stdout)
            if !output.json { printError("Error: \(error)") }
            throw ExitCode.failure
        }
    }

    /// Runs `body` and spins the run loop until it calls back (AppKit completions arrive on the main queue).
    /// Runs the main run loop until `body` calls back (from any thread), and returns the error it passed.
    private static func wait(_ body: (@escaping @Sendable ((any Error)?) -> Void) -> Void) -> (any Error)? {
        let outcome = Outcome()
        body { outcome.finish($0) }
        while !outcome.isFinished { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        return outcome.error
    }
}

/// A callback's result, set from another thread and read on the main one.
private final class Outcome: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var failure: (any Error)?
    var isFinished: Bool { lock.withLock { finished } }
    var error: (any Error)? { lock.withLock { failure } }

    func finish(_ error: (any Error)?) {
        lock.withLock {
            failure = error
            finished = true
        }
    }
}

func printError(_ text: String) {
    FileHandle.standardError.write(Data((text + "\n").utf8))
}

/// A job's progress on one line of the terminal (or a line per step when the output is not a terminal).
final class ProgressLine {
    private let isTerminal = isatty(STDERR_FILENO) != 0
    private var lastLabel: String?
    private var isShowing = false

    func show(_ progress: JobProgress) {
        let count = progress.total > 0 ? " \(progress.done) of \(progress.total)" : ""
        if isTerminal {
            FileHandle.standardError.write(Data("\r\u{1B}[K\(progress.label)…\(count)".utf8))
            isShowing = true
        } else if progress.label != lastLabel {
            printError("\(progress.label)…")
        }
        lastLabel = progress.label
    }

    func print(_ line: String) {
        clear()
        printError(line)
    }

    func clear() {
        guard isShowing else { return }
        FileHandle.standardError.write(Data("\r\u{1B}[K".utf8))
        isShowing = false
    }
}

/// A failure that is not a mistake in the command (those exit with 64): exits with 1.
struct ToolError: LocalizedError {
    var errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
