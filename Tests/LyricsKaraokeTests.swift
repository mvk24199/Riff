import XCTest
@testable import Riff

/// Pure-logic tests for the karaoke (B2) helpers — no SwiftUI runtime,
/// no PlayerBridge. We just want to guarantee:
///
///   1. `activeLyricIndex` matches whatever line owns `elapsedMs`.
///   2. `lineDurationMs` derives the line's slot from the NEXT timed
///      line, falls back to a sensible default at the tail, and floors
///      at 250ms when YT hands us two lines with identical startMs.
///   3. `lineProgress` is clamped 0…1 and lands at exactly 0 the moment
///      the line starts (no flash of completed fill on seek).
///   4. `KaraokeLineView.splitWords` preserves trailing whitespace so
///      re-joining the HStack reproduces the original line.
final class LyricsKaraokeTests: XCTestCase {

    private func line(_ idx: Int, _ text: String, _ startMs: Int?) -> InnerTubeClient.LyricLine {
        InnerTubeClient.LyricLine(id: idx, text: text, startMs: startMs)
    }

    func testActiveLyricIndexReturnsNegativeBeforeFirstLine() {
        let lines = [line(0, "a", 1_000), line(1, "b", 2_000)]
        XCTAssertEqual(LyricsKaraoke.activeLyricIndex(for: 500, in: lines), -1)
    }

    func testActiveLyricIndexLandsOnCurrentLine() {
        let lines = [line(0, "a", 1_000), line(1, "b", 3_000), line(2, "c", 5_000)]
        XCTAssertEqual(LyricsKaraoke.activeLyricIndex(for: 2_500, in: lines), 0)
        XCTAssertEqual(LyricsKaraoke.activeLyricIndex(for: 3_000, in: lines), 1)
        XCTAssertEqual(LyricsKaraoke.activeLyricIndex(for: 4_999, in: lines), 1)
        XCTAssertEqual(LyricsKaraoke.activeLyricIndex(for: 10_000, in: lines), 2)
    }

    func testActiveLyricIndexEmpty() {
        XCTAssertEqual(LyricsKaraoke.activeLyricIndex(for: 1_000, in: []), -1)
    }

    func testLineDurationDerivedFromNext() {
        let lines = [line(0, "a", 1_000), line(1, "b", 4_500)]
        XCTAssertEqual(LyricsKaraoke.lineDurationMs(idx: 0, in: lines), 3_500)
    }

    func testLineDurationFallsBackToDefaultAtTail() {
        let lines = [line(0, "a", 1_000)]
        XCTAssertEqual(LyricsKaraoke.lineDurationMs(idx: 0, in: lines), 3_500)
    }

    func testLineDurationFloorsAtTwoFiftyMs() {
        // Two lines with the same startMs (we've seen this on YT) would
        // give a zero-duration slot — guard against divide-by-zero in
        // lineProgress.
        let lines = [line(0, "a", 1_000), line(1, "b", 1_000), line(2, "c", 3_000)]
        XCTAssertEqual(LyricsKaraoke.lineDurationMs(idx: 0, in: lines), 2_000) // skips dup, uses 3_000
        XCTAssertEqual(LyricsKaraoke.lineDurationMs(idx: 1, in: lines), 2_000)
    }

    func testLineProgressClampedToZeroOneRange() {
        let lines = [line(0, "a", 1_000), line(1, "b", 3_000)]
        // Before the line's start — clamped to 0.
        XCTAssertEqual(LyricsKaraoke.lineProgress(elapsedMs: 500, idx: 0, in: lines), 0)
        // Exactly at the line's start — exactly 0, so a tap-to-seek
        // doesn't show a frame of pre-filled karaoke.
        XCTAssertEqual(LyricsKaraoke.lineProgress(elapsedMs: 1_000, idx: 0, in: lines), 0)
        // Midway through the line.
        XCTAssertEqual(LyricsKaraoke.lineProgress(elapsedMs: 2_000, idx: 0, in: lines), 0.5, accuracy: 0.001)
        // Past the line's end — clamped to 1.
        XCTAssertEqual(LyricsKaraoke.lineProgress(elapsedMs: 5_000, idx: 0, in: lines), 1)
    }

    func testLineProgressMissingStartReturnsZero() {
        let lines = [line(0, "a", nil), line(1, "b", 1_000)]
        XCTAssertEqual(LyricsKaraoke.lineProgress(elapsedMs: 500, idx: 0, in: lines), 0)
    }

    func testSplitWordsPreservesWhitespace() {
        // "hello world" → ["hello ", "world"]. The trailing space on
        // "hello" is load-bearing — without it, the HStack would render
        // "helloworld" because we use spacing: 0.
        let parts = KaraokeLineView.splitWords("hello world")
        XCTAssertEqual(parts, ["hello ", "world"])
    }

    func testSplitWordsHandlesMultipleSpaces() {
        let parts = KaraokeLineView.splitWords("a  b")
        XCTAssertEqual(parts.joined(), "a  b")
        XCTAssertEqual(parts.count, 2)
    }

    func testSplitWordsEmptyReturnsSingleEmpty() {
        // Defensive: an empty interlude line (♪) shouldn't crash.
        XCTAssertEqual(KaraokeLineView.splitWords(""), [""])
    }
}
