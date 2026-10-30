import SwiftUI

/// Now Playing as the vintage player chosen, filling the screen: a turntable on a walnut plinth, a cassette deck of
/// brushed aluminum, or a CD player in black, with their own keys, knobs, switches, meters and displays working the
/// app's player. The player itself (the stage) and its controls (the panel) are one above the other where the screen
/// is tall, side by side where it is wide, and on either side of a fold (a Galaxy Z Fold's or an iPhone Duo's) where
/// the device is partly open, so it suits a phone, a foldable open or closed, an iPad and a Mac window.
///
/// `chromeInset` leaves room at the top for the app's own buttons (laid over it, styled with `DeckChromeLabelStyle`);
/// `stageOverlay`, when given (the lyrics, Up Next), takes the stage's place behind smoked glass; `accessory` (the
/// app's own buttons, as AirPlay) goes at the foot of the panel.
public struct SkinDeck<Artwork: View, Accessory: View>: View {
    var skin: NowPlayingSkin
    var playback: SkinPlayback
    var controls: DeckControls
    var cassette: CassetteDesign
    var cassettePictures: CassettePictures
    var chromeInset: CGFloat
    var stageOverlay: AnyView?
    var playlist: SkinPlaylist?
    @AppStorage(NowPlayingSkin.pcThemeStorageKey) private var pcTheme: PCTheme = .classic
    @ViewBuilder var artwork: () -> Artwork
    @ViewBuilder var accessory: () -> Accessory

    public init(skin: NowPlayingSkin, playback: SkinPlayback, controls: DeckControls, cassette: CassetteDesign = .classic,
                cassettePictures: CassettePictures = CassettePictures(), chromeInset: CGFloat = 56, stageOverlay: AnyView? = nil,
                playlist: SkinPlaylist? = nil, @ViewBuilder artwork: @escaping () -> Artwork, @ViewBuilder accessory: @escaping () -> Accessory) {
        self.skin = skin
        self.playback = playback
        self.controls = controls
        self.cassette = cassette
        self.cassettePictures = cassettePictures
        self.chromeInset = chromeInset
        self.stageOverlay = stageOverlay
        self.playlist = playlist
        self.artwork = artwork
        self.accessory = accessory
    }

    public var body: some View {
        GeometryReader { proxy in
            if skin == .pcPlayer {
                PCPlayer(size: proxy.size, top: chromeInset, fold: Self.fold(in: proxy), playback: playback, controls: controls, playlist: playlist,
                         overlay: stageOverlay, theme: pcTheme, artwork: AnyView(artwork()), accessory: accessory)
            } else {
                decks(in: proxy)
            }
        }
        .background { surface.ignoresSafeArea() }
        .environment(\.colorScheme, skin == .cassette ? .light : .dark)
    }

