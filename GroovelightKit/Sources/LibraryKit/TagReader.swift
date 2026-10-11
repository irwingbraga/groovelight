import Foundation
import SFBAudioEngine

/// Tags and audio properties read from one file.
public struct FileTags: Sendable, Equatable {
    public var title: String?
    public var artist: String?
    public var album: String?
    public var albumArtist: String?
    public var composer: String?
    public var genre: String?
    public var year: Int?
    public var trackNumber: Int?
    public var trackTotal: Int?
    public var discNumber: Int?
    public var discTotal: Int?
    public var isCompilation: Bool = false
    public var bpm: Int?
    public var comment: String?
    public var lyrics: String?
    public var musicBrainzRecordingId: String?
    public var musicBrainzReleaseId: String?
    public var replayGainTrackGain: Double?
    public var replayGainAlbumGain: Double?

    public var duration: Double = 0
    public var format: String?
    public var sampleRate: Double?
    public var bitDepth: Int?
    public var bitrate: Double?
    public var channels: Int?

    /// Embedded front cover (or first picture) bytes.
    public var artwork: Data?
    /// A cue sheet stored in the file (the CUESHEET tag of FLAC, Ogg, APE and WavPack files).
    public var cueSheet: String?

    public init() {}
}

public enum TagReader {
    public static var supportedExtensions: Set<String> {
        Set(AudioFile.supportedPathExtensions.map { $0.lowercased() })
    }

    public static func read(_ url: URL) throws -> FileTags {
        let file = try AudioFile(readingPropertiesAndMetadataFrom: url)
        let metadata = file.metadata
        let properties = file.properties
        var tags = FileTags()
        // Some formats keep a removed text tag as an empty string: treat empty as missing.
        func text(_ value: String?) -> String? {
            guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return value
        }
        tags.title = text(metadata.title)
        tags.artist = text(metadata.artist)
        tags.album = text(metadata.albumTitle)
        tags.albumArtist = text(metadata.albumArtist)
        tags.composer = text(metadata.composer)
        tags.genre = text(metadata.genre)
        tags.year = parseYear(metadata.releaseDate)
        tags.trackNumber = metadata.trackNumber
        tags.trackTotal = metadata.trackTotal
        tags.discNumber = metadata.discNumber
        tags.discTotal = metadata.discTotal
        tags.isCompilation = metadata.isCompilation ?? false
        tags.bpm = metadata.bpm
        tags.comment = text(metadata.comment)
        tags.lyrics = text(metadata.lyrics)
        tags.musicBrainzRecordingId = text(metadata.musicBrainzRecordingID)
        tags.musicBrainzReleaseId = text(metadata.musicBrainzReleaseID)
        tags.replayGainTrackGain = metadata.replayGainTrackGain
        tags.replayGainAlbumGain = metadata.replayGainAlbumGain

        tags.duration = properties.duration ?? 0
        tags.format = properties.formatName
        tags.sampleRate = properties.sampleRate
        tags.bitDepth = properties.bitDepth
        tags.bitrate = properties.bitrate
        tags.channels = properties.channelCount.map(Int.init)

        if let extra = metadata.additionalMetadata {
            tags.cueSheet = extra.first { ($0.key as? String)?.uppercased() == "CUESHEET" }?.value as? String
        }
        let pictures = metadata.attachedPictures
        let front = pictures.first { $0.type == .frontCover } ?? pictures.first
        tags.artwork = front?.imageData
        return tags
    }

    /// Accepts "1999", "1999-03-02", "1999-03-02T00:00:00Z", "03/02/1999".
    static func parseYear(_ value: String?) -> Int? {
        guard let value else { return nil }
        var digits = ""
        for character in value {
            if character.isNumber {
                digits.append(character)
                if digits.count == 4, let year = Int(digits), (1000...2999).contains(year) { return year }
            } else {
                digits = ""
            }
        }
        return nil
    }
}
