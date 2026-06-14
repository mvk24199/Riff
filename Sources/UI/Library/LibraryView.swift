import SwiftUI

struct LibraryView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var section: Section = .liked
    @State private var sort: SortOrder = .recentlyAdded
    @State private var filterText: String = ""
    @State private var items: [MediaItem] = []
    @State private var mixedForYou: [HomeSection] = []
    @State private var errorMessage: String?

    enum Section: String, CaseIterable, Identifiable {
        case liked = "Liked", playlists = "Playlists", albums = "Albums", artists = "Artists", podcasts = "Podcasts", history = "History"
        var id: String { rawValue }
    }

    /// Library sort orders, mirroring YouTube Music's web library
    /// dropdown. The InnerTube response order is "recently added"
    /// (most-recent first), so we treat that as the natural ordering
    /// and sort A-Z / Z-A as local permutations on top of it.
    enum SortOrder: String, CaseIterable, Identifiable {
        case recentlyAdded = "Recently added"
        case aToZ = "A to Z"
        case zToA = "Z to A"
        var id: String { rawValue }
    }

    /// Items after applying the search-within-library filter and the
    /// active sort. Computed property keeps the view declaration tidy
    /// and avoids stale state when the user switches sort/filter
    /// without re-fetching.
    private var displayedItems: [MediaItem] {
        let filtered: [MediaItem]
        let needle = filterText.trimmingCharacters(in: .whitespaces).lowercased()
        if needle.isEmpty {
            filtered = items
        } else {
            filtered = items.filter {
                $0.title.lowercased().contains(needle)
                    || $0.subtitle.lowercased().contains(needle)
            }
        }
        switch sort {
        case .recentlyAdded:
            return filtered  // server order — newest first
        case .aToZ:
            return filtered.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .zToA:
            return filtered.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedDescending }
        }
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
        VStack(alignment: .leading, spacing: 12) {
            Picker("Section", selection: $section) {
                ForEach(Section.allCases) { s in Text(s.rawValue).tag(s) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 24)
            .padding(.top, 8)

            // Sort + filter row. Mirrors YT Music web's library
            // header: live filter on the left, sort dropdown on the
            // right, hit count in the middle when filtering.
            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.5))
                    TextField("Filter \(section.rawValue.lowercased())", text: $filterText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.06))
                .clipShape(Capsule())

                if !filterText.isEmpty {
                    Text("\(displayedItems.count) of \(items.count)")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                }

                Spacer()

                Menu {
                    ForEach(SortOrder.allCases) { order in
                        Button {
                            sort = order
                        } label: {
                            if sort == order {
                                Label(order.rawValue, systemImage: "checkmark")
                            } else {
                                Text(order.rawValue)
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.up.arrow.down")
                            .font(.system(size: 11, weight: .semibold))
                        Text(sort.rawValue)
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.06))
                    .foregroundStyle(.white.opacity(0.85))
                    .clipShape(Capsule())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            .padding(.horizontal, 24)

            ScrollView {
                // Personalized "Mixed for you" carousels sit above
                // the section grid so the user sees auto-generated
                // mixes (Supermix, Discover Mix, …) before the
                // explicit library content. Anonymous responses are
                // empty — the section hides itself entirely.
                if !mixedForYou.isEmpty {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        ForEach(mixedForYou) { section in
                            HomeSectionRow(section: section)
                        }
                    }
                    .padding(.bottom, 16)
                }
                if let errorMessage {
                    ErrorBanner(message: errorMessage) {
                        Task { await load() }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 12)
                }
                if items.isEmpty && errorMessage == nil {
                    Text("Nothing here yet.")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.55))
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 60)
                } else if displayedItems.isEmpty {
                    Text("No \(section.rawValue.lowercased()) match \"\(filterText)\".")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.55))
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 60)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 16)], spacing: 16) {
                        ForEach(displayedItems) { item in ThumbnailButton(item: item) }
                    }
                    .padding(.horizontal, 24)
                }
            }
        }
        .task(id: section) {
            // Reset filter on section switch — searching for "abc" in
            // Liked then jumping to Albums shouldn't carry the needle
            // forward; the user's intent moved with the section.
            filterText = ""
            await load()
        }
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
        // Fan out: library section + Mixed-for-you in parallel. The
        // mixed feed is best-effort — anonymous responses are empty
        // and any failure should silently hide the carousels rather
        // than show an error banner above the user's primary library
        // content.
        async let libraryFetch = env.innerTube.library(section: section)
        async let mixedFetch = env.innerTube.browseMixedForYou()
        do {
            items = try await libraryFetch
            errorMessage = nil
        } catch {
            items = []
            errorMessage = LoadErrorPresenter.message(for: error, env: env)
        }
        // try? collapses both "feed errored" and "feed returned empty"
        // into the same hide-the-carousels code path — exactly what we
        // want for a best-effort secondary surface.
        let mixedRaw = (try? await mixedFetch) ?? []
        mixedForYou = mixedRaw.compactMap { sec in
            let kept = sec.items.filter { !env.isBlocked($0) }
            guard !kept.isEmpty else { return nil }
            return HomeSection(id: sec.id, title: sec.title, items: kept)
        }
    }
}
