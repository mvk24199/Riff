import SwiftUI

/// Full-screen player. Layout matches YT Music desktop:
///   - hero blurred backdrop (whole window)
///   - left side: artwork + title + scrubber + transport
///   - right side: tabbed pane Up Next / Lyrics / Related
///   - top bar: prominent close button (chevron-down) + "Now Playing"
///   - ESC dismisses
struct NowPlayingView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var scrubbing: Double? = nil
    @State private var bottomTab: BottomTab = .upNext
    @State private var queueMode: QueueMode = .related

    enum BottomTab: String, CaseIterable, Identifiable {
        case upNext = "Up Next"
        case lyrics = "Lyrics"
        case related = "Related"
        var id: String { rawValue }
    }

    enum QueueMode: String, CaseIterable, Identifiable {
        case related = "Related"
        case discover = "Discover"
        case deepCuts = "Deep cuts"
        case upbeat = "Upbeat"
        case familiar = "Familiar"
        var id: String { rawValue }
    }

    var body: some View {
        let track = env.player.currentTrack
        ZStack {
            // Solid black base so the underlying tab content can never bleed through.
            Color.black.ignoresSafeArea()

            // Hero blurred backdrop fed by the artwork.
            AsyncImage(url: track?.thumbnailURL) { phase in
                if case .success(let img) = phase {
                    img.resizable().scaledToFill().blur(radius: 80).opacity(0.45)
                } else {
                    LinearGradient(colors: [Color(white: 0.08), .black],
                                   startPoint: .top, endPoint: .bottom)
                }
            }
            .ignoresSafeArea()

            LinearGradient(
                colors: [Color.black.opacity(0.45), Color.black.opacity(0.78)],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                topBar

                HStack(spacing: 0) {
                    leftPlayer
                    sidePane
                        .frame(width: 380)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
        .preferredColorScheme(.dark)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .onExitCommand { env.player.isFullPlayerOpen = false }
        .onChange(of: bottomTab) { _, newTab in
            if newTab == .lyrics { env.player.loadLyricsIfNeeded() }
            if newTab == .related { env.player.loadRelatedIfNeeded() }
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack {
            Button {
                env.player.isFullPlayerOpen = false
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Close")
                        .font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.1))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)

            Spacer()
            Text("Now Playing")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))
                .textCase(.uppercase)
                .tracking(1.2)
            Spacer()
            // Symmetry placeholder.
            Color.clear.frame(width: 88, height: 32)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    // MARK: - Left side: player

    private var leftPlayer: some View {
        let track = env.player.currentTrack
        return VStack(spacing: 22) {
            Spacer(minLength: 8)

            AsyncImage(url: track?.thumbnailURL) { phase in
                switch phase {
                case .success(let img): img.resizable().aspectRatio(contentMode: .fit)
                default: Color.white.opacity(0.06)
                }
            }
            .frame(width: 320, height: 320)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .shadow(color: .black.opacity(0.6), radius: 26, y: 10)

            VStack(spacing: 4) {
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

            scrubber
                .frame(maxWidth: 480)
            playbackControls
                .padding(.top, 4)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Right side: tabbed pane

    private var sidePane: some View {
        VStack(spacing: 14) {
            // Tab pills along the top of the side pane.
            HStack(spacing: 0) {
                ForEach(BottomTab.allCases) { t in
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) { bottomTab = t }
                    } label: {
                        VStack(spacing: 6) {
                            Text(t.rawValue)
                                .font(.system(size: 13, weight: bottomTab == t ? .semibold : .regular))
                                .foregroundStyle(bottomTab == t ? .white : .white.opacity(0.6))
                            Rectangle()
                                .fill(bottomTab == t ? Theme.red : Color.clear)
                                .frame(height: 2)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                }
            }

            Divider().background(Color.white.opacity(0.15))

            // Selected tab content fills remaining height.
            ScrollView {
                Group {
                    switch bottomTab {
                    case .upNext:  upNextContent
                    case .lyrics:  lyricsContent
                    case .related: relatedContent
                    }
                }
                .id(bottomTab)
                .transition(.opacity)
                Spacer(minLength: 8)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // .regularMaterial = macOS native frosted-glass surface. Reads as
        // a clearly distinct panel against the dark blurred backdrop —
        // previous solid Color(white: 0.16) blended in too much. The
        // brand-red top edge is an unmistakable visual landmark.
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Theme.red)
                .frame(height: 3)
                .clipShape(RoundedRectangle(cornerRadius: 1.5))
                .padding(.horizontal, 16)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.white.opacity(0.22), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.5), radius: 16, x: -4, y: 0)
        .padding(.leading, 16)  // visual gap from the player on the left
    }

    // MARK: - Scrubber

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
    }

    private var playbackControls: some View {
        HStack(spacing: 22) {
            controlButton(
                systemName: env.player.liked ? "heart.fill" : "heart",
                size: 20,
                tint: env.player.liked ? Theme.red : .white.opacity(0.7)
            ) {
                Task { await env.player.toggleLike() }
            }
            controlButton(systemName: "backward.fill", size: 22, tint: .white) {
                Task { await env.player.previous() }
            }
            ZStack {
                Circle().fill(Theme.red)
                    .frame(width: 64, height: 64)
                    .shadow(color: Theme.red.opacity(0.4), radius: 12, y: 4)
                Image(systemName: env.player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.white)
                    .offset(x: env.player.isPlaying ? 0 : 2)
            }
            .onTapGesture { Task { await env.player.togglePlay() } }
            controlButton(systemName: "forward.fill", size: 22, tint: .white) {
                Task { await env.player.next() }
            }
            controlButton(systemName: "shuffle", size: 18, tint: .white.opacity(0.6)) { }
        }
    }

    private func controlButton(systemName: String, size: CGFloat, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func format(time: Double) -> String {
        guard time.isFinite, time >= 0 else { return "0:00" }
        let total = Int(time)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: - Tab content

    private var upNextContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(QueueMode.allCases) { mode in
                        Button { queueMode = mode } label: {
                            Text(mode.rawValue)
                                .font(.system(size: 11, weight: .semibold))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(queueMode == mode ? Theme.red : Color.white.opacity(0.06))
                                .foregroundStyle(queueMode == mode ? .white : .white.opacity(0.85))
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if env.player.upNext.isEmpty {
                emptyHint("Queue empty.")
            } else {
                queueList(env.player.upNext)
            }
        }
    }

    private var lyricsContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            if env.player.lyricsLoading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading lyrics…")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.7))
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 16)
            } else if let text = env.player.lyrics, !text.isEmpty {
                Text(text)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineSpacing(5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            } else {
                emptyHint("Lyrics not available for this track.")
            }
        }
    }

    private var relatedContent: some View {
        Group {
            if env.player.related.isEmpty {
                emptyHint("Looking for related tracks…")
            } else {
                queueList(env.player.related)
            }
        }
    }

    private func queueList(_ items: [MediaItem]) -> some View {
        LazyVStack(alignment: .leading, spacing: 4) {
            ForEach(items) { item in
                Button {
                    Task { await env.player.play(item: item) }
                } label: {
                    HStack(spacing: 10) {
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
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            Text(item.subtitle)
                                .font(.system(size: 10))
                                .foregroundStyle(.white.opacity(0.55))
                                .lineLimit(1)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func emptyHint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.white.opacity(0.55))
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 12)
    }
}

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
