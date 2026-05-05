import SwiftUI

/// The "play on tap" primitive. Used in every list and grid in the app.
/// Tapping a thumbnail invokes the player directly — no DOM, no JS click simulation.
/// This is the single component that closes the gap with Kaset.
struct ThumbnailButton: View {
    @Environment(AppEnvironment.self) private var env
    let item: MediaItem

    var body: some View {
        Button(action: { Task { await play() } }) {
            VStack(alignment: .leading, spacing: 8) {
                AsyncImage(url: item.thumbnailURL) { phase in
                    switch phase {
                    case .success(let img): img.resizable().aspectRatio(contentMode: .fill)
                    default: Color.gray.opacity(0.2)
                    }
                }
                .frame(width: 180, height: 180)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(alignment: .bottomTrailing) {
                    if hovering {
                        Image(systemName: "play.circle.fill")
                            .font(.system(size: 36))
                            .foregroundStyle(.white)
                            .shadow(radius: 4)
                            .padding(8)
                    }
                }

                Text(item.title)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(2)
                    .foregroundStyle(.white)

                Text(item.subtitle)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 180)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    @State private var hovering: Bool = false

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
