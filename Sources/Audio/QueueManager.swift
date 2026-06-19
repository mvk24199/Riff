import Foundation
import Observation

/// Owns Riff's local "Up Next" queue and the played-history log.
///
/// Extracted from `PlayerBridge` per the audit (§6.8) so the queue
/// surface has one obvious owner. PlayerBridge keeps a `let queue:
/// QueueManager` and exposes pass-through computed properties so the
/// SwiftUI views (`env.player.upNext`, `env.player.playedHistory`)
/// don't change — observation still fires through the nested
/// `@Observable` because every read goes through `queue.upNext`.
///
/// Local-only caveat: `upNext` is *Riff's* view of what plays next.
/// The hidden WKWebView keeps its own server-driven queue. Mutating
/// `upNext` doesn't propagate to the WebView — when YT autoplays the
/// next track, it picks from its own queue, not ours. The intended
/// UX is that the user clicks an Up-Next row to jump to it
/// immediately, which IS sent to the WebView via `play(item:)`. See
/// PLAN.md and ARCHITECTURE.md for the rationale.
@Observable
@MainActor
final class QueueManager {
    /// Upcoming tracks shown in the Up Next pane. Replaced wholesale
    /// when `/next` returns or a Tune chip is applied; otherwise
    /// mutated by the user (move / remove / playNext / addToEnd).
    private(set) var upNext: [MediaItem] = []

    /// Tracks heard earlier in this session (most-recent last).
    /// Persisted across launches via `PlayedHistoryStore`.
    ///
    /// Mirrors the items in `playedEntries` for the legacy callers
    /// (Recap, Up-Next pane "Recently played" rows) that don't care
    /// about the played-at timestamp. The Stats surface (B1) reads
    /// `playedEntries` directly so it can filter by recency.
    var playedHistory: [MediaItem] { playedEntries.map(\.item) }

    /// Timestamped played history (most-recent last). Source of truth
    /// since B1; `playedHistory` derives from this. Persisted via
    /// `PlayedHistoryStore` under the v3 key — see that file for the
    /// v2 → v3 migration story.
    private(set) var playedEntries: [PlayedEntry] = []

    /// History cap. Enforced both in-memory and on the persisted
    /// journal so an old corrupted store can't balloon memory.
    ///
    /// Default bumped from 50 → 500 with B1: the Stats surface offers
    /// 7d / 30d / 90d windows and 50 entries doesn't get an active
    /// listener through a single weekend. 500 entries is ~25 KB at
    /// the encoded MediaItem size, so the synchronous-write cost
    /// stays in microseconds.
    @ObservationIgnored private let historyCap: Int
    @ObservationIgnored private let historyStore: PlayedHistoryStore

    /// `defaults` is injectable for tests so fixture history can't
    /// leak into the production `UserDefaults.standard`. Production
    /// callers should pass nothing and let it default.
    init(historyCap: Int = 500, defaults: UserDefaults = .standard) {
        self.historyCap = historyCap
        self.historyStore = PlayedHistoryStore(cap: historyCap, defaults: defaults)
        self.playedEntries = historyStore.load()
    }

    // MARK: - Up Next mutation

    /// Replace the whole upcoming queue. Called by PlayerBridge after
    /// a fresh `/next` response or when a Tune chip applies.
    func replaceQueue(_ items: [MediaItem]) {
        upNext = items
    }

    /// Clear `upNext`. Used during track transitions where we want a
    /// clean state until the next `/next` round-trip resolves.
    func clearQueue() {
        upNext = []
    }

    /// Insert at the top of `upNext` ("Play next" semantics). Dedupes:
    /// if the item is already queued elsewhere, it's moved rather
    /// than duplicated.
    func playNext(_ item: MediaItem) {
        upNext.removeAll { $0.id == item.id }
        upNext.insert(item, at: 0)
    }

    /// Append to the bottom ("Add to queue"). No-op when the item is
    /// already queued so the user can hit the menu twice without
    /// stacking duplicates.
    func addToEnd(_ item: MediaItem) {
        if upNext.contains(where: { $0.id == item.id }) { return }
        upNext.append(item)
    }

    /// Remove a row by `videoId`. Local-only — the WebView's queue
    /// still has it; this is a Riff-side display preference.
    func remove(videoId: String) {
        upNext.removeAll { $0.id == videoId }
    }

    /// Reorder a row by ±offset. Clamps within `[0, count-1]`. Same
    /// local-only caveat as `remove`.
    func move(videoId: String, by offset: Int) {
        guard let index = upNext.firstIndex(where: { $0.id == videoId }) else { return }
        let newIndex = max(0, min(upNext.count - 1, index + offset))
        guard newIndex != index else { return }
        let item = upNext.remove(at: index)
        upNext.insert(item, at: newIndex)
    }

    // MARK: - History

    /// Append `item` to played history. Skips when the same id was
    /// already at the tail (avoids duplicates from re-poll events).
    /// Persists synchronously — the journal is small (~50 items),
    /// the encode cost is microseconds, and the synchronous write
    /// means an unexpected crash never loses more than the *current*
    /// track.
    func archive(_ item: MediaItem, at date: Date = Date()) {
        if playedEntries.last?.item.id == item.id { return }
        playedEntries.append(PlayedEntry(item: item, playedAt: date))
        if playedEntries.count > historyCap {
            playedEntries.removeFirst(playedEntries.count - historyCap)
        }
        historyStore.save(playedEntries)
    }

    /// Wipe the persisted journal. Wired to Sign Out so the next user
    /// of this Mac doesn't see the previous user's plays. The
    /// in-memory `playedHistory` is left untouched — sign-out is
    /// already a destructive operation; if the user wants a clean
    /// slate they can also restart.
    func clearPersistedHistory() {
        historyStore.clear()
    }
}
