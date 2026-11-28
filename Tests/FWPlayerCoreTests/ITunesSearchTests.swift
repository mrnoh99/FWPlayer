import XCTest
@testable import FWPlayerCore

final class ITunesSearchTests: XCTestCase {
    private func queryItems(_ url: URL?) -> [String: String] {
        guard let url, let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return [:] }
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
    }

    func testTermsWithAmpersandsAndPlusSignsSurviveWhole() {
        for term in ["Bridge Over Troubled Water Simon & Garfunkel", "Me + You", "a=b #1", "Sigur Rós ( )"] {
            let url = ITunesSearch.albumSearchURL(term: term)
            let items = queryItems(url)
            XCTAssertEqual(items["term"], term, "\(url?.absoluteString ?? "nil")")
            XCTAssertEqual(items.count, 4, "the term must not split the query")
        }
    }

    func testPlusIsEncodedSoItIsNotReadAsASpace() {
        let url = ITunesSearch.albumSearchURL(term: "Me + You")
        XCTAssertTrue(url?.absoluteString.hasSuffix("term=Me%20%2B%20You") == true, url?.absoluteString ?? "nil")
    }

    func testTheSearchAsksForAlbums() {
        let items = queryItems(ITunesSearch.albumSearchURL(term: "Kind of Blue", limit: 3))
        XCTAssertEqual(items["media"], "music")
        XCTAssertEqual(items["entity"], "album")
        XCTAssertEqual(items["limit"], "3")
    }
}
