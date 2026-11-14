import Foundation

/// Lists classical albums under their composers. A classical record's artist tag names its performers (a soloist, an
/// orchestra, a conductor), different on every recording, so one composer's music ends up spread over many "artists".
/// The composer tag is what such albums share: albums found to be classical are listed by it, in Composers, and leave
/// Artists (their performers stay on the album pages and in search).
///
/// An album is classical when most of its songs have a classical genre ("Classical", "Clássica", "Baroque", "Opera"…,
/// whole words, so not "Classic Rock" or "Neoclassical Metal") and a real composer (not "Anonymous" or
/// "Traditional"), unless its artist also has music that is not classical (a band with one album tagged "Classical").
/// An album's override decides instead, either way.
public enum ClassicalGrouping {
    /// How an album is listed, when chosen on its page (nil: decided from its tags).
    public enum Mode: String, Sendable, CaseIterable {
        /// Under its composers, in Composers.
        case composer
        /// Under its artist, in Artists.
        case artist
    }

    /// One song, as the grouping needs it.
    public struct Song: Sendable {
        public var id: Int64
        public var albumKey: String
        public var genre: String?
        public var composer: String?
        /// The name Artists lists the song under (album artist, else artist).
        public var artistName: String

        public init(id: Int64, albumKey: String, genre: String?, composer: String?, artistName: String) {
            self.id = id
            self.albumKey = albumKey
            self.genre = genre
            self.composer = composer
            self.artistName = artistName
        }
    }

    /// Genres (folded: lowercase, no accents) that make a song classical, in the languages tags come in.
    static let genres: Set<String> = [
        "classical", "classique", "clasica", "classica", "klassik", "klassisch", "klassieke muziek", "klassiek",
        "baroque", "barroco", "barocco", "barock", "barok", "opera", "operetta", "opereta", "choral", "choir", "coral",
        "chamber", "chamber music", "musica de camara", "musica da camera", "musique de chambre", "kammermusik",
        "orchestral", "symphony", "sinfonia", "concerto", "concertos", "musica de concerto", "musica erudita",
        "early music", "renaissance", "medieval", "romantic", "romanticism", "classicism", "classical period",
        "oratorio", "lieder", "art song", "sacred", "sacred music", "musica sacra", "musique sacree", "requiem", "mass",
        "minimalism", "impressionism", "neoclassicism", "modern classical", "contemporary classical", "avant-garde classical",
    ]

    /// Composer tags that are not a composer to list.
    static let placeholders: Set<String> = [
        "anonymous", "anon", "anon.", "anonyme", "anonimo", "anonym", "traditional", "trad", "trad.", "tradicional",
        "traditionnel", "tradizionale", "folk", "unknown", "unknown composer", "various", "various composers",
        "various artists", "[unknown]", "n/a", "-",
    ]

    /// Particles skipped when matching a short name to a full one ("Palestrina" to "Giovanni Pierluigi da Palestrina").
    private static let particles: Set<String> = ["da", "de", "di", "del", "della", "von", "van", "der", "den", "le", "la", "du", "y"]

    /// Whether a genre tag (possibly several, separated by ";", "/" or ",") names a classical genre.
    public static func isClassicalGenre(_ genre: String?) -> Bool {
        guard let genre else { return false }
        return genre.split(whereSeparator: { ";/,|".contains($0) }).contains { part in
            let value = fold(String(part))
            if genres.contains(value) { return true }
            // "Western Classical", "Classical Piano", but not "Classical Crossover" (pop sung operatically).
            let words = value.split(separator: " ")
            return words.count > 1 && (words.contains("classical") || words.contains("classique")) && !words.contains("crossover")
        }
    }

    /// The composers a composer tag names, in order, as written ("Bach, Johann Sebastian" turned around), without
    /// placeholders.
    public static func composers(in tag: String?) -> [String] {
        guard let tag else { return [] }
        return tag.split(whereSeparator: { ";/\u{0}".contains($0) }).compactMap { part -> String? in
            var name = part.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            let halves = name.components(separatedBy: ", ")
            if halves.count == 2, !halves[0].isEmpty, !halves[1].isEmpty, !halves[1].contains(" & ") {
                name = halves[1] + " " + halves[0]
            }
            guard !name.isEmpty, !placeholders.contains(fold(name)) else { return nil }
            return name
        }
    }

