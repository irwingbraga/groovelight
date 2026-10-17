import LibraryKit
import MetadataKit
import SwiftUI

/// Review sheet for online metadata: pick the matching MusicBrainz release, then accept the proposed changes field by
/// field (album info), song by song, and the cover. The songs are fixed as one album even when their tags name
/// several (songs of one album imported with mixed-up tags); songs missing from the release can still take the
/// album's info.
struct FixMetadataSheet: View {
    var tracks: [Track]
    @Environment(AppModel.self) private var model
    private var group: SongGroup { SongGroup(tracks) }
    @Environment(\.dismiss) private var dismiss
    @AppStorage(MetadataStore.Keys.writeTags) private var writeToFiles = false

    enum Phase: Equatable {
        case searching, loadingRelease, ready, noResults, failed(String)
    }

    enum AlbumField: String, CaseIterable, Identifiable {
        case album = "Album", albumArtist = "Album Artist", year = "Year", genre = "Genre", compilation = "Compilation"
        var id: Self { self }
    }

    @State private var albumQuery = ""
    @State private var artistQuery = ""
    @State private var phase: Phase = .searching
    @State private var candidates: [MBRelease] = []
    @State private var selectedId: String?
    @State private var match: ReleaseMatch?
    @State private var proposal: [Int64: TrackMetadata] = [:]
    @State private var acceptedFields = Set(AlbumField.allCases)
    @State private var acceptedTracks: Set<Int64> = []
    @State private var cover: Data?
    @State private var coverSource: String?
    @State private var isLoadingCover = false
    @State private var useCover = true
    @State private var isApplying = false
    /// Songs written so far and in all, while applying.
    @State private var applyProgress: (done: Int, total: Int) = (0, 0)
    @State private var loadTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            header
                .disabled(isApplying)
            Divider()
            HStack(spacing: 0) {
                candidateList
                    .frame(width: 270)
                Divider()
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .disabled(isApplying)
            Divider()
            footer
        }
        .frame(width: 920, height: 640)
        .interactiveDismissDisabled(isApplying)
        #if DEBUG
        .onChange(of: "\(phase) cover=\(cover != nil) loadingCover=\(isLoadingCover) release=\(match?.release.title ?? "-") changes=\(changes.count)", initial: true) { _, state in
            DebugHitTargets.metadataSheetState = state
        }
        #endif
        .task {
            let group = group
            albumQuery = group.album ?? ""
            artistQuery = group.artist ?? ""
            search()
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Fix Metadata").font(.headline)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .help(group.isMixed ? "The songs are now in different albums. The ones you accept become one album." : "")
            }
            Spacer()
            TextField("Album", text: $albumQuery)
                .frame(width: 220)
            TextField("Artist", text: $artistQuery)
                .frame(width: 180)
            Button("Search") { search() }
                .disabled(phase == .searching)
        }
        .textFieldStyle(.roundedBorder)
        .onSubmit { search() }
        .padding(16)
    }

    private var candidateList: some View {
        Group {
            switch phase {
            case .searching:
                ProgressView("Searching MusicBrainz…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .noResults:
                ContentUnavailableView("No Matches", systemImage: "magnifyingglass",
                                       description: Text("Try another album title or artist."))
            case .failed(let message):
                ContentUnavailableView("Search Failed", systemImage: "wifi.exclamationmark", description: Text(message))
            case .loadingRelease, .ready:
                SelectableList(items: candidates, id: \.id, selection: Binding(get: { selectedId }, set: { id in
                    if let id, id != selectedId { loadRelease(id) }
                })) { release in
                    CandidateRow(release: release)
                }
            }
        }
        .background(.background.secondary)
    }

    @ViewBuilder
    private var detail: some View {
        if phase == .loadingRelease {
            ProgressView("Loading tracklist…")
        } else if let match, phase == .ready {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    coverRow(match)
                    albumFields(match)
                    songRows(match)
                }
                .padding(20)
            }
        } else if phase == .ready || phase == .noResults {
            Text("Select a release").foregroundStyle(.secondary)
        }
    }

    private func coverRow(_ match: ReleaseMatch) -> some View {
        HStack(spacing: 14) {
            ArtworkImage(hash: tracks.lazy.compactMap(\.artworkHash).first, size: .small, cornerRadius: 6)
                .frame(width: 90, height: 90)
            Image(systemName: "arrow.right").foregroundStyle(.secondary)
            Group {
                if let cover, let image = NSImage(data: cover) {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                } else if isLoadingCover {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "photo").font(.title2).foregroundStyle(.tertiary)
                }
            }
            .frame(width: 90, height: 90)
            .background(.quaternary, in: .rect(cornerRadius: 6))
            .clipShape(.rect(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Use this cover", isOn: $useCover)
                    .disabled(cover == nil)
                Text(cover == nil ? (isLoadingCover ? "Looking for a cover…" : "No cover found online")
                                  : "From \(coverSource ?? "the web")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            MatchScore(matched: match.matches.count, total: tracks.count, releaseTracks: match.release.totalTracks)
        }
    }

    private func albumFields(_ match: ReleaseMatch) -> some View {
        let sample = proposal.values.first ?? TrackMetadata()
        return VStack(alignment: .leading, spacing: 8) {
            Text("Album").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                ForEach(AlbumField.allCases) { field in
                    let current = currentValue(field)
                    let proposed = value(field, in: sample)
                    let changes = proposed != nil && proposed != current
                    GridRow {
                        Toggle(field.rawValue, isOn: Binding(
                            get: { changes && acceptedFields.contains(field) },
                            set: { on in if on { acceptedFields.insert(field) } else { acceptedFields.remove(field) } }))
                            .toggleStyle(.checkbox)
                            .disabled(!changes)
                            .frame(width: 130, alignment: .leading)
                        ChangeText(current: current, proposed: proposed)
                    }
                }
            }
        }
    }

    private func songRows(_ match: ReleaseMatch) -> some View {
        let ordered = tracks.sorted { lhs, rhs in
            let l = lhs.id.flatMap { match.match(for: $0) }
            let r = rhs.id.flatMap { match.match(for: $0) }
            switch (l, r) {
            case let (l?, r?): return (l.discNumber, l.trackNumber) < (r.discNumber, r.trackNumber)
            case (_?, nil): return true
            case (nil, _?): return false
            default: return lhs.title < rhs.title
            }
        }
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Songs").font(.headline)
                Spacer()
                Button(acceptedTracks.count == proposal.count ? "Deselect All" : "Select All") {
                    acceptedTracks = acceptedTracks.count == proposal.count ? [] : Set(proposal.keys)
                }
                .buttonStyle(.link)
                .disabled(proposal.isEmpty)
            }
            VStack(spacing: 0) {
                ForEach(ordered) { track in
                    let id = track.id ?? -1
                    let item = match.match(for: id)
                    HStack(spacing: 10) {
                        Toggle("", isOn: Binding(
                            get: { acceptedTracks.contains(id) },
                            set: { on in if on { acceptedTracks.insert(id) } else { acceptedTracks.remove(id) } }))
                            .toggleStyle(.checkbox)
                            .labelsHidden()
                            .disabled(proposal[id] == nil)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(track.trackNumber.map { "\($0). " } ?? "")\(track.title)")
                                .foregroundStyle(item == nil ? .secondary : .primary)
                            Text(track.url.lastPathComponent)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "arrow.right").foregroundStyle(.tertiary).font(.caption)
                        Group {
                            if let item {
                                let prefix = match.release.media?.count ?? 0 > 1 ? "\(item.discNumber)-\(item.trackNumber)" : "\(item.trackNumber)"
                                Text("\(prefix). \(item.track.title)")
                                    .foregroundStyle(item.score >= 0.75 ? .primary : Color.orange)
                                    .help(item.score >= 0.75 ? "Good match" : "Uncertain match: check this song")
                            } else {
                                Text("Not on this release: album info only")
                                    .foregroundStyle(.secondary)
                                    .help("Check it to give this song the album, album artist, year and genre, keeping its title and number")
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Text(formatDuration(track.duration))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .lineLimit(1)
                    .padding(.vertical, 6)
                    Divider()
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if isApplying {
                // Writing tags and covers into many files takes a while.
                ProgressView(value: Double(applyProgress.done), total: Double(max(applyProgress.total, 1)))
                    .frame(width: 200)
                Text("\(writeToFiles ? "Writing" : "Saving") \(min(applyProgress.done + 1, max(applyProgress.total, 1))) of \(max(applyProgress.total, 1)) songs…")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                Toggle("Write changes into the files", isOn: $writeToFiles)
                    .help("Off: fixes live in Groovelight's library only and survive rescans. On: tags and cover are saved into the audio files.")
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(isApplying)
            Button(isApplying ? "Applying…" : "Apply") { apply() }
                .keyboardShortcut(.defaultAction)
                .disabled(isApplying || phase != .ready || changeCount == 0)
        }
        .padding(16)
    }

    // MARK: - Values

    private var subtitle: String {
        let songs = tracks.count == 1 ? "1 song" : "\(tracks.count) songs"
        let group = group
        return group.isMixed ? "\(songs) from \(group.albumCount) albums, fixed as one album" : songs
    }

    private func currentValue(_ field: AlbumField) -> String? {
        // The songs' value, or the different ones they have now ("The Bends, Kid A").
        var distinct: [String] = []
        for value in tracks.compactMap({ value(field, in: $0.metadata) }) where !distinct.contains(value) { distinct.append(value) }
        guard distinct.count > 1 else { return distinct.first }
        return distinct.count <= 3 ? distinct.joined(separator: ", ") : "\(distinct.count) different values"
    }

    private func value(_ field: AlbumField, in metadata: TrackMetadata) -> String? {
        switch field {
        case .album: metadata.album
        case .albumArtist: metadata.albumArtist
        case .year: metadata.year.map(String.init)
        case .genre: metadata.genre
        case .compilation: metadata.isCompilation.map { $0 ? "Yes" : "No" }
        }
    }

    /// Accepted changes, keeping only fields that differ from the current values.
    private var changes: [Int64: TrackMetadata] {
        var result: [Int64: TrackMetadata] = [:]
        for track in tracks {
            guard let id = track.id, acceptedTracks.contains(id), var metadata = proposal[id] else { continue }
            if !acceptedFields.contains(.album) { metadata.album = nil }
            if !acceptedFields.contains(.albumArtist) { metadata.albumArtist = nil }
            if !acceptedFields.contains(.year) { metadata.year = nil }
            if !acceptedFields.contains(.genre) { metadata.genre = nil }
            if !acceptedFields.contains(.compilation) { metadata.isCompilation = nil }
            let diff = metadata.changes(from: track.metadata)
            if !diff.isEmpty { result[id] = diff }
        }
        return result
    }

    private var changeCount: Int { changes.count + (useCover && cover != nil ? 1 : 0) }

    // MARK: - Actions

    private func search() {
        loadTask?.cancel()
        phase = .searching
        match = nil
        loadTask = Task {
            do {
                let album = albumQuery.trimmingCharacters(in: .whitespaces)
                let artist = artistQuery.trimmingCharacters(in: .whitespaces)
                // Pass the fields as typed: an emptied field searches without it instead of falling back to the tags.
                let found = try await model.metadata.service.candidates(for: tracks, album: album, artist: artist)
                guard !Task.isCancelled else { return }
                candidates = Array(found.prefix(25))
                if let first = candidates.first {
                    loadRelease(first.id)
                } else {
                    phase = .noResults
                }
            } catch {
                if !Task.isCancelled { phase = .failed(error.localizedDescription) }
            }
        }
    }

    private func loadRelease(_ id: String) {
        loadTask?.cancel()
        selectedId = id
        phase = .loadingRelease
        cover = nil
        coverSource = nil
        loadTask = Task {
            do {
                let service = model.metadata.service
                let result = try await service.match(tracks, releaseId: id)
                guard !Task.isCancelled else { return }
                match = result
                proposal = ReleaseMatcher.proposal(for: result, includingUnmatched: true)
                // Songs not on the release are left out unless checked.
                acceptedTracks = Set(result.matches.map(\.localId))
                acceptedFields = Set(AlbumField.allCases)
                phase = .ready

                isLoadingCover = true
                let found = await service.cover(for: result.release, album: result.release.title, artist: result.release.artistName)
                guard !Task.isCancelled else { return }
                cover = found?.1
                coverSource = found?.0.source.rawValue
                isLoadingCover = false
            } catch {
                if !Task.isCancelled { phase = .failed(error.localizedDescription) }
            }
        }
    }

    private func apply() {
        isApplying = true
        applyProgress = (0, 0)
        let changes = changes
        let coverData = useCover ? cover : nil
        Task {
            let result = await model.metadata.apply(changes, cover: coverData, coverTrackIds: tracks.compactMap(\.id),
                                                    writeToFiles: writeToFiles) { done, total in
                applyProgress = (done, total)
            }
            isApplying = false
            if !result.failedWrites.isEmpty {
                model.errorMessage = "Could not write tags to \(result.failedWrites.count) file(s): \(result.failedWrites.prefix(3).joined(separator: ", ")). The changes were saved in the library instead."
            }
            await model.showAlbum(containing: tracks.compactMap(\.id).first)
            dismiss()
        }
    }
}

private struct CandidateRow: View {
    var release: MBRelease

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(release.title).font(.system(size: 13, weight: .semibold))
            Text(release.artistName).font(.system(size: 12)).foregroundStyle(.secondary)
            Text([release.year.map(String.init), release.country, "\(release.totalTracks) tracks", release.media?.first?.format]
                    .compactMap { $0 }.joined(separator: " · "))
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            let tags = [release.status == "Official" ? nil : release.status] + (release.releaseGroup?.secondaryTypes ?? []).map(Optional.some)
            if !tags.compactMap({ $0 }).isEmpty {
                HStack(spacing: 4) {
                    ForEach(tags.compactMap { $0 }, id: \.self) { tag in
                        Text(tag.uppercased())
                            .font(.system(size: 8, weight: .bold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.orange.opacity(0.18), in: .capsule)
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ChangeText: View {
    var current: String?
    var proposed: String?

    var body: some View {
        HStack(spacing: 8) {
            if let proposed, proposed != current {
                Text(current ?? "Empty")
                    .strikethrough(current != nil)
                    .foregroundStyle(.secondary)
                Image(systemName: "arrow.right").font(.caption).foregroundStyle(.tertiary)
                Text(proposed).fontWeight(.medium)
            } else {
                Text(current ?? "Empty").foregroundStyle(.secondary)
                Text("unchanged").font(.caption).foregroundStyle(.tertiary)
            }
        }
        .lineLimit(1)
    }
}

private struct MatchScore: View {
    var matched: Int
    var total: Int
    var releaseTracks: Int

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text("\(matched) of \(total) songs matched")
                .font(.callout.weight(.medium))
                .foregroundStyle(matched == total ? Color.green : Color.orange)
            Text("Release has \(releaseTracks) tracks")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

extension TrackMetadata {
    /// Only the fields that differ from `current`.
    func changes(from current: TrackMetadata) -> TrackMetadata {
        TrackMetadata(
            title: title != current.title ? title : nil,
            artist: artist != current.artist ? artist : nil,
            album: album != current.album ? album : nil,
            albumArtist: albumArtist != current.albumArtist ? albumArtist : nil,
            genre: genre != current.genre ? genre : nil,
            year: year != current.year ? year : nil,
            trackNumber: trackNumber != current.trackNumber ? trackNumber : nil,
            trackTotal: trackTotal != current.trackTotal ? trackTotal : nil,
            discNumber: discNumber != current.discNumber ? discNumber : nil,
            discTotal: discTotal != current.discTotal ? discTotal : nil,
            isCompilation: isCompilation != current.isCompilation ? isCompilation : nil,
            musicBrainzRecordingId: musicBrainzRecordingId != current.musicBrainzRecordingId ? musicBrainzRecordingId : nil,
            musicBrainzReleaseId: musicBrainzReleaseId != current.musicBrainzReleaseId ? musicBrainzReleaseId : nil,
            composer: composer != current.composer ? composer : nil,
            comment: comment != current.comment ? comment : nil,
            bpm: bpm != current.bpm ? bpm : nil,
            lyrics: lyrics != current.lyrics ? lyrics : nil
        )
    }
}
