import XCTest
@testable import Riff

/// Unit tests for `LibrarySorting` — the pure helpers powering B6's
/// Pinned Library + smart-filter behaviour. Pure-data shape (no
/// `AppEnvironment`, no SwiftUI), so the assertions read directly
/// without spinning up a view tree.
final class LibrarySortingTests: XCTestCase {

    // MARK: - Fixture helpers

    private func song(_ id: String, title: String? = nil) -> MediaItem {
        MediaItem(
            id: id,
            kind: .song,
            title: title ?? "Title-\(id)",
            subtitle: "Artist",
            thumbnailURL: nil
        )
    }

    private func entry(_ id: String, at date: Date) -> PlayedEntry {
        PlayedEntry(item: song(id), playedAt: date)
    }

    // MARK: - playCounts

    func testPlayCountsAggregatesByItemId() {
        let now = Date()
        let entries: [PlayedEntry] = [
            entry("a", at: now),
            entry("b", at: now),
            entry("a", at: now),
            entry("c", at: now),
            entry("a", at: now)
        ]

        let counts = LibrarySorting.playCounts(from: entries)

        XCTAssertEqual(counts["a"], 3)
        XCTAssertEqual(counts["b"], 1)
        XCTAssertEqual(counts["c"], 1)
        XCTAssertNil(counts["d"], "items not in the journal should be absent from the map")
    }

    func testPlayCountsEmptyJournalIsEmptyMap() {
        XCTAssertTrue(LibrarySorting.playCounts(from: []).isEmpty)
    }

    // MARK: - lastPlayed

    func testLastPlayedKeepsMostRecentTimestampPerId() {
        let early = Date(timeIntervalSince1970: 1_000)
        let mid = Date(timeIntervalSince1970: 2_000)
        let late = Date(timeIntervalSince1970: 3_000)
        let entries: [PlayedEntry] = [
            entry("a", at: early),
            entry("b", at: mid),
            entry("a", at: late),     // later wins
            entry("a", at: mid)        // earlier than `late`, must not overwrite
        ]

        let last = LibrarySorting.lastPlayed(from: entries)

        XCTAssertEqual(last["a"], late, "max wall-clock across the matching entries wins")
        XCTAssertEqual(last["b"], mid)
        XCTAssertNil(last["c"], "unplayed items absent from the map")
    }

    func testLastPlayedEmptyJournalIsEmptyMap() {
        XCTAssertTrue(LibrarySorting.lastPlayed(from: []).isEmpty)
    }

    // MARK: - partitionPinned

    func testPartitionPinnedFloatsPinnedToHeadPreservingOrder() {
        let items = [song("a"), song("b"), song("c"), song("d"), song("e")]
        let pinned: Set<String> = ["c", "e"]

        let result = LibrarySorting.partitionPinned(items, pinned: pinned)

        XCTAssertEqual(result.map(\.id), ["c", "e", "a", "b", "d"])
    }

    func testPartitionPinnedEmptyPinSetReturnsItemsUnchanged() {
        let items = [song("a"), song("b"), song("c")]

        let result = LibrarySorting.partitionPinned(items, pinned: [])

        XCTAssertEqual(result.map(\.id), ["a", "b", "c"])
    }

    func testPartitionPinnedAllPinnedReturnsItemsUnchanged() {
        let items = [song("a"), song("b"), song("c")]

        let result = LibrarySorting.partitionPinned(items, pinned: ["a", "b", "c"])

        XCTAssertEqual(result.map(\.id), ["a", "b", "c"], "when everything is pinned the partition is a no-op")
    }

    func testPartitionPinnedIgnoresUnknownIds() {
        let items = [song("a"), song("b")]

        // Stale pin ids — item was unliked since being pinned. The
        // partition should not invent entries.
        let result = LibrarySorting.partitionPinned(items, pinned: ["zz", "yy"])

        XCTAssertEqual(result.map(\.id), ["a", "b"])
    }

    func testPartitionPinnedPreservesRelativeOrderWithinEachGroup() {
        // Verifies the stable-partition contract: if input is ABCDE
        // and we pin D and B, the result must be DB then ACE — not
        // BD then ACE (which would lose the within-group sort) and
        // not DBACE in any other order. The "within pinned" order
        // mirrors the input traversal order, which is the sorted
        // order the caller already established.
        let items = [song("a"), song("b"), song("c"), song("d"), song("e")]

        let result = LibrarySorting.partitionPinned(items, pinned: ["d", "b"])

        XCTAssertEqual(
            result.map(\.id),
            ["b", "d", "a", "c", "e"],
            "pinned items appear in their input order, then unpinned items in their input order"
        )
    }
}