    /// The composer each song is listed under (songs not listed by composer are left out).
    public static func groups(for songs: [Song], overrides: [String: Mode] = [:]) -> [Int64: String] {
        let albums = Dictionary(grouping: songs, by: \.albumKey)
        // Albums that would be classical from their tags (the artist rule aside).
        var classicalByTags = Set<String>()
        for (key, tracks) in albums {
            let classical = tracks.filter { isClassicalGenre($0.genre) }.count
            if classical * 2 > tracks.count, tracks.contains(where: { !composers(in: $0.composer).isEmpty }) {
                classicalByTags.insert(key)
            }
        }
        // Artists with music that is not classical keep all their albums.
        var otherMusic = Set<String>()
        for (key, tracks) in albums where !classicalByTags.contains(key) {
            for track in tracks { otherMusic.insert(fold(track.artistName)) }
        }
        var listed: [(id: Int64, name: String)] = []
        for (key, tracks) in albums {
            let classical: Bool
            switch overrides[key] {
            case .composer: classical = true
            case .artist: classical = false
            case nil: classical = classicalByTags.contains(key) && !tracks.contains { otherMusic.contains(fold($0.artistName)) }
            }
            guard classical else { continue }
            for track in tracks {
                if let first = composers(in: track.composer).first { listed.append((track.id, first)) }
            }
        }
        let canonical = canonicalNames(listed.map(\.name))
        return Dictionary(listed.map { ($0.id, canonical[$0.name] ?? $0.name) }, uniquingKeysWith: { first, _ in first })
    }

    /// One spelling per composer: names that differ only in case or accents take the most used spelling, and a short
    /// form ("Vivaldi", "J.S. Bach") takes the one full name it fits ("Antonio Vivaldi", "Johann Sebastian Bach").
    static func canonicalNames(_ names: [String]) -> [String: String] {
        var counts: [String: [String: Int]] = [:]
        for name in names { counts[fold(name), default: [:]][name, default: 0] += 1 }
        // The spelling chosen for each folded name: the most used, then one in mixed case (not "ANTONIO VIVALDI"), then
        // the longest, then the first alphabetically.
        func mixedCase(_ name: String) -> Bool { name != name.uppercased() && name != name.lowercased() }
        var spelling: [String: String] = [:]
        for (key, variants) in counts {
            spelling[key] = variants.max { a, b in
                if a.value != b.value { return a.value < b.value }
                if mixedCase(a.key) != mixedCase(b.key) { return !mixedCase(a.key) }
                return a.key.count != b.key.count ? a.key.count < b.key.count : a.key > b.key
            }?.key
        }
        let keys = Array(spelling.keys)
        var target: [String: String] = [:]
        for key in keys {
            let candidates = keys.filter { $0 != key && fits(key, into: $0) }
            target[key] = candidates.count == 1 ? candidates[0] : key
        }
        var result: [String: String] = [:]
        for name in Set(names) {
            let key = fold(name)
            result[name] = spelling[target[key] ?? key] ?? name
        }
        return result
    }

    /// Whether `short` is a shorter way of writing `full`: the same last name, and its other words (or initials) found
    /// in order among the full name's.
    private static func fits(_ short: String, into full: String) -> Bool {
        let a = words(short)
        let b = words(full)
        guard let last = a.last, b.count > a.count || (b.count == a.count && short.count < full.count), b.last == last else { return false }
        let given = b.dropLast().filter { !particles.contains($0) }
        var index = given.startIndex
        for word in a.dropLast() where !particles.contains(word) {
            // "J.S." stands for two names.
            let parts = word.contains(".") ? word.split(separator: ".").map(String.init).filter { !$0.isEmpty } : [word]
            for part in parts {
                guard let match = given[index...].firstIndex(where: { candidate in
                    part.count == 1 ? candidate.hasPrefix(part) : candidate == part
                }) else { return false }
                index = given.index(after: match)
            }
        }
        return true
    }

    private static func words(_ name: String) -> [String] {
        name.split(whereSeparator: { $0.isWhitespace || $0 == "-" }).map(String.init).flatMap { word -> [String] in
            // "J.S." stays one word (split above); "J." becomes "j".
            word.hasSuffix(".") && word.dropLast().count == 1 ? [String(word.dropLast())] : [word]
        }
    }

    static func fold(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
