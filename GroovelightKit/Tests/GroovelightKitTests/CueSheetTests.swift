import Foundation
import Testing
@testable import LibraryKit

struct CueSheetTests {
    static let sample = """
        \u{FEFF}REM GENRE "Alternative Rock"
        REM DATE 1997
        REM DISCID 970ABC0C
        PERFORMER "Radiohead"
        TITLE "OK Computer"
        FILE "Radiohead - OK Computer.wav" WAVE
          TRACK 01 AUDIO
            TITLE "Airbag"
            PERFORMER "Radiohead"
            INDEX 01 00:00:00
          TRACK 02 AUDIO
            TITLE "Paranoid Android"
            ISRC GBAYE9700198
            INDEX 00 04:42:30
            INDEX 01 04:44:30
          TRACK 03 AUDIO
            TITLE "Subterranean Homesick Alien"
            SONGWRITER "Thom Yorke"
            INDEX 01 11:08:00
        """

    @Test func parsesASheet() throws {
        let sheet = try #require(CueSheet.parse(Self.sample.replacingOccurrences(of: "\n", with: "\r\n")))
        #expect(sheet.title == "OK Computer" && sheet.performer == "Radiohead" && sheet.genre == "Alternative Rock" && sheet.year == 1997)
        #expect(sheet.files.count == 1 && sheet.files[0].name == "Radiohead - OK Computer.wav")
        let tracks = sheet.tracks
        #expect(tracks.map(\.number) == [1, 2, 3])
        #expect(tracks[1].title == "Paranoid Android" && tracks[1].isrc == "GBAYE9700198")
        #expect(tracks[1].start == 284.4 && tracks[1].pregap == 282.4)
        #expect(tracks[2].start == 668 && tracks[2].songwriter == "Thom Yorke")
        #expect(tracks[0].performer == "Radiohead" && tracks[2].performer == nil)
    }

    @Test func readsOtherEncodings() throws {
        let text = "PERFORMER \"Sigur Rós\"\nTITLE \"Ágætis byrjun\"\nFILE \"a.flac\" WAVE\n TRACK 01 AUDIO\n  TITLE \"Svefn-g-englar\"\n  INDEX 01 00:00:00\n"
        let latin = try #require(text.data(using: .windowsCP1252))
        #expect(CueSheet.parse(CueSheet.decode(latin))?.performer == "Sigur Rós")
        let utf16 = try #require(text.data(using: .utf16))
        #expect(CueSheet.parse(CueSheet.decode(utf16))?.title == "Ágætis byrjun")
    }

    @Test func handlesSeveralFilesAndDataTracks() throws {
        let text = """
            FILE "CD1.flac" WAVE
              TRACK 01 AUDIO
                INDEX 01 00:00:00
              TRACK 02 AUDIO
                INDEX 01 03:00:00
            FILE "CD2.flac" WAVE
              TRACK 03 AUDIO
                INDEX 01 00:00:00
              TRACK 04 MODE1/2352
                INDEX 01 05:00:00
            """
        let sheet = try #require(CueSheet.parse(text))
        #expect(sheet.files.map(\.name) == ["CD1.flac", "CD2.flac"])
        #expect(sheet.files[1].tracks.map(\.number) == [3])
        #expect(CueSheet.parse("REM nothing here") == nil)
    }

    @Test func resolvesFileReferences() {
        let folder = URL(fileURLWithPath: "/Music/Album")
        let files: Set<String> = ["/Music/Album/Radiohead - OK Computer.flac", "/Music/Album/Other.mp3"]
        // The sheet still says .wav after the rip was compressed to FLAC.
        #expect(CueSheet.resolve("Radiohead - OK Computer.wav", relativeTo: folder, audioFiles: files)?.lastPathComponent == "Radiohead - OK Computer.flac")
        #expect(CueSheet.resolve("other.MP3", relativeTo: folder, audioFiles: files)?.lastPathComponent == "Other.mp3")
        #expect(CueSheet.resolve("Missing.flac", relativeTo: folder, audioFiles: files) == nil)
    }
}
