import Foundation
import LibraryKit
import Observation

/// Home's picks of the day: made once a day (kept in the library), with a few more drawn for "Something Else".
@MainActor @Observable
final class HomeStore {
    struct Card: Identifiable, Equatable {
        var pick: Discovery.Pick
        var title: String
        var subtitle: String
        var artworkHash: String?
        var tracks: [Track]
        var id: Discovery.Kind { pick.kind }
    }

    /// Song, Album and Artist of the Day, each with the next ones drawn for it (the day's pick first).
    private(set) var choices: [Discovery.Kind: [Card]] = [:]
    /// Which of each kind's choices is shown ("Something Else" moves on, and back to the pick after the last).
    var shown: [Discovery.Kind: Int] = [:]
    private(set) var isLoading = false
    /// The day the picks are for.
    private(set) var day: Int?

    @ObservationIgnored private let database: LibraryDatabase

    init(database: LibraryDatabase) {
        self.database = database
    }

    func card(_ kind: Discovery.Kind) -> Card? {
        guard let cards = choices[kind], !cards.isEmpty else { return nil }
        return cards[(shown[kind] ?? 0) % cards.count]
    }

    func hasAlternatives(_ kind: Discovery.Kind) -> Bool { (choices[kind]?.count ?? 0) > 1 }

    func somethingElse(_ kind: Discovery.Kind) {
        shown[kind] = (shown[kind] ?? 0) + 1
    }

    /// Makes (or reads back) today's picks, unless they are loaded already.
    func refresh(force: Bool = false) async {
        let today = Discovery.day(of: .now, in: .current)
        guard force || day != today, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        let database = database
        let result = try? await Task.detached(priority: .userInitiated) { () -> [Discovery.Kind: [Card]] in
            let (picks, picker) = try database.dailyPicks()
            return try await database.writer.read { db in
                var choices: [Discovery.Kind: [Card]] = [:]
                for kind in Discovery.Kind.allCases {
                    let first = picks.first { $0.kind == kind }
                    let others = picker.draw(kind, count: 6).filter { $0.key != first?.key }
                    choices[kind] = try ([first].compactMap { $0 } + others).prefix(6).compactMap { try Self.card($0, db) }
                }
                return choices
            }
        }.value
        guard let result else { return }
        choices = result
        shown = [:]
        day = today
    }

    nonisolated private static func card(_ pick: Discovery.Pick, _ db: Database) throws -> Card? {
        guard let card = try LibraryDatabase.homeCard(pick, db) else { return nil }
        return Card(pick: pick, title: card.title, subtitle: card.subtitle, artworkHash: card.artworkHash,
                    tracks: try LibraryDatabase.tracks(db, ids: pick.trackIds))
    }
}
