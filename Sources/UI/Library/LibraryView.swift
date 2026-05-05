import SwiftUI

struct LibraryView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var section: Section = .liked
    @State private var items: [MediaItem] = []

    enum Section: String, CaseIterable, Identifiable {
        case liked = "Liked", playlists = "Playlists", podcasts = "Podcasts", albums = "Albums", artists = "Artists"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("Section", selection: $section) {
                ForEach(Section.allCases) { s in Text(s.rawValue).tag(s) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 24)
            .padding(.top, 8)

            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 16)], spacing: 16) {
                    ForEach(items) { item in ThumbnailButton(item: item) }
                }
                .padding(.horizontal, 24)
            }
        }
        .task(id: section) { await load() }
    }

    private func load() async {
        do {
            items = try await env.innerTube.library(section: section)
        } catch {
            items = []
        }
    }
}
