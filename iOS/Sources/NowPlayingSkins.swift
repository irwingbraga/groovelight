import Skins
import SwiftUI

/// The cover in Now Playing, smaller while paused (the turntable, cassette deck and CD player take the whole of Now
/// Playing: `NowPlayingDeck`).
struct NowPlayingArtwork: View {
    let item: NowPlayingItem

    var body: some View {
        Cover(hash: item.artworkHash, corner: 14, large: true)
            .scaleEffect(item.isPlaying ? 1 : 0.92)
            .animation(.spring(duration: 0.5, bounce: 0.25), value: item.isPlaying)
    }
}

/// Now Playing as the vintage player chosen, filling the screen (and parting at the iPhone Duo's fold): its keys, knobs
/// and switches work the player, the lyrics or Up Next show behind smoked glass in the player's place, and this
/// device's buttons (love, AirPlay, Play On, Up Next) sit at the foot of its panel.
struct NowPlayingDeck: View {
    @Environment(AppModel.self) private var model
    let item: NowPlayingItem
    @Binding var panel: NowPlayingPanel?
    @AppStorage(NowPlayingSkin.storageKey) private var skin: NowPlayingSkin = .cover
    @AppStorage(NowPlayingSkin.cassetteStorageKey) private var cassette = ""
    @State private var volume = VolumeSender()

    var body: some View {
        let design = model.cassettes.design(id: UUID(uuidString: cassette))
        SkinDeck(skin: skin,
                 playback: SkinPlayback(title: item.title, artist: item.artist, album: item.album, isPlaying: item.isPlaying,
                                        duration: model.duration, levels: levels, time: { model.time(at: $0) }),
                 controls: DeckControls(
                    playPause: { model.togglePlayPause() }, previous: { model.previous() }, next: { model.next() },
                    seek: { model.seek(to: $0) },
                    // The Mac's level while it plays there; this device's own buttons set its level.
                    volume: model.target == .mac ? Binding(get: { volume.value ?? model.remote.state?.volume ?? 1 },
                                                           set: { value in volume.set(value) { model.remote.send(.volume($0)) } }) : nil,
                    isShuffled: model.isShuffled, toggleShuffle: { model.toggleShuffle() },
                    repeatMode: model.repeatMode == .one ? .one : model.repeatMode == .all ? .all : .off,
                    cycleRepeat: { model.cycleRepeat() }),
                 cassette: design, cassettePictures: model.cassettes.pictures(of: design), chromeInset: 60,
                 stageOverlay: panel.map { panel in
                     switch panel {
                     case .lyrics: AnyView(LyricsPanel(item: item, fontSize: 22))
                     case .upNext: AnyView(UpNextPanel())
                     }
                 }) {
            Cover(hash: item.artworkHash, corner: 0, large: true)
        } accessory: {
            NowPlayingButtons(panel: $panel)
                .foregroundStyle(.white)
                .padding(.vertical, 2)
                .background(Capsule().fill(Color.black.opacity(0.8)).overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 1)))
                .environment(\.colorScheme, .dark)
        }
        .transition(.opacity)
    }

    /// What this device plays, heard through it: the meters follow it. Played elsewhere, they swing on their own.
    private var levels: ((Date) -> (left: Float, right: Float))? {
        guard !model.isRemote else { return nil }
        let analyzer = model.player.controller.analyzer
        return { _ in
            let frame = analyzer.latestFrame
            return (frame.leftLevel, frame.rightLevel)
        }
    }
}

/// The Mac's level as a knob turns it: sent a few times a second, the last one always.
@MainActor @Observable final class VolumeSender {
    private(set) var value: Double?
    @ObservationIgnored private var sending: Task<Void, Never>?

    func set(_ value: Double, send: @escaping (Double) -> Void) {
        self.value = value
        guard sending == nil else { return }
        send(value)
        sending = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            if let latest = self.value, latest != value { send(latest) }
            self.sending = nil
            try? await Task.sleep(for: .seconds(1))
            // By now the Mac has said where it is.
            if self.sending == nil { self.value = nil }
        }
    }
}

/// Now Playing's menu choosing what shows in the cover's place, the cassette among the user's, and the cassettes to
/// make one.
struct SkinMenu: View {
    @Environment(AppModel.self) private var model
    @Binding var isShowingCassettes: Bool
    @AppStorage(NowPlayingSkin.storageKey) private var skin: NowPlayingSkin = .cover
    @AppStorage(NowPlayingSkin.cassetteStorageKey) private var cassette = ""

    var body: some View {
        Menu {
            Picker("Show", selection: Binding(get: { skin }, set: { value in withAnimation(.smooth) { skin = value } })) {
                ForEach(NowPlayingSkin.allCases) { Label($0.displayName, systemImage: $0.systemImage).tag($0) }
            }
            Menu("Cassette") {
                Picker("Cassette", selection: Binding(get: { model.cassettes.design(id: UUID(uuidString: cassette)).id.uuidString },
                                                      set: { cassette = $0; withAnimation(.smooth) { skin = .cassette } })) {
                    ForEach(model.cassettes.all) { Text($0.name).tag($0.id.uuidString) }
                }
                Divider()
                Button("Cassettes…", systemImage: "recordingtape") { isShowingCassettes = true }
            }
        } label: {
            Label("Look", systemImage: skin.systemImage)
        }
    }
}

/// The user's cassettes, in a sheet: choose one, make one, import or share one.
struct CassettesSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @AppStorage(NowPlayingSkin.cassetteStorageKey) private var cassette = ""

    var body: some View {
        NavigationStack {
            CassetteLibrary(store: model.cassettes, selection: $cassette)
                .navigationTitle("Cassettes")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

extension AppModel {
    /// A `.cassette` opened with the app (Files, Mail, AirDrop): added, chosen and shown in Now Playing.
    func openCassette(_ url: URL) {
        guard let design = try? cassettes.importDesign(from: url) else { return }
        UserDefaults.standard.set(design.id.uuidString, forKey: NowPlayingSkin.cassetteStorageKey)
        UserDefaults.standard.set(NowPlayingSkin.cassette.rawValue, forKey: NowPlayingSkin.storageKey)
        if nowPlaying != nil { activeWindow?.isShowingNowPlaying = true }
    }
}