    @ViewBuilder private func decks(in proxy: GeometryProxy) -> some View {
        do {
            let regions = DeckRegions(size: proxy.size, top: chromeInset, fold: Self.fold(in: proxy),
                                      stageAspect: skin == .cassette && stageOverlay == nil ? cassette.resolvedGeometry.aspectRatio * 0.92 : 1)
            ZStack(alignment: .topLeading) {
                stage
                    .frame(width: regions.stage.width, height: regions.stage.height)
                    .offset(x: regions.stage.minX, y: regions.stage.minY)
                panel(size: regions.panel.size)
                    .frame(width: regions.panel.width, height: regions.panel.height)
                    .offset(x: regions.panel.minX, y: regions.panel.minY)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
        }
    }

    @ViewBuilder private var stage: some View {
        if let stageOverlay {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.black.opacity(0.78))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.black.opacity(0.001).shadow(.inner(color: .black, radius: 10, y: 6))))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(LinearGradient(colors: [.black.opacity(0.6), .white.opacity(0.35)], startPoint: .top, endPoint: .bottom),
                                      lineWidth: 1.5))
                stageOverlay
                    .foregroundStyle(.white)
                    .environment(\.colorScheme, .dark)
                    .padding(16)
            }
        } else {
            switch skin {
            case .cover, .vinyl: TurntableStage(playback: playback, seek: controls.seek, artwork: artwork)
            case .cassette: CassetteStage(design: cassette, pictures: cassettePictures, playback: playback, artwork: artwork)
            case .compactDisc, .pcPlayer: DiscStage(playback: playback, artwork: artwork)
            }
        }
    }

    @ViewBuilder private func panel(size: CGSize) -> some View {
        switch skin {
        case .cover, .vinyl: TurntablePanel(size: size, playback: playback, controls: controls, accessory: accessory)
        case .cassette: CassettePanel(size: size, playback: playback, controls: controls, accessory: accessory)
        case .compactDisc, .pcPlayer: DiscPanel(size: size, playback: playback, controls: controls, accessory: accessory)
        }
    }

    /// What the player is made of, to the screen's edges.
    @ViewBuilder private var surface: some View {
        switch skin {
        case .cover, .vinyl:
            Textured(texture: .walnut, brightness: -0.04)
                .overlay(RadialGradient(colors: [.white.opacity(0.08), .black.opacity(0.45)], center: .init(x: 0.4, y: 0.25), startRadius: 50,
                                        endRadius: 900))
        case .cassette:
            Textured(texture: .aluminum, brightness: 0.14)
                .overlay(LinearGradient(colors: [.white.opacity(0.18), .clear, .black.opacity(0.15)], startPoint: .top, endPoint: .bottom))
                // Walnut cheeks at the sides.
                .overlay(alignment: .leading) { Cheek() }
                .overlay(alignment: .trailing) { Cheek() }
        case .pcPlayer:
            // The desktop of the time: a green hill under a blue sky.
            Color.clear.overlay(SkinTexture.hill.image.resizable().scaledToFill()).clipped()
        case .compactDisc:
            Textured(texture: .aluminum, brightness: -0.12, tint: Color(white: 0.32))
                .overlay(LinearGradient(colors: [.white.opacity(0.08), .clear, .black.opacity(0.3)], startPoint: .top, endPoint: .bottom))
        }
    }

    /// Where the fold is, while it divides the screen (iOS 27.1, an iPhone Duo partly open).
    private static func fold(in proxy: GeometryProxy) -> CGRect? {
        #if os(iOS)
        if #available(iOS 27.1, *) {
            return proxy.reservedRegions(kind: .division).first { $0.isActive }?.frame
        }
        #endif
        return nil
    }
}

/// A walnut end of the cassette deck.
private struct Cheek: View {
    var body: some View {
        Textured(texture: .walnut)
            .frame(width: 10)
            .overlay(LinearGradient(colors: [.black.opacity(0.4), .white.opacity(0.1), .black.opacity(0.4)], startPoint: .leading, endPoint: .trailing))
            .ignoresSafeArea()
    }
}

/// Where the stage and the panel go: one above the other on a tall screen, side by side on a wide one, and on either
/// side of a fold that divides it (left and right of an upright fold, above and below a level one).
/// A near square screen (a foldable open) has them one above the other too.
struct DeckRegions {
    var stage: CGRect
    var panel: CGRect

