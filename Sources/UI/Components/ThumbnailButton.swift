import SwiftUI

/// The "play on tap" primitive. Used in every list and grid in the app.
/// Tapping a thumbnail invokes the player directly — no DOM, no JS click
/// simulation. This is the single component that closes the gap with Kaset.
///
/// Visual goals: large rounded artwork (12pt corner) on a dark surface,
/// subtle shadow for depth, hover lifts the tile slightly and reveals a
/// red play button overlay at bottom-right.
struct ThumbnailButton: View {
    @Environment(AppEnvironment.self) private var env
    let item: MediaItem

    @State private var hovering: Bool = false

    var body: some View {
        Button(action: { Task { await play() } }) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .bottomTrailing) {
                    AsyncImage(url: item.thumbnailURL) { phase in
                        switch phase {
                        case .success(let img):
                            img.resizable().aspectRatio(contentMode: .fill)
                        default:
                            Color.white.opacity(0.06)
                        }
                    }
                    .frame(width: 180, height: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .shadow(color: .black.opacity(hovering ? 0.5 : 0.3), radius: hovering ? 12 : 6, y: hovering ? 6 : 3)

                    if hovering {
                        ZStack {
                            Circle().fill(Theme.red)
                                .frame(width: 48, height: 48)
                                .shadow(color: Theme.red.opacity(0.5), radius: 10)
                            Image(systemName: "play.fill")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(.white)
                                .offset(x: 1)
                        }
                        .padding(10)
                        .transition(.scale(scale: 0.7).combined(with: .opacity))
                    }
                }

                Text(item.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)

                Text(item.subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
            .frame(width: 180, alignment: .leading)
            .scaleEffect(hovering ? 1.02 : 1.0)
            .animation(.easeOut(duration: 0.15), value: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
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
