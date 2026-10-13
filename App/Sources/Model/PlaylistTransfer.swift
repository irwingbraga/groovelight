import AppKit
import LibraryKit
import Observation
import UniformTypeIdentifiers

/// Importing playlist files of other players (M3U, M3U8, PLS, XSPF, WPL, Music XML) as playlists of library songs, and
/// exporting playlists to those formats.
@MainActor
@Observable
final class PlaylistTransfer {
    /// What an import found, shown when some songs were not in the library.
    struct Report: Identifiable {
        struct Playlist: Identifiable {
            let id = UUID()
            var name: String
            var found: Int
            var total: Int
            var missing: [String]
        }

        let id = UUID()
        var playlists: [Playlist]
    }

    var report: Report?
    private(set) var isImporting = false

    @ObservationIgnored private unowned let model: AppModel

    init(model: AppModel) {
        self.model = model
    }

    static var readableTypes: [UTType] {
        PlaylistFormat.readableExtensions.sorted().compactMap { UTType(filenameExtension: $0) }
    }

    static func isPlaylistFile(_ url: URL) -> Bool {
        PlaylistFormat.readableExtensions.contains(url.pathExtension.lowercased())
    }

    // MARK: - Import

    func chooseAndImport() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = Self.readableTypes
        panel.prompt = "Import"
        panel.message = "Choose playlists (M3U, M3U8, PLS, XSPF, WPL or a Music / iTunes XML export) to add their songs as playlists."
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        importFiles(panel.urls)
    }

    /// Reads the files, finds their songs in the library and creates one playlist per list.
    func importFiles(_ urls: [URL]) {
        guard !urls.isEmpty, !isImporting else { return }
        isImporting = true
        Task {
            defer { isImporting = false }
            var reports: [Report.Playlist] = []
            var created: [Int64] = []
            var problems: [String] = []
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                let result = await Task.detached(priority: .userInitiated) { Result { try PlaylistFile.read(url) } }.value
                if scoped { url.stopAccessingSecurityScopedResource() }
                switch result {
                case .failure(let error):
                    problems.append(error.localizedDescription)
                case .success(let documents):
                    for document in documents {
                        do {
                            let entries = document.entries
                            let ids = try await model.database.writer.read { try LibraryDatabase.matchPlaylistEntries($0, entries) }
                            let playlist = try model.database.createPlaylist(named: document.name, trackIds: ids.compactMap { $0 })
                            if let id = playlist.id { created.append(id) }
                            let missing = zip(entries, ids).filter { $0.1 == nil }.map { $0.0.label }
                            reports.append(.init(name: document.name, found: ids.count - missing.count, total: ids.count, missing: missing))
                        } catch {
                            problems.append("\(document.name): \(error.localizedDescription)")
                        }
                    }
                }
            }
            if created.count == 1, let id = created.first {
                model.selection = .playlist(id)
            } else if created.count > 1 {
                model.selection = .allPlaylists
            }
            if !problems.isEmpty {
                model.errorMessage = problems.joined(separator: "\n")
            }
            // Shown when something was left out, or several playlists came in at once (a Music XML export).
            if reports.contains(where: { !$0.missing.isEmpty }) || reports.count > 1 {
                report = Report(playlists: reports)
            }
        }
    }

    // MARK: - Export

    /// Saves a playlist (nil: Loved Songs) to a file, in the format and path style chosen in the save panel.
    func export(playlistId: Int64?) {
        Task {
            let (name, tracks) = await contents(of: playlistId)
            guard !tracks.isEmpty else {
                model.errorMessage = "\(name) has no songs to export."
                return
            }
            let options = ExportOptions()
            let panel = NSSavePanel()
            panel.title = "Export Playlist"
            panel.prompt = "Export"
            panel.nameFieldStringValue = Self.fileName(name)
            panel.canCreateDirectories = true
            panel.accessoryView = options.view(panel: panel)
            options.apply(to: panel)
            guard panel.runModal() == .OK, let url = panel.url else { return }
            do {
                try Self.write(name: name, tracks: tracks, to: url, format: options.format, relative: options.relative)
            } catch {
                model.errorMessage = "Could not export \(name): \(error.localizedDescription)"
            }
        }
    }

    static func write(name: String, tracks: [Track], to url: URL, format: PlaylistFormat, relative: Bool) throws {
        let style: PlaylistFile.PathStyle = relative ? .relative(to: url.deletingLastPathComponent()) : .absolute
        try PlaylistFile.write(name: name, tracks: tracks, format: format, paths: style).write(to: url, options: .atomic)
    }

    func contents(of playlistId: Int64?) async -> (String, [Track]) {
        let result = try? await model.database.writer.read { db -> (String, [Track]) in
            guard let playlistId else { return ("Loved Songs", try LibraryDatabase.lovedTracks(db)) }
            let name = try LibraryKit.Playlist.fetchOne(db, key: playlistId)?.name ?? "Playlist"
            return (name, try LibraryDatabase.tracks(db, playlistId: playlistId))
        }
        return result ?? ("Playlist", [])
    }

    /// A file name without the characters Finder or other systems refuse.
    private static func fileName(_ name: String) -> String {
        let cleaned = name.components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined(separator: "-")
        return cleaned.trimmingCharacters(in: .whitespaces).isEmpty ? "Playlist" : cleaned
    }
}

