import AppKit
import AVFAudio
import Foundation
import GRDB
import SFBAudioEngine
import Testing
@testable import LibraryKit

/// Generates real audio files in several formats, tags them, scans them and checks the library.
struct ScannerIntegrationTests {
    static func makeFixtures(in directory: URL) throws -> [URL] {
        let album = directory.appendingPathComponent("Test Artist/Fixture Album", isDirectory: true)
        try FileManager.default.createDirectory(at: album, withIntermediateDirectories: true)

        // 1 s, 440 Hz stereo sine as the source WAV.
        let source = directory.appendingPathComponent("source.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100)!
        buffer.frameLength = 44_100
        for channel in 0..<2 {
            for i in 0..<44_100 { buffer.floatChannelData![channel][i] = 0.3 * sin(2 * .pi * 440 * Float(i) / 44_100) }
        }
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 2,
                                       AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false]
        do {
            let file = try AVAudioFile(forWriting: source, settings: settings)
            try file.write(from: buffer)
        }

        let conversions: [(String, [String])] = [
            ("01 Wave.wav", ["-f", "WAVE", "-d", "LEI16"]),
            ("02 Aiff.aiff", ["-f", "AIFF", "-d", "BEI16"]),
            ("03 Alac.m4a", ["-f", "m4af", "-d", "alac"]),
            ("04 Aac.m4a", ["-f", "m4af", "-d", "aac", "-b", "128000"]),
            ("05 Flac.flac", ["-f", "flac", "-d", "flac"]),
        ]
        var outputs: [URL] = []
        for (name, arguments) in conversions {
            let output = album.appendingPathComponent(name)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
            process.arguments = arguments + [source.path, output.path]
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 { outputs.append(output) }
        }
        try FileManager.default.removeItem(at: source)
        return outputs
    }

    static func pngData() -> Data {
        let image = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
            NSColor.systemPink.setFill()
            rect.fill()
            return true
        }
        let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
        return rep.representation(using: .png, properties: [:])!
    }

    @Test func scansTaggedFilesInEveryFormat() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("groovelight-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = try Self.makeFixtures(in: directory)
        #expect(files.count >= 4, "afconvert should produce at least WAV, AIFF, ALAC and AAC")

        // Tag every file except the WAV (left untagged to test the file name fallback).
        for (index, url) in files.enumerated() where url.pathExtension != "wav" {
            let file = try AudioFile(readingPropertiesAndMetadataFrom: url)
            file.metadata.title = "Song \(index + 1)"
            file.metadata.artist = "Test Artist"
            file.metadata.albumTitle = "Fixture Album"
            // SFBAudioEngine's ID3v2 writer (MP3/AIFF/WAV) silently drops dates that are not full ISO 8601 timestamps.
            file.metadata.releaseDate = "2001-05-04T00:00:00Z"
            file.metadata.trackNumber = index + 1
            file.metadata.genre = "Electronic"
            if index == 2 {
                file.metadata.attachPicture(AttachedPicture(imageData: Self.pngData(), type: .frontCover, description: nil))
            }
            try file.writeMetadata()
        }

        let database = try LibraryDatabase.inMemory()
        let artwork = try ArtworkCache(directory: directory.appendingPathComponent("Artwork"))
        let root = try database.addRoot(path: directory.appendingPathComponent("Test Artist").path, bookmark: Data())
        let scanner = LibraryScanner(database: database, artwork: artwork)

        let first = try await scanner.scan(root: root)
        #expect(first.added == files.count)
        #expect(first.failed.isEmpty)

        let tracks = try await database.writer.read { try Track.order(Column("path")).fetchAll($0) }
        #expect(tracks.count == files.count)
        for track in tracks {
            #expect(track.duration > 0.9 && track.duration < 1.2, "\(track.path) duration \(track.duration)")
            #expect(track.sampleRate == 44_100)
        }
        let wav = try #require(tracks.first { $0.path.hasSuffix(".wav") })
        #expect(wav.title == "01 Wave")
        let tagged = tracks.filter { !$0.path.hasSuffix(".wav") }
        for track in tagged {
            #expect(track.artist == "Test Artist" && track.year == 2001 && track.album == "Fixture Album",
                    "\(URL(fileURLWithPath: track.path).lastPathComponent): \(String(describing: track.artist)) \(String(describing: track.year)) \(String(describing: track.album))")
        }
        #expect(tracks.contains { $0.artworkHash != nil })
        if let hash = tracks.compactMap(\.artworkHash).first {
            #expect(FileManager.default.fileExists(atPath: artwork.url(for: hash, size: .small).path))
        }

        // Second scan: nothing changed.
        let second = try await scanner.scan(root: root)
        #expect(second.unchanged == files.count && second.added == 0 && second.updated == 0)

        // Delete one file: it disappears from the library.
        try FileManager.default.removeItem(at: files[0])
        let third = try await scanner.scan(root: root)
        #expect(third.removed == 1)
    }

    @Test func decodesEveryFixtureFormat() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("groovelight-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        for url in try Self.makeFixtures(in: directory) {
            let decoder = try AudioDecoder(url: url)
            try decoder.open()
            let buffer = AVAudioPCMBuffer(pcmFormat: decoder.processingFormat, frameCapacity: 4096)!
            try decoder.decode(into: buffer, length: 4096)
            #expect(buffer.frameLength > 0, "\(url.lastPathComponent) decoded no frames")
        }
    }
}
