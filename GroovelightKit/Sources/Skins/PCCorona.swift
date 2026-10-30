import SwiftUI

// MARK: - PC Player, Corona theme

/// The PC Player's themes: the classic two-window skin of the late 1990s, or Corona, the glassy blue media player of
/// 2002 (a screen in a periwinkle frame, the transport drawer under it, the playlist drawer beside it).
public enum PCTheme: String, CaseIterable, Identifiable, Sendable {
    case classic
    case corona

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .classic: "Classic"
        case .corona: "Corona"
        }
    }
}

/// Where Corona's parts go, in its own pixels (the main window 346 wide), and the scale they are drawn at: the main
/// window (its screen as tall as the room allows, down to 120 pixels) with the transport drawer under it, and the
/// playlist drawer beside it on a wide screen (on its left, as it slid out) or under it on a tall one, or across a fold.
struct CoronaLayout {
    var main: CGRect
    var playlist: CGRect
    var scale: CGFloat
    /// The screen's height, in the skin's pixels.
    var screenHeight: CGFloat

    static let width: CGFloat = 346
    /// The main window and the drawer around the screen: 26 above it, 19 under it (the metadata strip and the frame),
    /// then the drawer (60, its first pixel behind the window).
    static let chrome: CGFloat = 26 + 19 + 59
    static let playlistWidth: CGFloat = 263

    init(size: CGSize, top: CGFloat, fold: CGRect?) {
        let margin = max(8, min(size.width, size.height) * 0.02)
        let area = CGRect(x: margin, y: top, width: max(size.width - margin * 2, 1), height: max(size.height - top - margin, 1))
        let side = fold.map { $0.height >= size.height * 0.5 && $0.minX > area.minX + 120 && $0.maxX < area.maxX - 120 } ?? false
        let level = fold.map { $0.width >= size.width * 0.5 && $0.minY > area.minY + 120 && $0.maxY < area.maxY - 120 } ?? false
        if let fold, side {
            // The playlist left of an upright fold, the player right of it.
            let right = CGRect(x: fold.maxX + margin, y: area.minY, width: area.maxX - fold.maxX - margin, height: area.height)
            scale = min(right.width / Self.width, 3)
            screenHeight = min(240, max(120, right.height / scale - Self.chrome))
            main = CGRect(x: right.minX, y: right.minY, width: Self.width * scale, height: (screenHeight + Self.chrome) * scale)
            playlist = CGRect(x: area.minX, y: area.minY, width: fold.minX - margin - area.minX, height: area.height)
        } else if let fold, level {
            let upper = fold.minY - margin - area.minY
            scale = min(area.width / Self.width, 3)
            screenHeight = min(240, max(120, upper / scale - Self.chrome))
            main = CGRect(x: area.midX - Self.width * scale / 2, y: area.minY, width: Self.width * scale, height: (screenHeight + Self.chrome) * scale)
            playlist = CGRect(x: main.minX, y: fold.maxY + margin, width: main.width, height: area.maxY - fold.maxY - margin)
        } else if area.width >= area.height * 1.25 {
            // Wide: the playlist slid out on the player's left, as in the original.
            let total = Self.width + Self.playlistWidth - 13
            scale = min(area.width / total, area.height / (240 + Self.chrome), 3)
            screenHeight = min(240, max(120, area.height / scale - Self.chrome))
            let width = total * scale
            let left = area.midX - width / 2
            main = CGRect(x: left + (Self.playlistWidth - 13) * scale, y: area.minY, width: Self.width * scale, height: (screenHeight + Self.chrome) * scale)
            // From under the top bar down to the window's foot piece, as the original's.
            playlist = CGRect(x: left, y: main.minY + 33 * scale, width: Self.playlistWidth * scale, height: (screenHeight - 3) * scale)
        } else {
            // Tall: the playlist under the player, the screen giving it room.
            scale = min(area.width / Self.width, 3)
            screenHeight = min(240, max(120, (area.height * 0.5) / scale - Self.chrome))
            main = CGRect(x: area.midX - Self.width * scale / 2, y: area.minY, width: Self.width * scale, height: (screenHeight + Self.chrome) * scale)
            playlist = CGRect(x: main.minX, y: main.maxY + 4 * scale, width: main.width, height: max(area.maxY - main.maxY - 4 * scale, 80))
        }
    }
}

/// Corona's colors, as its bitmaps have them.
enum CoronaColors {
    static let frame = Color(hex: 0xC0D3EA)
    static let frameLight = Color(hex: 0xE7EEF8)
    static let frameEdge = Color(hex: 0xA1B5D5)
    static let frameShade = Color(hex: 0x93A0C1)
    static let frameDark = Color(hex: 0x60647F)
    static let tube = [Color(hex: 0xB7CBEA), Color(hex: 0x94AAD9), Color(hex: 0x7D94CC), Color(hex: 0x6577B9), Color(hex: 0x505FA6), Color(hex: 0x44549C)]
    static let navy = Color(hex: 0x202852)
    static let glyph = [Color(hex: 0x182B3C), Color(hex: 0x33597C), Color(hex: 0x4D7BA2)]
    static let green = Color(hex: 0x00FF00)
    static let seek = [Color(hex: 0x779C8C), Color(hex: 0x8EB599), Color(hex: 0xA0C8A1), Color(hex: 0xBBDEAE)]
    static let thumbGreen = [Color(hex: 0x1CE249), Color(hex: 0x53D324), Color(hex: 0x28A949)]
    static let block = [Color(hex: 0xA6B9DE), Color(hex: 0x8AA3CC), Color(hex: 0x8396BB)]
}

struct CoronaPlayer: View {
    var size: CGSize
    var top: CGFloat
    var fold: CGRect?
    var playback: SkinPlayback
    var controls: DeckControls
    var playlist: SkinPlaylist?
    var overlay: AnyView?
    var artwork: AnyView
    @Binding var showsPlaylist: Bool

