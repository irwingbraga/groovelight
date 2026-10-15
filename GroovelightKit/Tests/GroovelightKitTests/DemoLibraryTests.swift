import AVFAudio
import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import LibraryKit

/// Makes the demo library used for screenshots and tours: original albums (made-up artists, synthesized music,
/// generated covers, invented lyrics) in FLAC, ALAC and AAC, up to 24-bit / 192 kHz. Opt in with
/// `GL_DEMO_LIBRARY=/path/to/folder` (replaced if it exists).
struct DemoLibraryTests {
    static let folder = ProcessInfo.processInfo.environment["GL_DEMO_LIBRARY"]

    struct Album {
        var artist: String
        var title: String
        var year: Int
        var genre: String
        /// "flac", "alac" or "aac".
        var format: String
        var sampleRate: Double
        var bits: Int
        var songs: [String]
        /// Root note (MIDI), tempo, and the cover's two colors and pattern.
        var key: Int
        var tempo: Double
        var colors: (CGColor, CGColor)
        var pattern: Int
        var compilationArtists: [String]? = nil
    }

    static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGColor { CGColor(red: r, green: g, blue: b, alpha: 1) }

    static let albums: [Album] = [
        Album(artist: "Neon Arcade", title: "Afterglow", year: 2019, genre: "Synthwave", format: "flac", sampleRate: 96_000, bits: 24,
              songs: ["Afterglow", "Night Drive", "Chrome Sunset", "Pixel Hearts", "Last Arcade", "Outrun"],
              key: 45, tempo: 104, colors: (rgb(0.98, 0.25, 0.55), rgb(0.20, 0.05, 0.40)), pattern: 0),
        Album(artist: "Aurelia Quartet", title: "Hi-Res Sessions", year: 2024, genre: "Classical", format: "flac", sampleRate: 192_000, bits: 24,
              songs: ["Movement I: Dawn", "Movement II: River", "Movement III: Glass", "Movement IV: Home"],
              key: 50, tempo: 72, colors: (rgb(0.95, 0.85, 0.60), rgb(0.45, 0.30, 0.15)), pattern: 1),
        Album(artist: "Glass Harbor", title: "Lighthouse", year: 2002, genre: "Indie", format: "alac", sampleRate: 48_000, bits: 24,
              songs: ["Lighthouse", "Paper Boats", "Harbor Lights", "Salt and Silver", "Low Tide"],
              key: 52, tempo: 96, colors: (rgb(0.55, 0.80, 0.95), rgb(0.08, 0.20, 0.40)), pattern: 2),
        Album(artist: "Copper Sun", title: "Gold Rush FM", year: 1999, genre: "Rock", format: "aac", sampleRate: 44_100, bits: 16,
              songs: ["Gold Rush", "Desert Radio", "Copper Wire", "Highway 9", "Static Love"],
              key: 40, tempo: 128, colors: (rgb(0.95, 0.55, 0.15), rgb(0.40, 0.12, 0.05)), pattern: 3),
        Album(artist: "Velvet Static", title: "Chrome Hearts", year: 2011, genre: "Electronic", format: "flac", sampleRate: 44_100, bits: 16,
              songs: ["Chrome Hearts", "Velvet", "Signal Loss", "Mirror Ball", "Neon Rain", "Afterhours"],
              key: 48, tempo: 122, colors: (rgb(0.70, 0.70, 0.78), rgb(0.12, 0.12, 0.18)), pattern: 4),
        Album(artist: "Luna Drive", title: "Night Signals", year: 2016, genre: "Ambient", format: "alac", sampleRate: 44_100, bits: 16,
              songs: ["Night Signals", "Satellite", "Quiet Orbit", "Moonlight Relay"],
              key: 43, tempo: 70, colors: (rgb(0.30, 0.35, 0.85), rgb(0.03, 0.03, 0.15)), pattern: 5),
        Album(artist: "Saffron Skies", title: "Spice Route", year: 2008, genre: "World", format: "aac", sampleRate: 44_100, bits: 16,
              songs: ["Spice Route", "Caravan", "Marrakesh Blue", "Silk Road", "Saffron"],
              key: 47, tempo: 100, colors: (rgb(0.98, 0.75, 0.20), rgb(0.70, 0.20, 0.10)), pattern: 0),
        Album(artist: "Polar Tides", title: "Deep Blue", year: 2021, genre: "Ambient", format: "flac", sampleRate: 48_000, bits: 24,
              songs: ["Deep Blue", "Ice Shelf", "Aurora Line", "Whale Song"],
              key: 41, tempo: 66, colors: (rgb(0.30, 0.85, 0.85), rgb(0.02, 0.15, 0.30)), pattern: 1),
        Album(artist: "Midnight Bloom", title: "Hollow Moon", year: 2014, genre: "Dream Pop", format: "flac", sampleRate: 44_100, bits: 16,
              songs: ["Hollow Moon", "Petals", "Slow Bloom", "Velvet Night", "Fade"],
              key: 49, tempo: 88, colors: (rgb(0.80, 0.45, 0.85), rgb(0.15, 0.05, 0.25)), pattern: 2),
        Album(artist: "Static Season", title: "Winter Radio", year: 1987, genre: "New Wave", format: "aac", sampleRate: 44_100, bits: 16,
              songs: ["Winter Radio", "Cold Wave", "Frequency", "Snow on the Dial"],
              key: 46, tempo: 118, colors: (rgb(0.85, 0.90, 0.95), rgb(0.25, 0.35, 0.50)), pattern: 3),
        Album(artist: "Echo Valley", title: "Canyon Songs", year: 1974, genre: "Folk", format: "flac", sampleRate: 44_100, bits: 16,
              songs: ["Canyon Song", "Red Rock", "Campfire", "River Bend"],
              key: 44, tempo: 92, colors: (rgb(0.85, 0.55, 0.35), rgb(0.30, 0.15, 0.10)), pattern: 4),
        Album(artist: "Various Artists", title: "Summer Mixtape", year: 2020, genre: "Pop", format: "flac", sampleRate: 44_100, bits: 16,
              songs: ["Sunburn", "Pool Party", "Lemonade", "Golden Hour", "Ocean Air"],
              key: 51, tempo: 112, colors: (rgb(1.00, 0.85, 0.30), rgb(0.95, 0.35, 0.40)), pattern: 5,
              compilationArtists: ["Coral Club", "The Tangerines", "Mila Rae", "Sunday Static", "Beach Radio"]),
    ]

