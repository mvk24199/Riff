import SwiftUI

/// "Tap to act" tile. Songs play directly (the click-to-play wedge —
/// what Kaset can't do). Album / playlist / artist / podcast tiles push
/// a DetailView onto the active tab's NavigationStack so the user can
/// review the tracklist before committing to play. The hover overlay's
/// red play button always plays immediately (a one-tap shortcut for
/// people who want the YT-Music-iOS feel).
struct ThumbnailButton: View {
    @Environment(AppEnvironment.self) private var env
    let item: MediaItem

    @State private var hovering: Bool = false

    var body: some View {
        if item.kind == .song || item.kind == .episode {
            Button(action: { Task { await playDirect() } }) { content }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
        } else {
            NavigationLink(value: item) { content }
                .buttonStyle(.plain)
                .onHover { hovering = $0 }
                // Right-click / long-press: option to play immediately.
                .contextMenu {
                    Button("Play") { Task { await playDirect() } }
                }
        }
    }

    private var content: some View {
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
                    Button {
                        Task { await playDirect() }
                    } label: {
                        ZStack {
                            Circle().fill(Theme.red)
                                .frame(width: 48, height: 48)
                                .shadow(color: Theme.red.opacity(0.5), radius: 10)
                            Image(systemName: "play.fill")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(.white)
                                .offset(x: 1)
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(10)
                    .transition(.scale(scale: 0.7).combined(with: .opacity))
                }
            }

            Text(item.title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            Text(item.subtitle)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.6))
                .lineLimit(1)
        }
        .frame(width: 180, alignment: .leading)
        .scaleEffect(hovering ? 1.02 : 1.0)
        .animation(.easeOut(duration: 0.15), value: hovering)
    }

    private func playDirect() async {
        switch item.kind {
        case .song, .episode: await env.player.play(item: item)
        case .album:          await env.player.playAlbum(id: item.id)
        case .playlist:       await env.player.playPlaylist(id: item.id)
        case .artist:         await env.player.playArtistRadio(id: item.id)
        case .podcast:        await env.player.playPodcast(id: item.id)
        }
    }
}
