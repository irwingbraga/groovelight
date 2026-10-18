import Foundation
import Network
import Security

/// A small HTTP/1.1 server for the local network, advertised with Bonjour: one request per connection, JSON bodies up
/// to 64 MB, and file bodies streamed in 1 MB pieces with Range support (so a download cut off by Wi-Fi resumes).
/// With a TLS identity it serves HTTPS (TLS 1.2 or later) instead.
public final class LocalHTTPServer: @unchecked Sendable {
    public struct Request: Sendable {
        public var method: String
        /// Path without the query.
        public var path: String
        public var query: [String: String]
        /// Lowercased names.
        public var headers: [String: String]
        public var body: Data
        /// Address of the device asking, for logs.
        public var remote: String
        /// Came over TLS.
        public var secure = false
    }

    public struct Response: Sendable {
        public enum Body: Sendable {
            case data(Data)
            /// A file, or part of it (Range requests are answered from `range`).
            case file(URL)
        }

        public var status: Int
        public var headers: [String: String]
        public var body: Body

        public init(status: Int = 200, headers: [String: String] = [:], body: Body = .data(Data())) {
            self.status = status
            self.headers = headers
            self.body = body
        }

        public static func json<T: Encodable>(_ value: T, status: Int = 200) -> Response {
            let data = (try? WirelessProtocol.encoder.encode(value)) ?? Data()
            return Response(status: status, headers: ["Content-Type": "application/json"], body: .data(data))
        }

        public static func error(_ status: Int, _ message: String) -> Response {
            .json(["error": message], status: status)
        }
    }

    public typealias Handler = @Sendable (Request) async -> Response

    private let queue = DispatchQueue(label: "dev.irwingbraga.groovelight.http")
    private let handler: Handler
    private let identity: SecIdentity?
    private var listener: NWListener?
    private let lock = NSLock()
    private var boundPort: UInt16 = 0

    static let maximumBody = 64 * 1024 * 1024
    static let chunk = 1024 * 1024

    public init(identity: SecIdentity? = nil, handler: @escaping Handler) {
        self.identity = identity
        self.handler = handler
    }

    /// The port it listens on, once started.
    public var port: UInt16 { lock.withLock { boundPort } }

