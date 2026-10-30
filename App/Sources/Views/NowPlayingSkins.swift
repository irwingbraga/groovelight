import AppKit
import LibraryKit
import PlayerCore
import Skins
import SwiftUI

/// The cover in Now Playing (the turntable, cassette deck and CD player take the whole of it: `NowPlayingDeck`).
struct NowPlayingArtwork: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let player = model.player
        ArtworkImage(hash: player.current?.artworkHash, size: .large, cornerRadius: 14)
            .scaleEffect(player.state == .playing ? 1 : 0.92)
            .animation(.spring(duration: 0.5, bounce: 0.25), value: player.state)
            .shadow(color: .black.opacity(0.45), radius: 30, y: 18)
    }
}

/// Now Playing as the vintage player chosen: the whole window is the turntable, the cassette deck or the CD player,
/// their keys, knobs and switches working the player, the lyrics behind smoked glass in the player's place.
struct NowPlayingDeck: View {
    @Environment(AppModel.self) private var model
    @AppStorage(NowPlayingSkin.storageKey) private var skin: NowPlayingSkin = .cover
    @AppStorage(NowPlayingSkin.cassetteStorageKey) private var cassette = ""
    var chromeInset: CGFloat
    /// The song's file, for the PC Player's bit rate and sample rate.
    @State private var track: Track?

    var body: some View {
        let player = model.player
        let design = model.cassettes.design(id: UUID(uuidString: cassette))
        SkinDeck(skin: skin,
                 playback: SkinPlayback(title: player.current?.title ?? "Not Playing", artist: player.current?.artist ?? "",
                                        album: player.current?.album ?? "", isPlaying: player.state == .playing, duration: player.duration,
                                        levels: { _ in
                                            let frame = player.analyzer.latestFrame
                                            return (frame.leftLevel, frame.rightLevel)
                                        },
                                        spectrum: { _ in player.analyzer.latestFrame.bands },
                                        format: track.map { track in
                                            let spec = track.audioSpec
                                            return SkinFormat(sampleRate: spec.sampleRate, bitDepth: spec.bitDepth,
                                                              bitrate: spec.bitrate.map { Int($0.rounded()) }, channels: spec.channels)
                                        },
                                        time: { player.estimatedTime(at: $0) }),
                 controls: controls,
                 cassette: design, cassettePictures: model.cassettes.pictures(of: design), chromeInset: chromeInset,
                 stageOverlay: stageOverlay,
                 playlist: skin == .pcPlayer ? playlist : nil) {
            ArtworkImage(hash: player.current?.artworkHash, size: .large, cornerRadius: 0)
        } accessory: {
            // The PC Player has its own heart key; the other players a cap for it at the foot of their panel.
            if skin != .pcPlayer {
                LoveCap(track: track) { refresh in
                    model.toggleLoved(refresh)
                    Task { track = await model.currentTrack() }
                }
            }
        }
        .task(id: player.current?.id) { track = await model.currentTrack() }
        .transition(.opacity)
    }

    /// The lyrics or Up Next behind smoked glass in the player's place (the PC Player's playlist shows the queue).
    private var stageOverlay: AnyView? {
        if model.isShowingLyrics { return AnyView(CurrentLyrics(fontSize: 22)) }
        if model.isShowingNowPlayingQueue, skin != .pcPlayer {
            return AnyView(QueueView().scrollContentBackground(.hidden).environment(\.colorScheme, .dark))
        }
        return nil
    }

    private var controls: DeckControls {
        let player = model.player
        var controls = DeckControls(
            playPause: { player.togglePlayPause() }, previous: { player.previous() }, next: { player.next() },
            seek: { player.seek(to: $0) },
            volume: Binding(get: { Double(player.volume) }, set: { player.volume = Float($0) }),
            isShuffled: player.isShuffled, toggleShuffle: { player.setShuffle(!player.isShuffled) },
            repeatMode: player.repeatMode == .one ? .one : player.repeatMode == .all ? .all : .off,
            cycleRepeat: {
                player.repeatMode = switch player.repeatMode {
                case .off: .all
                case .all: .one
                case .one: .off
                }
            })
        let equalizer = model.equalizer
        controls.equalizer = Binding(get: { equalizer.isEnabled }, set: { equalizer.isEnabled = $0 })
        controls.eject = { withAnimation(.smooth) { model.isShowingNowPlaying = false } }
        if let current = track {
            controls.love = Binding(get: { current.isLoved }, set: { _ in
                model.toggleLoved(current)
                Task { track = await model.currentTrack() }
            })
        }
        return controls
    }