    var body: some View {
        let layout = CoronaLayout(size: size, top: top, fold: fold)
        let beside = layout.playlist.maxX <= layout.main.minX + 20 * layout.scale
        // On a wide screen (not across a fold) the window sits centered while the playlist is closed; opening it, the
        // window and the drawer slide apart, together centered.
        let shift = beside && fold == nil && !showsPlaylist ? (layout.playlist.width - 13 * layout.scale) / 2 : 0
        ZStack(alignment: .topLeading) {
            // The playlist drawer slides out: from behind the window to its left (as the original), or down from under it.
            CoronaPlaylist(scale: layout.scale, size: layout.playlist.size, playback: playback, controls: controls, playlist: playlist,
                           overlay: overlay, showsPlaylist: $showsPlaylist)
                .frame(width: layout.playlist.width, height: layout.playlist.height)
                .offset(x: beside && !showsPlaylist ? layout.main.minX - shift - layout.playlist.minX : 0,
                        y: !beside && !showsPlaylist ? -layout.playlist.height : 0)
                .frame(width: layout.playlist.width, height: layout.playlist.height, alignment: .topLeading)
                .clipped(antialiased: false)
                .allowsHitTesting(showsPlaylist)
                .offset(x: layout.playlist.minX, y: layout.playlist.minY)
            CoronaMain(scale: layout.scale, screenHeight: layout.screenHeight, playback: playback, controls: controls, artwork: artwork,
                       showsPlaylist: $showsPlaylist, showsHandle: !(beside && showsPlaylist))
                .frame(width: layout.main.width, height: layout.main.height)
                .offset(x: layout.main.minX - shift, y: layout.main.minY)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .animation(.easeInOut(duration: 0.35), value: showsPlaylist)
    }
}

/// A glossy round key: a silver rim, a pale face lit from above and bluer below, its glyph in navy; held, it sinks.
private struct CoronaRoundKey<Glyph: View>: View {
    var title: String
    var scale: CGFloat
    var diameter: CGFloat
    var isEnabled = true
    var tap: () -> Void
    var hold: (() -> Void)? = nil
    @ViewBuilder var glyph: () -> Glyph

    var body: some View {
        DeckPress(title: title, tap: isEnabled ? tap : {}, hold: isEnabled ? hold : nil) { pressed in
            ZStack {
                Circle().fill(LinearGradient(colors: [Color(hex: 0xB0B3BA), Color(hex: 0x607279)], startPoint: .top, endPoint: .bottom))
                Circle().fill(LinearGradient(colors: [.white, Color(hex: 0xF6F7FA), Color(hex: 0xA9ABB0)], startPoint: .top, endPoint: .bottom))
                    .padding(scale * 0.8)
                Circle().fill(LinearGradient(stops: [.init(color: pressed ? Color(hex: 0xB9CBE4) : .white, location: 0),
                                                     .init(color: pressed ? Color(hex: 0xA9C0DD) : Color(hex: 0xD5DCEF), location: 0.45),
                                                     .init(color: pressed ? Color(hex: 0x9DB8D6) : Color(hex: 0xC3E0F2), location: 1)],
                                             startPoint: .top, endPoint: .bottom))
                    .padding(scale * (diameter > 26 ? 3 : 2.2))
                Circle().strokeBorder(Color(hex: 0x5D686F).opacity(0.55), lineWidth: max(0.5, scale * 0.6))
                    .padding(scale * (diameter > 26 ? 3 : 2.2))
                glyph()
                    .opacity(isEnabled ? 1 : 0.4)
                    .offset(y: pressed ? scale * 0.5 : 0)
            }
            .frame(width: diameter * scale, height: diameter * scale)
            .shadow(color: .black.opacity(0.25), radius: scale, y: scale * 0.6)
        }
    }
}

/// A transport glyph in Corona's navy, darker at the top.
private func coronaGlyph(_ kind: PCGlyph.Kind, _ scale: CGFloat, width: CGFloat, height: CGFloat) -> some View {
    PCGlyph(kind: kind)
        .fill(LinearGradient(colors: CoronaColors.glyph, startPoint: .top, endPoint: .bottom))
        .frame(width: width * scale, height: height * scale)
}

/// The screen's pictures, cycled by the visualization key: bars of the spectrum, or the album's cover.
enum CoronaVisualization: Int, CaseIterable {
    case bars, albumArt
}

// MARK: Main window and transport drawer

private struct CoronaMain: View {
    var scale: CGFloat
    var screenHeight: CGFloat
    var playback: SkinPlayback
    var controls: DeckControls
    var artwork: AnyView
    @Binding var showsPlaylist: Bool
    /// The playlist drawer's edge down the window's left side (where it is not slid out beside it): its blue tube with
    /// the grip that slides it out.
    var showsHandle = true
    @AppStorage("nowPlaying.coronaVisualization") private var visualization = CoronaVisualization.bars.rawValue
    @State private var mutedVolume: Double?

