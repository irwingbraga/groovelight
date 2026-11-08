import Foundation
import LibraryKit
import Observation
import OSLog
import WirelessSync
import WirelessSyncClient

/// Home from the Mac (or the PC): the day's picks, each with a few more for "Something Else", and the listening dashboard.
/// The Mac works them out from its listening log (`GET /home`); the last one is kept on the device for when the Mac
/// is away, and fetched again only when it changed.
@MainActor
@Observable
final class HomeStore {
    private(set) var home: HomeSnapshot?
    /// When the Mac last answered with Home.
    private(set) var fetchedAt: Date?
    private(set) var isLoading = false
    private(set) var error: String?
    /// Which of each kind's cards is shown ("Something Else" moves on, and back to the pick after the last).
    var shown: [Discovery.Kind: Int] = [:]

    @ObservationIgnored private let sync: SyncStore
    @ObservationIgnored private let file: URL

    private static let log = Logger(subsystem: "dev.irwingbraga.groovelight", category: "home")
    private static let tagKey = "home.tag"
    private static let fetchedKey = "home.fetchedAt"

    init(sync: SyncStore, folders: AppFolders) {
        self.sync = sync
        file = folders.root.appendingPathComponent("Home.json")
        home = (try? Data(contentsOf: file)).flatMap { try? WirelessProtocol.decoder.decode(HomeSnapshot.self, from: $0) }
        fetchedAt = UserDefaults.standard.object(forKey: Self.fetchedKey) as? Date
        #if DEBUG
        // `-GLDebugHomeFile <path>` shows that Home (HomeSnapshot JSON), paired or not, for layout checks.
        if let path = UserDefaults.standard.string(forKey: "GLDebugHomeFile"),
           let data = FileManager.default.contents(atPath: path) {
            home = try? WirelessProtocol.decoder.decode(HomeSnapshot.self, from: data)
            fetchedAt = .now
        }
        #endif
    }

    /// Asks the Mac for Home (nothing comes back when it has not changed).
    func refresh() async {
        guard sync.isPaired, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let client = try await sync.client()
            let tag = home == nil ? nil : UserDefaults.standard.string(forKey: Self.tagKey)
            if let (fetched, newTag) = try await client.home(tag: tag) {
                if fetched.day != home?.day { shown = [:] }
                home = fetched
                UserDefaults.standard.set(newTag, forKey: Self.tagKey)
                try? WirelessProtocol.encoder.encode(fetched).write(to: file, options: .atomic)
            }
            fetchedAt = .now
            UserDefaults.standard.set(fetchedAt, forKey: Self.fetchedKey)
            error = nil
        } catch {
            // Kept: the last Home stays on screen.
            self.error = (error as? MacError).map { $0.status > 0 ? $0.localizedDescription : nil } ?? nil
            Self.log.error("Home: \(String(describing: error), privacy: .public)")
        }
    }

    /// Whether the picks are an earlier day's (the Mac was not reachable today).
    var isFromAnotherDay: Bool {
        guard let home else { return false }
        return home.day != Discovery.day(of: .now, in: .current)
    }

    func card(_ kind: Discovery.Kind) -> HomeSnapshot.Card? {
        guard let cards = home?.cards(kind), !cards.isEmpty else { return nil }
        return cards[(shown[kind] ?? 0) % cards.count]
    }

    func hasAlternatives(_ kind: Discovery.Kind) -> Bool { (home?.cards(kind).count ?? 0) > 1 }

    func somethingElse(_ kind: Discovery.Kind) {
        shown[kind] = (shown[kind] ?? 0) + 1
    }

    /// Forgets Home (unpaired).
    func clear() {
        home = nil
        fetchedAt = nil
        shown = [:]
        try? FileManager.default.removeItem(at: file)
        UserDefaults.standard.removeObject(forKey: Self.tagKey)
        UserDefaults.standard.removeObject(forKey: Self.fetchedKey)
    }
}
