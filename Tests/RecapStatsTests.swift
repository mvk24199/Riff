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
}