    var body: some View {
        let s = scale
        let screenBottom = 26 + screenHeight
        let drawerTop = screenBottom + 18
        ZStack(alignment: .topLeading) {
            // The transport drawer, flowing on from the window: the same edges, the seek row on the frame's periwinkle,
            // then the glossy tray (outlined on its sides and foot only, so it is one piece with the window).
            CoronaDrawerShape()
                .fill(LinearGradient(stops: [.init(color: CoronaColors.frame, location: 0), .init(color: Color(hex: 0xD3E0F1), location: 0.2),
                                             .init(color: .white, location: 0.27), .init(color: Color(hex: 0xF1F3FA), location: 0.42),
                                             .init(color: Color(hex: 0xE5EAF5), location: 0.55), .init(color: Color(hex: 0xF4F6FB), location: 0.66),
                                             .init(color: Color(hex: 0xD5DCEF), location: 0.86), .init(color: Color(hex: 0xB6C2D9), location: 1)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(CoronaDrawerShape(open: true).stroke(Color(hex: 0x646871), lineWidth: max(0.6, s * 0.8)))
                .frame(width: 333 * s, height: 60 * s)
                .offset(x: 13 * s, y: drawerTop * s)
            // The blue block at the drawer's lower right, with Groovelight's mark and the (decorative) view keys.
            CoronaBlockShape()
                .fill(LinearGradient(colors: CoronaColors.block, startPoint: .top, endPoint: .bottom))
                .overlay(CoronaBlockShape(edgeOnly: true).stroke(Color(hex: 0x6D7285), lineWidth: max(0.5, s * 0.6)))
                .frame(width: 333 * s, height: 60 * s)
                .offset(x: 13 * s, y: drawerTop * s)
            CoronaNote()
                .frame(width: 13 * s, height: 13 * s)
                .offset(x: (12 + 260) * s, y: (drawerTop + 21) * s)
            Image(systemName: "rectangle.dashed")
                .font(.system(size: 9 * s, weight: .medium)).foregroundStyle(.white.opacity(0.95))
                .offset(x: (12 + 283) * s, y: (drawerTop + 21) * s)
                .accessibilityHidden(true)
            Image(systemName: "arrow.down.right.and.arrow.up.left")
                .font(.system(size: 8 * s, weight: .medium)).foregroundStyle(.white.opacity(0.95))
                .offset(x: (12 + 302) * s, y: (drawerTop + 22) * s)
                .accessibilityHidden(true)
            Canvas { context, _ in
                for row in 0..<3 {
                    for column in 0..<(3 - row) {
                        let x = (12 + 326 - CGFloat(column) * 3) * s, y = (drawerTop + 35.5 - CGFloat(row) * 3) * s
                        context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 1.6 * s, height: 1.6 * s)), with: .color(.white.opacity(0.7)))
                    }
                }
            }
            .frame(width: 346 * s, height: (drawerTop + 60) * s)
            .allowsHitTesting(false)
            // The seek row: rewind, the track with its thumb, fast forward.
            CoronaSeekBar(playback: playback, seek: controls.seek, scale: s)
                // Between the seek keys: the thumb never goes under them.
                .frame(width: 249 * s, height: 13 * s)
                .offset(x: (12 + 42) * s, y: (drawerTop + 1) * s)
            CoronaSeekKey(title: "Rewind", scale: s, pointsRight: false, tap: { scan(-1)() }, hold: scan(-1))
                .frame(width: 35 * s, height: 13 * s)
                .offset(x: (12 + 6) * s, y: (drawerTop + 1) * s)
            CoronaSeekKey(title: "Fast Forward", scale: s, pointsRight: true, tap: { scan(1)() }, hold: scan(1))
                .frame(width: 35 * s, height: 13 * s)
                .offset(x: (12 + 291) * s, y: (drawerTop + 1) * s)
            // The transport keys: play (pause while playing) large, stop, previous and next joined, mute.
            Capsule().fill(LinearGradient(colors: [Color(hex: 0xEAF0F8), Color(hex: 0xC4CCDD)], startPoint: .top, endPoint: .bottom))
                .overlay(Capsule().stroke(Color(hex: 0x9297A5).opacity(0.7), lineWidth: max(0.5, s * 0.5)))
                .frame(width: 45 * s, height: 22 * s)
                .offset(x: (12 + 66) * s, y: (drawerTop + 24) * s)
            CoronaRoundKey(title: playback.isPlaying ? "Pause" : "Play", scale: s, diameter: 30, tap: controls.playPause) {
                if playback.isPlaying {
                    coronaGlyph(.pause, s, width: 9, height: 10)
                } else {
                    coronaGlyph(.play, s, width: 10, height: 12).offset(x: s)
                }
            }
            .offset(x: (12 + 8) * s, y: (drawerTop + 20) * s)
            CoronaRoundKey(title: "Stop", scale: s, diameter: 22, tap: {
                if playback.isPlaying { controls.playPause() }
                controls.seek(0)
            }) {
                coronaGlyph(.stop, s, width: 6.5, height: 6.5)
            }
            .offset(x: (12 + 42) * s, y: (drawerTop + 24) * s)
            CoronaRoundKey(title: "Previous", scale: s, diameter: 22, tap: controls.previous, hold: scan(-1)) {
                coronaGlyph(.previous, s, width: 7.5, height: 7.5)
            }
            .offset(x: (12 + 66) * s, y: (drawerTop + 24) * s)
            CoronaRoundKey(title: "Next", scale: s, diameter: 22, tap: controls.next, hold: scan(1)) {
                coronaGlyph(.next, s, width: 7.5, height: 7.5)
            }
            .offset(x: (12 + 89) * s, y: (drawerTop + 24) * s)
            CoronaRoundKey(title: mutedVolume == nil ? "Mute" : "Sound", scale: s, diameter: 22, isEnabled: controls.volume != nil, tap: toggleMute) {
                Image(systemName: mutedVolume == nil ? "speaker.wave.1.fill" : "speaker.slash.fill")
                    .font(.system(size: 8 * s, weight: .bold))
                    .foregroundStyle(LinearGradient(colors: CoronaColors.glyph, startPoint: .top, endPoint: .bottom))
            }
            .offset(x: (12 + 116) * s, y: (drawerTop + 24) * s)
            CoronaVolume(value: controls.volume ?? .constant(1), scale: s)
                .disabled(controls.volume == nil)
                .frame(width: 70 * s, height: 18 * s)
                .offset(x: (12 + 146) * s, y: (drawerTop + 25) * s)
            // The window: the blue tube along the top left and the bottom left, the periwinkle frame.
            // The bent tube: the window's top piece (around the corner, down to under the top bar) and its foot (with the
            // diagonal cut), and between them the playlist drawer's piece while the drawer is behind the window.
            CoronaEdge(length: screenBottom + 12, gap: showsHandle ? nil : 33...(screenBottom + 4))
                .frame(width: 130 * s, height: (screenBottom + 19) * s)
            if showsHandle {
                CoronaGrip(scale: s)
                    .offset(x: 3.5 * s, y: (26 + screenHeight / 2 - 14) * s)
                Color.clear
                    .frame(width: 13 * s, height: screenHeight * s)
                    .contentShape(.rect)
                    .offset(x: 0, y: 26 * s)
                    .onTapGesture { showsPlaylist.toggle() }
                    .accessibilityElement()
                    .accessibilityLabel(showsPlaylist ? "Hide Playlist" : "Show Playlist")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { showsPlaylist.toggle() }
            }
            CoronaFrameShape(screenHeight: screenHeight)
                .fill(LinearGradient(stops: [.init(color: .white, location: 0), .init(color: Color(hex: 0xDFE8F4), location: 0.01),
                                             .init(color: CoronaColors.frame, location: 0.06), .init(color: CoronaColors.frame, location: 1)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(CoronaFrameShape(screenHeight: screenHeight, open: true).stroke(CoronaColors.frameDark, lineWidth: max(0.6, s * 0.8)))
                .frame(width: 346 * s, height: (screenBottom + 19) * s)
            // The frame's lit edge along the left and its shaded edges around the screen.
            Rectangle().fill(Color(hex: 0xFAFDFF)).frame(width: s, height: (screenHeight + 6) * s).offset(x: 13 * s, y: 22 * s)
            // The screen: the spectrum or the cover.
            ZStack {
                Color.black
                switch CoronaVisualization(rawValue: visualization) ?? .bars {
                case .bars:
                    CoronaBars(playback: playback, scale: s)
                case .albumArt:
                    artwork
                        .aspectRatio(1, contentMode: .fit)
                        .frame(maxHeight: screenHeight * 0.78 * s)
                        .clipped()
                }
            }
            .frame(width: 320 * s, height: screenHeight * s)
            .clipped()
            .overlay(Rectangle().strokeBorder(CoronaColors.frameDark, lineWidth: max(0.6, s * 0.8)).padding(-s * 0.6))
            .offset(x: 19 * s, y: 26 * s)
            .contentShape(.rect)
            .onTapGesture { nextVisualization() }
            .accessibilityElement()
            .accessibilityLabel("Visualization")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { nextVisualization() }
            // The metadata strip: the song's details in turn, the time on the right.
            CoronaMetadata(playback: playback, scale: s)
                .frame(width: 320 * s, height: 15 * s)
                .offset(x: 19 * s, y: (screenBottom + 1) * s)
            // The top bar's keys: open (leaves Now Playing), the playlist, the next visualization, the equalizer; minimize
            // (for the look) and close (leaves Now Playing).
            topKey("Close Now Playing", "folder", x: 117, isEnabled: controls.eject != nil) { controls.eject?() }
            Rectangle().fill(Color(hex: 0xA1B5D5)).frame(width: s, height: 15 * s).offset(x: 138 * s, y: 5 * s)
            Rectangle().fill(Color.white).frame(width: s, height: 15 * s).offset(x: 139 * s, y: 5 * s)
            topKey(showsPlaylist ? "Hide Playlist" : "Show Playlist", "list.bullet", x: 144, isOn: showsPlaylist) { showsPlaylist.toggle() }
            topKey("Next Visualization", "asterisk", x: 167) { nextVisualization() }
            topKey("Equalizer", "chart.bar.fill", x: 190, isOn: controls.equalizer?.wrappedValue ?? false, isEnabled: controls.equalizer != nil) {
                controls.equalizer?.wrappedValue.toggle()
            }
            Rectangle().fill(Color(hex: 0xA1B5D5)).frame(width: s, height: 15 * s).offset(x: 302 * s, y: 5 * s)
            Rectangle().fill(Color.white).frame(width: s, height: 15 * s).offset(x: 303 * s, y: 5 * s)
            Text("_").font(.system(size: 11 * s, weight: .heavy)).foregroundStyle(CoronaColors.navy)
                .offset(x: 311 * s, y: 1 * s).accessibilityHidden(true)
            Button { controls.eject?() } label: {
                Image(systemName: "xmark").font(.system(size: 9 * s, weight: .heavy)).foregroundStyle(CoronaColors.navy)
                    .frame(width: 16 * s, height: 16 * s).contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(controls.eject == nil)
            .accessibilityLabel("Close Now Playing")
            .offset(x: 324 * s, y: 4 * s)
        }
        .frame(width: 346 * s, height: (drawerTop + 60) * s, alignment: .topLeading)
    }

    private func topKey(_ title: String, _ symbol: String, x: CGFloat, isOn: Bool = false, isEnabled: Bool = true,
                        tap: @escaping () -> Void) -> some View {
        CoronaRoundKey(title: title, scale: scale, diameter: 18, isEnabled: isEnabled, tap: tap) {
            Image(systemName: symbol)
                .font(.system(size: 7 * scale, weight: .heavy))
                .foregroundStyle(isOn ? Color(hex: 0x2B6CD8) : CoronaColors.navy)
        }
        .accessibilityValue(isOn ? "On" : "Off")
        .offset(x: x * scale, y: 3 * scale)
    }

    private func nextVisualization() {
        visualization = (visualization + 1) % CoronaVisualization.allCases.count
    }

    /// Mute: the volume to nothing, and back to where it was.
    private func toggleMute() {
        guard let volume = controls.volume else { return }
        if let mutedVolume {
            volume.wrappedValue = mutedVolume
            self.mutedVolume = nil
        } else {
            mutedVolume = max(volume.wrappedValue, 0.05)
            volume.wrappedValue = 0
        }
    }

    private func scan(_ direction: Double) -> () -> Void {
        { controls.seek(min(max(playback.time(.now) + direction * DeckControls.scanStep, 0), max(playback.duration - 1, 0))) }
    }
}

/// The window's periwinkle frame: the top bar rising with an S curve from the tab on the left to its rounded right
/// corner, down both sides around the screen to the metadata strip.
private struct CoronaFrameShape: Shape {
    var screenHeight: CGFloat
    /// Its outline without its foot, where the drawer flows on from it.
    var open = false

    func path(in rect: CGRect) -> Path {
        let s = rect.width / 346
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * s, y: rect.minY + y * s) }
        let bottom = 26 + screenHeight + 19
        var path = Path()
        if open {
            path.move(to: p(13, bottom))
            path.addLine(to: p(13, 24))
            path.addQuadCurve(to: p(20, 20), control: p(13, 20))
            path.addLine(to: p(92, 20))
            path.addCurve(to: p(118, 0), control1: p(106, 20), control2: p(104, 0))
            path.addLine(to: p(336, 0))
            path.addQuadCurve(to: p(346, 10), control: p(346, 0))
            path.addLine(to: p(346, bottom))
            path.move(to: CGPoint(x: rect.minX + 19 * s, y: rect.minY + 26 * s))
            path.addRect(CGRect(origin: p(19, 26), size: CGSize(width: 320 * s, height: screenHeight * s)))
            path.addRect(CGRect(origin: p(19, 26 + screenHeight + 1), size: CGSize(width: 320 * s, height: 15 * s)))
            return path
        }
        path.move(to: p(13, 24))
        path.addLine(to: p(13, bottom))
        path.addLine(to: p(346, bottom))
        path.addLine(to: p(346, 10))
        path.addQuadCurve(to: p(336, 0), control: p(346, 0))
        path.addLine(to: p(118, 0))
        path.addCurve(to: p(92, 20), control1: p(104, 0), control2: p(106, 20))
        path.addLine(to: p(20, 20))
        path.addQuadCurve(to: p(13, 24), control: p(13, 20))
        path.closeSubpath()
        // The screen and the metadata strip, cut out.
        path.addRect(CGRect(origin: p(19, 26), size: CGSize(width: 320 * s, height: screenHeight * s)))
        path.addRect(CGRect(origin: p(19, 26 + screenHeight + 1), size: CGSize(width: 320 * s, height: 15 * s)))
        return path
    }
}

/// The window's blue edge as one bent tube: from behind the frame along the top, around a rounded corner, and down the
/// left side `length` pixels (from its top, 7 down) to a diagonal cut, lit on its outer side and darker on its inner
/// side all along.
private struct CoronaEdge: View {
    var length: CGFloat
    /// Where the playlist drawer's piece is missing (slid out), in the skin's pixels from the top: the window's pieces end
    /// flat at its ends.
    var gap: ClosedRange<CGFloat>? = nil

    var body: some View {
        Canvas { context, size in
            let s = size.width / 130
            let thickness: CGFloat = 13, radius: CGFloat = 10, top: CGFloat = 7
            let bottom = top + length
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * s, y: y * s) }
            // The outline: the right end and the bottom end rounded, the outer corner rounded.
            var outline = Path()
            outline.move(to: p(radius, top))
            // Its top runs on behind the frame.
            outline.addLine(to: p(130, top))
            outline.addLine(to: p(130, top + thickness))
            outline.addLine(to: p(thickness + 3, top + thickness))
            outline.addQuadCurve(to: p(thickness, top + thickness + 3), control: p(thickness, top + thickness))
            // The foot: cut on a diagonal, the inner side the longer.
            outline.addLine(to: p(thickness, bottom - 2))
            outline.addQuadCurve(to: p(thickness - 1.5, bottom - 0.5), control: p(thickness, bottom))
            outline.addLine(to: p(0, bottom - thickness))
            outline.addLine(to: p(0, top + radius))
            outline.addArc(center: p(radius, top + radius), radius: radius * s, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
            outline.closeSubpath()
            var inside = context
            if let gap {
                var kept = Path()
                kept.addRect(CGRect(x: 0, y: 0, width: size.width, height: gap.lowerBound * s))
                kept.addRect(CGRect(x: 0, y: gap.upperBound * s, width: size.width, height: size.height))
                inside.clip(to: kept)
                context.clip(to: kept)
            }
            inside.clip(to: outline)
            inside.fill(outline, with: .color(CoronaColors.tube.last!))
            // Bands from the outer edge in, each following the bend: the light stays outside around the corner.
            let bands = Int((thickness * s).rounded(.up)) * 2
            for band in 0..<bands {
                let d = (CGFloat(band) + 0.5) * thickness / CGFloat(bands)
                // The tube's colors blended smoothly across its width.
                let position = Double(d / thickness) * Double(CoronaColors.tube.count - 1)
                let lower = min(Int(position), CoronaColors.tube.count - 2)
                let color = CoronaColors.tube[lower].mix(with: CoronaColors.tube[lower + 1], by: position - Double(lower))
                var line = Path()
                line.move(to: p(130, top + d))
                line.addLine(to: p(radius, top + d))
                if radius - d > 0 {
                    line.addArc(center: p(radius, top + radius), radius: (radius - d) * s, startAngle: .degrees(270), endAngle: .degrees(180), clockwise: true)
                } else {
                    line.addLine(to: p(d, top + d))
                }
                line.addLine(to: p(d, bottom + 2))
                inside.stroke(line, with: .color(color), lineWidth: thickness / CGFloat(bands) * s + 1)
            }
            context.stroke(outline, with: .color(Color(hex: 0x45549D)), lineWidth: max(0.6, s * 0.6))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// A blue tube of the window's edge, lit on its upper (or left) side: along the top left, or down the bottom left.
private struct CoronaTube: View {
    var horizontal: Bool
    /// Cut flat at its ends (the playlist drawer's piece, meeting the window's pieces).
    var flatEnds = false

    var body: some View {
        GeometryReader { proxy in
            let side = flatEnds ? 0 : (horizontal ? proxy.size.height : proxy.size.width)
            RoundedRectangle(cornerRadius: side / 2)
                .fill(LinearGradient(colors: CoronaColors.tube, startPoint: horizontal ? .top : .leading, endPoint: horizontal ? .bottom : .trailing))
                .overlay(RoundedRectangle(cornerRadius: side / 2).stroke(Color(hex: 0x45549D), lineWidth: 0.6))
        }
    }
}

/// The playlist drawer's grip on its blue tube: two columns of light dots.
private struct CoronaGrip: View {
    var scale: CGFloat

    var body: some View {
        VStack(spacing: 2 * scale) {
            ForEach(0..<8, id: \.self) { _ in
                HStack(spacing: 2 * scale) {
                    ForEach(0..<2, id: \.self) { _ in Circle().fill(.white.opacity(0.7)).frame(width: 1.6 * scale, height: 1.6 * scale) }
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The drawer: a glossy tray with a large rounded lower left corner, its right end lower.
private struct CoronaDrawerShape: Shape {
    /// Its outline without its top, where it flows on from the window.
    var open = false

    func path(in rect: CGRect) -> Path {
        let s = rect.width / 334
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * s, y: rect.minY + y * s) }
        var path = Path()
        if open {
            path.move(to: p(334, 0))
        } else {
            path.move(to: p(0, 0))
            path.addLine(to: p(334, 0))
        }
        // The right end: the blue block's foot with its rounded corner, then the one S curve down to the tray's foot.
        path.addLine(to: p(334, 32))
        path.addQuadCurve(to: p(326, 40), control: p(334, 40))
        path.addLine(to: p(229, 40))
        Self.lowerCurve(&path, p)
        path.addLine(to: p(22, 58))
        path.addQuadCurve(to: p(0, 36), control: p(0, 58))
        if open {
            path.addLine(to: p(0, 0))
        } else {
            path.closeSubpath()
        }
        return path
    }
}

/// The drawer's S curve, in its pixels: from the blue block's top it sweeps down to the left (its upper half the
/// block's left edge) and on down to the tray's foot (its lower half the drawer's outline), smooth where they meet.
extension CoronaDrawerShape {
    static func upperCurve(_ path: inout Path, _ p: (CGFloat, CGFloat) -> CGPoint) {
        path.addCurve(to: p(229, 40), control1: p(240, 17), control2: p(236, 32))
    }

    static func lowerCurve(_ path: inout Path, _ p: (CGFloat, CGFloat) -> CGPoint) {
        path.addCurve(to: p(205, 58), control1: p(222, 48), control2: p(218, 58))
    }
}

/// The blue block at the drawer's lower right (in the drawer's frame): from the S curve's top across to the right end,
/// down to its rounded corner, back along its foot and up the curve. `edgeOnly`: just its top and its curved edge.
private struct CoronaBlockShape: Shape {
    var edgeOnly = false

    func path(in rect: CGRect) -> Path {
        let s = rect.width / 334
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * s, y: rect.minY + y * s) }
        var path = Path()
        if edgeOnly {
            path.move(to: p(334, 17))
            path.addLine(to: p(256, 17))
            var upper = Path()
            upper.move(to: p(229, 40))
            upper.addCurve(to: p(256, 17), control1: p(236, 32), control2: p(240, 17))
            path.addPath(upper)
            return path
        }
        path.move(to: p(256, 17))
        path.addLine(to: p(334, 17))
        path.addLine(to: p(334, 32))
        path.addQuadCurve(to: p(326, 40), control: p(334, 40))
        path.addLine(to: p(229, 40))
        path.addCurve(to: p(256, 17), control1: p(236, 32), control2: p(240, 17))
        path.closeSubpath()
        return path
    }
}

/// Groovelight's mark on the blue block: the icon's notes in white.
private struct CoronaNote: View {
    var body: some View {
        Canvas { context, size in
            let notes = PCLogoNotes.path(in: CGRect(origin: .zero, size: size))
            context.fill(notes.offsetBy(dx: 0.6, dy: 0.6), with: .color(Color(hex: 0x45549D).opacity(0.7)))
            context.fill(notes, with: .linearGradient(Gradient(colors: [.white, Color(hex: 0xDDE6F7)]), startPoint: .zero,
                                                     endPoint: CGPoint(x: 0, y: size.height)))
        }
        .accessibilityHidden(true)
    }
}

/// A seek key at an end of the seek bar: a white capsule with two navy arrowheads; held, it keeps going.
private struct CoronaSeekKey: View {
    var title: String
    var scale: CGFloat
    var pointsRight: Bool
    var tap: () -> Void
    var hold: () -> Void

    var body: some View {
        DeckPress(title: title, tap: tap, hold: hold) { pressed in
            ZStack {
                Capsule().fill(LinearGradient(colors: [Color(hex: 0xB2B4BE), Color(hex: 0x98ADB7)], startPoint: .top, endPoint: .bottom))
                Capsule().fill(LinearGradient(stops: [.init(color: .white, location: 0), .init(color: Color(hex: 0xECEDF3), location: 0.5),
                                                      .init(color: pressed ? Color(hex: 0xA8C8E4) : Color(hex: 0xC0E0F0), location: 1)],
                                              startPoint: .top, endPoint: .bottom))
                    .padding(scale * 0.8)
                HStack(spacing: 0.6 * scale) {
                    ForEach(0..<2, id: \.self) { _ in
                        PCGlyph(kind: .play)
                            .fill(CoronaColors.navy)
                            .frame(width: 4 * scale, height: 4 * scale)
                    }
                }
                .scaleEffect(x: pointsRight ? 1 : -1)
            }
        }
    }
}

/// The seek bar: a green-tinted groove and the thumb (silver with green caps) at the song's place, dragged to seek.
private struct CoronaSeekBar: View {
    var playback: SkinPlayback
    var seek: (TimeInterval) -> Void
    var scale: CGFloat
    @State private var dragging: Double?

    var body: some View {
        GeometryReader { proxy in
            let thumb = 23 * scale
            let travel = proxy.size.width - thumb
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(LinearGradient(colors: CoronaColors.seek, startPoint: .top, endPoint: .bottom))
                    .frame(height: 9 * scale)
                    .overlay(alignment: .bottom) { Rectangle().fill(.white).frame(height: 2 * scale).offset(y: 2 * scale) }
                TimelineView(.periodic(from: .now, by: 0.25)) { context in
                    let progress = dragging ?? playback.progress(at: context.date)
                    CoronaThumb(scale: scale, horizontal: true)
                        .frame(width: thumb, height: proxy.size.height)
                        .offset(x: travel * progress)
                        .opacity(playback.duration > 0 ? 1 : 0)
                }
            }
            .contentShape(.rect)
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag in dragging = min(max((drag.location.x - thumb / 2) / max(travel, 1), 0), 1) }
                .onEnded { _ in
                    if let dragging, playback.duration > 0 { seek(min(dragging, 0.995) * playback.duration) }
                    dragging = nil
                })
        }
        .accessibilityElement()
        .accessibilityLabel("Position")
        .accessibilityAdjustableAction { direction in
            seek(min(max(playback.time(.now) + (direction == .increment ? 10 : -10), 0), playback.duration))
        }
    }
}

/// Corona's slider thumb: silver, with green caps at its ends (left and right along the seek bar, top and bottom on
/// the volume).
private struct CoronaThumb: View {
    var scale: CGFloat
    var horizontal: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 3 * scale)
        ZStack {
            shape.fill(LinearGradient(colors: CoronaColors.thumbGreen, startPoint: horizontal ? .leading : .top, endPoint: horizontal ? .trailing : .bottom))
            shape.fill(LinearGradient(colors: [.white, Color(hex: 0xCCD8E7), Color(hex: 0xA3B3CA)], startPoint: .top, endPoint: .bottom))
                .padding(horizontal ? .horizontal : .vertical, 4.5 * scale)
                .padding(horizontal ? .vertical : .horizontal, scale)
            shape.strokeBorder(Color(hex: 0x747475), lineWidth: max(0.5, scale * 0.6))
        }
    }
}

/// The volume: a wedge widening to the right, green as far as the level, and the green-capped thumb.
private struct CoronaVolume: View {
    @Binding var value: Double
    var scale: CGFloat

    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width, h = proxy.size.height
            let thumb = 10 * scale
            let level = min(max(value, 0), 1)
            ZStack(alignment: .leading) {
                Canvas { context, size in
                    var wedge = Path()
                    wedge.move(to: CGPoint(x: 0, y: size.height * 0.72))
                    wedge.addLine(to: CGPoint(x: size.width, y: size.height * 0.2))
                    wedge.addLine(to: CGPoint(x: size.width, y: size.height * 0.72))
                    wedge.closeSubpath()
                    context.fill(wedge, with: .linearGradient(Gradient(colors: [Color(hex: 0xDFE6F7), Color(hex: 0xA3ADCB)]), startPoint: .zero,
                                                             endPoint: CGPoint(x: 0, y: size.height)))
                    var lit = context
                    lit.clip(to: Path(CGRect(x: 0, y: 0, width: thumb / 2 + (w - thumb) * level, height: size.height)))
                    lit.fill(wedge, with: .linearGradient(Gradient(colors: [Color(hex: 0x72A382), Color(hex: 0x99D295)]), startPoint: .zero,
                                                         endPoint: CGPoint(x: 0, y: size.height)))
                    context.stroke(wedge, with: .color(Color(hex: 0x9FAACB)), lineWidth: max(0.5, scale * 0.5))
                }
                CoronaThumb(scale: scale, horizontal: false)
                    .frame(width: thumb, height: h)
                    .offset(x: (w - thumb) * level)
            }
            .contentShape(.rect)
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag in value = min(max((drag.location.x - thumb / 2) / max(w - thumb, 1), 0), 1) })
        }
        .accessibilityElement()
        .accessibilityLabel("Volume")
        .accessibilityValue("\(Int((value * 100).rounded())) percent")
        .accessibilityAdjustableAction { direction in
            value = min(max(value + (direction == .increment ? 0.1 : -0.1), 0), 1)
        }
    }
}

