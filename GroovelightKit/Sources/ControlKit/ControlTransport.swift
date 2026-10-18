import CoreFoundation
import Foundation

/// Sends requests to the running app.
public enum ControlClient {
    public enum ClientError: LocalizedError {
        case notRunning
        case sendFailed(Int32)
        case badReply

        public var errorDescription: String? {
            switch self {
            case .notRunning: "Groovelight is not running."
            case .sendFailed(let status) where status == kCFMessagePortReceiveTimeout:
                "Groovelight did not answer in time. It may be showing a dialog (a keychain or permission prompt): answer it and try again."
            case .sendFailed(let status): "Could not reach Groovelight (message port error \(status))."
            case .badReply: "Groovelight sent a reply this tool cannot read. Update the app and the tool together."
            }
        }
    }

    /// Whether the app is listening.
    public static func isAvailable(port: String = ControlPort.name) -> Bool {
        CFMessagePortCreateRemote(nil, port as CFString) != nil
    }

    public static func send(_ request: ControlRequest, port: String = ControlPort.name, timeout: TimeInterval = 30) throws -> ControlReply {
        guard let remote = CFMessagePortCreateRemote(nil, port as CFString) else { throw ClientError.notRunning }
        defer { CFMessagePortInvalidate(remote) }
        let body = try JSONEncoder().encode(Envelope(version: ControlPort.protocolVersion, request: request))
        var reply: Unmanaged<CFData>?
        let status = CFMessagePortSendRequest(remote, 0, body as CFData, timeout, timeout, CFRunLoopMode.defaultMode.rawValue, &reply)
        guard status == kCFMessagePortSuccess else { throw ClientError.sendFailed(status) }
        guard let data = reply?.takeRetainedValue() as Data?,
              let decoded = try? JSONDecoder().decode(ControlReply.self, from: data) else { throw ClientError.badReply }
        return decoded
    }

    /// Sends a request and, when it starts a job, polls it until it is done, passing every update along.
    public static func run(_ request: ControlRequest, port: String = ControlPort.name, interval: TimeInterval = 0.25,
                           onUpdate: (ControlReply) -> Void = { _ in }) throws -> ControlReply {
        var reply = try send(request, port: port)
        while let job = reply.job, !reply.finished, reply.error == nil {
            onUpdate(reply)
            Thread.sleep(forTimeInterval: interval)
            reply = try send(.poll(job: job), port: port)
        }
        return reply
    }
}

/// The app's end: answers requests on the main run loop.
@MainActor
public final class ControlServer {
    public typealias Handler = @MainActor (ControlRequest) -> ControlReply

    private let handler: Handler
    private var port: CFMessagePort?
    private var source: CFRunLoopSource?

    public init(handler: @escaping Handler) {
        self.handler = handler
    }

    /// Starts listening; false when the name is taken (another copy of the app) or not allowed.
    @discardableResult
    public func start(name: String = ControlPort.name) -> Bool {
        var context = CFMessagePortContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil,
                                           copyDescription: nil)
        var shouldFree: DarwinBoolean = false
        guard let port = CFMessagePortCreateLocal(nil, name as CFString, { _, _, data, info in
            guard let info else { return nil }
            let server = Unmanaged<ControlServer>.fromOpaque(info).takeUnretainedValue()
            let reply = MainActor.assumeIsolated { server.answer(data.map { $0 as Data }) }
            return (try? JSONEncoder().encode(reply)).map { Unmanaged.passRetained($0 as CFData) }
        }, &context, &shouldFree) else { return false }
        let source = CFMessagePortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        self.port = port
        self.source = source
        return true
    }

    public func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let port { CFMessagePortInvalidate(port) }
        port = nil
        source = nil
    }

    private func answer(_ data: Data?) -> ControlReply {
        guard let data, let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else {
            return .failure("Groovelight could not read the request. Update the app and the tool together.")
        }
        guard envelope.version == ControlPort.protocolVersion else {
            return .failure("This tool speaks version \(envelope.version) of the protocol, the app version \(ControlPort.protocolVersion). Use the tool that comes with the app.")
        }
        return handler(envelope.request)
    }
}

struct Envelope: Codable {
    var version: Int
    var request: ControlRequest
}
