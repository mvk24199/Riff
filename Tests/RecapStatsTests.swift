import XCTest
@testable import Riff

/// Unit tests for `RecapStats.compute(from:)` — the pure aggregation
/// driving the "Your Riff Highlights" sheet. No PlayerBridge / no
/// UserDefaults — the function takes a `[MediaItem]` directly, which
/// is the whole reason it was extracted as a static method.
final class RecapStatsTests: XCTestCase {

    // MARK: - Fixture helpers

    private func song(
        _ id: String,
        title: String? = nil,
        artist: String = "Artist",
        year: Int? = nil,
        duration: Int? = nil,
        artistId: String? = nil
    ) -> MediaItem {
        MediaItem(
            id: id,
            kind: .song,
            title: title ?? "Title-\(id)",
            subtitle: artist,
            thumbnailURL: nil,
            artistId: artistId,
            durationSeconds: duration,
            year: year
        )
    }

    // MARK: - Empty history

    func testEmptyHistoryProducesEmptyStats() {
        let stats = RecapStats.compute(from: [])

        XCTAssertTrue(stats.isEmpty)
        XCTAssertEqual(stats.totalPlays, 0)
        XCTAssertEqual(stats.uniqueTracks, 0)
        XCTAssertTrue(stats.topArtists.isEmpty)
        XCTAssertTrue(stats.topTracks.isEmpty)
        XCTAssertNil(stats.averageYear)
        XCTAssertNil(stats.totalRuntimeSeconds)
        XCTAssertNil(stats.firstPlayed)
        XCTAssertNil(stats.mostRecent)
    }

    // MARK: - Counts + ordering

    func testTotalAndUniquePlaysCount() {
        let history: [MediaItem] = [
            song("a"), song("a"), song("b"), song("c"), song("c"), song("c"),
        ]
        let stats = RecapStats.compute(from: history)

        XCTAssertEqual(stats.totalPlays, 6)
        XCTAssertEqual(stats.uniqueTracks, 3)
    }

    func testTopTracksSortedByPlayCountDesc() {
        let history: [MediaItem] = [
            song("a"), song("b"), song("b"), song("c"), song("c"), song("c"),
            song("d"), song("d"),
        ]
        let stats = RecapStats.compute(from: history)
        let order = stats.topTracks.map(\.item.id)

        XCTAssertEqual(order, ["c", "b", "d", "a"])
        XCTAssertEqual(stats.topTracks.first?.count, 3)
    }

    func testTopTracksCapsAtTen() {
        // 12 distinct tracks → only top 10 returned.
        let history: [MediaItem] = (0..<12).map { song("id-\($0)") }
        let stats = RecapStats.compute(from: history)

        XCTAssertEqual(stats.topTracks.count, 10)
    }

    func testTopArtistsSortedByPlayCountDesc() {
        let history: [MediaItem] = [
            song("a", artist: "Foo"),
            song("b", artist: "Foo"),
            song("c", artist: "Bar"),
            song("d", artist: "Bar"),
            song("e", artist: "Bar"),
            song("f", artist: "Baz"),
        ]
        let stats = RecapStats.compute(from: history)
        let names = stats.topArtists.map(\.name)

        XCTAssertEqual(names, ["Bar", "Foo", "Baz"])
        XCTAssertEqual(stats.topArtists.first?.count, 3)
    }

    func testTopArtistsCapsAtFive() {
        let history: [MediaItem] = (0..<8).map { song("t-\($0)", artist: "Artist-\($0)") }
        let stats = RecapStats.compute(from: history)

        XCTAssertEqual(stats.topArtists.count, 5)
    }

    func testArtistBucketingIsCaseInsensitive() {
        let history: [MediaItem] = [
            song("a", artist: "Foo"),
            song("b", artist: "foo"),
            song("c", artist: "FOO"),
        ]
        let stats = RecapStats.compute(from: history)

        XCTAssertEqual(stats.topArtists.count, 1)
        XCTAssertEqual(stats.topArtists.first?.count, 3)
        // First-seen casing wins for display.
        XCTAssertEqual(stats.topArtists.first?.name, "Foo")
    }

    func testEmptyArtistSubtitleIsSkipped() {
        let history: [MediaItem] = [
            song("a", artist: ""),
            song("b", artist: "   "),
            song("c", artist: "Real"),
        ]
        let stats = RecapStats.compute(from: history)

        XCTAssertEqual(stats.topArtists.map(\.name), ["Real"])
    }

    // MARK: - First / most recent

    func testFirstAndMostRecentReflectOldestNewestOrder() {
        let history: [MediaItem] = [
            song("first"),
            song("middle"),
            song("last"),
        ]
        let stats = RecapStats.compute(from: history)

        XCTAssertEqual(stats.firstPlayed?.id, "first")
        XCTAssertEqual(stats.mostRecent?.id, "last")
    }

    // MARK: - Year averaging gate

    func testAverageYearSuppressedBelowSampleThreshold() {
        // Two tracks with a year — below the min sample size of 3.
        let history: [MediaItem] = [
            song("a", year: 2020),
            song("b", year: 2024),
            song("c"),
            song("d"),
        ]
        let stats = RecapStats.compute(from: history)

        XCTAssertNil(stats.averageYear)
    }

    func testAverageYearComputedAtOrAboveThreshold() {
        let history: [MediaItem] = [
            song("a", year: 2020),
            song("b", year: 2022),
            song("c", year: 2024),
        ]
        let stats = RecapStats.compute(from: history)

        XCTAssertEqual(stats.averageYear, 2022)
    }

