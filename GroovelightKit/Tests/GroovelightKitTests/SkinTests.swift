import AppKit
import Foundation
import SwiftUI
import AVFAudio
import PlayerCore
import Testing
@testable import Skins

@MainActor
struct SkinTests {
    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "SkinTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func colorsReadAndWriteAsHex() {
        #expect(HexColor("#FF8000").hex == "#FF8000")
        #expect(HexColor("ff800080").alpha > 0.49)
        #expect(HexColor("#FF800080").hex == "#FF800080")
        #expect(HexColor.parse("#12") == nil)
        #expect(HexColor.parse("#GGGGGG") == nil)
    }

    @Test func designsRoundTrip() throws {
        for design in CassetteDesign.builtIn {
            let data = try JSONEncoder().encode(design)
            #expect(try JSONDecoder().decode(CassetteDesign.self, from: data) == design)
        }
    }

    /// A design written by hand with only some fields opens, the rest from the classic one, the clarity kept in range.
    @Test func handWrittenDesignsOpen() throws {
        let json = ##"{"name": "Mine", "shellColor": "#00FF00", "shellClarity": 3, "label": {"background": "#FFFFFF"}, "someday": true}"##
        let design = try JSONDecoder().decode(CassetteDesign.self, from: Data(json.utf8))
        #expect(design.name == "Mine")
        #expect(design.shellColor == HexColor("#00FF00"))
        #expect(design.shellClarity == 0.8)
        #expect(design.label.background == HexColor("#FFFFFF"))
        #expect(design.label.showsText)
        #expect(design.reels == CassetteDesign.classic.reels)
        #expect(design.resolvedGeometry == .standard)
    }

    @Test func storeSavesDuplicatesAndDeletes() throws {
        let store = CassetteStore(folder: try temporaryFolder())
        #expect(store.custom.isEmpty)
        #expect(throws: CassetteStore.StoreError.self) { try store.save(.classic) }
        var copy = try store.duplicate(.classic, name: "My Tape")
        #expect(store.custom.map(\.name) == ["My Tape"])
        copy.brand = "MINE"
        try store.save(copy)
        #expect(store.design(id: copy.id).brand == "MINE")
        try store.delete(copy)
        #expect(store.custom.isEmpty)
        // A deleted choice falls back to the first built-in design.
        #expect(store.design(id: copy.id) == CassetteDesign.builtIn[0])
    }

    /// A design exported as a folder with its picture imports elsewhere, with the picture; imported again where it is,
    /// it comes in as a copy.
    @Test func designsTravelAsFolders() throws {
        let store = CassetteStore(folder: try temporaryFolder())
        let design = try store.duplicate(.chrome, name: "Shared")
        let picture = try temporaryFolder().appending(path: "shell.png")
        try Self.png(width: 100, height: 64).write(to: picture)
        let withPicture = try store.setPicture(.shell, from: picture, in: design)
        #expect(store.url(of: .shell, in: withPicture) != nil)

        let exported = try store.export(withPicture, to: try temporaryFolder())
        #expect(exported.lastPathComponent == "Shared.cassette")

        let other = CassetteStore(folder: try temporaryFolder())
        let imported = try other.importDesign(from: exported)
        #expect(imported.id == withPicture.id)
        #expect(other.url(of: .shell, in: imported) != nil)

        let again = try store.importDesign(from: exported.appending(path: CassetteStore.fileName))
        #expect(again.id != withPicture.id)
        #expect(store.custom.count == 2)

        #expect(throws: CassetteStore.StoreError.self) { try other.importDesign(from: try temporaryFolder()) }
    }

    /// The tape goes from the left reel to the right over the song, and the right reel turns slower as it fills.
    @Test func reelsWindTheTape() {
        let layout = CassetteGeometry.standard
        func state(_ time: TimeInterval) -> ReelState {
            ReelState(layout: layout, width: 1000, playback: SkinPlayback(title: "", artist: "", isPlaying: true, duration: 200) { _ in time }, date: .now)
        }
        let start = state(0), middle = state(100), end = state(200)
        #expect(start.leftRadius > start.rightRadius)
        #expect(abs(end.leftRadius - start.rightRadius) < 0.001)
        #expect(abs(end.rightRadius - start.leftRadius) < 0.001)
        // At the start the bare right hub turns half a turn a second.
        let early = state(1)
        #expect(abs(early.rightAngle.radians - .pi) < 0.05)
        // Later, a full right reel turns slower than the near-bare left one.
        let late = state(199), last = state(200)
        #expect(last.rightAngle.radians - late.rightAngle.radians < last.leftAngle.radians - late.leftAngle.radians)
        #expect(middle.rightAngle.radians > start.rightAngle.radians)
    }

    /// Each skin draws something (and with `GL_SNAPSHOT_DIR` set, is written there as a PNG to look at).
    @Test func skinsRender() throws {
        let snapshots = ProcessInfo.processInfo.environment["GL_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0) }
        let playback = SkinPlayback(title: "Living Inside Myself", artist: "Gino Vannelli", isPlaying: true, duration: 240) { _ in 70 }
        var cases: [(String, NowPlayingSkin, CassetteDesign)] = [("vinyl", .vinyl, .classic), ("cd", .compactDisc, .classic)]
        cases += CassetteDesign.builtIn.map { ("cassette-\($0.name.lowercased())", .cassette, $0) }
        for (name, skin, design) in cases {
            let view = SkinView(skin: skin, playback: playback, cassette: design) {
                LinearGradient(colors: [.orange, .purple], startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            .frame(width: 600, height: 600)
            .background(Color(white: 0.2))
            let renderer = ImageRenderer(content: view)
            // As on a Retina screen, where the textures and the foil are drawn at their finest.
            renderer.scale = 2
            let image = try #require(renderer.cgImage)
            #expect(image.width == 1200)
            if let snapshots {
                let rep = NSBitmapImageRep(cgImage: image)
                try rep.representation(using: .png, properties: [:])?.write(to: snapshots.appending(path: "skin-\(name).png"))
            }
        }
    }

    /// The player and its panel: one above the other on a phone and an open foldable, side by side on a Mac window,
    /// and on either side of an iPhone Duo's fold while it divides the screen.
    @Test func decksFollowTheScreenAndTheFold() {
        let phone = DeckRegions(size: CGSize(width: 393, height: 852), top: 60, fold: nil)
        #expect(phone.panel.minY > phone.stage.maxY)
        let open = DeckRegions(size: CGSize(width: 720, height: 800), top: 60, fold: nil)
        #expect(open.panel.minY > open.stage.maxY)
        let mac = DeckRegions(size: CGSize(width: 1100, height: 760), top: 60, fold: nil)
        #expect(mac.panel.minX > mac.stage.maxX)
        // Partly folded like a book: each on its side of the fold, none in it.
        let fold = CGRect(x: 440, y: 0, width: 30, height: 900)
        let book = DeckRegions(size: CGSize(width: 910, height: 900), top: 60, fold: fold)
        #expect(book.stage.maxX <= fold.minX && book.panel.minX >= fold.maxX)
        // Partly folded like a laptop: the player above, the controls below.
        let level = CGRect(x: 0, y: 430, width: 900, height: 30)
        let laptop = DeckRegions(size: CGSize(width: 900, height: 900), top: 60, fold: level)
        #expect(laptop.stage.maxY <= level.minY && laptop.panel.minY >= level.maxY)
    }

    /// The VU meters read the music's level: silence rests, -12 dBFS is 0 VU, louder goes into the red; and the needle
    /// takes a VU meter's 300 ms to get there.
    @Test func vuMetersFollowTheLevel() {
        #expect(VUMeter.position(rms: 0) == 0)
        #expect(abs(VUMeter.position(rms: pow(10, -12.0 / 20)) - 0.78) < 0.001)
        #expect(VUMeter.position(rms: pow(10, -22.0 / 20)) < VUMeter.position(rms: pow(10, -15.0 / 20)))
        #expect(VUMeter.position(rms: 1) > 1)
        let needle = VUNeedle()
        let start = Date.now
        _ = needle.position(toward: 0, at: start)
        var position = 0.0
        for step in 1...30 { position = needle.position(toward: 0.78, at: start.addingTimeInterval(Double(step) * 0.01)) }
        #expect(abs(position - 0.78) < 0.01)
        let early = VUNeedle()
        _ = early.position(toward: 0, at: start)
        #expect(early.position(toward: 0.78, at: start.addingTimeInterval(0.05)) < 0.6)
    }

    /// Gold and silver foil are kept in the file, and a finish this version does not know reads as plain ink.
    @Test func foilFinishesReadAndWrite() throws {
        let data = try JSONEncoder().encode(CassetteDesign.blackGold)
        let read = try JSONDecoder().decode(CassetteDesign.self, from: data)
        #expect(read.label.textFinish == .gold)
        #expect(read.reels.ringFinish == .gold)
        #expect(read.label.bands.first?.finish == .gold)
        #expect(read.label.bands[1].finish == nil)
        let later = ##"{"name": "Later", "label": {"textFinish": "copper", "bands": [{"color": "#FFFFFF", "y": 0.5, "height": 0.1, "finish": "rose"}]}, "reels": {"hubColor": "#FFFFFF", "tapeColor": "#000000", "ringFinish": "copper"}}"##
        let design = try JSONDecoder().decode(CassetteDesign.self, from: Data(later.utf8))
        #expect(design.label.textFinish == nil)
        #expect(design.label.bands.count == 1 && design.label.bands[0].finish == nil)
        #expect(design.reels.ringFinish == nil)
        #expect(!String(decoding: try JSONEncoder().encode(CassetteDesign.classic), as: UTF8.self).contains("Finish"))
    }

    /// The PC Player shows a lossless file's PCM bit rate (1411 for a CD) and a lossy one's own; its windows dock one
    /// under the other, the main window at the original's proportions, and part on either side of a fold.
    @Test func pcPlayerFormatAndLayout() {
        let cd = SkinFormat(sampleRate: 44_100, bitDepth: 16, bitrate: nil, channels: 2)
        #expect(cd.kbps == 1411 && cd.kHz == 44 && cd.channels == 2)
        let mp3 = SkinFormat(sampleRate: 48_000, bitDepth: nil, bitrate: 320, channels: 2)
        #expect(mp3.kbps == 320 && mp3.kHz == 48)
        let phone = PCLayout(size: CGSize(width: 393, height: 852), top: 60, fold: nil)
        #expect(abs(phone.main.width / phone.main.height - 275.0 / 116) < 0.001)
        #expect(phone.playlist.minY == phone.main.maxY && phone.playlist.width == phone.main.width)
        #expect(phone.main.minX >= 0 && phone.main.maxX <= 393)
        let duo = PCLayout(size: CGSize(width: 900, height: 700), top: 40, fold: CGRect(x: 440, y: 0, width: 20, height: 700))
        #expect(duo.main.maxX <= 440 && duo.playlist.minX >= 460)
    }

    /// Corona puts its playlist under the player on a phone and on its left on a wide screen, as it slid out; its
    /// screen gives room to the playlist but stays between 120 and 240 of its pixels.
    @Test func coronaLayout() {
        let phone = CoronaLayout(size: CGSize(width: 393, height: 852), top: 60, fold: nil)
        #expect(phone.playlist.minY >= phone.main.maxY && (120...240).contains(phone.screenHeight))
        #expect(phone.main.minX >= 0 && phone.main.maxX <= 393)
        let mac = CoronaLayout(size: CGSize(width: 1100, height: 760), top: 60, fold: nil)
        #expect(mac.playlist.maxX <= mac.main.minX + 13 * mac.scale + 0.5 && mac.screenHeight == 240)
        let duo = CoronaLayout(size: CGSize(width: 900, height: 700), top: 40, fold: CGRect(x: 440, y: 0, width: 20, height: 700))
        #expect(duo.playlist.maxX <= 440 && duo.main.minX >= 460)
    }

    /// The record and the disc turn from the clock: up to speed smoothly when they start, coasting to a stop when they
    /// stop, never jumping.
    @Test func motorsSpeedUpAndSlowDown() {
        let start = Date.now
        var motion = SpinMotion(speed: 300, spinUp: 1.5, spinDown: 2, isOn: false)
        motion.turn(true, at: start)
        #expect(motion.state(at: start).velocity == 0)
        #expect(abs(motion.state(at: start.addingTimeInterval(0.75)).velocity - 150) < 0.001)
        #expect(motion.state(at: start.addingTimeInterval(1.5)).velocity == 300)
        // Smoothstep's integral: half the full speed's turning over the spin-up.
        #expect(abs(motion.state(at: start.addingTimeInterval(1.5)).angle - 225) < 0.001)
        #expect(abs(motion.state(at: start.addingTimeInterval(2.5)).angle - 525) < 0.001)
        // Stopping halfway through stopping keeps the angle and the speed where they were.
        let stop = start.addingTimeInterval(2.5)
        motion.turn(false, at: stop)
        #expect(abs(motion.state(at: stop).angle - 165) < 0.001)
        #expect(motion.state(at: stop).velocity == 300)
        #expect(motion.isTurning(at: stop.addingTimeInterval(1.9)))
        #expect(!motion.isTurning(at: stop.addingTimeInterval(2.01)))
        var last = motion.state(at: stop).angle
        for step in 1...30 {
            let angle = motion.state(at: stop.addingTimeInterval(Double(step) * 0.1)).angle
            #expect(angle >= last)
            last = angle
        }
        #expect(abs(last - (165 + 300)) < 0.001)
    }

    /// The analyzer measures each channel on its own, for the VU meters.
    @Test func analyzerMeasuresEachChannel() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
        buffer.frameLength = 1024
        for frame in 0..<1024 {
            buffer.floatChannelData![0][frame] = 0.5
            buffer.floatChannelData![1][frame] = 0.1
        }
        let analyzer = SpectrumAnalyzer()
        analyzer.process(buffer)
        #expect(abs(analyzer.latestFrame.leftLevel - 0.5) < 0.001)
        #expect(abs(analyzer.latestFrame.rightLevel - 0.1) < 0.001)
    }

    /// Each player fills screens of every shape: a phone, a foldable's narrow outer screen and its open one (near
    /// square), and a Mac window (with `GL_SNAPSHOT_DIR` set, written there as PNGs).
    @Test func decksRender() throws {
        let snapshots = ProcessInfo.processInfo.environment["GL_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0) }
        let playback = SkinPlayback(title: "Living Inside Myself", artist: "Gino Vannelli", album: "Nightwalker", isPlaying: true,
                                    duration: 240, format: SkinFormat(kbps: 320, kHz: 44, channels: 2)) { _ in 70 }
        let playlist = SkinPlaylist(entries: [("Gino Vannelli", "Living Inside Myself", 260.0), ("Toto", "Rosanna", 331), ("Steely Dan", "Peg", 237),
                                              ("Christopher Cross", "Sailing", 255), ("Michael McDonald", "I Keep Forgettin'", 220),
                                              ("Kenny Loggins", "This Is It", 229)].map { .init(title: $0.1, artist: $0.0, duration: $0.2) },
                                    current: 0)
        let screens: [(String, CGSize)] = [("phone", CGSize(width: 393, height: 852)), ("cover", CGSize(width: 344, height: 882)),
                                           ("open", CGSize(width: 720, height: 800)), ("mac", CGSize(width: 1100, height: 760))]
        defer { UserDefaults.standard.removeObject(forKey: NowPlayingSkin.pcThemeStorageKey) }
        for (skin, theme) in [(NowPlayingSkin.vinyl, PCTheme.classic), (.cassette, .classic), (.compactDisc, .classic), (.pcPlayer, .classic),
                              (.pcPlayer, .corona)] {
            UserDefaults.standard.set(theme.rawValue, forKey: NowPlayingSkin.pcThemeStorageKey)
            for (name, size) in screens {
                let view = SkinDeck(skin: skin, playback: playback, controls: .inert, cassette: .mixtape, playlist: playlist) {
                    LinearGradient(colors: [.orange, .purple], startPoint: .topLeading, endPoint: .bottomTrailing)
                } accessory: {
                    EmptyView()
                }
                .frame(width: size.width, height: size.height)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                let image = try #require(renderer.cgImage)
                #expect(image.width == Int(size.width * 2))
                if let snapshots {
                    let rep = NSBitmapImageRep(cgImage: image)
                    try rep.representation(using: .png, properties: [:])?.write(to: snapshots.appending(path: "deck-\(skin.rawValue)\(theme == .corona ? "-corona" : "")-\(name).png"))
                }
            }
        }
    }

    static func png(width: Int, height: Int) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        return rep.representation(using: .png, properties: [:])!
    }
}
