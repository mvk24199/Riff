import XCTest
@testable import Riff

/// Tests for the two PlayerBridge extractions: `QueueManager` and
/// `BrowseIdResolver`. These are pure value-or-state types (no
/// network, no JS bridge), so they unit-test cleanly.
@MainActor
final class QueueManagerTests: XCTestCase {

    private func item(_ id: String, title: String = "T") -> MediaItem {
        MediaItem(id: id, kind: .song, title: title, subtitle: "Artist", thumbnailURL: nil)
    }

    func testReplaceQueueAssignsItems() {
        let q = QueueManager(historyCap: 5)
        q.replaceQueue([item("a"), item("b"), item("c")])
        XCTAssertEqual(q.upNext.map(\.id), ["a", "b", "c"])
    }

    func testPlayNextDedupesAndMovesToFront() {
        let q = QueueManager(historyCap: 5)
        q.replaceQueue([item("a"), item("b"), item("c")])
        q.playNext(item("c"))
        XCTAssertEqual(q.upNext.map(\.id), ["c", "a", "b"],
            "Existing entry should move to the front rather than duplicate")
    }

    func testAddToEndDedupes() {
        let q = QueueManager(historyCap: 5)
        q.replaceQueue([item("a")])
        q.addToEnd(item("b"))
        q.addToEnd(item("a"))   // duplicate — must be a no-op
        XCTAssertEqual(q.upNext.map(\.id), ["a", "b"])
    }

    func testRemoveByVideoId() {
        let q = QueueManager(historyCap: 5)
        q.replaceQueue([item("a"), item("b"), item("c")])
        q.remove(videoId: "b")
        XCTAssertEqual(q.upNext.map(\.id), ["a", "c"])
    }

    func testMoveDownAndUpClampsToBounds() {
        let q = QueueManager(historyCap: 5)
        q.replaceQueue([item("a"), item("b"), item("c")])
        q.move(videoId: "a", by: -10)            // already at top — clamp
        XCTAssertEqual(q.upNext.map(\.id), ["a", "b", "c"])
        q.move(videoId: "a", by: 100)            // clamp to bottom
        XCTAssertEqual(q.upNext.map(\.id), ["b", "c", "a"])
        q.move(videoId: "c", by: -1)
        XCTAssertEqual(q.upNext.map(\.id), ["c", "b", "a"])
    }

    func testArchiveDedupesAgainstTail() {
        let q = QueueManager(historyCap: 5)
        // Use a unique key so the persisted-history journal from a
        // previous test run doesn't bleed in.
        q.clearPersistedHistory()
        q.archive(item("a"))
        let sizeBeforeDup = q.playedHistory.count
        q.archive(item("a"))                     // immediate dup — no-op
        XCTAssertEqual(q.playedHistory.count, sizeBeforeDup)
        q.archive(item("b"))
        XCTAssertGreaterThan(q.playedHistory.count, sizeBeforeDup)
    }

    func testArchiveRespectsCap() {
        let q = QueueManager(historyCap: 3)
        q.clearPersistedHistory()
        q.archive(item("a"))
        q.archive(item("b"))
        q.archive(item("c"))
        q.archive(item("d"))
        XCTAssertEqual(q.playedHistory.suffix(3).map(\.id), ["b", "c", "d"],
            "Cap should drop the oldest entries when exceeded")
        XCTAssertEqual(q.playedHistory.count, 3)
    }

    func testClearQueue() {
        let q = QueueManager(historyCap: 5)
        q.replaceQueue([item("a"), item("b")])
        q.clearQueue()
        XCTAssertTrue(q.upNext.isEmpty)
    }
}

/// `BrowseIdResolver` paths 2 and 3 are pure (no network) and can be
/// tested directly. Path 1 (innerTube.playable) requires a network
/// stub — left for an integration test once we wire URLProtocol-based
/// stubs into the test target.
final class BrowseIdResolverTests: XCTestCase {

    /// VL-prefixed browseIds where InnerTube can't resolve should fall
    /// through to the direct-playlist path, with the VL stripped.
    func testVLPrefixStripFallback() async {
        // Use a mock InnerTubeClient with a session that always 404s
        // so `innerTube.playable(...)` throws → resolver moves on.
        let unreachable = InnerTubeClient(session: Self.failingSession)
        let result = await BrowseIdResolver.resolve("VLPLfake123", via: unreachable)
        XCTAssertEqual(result, .directPlaylist(playlistId: "PLfake123"))
    }

    /// Non-VL browseIds where resolution fails should land on the
    /// browse-page fallback URL.
    func testBrowsePageFallback() async {
        let unreachable = InnerTubeClient(session: Self.failingSession)
        let result = await BrowseIdResolver.resolve("MPREb_unresolvable", via: unreachable)
        let expected = URL(string: "https://music.youtube.com/browse/MPREb_unresolvable")!
        XCTAssertEqual(result, .browsePage(expected))
    }

    /// URLSession that fails every request — used to drive the resolver
    /// past the InnerTube path so we can assert the fallback branches.
    /// We don't intercept; we just point at an unreachable hostname so
    /// the request fails fast.
    private static let failingSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 0.1
        config.timeoutIntervalForResource = 0.1
        return URLSession(configuration: config)
    }()
}