/// The metadata strip: the song's title, artist and album in turn (as the player cycled them), the time at the right.
private struct CoronaMetadata: View {
    var playback: SkinPlayback
    var scale: CGFloat

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let fields = [playback.title, playback.artist, playback.album].filter { !$0.isEmpty }
            let field = fields.isEmpty ? "" : fields[Int(context.date.timeIntervalSinceReferenceDate / 4) % fields.count]
            HStack {
                Text(field).lineLimit(1)
                Spacer(minLength: 6 * scale)
                Text(clockText(playback.time(context.date))).monospacedDigit()
            }
            .font(.system(size: 8.5 * scale, weight: .bold))
            .foregroundStyle(CoronaColors.green)
            .padding(.horizontal, 4 * scale)
            .frame(maxHeight: .infinity)
            .background(Color.black)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The screen's bars: the spectrum in forty bars, deep blue at their foot to white at their top, with falling caps.
private struct CoronaBars: View {
    var playback: SkinPlayback
    var scale: CGFloat
    @State private var state = PCSpectrumState()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !playback.isPlaying && state.isQuiet)) { context in
            let target = playback.isPlaying ? PCSpectrum.target(playback: playback, at: context.date) : Array(repeating: 0, count: PCSpectrumState.bars)
            let (bars, peaks) = state.update(toward: target, at: context.date)
            Canvas { canvas, size in
                let count = PCSpectrumState.bars
                let gap = size.width * 0.012
                let width = (size.width - gap * CGFloat(count + 1)) / CGFloat(count)
                let gradient = Gradient(colors: [Color(hex: 0xE8F6FF), Color(hex: 0x3FA9F5), Color(hex: 0x1E4FB5), Color(hex: 0x0B1F5C)])
                for index in 0..<count {
                    let x = gap + CGFloat(index) * (width + gap)
                    let height = size.height * 0.9 * bars[index]
                    if height > 0 {
                        canvas.fill(Path(CGRect(x: x, y: size.height - height, width: width, height: height)),
                                    with: .linearGradient(gradient, startPoint: CGPoint(x: 0, y: size.height * 0.1), endPoint: CGPoint(x: 0, y: size.height)))
                    }
                    let peak = size.height * 0.9 * peaks[index]
                    if peak > 2 {
                        canvas.fill(Path(CGRect(x: x, y: size.height - peak - 2 * scale, width: width, height: 1.5 * scale)), with: .color(.white.opacity(0.85)))
                    }
                }
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: Playlist drawer

private struct CoronaPlaylist: View {
    var scale: CGFloat
    var size: CGSize
    var playback: SkinPlayback
    var controls: DeckControls
    var playlist: SkinPlaylist?
    var overlay: AnyView?
    @Binding var showsPlaylist: Bool

    var body: some View {
        let s = scale
        let height = size.height / s, width = size.width / s
        let entries = playlist?.entries ?? [SkinPlaylist.Entry(title: playback.title, artist: playback.artist, duration: playback.duration)]
        let current = playlist == nil ? 0 : playlist?.current
        ZStack(alignment: .topLeading) {
            // The frame: the blue tube down the left with its grip, the periwinkle around the list.
            RoundedRectangle(cornerRadius: 8 * s)
                .fill(LinearGradient(stops: [.init(color: .white, location: 0), .init(color: Color(hex: 0xC9DAEF), location: 0.02),
                                             .init(color: CoronaColors.frame, location: 0.05), .init(color: CoronaColors.frame, location: 0.95),
                                             .init(color: CoronaColors.frameEdge, location: 1)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: 8 * s).stroke(Color(hex: 0x73767B), lineWidth: max(0.6, s * 0.8)))
                .frame(width: (width - 6) * s, height: size.height)
                .offset(x: 6 * s)
            CoronaTube(horizontal: false, flatEnds: true)
                .frame(width: 13 * s, height: size.height)
            CoronaGrip(scale: s)
                .offset(x: 3.5 * s, y: (height / 2 - 14) * s)
            // The top: shuffle, the list's name, close.
            CoronaRoundKey(title: "Shuffle", scale: s, diameter: 19, tap: controls.toggleShuffle) {
                Image(systemName: "shuffle")
                    .font(.system(size: 7.5 * s, weight: .heavy))
                    .foregroundStyle(controls.isShuffled ? Color(hex: 0x2B6CD8) : CoronaColors.navy)
            }
            .accessibilityValue(controls.isShuffled ? "On" : "Off")
            .offset(x: 26 * s, y: 9 * s)
            HStack {
                Text("Now Playing")
                    .font(.system(size: 8.5 * s))
                    .foregroundStyle(.black)
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.system(size: 6 * s, weight: .bold))
                    .foregroundStyle(CoronaColors.navy)
            }
            .padding(.horizontal, 4 * s)
            .frame(width: (width - 110) * s, height: 15 * s)
            .background(RoundedRectangle(cornerRadius: 2 * s).fill(.white))
            .overlay(RoundedRectangle(cornerRadius: 2 * s).stroke(Color(hex: 0x7F9DB9), lineWidth: max(0.5, s * 0.6)))
            .offset(x: 52 * s, y: 11 * s)
            .accessibilityHidden(true)
            Button { showsPlaylist = false } label: {
                Image(systemName: "xmark").font(.system(size: 8.5 * s, weight: .heavy)).foregroundStyle(CoronaColors.navy)
                    .frame(width: 15 * s, height: 15 * s).contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Hide Playlist")
            .offset(x: (width - 22) * s, y: 11 * s)
            // The list: white on black, the song playing in bold green.
            Group {
                if let overlay {
                    overlay
                        .foregroundStyle(.white)
                        .environment(\.colorScheme, .dark)
                        .padding(8 * s)
                } else {
                    list(entries: entries, current: current)
                }
            }
            .frame(width: (width - 37) * s, height: (height - 34 - 12) * s)
            .background(Color.black)
            .overlay(Rectangle().strokeBorder(CoronaColors.frameDark, lineWidth: max(0.6, s * 0.8)).padding(-s * 0.6))
            .offset(x: 26 * s, y: 34 * s)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .environment(\.colorScheme, .dark)
    }

    private func list(entries: [SkinPlaylist.Entry], current: Int?) -> some View {
        ScrollViewReader { reader in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                        let isCurrent = index == current
                        Button {
                            playlist?.play?(index)
                        } label: {
                            HStack(spacing: 4 * scale) {
                                Text([entry.title, entry.artist].filter { !$0.isEmpty }.joined(separator: " - "))
                                    .lineLimit(1)
                                Spacer(minLength: 4 * scale)
                                Text(clockText(entry.duration).trimmingPrefix("0"))
                                    .monospacedDigit()
                            }
                            .font(.system(size: 9 * scale, weight: isCurrent ? .bold : .regular))
                            .foregroundStyle(isCurrent ? CoronaColors.green : Color.white)
                            .padding(.horizontal, 3 * scale)
                            .frame(height: 13 * scale)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .disabled(playlist?.play == nil)
                        .accessibilityAddTraits(isCurrent ? .isSelected : [])
                        .id(index)
                    }
                }
                .padding(.vertical, 2 * scale)
            }
            .scrollIndicators(.visible)
            .onAppear { if let current { reader.scrollTo(current, anchor: .center) } }
            .onChange(of: current) { _, current in
                if let current { withAnimation { reader.scrollTo(current, anchor: .center) } }
            }
        }
    }
}
