import SwiftUI
import AppKit

/// Compact always-on-top playback strip. Lives in its own NSWindow so the
/// user can keep audio controls visible while another app has focus.
/// Toggled via the Window menu (Riff → Window → Mini Player) or ⌥⌘M.
struct FloatingMiniPlayerView: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        let track = env.player.currentTrack
        VStack(spacing: 0) {
            // 2pt progress strip across the very top.
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Color.white.opacity(0.06))
                    Rectangle()
                        .fill(Theme.red)
                        .frame(width: geo.size.width * env.player.progress)
                }
            }
            .frame(height: 2)

            HStack(spacing: 12) {
                AsyncImage(url: track?.thumbnailURL) { phase in
                    if case .success(let img) = phase {
                        img.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Color.white.opacity(0.06)
                    }
                }
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 2) {
                    Text(track?.title ?? "Nothing playing")
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .foregroundStyle(.white)
                    Text(track?.subtitle ?? "")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                }
                Spacer(minLength: 6)

                button(systemName: "backward.fill", size: 14) {
                    Task { await env.player.previous() }
                }
                button(
                    systemName: env.player.isPlaying ? "pause.fill" : "play.fill",
                    size: 18
                ) {
                    Task { await env.player.togglePlay() }
                }
                button(systemName: "forward.fill", size: 14) {
                    Task { await env.player.next() }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .contextMenu { nowPlayingMenuItems }
        }
        .frame(width: 360, height: 70)
        .background(.ultraThinMaterial)
        .background(Color.black.opacity(0.85))
        .preferredColorScheme(.dark)
        .background(WindowFloater())
    }

    @ViewBuilder
    private var nowPlayingMenuItems: some View {
        if let track = env.player.currentTrack {
            let item = MediaItem(
                id: track.videoId,
                kind: .song,
                title: track.title,
                subtitle: track.subtitle,
                thumbnailURL: track.thumbnailURL,
                albumId: track.albumId,
                artistId: track.artistId
            )
            TrackContextMenu(item: item, omitPrimaryPlay: true)
        }
    }

    private func button(systemName: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Reaches into the hosting NSWindow to set window level + appearance to
/// match a floating utility panel: always-on-top, joins all spaces,
/// hidden from Mission Control. Has to be done via NSViewRepresentable
/// because SwiftUI doesn't expose `.windowLevel(.floating)` directly.
private struct WindowFloater: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async {
            guard let window = v.window else { return }
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.styleMask.insert(.fullSizeContentView)
            window.isMovableByWindowBackground = true
            window.backgroundColor = .black
        }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
