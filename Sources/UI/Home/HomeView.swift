import SwiftUI

struct HomeView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var sections: [HomeSection] = []
    @State private var loading = true

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 32) {
                    if loading && sections.isEmpty {
                        HomeSkeleton()
                    } else {
                        ForEach(sections) { section in
                            HomeSectionRow(section: section)
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
            }
            .navigationDestination(for: MediaItem.self) { DetailView(item: $0) }
            .task { await load() }
        }
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

/// Skeleton rows shown while `browseHome()` is in flight. Two carousels'
/// worth of placeholder tiles with a soft pulse, so an empty Home tab
/// reads as "loading" instead of "broken".
private struct HomeSkeleton: View {
    @State private var pulse = false
    var body: some View {
        VStack(alignment: .leading, spacing: 32) {
            ForEach(0..<2, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 12) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.white.opacity(pulse ? 0.10 : 0.06))
                        .frame(width: 180, height: 22)
                    HStack(spacing: 16) {
                        ForEach(0..<5, id: \.self) { _ in
                            VStack(alignment: .leading, spacing: 8) {
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(Color.white.opacity(pulse ? 0.10 : 0.06))
                                    .frame(width: 180, height: 180)
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color.white.opacity(pulse ? 0.10 : 0.06))
                                    .frame(width: 140, height: 12)
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(Color.white.opacity(pulse ? 0.10 : 0.06))
                                    .frame(width: 100, height: 10)
                            }
                        }
                    }
                }
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
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
