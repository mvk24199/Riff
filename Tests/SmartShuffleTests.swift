import XCTest
@testable import Riff

/// Tests for B5 Smart Shuffle pure-logic merge. The interleave function
/// is a free function, so these are straight value-in / value-out
/// checks — no PlayerBridge, no UserDefaults, no network.
final class SmartShuffleTests: XCTestCase {

    private func item(_ id: String) -> MediaItem {
        MediaItem(id: id, kind: .song, title: id, subtitle: "Artist", thumbnailURL: nil)
    }

    func testEmptyBaseProducesEmptyResult() {
        let result = SmartShuffle.merge(base: [], pool: [item("p1")])
        XCTAssertTrue(result.merged.isEmpty)
        XCTAssertTrue(result.injectedIds.isEmpty)
    }

    func testEmptyPoolPassesBaseThrough() {
        let base = [item("a"), item("b"), item("c"), item("d"), item("e")]
        let result = SmartShuffle.merge(base: base, pool: [])
        XCTAssertEqual(result.merged.map(\.id), ["a", "b", "c", "d", "e"])
        XCTAssertTrue(result.injectedIds.isEmpty)
    }

    func testInjectionLandsAtEveryNthSlot() {
        // every=4 → output positions 4, 8, 12, … are injections.
        let base = (0..<10).map { item("b\($0)") }
        let pool = (0..<5).map { item("p\($0)") }
        let result = SmartShuffle.merge(base: base, pool: pool, every: 4)
        // After 3 base items (b0,b1,b2), inject p0. After 3 more
        // (b3,b4,b5), inject p1. Etc.
        XCTAssertEqual(
            result.merged.map(\.id),
            ["b0", "b1", "b2", "p0",
             "b3", "b4", "b5", "p1",
             "b6", "b7", "b8", "p2",
             "b9"]
        )
        XCTAssertEqual(result.injectedIds, ["p0", "p1", "p2"])
    }

    func testInjectionStopsWhenPoolRunsOut() {
        let base = (0..<10).map { item("b\($0)") }
        // Only one pool item — second slot that would inject just
        // emits the base item with no replacement.
        let pool = [item("p0")]
        let result = SmartShuffle.merge(base: base, pool: pool, every: 4)
        XCTAssertEqual(
            result.merged.map(\.id),
            ["b0", "b1", "b2", "p0",
             "b3", "b4", "b5", "b6", "b7", "b8", "b9"]
        )
        XCTAssertEqual(result.injectedIds, ["p0"])
    }

    func testPoolMembersAlreadyInBaseAreSkipped() {
        // p0 is already in base, must NOT be injected (no duplicates).
        let base = [item("b0"), item("b1"), item("b2"), item("p0"), item("b3"), item("b4")]
        let pool = [item("p0"), item("p1")]
        let result = SmartShuffle.merge(base: base, pool: pool, every: 4)
        // First injection slot uses p1 (p0 filtered out).
        XCTAssertEqual(
            result.merged.map(\.id),
            ["b0", "b1", "b2", "p1", "p0", "b3", "b4"]
        )
        XCTAssertEqual(result.injectedIds, ["p1"])
    }

    func testProtectedIdsAreNotInjectedFromPool() {
        // Even though "user-queued" isn't in base, the caller wants it
        // protected from injection (typically the current track id).
        let base = [item("b0"), item("b1"), item("b2"), item("b3"), item("b4")]
        let pool = [item("user-queued"), item("p1")]
        let result = SmartShuffle.merge(
            base: base, pool: pool, every: 4, protectedIds: ["user-queued"]
        )
        XCTAssertEqual(result.injectedIds, ["p1"])
        XCTAssertFalse(result.merged.map(\.id).contains("user-queued"))
    }

    func testDuplicatePoolEntriesDeduped() {
        let base = (0..<10).map { item("b\($0)") }
        // p0 appears twice — only inject it once.
        let pool = [item("p0"), item("p0"), item("p1")]
        let result = SmartShuffle.merge(base: base, pool: pool, every: 4)
        XCTAssertEqual(result.injectedIds, ["p0", "p1"])
    }

    func testEveryClampsToMinimumTwo() {
        // every=1 would inject between every base item — clamped to 2.
        let base = [item("b0"), item("b1"), item("b2")]
        let pool = [item("p0"), item("p1"), item("p2")]
        let result = SmartShuffle.merge(base: base, pool: pool, every: 1)
        // Clamped to 2: output = b0, p0, b1, p1, b2
        XCTAssertEqual(
            result.merged.map(\.id),
            ["b0", "p0", "b1", "p1", "b2"]
        )
    }

    func testInjectionPreservesBaseOrder() {
        let base = (0..<8).map { item("b\($0)") }
        let pool = (0..<3).map { item("p\($0)") }
        let result = SmartShuffle.merge(base: base, pool: pool, every: 4)
        // Strip out injections; what remains must equal base in order.
        let baseInOutput = result.merged
            .filter { !result.injectedIds.contains($0.id) }
            .map(\.id)
        XCTAssertEqual(baseInOutput, base.map(\.id))
    }

    func testEveryThreeAlsoWorks() {
        // Spec calls out "every 3rd or 4th" as the target cadence.
        // Verify 3 produces a tighter injection pattern.
        let base = (0..<6).map { item("b\($0)") }
        let pool = (0..<3).map { item("p\($0)") }
        let result = SmartShuffle.merge(base: base, pool: pool, every: 3)
        // Injections sit BEFORE every Nth base item, so b5 (the last
        // base) doesn't get a trailing injection.
        // Output: b0, b1, p0, b2, b3, p1, b4, b5
        XCTAssertEqual(
            result.merged.map(\.id),
            ["b0", "b1", "p0", "b2", "b3", "p1", "b4", "b5"]
        )
        XCTAssertEqual(result.injectedIds, ["p0", "p1"])
    }
}