    /// `stageAspect` is the stage's width over its height (the cassette's door is wide, the others square).
    init(size: CGSize, top: CGFloat, fold: CGRect?, stageAspect: CGFloat = 1) {
        let margin = max(12, min(size.width, size.height) * 0.025)
        let area = CGRect(x: margin, y: top, width: max(size.width - margin * 2, 1), height: max(size.height - top - margin, 1))
        if let fold, fold.height >= size.height * 0.5, fold.minX > area.minX + 120, fold.maxX < area.maxX - 120 {
            stage = CGRect(x: area.minX, y: area.minY, width: fold.minX - margin - area.minX, height: area.height)
            panel = CGRect(x: fold.maxX + margin, y: area.minY, width: area.maxX - fold.maxX - margin, height: area.height)
        } else if let fold, fold.width >= size.width * 0.5, fold.minY > area.minY + 120, fold.maxY < area.maxY - 120 {
            stage = CGRect(x: area.minX, y: area.minY, width: area.width, height: fold.minY - margin - area.minY)
            panel = CGRect(x: area.minX, y: fold.maxY + margin, width: area.width, height: area.maxY - fold.maxY - margin)
        } else if area.width >= area.height * 1.25 {
            // Clearly wide (a Mac window, an iPad or a phone on its side). A near square screen (a foldable open) keeps
            // the panel under the player, where it has the width to be large.
            let width = min(area.height * stageAspect, area.width * 0.58)
            stage = CGRect(x: area.minX, y: area.minY, width: width, height: area.height)
            panel = CGRect(x: area.minX + width + margin, y: area.minY, width: area.width - width - margin, height: area.height)
        } else {
            let height = min(area.width / stageAspect, area.height * 0.56)
            stage = CGRect(x: area.minX, y: area.minY, width: area.width, height: height)
            panel = CGRect(x: area.minX, y: area.minY + height + margin, width: area.width, height: area.height - height - margin)
        }
    }

    /// How much a panel drawn for `reference` grows (or shrinks) to fill `size`.
    static func scale(_ size: CGSize, reference: CGSize) -> CGFloat {
        min(max(min(size.width / reference.width, size.height / reference.height), 0.62), 1.9)
    }
}

/// Rows one under the other, the room left over shared between them (up to `maxHeight`), so a panel fills a tall
/// screen instead of sitting in the middle of it.
struct SpreadLayout: Layout {
    var spacing: CGFloat
    var maxHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil)) }
        let natural = sizes.map(\.height).reduce(0, +) + spacing * CGFloat(max(subviews.count - 1, 0))
        let width = proposal.width ?? sizes.map(\.width).max() ?? 0
        return CGSize(width: width, height: max(natural, min(proposal.height ?? natural, maxHeight)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil)) }
        let natural = sizes.map(\.height).reduce(0, +) + spacing * CGFloat(max(subviews.count - 1, 0))
        let gap = spacing + (subviews.count > 1 ? max(bounds.height - natural, 0) / CGFloat(subviews.count - 1) : 0)
        var y = bounds.minY
        for (subview, size) in zip(subviews, sizes) {
            subview.place(at: CGPoint(x: bounds.midX, y: y), anchor: .top, proposal: ProposedViewSize(width: bounds.width, height: size.height))
            y += size.height + gap
        }
    }
}

// MARK: - Turntable

