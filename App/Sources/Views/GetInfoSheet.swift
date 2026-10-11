import AppKit
import LibraryKit
import SwiftUI

/// Manual tag editor for one or several songs (like Get Info in Music): details, artwork, lyrics and file info.
///
/// With several songs, fields that differ show "Mixed" and only the fields that were changed are applied; per-song
/// fields (title, track number, lyrics) are disabled. Clearing a field removes the tag.
struct GetInfoSheet: View {
    var tracks: [Track]
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @AppStorage(MetadataStore.Keys.writeTags) private var writeToFiles = false

    enum Tab: String, CaseIterable, Identifiable {
        case details = "Details", artwork = "Artwork", lyrics = "Lyrics", file = "File"
        var id: Self { self }
    }

    enum Field: CaseIterable {
        case title, artist, album, albumArtist, composer, genre, year, bpm, trackNumber, trackTotal, discNumber, discTotal, comment

        var isNumber: Bool {
            switch self {
            case .year, .bpm, .trackNumber, .trackTotal, .discNumber, .discTotal: true
            default: false
            }
        }

        /// Fields that only make sense per song.
        var isPerSong: Bool { self == .title || self == .trackNumber }

        func value(of track: Track) -> String {
            switch self {
            case .title: track.title
            case .artist: track.artist ?? ""
            case .album: track.album ?? ""
            case .albumArtist: track.albumArtist ?? ""
            case .composer: track.composer ?? ""
            case .genre: track.genre ?? ""
            case .year: track.year.map(String.init) ?? ""
            case .bpm: track.bpm.map(String.init) ?? ""
            case .trackNumber: track.trackNumber.map(String.init) ?? ""
            case .trackTotal: track.trackTotal.map(String.init) ?? ""
            case .discNumber: track.discNumber.map(String.init) ?? ""
            case .discTotal: track.discTotal.map(String.init) ?? ""
            case .comment: track.comment ?? ""
            }
        }
    }

    @State private var tab: Tab = .details
    @State private var values: [Field: String] = [:]
    @State private var initial: [Field: String] = [:]
    @State private var mixed: Set<Field> = []
    @State private var compilation: Bool?
    @State private var initialCompilation: Bool?
    @State private var lyrics = ""
    @State private var initialLyrics = ""
    @State private var newCover: Data?
    @State private var isDropTargeted = false
    @State private var isSaving = false
    @State private var didLoad = false

