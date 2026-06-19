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
    ///
    /// `playCount` and `lastPlayed` are derived from the local
    /// `PlayerBridge.playedEntries` journal — InnerTube doesn't surface
    /// per-track listening stats on the Liked Songs browse response,
    /// so we count locally. These two orders are only meaningful for
    /// individual songs (i.e. the Liked section) and are hidden in the
    /// menu for other sections.
    enum SortOrder: String, CaseIterable, Identifiable {
        case recentlyAdded = "Recently added"
        case aToZ = "A to Z"
        case zToA = "Z to A"
        case playCount = "Most played"
        case lastPlayed = "Last played"
        var id: String { rawValue }

        /// Sorts that depend on the local play-history journal. They
        /// only make sense for song rows (the Liked section), so the
        /// dropdown filters them out for Playlists / Albums / etc.
        var requiresPlayHistory: Bool {
            switch self {
            case .playCount, .lastPlayed: return true
            case .recentlyAdded, .aToZ, .zToA: return false
            }
        }
    }

    /// Items after applying the search-within-library filter, the
    /// active sort, and the user's pinned-id partition. Computed
    /// property keeps the view declaration tidy and avoids stale state
    /// when the user switches sort/filter without re-fetching.
    ///
    /// Order of operations: filter → sort → float pinned to top.
    /// Pinning is applied LAST so it always wins regardless of the
    /// chosen sort — that's the whole point of pinning. Within the
    /// pinned head and the unpinned tail we still preserve the sort,
    /// so the user's mental model ("Recently added, but my favorites
    /// first") stays intact.
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
        let sorted: [MediaItem]
        switch sort {
        case .recentlyAdded:
            sorted = filtered  // server order — newest first
        case .aToZ:
            sorted = filtered.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .zToA:
            sorted = filtered.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedDescending }
        case .playCount:
            let counts = LibrarySorting.playCounts(from: env.player.playedEntries)
            sorted = filtered.sorted {
                let lhs = counts[$0.id] ?? 0
                let rhs = counts[$1.id] ?? 0
                if lhs == rhs {
                    // Tie-break alphabetically so the order is stable
                    // (otherwise SwiftUI would shuffle equally-played
                    // rows on every play-count tick).
                    return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
                }
                return lhs > rhs  // most-played first
            }
        case .lastPlayed:
            let last = LibrarySorting.lastPlayed(from: env.player.playedEntries)
            sorted = filtered.sorted {
                let lhs = last[$0.id] ?? .distantPast
                let rhs = last[$1.id] ?? .distantPast
                if lhs == rhs {
                    return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
                }
                return lhs > rhs  // most-recent first
            }
        }
        return LibrarySorting.partitionPinned(sorted, pinned: env.pinnedLibraryIds)
    }

    /// Sort orders shown in the dropdown for the current section.
    /// Liked Songs gets the full set (incl. play-count / last-played
    /// derived from local history); other sections get only the
    /// server-order-friendly orders since play counts on a *playlist*
    /// row don't have a meaningful definition here.
    private var availableSorts: [SortOrder] {
        SortOrder.allCases.filter { order in
            !order.requiresPlayHistory || section == .liked
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
                        .foregroundStyle(.white.opacity(0.75))
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
                        .foregroundStyle(.white.opacity(0.75))
                }

                Spacer()

                Menu {
                    ForEach(availableSorts) { order in
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
                .fixedSize()
                .help("Sort library")
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
                        .foregroundStyle(.white.opacity(0.75))
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 60)
                } else if displayedItems.isEmpty {
                    Text("No \(section.rawValue.lowercased()) match \"\(filterText)\".")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.75))
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 60)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 16)], spacing: 16) {
                        ForEach(displayedItems) { item in
                            ThumbnailButton(item: item, showPinAction: true)
                                .overlay(alignment: .topLeading) {
                                    // Visual cue: tiny pin badge on the
                                    // tile when this item is pinned, so
                                    // the user can spot which tiles are
                                    // floating to the top by choice vs.
                                    // by natural sort order. Off-grid
                                    // when not pinned so unpinned tiles
                                    // are visually unchanged.
                                    if env.isPinned(item.id) {
                                        Image(systemName: "pin.fill")
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundStyle(.white)
                                            .padding(5)
                                            .background(Theme.red, in: Circle())
                                            .shadow(color: .black.opacity(0.4), radius: 3, y: 1)
                                            .padding(6)
                                            .help("Pinned — right-click to unpin")
                                    }
                                }
                        }
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
            // If the active sort is no longer offered in the new
            // section (e.g. user picked "Most played" in Liked then
            // switched to Albums), reset to the default rather than
            // leave the dropdown showing an option that isn't in its
            // menu. Recently-added is always the safe fallback.
            if !availableSorts.contains(sort) {
                sort = .recentlyAdded
            }
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
