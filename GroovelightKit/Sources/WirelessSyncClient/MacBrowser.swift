import Foundation
import Network
import WirelessSync

/// A Mac running Groovelight, found on the network.
public struct FoundMac: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var host: String
    public var port: Int
}

/// Finds Groovelight on the local network (Bonjour `_groovelight._tcp`), resolving each Mac to an address and port.
public enum MacBrowser {
    /// The Macs as they come and go, until the stream is no longer read.
    public static func macs() -> AsyncStream<[FoundMac]> {
        AsyncStream { continuation in
            let queue = DispatchQueue(label: "dev.irwingbraga.groovelight.browser")
            let browser = NWBrowser(for: .bonjourWithTXTRecord(type: WirelessProtocol.serviceType, domain: nil), using: .tcp)
            let found = Found()
            browser.browseResultsChangedHandler = { results, _ in
                let names = Set(results.compactMap(\.serviceName))
                found.keep(names)
                continuation.yield(found.macs)
                for result in results {
                    guard let name = result.serviceName, !found.isResolving(name) else { continue }
                    let id = result.txt?["id"] ?? name
                    resolve(result.endpoint, queue: queue) { host, port in
                        found.add(FoundMac(id: id, name: displayName(name), host: host, port: port), service: name)
                        continuation.yield(found.macs)
                    }
                }
            }
            browser.stateUpdateHandler = { state in
                if case .failed = state { continuation.finish() }
            }
            continuation.onTermination = { _ in browser.cancel() }
            browser.start(queue: queue)
        }
    }

    /// The first Mac with this id found within `timeout`, or nil.
    public static func find(id: String, timeout: Duration = .seconds(10)) async -> FoundMac? {
        await withTaskGroup(of: FoundMac?.self) { group in
            group.addTask {
                for await macs in macs() {
                    if let mac = macs.first(where: { $0.id == id }) { return mac }
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// "Groovelight on Irwing's Mac" as "Irwing's Mac".
    static func displayName(_ service: String) -> String {
        service.hasPrefix("Groovelight on ") ? String(service.dropFirst("Groovelight on ".count)) : service
    }

    /// The address and port behind a Bonjour service (IPv4 when the Mac has one: simpler to put in a URL).
    private static func resolve(_ endpoint: NWEndpoint, queue: DispatchQueue, done: @escaping @Sendable (String, Int) -> Void) {
        let parameters = NWParameters.tcp
        if let ip = parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options { ip.version = .v4 }
        let connection = NWConnection(to: endpoint, using: parameters)
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                if case let .hostPort(host, port) = connection.currentPath?.remoteEndpoint {
                    done(address(host), Int(port.rawValue))
                }
                connection.cancel()
            case .failed, .waiting:
                connection.cancel()
            default:
                break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 10) { connection.cancel() }
    }

    private static func address(_ host: NWEndpoint.Host) -> String {
        switch host {
        case .ipv4(let address): "\(address)".components(separatedBy: "%").first ?? "\(address)"
        case .ipv6(let address): "\(address)"
        case .name(let name, _): name
        @unknown default: "\(host)"
        }
    }

    /// What the browser has resolved so far (touched on its queue only).
    private final class Found: @unchecked Sendable {
        private var byService: [String: FoundMac] = [:]
        private var resolving = Set<String>()

        var macs: [FoundMac] { byService.values.sorted { $0.name < $1.name } }

        func isResolving(_ service: String) -> Bool {
            defer { resolving.insert(service) }
            return resolving.contains(service)
        }

        func add(_ mac: FoundMac, service: String) { byService[service] = mac }

        func keep(_ services: Set<String>) {
            byService = byService.filter { services.contains($0.key) }
            resolving = resolving.intersection(services)
        }
    }
}

private extension NWBrowser.Result {
    var serviceName: String? {
        if case let .service(name, _, _, _) = endpoint { return name }
        return nil
    }

    var txt: NWTXTRecord? {
        if case let .bonjour(record) = metadata { return record }
        return nil
    }
}