    /// Starts listening (any free port unless `port` is given) and advertises `name` as `WirelessProtocol.serviceType`
    /// with the TXT record. Calls `ready` with the port, or nil when it could not start.
    public func start(name: String?, txt: [String: String] = [:], port: UInt16 = 0, ready: @escaping @Sendable (UInt16?) -> Void) {
        do {
            let parameters: NWParameters
            if let identity, let secIdentity = sec_identity_create(identity) {
                let tls = NWProtocolTLS.Options()
                sec_protocol_options_set_local_identity(tls.securityProtocolOptions, secIdentity)
                sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
                parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
            } else {
                parameters = NWParameters.tcp
            }
            parameters.includePeerToPeer = false
            let listener = try NWListener(using: parameters, on: port == 0 ? .any : NWEndpoint.Port(rawValue: port)!)
            if let name {
                listener.service = NWListener.Service(name: name, type: WirelessProtocol.serviceType, domain: nil,
                                                      txtRecord: NWTXTRecord(txt))
            }
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                switch state {
                case .ready:
                    let bound = listener?.port?.rawValue ?? 0
                    self?.lock.withLock { self?.boundPort = bound }
                    ready(bound)
                case .failed:
                    ready(nil)
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.start(queue: queue)
            lock.withLock { self.listener = listener }
        } catch {
            ready(nil)
        }
    }

    public func stop() {
        lock.withLock {
            listener?.cancel()
            listener = nil
        }
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveHead(connection, buffer: Data())
    }

    private func receiveHead(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = buffer[..<end.lowerBound]
                let rest = buffer[end.upperBound...]
                guard var request = Self.parseHead(Data(head), remote: "\(connection.endpoint)") else {
                    self.send(.error(400, "bad request"), on: connection, request: nil)
                    return
                }
                request.secure = self.identity != nil
                let length = Int(request.headers["content-length"] ?? "0") ?? 0
                guard length <= Self.maximumBody else {
                    self.send(.error(413, "too large"), on: connection, request: nil)
                    return
                }
                self.receiveBody(connection, request: &request, body: Data(rest), length: length)
            } else if isComplete || error != nil || buffer.count > 64 * 1024 {
                connection.cancel()
            } else {
                self.receiveHead(connection, buffer: buffer)
            }
        }
    }

    private func receiveBody(_ connection: NWConnection, request: inout Request, body: Data, length: Int) {
        if body.count >= length {
            request.body = body.prefix(length)
            let request = request
            Task { [handler] in
                let response = await handler(request)
                self.send(response, on: connection, request: request)
            }
            return
        }
        let pending = request
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.chunk) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            guard let data, error == nil, !(isComplete && data.isEmpty) else {
                connection.cancel()
                return
            }
            var request = pending
            self.receiveBody(connection, request: &request, body: body + data, length: length)
        }
    }

    static func parseHead(_ head: Data, remote: String) -> Request? {
        guard let text = String(data: head, encoding: .utf8) else { return nil }
        var lines = text.components(separatedBy: "\r\n")
        let parts = lines.removeFirst().split(separator: " ")
        guard parts.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let target = String(parts[1])
        let components = URLComponents(string: target)
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        let path = components?.percentEncodedPath.removingPercentEncoding ?? target
        return Request(method: String(parts[0]).uppercased(), path: path, query: query, headers: headers, body: Data(),
                       remote: remote)
    }

    // MARK: - Responses

    private func send(_ response: Response, on connection: NWConnection, request: Request?) {
        switch response.body {
        case .data(let data):
            let head = Self.head(status: response.status, headers: response.headers, length: data.count)
            connection.send(content: head + data, completion: .contentProcessed { _ in connection.cancel() })
        case .file(let url):
            guard let handle = try? FileHandle(forReadingFrom: url),
                  let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
                send(.error(404, "missing file"), on: connection, request: request)
                return
            }
            var status = response.status
            var headers = response.headers
            headers["Accept-Ranges"] = "bytes"
            headers["Content-Type"] = headers["Content-Type"] ?? "application/octet-stream"
            var start = 0, end = size - 1
            if let range = request?.headers["range"], let parsed = Self.parseRange(range, size: size) {
                (start, end) = parsed
                status = 206
                headers["Content-Range"] = "bytes \(start)-\(end)/\(size)"
            }
            let length = max(end - start + 1, 0)
            try? handle.seek(toOffset: UInt64(start))
            connection.send(content: Self.head(status: status, headers: headers, length: length), completion: .contentProcessed { [weak self] error in
                guard error == nil else {
                    try? handle.close()
                    connection.cancel()
                    return
                }
                self?.stream(handle, remaining: length, on: connection)
            })
        }
    }

    /// Sends the file a piece at a time, each piece after the previous one left.
    private func stream(_ handle: FileHandle, remaining: Int, on connection: NWConnection) {
        guard remaining > 0, let data = try? handle.read(upToCount: min(Self.chunk, remaining)), !data.isEmpty else {
            try? handle.close()
            connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
            return
        }
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard error == nil else {
                try? handle.close()
                connection.cancel()
                return
            }
            self?.stream(handle, remaining: remaining - data.count, on: connection)
        })
    }

    /// "bytes=100-" or "bytes=100-199" (one range).
    static func parseRange(_ header: String, size: Int) -> (Int, Int)? {
        guard header.hasPrefix("bytes="), size > 0 else { return nil }
        let spec = header.dropFirst(6).split(separator: ",").first ?? ""
        let bounds = spec.split(separator: "-", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard bounds.count == 2 else { return nil }
        if bounds[0].isEmpty, let suffix = Int(bounds[1]) { return (max(size - suffix, 0), size - 1) }
        guard let start = Int(bounds[0]), start < size else { return nil }
        let end = Int(bounds[1]).map { min($0, size - 1) } ?? size - 1
        return end >= start ? (start, end) : nil
    }

    static func head(status: Int, headers: [String: String], length: Int) -> Data {
        var lines = ["HTTP/1.1 \(status) \(reason(status))", "Content-Length: \(length)", "Connection: close"]
        for (name, value) in headers.sorted(by: { $0.key < $1.key }) { lines.append("\(name): \(value)") }
        return Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 206: "Partial Content"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 409: "Conflict"
        case 413: "Payload Too Large"
        default: "Status"
        }
    }
}
