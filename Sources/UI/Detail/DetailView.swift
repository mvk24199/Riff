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
                        tracklist(page.tracks)
                    }
                } else if loading {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 240)
                } else if let error {
                    Text(error)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.7))
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
                Text(page.subtitle.isEmpty ? item.subtitle : page.subtitle)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.7))
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

    private func tracklist(_ tracks: [MediaItem]) -> some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                Button {
                    Task { await env.player.play(item: track) }
                } label: {
                    HStack(spacing: 14) {
                        Text("\(index + 1)")
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.45))
                            .frame(width: 28, alignment: .trailing)
                        AsyncImage(url: track.thumbnailURL) { phase in
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
            self.error = "Couldn't load: \(error.localizedDescription)"
        }
    }

    private func playAll(_ page: InnerTubeClient.DetailPage) async {
        if let plid = page.playablePlaylistId {
            await env.player.playPlaylist(id: plid)
        } else if let first = page.tracks.first {
            await env.player.play(item: first)
        }
    }

    private func shuffle(_ page: InnerTubeClient.DetailPage) async {
        // Pick a random track to start; YT Music's "shuffle" semantics are
        // server-driven (the watch page shuffles the queue) but we don't
        // have a clean param token, so the first random track is a
        // pragmatic stand-in.
        if let track = page.tracks.randomElement() {
            await env.player.play(item: track)
        }
    }
}
