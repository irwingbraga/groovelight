import AVFAudio
import LibraryKit
import MediaPlayer
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
    /// Closes Now Playing (the PC Player's eject key).
    var close: (() -> Void)? = nil
    @AppStorage(NowPlayingSkin.storageKey) private var skin: NowPlayingSkin = .cover
    @AppStorage(NowPlayingSkin.cassetteStorageKey) private var cassette = ""
    @State private var volume = VolumeSender()
    @State private var systemVolume = SystemVolumeControl()

    var body: some View {
        Group {
            // The PC Player has its own heart key; the other players a cap for it at the foot of their panel (the rest of
            // the cover's buttons are in the caps at the top).
            if skin == .pcPlayer {
                deck { EmptyView() }
            } else {
                deck { LoveCap(item: item) }
            }
        }
        // The system's volume slider, out of sight, for the knob to move (and so the volume's own banner stays hidden).
        .background(HiddenVolumeSlider(control: systemVolume).frame(width: 1, height: 1).opacity(0.01).allowsHitTesting(false))
        .transition(.opacity)
    }

    private func deck<Accessory: View>(@ViewBuilder accessory: @escaping () -> Accessory) -> some View {
        let design = model.cassettes.design(id: UUID(uuidString: cassette))
        return SkinDeck(skin: skin,
                        playback: SkinPlayback(title: item.title, artist: item.artist, album: item.album, isPlaying: item.isPlaying,
                                               duration: model.duration, levels: levels, spectrum: spectrum,
                                               format: item.spec.map { SkinFormat(sampleRate: $0.sampleRate, bitDepth: $0.bitDepth,
                                                                                  bitrate: $0.bitrate.map { Int($0.rounded()) }, channels: $0.channels) },
                                               time: { model.time(at: $0) }),
                        controls: controls,
                        cassette: design, cassettePictures: model.cassettes.pictures(of: design), chromeInset: 60,
                        stageOverlay: panel.map { panel in
                            switch panel {
                            case .lyrics: AnyView(LyricsPanel(item: item, fontSize: 22))
                            case .upNext: AnyView(UpNextPanel())
                            }
                        },
                        playlist: skin == .pcPlayer ? playlist : nil) {
            Cover(hash: item.artworkHash, corner: 0, large: true)
        } accessory: {
            accessory()
        }
    }

    private var controls: DeckControls {
        var controls = DeckControls(
            playPause: { model.togglePlayPause() }, previous: { model.previous() }, next: { model.next() },
            seek: { model.seek(to: $0) },
            // The Mac's level while it plays there; this device's own (as its buttons set it) while it plays here.
            volume: model.target == .mac
                ? Binding(get: { volume.value ?? model.remote.state?.volume ?? 1 },
                          set: { value in volume.set(value) { model.remote.send(.volume($0)) } })
                : Binding(get: { systemVolume.value }, set: { systemVolume.set($0) }),
            isShuffled: model.isShuffled, toggleShuffle: { model.toggleShuffle() },
            repeatMode: model.repeatMode == .one ? .one : model.repeatMode == .all ? .all : .off,
            cycleRepeat: { model.cycleRepeat() })
        // The equalizer of this device, while it plays here.
        if !model.isRemote {
            let equalizer = model.player.equalizer
            controls.equalizer = Binding(get: { equalizer.isEnabled }, set: { equalizer.isEnabled = $0 })
        }
        controls.eject = close
        if item.id >= 0 {
            controls.love = Binding(get: { item.isLoved }, set: { _ in model.toggleLove() })
        }
        return controls
    }

    /// The queue for the PC Player's playlist: this device's, or the Mac's while it plays there (a song chosen there
    /// starts the Mac's queue from it).
    private var playlist: SkinPlaylist {
        if model.isRemote {
            let state = model.remote.state
            let ids = state?.queue ?? []
            let tracks = model.library.read { db in try ids.map { try LibraryDatabase.track(db, id: $0) } } ?? []
            let entries = tracks.map { track in
                SkinPlaylist.Entry(title: track?.title ?? "", artist: track?.displayArtist ?? "", duration: track?.duration ?? 0)
            }
            return SkinPlaylist(entries: entries, current: state?.queueIndex) { index in
                model.remote.send(.play(songIds: ids, startAt: index, position: 0, shuffle: false))
            }
        }
        let controller = model.player.controller
        let entries = controller.queue.items.map { SkinPlaylist.Entry(title: $0.title, artist: $0.artist, duration: $0.duration) }
        return SkinPlaylist(entries: entries, current: controller.queue.currentIndex) { controller.jump(toQueueIndex: $0) }
    }

    /// The analyzer's bands while this device plays, for the PC Player's spectrum.
    private var spectrum: ((Date) -> [Float])? {
        guard !model.isRemote else { return nil }
        let analyzer = model.player.controller.analyzer
        return { _ in analyzer.latestFrame.bands }
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

/// Love, on an aluminum cap at the foot of a player's panel.
private struct LoveCap: View {
    @Environment(AppModel.self) private var model
    let item: NowPlayingItem

    var body: some View {
        Button { model.toggleLove() } label: {
            DeckCap {
                Image(systemName: item.isLoved ? "heart.fill" : "heart")
                    .foregroundStyle(item.isLoved ? AnyShapeStyle(Color(red: 0.84, green: 0.15, blue: 0.24)) : AnyShapeStyle(Color.black.opacity(0.65)))
                    .contentTransition(.symbolEffect(.replace))
            }
        }
        .buttonStyle(.plain)
        .disabled(item.id < 0)
        .accessibilityLabel(item.isLoved ? "Unlove" : "Love")
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

/// This device's volume, for the knob: read from the audio session as it changes (the side buttons too), set through the
/// system's volume slider (an app sets the device's volume no other way).
@MainActor @Observable final class SystemVolumeControl {
    private(set) var value = Double(AVAudioSession.sharedInstance().outputVolume)
    @ObservationIgnored weak var slider: UISlider?
    @ObservationIgnored private var observation: NSKeyValueObservation?

    init() {
        observation = AVAudioSession.sharedInstance().observe(\.outputVolume) { [weak self] session, _ in
            let level = Double(session.outputVolume)
            Task { @MainActor in self?.value = level }
        }
    }

    func set(_ level: Double) {
        value = level
        slider?.setValue(Float(level), animated: false)
        slider?.sendActions(for: .valueChanged)
    }
}

private struct HiddenVolumeSlider: UIViewRepresentable {
    let control: SystemVolumeControl

    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: CGRect(x: 0, y: 0, width: 100, height: 30))
        control.slider = view.subviews.compactMap { $0 as? UISlider }.first
        return view
    }

    func updateUIView(_ view: MPVolumeView, context: Context) {
        if control.slider == nil { control.slider = view.subviews.compactMap { $0 as? UISlider }.first }
    }
}

/// Now Playing's menu choosing what shows in the cover's place, the cassette among the user's, and the cassettes to
/// make one.
struct SkinMenu: View {
    @Environment(AppModel.self) private var model
    @Binding var isShowingCassettes: Bool
    @AppStorage(NowPlayingSkin.storageKey) private var skin: NowPlayingSkin = .cover
    @AppStorage(NowPlayingSkin.cassetteStorageKey) private var cassette = ""
    @AppStorage(NowPlayingSkin.pcThemeStorageKey) private var pcTheme: PCTheme = .classic

    var body: some View {
        Menu {
            Picker("Show", selection: Binding(get: { skin }, set: { value in withAnimation(.smooth) { skin = value } })) {
                ForEach(NowPlayingSkin.allCases) { Label($0.displayName, systemImage: $0.systemImage).tag($0) }
            }
            Menu("PC Player Theme") {
                Picker("PC Player Theme", selection: Binding(get: { pcTheme },
                                                             set: { pcTheme = $0; withAnimation(.smooth) { skin = .pcPlayer } })) {
                    ForEach(PCTheme.allCases) { Text($0.displayName).tag($0) }
                }
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
