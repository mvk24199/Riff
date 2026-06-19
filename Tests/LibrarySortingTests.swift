import XCTest
@testable import Riff

/// Unit tests for `LibrarySorting` — the pure helpers powering B6's
/// Pinned Library + smart-filter behaviour. Pure-data shape (no
/// `AppEnvironment`, no SwiftUI), so the assertions read directly
/// without spinning up a view tree.
final class LibrarySortingTests: XCTestCase {

    // MARK: - Fixture helpers

    private func song(_ id: String, title: String? = nil, durationSeconds: Int? = nil) -> MediaItem {
        MediaItem(
            id: id,
            kind: .song,
            title: title ?? "Title-\(id)",
            subtitle: "Artist",
            thumbnailURL: nil,
            durationSeconds: durationSeconds
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

    // MARK: - sortTracks (B7)

    func testSortTracksOriginalIsIdentity() {
        let items = [song("a"), song("b"), song("c")]

        let result = LibrarySorting.sortTracks(items, by: .original)

        XCTAssertEqual(result.map(\.id), ["a", "b", "c"], ".original must not permute")
    }

    func testSortTracksAToZIsCaseInsensitive() {
        let items = [
            song("1", title: "banana"),
            song("2", title: "Apple"),
            song("3", title: "cherry")
        ]

        let result = LibrarySorting.sortTracks(items, by: .aToZ)

        XCTAssertEqual(result.map(\.id), ["2", "1", "3"], "case-insensitive: Apple < banana < cherry")
    }

    func testSortTracksZToAReversesAlphabetical() {
        let items = [
            song("1", title: "banana"),
            song("2", title: "Apple"),
            song("3", title: "cherry")
        ]

        let result = LibrarySorting.sortTracks(items, by: .zToA)

        XCTAssertEqual(result.map(\.id), ["3", "1", "2"])
    }

    func testSortTracksPlayCountTieBreaksAlphabetically() {
        let now = Date()
        let items = [
            song("a", title: "Zebra"),  // 2 plays
            song("b", title: "Apple"),  // 2 plays
            song("c", title: "Mango")    // 1 play
        ]
        let entries: [PlayedEntry] = [
            entry("a", at: now), entry("a", at: now),
            entry("b", at: now), entry("b", at: now),
            entry("c", at: now)
        ]

        let result = LibrarySorting.sortTracks(items, by: .playCount, entries: entries)

        // Most-played first; "Apple" beats "Zebra" on alphabetical tie-break.
        XCTAssertEqual(result.map(\.id), ["b", "a", "c"])
    }

    func testSortTracksPlayCountTreatsUnplayedAsZero() {
        let now = Date()
        let items = [
            song("a", title: "Apple"),    // 0 plays
            song("b", title: "Banana")    // 1 play
        ]
        let entries: [PlayedEntry] = [entry("b", at: now)]

        let result = LibrarySorting.sortTracks(items, by: .playCount, entries: entries)

        XCTAssertEqual(result.map(\.id), ["b", "a"], "played items beat unplayed under .playCount")
    }

    func testSortTracksLastPlayedMostRecentFirst() {
        let early = Date(timeIntervalSince1970: 1_000)
        let late = Date(timeIntervalSince1970: 5_000)
        let items = [song("a"), song("b"), song("c")]
        let entries: [PlayedEntry] = [
            entry("a", at: early),
            entry("b", at: late)
            // "c" never played
        ]

        let result = LibrarySorting.sortTracks(items, by: .lastPlayed, entries: entries)

        XCTAssertEqual(result.map(\.id), ["b", "a", "c"], "most-recent first, never-played to the tail")
    }

    func testSortTracksDurationShortestFirst() {
        let items = [
            song("a", durationSeconds: 200),
            song("b", durationSeconds: 100),
            song("c", durationSeconds: 300)
        ]

        let result = LibrarySorting.sortTracks(items, by: .durationShortest)

        XCTAssertEqual(result.map(\.id), ["b", "a", "c"])
    }

    func testSortTracksDurationLongestFirst() {
        let items = [
            song("a", durationSeconds: 200),
            song("b", durationSeconds: 100),
            song("c", durationSeconds: 300)
        ]

        let result = LibrarySorting.sortTracks(items, by: .durationLongest)

        XCTAssertEqual(result.map(\.id), ["c", "a", "b"])
    }

    func testSortTracksDurationShortestSinksMissingDurationsToTail() {
        let items = [
            song("a", durationSeconds: 200),
            song("b", durationSeconds: nil),
            song("c", durationSeconds: 100),
            song("d", durationSeconds: nil)
        ]

        let result = LibrarySorting.sortTracks(items, by: .durationShortest)

        // Real-duration rows come first in ascending order; missing-
        // duration rows trail, tied to each other and tie-broken by
        // title (both "Title-b" and "Title-d", b < d).
        XCTAssertEqual(result.map(\.id), ["c", "a", "b", "d"])
    }

    func testSortTracksDurationLongestSinksMissingDurationsToTail() {
        let items = [
            song("a", durationSeconds: 200),
            song("b", durationSeconds: nil),
            song("c", durationSeconds: 100),
            song("d", durationSeconds: nil)
        ]

        let result = LibrarySorting.sortTracks(items, by: .durationLongest)

        // Real-duration rows come first in descending order; missing-
        // duration rows trail.
        XCTAssertEqual(result.map(\.id), ["a", "c", "b", "d"])
    }

    func testSortTracksIsPureAndDoesNotMutateInput() {
        let original = [song("c"), song("a"), song("b")]

        _ = LibrarySorting.sortTracks(original, by: .aToZ)

        XCTAssertEqual(original.map(\.id), ["c", "a", "b"], "input array must remain untouched")
    }

    func testTrackSortOrderRequiresPlayHistoryFlag() {
        XCTAssertTrue(LibrarySorting.TrackSortOrder.playCount.requiresPlayHistory)
        XCTAssertTrue(LibrarySorting.TrackSortOrder.lastPlayed.requiresPlayHistory)
        XCTAssertFalse(LibrarySorting.TrackSortOrder.original.requiresPlayHistory)
        XCTAssertFalse(LibrarySorting.TrackSortOrder.aToZ.requiresPlayHistory)
        XCTAssertFalse(LibrarySorting.TrackSortOrder.durationShortest.requiresPlayHistory)
    }

    func testTrackSortOrderOriginalLabelAdaptsToSurface() {
        // The `.original` label morphs per surface so it reads naturally
        // — guarding this against silent renames keeps the menu copy
        // consistent across album / playlist / search.
        XCTAssertEqual(LibrarySorting.TrackSortOrder.original.displayName(for: .album), "Album order")
        XCTAssertEqual(LibrarySorting.TrackSortOrder.original.displayName(for: .playlist), "Playlist order")
        XCTAssertEqual(LibrarySorting.TrackSortOrder.original.displayName(for: .search), "Relevance")
        XCTAssertEqual(LibrarySorting.TrackSortOrder.original.displayName(for: .generic), "Original order")
        // Non-`.original` cases share one label across surfaces.
        XCTAssertEqual(LibrarySorting.TrackSortOrder.aToZ.displayName(for: .album), "A to Z")
        XCTAssertEqual(LibrarySorting.TrackSortOrder.aToZ.displayName(for: .search), "A to Z")
    }
}
