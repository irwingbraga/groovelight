import Foundation
import SFBAudioEngine

/// Writes metadata fixes, lyrics and cover art into audio files.
public enum TagWriter {
    public struct Result: Sendable {
        public var fileSize: Int64
        public var modifiedAt: Date
    }

    /// Writes the fields set in `metadata` (others are left untouched), plus optional lyrics and front cover.
    /// Returns the file's new size and modification date.
    @discardableResult
    public static func write(_ metadata: TrackMetadata, lyrics: String? = nil, frontCover: Data? = nil, to url: URL) throws -> Result {
        let file = try AudioFile(readingPropertiesAndMetadataFrom: url)
        let tags = file.metadata
        // Set fields are written; an empty string or 0 removes the tag.
        func text(_ value: String?) -> String?? {
            guard let value else { return .none }
            return .some(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value)
        }
        func number(_ value: Int?) -> Int?? {
            guard let value else { return .none }
            return .some(value == 0 ? nil : value)
        }
        if let value = text(metadata.title) { tags.title = value }
        if let value = text(metadata.artist) { tags.artist = value }
        if let value = text(metadata.album) { tags.albumTitle = value }
        if let value = text(metadata.albumArtist) { tags.albumArtist = value }
        if let value = text(metadata.genre) { tags.genre = value }
        if let value = text(metadata.composer) { tags.composer = value }
        if let value = text(metadata.comment) { tags.comment = value }
        // SFBAudioEngine's ID3v2 writer (MP3, AIFF, WAV) silently drops dates that are not full ISO 8601 timestamps;
        // other formats get the plain year.
        if let value = number(metadata.year) {
            let usesID3 = ["mp3", "aif", "aiff", "aifc", "wav", "wave"].contains(url.pathExtension.lowercased())
            tags.releaseDate = value.map { usesID3 ? String(format: "%04d-01-01T00:00:00Z", $0) : String(format: "%04d", $0) }
        }
        if let value = number(metadata.trackNumber) { tags.trackNumber = value }
        if let value = number(metadata.trackTotal) { tags.trackTotal = value }
        if let value = number(metadata.discNumber) { tags.discNumber = value }
        if let value = number(metadata.discTotal) { tags.discTotal = value }
        if let value = number(metadata.bpm) { tags.bpm = value }
        if let value = metadata.isCompilation { tags.isCompilation = value }
        if let value = text(metadata.musicBrainzRecordingId) { tags.musicBrainzRecordingID = value }
        if let value = text(metadata.musicBrainzReleaseId) { tags.musicBrainzReleaseID = value }
        if let value = text(metadata.lyrics) { tags.lyrics = value }
        if let lyrics { tags.lyrics = lyrics }
        if let frontCover {
            tags.removeAttachedPicturesOfType(.frontCover)
            tags.attachPicture(AttachedPicture(imageData: frontCover, type: .frontCover, description: nil))
        }
        try file.writeMetadata()

        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return Result(fileSize: Int64(values.fileSize ?? 0), modifiedAt: values.contentModificationDate ?? .now)
    }
}
