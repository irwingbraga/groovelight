import AVFAudio
import LibraryKit
import MetadataKit
import PlayerCore
import SwiftUI

/// What Now Playing shows beside (or, on a phone, instead of) the cover: the lyrics or what plays next.
enum NowPlayingPanel: Hashable {
    case lyrics
    case upNext
}

// MARK: - Quality

extension QualityTier {
    /// The Mac's badge colors: gold for Hi-Res, teal for Lossless, purple for DSD.
    var tint: Color {
        switch self {
        case .hiResLossless: Color(red: 0.88, green: 0.70, blue: 0.30)
        case .lossless: Color(red: 0.35, green: 0.75, blue: 0.80)
        case .dsd: Color(red: 0.70, green: 0.50, blue: 0.95)
        case .highQuality, .standard: .secondary
        }
    }

    var badgeText: String {
        switch self {
        case .hiResLossless: "Hi-Res"
        case .lossless: "Lossless"
        case .dsd: "DSD"
        case .highQuality: "HQ"
        case .standard: ""
        }
    }

    var symbol: String? {
        switch self {
        case .hiResLossless, .lossless: "waveform"
        case .dsd: "waveform.path"
        case .highQuality, .standard: nil
        }
    }
}

/// The quality mark, as on the Mac (Apple Music's Lossless mark): nothing for standard lossy files.
struct QualityBadge: View {
    var tier: QualityTier
    /// The smaller one, for song rows and the player bars.
    var isMini = false

    var body: some View {
        if tier != .standard {
            HStack(spacing: 3) {
                if let symbol = tier.symbol { Image(systemName: symbol).font(.system(size: isMini ? 7 : 8, weight: .bold)) }
                Text(tier.badgeText.uppercased()).font(.system(size: isMini ? 8 : 9, weight: .bold)).tracking(0.4)
            }
            .foregroundStyle(tier.tint)
            .padding(.horizontal, isMini ? 4 : 6)
            .padding(.vertical, isMini ? 1 : 2)
            .background(tier.tint.opacity(0.14), in: .capsule)
            .overlay(Capsule().strokeBorder(tier.tint.opacity(0.55), lineWidth: 0.8))
            .fixedSize()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(tier.displayName)
        }
    }
}

/// The badge and the format ("FLAC · 24-bit / 96 kHz"); a tap shows the details and where the sound goes.
struct QualityLabel: View {
    let spec: AudioSpec
    @State private var showsDetails = false

    var body: some View {
        Button { showsDetails = true } label: {
            HStack(spacing: 6) {
                QualityBadge(tier: spec.tier)
                Text(spec.summary).lineLimit(1)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showsDetails) {
            AudioDetails(spec: spec)
                .presentationDetents([.medium])
        }
    }
}

/// An album's quality, as on the Mac's album page: the badge and the shared format ("FLAC · 24-bit / 96 kHz"), or the
/// best badge and "Mixed formats" with the codecs when its songs differ.
struct AlbumQualitySummary: View {
    let specs: [AudioSpec]

