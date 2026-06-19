import Foundation

/// Pure helpers powering the Library section's sort + pin behavior,
/// and (B7) the shared track-list sort used on every other list
/// surface (album / playlist detail, search results).
///
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

    // MARK: - B7: shared track-list sort

    /// Sort orders for individual track lists (album / playlist
    /// tracklist, search results, anywhere the rows are songs).
    ///
    /// Distinct from `LibraryView.SortOrder` because the semantics
    /// differ: the Library grid sorts heterogeneous tiles (albums,
    /// playlists, artists, podcasts) where "duration" has no honest
    /// per-tile definition. Track lists are homogeneous songs/episodes,
    /// so we add `durationShortest` / `durationLongest` and drop
    /// `recentlyAdded` (which collapses to `original` for a tracklist —
    /// the server-provided order *is* the tracklist's "recently added").
    ///
    /// `playCount` / `lastPlayed` mirror the Library helpers above —
    /// both derive from the local `PlayedEntry` journal.
    enum TrackSortOrder: String, CaseIterable, Identifiable, Sendable {
        /// Server / source order. For an album this is the album track
        /// order; for a playlist this is "recently added" (newest first
        /// in YT Music's response); for search this is YT's relevance
        /// ranking. Label adapts via `displayName(for:)`.
        case original = "original"
        case aToZ = "aToZ"
        case zToA = "zToA"
        case playCount = "playCount"
        case lastPlayed = "lastPlayed"
        case durationShortest = "durationShortest"
        case durationLongest = "durationLongest"

        var id: String { rawValue }

        /// User-facing label. `original` morphs per surface so it reads
        /// naturally — "Album order" feels right on an album page,
        /// "Playlist order" on a playlist, "Relevance" on search. The
        /// caller supplies the surface; the enum carries the verbiage.
        func displayName(for surface: TrackSortSurface) -> String {
            switch self {
            case .original:
                switch surface {
                case .album:    return "Album order"
                case .playlist: return "Playlist order"
                case .search:   return "Relevance"
                case .generic:  return "Original order"
                }
            case .aToZ:             return "A to Z"
            case .zToA:             return "Z to A"
            case .playCount:        return "Most played"
            case .lastPlayed:       return "Last played"
            case .durationShortest: return "Shortest first"
            case .durationLongest:  return "Longest first"
            }
        }

        /// Whether this sort needs `PlayedEntry` history to be meaningful.
        /// Surfaces that never carry history (e.g. search results pre-play)
        /// still show the options — the user just sees an unsorted tail
        /// for items they haven't played yet, which is honest and matches
        /// how the Library section handles the same case.
        var requiresPlayHistory: Bool {
            switch self {
            case .playCount, .lastPlayed: return true
            default:                      return false
            }
        }

        /// Whether this sort needs `durationSeconds` to be meaningful.
        /// Items missing a duration sort to the end under both duration
        /// orders — we'd rather show them in a predictable trailing
        /// position than hide them or shuffle them randomly.
        var requiresDuration: Bool {
            switch self {
            case .durationShortest, .durationLongest: return true
            default:                                  return false
            }
        }
    }

    /// Which list surface a `TrackSortOrder` is being applied to.
    /// Used purely to pick the right label for the `.original` case
    /// (the sort math is identical across surfaces).
    enum TrackSortSurface: Sendable {
        case album
        case playlist
        case search
        case generic
    }

    /// Apply a `TrackSortOrder` to a homogeneous list of tracks.
    ///
    /// Pure function: no `AppEnvironment`, no SwiftUI, no side effects.
    /// Tests in `LibrarySortingTests` exercise this directly.
    ///
    /// `entries` powers the play-count / last-played orders; the caller
    /// passes `env.player.playedEntries` (or `[]` if the surface has no
    /// concept of local history).
    ///
    /// Stable: all tie-breaks fall through to alphabetical title order
    /// so SwiftUI doesn't shuffle rows on every play-count tick or
    /// every duration round-trip.
    static func sortTracks(
        _ items: [MediaItem],
        by order: TrackSortOrder,
        entries: [PlayedEntry] = []
    ) -> [MediaItem] {
        switch order {
        case .original:
            return items
        case .aToZ:
            return items.sorted { lhs, rhs in
                lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
        case .zToA:
            return items.sorted { lhs, rhs in
                lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedDescending
            }
        case .playCount:
            let counts = playCounts(from: entries)
            return items.sorted { lhs, rhs in
                let l = counts[lhs.id] ?? 0
                let r = counts[rhs.id] ?? 0
                if l == r {
                    return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
                }
                return l > r  // most-played first
            }
        case .lastPlayed:
            let last = lastPlayed(from: entries)
            return items.sorted { lhs, rhs in
                let l = last[lhs.id] ?? .distantPast
                let r = last[rhs.id] ?? .distantPast
                if l == r {
                    return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
                }
                return l > r  // most-recent first
            }
        case .durationShortest:
            return items.sorted { lhs, rhs in
                // Missing durations sort to the end. Using Int.max as a
                // sentinel keeps the comparator stable: items without a
                // duration always lose to items that have one, and tie
                // amongst themselves on title.
                let l = lhs.durationSeconds ?? Int.max
                let r = rhs.durationSeconds ?? Int.max
                if l == r {
                    return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
                }
                return l < r
            }
        case .durationLongest:
            return items.sorted { lhs, rhs in
                // Missing durations sort to the end. Using -1 as a
                // sentinel keeps "no duration" strictly less than every
                // real duration, so they trail under the descending
                // comparator below.
                let l = lhs.durationSeconds ?? -1
                let r = rhs.durationSeconds ?? -1
                if l == r {
                    return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
                }
                return l > r
            }
        }
    }
}
