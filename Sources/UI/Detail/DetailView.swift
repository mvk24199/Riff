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
        .task(id: item.id) { await load() }
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
                }
            }
            Spacer()
        }
        .padding(.horizontal, 32)
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
                    artistId: track.artistId
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
                .contextMenu { TrackContextMenu(item: resolved) }
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
