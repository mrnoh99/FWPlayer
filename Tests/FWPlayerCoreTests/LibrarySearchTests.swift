import XCTest
@testable import FWPlayerCore

final class LibrarySearchTests: XCTestCase {
    func testTermsAreNormalisedAndSplit() {
        XCTAssertEqual(LibrarySearch.terms(from: "  Éagles   HOTEL "), ["eagles", "hotel"])
        XCTAssertTrue(LibrarySearch.terms(from: "   ").isEmpty)
    }

    func testWordsMayBeSpreadAcrossThePath() {
        let terms = LibrarySearch.terms(from: "eagles hotel california")
        let score = LibrarySearch.score(
            name: "01-Hotel California.flac",
            path: "02Pop/Eagles - The Studio Albums/Disc 5 - Hotel California 1976/01-Hotel California.flac",
            isFolder: false, terms: terms)
        XCTAssertNotNil(score)
    }

    func testFilesUnderAMatchingFolderDoNotAllMatch() {
        let terms = LibrarySearch.terms(from: "eagles")
        // The folder itself matches...
        XCTAssertNotNil(LibrarySearch.score(name: "Eagles - The Studio Albums", path: "02Pop/Eagles - The Studio Albums",
                                            isFolder: true, terms: terms))
        // ...but its tracks (whose own names don't contain the word) don't flood the results.
        XCTAssertNil(LibrarySearch.score(name: "02-New Kid In Town.flac",
                                         path: "02Pop/Eagles - The Studio Albums/Disc 5/02-New Kid In Town.flac",
                                         isFolder: false, terms: terms))
    }

    func testEveryWordMustAppearSomewhere() {
        let terms = LibrarySearch.terms(from: "hotel zebra")
        XCTAssertNil(LibrarySearch.score(name: "01-Hotel California.flac", path: "Eagles/01-Hotel California.flac",
                                         isFolder: false, terms: terms))
    }

    func testCaseAccentsAndWidthAreIgnored() {
        XCTAssertNotNil(LibrarySearch.score(name: "Café Del Mar", path: "Music/Café Del Mar", isFolder: true,
                                            terms: LibrarySearch.terms(from: "CAFE del")))
        XCTAssertNotNil(LibrarySearch.score(name: "Ｂeethoven", path: "Ｂeethoven", isFolder: true,
                                            terms: LibrarySearch.terms(from: "beethoven")))
    }

    func testDecomposedHangulFileNamesMatchTypedText() {
        let decomposed = "에디트 피아프".decomposedStringWithCanonicalMapping       // how macOS often stores names
        XCTAssertNotEqual(decomposed.unicodeScalars.count, "에디트 피아프".unicodeScalars.count)
        XCTAssertNotNil(LibrarySearch.score(name: decomposed, path: decomposed, isFolder: true,
                                            terms: LibrarySearch.terms(from: "피아프")))
    }

    func testBetterMatchesScoreHigher() {
        let terms = LibrarySearch.terms(from: "hotel california")
        let exact = LibrarySearch.score(name: "Hotel California", path: "Eagles/Hotel California", isFolder: true, terms: terms)!
        let partial = LibrarySearch.score(name: "Hotel California Live 1977", path: "Eagles/Hotel California Live 1977",
                                          isFolder: true, terms: terms)!
        let track = LibrarySearch.score(name: "Hotel California.flac", path: "Eagles/Hotel California.flac",
                                        isFolder: false, terms: terms)!
        let deep = LibrarySearch.score(name: "Hotel California", path: "a/b/c/d/e/Hotel California", isFolder: true, terms: terms)!
        XCTAssertGreaterThan(exact, partial)
        XCTAssertGreaterThan(exact, track)       // folders first
        XCTAssertGreaterThan(exact, deep)        // shallower first
    }
}
