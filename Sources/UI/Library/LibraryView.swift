import SwiftUI

struct LibraryView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var section: Section = .liked
    @State private var items: [MediaItem] = []
    @State private var errorMessage: String?

    enum Section: String, CaseIterable, Identifiable {
        case liked = "Liked", playlists = "Playlists", albums = "Albums", artists = "Artists", podcasts = "Podcasts", history = "History"
        var id: String { rawValue }
    }

    var body: some View {
        @Bindable var env = env
        NavigationStack(path: $env.libraryNavPath) {
            Group {
                if env.isSignedIn {
                    signedInView
                } else {
                    anonymousEmptyState
                }
            }
            .navigationDestination(for: MediaItem.self) { DetailView(item: $0) }
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
                if let errorMessage {
                    ErrorBanner(message: errorMessage) {
                        Task { await load() }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 12)
                }
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
            errorMessage = nil
        } catch {
            items = []
            errorMessage = LoadErrorPresenter.message(for: error, env: env)
        }
    }
}
