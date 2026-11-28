import XCTest
@testable import FWPlayerCore

/// Matching a track to LRCLIB's results (no network).
final class LyricsLookupTests: XCTestCase {

    private func entry(_ duration: Double?, lyrics: String? = "la la", synced: String? = nil,
                       instrumental: Bool = false) -> LyricsLookup.Entry {
        LyricsLookup.Entry(trackName: "Song", artistName: "Artist", albumName: nil, duration: duration,
                           instrumental: instrumental, plainLyrics: lyrics, syncedLyrics: synced)
    }

    func testSearchTitleDropsTrackNumberAndRepeatedArtist() {
        XCTAssertEqual(LyricsLookup.searchTitle("05. Michael Jackson - Beat It", artist: "Michael Jackson"), "Beat It")
        XCTAssertEqual(LyricsLookup.searchTitle("03 - Miles Davis - Blue in Green", artist: "Miles Davis"), "Blue in Green")
        XCTAssertEqual(LyricsLookup.searchTitle("1-03 So What", artist: nil), "So What")
        XCTAssertEqual(LyricsLookup.searchTitle("michael jackson - Beat It", artist: "Michael Jackson"), "Beat It")
    }

    func testSearchTitleLeavesOrdinaryTitlesAlone() {
        XCTAssertEqual(LyricsLookup.searchTitle("1999", artist: "Prince"), "1999")
        XCTAssertEqual(LyricsLookup.searchTitle("Beat It", artist: "Michael Jackson"), "Beat It")
        XCTAssertEqual(LyricsLookup.searchTitle("Song - Live", artist: "Artist"), "Song - Live")
        XCTAssertEqual(LyricsLookup.searchTitle("Artist - ", artist: "Artist"), "Artist -")
    }

    func testBestPicksTheClosestLength() {
        let pick = LyricsLookup.best([entry(258, lyrics: "edit"), entry(298, lyrics: "album")], duration: 297)
        XCTAssertEqual(pick?.plainLyrics, "album")
    }

    func testBestPrefersLyricsWhenLengthsTie() {
        let pick = LyricsLookup.best([entry(300, lyrics: nil, instrumental: true), entry(301, lyrics: "words")],
                                     duration: 300)
        XCTAssertEqual(pick?.plainLyrics, "words")
    }

    func testBestRejectsResultsFarFromTheTrackLength() {
        XCTAssertNil(LyricsLookup.best([entry(120), entry(600)], duration: 300))
    }

    func testBestWithoutALengthTakesTheFirstWithLyrics() {
        let pick = LyricsLookup.best([entry(100, lyrics: nil, instrumental: true), entry(200, lyrics: "words")],
                                     duration: nil)
        XCTAssertEqual(pick?.plainLyrics, "words")
    }

    func testOutcome() {
        XCTAssertEqual(LyricsLookup.outcome(of: entry(300, lyrics: "  hello \n")), .lyrics("hello"))
        XCTAssertEqual(LyricsLookup.outcome(of: entry(300, lyrics: nil, instrumental: true)), .instrumental)
        XCTAssertEqual(LyricsLookup.outcome(of: entry(300, lyrics: nil)), .notFound)
        XCTAssertEqual(LyricsLookup.outcome(of: nil), .notFound)
        XCTAssertEqual(LyricsLookup.outcome(of: entry(300, lyrics: nil, synced: "[00:01.00] One\n[00:02.50] Two")),
                       .lyrics("One\nTwo"))
    }

    func testOutcomeTextIsOnlyForFoundLyrics() {
        XCTAssertEqual(LyricsLookup.Outcome.lyrics("words").text, "words")
        XCTAssertNil(LyricsLookup.Outcome.instrumental.text)
        XCTAssertNil(LyricsLookup.Outcome.notFound.text)
        XCTAssertNil(LyricsLookup.Outcome.unavailable.text)
    }

    func testPlainTextFromSyncedLyrics() {
        let synced = """
        [ar:Artist]
        [ti:Song]
        [00:12.34] First line
        [00:15.00][01:15.00] Chorus
        [00:20.00]
        [00:21.10] Last line
        """
        XCTAssertEqual(LyricsLookup.plainText(fromSynced: synced), "First line\nChorus\n\nLast line")
        XCTAssertNil(LyricsLookup.plainText(fromSynced: "[ar:Artist]\n[00:01.00]"))
    }
}
