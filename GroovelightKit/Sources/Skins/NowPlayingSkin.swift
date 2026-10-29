import SwiftUI

/// What Now Playing shows in the cover's place: the cover, or one of the vintage players, the cover on them.
public enum NowPlayingSkin: String, CaseIterable, Identifiable, Sendable {
    case cover
    case vinyl
    case cassette
    case compactDisc

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .cover: "Cover"
        case .vinyl: "Vinyl"
        case .cassette: "Cassette"
        case .compactDisc: "CD"
        }
    }

    public var systemImage: String {
        switch self {
        case .cover: "photo"
        case .vinyl: "circle.circle"
        case .cassette: "recordingtape"
        case .compactDisc: "opticaldisc"
        }
    }

    /// The key the choice is kept under (`@AppStorage`), and the chosen cassette's.
    public static let storageKey = "nowPlaying.skin"
    public static let cassetteStorageKey = "nowPlaying.cassette"
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

    public init(title: String, artist: String, album: String = "", isPlaying: Bool, duration: TimeInterval,
                levels: ((Date) -> (left: Float, right: Float))? = nil, time: @escaping (Date) -> TimeInterval) {
        self.title = title
        self.artist = artist
        self.album = album
        self.isPlaying = isPlaying
        self.duration = duration
        self.levels = levels
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
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(skin.displayName): \(playback.title)"))
    }
}