    var body: some View {
        Group {
            if let spec = AudioSpec.uniform(specs) {
                HStack(spacing: 6) {
                    QualityBadge(tier: spec.tier)
                    Text(spec.summary)
                }
            } else if let best = specs.map(\.tier).max() {
                HStack(spacing: 6) {
                    QualityBadge(tier: best)
                    Text("Mixed formats · \(Array(Set(specs.map(\.codec.shortName))).sorted().joined(separator: ", "))")
                }
            }
        }
        .font(.caption.weight(.medium).monospacedDigit())
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}

/// The song's format and resolution, and the output it plays through.
struct AudioDetails: View {
    let spec: AudioSpec
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("File") {
                    LabeledContent("Quality", value: spec.tier.displayName)
                    LabeledContent("Format", value: spec.formatName ?? "Unknown")
                    if let rate = spec.sampleRateText { LabeledContent("Sample Rate", value: rate) }
                    if let bits = spec.bitDepth { LabeledContent("Bit Depth", value: "\(bits)-bit") }
                    if let bitrate = spec.bitrate { LabeledContent("Bitrate", value: "\(Int(bitrate.rounded())) kbps") }
                    if let channels = spec.channels { LabeledContent("Channels", value: channels == 2 ? "Stereo" : channels == 1 ? "Mono" : "\(channels)") }
                }
                Section("Output") {
                    let session = AVAudioSession.sharedInstance()
                    LabeledContent("Playing Through", value: session.currentRoute.outputs.map(\.portName).joined(separator: ", "))
                    LabeledContent("Output Rate", value: "\((session.sampleRate / 1000).formatted(.number.precision(.fractionLength(0...1)))) kHz")
                }
            }
            .navigationTitle("Audio Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}

// MARK: - Lyrics

/// The lyrics. Synced ones follow the song (the line being sung lit and kept in view, a tap on a line goes there), as on
/// the Mac; plain ones scroll freely.
struct LyricsPanel: View {
    let item: NowPlayingItem
    var fontSize: CGFloat = 26

    var body: some View {
        if item.lyrics.lines.isEmpty {
            ContentUnavailableView("No Lyrics", systemImage: "quote.bubble",
                                   description: Text("Lyrics in the song's file, or found by the Mac, show up here."))
        } else if item.lyrics.isSynced {
            SyncedLyricsView(lyrics: item.lyrics, fontSize: fontSize)
        } else {
            ScrollView {
                Text(item.lyrics.plainText)
                    .font(.system(size: fontSize * 0.85, weight: .bold))
                    .lineSpacing(fontSize * 0.4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 32)
            }
            .scrollIndicators(.never)
            .mask(Self.fade)
        }
    }

    static let fade = LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .white, location: 0.08),
                                             .init(color: .white, location: 0.92), .init(color: .clear, location: 1)],
                                     startPoint: .top, endPoint: .bottom)
}

private struct SyncedLyricsView: View {
    let lyrics: SyncedLyrics
    let fontSize: CGFloat
    @Environment(AppModel.self) private var model

    var body: some View {
        // The position moved on between updates, so a line lights up as it starts; only a new line redraws them.
        TimelineView(.animation(minimumInterval: 0.05, paused: model.nowPlaying?.isPlaying != true)) { context in
            SyncedLyricsLines(lyrics: lyrics, fontSize: fontSize, active: lyrics.lineIndex(at: model.time(at: context.date) + 0.15))
                .equatable()
        }
    }
}

private struct SyncedLyricsLines: View, Equatable {
    let lyrics: SyncedLyrics
    let fontSize: CGFloat
    let active: Int?
    @Environment(AppModel.self) private var model
    @State private var height: CGFloat = 0

    /// Where the line being sung is held, from the top.
    private static let anchor: CGFloat = 0.3

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.active == rhs.active && lhs.fontSize == rhs.fontSize && lhs.lyrics == rhs.lyrics
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: fontSize * 0.7) {
                    ForEach(Array(lyrics.lines.enumerated()), id: \.offset) { index, line in
                        Text(line.text.isEmpty ? "♪" : line.text)
                            .font(.system(size: fontSize, weight: .bold))
                            .foregroundStyle(Color.primary.opacity(index == active ? 1 : 0.35))
                            .scaleEffect(index == active ? 1.03 : 1, anchor: .leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(.rect)
                            .onTapGesture { if let time = line.time { model.seek(to: time) } }
                            .id(index)
                    }
                }
                .padding(.top, max(fontSize * 1.5, height * 0.08))
                .padding(.bottom, max(fontSize * 6, height * (1 - Self.anchor)))
                .animation(.easeOut(duration: 0.3), value: active)
                .id("lines")
            }
            .scrollIndicators(.never)
            .mask(LyricsPanel.fade)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
            .onChange(of: active, initial: true) { _, index in
                withAnimation(.smooth(duration: 0.6)) {
                    if let index {
                        proxy.scrollTo(index, anchor: UnitPoint(x: 0, y: Self.anchor))
                    } else {
                        proxy.scrollTo("lines", anchor: .top)
                    }
                }
            }
        }
    }
}

// MARK: - Up Next