/// The turntable's aluminum plate: the song in a receiver's dial window, the keys, the time, shuffle and repeat, and the volume.
private struct TurntablePanel<Accessory: View>: View {
    var size: CGSize
    var playback: SkinPlayback
    var controls: DeckControls
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        let scale = DeckRegions.scale(size, reference: CGSize(width: 360, height: 290))
        SpreadLayout(spacing: 14 * scale, maxHeight: 290 * scale * 1.5) {
            DialWindow(playback: playback, seek: controls.seek, scale: scale)
            HStack(alignment: .bottom, spacing: 12 * scale) {
                captioned("PREV", scale) {
                    MetalKey(title: "Previous", symbol: "backward.end.fill", size: CGSize(width: 54 * scale, height: 44 * scale),
                             tap: controls.previous, hold: scan(-1))
                }
                captioned("START · STOP", scale) {
                    MetalKey(title: playback.isPlaying ? "Stop" : "Start", symbol: playback.isPlaying ? "stop.fill" : "play.fill",
                             size: CGSize(width: 92 * scale, height: 52 * scale), lamp: playback.isPlaying, tap: controls.playPause)
                }
                captioned("NEXT", scale) {
                    MetalKey(title: "Next", symbol: "forward.end.fill", size: CGSize(width: 54 * scale, height: 44 * scale),
                             tap: controls.next, hold: scan(1))
                }
                Spacer(minLength: 0)
                captioned("TIME", scale) { LEDClock(playback: playback, size: 15 * scale) }
            }
            HStack(alignment: .bottom, spacing: 18 * scale) {
                captioned("SHUFFLE", scale) {
                    ToggleSwitch(title: "Shuffle", position: controls.isShuffled ? 0 : 1, value: controls.isShuffled ? "On" : "Off",
                                 size: 44 * scale, tap: controls.toggleShuffle)
                }
                captioned(repeatCaption(controls.repeatMode), scale) {
                    ToggleSwitch(title: "Repeat", positions: 3, position: repeatPosition(controls.repeatMode),
                                 value: repeatCaption(controls.repeatMode), size: 44 * scale, tap: controls.cycleRepeat)
                }
                Spacer(minLength: 0)
                if let volume = controls.volume {
                    captioned("VOLUME", scale) { Knob(title: "Volume", value: volume, diameter: 66 * scale) }
                }
            }
            accessory()
                .foregroundStyle(Color.black.opacity(0.65))
                .tint(Color.black.opacity(0.65))
        }
        .padding(.horizontal, 20 * scale)
        .padding(.vertical, 16 * scale)
        .frame(maxWidth: 360 * scale)
        .background(Plate(texture: .aluminum, brightness: 0.12, cornerRadius: 10 * scale, screws: 9 * scale))
        .environment(\.colorScheme, .light)
        .frame(width: size.width, height: size.height)
    }

    private func scan(_ direction: Double) -> () -> Void {
        { controls.seek(min(max(playback.time(.now) + direction * DeckControls.scanStep, 0), max(playback.duration - 1, 0))) }
    }
}

/// A caption engraved under a control.
@MainActor @ViewBuilder private func captioned<Content: View>(_ caption: String, _ scale: CGFloat, onDark: Bool = false,
                                                   @ViewBuilder content: () -> Content) -> some View {
    VStack(spacing: 5 * scale) {
        content()
        Engraved(caption, size: 7.5 * scale, onDark: onDark)
    }
}

private func repeatCaption(_ mode: DeckControls.Repeat) -> String {
    switch mode {
    case .off: "REPEAT OFF"
    case .all: "REPEAT ALL"
    case .one: "REPEAT ONE"
    }
}

/// Repeat's toggle: down for off, the middle for all, up for one.
private func repeatPosition(_ mode: DeckControls.Repeat) -> Int {
    switch mode {
    case .off: 2
    case .all: 1
    case .one: 0
    }
}

/// A receiver's dial window, set into the plate: smoked glass lit warm from behind by its lamps, the song in cream
/// lettering, the artist and the album under it, and the printed scale along the bottom, its red pointer where the
/// song is (dragged along the scale, it goes there).
private struct DialWindow: View {
    var playback: SkinPlayback
    var seek: (TimeInterval) -> Void
    var scale: CGFloat

    static let lettering = Color(red: 1, green: 0.93, blue: 0.78)
    static let glow = Color(red: 1, green: 0.6, blue: 0.18)