/// The save panel's format menu and path option. The format is remembered between exports.
@MainActor
private final class ExportOptions: NSObject {
    private static let formatKey = "playlists.exportFormat"
    private static let relativeKey = "playlists.exportRelative"

    var format: PlaylistFormat = PlaylistFormat(rawValue: UserDefaults.standard.string(forKey: formatKey) ?? "") ?? .m3u8
    var relative = UserDefaults.standard.bool(forKey: relativeKey)
    private weak var panel: NSSavePanel?
    private var relativeBox: NSButton?

    func view(panel: NSSavePanel) -> NSView {
        self.panel = panel
        let label = NSTextField(labelWithString: "Format:")
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        for format in PlaylistFormat.exportable {
            popup.addItem(withTitle: "\(format.name) (.\(format.fileExtension))")
        }
        popup.selectItem(at: PlaylistFormat.exportable.firstIndex(of: format) ?? 0)
        popup.target = self
        popup.action = #selector(formatChanged(_:))
        let box = NSButton(checkboxWithTitle: "Paths relative to the playlist file", target: self, action: #selector(relativeChanged(_:)))
        box.state = relative ? .on : .off
        relativeBox = box
        updateRelativeBox()

        let row = NSStackView(views: [label, popup])
        row.spacing = 8
        let stack = NSStackView(views: [row, box])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 20, bottom: 12, right: 20)
        return stack
    }

    func apply(to panel: NSSavePanel) {
        panel.allowedContentTypes = [UTType(filenameExtension: format.fileExtension) ?? .data]
    }

    @objc private func formatChanged(_ sender: NSPopUpButton) {
        format = PlaylistFormat.exportable[max(sender.indexOfSelectedItem, 0)]
        UserDefaults.standard.set(format.rawValue, forKey: Self.formatKey)
        updateRelativeBox()
        if let panel { apply(to: panel) }
    }

    @objc private func relativeChanged(_ sender: NSButton) {
        relative = sender.state == .on
        UserDefaults.standard.set(relative, forKey: Self.relativeKey)
    }

    /// Music XML always holds full file addresses.
    private func updateRelativeBox() {
        relativeBox?.isEnabled = format != .musicXML
        if format == .musicXML { relative = false; relativeBox?.state = .off }
        else { relativeBox?.state = UserDefaults.standard.bool(forKey: Self.relativeKey) ? .on : .off; relative = relativeBox?.state == .on }
    }
}