    /// Made-up lyrics (synced) for a few songs: (album title, song number) -> lines.
    static let lyrics: [String: [String]] = [
        "Afterglow#1": ["City lights are fading out", "We're chasing the last of the sun", "Turn it up, the night is young",
                        "Afterglow, afterglow", "Hold on to the neon glow", "Afterglow, don't let me go",
                        "Streets are humming like a song", "We've been driving all night long"],
        "Lighthouse#1": ["Out where the water meets the sky", "A little light keeps turning round", "Calling every boat back home",
                         "Lighthouse, lighthouse", "Shine a little longer now", "Lighthouse, lighthouse", "Guide me back somehow"],
        "Hollow Moon#1": ["Under a hollow moon", "We danced in the quiet room", "Petals on the floor",
                          "Nothing left to wait for", "Hollow moon, hollow moon", "Stay a little longer soon"],
    ]

    @Test(.enabled(if: folder != nil), .timeLimit(.minutes(20))) func makeDemoLibrary() throws {
        let root = URL(fileURLWithPath: Self.folder!, isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for album in Self.albums {
            let folder = root.appendingPathComponent(album.artist).appendingPathComponent(album.title)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let cover = try #require(Self.cover(album))
            for (index, title) in album.songs.enumerated() {
                let number = index + 1
                let ext = album.format == "flac" ? "flac" : "m4a"
                let url = folder.appendingPathComponent(String(format: "%02d %@.%@", number, title, ext))
                // Hi-res songs are shorter, so the library stays small.
                let seconds = album.sampleRate > 48_000 ? 24.0 : 40.0 + Double(number * 3)
                try Self.writeSong(url: url, album: album, number: number, seconds: seconds)
                let artist = album.compilationArtists?[index % album.compilationArtists!.count] ?? album.artist
                let lyrics = Self.lyrics["\(album.title)#\(number)"].map { Self.lrc($0, seconds: seconds) }
                try TagWriter.write(TrackMetadata(title: title, artist: artist, album: album.title,
                                                  albumArtist: album.compilationArtists == nil ? album.artist : "Various Artists",
                                                  genre: album.genre, year: album.year, trackNumber: number, trackTotal: album.songs.count,
                                                  discNumber: 1, discTotal: 1, isCompilation: album.compilationArtists != nil),
                                    lyrics: lyrics, frontCover: cover, to: url)
            }
        }
        let count = FileManager.default.enumerator(atPath: root.path)?.compactMap { $0 as? String }.filter { $0.hasSuffix(".flac") || $0.hasSuffix(".m4a") }.count
        #expect(count == Self.albums.reduce(0) { $0 + $1.songs.count })
    }

    /// Lines spread over the song, starting a few seconds in.
    static func lrc(_ lines: [String], seconds: Double) -> String {
        let step = (seconds - 6) / Double(lines.count)
        return lines.enumerated().map { index, line in
            let time = 4 + Double(index) * step
            return String(format: "[%02d:%05.2f]%@", Int(time) / 60, time.truncatingRemainder(dividingBy: 60), line)
        }.joined(separator: "\n")
    }

    // MARK: - Music

    /// A short piece: a four-chord progression (pads), a bass line, a kick and hi-hats, in stereo.
    static func writeSong(url: URL, album: Album, number: Int, seconds: Double) throws {
        let rate = album.sampleRate
        let frames = Int(seconds * rate)
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        let left = buffer.floatChannelData![0], right = buffer.floatChannelData![1]
        // Progressions in scale degrees (semitones from the root), one per song.
        let progressions: [[[Int]]] = [
            [[0, 4, 7], [9, 12, 16], [5, 9, 12], [7, 11, 14]],
            [[0, 3, 7], [8, 12, 15], [3, 7, 10], [10, 14, 17]],
            [[0, 4, 7, 11], [5, 9, 12, 16], [2, 5, 9, 12], [7, 11, 14, 17]],
            [[0, 3, 7, 10], [5, 8, 12, 15], [7, 10, 14, 17], [3, 7, 10, 14]],
        ]
        let progression = progressions[(number + album.pattern) % progressions.count]
        let beat = 60 / album.tempo
        let bar = beat * 4
        func frequency(_ midi: Int) -> Double { 440 * pow(2, Double(midi - 69) / 12) }
        var seed: UInt64 = UInt64(album.key * 1_000 + number)
        func noise() -> Float {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Float(Int64(bitPattern: seed >> 11) % 2_000_000) / 1_000_000 - 1
        }
        for frame in 0..<frames {
            let t = Double(frame) / rate
            let chord = progression[Int(t / bar) % progression.count]
            let inBar = t.truncatingRemainder(dividingBy: bar)
            let inBeat = t.truncatingRemainder(dividingBy: beat)
            // Pads: the chord an octave up, soft attack per bar.
            var pad = 0.0
            for (voice, degree) in chord.enumerated() {
                let f = frequency(album.key + 12 + degree)
                pad += sin(2 * .pi * f * t + Double(voice)) * (0.5 + 0.5 * sin(2 * .pi * 0.25 * t + Double(voice)))
            }
            pad *= 0.06 * min(inBar / 0.4, 1)
            // Bass on the root, eighth notes.
            let eighth = beat / 2
            let bassEnvelope = exp(-t.truncatingRemainder(dividingBy: eighth) * 6)
            let bass = sin(2 * .pi * frequency(album.key + chord[0] - 12) * t) * 0.22 * bassEnvelope
            // Kick on every beat, hi-hat on the off-beats.
            let kick = sin(2 * .pi * (50 + 90 * exp(-inBeat * 30)) * inBeat) * exp(-inBeat * 9) * 0.45
            let offBeat = (inBeat - beat / 2)
            let hat = offBeat >= 0 ? Double(noise()) * exp(-offBeat * 45) * 0.06 : 0
            // Fade in and out.
            let fade = min(t / 1.5, 1) * min((seconds - t) / 2.5, 1)
            let pan = 0.5 + 0.3 * sin(2 * .pi * 0.1 * t)
            let mono = (bass + kick) * fade
            left[frame] = Float(mono + (pad * (1 - pan) + hat * 0.6) * fade)
            right[frame] = Float(mono + (pad * pan + hat * 0.4) * fade)
        }
        var settings: [String: Any] = [AVSampleRateKey: rate, AVNumberOfChannelsKey: 2]
        switch album.format {
        case "flac":
            settings[AVFormatIDKey] = kAudioFormatFLAC
            settings[AVEncoderBitDepthHintKey] = album.bits
        case "alac":
            settings[AVFormatIDKey] = kAudioFormatAppleLossless
            settings[AVEncoderBitDepthHintKey] = album.bits
        default:
            settings[AVFormatIDKey] = kAudioFormatMPEG4AAC
            settings[AVEncoderBitRateKey] = 256_000
        }
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
    }

    // MARK: - Covers

    /// A 1200 px cover: a diagonal gradient and one of six patterns (circles, stripes, rings, grid, waves, sun).
    static func cover(_ album: Album) -> Data? {
        let size = 1200
        guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [album.colors.0, album.colors.1] as CFArray,
                                        locations: [0, 1]) else { return nil }
        let s = CGFloat(size)
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: s), end: CGPoint(x: s, y: 0), options: [])
        let light = CGColor(red: 1, green: 1, blue: 1, alpha: 0.22)
        let dark = CGColor(red: 0, green: 0, blue: 0, alpha: 0.18)
        context.setLineWidth(10)
        switch album.pattern {
        case 0:
            for i in 0..<9 {
                context.setStrokeColor(i % 2 == 0 ? light : dark)
                context.strokeEllipse(in: CGRect(x: s / 2 - CGFloat(i) * 70, y: s * 0.35 - CGFloat(i) * 70, width: CGFloat(i) * 140, height: CGFloat(i) * 140))
            }
        case 1:
            context.setFillColor(light)
            for i in stride(from: 0, to: size, by: 80) { context.fill(CGRect(x: CGFloat(i), y: 0, width: 30, height: s)) }
        case 2:
            context.setFillColor(light)
            context.fillEllipse(in: CGRect(x: s * 0.25, y: s * 0.4, width: s * 0.5, height: s * 0.5))
            context.setFillColor(dark)
            for i in 0..<6 { context.fill(CGRect(x: 0, y: s * 0.12 + CGFloat(i) * 60, width: s, height: 18)) }
        case 3:
            context.setStrokeColor(light)
            for i in stride(from: 0, through: size, by: 100) {
                context.move(to: CGPoint(x: CGFloat(i), y: 0)); context.addLine(to: CGPoint(x: CGFloat(i), y: s))
                context.move(to: CGPoint(x: 0, y: CGFloat(i))); context.addLine(to: CGPoint(x: s, y: CGFloat(i)))
            }
            context.strokePath()
        case 4:
            context.setStrokeColor(light)
            for row in 0..<12 {
                context.move(to: CGPoint(x: 0, y: CGFloat(row) * 100 + 50))
                for x in stride(from: 0, through: size, by: 20) {
                    context.addLine(to: CGPoint(x: CGFloat(x), y: CGFloat(row) * 100 + 50 + 30 * sin(CGFloat(x) / 90 + CGFloat(row))))
                }
            }
            context.strokePath()
        default:
            context.setFillColor(CGColor(red: 1, green: 0.95, blue: 0.8, alpha: 0.85))
            context.fillEllipse(in: CGRect(x: s * 0.3, y: s * 0.45, width: s * 0.4, height: s * 0.4))
            context.setFillColor(dark)
            for i in 0..<7 { context.fill(CGRect(x: 0, y: s * 0.18 + CGFloat(i) * 45, width: s, height: 12 + CGFloat(i) * 3)) }
        }
        guard let image = context.makeImage() else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? data as Data : nil
    }
}