    var body: some View {
        let corner = 5 * scale
        let subtitle = [playback.artist, playback.album].filter { !$0.isEmpty }.joined(separator: "  ·  ")
        VStack(alignment: .leading, spacing: 3 * scale) {
            Text(playback.title.isEmpty ? " " : playback.title)
                .font(.system(size: 16 * scale, weight: .medium).width(.expanded))
                .tracking(0.6 * scale)
            Text(subtitle.isEmpty ? " " : subtitle)
                .font(.system(size: 10.5 * scale, weight: .regular).width(.expanded))
                .tracking(0.5 * scale)
                .opacity(0.72)
            DialScale(playback: playback, seek: seek, scale: scale)
                .frame(height: 20 * scale)
                .padding(.top, 4 * scale)
        }
        .lineLimit(1)
        .truncationMode(.tail)
        .foregroundStyle(Self.lettering)
        .shadow(color: Self.glow.opacity(0.85), radius: 3 * scale)
        .padding(.horizontal, 12 * scale)
        .padding(.top, 9 * scale)
        .padding(.bottom, 6 * scale)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            // The glass, dark, warmed by the lamps behind it (brightest low in the middle), darker at its ends.
            ZStack {
                Color(red: 0.07, green: 0.045, blue: 0.025)
                EllipticalGradient(colors: [Self.glow.opacity(0.42), Self.glow.opacity(0.12), .clear], center: .init(x: 0.5, y: 0.85),
                                   startRadiusFraction: 0, endRadiusFraction: 0.75)
                LinearGradient(colors: [.black.opacity(0.55), .clear, .clear, .black.opacity(0.55)], startPoint: .leading, endPoint: .trailing)
            }
        }
        .overlay {
            // The glass's reflection, across its top.
            LinearGradient(stops: [.init(color: .white.opacity(0.13), location: 0), .init(color: .white.opacity(0.04), location: 0.42),
                                   .init(color: .clear, location: 0.46)], startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false)
        }
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: corner, style: .continuous)
            .strokeBorder(LinearGradient(colors: [.black.opacity(0.7), .white.opacity(0.6)], startPoint: .top, endPoint: .bottom), lineWidth: 1.5 * scale))
        .padding(2 * scale)
        .background(RoundedRectangle(cornerRadius: corner + 2 * scale, style: .continuous).fill(Color.black.opacity(0.12)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([playback.title, subtitle].filter { !$0.isEmpty }.joined(separator: ", "))
        .accessibilityAdjustableAction { direction in
            seek(min(max(playback.time(.now) + (direction == .increment ? 10 : -10), 0), playback.duration))
        }
    }
}
/// The dial's printed scale: fine ticks, longer every fifth, and the red pointer along it where the song is.
private struct DialScale: View {
    var playback: SkinPlayback
    var seek: (TimeInterval) -> Void
    var scale: CGFloat
    @State private var dragging: Double?

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width, height = proxy.size.height
            ZStack(alignment: .topLeading) {
                Canvas { context, size in
                    let ticks = 50
                    for tick in 0...ticks {
                        let x = size.width * Double(tick) / Double(ticks)
                        let long = tick.isMultiple(of: 5)
                        var line = Path()
                        line.move(to: CGPoint(x: x, y: size.height * 0.35))
                        line.addLine(to: CGPoint(x: x, y: size.height * (long ? 0.95 : 0.7)))
                        context.stroke(line, with: .color(DialWindow.lettering.opacity(long ? 0.75 : 0.45)), lineWidth: long ? 1 : 0.6)
                    }
                    var base = Path()
                    base.move(to: CGPoint(x: 0, y: size.height * 0.35))
                    base.addLine(to: CGPoint(x: size.width, y: size.height * 0.35))
                    context.stroke(base, with: .color(DialWindow.lettering.opacity(0.5)), lineWidth: 0.6)
                }
                TimelineView(.periodic(from: .now, by: 0.25)) { context in
                    let progress = dragging ?? playback.progress(at: context.date)
                    Capsule()
                        .fill(Color(red: 1, green: 0.22, blue: 0.12))
                        .frame(width: max(2, 2.2 * scale), height: height * 1.2)
                        .shadow(color: Color(red: 1, green: 0.2, blue: 0.1), radius: 3 * scale)
                        .offset(x: width * progress - max(2, 2.2 * scale) / 2, y: -height * 0.15)
                        .animation(dragging == nil ? .linear(duration: 0.25) : nil, value: progress)
                }
            }
            .contentShape(.rect)
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag in dragging = min(max(drag.location.x / width, 0), 1) }
                .onEnded { _ in
                    if let dragging, playback.duration > 0 { seek(min(dragging, 0.995) * playback.duration) }
                    dragging = nil
                })
        }
    }
}

