import SwiftUI

struct SearchView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var query: String = ""
    @State private var filter: SearchFilter = .all
    @State private var results: [MediaItem] = []

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

            Picker("Filter", selection: $filter) {
                ForEach(SearchFilter.allCases) { f in Text(f.rawValue).tag(f) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 24)

            ScrollView {
                if results.isEmpty, !query.isEmpty {
                    EmptySearchState(query: query)
                        .padding(.top, 80)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 16)], spacing: 16) {
                        ForEach(results) { item in
                            ThumbnailButton(item: item)
                        }
                    }
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

    private struct SearchInput: Hashable {
        let query: String
        let filter: SearchFilter
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
                    .foregroundStyle(.white.opacity(0.55))
            }
            .frame(maxWidth: .infinity)
        }
    }

    private func debouncedRunSearch() async {
        do {
            try await Task.sleep(nanoseconds: 300_000_000)
        } catch {
            return  // task was cancelled — newer input arrived
        }
        guard !query.isEmpty else { results = []; return }
        do {
            results = try await env.innerTube.search(query: query, filter: filter)
        } catch {
            results = []
        }
    }
}