/// What plays next. Here: a tap plays a song, and songs can be moved and removed. Elsewhere (the Mac, another device):
/// the songs of its queue that are on this device, shown only.
struct UpNextPanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("Up Next").font(.title3.bold())
                Spacer()
                if model.isRemote {
                    Text("On \(model.targetName)").font(.footnote).foregroundStyle(.secondary)
                } else if model.isShuffled {
                    Label("Shuffled", systemImage: "shuffle").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal)
            if model.isRemote { remote } else { here }
        }
    }

    @ViewBuilder private var here: some View {
        let controller = model.player.controller
        let base = (controller.queue.currentIndex ?? -1) + 1
        let upcoming = Array(controller.queue.upcoming.enumerated())
        if upcoming.isEmpty {
            nothing
        } else {
            List {
                ForEach(upcoming, id: \.offset) { offset, item in
                    Button { controller.jump(toQueueIndex: base + offset) } label: {
                        row(title: item.title, artist: item.artist, hash: model.library.artworkHash(trackId: item.id))
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.clear)
                }
                .onMove { source, destination in
                    controller.moveInQueue(fromOffsets: IndexSet(source.map { $0 + base }), toOffset: destination + base)
                }
                .onDelete { offsets in
                    for offset in offsets.sorted(by: >) { controller.removeFromQueue(at: base + offset) }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    @ViewBuilder private var remote: some View {
        let state = model.remote.state
        let ids = state.flatMap { state in state.queueIndex.map { Array(state.queue.dropFirst($0 + 1)) } } ?? []
        let found = model.library.read { db in try ids.compactMap { try LibraryDatabase.track(db, id: $0) } } ?? []
        if found.isEmpty {
            nothing
        } else {
            List(Array(found.enumerated()), id: \.offset) { _, track in
                row(title: track.title, artist: track.displayArtist, hash: track.artworkHash)
                    .listRowBackground(Color.clear)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    private var nothing: some View {
        ContentUnavailableView("Nothing Up Next", systemImage: "list.bullet", description: Text("Nothing plays after this song."))
            .frame(maxHeight: .infinity)
    }

    private func row(title: String, artist: String, hash: String?) -> some View {
        HStack(spacing: 12) {
            Cover(hash: hash, size: 44, corner: 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(1)
                Text(artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .contentShape(.rect)
    }
}

// MARK: - The buttons under the controls

/// Love, AirPlay, Play On and Up Next, under the controls (the lyrics are at the top, as on the Mac). Up Next shows its
/// panel (again to go back to the cover).
struct NowPlayingButtons: View {
    @Environment(AppModel.self) private var model
    @Binding var panel: NowPlayingPanel?

    var body: some View {
        let isLoved = model.nowPlaying?.isLoved ?? false
        HStack {
            Button { model.toggleLove() } label: {
                Label(isLoved ? "Unlove" : "Love", systemImage: isLoved ? "heart.fill" : "heart")
                    .labelStyle(.iconOnly)
                    .font(.title3)
                    .foregroundStyle(isLoved ? AnyShapeStyle(.pink) : AnyShapeStyle(.white))
                    .frame(width: 40, height: 40)
                    .contentTransition(.symbolEffect(.replace))
            }
            .disabled((model.nowPlaying?.id ?? -1) < 0)
            Spacer()
            AirPlayButton().frame(width: 36, height: 36)
            Spacer()
            PlaybackTargetButton()
                .labelStyle(.iconOnly)
                .font(.title3)
            Spacer()
            toggle(.upNext, title: "Up Next", symbol: "list.bullet")
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 24)
    }

    private func toggle(_ kind: NowPlayingPanel, title: String, symbol: String) -> some View {
        Button {
            withAnimation(.smooth) { panel = panel == kind ? nil : kind }
        } label: {
            Label(title, systemImage: symbol)
                .labelStyle(.iconOnly)
                .font(.title3)
                .frame(width: 40, height: 40)
                .background(panel == kind ? AnyShapeStyle(.white.opacity(0.2)) : AnyShapeStyle(.clear), in: .circle)
        }
        .accessibilityAddTraits(panel == kind ? .isSelected : [])
    }
}