/// Elapsed time in red LED digits behind a dark window.
private struct LEDClock: View {
    var playback: SkinPlayback
    var size: CGFloat

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            VFDText(text: clockText(playback.time(context.date)), ghost: "88:88", font: SkinFont.digits(size),
                    color: Color(red: 1, green: 0.25, blue: 0.15))
        }
        .padding(.horizontal, size * 0.5)
        .padding(.vertical, size * 0.4)
        .background(Recess(cornerRadius: size * 0.3, fill: Color(red: 0.08, green: 0.02, blue: 0.02), depth: 3))
    }
}

// MARK: - Cassette deck

/// The cassette deck's controls: its name, the VU meters and the counter, the piano keys, the switches and the level.
private struct CassettePanel<Accessory: View>: View {
    var size: CGSize
    var playback: SkinPlayback
    var controls: DeckControls
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        let scale = DeckRegions.scale(size, reference: CGSize(width: 360, height: 300))
        let key = CGSize(width: 54 * scale, height: 62 * scale)
        let isPaused = !playback.isPlaying && playback.time(.now) > 0.5
        SpreadLayout(spacing: 14 * scale, maxHeight: 300 * scale * 1.5) {
            HStack(alignment: .firstTextBaseline) {
                Text("GROOVELIGHT")
                    .font(.system(size: 13 * scale, weight: .black).width(.expanded))
                    .foregroundStyle(.black.opacity(0.7))
                    .shadow(color: .white.opacity(0.6), radius: 0, y: 0.8)
                Spacer(minLength: 8)
                Engraved("STEREO CASSETTE DECK", size: 7.5 * scale)
            }
            HStack(alignment: .bottom, spacing: 10 * scale) {
                VUMeter(channel: 0, playback: playback).frame(width: 104 * scale, height: 64 * scale)
                VUMeter(channel: 1, playback: playback).frame(width: 104 * scale, height: 64 * scale)
                Spacer(minLength: 0)
                captioned("COUNTER", scale) {
                    TapeCounter(playback: playback).frame(width: 84 * scale, height: 28 * scale)
                        .padding(4 * scale)
                        .background(Recess(cornerRadius: 4 * scale, fill: Color(white: 0.12), depth: 3))
                }
            }
            HStack(spacing: 4 * scale) {
                PianoKey(title: "Rewind", symbol: "backward.fill", size: key, tap: controls.previous, hold: scan(-1))
                PianoKey(title: "Play", symbol: "play.fill", size: key, isLatched: playback.isPlaying, accent: .green.opacity(0.8)) {
                    if !playback.isPlaying { controls.playPause() }
                }
                PianoKey(title: "Fast Forward", symbol: "forward.fill", size: key, tap: controls.next, hold: scan(1))
                PianoKey(title: "Stop", symbol: "stop.fill", size: key) {
                    if playback.isPlaying { controls.playPause() }
                    controls.seek(0)
                }
                PianoKey(title: "Pause", symbol: "pause.fill", size: key, isLatched: isPaused, accent: .orange.opacity(0.8)) {
                    controls.playPause()
                }
            }
            .padding(5 * scale)
            .background(RoundedRectangle(cornerRadius: 6 * scale).fill(Color.black.opacity(0.75)))
            HStack(alignment: .bottom, spacing: 18 * scale) {
                captioned("SHUFFLE", scale) {
                    ToggleSwitch(title: "Shuffle", position: controls.isShuffled ? 0 : 1, value: controls.isShuffled ? "On" : "Off",
                                 size: 42 * scale, tap: controls.toggleShuffle)
                }
                captioned(repeatCaption(controls.repeatMode), scale) {
                    ToggleSwitch(title: "Repeat", positions: 3, position: repeatPosition(controls.repeatMode),
                                 value: repeatCaption(controls.repeatMode), size: 42 * scale, tap: controls.cycleRepeat)
                }
                Spacer(minLength: 0)
                if let volume = controls.volume {
                    captioned("OUTPUT LEVEL", scale) { Knob(title: "Volume", value: volume, diameter: 64 * scale) }
                }
            }
            accessory()
                .foregroundStyle(Color.black.opacity(0.65))
                .tint(Color.black.opacity(0.65))
        }
        .padding(.horizontal, 8 * scale)
        .frame(maxWidth: 376 * scale)
        .frame(width: size.width, height: size.height)
    }

    /// A step of Rewind or Fast Forward held, with the tape's sound as a deck makes it.
    private func scan(_ direction: Double) -> () -> Void {
        {
            TapeCue.shared.cue()
            controls.seek(min(max(playback.time(.now) + direction * DeckControls.scanStep, 0), max(playback.duration - 1, 0)))
        }
    }
}

