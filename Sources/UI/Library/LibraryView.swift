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
        if env.isSignedIn {
            signedInView
        } else {
            anonymousEmptyState
        }
    }

    private var signedInView: some View {
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

    private var anonymousEmptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "music.note.list")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("Sign in to see your library")
                .font(.system(size: 22, weight: .semibold))
            Text("Liked songs, playlists, and subscribed podcasts appear here.")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Sign In…") { env.isSignInSheetPresented = true }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .padding(.top, 8)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 32)
    }

    private func load() async {
        do {
            items = try await env.innerTube.library(section: section)
        } catch {
            items = []
        }
    }
}
