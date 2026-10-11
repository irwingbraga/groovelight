import Foundation

/// A CUE sheet: an album stored as one (or a few) audio files, with the track list and where each track starts.
public struct CueSheet: Hashable, Sendable {
    public struct Track: Hashable, Sendable {
        public var number: Int
        public var title: String?
        public var performer: String?
        public var songwriter: String?
        public var isrc: String?
        /// INDEX 01, in seconds from the start of the file: where the track starts.
        public var start: Double
        /// INDEX 00 (start of the pregap), when present.
        public var pregap: Double?
    }

    public struct File: Hashable, Sendable {
        /// The file name as written in the sheet (relative to the sheet).
        public var name: String
        public var tracks: [Track]
    }

    public var title: String?
    public var performer: String?
    public var songwriter: String?
    public var genre: String?
    public var year: Int?
    public var discNumber: Int?
    public var discTotal: Int?
    public var comment: String?
    public var files: [File]

    /// All tracks of all files, in order.
    public var tracks: [Track] { files.flatMap(\.tracks) }

    // MARK: Parsing

    /// Reads a cue sheet, guessing the text encoding (UTF-8 with or without BOM, UTF-16, else Windows-1252, which many
    /// older rips use).
    public static func read(_ url: URL) -> CueSheet? {
        guard let data = try? Data(contentsOf: url), data.count < 1_000_000 else { return nil }
        return parse(decode(data))
    }

    static func decode(_ data: Data) -> String {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { return String(decoding: data.dropFirst(3), as: UTF8.self) }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) { return String(data: data, encoding: .utf16) ?? "" }
        if let text = String(data: data, encoding: .utf8) { return text }
        return String(data: data, encoding: .windowsCP1252) ?? String(decoding: data, as: UTF8.self)
    }

    /// Parses cue sheet text; nil when it has no FILE with tracks.
    public static func parse(_ text: String) -> CueSheet? {
        var sheet = CueSheet(files: [])
        var currentTrack: Track?
        func finishTrack() {
            if let track = currentTrack, !sheet.files.isEmpty { sheet.files[sheet.files.count - 1].tracks.append(track) }
            currentTrack = nil
        }

        // A byte order mark can survive decoding (or come from an embedded sheet).
        let text = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        for rawLine in text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").split(separator: "\n") {
            let words = tokenize(String(rawLine).trimmingCharacters(in: .whitespaces))
            guard let command = words.first?.uppercased() else { continue }
            let value = words.count > 1 ? words[1] : nil
            switch command {
            case "FILE":
                finishTrack()
                if let value { sheet.files.append(File(name: value, tracks: [])) }
            case "TRACK":
                finishTrack()
                // Only audio tracks ("TRACK 03 AUDIO").
                if let number = value.flatMap(Int.init), words.count < 3 || words[2].uppercased() == "AUDIO" {
                    currentTrack = Track(number: number, start: 0)
                }
            case "INDEX":
                guard words.count >= 3, let index = Int(words[1]), let time = parseTime(words[2]) else { continue }
                if index == 1 { currentTrack?.start = time } else if index == 0 { currentTrack?.pregap = time }
            case "TITLE":
                if currentTrack != nil { currentTrack?.title = value } else { sheet.title = value }
            case "PERFORMER":
                if currentTrack != nil { currentTrack?.performer = value } else { sheet.performer = value }
            case "SONGWRITER":
                if currentTrack != nil { currentTrack?.songwriter = value } else { sheet.songwriter = value }
            case "ISRC":
                currentTrack?.isrc = value
            case "REM":
                guard words.count >= 3 else { continue }
                let field = words[1].uppercased()
                let remValue = words[2...].joined(separator: " ")
                switch field {
                case "GENRE": sheet.genre = remValue
                case "DATE": sheet.year = remValue.prefix(4).allSatisfy(\.isNumber) ? Int(remValue.prefix(4)) : nil
                case "DISCNUMBER": sheet.discNumber = Int(remValue)
                case "TOTALDISCS": sheet.discTotal = Int(remValue)
                case "COMMENT": sheet.comment = remValue
                default: break
                }
            default:
                break
            }
        }
        finishTrack()
        sheet.files.removeAll { $0.tracks.isEmpty }
        return sheet.files.isEmpty ? nil : sheet
    }

    /// Splits a line into words, keeping "quoted values" together.
    static func tokenize(_ line: String) -> [String] {
        var words: [String] = []
        var current = ""
        var inQuotes = false
        for character in line {
            if character == "\"" {
                inQuotes.toggle()
                if !inQuotes { words.append(current); current = "" }
            } else if character == " " || character == "\t", !inQuotes {
                if !current.isEmpty { words.append(current); current = "" }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { words.append(current) }
        return words
    }

    /// "mm:ss:ff" (75 frames per second) to seconds.
    static func parseTime(_ text: String) -> Double? {
        let parts = text.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return Double(parts[0] * 60 + parts[1]) + Double(parts[2]) / 75
    }

    // MARK: Files

    /// Finds the audio file a FILE line refers to: the exact name, a case-insensitive match, or (rips often say
    /// ".wav" for a file later compressed to ".flac") the same name with another audio extension.
    public static func resolve(_ name: String, relativeTo directory: URL, audioFiles: Set<String>) -> URL? {
        let normalized = name.replacingOccurrences(of: "\\", with: "/")
        let direct = directory.appendingPathComponent(normalized).standardizedFileURL
        if audioFiles.contains(direct.path) { return direct }
        let lowerName = direct.lastPathComponent.lowercased()
        let lowerBase = direct.deletingPathExtension().lastPathComponent.lowercased()
        let folder = direct.deletingLastPathComponent().path
        let siblings = audioFiles.filter { URL(fileURLWithPath: $0).deletingLastPathComponent().path == folder }
        if let match = siblings.first(where: { URL(fileURLWithPath: $0).lastPathComponent.lowercased() == lowerName }) {
            return URL(fileURLWithPath: match)
        }
        if let match = siblings.first(where: { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent.lowercased() == lowerBase }) {
            return URL(fileURLWithPath: match)
        }
        return nil
    }
}