// MARK: - CD player

/// The CD player's front: the fluorescent display (time, the song stepping through, the position bar), the round keys
/// and the volume dial.
private struct DiscPanel<Accessory: View>: View {
    var size: CGSize
    var playback: SkinPlayback
    var controls: DeckControls
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        let scale = DeckRegions.scale(size, reference: CGSize(width: 360, height: 300))
        SpreadLayout(spacing: 16 * scale, maxHeight: 300 * scale * 1.5) {
            HStack(alignment: .firstTextBaseline) {
                Text("GROOVELIGHT")
                    .font(.system(size: 13 * scale, weight: .black).width(.expanded))
                    .foregroundStyle(.white.opacity(0.85))
                Spacer(minLength: 8)
                Engraved("COMPACT DISC PLAYER", size: 7.5 * scale, onDark: true)
            }
            display(scale)
            HStack(alignment: .center, spacing: 12 * scale) {
                RoundKey(title: "Previous", symbol: "backward.end.fill", diameter: 46 * scale, tap: controls.previous, hold: scan(-1))
                RoundKey(title: playback.isPlaying ? "Pause" : "Play", symbol: "playpause.fill", diameter: 58 * scale, tap: controls.playPause)
                RoundKey(title: "Next", symbol: "forward.end.fill", diameter: 46 * scale, tap: controls.next, hold: scan(1))
                RoundKey(title: "Stop", symbol: "stop.fill", diameter: 40 * scale) {
                    if playback.isPlaying { controls.playPause() }
                    controls.seek(0)
                }
                Spacer(minLength: 0)
                if let volume = controls.volume {
                    captioned("VOLUME", scale, onDark: true) { Knob(title: "Volume", value: volume, diameter: 70 * scale, onDark: true) }
                }
            }
            HStack(spacing: 12 * scale) {
                captioned("RANDOM", scale, onDark: true) {
                    RoundKey(title: controls.isShuffled ? "Shuffle On" : "Shuffle Off", symbol: "shuffle", diameter: 30 * scale,
                             tap: controls.toggleShuffle)
                }
                captioned("REPEAT", scale, onDark: true) {
                    RoundKey(title: repeatCaption(controls.repeatMode).capitalized, symbol: controls.repeatMode == .one ? "repeat.1" : "repeat",
                             diameter: 30 * scale, tap: controls.cycleRepeat)
                }
                Spacer(minLength: 0)
                accessory()
                    .foregroundStyle(.white.opacity(0.8))
                    .tint(.white.opacity(0.8))
            }
        }
        .padding(.horizontal, 8 * scale)
        .frame(maxWidth: 376 * scale)
        .frame(width: size.width, height: size.height)
    }

    private func display(_ scale: CGFloat) -> some View {
        let characters = 14
        return VStack(alignment: .leading, spacing: 8 * scale) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4 * scale) {
                    indicator(playback.isPlaying ? "PLAY" : "PAUSE", lit: true, scale: scale)
                    indicator("RANDOM", lit: controls.isShuffled, scale: scale)
                    indicator(controls.repeatMode == .one ? "REPEAT 1" : "REPEAT", lit: controls.repeatMode != .off, scale: scale)
                }
                Spacer(minLength: 0)
                TimelineView(.periodic(from: .now, by: 0.5)) { context in
                    VFDText(text: clockText(playback.time(context.date)), ghost: "88:88", font: SkinFont.digits(34 * scale))
                }
            }
            VFDMarquee(text: playback.title, count: characters, size: 15 * scale, isMoving: playback.isPlaying)
            VFDMarquee(text: playback.artist, count: characters, size: 15 * scale, isMoving: playback.isPlaying)
            VFDBar(playback: playback, seek: controls.seek).frame(height: 8 * scale)
        }
        .padding(14 * scale)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Recess(cornerRadius: 8 * scale, fill: LinearGradient(colors: [Color(red: 0.02, green: 0.08, blue: 0.08), Color(red: 0.01, green: 0.04, blue: 0.05)],
                                                                         startPoint: .top, endPoint: .bottom), depth: 5))
        .overlay(RoundedRectangle(cornerRadius: 8 * scale)
            .fill(LinearGradient(colors: [.white.opacity(0.1), .clear], startPoint: .topLeading, endPoint: .center)).allowsHitTesting(false))
    }

    private func indicator(_ text: String, lit: Bool, scale: CGFloat) -> some View {
        Text(text)
            .font(.system(size: 8 * scale, weight: .bold).width(.expanded))
            .foregroundStyle(lit ? vfdColor : vfdColor.opacity(0.1))
            .shadow(color: lit ? vfdColor.opacity(0.7) : .clear, radius: 3)
    }

    private func scan(_ direction: Double) -> () -> Void {
        { controls.seek(min(max(playback.time(.now) + direction * DeckControls.scanStep, 0), max(playback.duration - 1, 0))) }
    }
}

