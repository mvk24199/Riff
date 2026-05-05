import Foundation

/// Tiny encapsulation of the locally-persisted played-history journal.
/// Pulled out of `PlayerBridge` (audit §6.8 — "PlayerBridge becoming a
/// god class") so the journal lifecycle has one obvious owner. The
/// rest of `PlayerBridge` keeps its own in-memory `playedHistory`
/// array for SwiftUI observation; this type owns the disk side only.
///
/// Writes are eager — every `append(_:)` synchronously persists. The
/// history is small (cap 50 items) so the encode cost is in the
/// micro-second range and an unexpected crash never loses more than
/// the *current* track.
///
/// Why UserDefaults rather than a real DB or an on-disk JSON file:
/// the data is tiny, it's per-user (UserDefaults already scopes to
/// the bundle id), and macOS atomically replaces the plist on every
/// write so partial corruption is unreachable. A real DB would be
/// over-engineering for ~50 song-row dictionaries.
struct PlayedHistoryStore {
    private static let key = "player.history"
    let cap: Int

    /// Load whatever was journalled in the last session. Trimmed to
    /// `cap` so a corrupted/giant store can't balloon memory; the
    /// most-recent N are kept (history is appended in chronological
    /// order, so suffix() preserves the latest plays).
    func load() -> [MediaItem] {
        guard let data = UserDefaults.standard.data(forKey: Self.key),
              let decoded = try? JSONDecoder().decode([MediaItem].self, from: data) else {
            return []
        }
        return Array(decoded.suffix(cap))
    }

    /// Persist the current full history. Caller is responsible for
    /// applying `cap` before passing it in — keeps the rule "the
    /// in-memory array is the source of truth, this just mirrors it"
    /// from drifting.
    func save(_ items: [MediaItem]) {
        guard let data = try? JSONEncoder().encode(items) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }

    /// Used on Sign Out to wipe the journal — keeps the next user of
    /// this Mac (or the same user who deliberately signed out) from
    /// seeing the previous session's plays.
    func clear() {
        UserDefaults.standard.removeObject(forKey: Self.key)
    }
}
