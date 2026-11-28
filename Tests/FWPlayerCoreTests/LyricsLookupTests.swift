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
        XCTAssertEqual(LyricsLookup.outcome(of: entry(300, lyrics: "  hello \n")), .lyrics(.init(plain: "hello", synced: nil)))
        XCTAssertEqual(LyricsLookup.outcome(of: entry(300, lyrics: nil, instrumental: true)), .instrumental)
        XCTAssertEqual(LyricsLookup.outcome(of: entry(300, lyrics: nil)), .notFound)
        XCTAssertEqual(LyricsLookup.outcome(of: nil), .notFound)
        XCTAssertEqual(LyricsLookup.outcome(of: entry(300, lyrics: nil, synced: "[00:01.00] One\n[00:02.50] Two")),
                       .lyrics(.init(plain: "One\nTwo", synced: [.init(time: 1, text: "One"), .init(time: 2.5, text: "Two")])))
    }

    func testOutcomeTextIsOnlyForFoundLyrics() {
        let words = LyricsLookup.Lyrics(plain: "words", synced: nil)
        XCTAssertEqual(LyricsLookup.Outcome.lyrics(words).lyrics, words)
        XCTAssertNil(LyricsLookup.Outcome.instrumental.lyrics)
        XCTAssertNil(LyricsLookup.Outcome.notFound.lyrics)
        XCTAssertNil(LyricsLookup.Outcome.unavailable.lyrics)
    }

    func testOutcomeKeepsSyncedLinesAlongsidePlainLyrics() {
        let found = LyricsLookup.outcome(of: entry(300, lyrics: "One\nTwo", synced: "[00:01.00] One\n[00:02.00] Two"))
        XCTAssertEqual(found.lyrics?.plain, "One\nTwo")
        XCTAssertEqual(found.lyrics?.synced?.map(\.time), [1, 2])
    }

    func testSyncedLinesAreParsedInOrder() {
        let lines = LyricsLookup.lines(fromSynced: """
        [ar:Artist]
        [00:12.34] First line
        [00:15.00][01:15.5] Chorus
        [00:20:50]
        [00:05] Intro
        """)
        XCTAssertEqual(lines, [
            .init(time: 5, text: "Intro"),
            .init(time: 12.34, text: "First line"),
            .init(time: 15, text: "Chorus"),
            .init(time: 20.5, text: ""),
            .init(time: 75.5, text: "Chorus"),
        ])
        XCTAssertNil(LyricsLookup.lines(fromSynced: "Just words\nno times"))
    }

    func testLineIndexFollowsTime() {
        let lines: [LyricsLookup.Line] = [.init(time: 5, text: "a"), .init(time: 10, text: "b"), .init(time: 20, text: "c")]
        XCTAssertNil(LyricsLookup.lineIndex(in: lines, at: 4.9))
        XCTAssertEqual(LyricsLookup.lineIndex(in: lines, at: 5), 0)
        XCTAssertEqual(LyricsLookup.lineIndex(in: lines, at: 19.9), 1)
        XCTAssertEqual(LyricsLookup.lineIndex(in: lines, at: 300), 2)
        XCTAssertNil(LyricsLookup.lineIndex(in: [], at: 1))
    }

    func testEmbeddedLyricsMayBeLRC() {
        let lrc = LyricsLookup.lyrics(fromEmbedded: "[00:01.00] One\n[00:02.00] Two")
        XCTAssertEqual(lrc?.plain, "One\nTwo")
        XCTAssertEqual(lrc?.synced?.count, 2)
        let plain = LyricsLookup.lyrics(fromEmbedded: "  Just words \n")
        XCTAssertEqual(plain, .init(plain: "Just words", synced: nil))
        XCTAssertNil(LyricsLookup.lyrics(fromEmbedded: "   "))
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
