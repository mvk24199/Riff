import SwiftUI

struct MiniPlayerView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var showFullPlayer = false

    var body: some View {
        let track = env.player.currentTrack
        HStack(spacing: 12) {
            AsyncImage(url: track?.thumbnailURL) { phase in
                switch phase {
                case .success(let img): img.resizable().aspectRatio(contentMode: .fill)
                default: Color.gray.opacity(0.2)
                }
            }
            .frame(width: 48, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(track?.title ?? "—").font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(track?.subtitle ?? "").font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button(action: { Task { await env.player.previous() } }) { Image(systemName: "backward.fill") }
            Button(action: { Task { await env.player.togglePlay() } }) {
                Image(systemName: env.player.isPlaying ? "pause.fill" : "play.fill")
            }
            Button(action: { Task { await env.player.next() } }) { Image(systemName: "forward.fill") }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .overlay(Rectangle().frame(height: 1).foregroundStyle(.white.opacity(0.08)), alignment: .top)
        .onTapGesture { showFullPlayer = true }
        .sheet(isPresented: $showFullPlayer) { NowPlayingView() }
    }
}
