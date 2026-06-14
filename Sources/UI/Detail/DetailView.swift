import SwiftUI

/// Album / Playlist / Artist / Podcast detail page. One view because all
/// four use the same InnerTube /browse response shape (header + tracklist),
/// they just style slightly differently. Pushed onto the active tab's
/// NavigationStack when the user taps a non-song tile.
struct DetailView: View {
    @Environment(AppEnvironment.self) private var env
    let item: MediaItem

    @State private var page: InnerTubeClient.DetailPage?
    @State private var loading = true
    @State private var error: String?
    @State private var editSheetPresented = false

    /// True when the open detail page represents a playlist owned by
    /// the signed-in user — checked by id against env.userPlaylists.
    /// Drives the Edit affordance: only user-owned playlists can be
    /// renamed / deleted / have tracks removed.
    private var isUserOwnedPlaylist: Bool {
        guard item.kind == .playlist else { return false }
        return env.userPlaylists.contains { $0.id == item.id }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let page {
                    header(page)
                    Divider().background(Theme.divider)
                    if page.tracks.isEmpty {
                        Text("No tracks")
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.55))
                            .padding(.horizontal, 32)
                    } else {
                        tracklist(page.tracks, fallbackArtwork: page.artworkURL ?? item.thumbnailURL)
                    }
                    // "More from <Artist>" / "You might also like" /
                    // "Other versions" — YT Music's at-the-bottom carousels.
                    // Falls through gracefully when YT didn't return any.
                    if !page.relatedSections.isEmpty {
                        relatedSections(page.relatedSections)
                            .padding(.top, 16)
                    }
                } else if loading {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 240)
                } else if let error {
                    ErrorBanner(message: error) {
                        Task { await load() }
                    }
                    .padding(.horizontal, 32)
                }
            }
            .padding(.vertical, 24)
        }
        .background(Color.black.ignoresSafeArea())
        .task(id: item.id) {
            await load()
            // Make sure userPlaylists is populated so the
            // isUserOwnedPlaylist check returns the right answer on
            // first navigation. Cheap when already loaded.
            env.loadUserPlaylistsIfNeeded()
        }
    }

    private func header(_ page: InnerTubeClient.DetailPage) -> some View {
        HStack(alignment: .top, spacing: 24) {
            AsyncImage(url: page.artworkURL ?? item.thumbnailURL) { phase in
                switch phase {
                case .success(let img): img.resizable().aspectRatio(contentMode: .fill)
                default: Color.white.opacity(0.06)
                }
            }
            .frame(width: 220, height: 220)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .shadow(color: .black.opacity(0.4), radius: 16, y: 6)

            VStack(alignment: .leading, spacing: 8) {
                Text(kindLabel)
                    .font(.system(size: 11, weight: .semibold))
                    .textCase(.uppercase)
                    .tracking(1.2)
                    .foregroundStyle(.white.opacity(0.55))
                Text(page.title.isEmpty ? item.title : page.title)
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                annotatedSubtitle(page)
                    .font(.system(size: 13))
                    .lineLimit(3)
                // Metadata line: "9 songs · 32 min · 2024" (or whichever
                // pieces are available). Built from the tracks we
                // already parsed — no extra round-trip. Empty string
                // when nothing's known (renders as a zero-height
                // EmptyView via the conditional).
                if let meta = metadataLine(for: page) {
                    Text(meta)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.5))
                }
                Spacer(minLength: 8)
                HStack(spacing: 10) {
                    Button {
                        Task { await playAll(page) }
                    } label: {
                        Label("Play", systemImage: "play.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .padding(.horizontal, 18)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.red)

                    Button {
                        Task { await shuffle(page) }
                    } label: {
                        Label("Shuffle", systemImage: "shuffle")
                            .font(.system(size: 13, weight: .semibold))
                            .padding(.horizontal, 18)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.bordered)

                    // Edit menu — visible only on user-owned
                    // playlists. The endpoints we expose
                    // (rename / privacy / delete) all require
                    // ownership, so showing it elsewhere would just
                    // produce errors on save.
                    if isUserOwnedPlaylist {
                        Menu {
                            Button("Edit Playlist…") {
                                editSheetPresented = true
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 13, weight: .semibold))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .frame(width: 44)
                    }
                }
            }
            Spacer()
        }
        .padding(.horizontal, 32)
        .sheet(isPresented: $editSheetPresented) {
            EditPlaylistSheet(
                playlistId: item.id,
                initialTitle: page.title.isEmpty ? item.title : page.title,
                onDeleted: {
                    // Pop back to the previous nav stack frame so
                    // the user isn't stranded on a deleted playlist.
                    // Falls back to no-op if the user was at root.
                    switch env.activeTab {
                    case .home:    if !env.homeNavPath.isEmpty    { env.homeNavPath.removeLast()    }
                    case .search:  if !env.searchNavPath.isEmpty  { env.searchNavPath.removeLast()  }
                    case .library: if !env.libraryNavPath.isEmpty { env.libraryNavPath.removeLast() }
                    }
                }
            )
        }
    }

    /// Renders the album / playlist tracklist. `fallbackArtwork` is used
    /// for any track whose own row didn't carry a thumbnail — common on
    /// album responses where YT omits per-track artwork because every
    /// track shares the album cover.
    private func tracklist(_ tracks: [MediaItem], fallbackArtwork: URL?) -> some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                // Backfill missing track artwork with the album/playlist
                // cover so the now-playing strip and lock screen show
                // *something* rather than a black square.
                let resolved = MediaItem(
                    id: track.id,
                    kind: track.kind,
                    title: track.title,
                    subtitle: track.subtitle,
                    thumbnailURL: track.thumbnailURL ?? fallbackArtwork,
                    albumId: track.albumId,
                    artistId: track.artistId,
                    setVideoId: track.setVideoId
                )
                Button {
                    Task { await env.player.play(item: resolved) }
                } label: {
                    HStack(spacing: 14) {
                        Text("\(index + 1)")
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.45))
                            .frame(width: 28, alignment: .trailing)
                        AsyncImage(url: track.thumbnailURL ?? fallbackArtwork) { phase in
                            if case .success(let img) = phase {
                                img.resizable().aspectRatio(contentMode: .fill)
                            } else {
                                Color.white.opacity(0.06)
                            }
                        }
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(track.title)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            Text(track.subtitle)
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.55))
                                .lineLimit(1)
                        }
                        Spacer()
                        // Per-track duration — shown when the parser
                        // captured it. Albums almost always provide
                        // it; some "Songs" search shelves omit it.
                        if let secs = track.durationSeconds {
                            Text(formatTrackDuration(secs))
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.55))
                                .padding(.trailing, 8)
                        }
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 32)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(
                    Color.white.opacity(0).onHover { hovering in
                        // Hover background handled by the hidden modifier below.
                        _ = hovering
                    }
                )
                .contextMenu {
                    TrackContextMenu(item: resolved)
                    // "Remove from this playlist" — only meaningful
                    // when the open detail page is a user-owned
                    // playlist AND the row carries a setVideoId
                    // (parsed by parseListItem from playlistItemData).
                    if isUserOwnedPlaylist, let setId = resolved.setVideoId {
                        Divider()
                        Button("Remove from this playlist") {
                            Task { await removeFromCurrentPlaylist(track: resolved, setVideoId: setId) }
                        }
                    }
                }
            }
        }
    }

    /// Renders the album / playlist / artist subtitle with the linkable
    /// segments (artist / album runs) tappable. Built as an
    /// `HStack(alignment: .firstTextBaseline)` of individual `Text` /
    /// `Button` segments because:
    ///
    ///   - `AttributedString` + `.link` was eating runs in the album
    ///     header (some responsive-header layouts wrap subtitle.runs
    ///     in attributes that lose foreground colour, leaving an
    ///     "invisible" string on black).
    ///   - Native `Button` for each linkable run gives free hover
    ///     feedback + correct accessibility labels.
    ///
    /// Tradeoff: a long subtitle won't wrap mid-run. In practice album
    /// subtitles fit on one line anyway, and `Spacer` + `lineLimit(1)`
    /// gracefully truncates with an ellipsis.
    @ViewBuilder
    private func annotatedSubtitle(_ page: InnerTubeClient.DetailPage) -> some View {
        let runs: [InnerTubeClient.AnnotatedRun] = page.subtitleRuns.isEmpty
            ? [InnerTubeClient.AnnotatedRun(
                text: page.subtitle.isEmpty ? item.subtitle : page.subtitle,
                browseId: nil, kind: nil)]
            : page.subtitleRuns
        // Drop empty runs that would render as zero-width gaps.
        let visible = runs.filter { !$0.text.isEmpty }

        if visible.isEmpty {
            // OST and various-artists albums often come back with an
            // empty subtitle — YT has no single "album artist" to
            // surface. Leaving the header blank reads as broken;
            // fall back to the kind label so the user gets at least
            // "Album" / "Playlist" / etc.
            Text(kindLabel)
                .foregroundStyle(.white.opacity(0.7))
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                ForEach(Array(visible.enumerated()), id: \.offset) { _, run in
                    if let id = run.browseId, let kind = run.kind, kind == .artist || kind == .album {
                        Button {
                            env.navigateToBrowseId(id, kind: kind)
                        } label: {
                            Text(run.text)
                                .foregroundStyle(.white)
                                .underline(true, color: .white.opacity(0.5))
                        }
                        .buttonStyle(.plain)
                    } else {
                        Text(run.text)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    /// Renders the carousels returned by `/browse` after the tracklist.
    /// Uses `HomeSectionRow` so the visual treatment matches the Home
    /// tab's carousels — a familiar pattern keeps the page coherent.
    private func relatedSections(_ sections: [HomeSection]) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            Divider().background(Theme.divider)
            ForEach(sections) { section in
                HomeSectionRow(section: section)
                    .padding(.horizontal, 32)
            }
        }
    }

    /// "9 songs · 32 min · 2024" header metadata. Returns nil when
    /// the tracks list is empty AND no year is known — at that point
    /// there's nothing useful to show, and a stub line would just
    /// add noise. Year is sourced from any track that has one (album
    /// detail responses sometimes put it on the rows even when the
    /// header subtitle omits it).
    private func metadataLine(for page: InnerTubeClient.DetailPage) -> String? {
        var pieces: [String] = []
        if !page.tracks.isEmpty {
            // "song" vs "songs" — small touch, but reads less robotic.
            pieces.append(page.tracks.count == 1 ? "1 song" : "\(page.tracks.count) songs")
            let totalSeconds = page.tracks.compactMap(\.durationSeconds).reduce(0, +)
            if totalSeconds > 0 {
                pieces.append(formatTotalRuntime(totalSeconds))
            }
        }
        // Year: first non-nil from the tracks. The album's header may
        // not have surfaced it but per-track rows often do.
        if let y = page.tracks.compactMap(\.year).first {
            pieces.append(String(y))
        }
        return pieces.isEmpty ? nil : pieces.joined(separator: " • ")
    }

    /// Compact "32 min" / "1 hr 18 min" for the metadata line. Drops
    /// seconds — total album runtimes in seconds add noise.
    private func formatTotalRuntime(_ totalSeconds: Int) -> String {
        let totalMinutes = totalSeconds / 60
        if totalMinutes < 60 {
            return "\(totalMinutes) min"
        }
        let h = totalMinutes / 60
        let m = totalMinutes % 60
        return m == 0 ? "\(h) hr" : "\(h) hr \(m) min"
    }

    /// Per-row duration formatter — matches the search-result-row
    /// convention. Local to DetailView so we don't bind to a UI
    /// helper from a different module.
    private func formatTrackDuration(_ totalSeconds: Int) -> String {
        let h = totalSeconds / 3600
        let m = (totalSeconds % 3600) / 60
        let s = totalSeconds % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        }
        return String(format: "%d:%02d", m, s)
    }

    private var kindLabel: String {
        switch item.kind {
        case .album:    return "Album"
        case .playlist: return "Playlist"
        case .artist:   return "Artist"
        case .podcast:  return "Podcast"
        case .episode:  return "Episode"
        case .song:     return "Song"
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let detail: InnerTubeClient.DetailPage
            switch item.kind {
            case .playlist:
                // For curated playlists from carousels, item.id is the playlistId
                // (we strip "VL" in the parser). detail() expects browseId.
                detail = try await env.innerTube.playlistDetail(playlistId: item.id)
            default:
                detail = try await env.innerTube.detail(forBrowseId: item.id)
            }
            page = detail
            error = nil
        } catch {
            self.error = LoadErrorPresenter.message(for: error, env: env)
        }
    }

    private func playAll(_ page: InnerTubeClient.DetailPage) async {
        if let plid = page.playablePlaylistId {
            await env.player.playPlaylist(id: plid)
        } else if let first = page.tracks.first {
            await env.player.play(item: backfillArtwork(first, page: page))
        }
    }

    /// Issue ACTION_REMOVE_VIDEO and optimistically prune the row
    /// from the in-memory tracklist so the UI reflects the change
    /// before /browse re-fetches. The `try?` swallows errors so a
    /// permission failure (rare; we already gated on ownership)
    /// doesn't strand the user — the next reload will show the
    /// authoritative state.
    private func removeFromCurrentPlaylist(track: MediaItem, setVideoId: String) async {
        try? await env.innerTube.removeFromPlaylist(
            setVideoId: setVideoId,
            videoId: track.id,
            playlistId: item.id
        )
        // Optimistic prune of the local copy so the user sees the
        // removal immediately. We don't refetch here because that
        // would scroll the user back to the top; the next time the
        // page loads it'll be authoritative.
        if var current = page {
            let pruned = current.tracks.filter { $0.id != track.id || $0.setVideoId != setVideoId }
            page = InnerTubeClient.DetailPage(
                title: current.title,
                subtitle: current.subtitle,
                subtitleRuns: current.subtitleRuns,
                artworkURL: current.artworkURL,
                playablePlaylistId: current.playablePlaylistId,
                tracks: pruned,
                relatedSections: current.relatedSections
            )
            _ = current  // silence unused-let warning
        }
    }

    private func shuffle(_ page: InnerTubeClient.DetailPage) async {
        // Pick a random track to start; YT Music's "shuffle" semantics are
        // server-driven (the watch page shuffles the queue) but we don't
        // have a clean param token, so the first random track is a
        // pragmatic stand-in.
        if let track = page.tracks.randomElement() {
            await env.player.play(item: backfillArtwork(track, page: page))
        }
    }

    /// Returns `track` with its missing thumbnail filled from the
    /// album/playlist cover, mirroring the same backfill the per-row
    /// tap action does. Keeps the now-playing strip + Now Playing view
    /// from showing a black square for tracks that didn't carry their
    /// own artwork in the InnerTube response.
    private func backfillArtwork(_ track: MediaItem, page: InnerTubeClient.DetailPage) -> MediaItem {
        guard track.thumbnailURL == nil else { return track }
        return MediaItem(
            id: track.id,
            kind: track.kind,
            title: track.title,
            subtitle: track.subtitle,
            thumbnailURL: page.artworkURL ?? item.thumbnailURL,
            albumId: track.albumId,
            artistId: track.artistId
        )
    }
}
