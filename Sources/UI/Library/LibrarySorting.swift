import Foundation

/// Pure helpers powering the Library section's sort + pin behavior.
/// Lifted out of `LibraryView` so they're directly testable without
/// spinning up an `AppEnvironment` + the SwiftUI view tree.
///
/// The Library tab treats Liked Songs as a real filterable playlist —
/// users can sort the same row set by recency, alphabetical order, OR
/// (for Liked specifically) by their own listening behavior:
///   - **Play count**: how many `PlayedEntry` rows match this item's id.
///   - **Last played**: max `playedAt` over the same matching entries.
///
/// We derive both stats from the local `PlayedEntry` journal because
/// InnerTube doesn't return per-track play counts on the Liked Songs
/// browse response. That's fine — the journal is the only source of
/// truth the user actually trusts ("how often have *I* played this").
enum LibrarySorting {

    /// Build a `id → play count` map over a `playedEntries` journal.
    /// O(N) over the journal. Caller materializes once per sort pass
    /// rather than re-counting per item.
    static func playCounts(from entries: [PlayedEntry]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for entry in entries {
            counts[entry.item.id, default: 0] += 1
        }
        return counts
    }

    /// Build a `id → most-recent playedAt` map. Items missing from the
    /// journal don't appear in the dict — callers should treat absence
    /// as "never played" and sort accordingly.
    static func lastPlayed(from entries: [PlayedEntry]) -> [String: Date] {
        var last: [String: Date] = [:]
        for entry in entries {
            if let existing = last[entry.item.id] {
                if entry.playedAt > existing {
                    last[entry.item.id] = entry.playedAt
                }
            } else {
                last[entry.item.id] = entry.playedAt
            }
        }
        return last
    }

    /// Reorder `items` so anything whose id is in `pinned` floats to
    /// the front, preserving the relative order of both halves.
    ///
    /// Stable partition (not a re-sort by pin status alone), so the
    /// user's chosen sort order is still respected within the pinned
    /// and unpinned groups. Example: if the sort is "Recently added"
    /// and the user pins the 5th and 12th items, the result is
    /// `[item5, item12, item1, item2, item3, item4, item6, …]`.
    static func partitionPinned(_ items: [MediaItem], pinned: Set<String>) -> [MediaItem] {
        guard !pinned.isEmpty else { return items }
        var pinnedHead: [MediaItem] = []
        var rest: [MediaItem] = []
        pinnedHead.reserveCapacity(min(pinned.count, items.count))
        rest.reserveCapacity(items.count)
        for item in items {
            if pinned.contains(item.id) {
                pinnedHead.append(item)
            } else {
                rest.append(item)
            }
        }
        return pinnedHead + rest
    }
}