// MARK: - The app's buttons

/// A round aluminum cap, its symbol engraved: the app's buttons over a player (close, the look, the lyrics).
public struct DeckCap<Content: View>: View {
    var isPressed: Bool
    var content: Content

    public init(isPressed: Bool = false, @ViewBuilder content: () -> Content) {
        self.isPressed = isPressed
        self.content = content()
    }

    public var body: some View {
        content
            .labelStyle(.iconOnly)
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(Color.black.opacity(0.65))
            .shadow(color: .white.opacity(0.6), radius: 0, y: 0.8)
            .frame(width: 40, height: 40)
            .background {
                ZStack {
                    Circle().fill(Color.black.opacity(0.6)).padding(-2)
                    Textured(texture: .aluminum, brightness: isPressed ? 0.04 : 0.16)
                        .overlay(LinearGradient(colors: [.white.opacity(isPressed ? 0.1 : 0.35), .clear, .black.opacity(0.2)], startPoint: .top,
                                                endPoint: .bottom))
                        .clipShape(Circle())
                        .overlay(Circle().strokeBorder(LinearGradient(colors: [.white.opacity(0.8), .black.opacity(0.35)], startPoint: .top,
                                                                      endPoint: .bottom), lineWidth: 1))
                }
                .shadow(color: .black.opacity(isPressed ? 0.3 : 0.5), radius: isPressed ? 1 : 3, y: isPressed ? 1 : 2)
            }
            .contentShape(.circle)
    }
}

/// The cap for a label (buttons and menus alike).
public struct DeckChromeLabelStyle: LabelStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        DeckCap { configuration.icon }
    }
}

/// The cap for a button, pressed in while held.
public struct DeckChromeButtonStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        DeckCap(isPressed: configuration.isPressed) { configuration.label }
    }
}
