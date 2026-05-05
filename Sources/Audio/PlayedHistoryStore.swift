import Foundation

/// Tiny encapsulation of the locally-persisted played-history journal.
/// Pulled out of `PlayerBridge` (audit §6.8) so the journal lifecycle
/// has one obvious owner. The rest of `PlayerBridge` keeps its own
/// in-memory `playedHistory` array for SwiftUI observation; this type
/// owns the disk side only.
///
/// Writes are eager — every `archive(_:)` synchronously persists.
/// History is small (cap 50 items) so the encode cost is microseconds
/// and an unexpected crash never loses more than the *current* track.
///
/// **Storage isolation:** `defaults` is injectable. Production uses
/// `.standard`; tests inject a per-suite `UserDefaults(suiteName:)` so
/// fixture data never bleeds into the running app's history. (Found
/// the hard way: a previous version used `.standard` unconditionally,
/// and `xcodebuild test` polluted production defaults with rows like
/// `{title: "T", subtitle: "Artist"}` from test fixtures.)
///
/// **Storage key versioning:** the `v2` suffix is a one-time wipe to
/// clear test pollution from existing user installs. Future schema
/// changes should bump the version in the same way; UserDefaults
/// supports millions of orphan keys without ill effect, so the
/// abandoned `v1` key is safe to leave.
struct PlayedHistoryStore {
    private static let key = "player.history.v2"
    let cap: Int
    let defaults: UserDefaults

    init(cap: Int, defaults: UserDefaults = .standard) {
        self.cap = cap
        self.defaults = defaults
        // Opportunistic one-time cleanup of the legacy key. Cheap and
        // bounded: it runs once per process. Anyone whose v1 store had
        // legitimate data loses it; in practice the only people with
        // v1 data are the developer running tests, and this is the
        // entry point for the pollution-fix anyway.
        defaults.removeObject(forKey: "player.history")
    }

    /// Load whatever was journalled in the last session. Trimmed to
    /// `cap` so a corrupted/giant store can't balloon memory; the
    /// most-recent N are kept (history is appended in chronological
    /// order, so `suffix()` preserves the latest plays).
    func load() -> [MediaItem] {
        guard let data = defaults.data(forKey: Self.key),
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
        defaults.set(data, forKey: Self.key)
    }

    /// Used on Sign Out to wipe the journal — keeps the next user of
    /// this Mac (or the same user who deliberately signed out) from
    /// seeing the previous session's plays.
    func clear() {
        defaults.removeObject(forKey: Self.key)
    }
}
