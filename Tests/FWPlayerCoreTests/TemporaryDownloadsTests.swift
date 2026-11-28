import XCTest
@testable import FWPlayerCore

/// Downloads for playback get a folder each, so same-named files never clash.
final class TemporaryDownloadsTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TemporaryDownloadsTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url)
    }

    func testSameNamedDownloadsDontOverwriteOrRemoveEachOther() throws {
        let first = try TemporaryDownloads.newFileURL(named: "Track 01.m4a", in: root)
        let second = try TemporaryDownloads.newFileURL(named: "Track 01.m4a", in: root)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(first.lastPathComponent, "Track 01.m4a")   // the extension still says the format
        try write("one", to: first)
        try write("two", to: second)

        TemporaryDownloads.remove(first, in: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.deletingLastPathComponent().path))
        XCTAssertEqual(try String(contentsOf: second, encoding: .utf8), "two")
    }

    func testRemoveIgnoresAFragmentAndFilesOutsideTheRoot() throws {
        let track = try TemporaryDownloads.newFileURL(named: "track.iso", in: root)
        try write("iso", to: track)
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("outside-\(UUID().uuidString)")
        try write("keep", to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }

        TemporaryDownloads.remove(outside, in: root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))

        var components = URLComponents(url: track, resolvingAgainstBaseURL: false)!
        components.fragment = "track=3"
        TemporaryDownloads.remove(components.url!, in: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: track.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path), "the root itself stays")
    }

    func testRemoveAllClearsLeftovers() throws {
        try write("old", to: try TemporaryDownloads.newFileURL(named: "a.mp3", in: root))
        TemporaryDownloads.removeAll(in: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }
}