    /// The queue for the PC Player's playlist, a song in it played when chosen.
    private var playlist: SkinPlaylist {
        let player = model.player
        let entries = player.queue.items.map { SkinPlaylist.Entry(title: $0.title, artist: $0.artist, duration: $0.duration) }
        return SkinPlaylist(entries: entries, current: player.queue.currentIndex) { player.jump(toQueueIndex: $0) }
    }
}

/// Now Playing's button choosing what shows in the cover's place, the cassette among the user's, and opening the
/// Cassettes window to make one.
struct SkinMenu: View {
    @Environment(AppModel.self) private var model
    /// Over a player: an aluminum cap, as the other buttons there.
    var isDeck = false
    @Environment(\.openWindow) private var openWindow
    @AppStorage(NowPlayingSkin.storageKey) private var skin: NowPlayingSkin = .cover
    @AppStorage(NowPlayingSkin.cassetteStorageKey) private var cassette = ""
    @AppStorage(NowPlayingSkin.pcThemeStorageKey) private var pcTheme: PCTheme = .classic

    var body: some View {
        Menu {
            Picker("Show", selection: Binding(get: { skin }, set: { value in withAnimation(.smooth) { skin = value } })) {
                ForEach(NowPlayingSkin.allCases) { Label($0.displayName, systemImage: $0.systemImage).tag($0) }
            }
            .pickerStyle(.inline)
            Picker("PC Player Theme", selection: Binding(get: { pcTheme }, set: { pcTheme = $0; withAnimation(.smooth) { skin = .pcPlayer } })) {
                ForEach(PCTheme.allCases) { Text($0.displayName).tag($0) }
            }
            Divider()
            Picker("Cassette", selection: Binding(get: { model.cassettes.design(id: UUID(uuidString: cassette)).id.uuidString },
                                                  set: { cassette = $0; withAnimation(.smooth) { skin = .cassette } })) {
                ForEach(model.cassettes.all) { Text($0.name).tag($0.id.uuidString) }
            }
            Divider()
            Button("Cassettes…") { openWindow(id: WindowID.cassettes) }
        } label: {
            if isDeck {
                DeckCap { Image(systemName: skin.systemImage) }
            } else {
                Image(systemName: skin.systemImage).frame(width: 20, height: 20)
            }
        }
        .menuIndicator(.hidden)
        .help("Cover, Vinyl, Cassette, CD or PC Player")
    }
}

/// Love, on an aluminum cap at the foot of a player's panel.
private struct LoveCap: View {
    @Environment(AppModel.self) private var model
    var track: Track?
    var toggle: (Track) -> Void

    var body: some View {
        let isLoved = track?.isLoved == true
        Button { if let track { toggle(track) } } label: {
            DeckCap {
                Image(systemName: isLoved ? "heart.fill" : "heart")
                    .foregroundStyle(isLoved ? AnyShapeStyle(Color(red: 0.84, green: 0.15, blue: 0.24)) : AnyShapeStyle(Color.black.opacity(0.65)))
                    .contentTransition(.symbolEffect(.replace))
            }
        }
        .buttonStyle(.plain)
        .disabled(track == nil)
        .help((isLoved ? "Unlove" : "Love") + model.shortcuts.hint(.love))
    }
}

/// The user's cassettes: choose one, make one, import or share one.
struct CassettesWindow: View {
    @Environment(AppModel.self) private var model
    @AppStorage(NowPlayingSkin.cassetteStorageKey) private var cassette = ""

    var body: some View {
        CassetteLibrary(store: model.cassettes, selection: $cassette)
            .frame(minWidth: 360, minHeight: 420)
    }
}

extension AppModel {
    /// A `.cassette` opened with the app (Finder, Open With): added, chosen and shown in Now Playing.
    func openCassette(_ url: URL) {
        do {
            let design = try cassettes.importDesign(from: url)
            UserDefaults.standard.set(design.id.uuidString, forKey: NowPlayingSkin.cassetteStorageKey)
            UserDefaults.standard.set(NowPlayingSkin.cassette.rawValue, forKey: NowPlayingSkin.storageKey)
            NSApp.activate()
            isShowingNowPlaying = true
        } catch {
            NSApp.activate()
            NSAlert(error: error).runModal()
        }
    }
}

/// Now Playing's buttons at the top right: clear glass over the cover, aluminum caps over a player.
struct NowPlayingButtonsStyle: ViewModifier {
    var isDeck: Bool

    func body(content: Content) -> some View {
        if isDeck {
            content
                .buttonStyle(DeckChromeButtonStyle())
                .menuStyle(.button)
        } else {
            // Clear glass and white icons, like the rest of Now Playing. Glass buttons color the glass with the tint (the
            // app's navy), so the tint is cleared here.
            content
                .clearGlassButtonStyle()
                .tint(.clear)
                .foregroundStyle(.white)
        }
    }
}
