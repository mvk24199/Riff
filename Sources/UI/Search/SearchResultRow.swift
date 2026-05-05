import SwiftUI

/// One row in the search results list. Mirrors YT Music's compact list
/// layout: small square thumbnail, bold title, subtitle prefixed with
/// the kind ("Song • Artist • plays" / "Album • Artist • year").
///
/// Tap behaviour matches the rest of the app:
///   - songs / episodes play immediately
///   - albums / playlists / artists / podcasts push a DetailView
///
/// Right-click surfaces the standard `TrackContextMenu` (for songs) or
/// a play / start-radio menu (for non-songs).
struct SearchResultRow: View {
    @Environment(AppEnvironment.self) private var env
    let item: MediaItem

    @State private var hovering = false

    var body: some View {
        Group {
            if item.kind == .song || item.kind == .episode {
                Button { Task { await play() } } label: { rowContent }
                    .buttonStyle(.plain)
                    .contextMenu { TrackContextMenu(item: item) }
            } else {
                NavigationLink(value: item) { rowContent }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Play") { Task { await play() } }
                        if item.kind != .episode {
                            Button("Start radio") { Task { await play() } }
                        }
                    }
            }
        }
        .onHover { hovering = $0 }
    }

    private var rowContent: some View {
        HStack(spacing: 14) {
            ZStack {
                AsyncImage(url: item.thumbnailURL) { phase in
                    if case .success(let img) = phase {
                        img.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Color.white.opacity(0.06)
                    }
                }
                .frame(width: 48, height: 48)
                .clipShape(thumbnailShape)
                // Hover overlay: dims the thumbnail and surfaces a play
                // glyph so the user sees the row is actionable. Songs
                // get a play arrow; albums/artists get a chevron since
                // the primary action is "open detail page".
                if hovering {
                    Rectangle().fill(.black.opacity(0.45))
                        .clipShape(thumbnailShape)
                        .frame(width: 48, height: 48)
                    Image(systemName: hoverIcon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(formattedSubtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(hovering ? Color.white.opacity(0.04) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
    }

    /// Artists get a circular thumbnail; everything else stays squared
    /// with rounded corners. Mirrors YT Music's row visuals.
    private var thumbnailShape: AnyShape {
        if item.kind == .artist {
            return AnyShape(Circle())
        }
        return AnyShape(RoundedRectangle(cornerRadius: 6))
    }

    private var hoverIcon: String {
        switch item.kind {
        case .song, .episode: return "play.fill"
        default:              return "chevron.right"
        }
    }

    /// "Kind • subtitle" for visual parity with YT Music search rows
    /// ("Album • Ravindra Jain • 2021"). When the parsed subtitle
    /// already starts with the kind label we don't double up.
    private var formattedSubtitle: String {
        let kind = kindLabel
        let trimmed = item.subtitle.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return kind }
        if trimmed.lowercased().hasPrefix(kind.lowercased()) { return trimmed }
        return "\(kind) • \(trimmed)"
    }

    private var kindLabel: String {
        switch item.kind {
        case .song:     return "Song"
        case .album:    return "Album"
        case .playlist: return "Playlist"
        case .artist:   return "Artist"
        case .podcast:  return "Podcast"
        case .episode:  return "Episode"
        }
    }

    private func play() async {
        switch item.kind {
        case .song, .episode: await env.player.play(item: item)
        case .album:          await env.player.playAlbum(id: item.id)
        case .playlist:       await env.player.playPlaylist(id: item.id)
        case .artist:         await env.player.playArtistRadio(id: item.id)
        case .podcast:        await env.player.playPodcast(id: item.id)
        }
    }
}

/// Wide hero card for the first search result — mirrors YT Music's
/// "Top result" panel: large square thumbnail, big bold title, subtitle,
/// prominent Play pill, and an overflow ⋮ menu on the right.
struct TopResultCard: View {
    @Environment(AppEnvironment.self) private var env
    let item: MediaItem

    @State private var hovering = false

    var body: some View {
        // Tappable surface — for non-songs the whole card pushes the
        // detail page (mirrors YT Music's "click a non-Top-result item
        // to open it"); for songs the card-level tap plays.
        Group {
            if item.kind == .song || item.kind == .episode {
                Button { Task { await play() } } label: { cardContent }
                    .buttonStyle(.plain)
                    .contextMenu { TrackContextMenu(item: item) }
            } else {
                NavigationLink(value: item) { cardContent }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Play") { Task { await play() } }
                        Button("Start radio") { Task { await play() } }
                    }
            }
        }
        .onHover { hovering = $0 }
    }

    private var cardContent: some View {
        HStack(spacing: 16) {
            AsyncImage(url: item.thumbnailURL) { phase in
                if case .success(let img) = phase {
                    img.resizable().aspectRatio(contentMode: .fill)
                } else {
                    Color.white.opacity(0.06)
                }
            }
            .frame(width: 100, height: 100)
            .clipShape(item.kind == .artist ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 10)))

            VStack(alignment: .leading, spacing: 6) {
                Text(item.title)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                Text(formattedSubtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
                Spacer(minLength: 4)
                HStack(spacing: 8) {
                    // Play pill — primary action, always visible. Stops
                    // the card-level tap so clicking the pill plays
                    // even on non-song top-results (rather than pushing
                    // detail).
                    Button {
                        Task { await play() }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 11, weight: .bold))
                            Text("Play")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(.white)
                        .foregroundStyle(.black)
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer(minLength: 8)
        }
        .padding(16)
        .background(hovering ? Color.white.opacity(0.07) : Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
    }

    private var formattedSubtitle: String {
        let kind = kindLabel
        let trimmed = item.subtitle.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return kind }
        if trimmed.lowercased().hasPrefix(kind.lowercased()) { return trimmed }
        return "\(kind) • \(trimmed)"
    }

    private var kindLabel: String {
        switch item.kind {
        case .song:     return "Song"
        case .album:    return "Album"
        case .playlist: return "Playlist"
        case .artist:   return "Artist"
        case .podcast:  return "Podcast"
        case .episode:  return "Episode"
        }
    }

    private func play() async {
        switch item.kind {
        case .song, .episode: await env.player.play(item: item)
        case .album:          await env.player.playAlbum(id: item.id)
        case .playlist:       await env.player.playPlaylist(id: item.id)
        case .artist:         await env.player.playArtistRadio(id: item.id)
        case .podcast:        await env.player.playPodcast(id: item.id)
        }
    }
}
