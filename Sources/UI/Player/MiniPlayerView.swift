import SwiftUI

/// The pinned playback strip at the bottom of the window. Tap anywhere to
/// expand into NowPlayingView. Visual goals (per YT Music iOS):
///   - thin red progress line across the very top
///   - generous 56pt artwork with rounded corners + subtle shadow
///   - ample horizontal padding so the controls don't feel cramped
///   - whole strip is tappable but the action buttons short-circuit hits
struct MiniPlayerView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var showFullPlayer = false

    var body: some View {
        let track = env.player.currentTrack
        VStack(spacing: 0) {
            // Edge-to-edge progress line.
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(Color.white.opacity(0.06))
                    Rectangle()
                        .fill(Theme.red)
                        .frame(width: geo.size.width * env.player.progress)
                }
            }
            .frame(height: 2)

            HStack(spacing: 14) {
                AsyncImage(url: track?.thumbnailURL) { phase in
                    switch phase {
                    case .success(let img): img.resizable().aspectRatio(contentMode: .fill)
                    default: Color.gray.opacity(0.2)
                    }
                }
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .shadow(color: .black.opacity(0.4), radius: 6, y: 2)

                VStack(alignment: .leading, spacing: 2) {
                    Text(track?.title ?? "—")
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                        .foregroundStyle(.white)
                    Text(track?.subtitle ?? "")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 12)

                controlButton(systemName: "backward.fill", size: 16) {
                    Task { await env.player.previous() }
                }
                controlButton(
                    systemName: env.player.isPlaying ? "pause.fill" : "play.fill",
                    size: 22
                ) {
                    Task { await env.player.togglePlay() }
                }
                controlButton(systemName: "forward.fill", size: 16) {
                    Task { await env.player.next() }
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(Color.black.opacity(0.92))
            .background(.ultraThinMaterial)
            .contentShape(Rectangle())
            .onTapGesture { showFullPlayer = true }
        }
        .sheet(isPresented: $showFullPlayer) { NowPlayingView() }
    }

    private func controlButton(systemName: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