    private var isSingle: Bool { tracks.count == 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            Picker("Section", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Group {
                switch tab {
                case .details: details
                case .artwork: artwork
                case .lyrics: lyricsEditor
                case .file: fileInfo
                }
            }
            .frame(maxWidth: .infinity, minHeight: 330, alignment: .top)

            HStack {
                Toggle("Write changes into the files", isOn: $writeToFiles)
                    .help("Off: changes live in Groovelight's library only and survive rescans. On: tags and artwork are saved into the audio files (except for songs from cue sheets, which share one file).")
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isSaving ? "Saving…" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSaving || !isValid)
            }
        }
        .padding(20)
        .frame(width: 600)
        .onAppear(perform: load)
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 14) {
            Group {
                if let newCover, let image = NSImage(data: newCover) {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    ArtworkImage(hash: tracks.first?.artworkHash, size: .small, cornerRadius: 0)
                }
            }
            .frame(width: 64, height: 64)
            .clipShape(.rect(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                Text(isSingle ? (tracks.first?.title ?? "") : "\(tracks.count) songs")
                    .font(.headline)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
        }
    }

    private var subtitle: String {
        let albums = Set(tracks.map(\.displayAlbum))
        let artists = Set(tracks.map(\.displayArtist))
        let artist = artists.count == 1 ? artists.first! : "Various Artists"
        return albums.count == 1 ? "\(artist) · \(albums.first!)" : "\(artist) · \(albums.count) albums"
    }

    private var details: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 9) {
            row("Title", .title)
            row("Artist", .artist)
            row("Album", .album)
            row("Album Artist", .albumArtist)
            row("Composer", .composer)
            row("Genre", .genre)
            GridRow {
                label("Year")
                HStack(spacing: 8) {
                    field(.year).frame(width: 70)
                    Text("BPM").foregroundStyle(.secondary)
                    field(.bpm).frame(width: 60)
                }
            }
            GridRow {
                label("Track")
                HStack(spacing: 8) {
                    field(.trackNumber).frame(width: 50)
                    Text("of").foregroundStyle(.secondary)
                    field(.trackTotal).frame(width: 50)
                    Text("Disc").foregroundStyle(.secondary).padding(.leading, 12)
                    field(.discNumber).frame(width: 50)
                    Text("of").foregroundStyle(.secondary)
                    field(.discTotal).frame(width: 50)
                }
            }
            GridRow {
                label("Compilation")
                Picker("Compilation", selection: Binding(get: { compilation }, set: { compilation = $0 })) {
                    Text("No").tag(Bool?.some(false))
                    Text("Yes").tag(Bool?.some(true))
                    if initialCompilation == nil { Text("Mixed").tag(Bool?.none) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            GridRow(alignment: .top) {
                label("Comments")
                TextField(mixed.contains(.comment) ? "Mixed" : "", text: binding(.comment), axis: .vertical)
                    .lineLimit(2...4)
            }
        }
        .textFieldStyle(.roundedBorder)
    }

    private func row(_ title: String, _ field: Field) -> some View {
        GridRow {
            label(title)
            self.field(field)
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .gridColumnAlignment(.trailing)
    }

    private func field(_ field: Field) -> some View {
        let disabled = !isSingle && field.isPerSong
        let invalid = field.isNumber && !isValidNumber(values[field] ?? "")
        // Number boxes are narrow: a dash for the per-song placeholder.
        let perSong = field.isNumber ? "–" : "Per song"
        return TextField(disabled ? perSong : (mixed.contains(field) ? "Mixed" : ""), text: binding(field))
            .disabled(disabled)
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(invalid ? Color.red : .clear, lineWidth: 1.5))
            .help(invalid ? "Enter a whole number, or leave empty to remove it" : "")
    }

    private func binding(_ field: Field) -> Binding<String> {
        Binding(get: { values[field] ?? "" }, set: { values[field] = $0 })
    }

    private var artwork: some View {
        VStack(spacing: 12) {
            Group {
                if let newCover, let image = NSImage(data: newCover) {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                } else if Set(tracks.map(\.artworkHash)).count > 1 {
                    ZStack {
                        Rectangle().fill(.quaternary)
                        Text("Mixed artwork").foregroundStyle(.secondary)
                    }
                } else {
                    ArtworkImage(hash: tracks.first?.artworkHash, size: .large, cornerRadius: 0)
                }
            }
            .frame(width: 240, height: 240)
            .clipShape(.rect(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(isDropTargeted ? Color.brand : .clear, lineWidth: 3))
            .dropDestination(for: URL.self) { urls, _ in
                urls.first.map(useImage(at:)) ?? false
            } isTargeted: { isDropTargeted = $0 }
            HStack {
                Button("Choose Image…") { chooseImage() }
                if newCover != nil {
                    Button("Revert") { newCover = nil }
                }
            }
            Text(isSingle ? "Drop an image on the artwork to use it." : "The image is used for all \(tracks.count) songs.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var lyricsEditor: some View {
        if isSingle {
            VStack(alignment: .leading, spacing: 6) {
                TextEditor(text: $lyrics)
                    .font(.system(size: 13, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(.background.secondary, in: .rect(cornerRadius: 6))
                    .frame(minHeight: 300)
                Text("Plain text, or synced lyrics in LRC format (\"[01:23.45] line\"). Leave empty to remove them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            ContentUnavailableView("Lyrics are per song", systemImage: "quote.bubble",
                                   description: Text("Select a single song to edit its lyrics."))
        }
    }

    @ViewBuilder
    private var fileInfo: some View {
        if isSingle, let track = tracks.first {
            let spec = track.audioSpec
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 7) {
                info("Format", spec.tier == .standard ? spec.summary : "\(spec.tier.displayName) · \(spec.summary)")
                info("Bit rate", spec.bitrateText ?? "")
                info("Channels", spec.channelsText ?? "")
                info("Duration", formatDuration(track.duration))
                info("Size", ByteCountFormatter.string(fromByteCount: track.fileSize, countStyle: .file))
                info("Date Added", track.dateAdded.formatted(date: .abbreviated, time: .shortened))
                info("Plays", "\(track.playCount)\(track.lastPlayedAt.map { ", last \($0.formatted(.relative(presentation: .named)))" } ?? "")")
                GridRow(alignment: .top) {
                    Text("Location").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(track.url.path)
                            .textSelection(.enabled)
                            .lineLimit(3)
                            .truncationMode(.middle)
                        Button("Show in Finder") { model.showInFinder([track]) }
                            .buttonStyle(.link)
                    }
                }
                if track.isCueTrack, let sheet = track.cueSheetURL {
                    info("Cue Sheet", sheet == track.url ? "Embedded in the file" : sheet.lastPathComponent)
                    info("Range", "\(formatDuration(track.startTime ?? 0)) to \(track.endTime.map(formatDuration) ?? "end of file")")
                }
            }
        } else {
            ContentUnavailableView("\(tracks.count) songs", systemImage: "doc.on.doc",
                                   description: Text("Select a single song to see its file details."))
        }
    }

    private func info(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value).textSelection(.enabled)
        }
    }

    // MARK: - Loading and saving

    private func load() {
        guard !didLoad else { return }
        didLoad = true
        for field in Field.allCases {
            let distinct = Set(tracks.map { field.value(of: $0) })
            if distinct.count == 1 {
                initial[field] = distinct.first
            } else {
                initial[field] = ""
                mixed.insert(field)
            }
        }
        values = initial
        let flags = Set(tracks.map(\.isCompilation))
        initialCompilation = flags.count == 1 ? flags.first : nil
        compilation = initialCompilation
        initialLyrics = isSingle ? (tracks.first?.lyrics ?? "") : ""
        lyrics = initialLyrics
        #if DEBUG
        // Debug tour: type into fields.
        for (field, value) in DebugHitTargets.getInfoPrefill { values[field] = value }
        if let text = DebugHitTargets.getInfoLyrics { lyrics = text }
        DebugHitTargets.getInfoMixed = mixed.count
        #endif
    }

    private func isValidNumber(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || (Int(trimmed).map { $0 >= 0 } ?? false)
    }

    private var isValid: Bool {
        Field.allCases.filter(\.isNumber).allSatisfy { isValidNumber(values[$0] ?? "") }
    }

    /// The edits as a `TrackMetadata` (fields left alone stay nil). Empty text or numbers clear the tag.
    private var edits: TrackMetadata {
        var metadata = TrackMetadata()
        func changed(_ field: Field) -> String? {
            let value = values[field] ?? ""
            // A mixed field left empty was not edited.
            guard value != initial[field], !(mixed.contains(field) && value.isEmpty) else { return nil }
            return value
        }
        func number(_ field: Field) -> Int? {
            changed(field).map { Int($0.trimmingCharacters(in: .whitespaces)) ?? 0 }
        }
        if isSingle { metadata.title = changed(.title) }
        metadata.artist = changed(.artist)
        metadata.album = changed(.album)
        metadata.albumArtist = changed(.albumArtist)
        metadata.composer = changed(.composer)
        metadata.genre = changed(.genre)
        metadata.comment = changed(.comment)
        metadata.year = number(.year)
        metadata.bpm = number(.bpm)
        if isSingle { metadata.trackNumber = number(.trackNumber) }
        metadata.trackTotal = number(.trackTotal)
        metadata.discNumber = number(.discNumber)
        metadata.discTotal = number(.discTotal)
        if compilation != initialCompilation { metadata.isCompilation = compilation }
        if isSingle, lyrics != initialLyrics { metadata.lyrics = lyrics }
        return metadata
    }

    private func save() {
        let metadata = edits
        let ids = tracks.compactMap(\.id)
        guard !metadata.isEmpty || newCover != nil else {
            dismiss()
            return
        }
        isSaving = true
        Task {
            let changes = metadata.isEmpty ? [:] : Dictionary(uniqueKeysWithValues: ids.map { ($0, metadata) })
            let result = await model.metadata.apply(changes, cover: newCover, coverTrackIds: newCover == nil ? [] : ids,
                                                    writeToFiles: writeToFiles)
            isSaving = false
            if !result.failedWrites.isEmpty {
                model.errorMessage = "Could not write tags to \(result.failedWrites.count) file(s): \(result.failedWrites.prefix(3).joined(separator: ", ")). The changes were saved in the library instead."
            }
            // The album may have been renamed: reopen its page under the new name.
            await model.showAlbum(containing: ids.first)
            dismiss()
        }
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.prompt = "Use Image"
        panel.message = "Choose artwork for \(isSingle ? "this song" : "these \(tracks.count) songs")."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        _ = useImage(at: url)
    }

    private func useImage(at url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url), NSImage(data: data) != nil else {
            model.errorMessage = "\(url.lastPathComponent) is not an image Groovelight can read."
            return false
        }
        newCover = data
        return true
    }
}
