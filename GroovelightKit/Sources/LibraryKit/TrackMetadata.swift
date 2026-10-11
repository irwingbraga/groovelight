import Foundation

/// The editable tag fields of a track. Used for proposed fixes, manual edits, overrides kept in the database (nil means
/// "keep the current value") and for writing tags back to files. An empty string or a 0 number clears the field.
public struct TrackMetadata: Codable, Hashable, Sendable {
    public var title: String?
    public var artist: String?
    public var album: String?
    public var albumArtist: String?
    public var genre: String?
    public var year: Int?
    public var trackNumber: Int?
    public var trackTotal: Int?
    public var discNumber: Int?
    public var discTotal: Int?
    public var isCompilation: Bool?
    public var musicBrainzRecordingId: String?
    public var musicBrainzReleaseId: String?
    public var composer: String?
    public var comment: String?
    public var bpm: Int?
    public var lyrics: String?

    public init(title: String? = nil, artist: String? = nil, album: String? = nil, albumArtist: String? = nil,
                genre: String? = nil, year: Int? = nil, trackNumber: Int? = nil, trackTotal: Int? = nil,
                discNumber: Int? = nil, discTotal: Int? = nil, isCompilation: Bool? = nil,
                musicBrainzRecordingId: String? = nil, musicBrainzReleaseId: String? = nil,
                composer: String? = nil, comment: String? = nil, bpm: Int? = nil, lyrics: String? = nil) {
        self.title = title
        self.artist = artist
        self.album = album
        self.albumArtist = albumArtist
        self.genre = genre
        self.year = year
        self.trackNumber = trackNumber
        self.trackTotal = trackTotal
        self.discNumber = discNumber
        self.discTotal = discTotal
        self.isCompilation = isCompilation
        self.musicBrainzRecordingId = musicBrainzRecordingId
        self.musicBrainzReleaseId = musicBrainzReleaseId
        self.composer = composer
        self.comment = comment
        self.bpm = bpm
        self.lyrics = lyrics
    }

    public var isEmpty: Bool { self == TrackMetadata() }

    /// Fields of `other` that are set win.
    public func merging(_ other: TrackMetadata) -> TrackMetadata {
        TrackMetadata(
            title: other.title ?? title, artist: other.artist ?? artist, album: other.album ?? album,
            albumArtist: other.albumArtist ?? albumArtist, genre: other.genre ?? genre, year: other.year ?? year,
            trackNumber: other.trackNumber ?? trackNumber, trackTotal: other.trackTotal ?? trackTotal,
            discNumber: other.discNumber ?? discNumber, discTotal: other.discTotal ?? discTotal,
            isCompilation: other.isCompilation ?? isCompilation,
            musicBrainzRecordingId: other.musicBrainzRecordingId ?? musicBrainzRecordingId,
            musicBrainzReleaseId: other.musicBrainzReleaseId ?? musicBrainzReleaseId,
            composer: other.composer ?? composer, comment: other.comment ?? comment, bpm: other.bpm ?? bpm,
            lyrics: other.lyrics ?? lyrics
        )
    }
}

extension Track {
    /// Current values of the editable fields.
    public var metadata: TrackMetadata {
        TrackMetadata(title: title, artist: artist, album: album, albumArtist: albumArtist, genre: genre, year: year,
                      trackNumber: trackNumber, trackTotal: trackTotal, discNumber: discNumber, discTotal: discTotal,
                      isCompilation: isCompilation, musicBrainzRecordingId: musicBrainzRecordingId,
                      musicBrainzReleaseId: musicBrainzReleaseId, composer: composer, comment: comment, bpm: bpm,
                      lyrics: lyrics)
    }

    /// Sets every field present in `metadata` (an empty string or 0 clears it) and recomputes the album grouping key.
    public mutating func apply(_ metadata: TrackMetadata) {
        func text(_ value: String?, _ current: String?) -> String? {
            guard let value else { return current }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : value
        }
        func number(_ value: Int?, _ current: Int?) -> Int? {
            guard let value else { return current }
            return value == 0 ? nil : value
        }
        // A song always has a title; clearing it falls back to the file name, as for untagged files.
        if let value = metadata.title { title = text(value, nil) ?? url.deletingPathExtension().lastPathComponent }
        artist = text(metadata.artist, artist)
        album = text(metadata.album, album)
        albumArtist = text(metadata.albumArtist, albumArtist)
        genre = text(metadata.genre, genre)
        year = number(metadata.year, year)
        trackNumber = number(metadata.trackNumber, trackNumber)
        trackTotal = number(metadata.trackTotal, trackTotal)
        discNumber = number(metadata.discNumber, discNumber)
        discTotal = number(metadata.discTotal, discTotal)
        if let value = metadata.isCompilation { isCompilation = value }
        musicBrainzRecordingId = text(metadata.musicBrainzRecordingId, musicBrainzRecordingId)
        musicBrainzReleaseId = text(metadata.musicBrainzReleaseId, musicBrainzReleaseId)
        composer = text(metadata.composer, composer)
        comment = text(metadata.comment, comment)
        bpm = number(metadata.bpm, bpm)
        lyrics = text(metadata.lyrics, lyrics)
        albumKey = Track.makeAlbumKey(album: album, albumArtist: albumArtist, artist: artist, isCompilation: isCompilation)
    }

    /// Overrides kept in the database for fixes not written to the file.
    public var overrides: TrackMetadata? {
        get { metadataOverrides.flatMap { try? JSONDecoder().decode(TrackMetadata.self, from: $0) } }
        set { metadataOverrides = newValue.flatMap { $0.isEmpty ? nil : try? JSONEncoder().encode($0) } }
    }

    /// Lyrics to show: from the file first, then fetched online.
    public var displayLyrics: String? { lyrics.nonEmpty ?? fetchedLyrics.nonEmpty }
}
