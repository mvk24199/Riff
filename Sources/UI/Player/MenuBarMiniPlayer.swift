import SwiftUI
import AppKit

/// Compact popover surfaced from the system menu bar via MenuBarExtra.
/// Gives users transport + scrubber + open-mini-player without bringing
/// the main Riff window forward.
///
/// Mirrors FloatingMiniPlayerView semantics but is a thinner, fixed-size
/// popover since the system menu bar cannot host an arbitrarily-resizable
/// surface.
///
/// Reads from the same env.player; no second WKWebView, no duplicated
/// state, honors the architectural rule.
struct MenuBarMiniPlayer: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let track = env.player.currentTrack
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                artwork(url: track?.thumbnailURL)
                VStack(alignment: .leading, spacing: 2) {
                    Text(track?.title ?? "Nothing playing")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(track?.subtitle ?? "")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }

            // Progress + timestamps. Hidden in the resting state so the
            // popover stays compact when nothing is loaded.
            if env.player.hasTrack {
                VStack(spacing: 4) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.12))
                            Capsule()
                                .fill(Theme.red)
                                .frame(width: geo.size.width * env.player.progress)
                        }
                    }
                    .frame(height: 3)
                    HStack {
                        Text(format(env.player.elapsed))
                        Spacer()
                        Text("-" + format(max(0, env.player.duration - env.player.elapsed)))
                    }
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 24) {
                Spacer()
                transport(systemName: "backward.fill", size: 14, help: "Previous") {
                    Task { await env.player.previous() }
                }
                .disabled(!env.player.hasTrack)

                transport(
                    systemName: env.player.isPlaying ? "pause.fill" : "play.fill",
                    size: 20,
                    help: env.player.isPlaying ? "Pause" : "Play"
                ) {
                    Task { await env.player.togglePlay() }
                }
                .disabled(!env.player.hasTrack)

                transport(systemName: "forward.fill", size: 14, help: "Next") {
                    Task { await env.player.next() }
                }
                .disabled(!env.player.hasTrack)
                Spacer()
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Button {
                    openWindow(id: "mini-player")
                } label: {
                    Label("Open Mini Player", systemImage: "rectangle.on.rectangle")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .keyboardShortcut("M", modifiers: [.command, .option])

                Button {
                    NSApp.terminate(nil)
                } label: {
                    Label("Quit Riff", systemImage: "power")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .keyboardShortcut("Q", modifiers: .command)
            }
            .font(.system(size: 12))
        }
        .padding(14)
        .frame(width: 280)
    }

    @ViewBuilder
    private func artwork(url: URL?) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.white.opacity(0.08))
            if let url {
                AsyncImage(url: url) { phase in
                    if case .success(let img) = phase {
                        img.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Image(systemName: "music.note")
                            .font(.system(size: 18))
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private func transport(
        systemName: String,
        size: CGFloat,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func format(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}

/// Label rendered next to the system menu bar clock. SF Symbol that mirrors
/// transport state: music.note when nothing is loaded, play.fill while
/// playing, pause.fill when paused. MenuBarExtra label only takes Views,
/// not NSImages, so we stick to SF Symbols for native chrome.
struct MenuBarMiniPlayerLabel: View {
    @Environment(AppEnvironment.self) private var env

    var body: some View {
        Image(systemName: iconName)
    }

    private var iconName: String {
        if env.player.hasTrack {
            return env.player.isPlaying ? "play.fill" : "pause.fill"
        }
        return "music.note"
    }
}
