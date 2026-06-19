import Foundation

/// Pure logic for B5 Smart Shuffle.
///
/// Smart Shuffle injects related-song recommendations into the visible
/// Up Next queue at a fixed cadence (every Nth slot). Each injected
/// item carries a "+" badge in the QueueRow so the user knows it's a
/// suggestion rather than a track from the current playlist / radio.
///
/// The merge logic is split out as a free function so it's
/// unit-testable without standing up a `PlayerBridge` or hitting the
/// JS bridge. Production code path: `PlayerBridge.applySmartShuffle`
/// → `SmartShuffle.merge` → `QueueManager.replaceQueue`.
enum SmartShuffle {
    /// Default cadence — every 4th slot becomes an injected
    /// recommendation. Matches Spotify's observed Smart Shuffle
    /// rhythm (1-2 base tracks, 1 suggestion, ~25% of the queue).
    static let defaultEvery: Int = 4

    /// Result of merging the base queue with the recommendation pool.
    struct Result: Equatable {
        /// The new merged Up Next list (preserves base order; injected
        /// items occupy every Nth position).
        let merged: [MediaItem]
        /// VideoIds of items that came from the recommendation pool.
        /// QueueRow reads this to render the "+" badge.
        let injectedIds: Set<String>
    }

    /// Interleave `base` with one item from `pool` at every Nth
    /// position. The first injection lands at index `every - 1`
    /// (1-indexed: "every 4th slot" means slot 4, slot 8, …).
    ///
    /// - Items already present in `base` are filtered out of the pool
    ///   to avoid duplicates.
    /// - `protectedIds` (the currently-playing track, anything the
    ///   user explicitly queued) are never replaced — they stay where
    ///   they are; the injection slides in around them.
    /// - When the pool runs dry the remainder of the base list passes
    ///   through unchanged. We don't loop the pool — repeating the
    ///   same suggestion every 4 slots would be worse than no
    ///   suggestion at all.
    /// - `every` is clamped to `>= 2`. Zero/one would inject between
    ///   every base item, which isn't "every Nth" — it'd dominate the
    ///   queue.
    ///
    /// The returned `merged` array can be longer than `base` by up
    /// to `base.count / (every - 1)` items.
    static func merge(
        base: [MediaItem],
        pool: [MediaItem],
        every: Int = defaultEvery,
        protectedIds: Set<String> = []
    ) -> Result {
        let step = max(2, every)
        let baseIds = Set(base.map(\.id))
        // Pool minus anything already in the base queue, minus protected
        // ids (which are necessarily in the base queue but we double-
        // check for callers that pass a stale base snapshot).
        var remainingPool = pool.filter { item in
            !baseIds.contains(item.id) && !protectedIds.contains(item.id)
        }
        // Also dedup the pool itself in case the caller handed us a
        // related-songs list with repeats.
        var seenPool = Set<String>()
        remainingPool = remainingPool.filter { item in
            if seenPool.contains(item.id) { return false }
            seenPool.insert(item.id)
            return true
        }

        guard !remainingPool.isEmpty, !base.isEmpty else {
            return Result(merged: base, injectedIds: [])
        }

        var merged: [MediaItem] = []
        var injectedIds = Set<String>()
        // `slotsSinceInjection` counts base items emitted since the
        // last injection (or since the start). When it hits `step - 1`
        // we emit a recommendation BEFORE the next base item, so
        // injections sit at positions step, 2*step, … in the output.
        var slotsSinceInjection = 0
        for item in base {
            if slotsSinceInjection >= step - 1, let pick = remainingPool.first {
                remainingPool.removeFirst()
                merged.append(pick)
                injectedIds.insert(pick.id)
                slotsSinceInjection = 0
            }
            merged.append(item)
            slotsSinceInjection += 1
        }
        return Result(merged: merged, injectedIds: injectedIds)
    }
}
