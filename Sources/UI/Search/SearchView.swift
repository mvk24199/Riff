import SwiftUI

struct SearchView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var query: String = ""
    @State private var filter: SearchFilter = .all
    @State private var yearFilter: YearFilter = .any
    @State private var durationFilter: DurationFilter = .any
    @State private var results: [MediaItem] = []
    @State private var searching: Bool = false
    @State private var errorMessage: String?

    enum SearchFilter: String, CaseIterable, Identifiable {
        case all = "All", songs = "Songs", albums = "Albums", playlists = "Playlists", artists = "Artists", podcasts = "Podcasts"
        var id: String { rawValue }

        /// `params` token sent to /search to scope results. Values cribbed
        /// from `ytmusicapi`'s `parsers/search.py` — they keep these
        /// current; my earlier hand-rolled trailing bytes were wrong and
        /// returned empty result sets for everything except songs.
        var paramsToken: String? {
            switch self {
            case .all:       return nil
            case .songs:     return "EgWKAQIIAWoQEAMQBBAJEA4QChAFEBEQEBAV"
            case .albums:    return "EgWKAQIYAWoQEAMQBBAJEA4QChAFEBEQEBAV"
            case .playlists: return "EgWKAQIoAWoQEAMQBBAJEA4QChAFEBEQEBAV"
            case .artists:   return "EgWKAQIgAWoQEAMQBBAJEA4QChAFEBEQEBAV"
            case .podcasts:  return "EgWKAQJQAWoQEAMQBBAJEA4QChAFEBEQEBAV"
            }
        }
    }

    /// Year buckets — coarse decadal slices that map to InnerTube's
    /// `year` field on `MediaItem`. InnerTube doesn't expose a
    /// `params` token for year filtering on `/search`, so this is a
    /// client-side post-filter applied to the result set.
    ///
    /// Items without a parsed year are dropped under any non-`.any`
    /// filter — better to under-show than to surface unrelated items
    /// the user might think the filter excluded.
    enum YearFilter: String, CaseIterable, Identifiable {
        case any    = "Any year"
        case y2020s = "2020s"
        case y2010s = "2010s"
        case y2000s = "2000s"
        case older  = "Pre-2000"
        var id: String { rawValue }

        func matches(_ year: Int?) -> Bool {
            switch self {
            case .any:    return true
            case .y2020s: return (year ?? -1) >= 2020
            case .y2010s: return (year ?? -1) >= 2010 && (year ?? Int.max) < 2020
            case .y2000s: return (year ?? -1) >= 2000 && (year ?? Int.max) < 2010
            case .older:  return (year ?? 0) > 0 && (year ?? Int.max) < 2000
            }
        }
    }

    /// Length buckets for songs / episodes. Same client-side
    /// post-filter rationale as `YearFilter`. Only applied to
    /// kinds that carry duration — albums/playlists/artists pass
    /// through regardless so we don't accidentally exclude them.
    enum DurationFilter: String, CaseIterable, Identifiable {
        case any    = "Any length"
        case short  = "Short (< 3 min)"
        case medium = "3–7 min"
        case long   = "Long (7+ min)"
        var id: String { rawValue }

        func matches(_ kind: MediaItem.Kind, _ seconds: Int?) -> Bool {
            if self == .any { return true }
            // Don't apply to types that aren't audio tracks.
            guard kind == .song || kind == .episode else { return true }
            guard let s = seconds else { return false }
            switch self {
            case .any:    return true
            case .short:  return s < 180
            case .medium: return s >= 180 && s < 420
            case .long:   return s >= 420
            }
        }
    }

    /// Apply the year + duration filters on top of the network
    /// results. Network response is cached in `results`; this gets
    /// re-evaluated on every filter change without a refetch.
    private var displayedResults: [MediaItem] {
        results.filter { item in
            yearFilter.matches(item.year) && durationFilter.matches(item.kind, item.durationSeconds)
        }
    }

    /// True when at least one refinement is active.
    private var isFiltering: Bool {
        yearFilter != .any || durationFilter != .any
    }

    var body: some View {
        @Bindable var env = env
        NavigationStack(path: $env.searchNavPath) { searchContent }
    }

    private var searchContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            TextField("Search", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 24)
                .padding(.top, 8)

            // Pill-style filter row mirroring YT Music's chips. Horizontal
            // scroll keeps it from clipping when the user resizes the
            // window narrow.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(SearchFilter.allCases) { f in
                        FilterChip(
                            label: f.rawValue,
                            selected: filter == f,
                            action: { filter = f }
                        )
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 4)
            }

            // Refinement row — year + duration buckets. Only visible
            // when results exist, so the search input doesn't look
            // overwhelmed when the user hasn't typed yet. Both filter
            // groups scroll horizontally as a single row; a thin
            // section divider separates them visually.
            if !results.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(YearFilter.allCases) { y in
                            RefinementChip(
                                label: y.rawValue,
                                selected: yearFilter == y,
                                action: { yearFilter = y }
                            )
                        }
                        Divider()
                            .frame(height: 16)
                            .padding(.horizontal, 4)
                        ForEach(DurationFilter.allCases) { d in
                            RefinementChip(
                                label: d.rawValue,
                                selected: durationFilter == d,
                                action: { durationFilter = d }
                            )
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 2)
                }
                if isFiltering {
                    HStack(spacing: 6) {
                        Text("\(displayedResults.count) of \(results.count) matches")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.75))
                        Button("Clear") {
                            yearFilter = .any
                            durationFilter = .any
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.red)
                    }
                    .padding(.horizontal, 24)
                }
            }

            ScrollView {
                if let errorMessage {
                    ErrorBanner(message: errorMessage) {
                        Task { await debouncedRunSearch() }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 12)
                }
                if searching && results.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Searching…")
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.75))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 60)
                } else if query.isEmpty && results.isEmpty {
                    // Pre-search empty state. Without this the user sees
                    // an unstyled blank surface the moment they wipe the
                    // field, which reads as "broken". The prompt mirrors
                    // YT Music's "Find your music" rest state.
                    InitialSearchState()
                        .padding(.top, 80)
                } else if results.isEmpty, !query.isEmpty {
                    EmptySearchState(query: query)
                        .padding(.top, 80)
                } else if !results.isEmpty && displayedResults.isEmpty {
                    // Refinement narrowed to zero. Distinct from a
                    // genuine "no results for query" — the network
                    // came back fine; the local filter is the gate.
                    VStack(spacing: 8) {
                        Text("No results match these filters.")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.85))
                        Button("Clear refinements") {
                            yearFilter = .any
                            durationFilter = .any
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 80)
                } else if !results.isEmpty {
                    resultList
                        .padding(.horizontal, 24)
                }
            }
        }
        // Re-run on every (query, filter) change. The 300ms debounce
        // collapses bursts of keystrokes into a single request; .task(id:)
        // cancels the previous in-flight search when inputs change.
        .task(id: SearchInput(query: query, filter: filter)) {
            await debouncedRunSearch()
        }
        .navigationDestination(for: MediaItem.self) { DetailView(item: $0) }
    }

    /// "Top result" hero card + list rows for the rest. Mirrors YT
    /// Music's search layout — the first result is rendered in a wide
    /// card with a prominent Play pill, the remainder as compact list
    /// rows. We also break the list at the kind boundary (Songs /
    /// Albums / Artists / etc.) under the "All" filter so users can
    /// scan by category, the way YT Music does.
    @ViewBuilder
    private var resultList: some View {
        if let top = displayedResults.first {
            VStack(alignment: .leading, spacing: 16) {
                Text("Top result")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.top, 8)
                TopResultCard(item: top)
                if displayedResults.count > 1 {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: []) {
                        ForEach(groupedRest(), id: \.title) { group in
                            if !group.title.isEmpty {
                                Text(group.title)
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 4)
                                    .padding(.top, 16)
                                    .padding(.bottom, 8)
                            }
                            ForEach(group.items) { item in
                                SearchResultRow(item: item)
                            }
                        }
                    }
                }
            }
            .padding(.bottom, 16)
        }
    }

    /// Buckets `displayedResults[1...]` (everything after the top
    /// result) by kind. Under specific-kind filters we collapse to a
    /// single nameless group so we don't show a redundant header.
    private func groupedRest() -> [(title: String, items: [MediaItem])] {
        let rest = Array(displayedResults.dropFirst())
        guard filter == .all else {
            return [(title: "", items: rest)]
        }
        // Preserve YT's original ordering (search shelves come back in
        // a deliberate sequence — Songs first when relevant, etc.) by
        // walking once and only emitting a header when the kind changes.
        var groups: [(title: String, items: [MediaItem])] = []
        var seenKinds: Set<MediaItem.Kind> = []
        for item in rest {
            let title = pluralKind(item.kind)
            if !seenKinds.contains(item.kind) {
                groups.append((title: title, items: [item]))
                seenKinds.insert(item.kind)
            } else if let lastIdx = groups.lastIndex(where: { $0.title == title }) {
                groups[lastIdx].items.append(item)
            }
        }
        return groups
    }

    private func pluralKind(_ kind: MediaItem.Kind) -> String {
        switch kind {
        case .song:     return "Songs"
        case .album:    return "Albums"
        case .playlist: return "Playlists"
        case .artist:   return "Artists"
        case .podcast:  return "Podcasts"
        case .episode:  return "Episodes"
        }
    }

    private struct SearchInput: Hashable {
        let query: String
        let filter: SearchFilter
    }

    /// Resting state shown before the user has typed anything (or after
    /// they've cleared the field). A blank scroll surface reads as
    /// "broken" — the icon + prompt signal that the input is the next
    /// action.
    private struct InitialSearchState: View {
        var body: some View {
            VStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 40))
                    .foregroundStyle(.white.opacity(0.4))
                Text("Find your music")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                Text("Search for songs, albums, artists, playlists, or podcasts.")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.75))
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 32)
        }
    }

    private struct EmptySearchState: View {
        let query: String
        var body: some View {
            VStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 40))
                    .foregroundStyle(.white.opacity(0.4))
                Text("No results for \u{201C}\(query)\u{201D}")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                Text("Try a different keyword or filter.")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.75))
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// Filter pill — selected state has the YT-Music white pill,
    /// unselected is a dim translucent capsule. Replaces the segmented
    /// picker which couldn't horizontally-scroll on narrow windows.
    private struct FilterChip: View {
        let label: String
        let selected: Bool
        let action: () -> Void
        var body: some View {
            Button(action: action) {
                Text(label)
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(selected ? Color.white : Color.white.opacity(0.08))
                    .foregroundStyle(selected ? .black : .white)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    /// Secondary refinement pill — smaller and tinted so the primary
    /// kind row stays visually dominant. Selected state uses the
    /// brand red so the user can tell at a glance which refinements
    /// are active.
    private struct RefinementChip: View {
        let label: String
        let selected: Bool
        let action: () -> Void
        var body: some View {
            Button(action: action) {
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(selected ? Theme.red.opacity(0.85) : Color.white.opacity(0.06))
                    .foregroundStyle(selected ? .white : .white.opacity(0.75))
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    private func debouncedRunSearch() async {
        do {
            try await Task.sleep(nanoseconds: 300_000_000)
        } catch {
            return  // task was cancelled — newer input arrived
        }
        guard !query.isEmpty else { results = []; searching = false; return }
        searching = true
        defer { searching = false }
        do {
            let raw = try await env.innerTube.search(query: query, filter: filter)
            results = raw.filter { !env.isBlocked($0) }
            errorMessage = nil
        } catch {
            results = []
            errorMessage = LoadErrorPresenter.message(for: error, env: env)
        }
    }
}
