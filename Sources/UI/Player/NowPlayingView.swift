import SwiftUI

/// Full-screen player. Visually inspired by YT Music iOS:
///   - hero blurred backdrop fed by current artwork
///   - centered square album art with a soft shadow for depth
///   - draggable scrubber with elapsed / remaining time labels
///   - large red play button (the only chromatic element on the surface)
///   - Up Next list at the bottom
struct NowPlayingView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var scrubbing: Double? = nil

    var body: some View {
        let track = env.player.currentTrack
        ZStack {
            // Hero backdrop: blurred artwork at low opacity so text stays
            // readable. Blur radius 60 + opacity 0.55 lands close to YTM iOS.
            AsyncImage(url: track?.thumbnailURL) { phase in
                if case .success(let img) = phase {
                    img.resizable().scaledToFill().blur(radius: 60).opacity(0.55)
                } else {
                    LinearGradient(colors: [Color(white: 0.08), .black],
                                   startPoint: .top, endPoint: .bottom)
                }
            }
            .ignoresSafeArea()

            // Lighten-to-dark overlay so the controls/text remain crisp.
            LinearGradient(
                colors: [Color.black.opacity(0.2), Color.black.opacity(0.65)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 28) {
                grabber
                    .padding(.top, 12)

                Spacer(minLength: 8)

                AsyncImage(url: track?.thumbnailURL) { phase in
                    switch phase {
                    case .success(let img): img.resizable().aspectRatio(contentMode: .fit)
                    default: Color.white.opacity(0.06)
                    }
                }
                .frame(maxWidth: 380, maxHeight: 380)
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .shadow(color: .black.opacity(0.6), radius: 30, y: 12)

                VStack(spacing: 6) {
                    Text(track?.title ?? "—")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                    Text(track?.subtitle ?? "")
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                }
                .padding(.horizontal, 32)

                scrubber

                playbackControls

                if !env.player.upNext.isEmpty {
                    UpNextList(items: env.player.upNext)
                        .frame(maxHeight: 200)
                        .padding(.horizontal, 24)
                }

                Spacer(minLength: 12)
            }
        }
        .preferredColorScheme(.dark)
        .frame(minWidth: 520, minHeight: 760)
    }

    // MARK: - Pieces

    /// Small drag-handle pill at the top of the sheet. YT Music iOS uses
    /// this same affordance to suggest "swipe down to dismiss".
    private var grabber: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(Color.white.opacity(0.25))
            .frame(width: 44, height: 5)
    }

    private var scrubber: some View {
        let duration = max(env.player.duration, 0.001)
        let displayed = scrubbing ?? env.player.elapsed
        return VStack(spacing: 6) {
            ScrubberSlider(
                value: Binding(
                    get: { displayed },
                    set: { scrubbing = $0 }
                ),
                range: 0...duration,
                onCommit: { value in
                    scrubbing = nil
                    Task { await env.player.seek(to: value / duration) }
                }
            )
            HStack {
                Text(format(time: displayed))
                Spacer()
                Text("-" + format(time: max(0, duration - displayed)))
            }
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(.white.opacity(0.6))
        }
        .padding(.horizontal, 32)
    }

    private var playbackControls: some View {
        HStack(spacing: 28) {
            controlButton(systemName: "shuffle", size: 18, tint: .white.opacity(0.6)) { }
            controlButton(systemName: "backward.fill", size: 24, tint: .white) {
                Task { await env.player.previous() }
            }
            ZStack {
                Circle().fill(Theme.red)
                    .frame(width: 72, height: 72)
                    .shadow(color: Theme.red.opacity(0.4), radius: 12, y: 4)
                Image(systemName: env.player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(.white)
                    .offset(x: env.player.isPlaying ? 0 : 2)
            }
            .onTapGesture { Task { await env.player.togglePlay() } }
            controlButton(systemName: "forward.fill", size: 24, tint: .white) {
                Task { await env.player.next() }
            }
            controlButton(systemName: "repeat", size: 18, tint: .white.opacity(0.6)) { }
        }
    }

    private func controlButton(systemName: String, size: CGFloat, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func format(time: Double) -> String {
        guard time.isFinite, time >= 0 else { return "0:00" }
        let total = Int(time)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Continuous-value slider with a custom track + thumb. SwiftUI's stock
/// Slider doesn't fit the dark, minimal look; this keeps it under one file.
private struct ScrubberSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var onCommit: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            let span = max(range.upperBound - range.lowerBound, 0.0001)
            let progress = max(0, min(1, (value - range.lowerBound) / span))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.18)).frame(height: 4)
                Capsule().fill(Color.white).frame(width: geo.size.width * progress, height: 4)
                Circle()
                    .fill(.white)
                    .frame(width: 12, height: 12)
                    .shadow(color: .black.opacity(0.4), radius: 3)
                    .offset(x: max(0, geo.size.width * progress - 6))
            }
            .frame(height: 12)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        let p = max(0, min(1, g.location.x / geo.size.width))
                        value = range.lowerBound + Double(p) * span
                    }
                    .onEnded { _ in onCommit(value) }
            )
        }
        .frame(height: 18)
    }
}

private struct UpNextList: View {
    let items: [MediaItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Up Next")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))
                .textCase(.uppercase)
                .tracking(1.2)
                .padding(.horizontal, 4)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(items) { item in
                        HStack(spacing: 12) {
                            AsyncImage(url: item.thumbnailURL) { phase in
                                if case .success(let img) = phase {
                                    img.resizable().aspectRatio(contentMode: .fill)
                                } else {
                                    Color.white.opacity(0.06)
                                }
                            }
                            .frame(width: 36, height: 36)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title)
                                    .font(.system(size: 13))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                Text(item.subtitle)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.white.opacity(0.55))
                                    .lineLimit(1)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                    }
                }
            }
            .background(Color.white.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }
}
