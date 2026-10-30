import SwiftUI

/// What Now Playing shows in the cover's place: the cover, or one of the vintage players, the cover on them.
public enum NowPlayingSkin: String, CaseIterable, Identifiable, Sendable {
    case cover
    case vinyl
    case cassette
    case compactDisc
    case pcPlayer

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .cover: "Cover"
        case .vinyl: "Vinyl"
        case .cassette: "Cassette"
        case .compactDisc: "CD"
        case .pcPlayer: "PC Player"
        }
    }

    public var systemImage: String {
        switch self {
        case .cover: "photo"
        case .vinyl: "circle.circle"
        case .cassette: "recordingtape"
        case .compactDisc: "opticaldisc"
        case .pcPlayer: "desktopcomputer"
        }
    }

    /// The key the choice is kept under (`@AppStorage`), and the chosen cassette's.
    public static let storageKey = "nowPlaying.skin"
    public static let cassetteStorageKey = "nowPlaying.cassette"
    /// Whether the cassette deck plays the tape's sound while Rewind or Fast Forward is held (on unless turned off).
    public static let tapeCueStorageKey = "nowPlaying.tapeCue"
    /// The PC Player's theme (`PCTheme`).
    public static let pcThemeStorageKey = "nowPlaying.pcTheme"
}


/// A song file's bit rate (kbps), sample rate (kHz) and channels, as the PC Player shows them.
public struct SkinFormat: Sendable, Equatable {
    public var kbps: Int?
    public var kHz: Int?
    public var channels: Int?

    public init(kbps: Int?, kHz: Int?, channels: Int?) {
        self.kbps = kbps
        self.kHz = kHz
        self.channels = channels
    }

    /// From a file's sample rate, bit depth and channels, its bit rate when known (a lossless file's is the PCM rate,
    /// as the classic players show it: 1411 for a CD).
    public init(sampleRate: Double?, bitDepth: Int?, bitrate: Int?, channels: Int?) {
        let pcm = sampleRate.flatMap { rate in bitDepth.map { Int((rate * Double($0) * Double(channels ?? 2) / 1000).rounded()) } }
        kbps = bitrate.map { $0 >= 10_000 ? $0 / 1000 : $0 } ?? pcm
        kHz = sampleRate.map { Int(($0 / 1000).rounded()) }
        self.channels = channels
    }
}

/// The songs in the queue for the PC Player's playlist: each one's title, artist and length, the one playing, and how
/// to play another (nil where it cannot be chosen from here).
public struct SkinPlaylist {
    public struct Entry: Sendable {
        public var title: String
        public var artist: String
        public var duration: TimeInterval

        public init(title: String, artist: String, duration: TimeInterval) {
            self.title = title
            self.artist = artist
            self.duration = duration
        }
    }

    public var entries: [Entry]
    public var current: Int?
    public var play: ((Int) -> Void)?

    public init(entries: [Entry], current: Int?, play: ((Int) -> Void)? = nil) {
        self.entries = entries
        self.current = current
        self.play = play
    }
}

/// What a skin needs of the song: what it is, whether it plays, and where it is (read at each frame).
public struct SkinPlayback {
    public var title: String
    public var artist: String
    public var album: String
    public var isPlaying: Bool
    public var duration: TimeInterval
    public var time: (Date) -> TimeInterval
    /// What is heard now, each channel's RMS (linear, full scale 1), for the VU meters; nil where the music is not
    /// heard through this device (played on another), and the meters swing on their own.
    public var levels: ((Date) -> (left: Float, right: Float))?
    /// What is heard now as the analyzer's bands, low to high (0 to 1), for the PC Player's spectrum; nil where the
    /// music is not heard here, and it dances on its own.
    public var spectrum: ((Date) -> [Float])?
    /// The file's bit rate and sample rate, and whether it is stereo, for the PC Player's display (when known).
    public var format: SkinFormat?

    public init(title: String, artist: String, album: String = "", isPlaying: Bool, duration: TimeInterval,
                levels: ((Date) -> (left: Float, right: Float))? = nil, spectrum: ((Date) -> [Float])? = nil, format: SkinFormat? = nil,
                time: @escaping (Date) -> TimeInterval) {
        self.title = title
        self.artist = artist
        self.album = album
        self.isPlaying = isPlaying
        self.duration = duration
        self.levels = levels
        self.spectrum = spectrum
        self.format = format
        self.time = time
    }

    func progress(at date: Date) -> Double {
        duration > 0 ? min(max(time(date) / duration, 0), 1) : 0
    }
}

/// Only the skin's player, in a square (the turntable, the cassette or the CD, with `artwork` on it), without its
/// panel: for previews. Now Playing shows the whole player, `SkinDeck`.
public struct SkinView<Artwork: View>: View {
    var skin: NowPlayingSkin
    var playback: SkinPlayback
    var cassette: CassetteDesign
    var cassettePictures: CassettePictures
    @ViewBuilder var artwork: () -> Artwork

    public init(skin: NowPlayingSkin, playback: SkinPlayback, cassette: CassetteDesign = .classic,
                cassettePictures: CassettePictures = CassettePictures(), @ViewBuilder artwork: @escaping () -> Artwork) {
        self.skin = skin
        self.playback = playback
        self.cassette = cassette
        self.cassettePictures = cassettePictures
        self.artwork = artwork
    }

    public var body: some View {
        Group {
            switch skin {
            case .cover: artwork()
            case .vinyl: TurntableStage(playback: playback, seek: { _ in }, artwork: artwork).background(Textured(texture: .walnut))
            case .cassette: CassetteStage(design: cassette, pictures: cassettePictures, playback: playback, artwork: artwork)
                .background(Textured(texture: .aluminum, brightness: 0.12))
            case .compactDisc: DiscStage(playback: playback, artwork: artwork).background(Textured(texture: .aluminum, brightness: -0.1, tint: Color(white: 0.3)))
            case .pcPlayer:
                GeometryReader { proxy in
                    let scale = proxy.size.width / PCLayout.mainSize.width
                    PCPlayer(size: CGSize(width: proxy.size.width, height: proxy.size.height), top: 0, fold: nil, playback: playback,
                             controls: .inert, playlist: nil, overlay: nil) { EmptyView() }
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .id(scale)
                }
                .background(Color.clear.overlay(SkinTexture.hill.image.resizable().scaledToFill()).clipped())
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(skin.displayName): \(playback.title)"))
    }
}
