import XCTest
@testable import Riff

final class NowPlayingSnapshotTests: XCTestCase {

    // MARK: - projectedElapsed

    func testProjectedElapsedStaticWhilePaused() {
        let snap = NowPlayingSnapshot(
            videoId: "abc",
            title: "T",
            subtitle: "S",
            thumbnailURLString: nil,
            isPlaying: false,
            updatedAt: Date(timeIntervalSinceNow: -60),
            elapsed: 30,
            duration: 200
        )
        // Paused snapshots don't extrapolate, even when 60s old.
        XCTAssertEqual(snap.projectedElapsed(at: Date()), 30, accuracy: 0.001)
    }

    func testProjectedElapsedExtrapolatesWhilePlaying() {
        let written = Date()
        let snap = NowPlayingSnapshot(
            videoId: "abc",
            title: "T",
            subtitle: "S",
            thumbnailURLString: nil,
            isPlaying: true,
            updatedAt: written,
            elapsed: 30,
            duration: 200
        )
        let later = written.addingTimeInterval(15)
        XCTAssertEqual(snap.projectedElapsed(at: later), 45, accuracy: 0.001)
    }

    func testProjectedElapsedClampedToDuration() {
        let written = Date()
        let snap = NowPlayingSnapshot(
            videoId: "abc",
            title: "T",
            subtitle: "S",
            thumbnailURLString: nil,
            isPlaying: true,
            updatedAt: written,
            elapsed: 195,
            duration: 200
        )
        // 195 + 60 = 255 would overflow; expect a clamp to duration.
        let later = written.addingTimeInterval(60)
        XCTAssertEqual(snap.projectedElapsed(at: later), 200, accuracy: 0.001)
    }

    func testProjectedElapsedNonNegativeWhenClockJumpsBackward() {
        let written = Date()
        let snap = NowPlayingSnapshot(
            videoId: "abc",
            title: "T",
            subtitle: "S",
            thumbnailURLString: nil,
            isPlaying: true,
            updatedAt: written,
            elapsed: 30,
            duration: 200
        )
        // Clock-skew safety: an at-time before the write should not
        // produce negative deltas. The implementation max-zeroes the
        // gap.
        let earlier = written.addingTimeInterval(-10)
        XCTAssertEqual(snap.projectedElapsed(at: earlier), 30, accuracy: 0.001)
    }

    // MARK: - thumbnailURL

    func testThumbnailURLNilOnMissingString() {
        let snap = NowPlayingSnapshot(
            videoId: "x", title: "T", subtitle: "S",
            thumbnailURLString: nil,
            isPlaying: false, updatedAt: Date(),
            elapsed: 0, duration: 0
        )
        XCTAssertNil(snap.thumbnailURL)
    }

    func testThumbnailURLNilOnEmptyString() {
        let snap = NowPlayingSnapshot(
            videoId: "x", title: "T", subtitle: "S",
            thumbnailURLString: "",
            isPlaying: false, updatedAt: Date(),
            elapsed: 0, duration: 0
        )
        XCTAssertNil(snap.thumbnailURL)
    }

    // MARK: - Codable round-trip

    func testCodableRoundTrip() throws {
        let original = NowPlayingSnapshot(
            videoId: "abc123",
            title: "Title",
            subtitle: "Artist - Album",
            thumbnailURLString: nil,
            isPlaying: true,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            elapsed: 42.5,
            duration: 180
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(NowPlayingSnapshot.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    // MARK: - WidgetCommand

    func testWidgetCommandRawValueRoundTrip() {
        // Adding a new case without a corresponding RawValue migration
        // would silently break widget-to-app dispatch. Lock down the
        // current rawvalues so renames trip CI rather than the user.
        XCTAssertEqual(WidgetCommand.togglePlay.rawValue, "togglePlay")
        XCTAssertEqual(WidgetCommand.next.rawValue, "next")
        XCTAssertEqual(WidgetCommand.previous.rawValue, "previous")
        XCTAssertEqual(WidgetCommand(rawValue: "togglePlay"), .togglePlay)
        XCTAssertNil(WidgetCommand(rawValue: "unknown"))
    }
}
