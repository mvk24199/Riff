import SwiftUI

struct SearchView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var query: String = ""
    @State private var filter: SearchFilter = .all
    @State private var results: [MediaItem] = []

    enum SearchFilter: String, CaseIterable, Identifiable {
        case all = "All", songs = "Songs", albums = "Albums", playlists = "Playlists", artists = "Artists", podcasts = "Podcasts"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            TextField("Search", text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .onSubmit { Task { await runSearch() } }

            Picker("Filter", selection: $filter) {
                ForEach(SearchFilter.allCases) { f in Text(f.rawValue).tag(f) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 24)

            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 16)], spacing: 16) {
                    ForEach(results) { item in
                        ThumbnailButton(item: item)
                    }
                }
                .padding(.horizontal, 24)
            }
        }
    }

    private func runSearch() async {
        guard !query.isEmpty else { results = []; return }
        do {
            results = try await env.innerTube.search(query: query, filter: filter)
        } catch {
            results = []
        }
    }
}