    func testAverageYearRoundsToNearest() {
        // (2020 + 2021 + 2023) / 3 = 2021.33 → rounds to 2021.
        let history: [MediaItem] = [
            song("a", year: 2020),
            song("b", year: 2021),
            song("c", year: 2023),
        ]
        let stats = RecapStats.compute(from: history)

        XCTAssertEqual(stats.averageYear, 2021)
    }

    // MARK: - Runtime sum

    func testTotalRuntimeSumsDurations() {
        let history: [MediaItem] = [
            song("a", duration: 180),
            song("b", duration: 240),
            song("c"),                  // no duration — skipped
            song("d", duration: 60),
        ]
        let stats = RecapStats.compute(from: history)

        XCTAssertEqual(stats.totalRuntimeSeconds, 480)
    }

    func testTotalRuntimeNilWhenNoDurations() {
        let history: [MediaItem] = [song("a"), song("b")]
        let stats = RecapStats.compute(from: history)

        XCTAssertNil(stats.totalRuntimeSeconds)
    }

    // MARK: - Windowed compute (B1)

    /// Sanity: `.allTime` over a timestamped list matches the legacy
    /// `compute(from: [MediaItem])` so the new entry point doesn't
    /// silently re-derive anything. Order matters — totals are the
    /// same, so this is the strictest comparison we can run without
    /// re-asserting every sub-stat.
    func testAllTimeMatchesLegacyCompute() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let entries: [PlayedEntry] = [
            .init(item: song("a", artist: "A", duration: 100), playedAt: now.addingTimeInterval(-100_000)),
            .init(item: song("b", artist: "B", duration: 200), playedAt: now.addingTimeInterval(-50_000)),
            .init(item: song("a", artist: "A", duration: 100), playedAt: now.addingTimeInterval(-25_000)),
        ]
        let legacy = RecapStats.compute(from: entries.map(\.item))
        let windowed = RecapStats.compute(from: entries, window: .allTime, now: now)

        XCTAssertEqual(windowed.totalPlays, legacy.totalPlays)
        XCTAssertEqual(windowed.uniqueTracks, legacy.uniqueTracks)
        XCTAssertEqual(windowed.totalRuntimeSeconds, legacy.totalRuntimeSeconds)
        XCTAssertEqual(windowed.topArtists, legacy.topArtists)
    }

    func testSevenDayWindowExcludesOlderEntries() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let day: TimeInterval = 60 * 60 * 24
        let entries: [PlayedEntry] = [
            .init(item: song("ancient", artist: "Old"), playedAt: now.addingTimeInterval(-30 * day)),
            .init(item: song("recent-1", artist: "New"), playedAt: now.addingTimeInterval(-2 * day)),
            .init(item: song("recent-2", artist: "New"), playedAt: now.addingTimeInterval(-1 * day)),
        ]
        let stats = RecapStats.compute(from: entries, window: .sevenDays, now: now)

        XCTAssertEqual(stats.totalPlays, 2)
        XCTAssertEqual(stats.uniqueTracks, 2)
        XCTAssertEqual(stats.topArtists.first?.name, "New")
    }

    func testThirtyDayWindowIncludesBoundaryEntries() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let day: TimeInterval = 60 * 60 * 24
        let entries: [PlayedEntry] = [
            // Right on the cutoff (30 days ago) — half-open lookback
            // (>= cutoff) means this counts.
            .init(item: song("edge", artist: "A"), playedAt: now.addingTimeInterval(-30 * day)),
            // One second outside.
            .init(item: song("outside", artist: "B"), playedAt: now.addingTimeInterval(-30 * day - 1)),
        ]
        let stats = RecapStats.compute(from: entries, window: .thirtyDays, now: now)

        XCTAssertEqual(stats.totalPlays, 1)
        XCTAssertEqual(stats.topTracks.first?.item.id, "edge")
    }

    func testNinetyDayWindowKeepsLastQuarter() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let day: TimeInterval = 60 * 60 * 24
        let entries: [PlayedEntry] = [
            .init(item: song("a"), playedAt: now.addingTimeInterval(-100 * day)),
            .init(item: song("b"), playedAt: now.addingTimeInterval(-80 * day)),
            .init(item: song("c"), playedAt: now.addingTimeInterval(-1 * day)),
        ]
        let stats = RecapStats.compute(from: entries, window: .ninetyDays, now: now)

        XCTAssertEqual(stats.totalPlays, 2)
        XCTAssertEqual(Set(stats.topTracks.map(\.item.id)), Set(["b", "c"]))
    }

    /// Migrated pre-B1 entries carry `Date.distantPast`. They should
    /// never appear in a bounded window — including them would lie
    /// about when they played.
    func testDistantPastEntriesExcludedFromBoundedWindows() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let entries: [PlayedEntry] = [
            .init(item: song("migrated"), playedAt: .distantPast),
            .init(item: song("today"), playedAt: now.addingTimeInterval(-3600)),
        ]
        let sevenDay = RecapStats.compute(from: entries, window: .sevenDays, now: now)
        let allTime = RecapStats.compute(from: entries, window: .allTime, now: now)

        XCTAssertEqual(sevenDay.totalPlays, 1)
        XCTAssertEqual(sevenDay.topTracks.first?.item.id, "today")
        // All-time still includes them — we have an item, we just don't
        // know when. Showing it under "All time" is honest.
        XCTAssertEqual(allTime.totalPlays, 2)
    }

    func testEmptyEntriesProducesEmptyStatsAcrossAllWindows() {
        for window in RecapWindow.allCases {
            let stats = RecapStats.compute(from: [], window: window)
            XCTAssertTrue(stats.isEmpty, "Window \(window) should be empty")
        }
    }
}
