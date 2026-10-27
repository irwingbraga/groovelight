import SwiftUI

/// A run of a sorted list under one letter of the A to Z index beside long lists (Artists, Songs), as in Contacts: the
/// items keep their place in the whole list (`offset`), for lists that play from where a song is.
struct IndexSection<Item>: Identifiable {
    let id: Int
    let letter: String
    let items: [(offset: Int, element: Item)]
}

enum SectionIndex {
    /// Lists shorter than this have no index: they are quick to scroll through (`-GLDebugIndexMinimum <count>` sets it,
    /// for layout checks with a small library).
    static var minimumCount: Int {
        #if DEBUG
        if UserDefaults.standard.object(forKey: "GLDebugIndexMinimum") != nil { return UserDefaults.standard.integer(forKey: "GLDebugIndexMinimum") }
        #endif
        return 40
    }

    /// The letter a name is filed under: its first letter without accents ("É" under E), or "#" for digits, symbols and
    /// other scripts.
    static func letter(_ text: String) -> String {
        guard let first = text.first(where: { $0.isLetter || $0.isNumber }) else { return "#" }
        let folded = String(first).folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil).uppercased()
        guard let scalar = folded.unicodeScalars.first, folded.unicodeScalars.count == 1, ("A"..."Z").contains(Character(scalar)) else { return "#" }
        return folded
    }

    /// A sorted list cut into runs of the same letter.
    static func sections<Item>(_ items: [Item], by name: (Item) -> String) -> [IndexSection<Item>] {
        var sections: [IndexSection<Item>] = []
        var run: [(offset: Int, element: Item)] = []
        var letter: String?
        for (offset, item) in items.enumerated() {
            let current = Self.letter(name(item))
            if current != letter, let letter, !run.isEmpty {
                sections.append(IndexSection(id: sections.count, letter: letter, items: run))
                run = []
            }
            letter = current
            run.append((offset, item))
        }
        if let letter, !run.isEmpty { sections.append(IndexSection(id: sections.count, letter: letter, items: run)) }
        return sections
    }

    /// Whether a list of this many items in these sections shows the index.
    static func visibility(count: Int, sections: Int) -> Visibility {
        count >= minimumCount && sections > 1 ? .visible : .hidden
    }
}
