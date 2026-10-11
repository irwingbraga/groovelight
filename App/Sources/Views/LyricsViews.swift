import LibraryKit
import MetadataKit
import PlayerCore
import SwiftUI

/// Lyrics of the song that is playing, loaded from the library and looked up online when it has none. Used next to the
/// cover in Now Playing and in the side panel.
struct CurrentLyrics: View {
    var fontSize: CGFloat
    @Environment(AppModel.self) private var model
    @State private var track: Track?

    var body: some View {
        let player = model.player
        LyricsPanel(lyrics: track?.id == player.current?.id ? track?.displayLyrics : nil,
                    isSearching: player.current.map { model.metadata.lyricsInFlight.contains($0.id) } ?? false,
                    isFromWeb: track?.lyrics == nil && track?.fetchedLyrics != nil,
                    fontSize: fontSize)
            .task(id: player.current?.id) {
                track = await model.currentTrack()
                // Online lookup when the song has no lyrics yet (also started when the song began playing).
                if let current = track, current.displayLyrics == nil, await model.metadata.ensureLyrics(for: current) {
                    track = await model.currentTrack()
                }
            }
            .onChange(of: player.current.map { model.metadata.lyricsInFlight.contains($0.id) }) { _, searching in
                // The lookup started at playback finished: reload the track to pick up its lyrics.
                if searching == false { Task { track = await model.currentTrack() } }
            }
    }
}

/// Lyrics in the right side panel (like Up Next): the song on top, then its lyrics following playback.
struct LyricsSidePanel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let item = model.player.current {
                HStack(spacing: 10) {
                    ArtworkImage(hash: item.artworkHash, size: .small, cornerRadius: 4)
                        .frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.title).font(.system(size: 13, weight: .semibold))
                        Text(item.artist).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    .lineLimit(1)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                Divider()
                CurrentLyrics(fontSize: 19)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 8)
            } else {
                ContentUnavailableView("Nothing Playing", systemImage: "quote.bubble",
                                       description: Text("Lyrics of the song that is playing show up here."))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// Lyrics text. Synced (LRC) lyrics follow the song: the current line is highlighted and kept in view, and clicking a
/// line seeks there. Plain lyrics scroll freely. Colors follow the environment (white on Now Playing's dark backdrop,
/// the system text color in the side panel).
struct LyricsPanel: View {
    var lyrics: String?
    var isSearching = false
    var isFromWeb = false
    var fontSize: CGFloat = 24

    var body: some View {
        if let lyrics, !lyrics.isEmpty {
            let parsed = SyncedLyrics(parsing: lyrics)
            VStack(alignment: .leading, spacing: 8) {
                if parsed.isSynced {
                    SyncedLyricsView(lyrics: parsed, fontSize: fontSize)
                } else {
                    ScrollView {
                        Text(parsed.plainText)
                            .font(.system(size: fontSize * 0.92, weight: .bold))
                            .lineSpacing(fontSize * 0.42)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 40)
                    }
                    .scrollIndicators(.never)
                    .mask(Self.fade)
                }
                if isFromWeb {
                    Text("Lyrics from LRCLIB")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        } else {
            VStack(spacing: 10) {
                if isSearching {
                    ProgressView().controlSize(.large)
                    Text("Searching for lyrics…")
                        .font(.headline)
                } else {
                    Image(systemName: "quote.bubble")
                        .font(.largeTitle)
                    Text("No lyrics for this song")
                        .font(.headline)
                    Text("Lyrics embedded in your files show up here, and Groovelight looks them up on LRCLIB (Settings, Metadata).")
                        .font(.callout)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    static let fade = LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .white, location: 0.08),
                                             .init(color: .white, location: 0.92), .init(color: .clear, location: 1)],
                                     startPoint: .top, endPoint: .bottom)
}

private struct SyncedLyricsView: View {
    var lyrics: SyncedLyrics
    var fontSize: CGFloat
    @Environment(AppModel.self) private var model

    var body: some View {
        let player = model.player
        // Lines lead the audio slightly so a line lights up as it starts being sung.
        let active = lyrics.lineIndex(at: player.currentTime + 0.25)
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: fontSize * 0.75) {
                    ForEach(Array(lyrics.lines.enumerated()), id: \.offset) { index, line in
                        Text(line.text.isEmpty ? "♪" : line.text)
                            .font(.system(size: fontSize, weight: .bold))
                            .foregroundStyle(Color.primary.opacity(index == active ? 1 : 0.35))
                            .blur(radius: active.map { abs($0 - index) > 3 ? 0.6 : 0 } ?? 0)
                            .scaleEffect(index == active ? 1.03 : 1, anchor: .leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(.rect)
                            .onTapGesture { if let time = line.time { player.seek(to: time) } }
                            .id(index)
                    }
                }
                .padding(.vertical, fontSize * 6)
                .animation(.easeOut(duration: 0.3), value: active)
            }
            .scrollIndicators(.never)
            .mask(LyricsPanel.fade)
            .onChange(of: active, initial: true) { _, index in
                guard let index else { return }
                withAnimation(.smooth(duration: 0.6)) { proxy.scrollTo(index, anchor: UnitPoint(x: 0, y: 0.35)) }
            }
        }
    }
}
