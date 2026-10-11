import Foundation

public enum MetadataError: Error, Equatable, Sendable {
    case notFound
    case http(Int)
    case invalidResponse
}

/// Fetches a URL. Abstracted so tests can serve canned responses.
public protocol HTTPFetching: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionFetcher: HTTPFetching {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MetadataError.invalidResponse }
        return (data, http)
    }
}

/// Spaces requests at least `interval` apart (MusicBrainz allows one request per second per client).
public actor RateLimiter {
    private let interval: Duration
    private var next: ContinuousClock.Instant?

    public init(interval: Duration) {
        self.interval = interval
    }

    public func wait() async throws {
        let clock = ContinuousClock()
        let now = clock.now
        let slot = max(now, next ?? now)
        next = slot + interval
        if slot > now { try await clock.sleep(until: slot) }
    }
}

/// Identifies the app to web services, as MusicBrainz and LRCLIB ask.
public struct ClientIdentity: Sendable {
    public var name: String
    public var version: String
    /// Optional contact (email or URL) appended to the User-Agent, as MusicBrainz recommends.
    public var contact: String?

    public init(name: String = "Groovelight", version: String, contact: String? = nil) {
        self.name = name
        self.version = version
        self.contact = contact
    }

    public var userAgent: String {
        if let contact, !contact.isEmpty { return "\(name)/\(version) ( \(contact) )" }
        return "\(name)/\(version)"
    }
}

extension HTTPFetching {
    /// GET returning the body, with `notFound` for 404 and `http` for other failures.
    func get(_ url: URL, identity: ClientIdentity, accept: String = "application/json") async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue(identity.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        let (data, response) = try await data(for: request)
        switch response.statusCode {
        case 200..<300: return data
        case 404: throw MetadataError.notFound
        default: throw MetadataError.http(response.statusCode)
        }
    }
}

extension HTTPFetching {
    /// GET through a rate limiter, retrying "busy" answers (503, 429) with a growing backoff.
    func get(_ url: URL, identity: ClientIdentity, limiter: RateLimiter, accept: String = "application/json") async throws -> Data {
        for attempt in 0..<3 {
            try await limiter.wait()
            do {
                return try await get(url, identity: identity, accept: accept)
            } catch MetadataError.http(let status) where (status == 503 || status == 429) && attempt < 2 {
                try await Task.sleep(for: .seconds(1.5 * Double(attempt + 1)))
            }
        }
        throw MetadataError.http(503)
    }
}

extension URL {
    static func build(_ base: String, _ items: [String: String?]) -> URL {
        var components = URLComponents(string: base)!
        components.queryItems = items.compactMap { key, value in value.map { URLQueryItem(name: key, value: $0) } }
            .sorted { $0.name < $1.name }
        // URLComponents leaves "+" alone, which servers read as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.url!
    }
}
