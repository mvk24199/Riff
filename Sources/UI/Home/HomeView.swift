import SwiftUI

struct HomeView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var sections: [HomeSection] = []
    @State private var loading = true

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 32) {
                ForEach(sections) { section in
                    HomeSectionRow(section: section)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .task { await load() }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            sections = try await env.innerTube.browseHome()
        } catch {
            sections = []
        }
    }
}

struct HomeSection: Identifiable, Hashable {
    let id: String
    let title: String
    let items: [MediaItem]
}

struct HomeSectionRow: View {
    let section: HomeSection

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(section.title)
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.white)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 16) {
                    ForEach(section.items) { item in
                        ThumbnailButton(item: item)
                    }
                }
            }
        }
    }
}
