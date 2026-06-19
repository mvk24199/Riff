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

    /// Mirrors YT Music's "Tune" popover, simplified to the dimensions we
    /// can actually source data for. The full YT-Music feature uses a
    /// continuous Familiar↔Discover slider + mood chips, both routed
    /// through protobuf-encoded `/next` params tokens that aren't
    /// publicly documented. Until those tokens are reverse-engineered,
    /// these three modes give the user something real:
    ///
    ///   - Related: the default radio queue from `/next`.
    ///   - Discover: the related-songs endpoint (broader artists).
    ///   - Familiar: radio queue filtered to artists already in playedHistory.
    enum QueueMode: String, CaseIterable, Identifiable {
        case related = "Related"
        case discover = "Discover"
        case familiar = "Familiar"
        var id: String { rawValue }
    }

    var body: some View {
        let track = env.player.currentTrack
        // Foreground content only — backdrops are .background modifiers
        // outside this VStack so they can ignoresSafeArea independently
        // without inflating the foreground's frame.
        VStack(spacing: 0) {
            topBar
            HStack(alignment: .top, spacing: 16) {
                leftPlayer
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                sidePane
                    .frame(width: 380)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            // Backdrops as a background stack — entirely behind the
            // foreground; their sizes have no effect on the foreground's
            // layout. ZStack here is fine because it has no influence on
            // the VStack above.
            ZStack {
                Color.black
                AsyncImage(url: track?.thumbnailURL) { phase in
                    if case .success(let img) = phase {
                        img.resizable().scaledToFill().blur(radius: 80).opacity(0.45)
                    } else {
                        LinearGradient(colors: [Color(white: 0.08), .black],
                                       startPoint: .top, endPoint: .bottom)
                    }
                }
                LinearGradient(
                    colors: [Color.black.opacity(0.45), Color.black.opacity(0.78)],
                    startPoint: .top, endPoint: .bottom
                )
            }
            .ignoresSafeArea()
        }
        .preferredColorScheme(.dark)
        .onExitCommand { env.player.isFullPlayerOpen = false }
        .onChange(of: bottomTab) { _, newTab in
            if newTab == .lyrics { env.player.loadLyricsIfNeeded() }
            if newTab == .related { env.player.loadRelatedIfNeeded() }
        }
        .onChange(of: queueMode) { _, mode in
            // "Discover" reuses the same `related` field that the Related
            // top-tab populates — fetch lazily on first selection so we
            // don't pay the cost when the user only ever uses Related.
            if mode == .discover { env.player.loadRelatedIfNeeded() }
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
                .foregroundStyle(.white.opacity(0.75))
                .textCase(.uppercase)
                .tracking(1.2)
            Spacer()
            // Symmetry placeholder.
            Color.clear.frame(width: 88, height: 32)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    // MARK: - Left column (artwork + title + scrubber + transport)

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
            .contextMenu { nowPlayingMenuItems }

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
            .padding(.horizontal, 32)
            .contextMenu { nowPlayingMenuItems }

            scrubber
                .frame(maxWidth: 480)
            playbackControls
                .padding(.top, 4)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Right column (Up Next / Lyrics / Related side pane)

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
            .foregroundStyle(.white.opacity(0.75))
        }
    }

    private var playbackControls: some View {
        HStack(spacing: 16) {
            controlButton(
                systemName: env.player.liked ? "heart.fill" : "heart",
                size: 20,
                tint: env.player.liked ? Theme.red : .white.opacity(0.7),
                help: env.player.liked ? "Unlike" : "Like"
            ) {
                Task { await env.player.toggleLike() }
            }
            // Shuffle — when ON, our `next()` plays a random upcoming
            // track instead of advancing to the page's natural next.
            controlButton(
                systemName: "shuffle",
                size: 18,
                tint: env.player.shuffleEnabled ? Theme.red : .white.opacity(0.7),
                help: env.player.shuffleEnabled ? "Shuffle on" : "Shuffle"
            ) {
                env.player.toggleShuffle()
            }
            // Skip-back -15s — useful for any track but especially podcasts.
            controlButton(systemName: "gobackward.15", size: 20, tint: .white.opacity(0.85), help: "Back 15 seconds") {
                Task { await env.player.skip(by: -15) }
            }
            controlButton(systemName: "backward.fill", size: 22, tint: .white, help: "Previous") {
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
            .help(env.player.isPlaying ? "Pause" : "Play")
            controlButton(systemName: "forward.fill", size: 22, tint: .white, help: "Next") {
                Task { await env.player.next() }
            }
            // Skip-forward +30s.
            controlButton(systemName: "goforward.30", size: 20, tint: .white.opacity(0.85), help: "Forward 30 seconds") {
                Task { await env.player.skip(by: 30) }
            }
            // Repeat — currently two-state (off / one). The "1" badge
            // on `repeat.1` makes the active mode read at a glance.
            controlButton(
                systemName: env.player.repeatMode == .one ? "repeat.1" : "repeat",
                size: 18,
                tint: env.player.repeatMode == .off ? .white.opacity(0.7) : Theme.red,
                help: env.player.repeatMode == .one ? "Repeat one" : "Repeat"
            ) {
                Task { await env.player.toggleRepeat() }
            }
            playbackRateMenu
            sleepTimerMenu
            addToPlaylistMenu
            moreMenu
        }
    }

    /// Sleep-timer menu. Shows the running countdown when armed (mm:ss),
    /// preset durations + mode submenu when idle. Mirrors YT Music
    /// mobile's sleep-timer affordance, plus two modes neither YTM
    /// desktop nor Spotify ship: gentle 10s fade-out, and stop after
    /// the current track ends. Persists for the session only — Apple
    /// Music, YT Music, Spotify all behave this way.
    private var sleepTimerMenu: some View {
        Menu {
            if env.player.sleepTimerRemaining != nil || env.player.endOfTrackArmed {
                Button("Cancel timer") { env.player.cancelSleepTimer() }
                Divider()
            }
            // End-of-track is its own discrete entry — it has no
            // countdown ("stop after this track ends" is the whole
            // semantics) so a top-level button reads cleaner than
            // burying it under a "minutes" submenu.
            Button(action: { env.player.setSleepTimer(minutes: 0, mode: .endOfTrack) }) {
                Label("End of current track", systemImage: "stop.circle")
            }
            Divider()
            ForEach([5, 10, 15, 30, 45, 60], id: \.self) { minutes in
                Menu("\(minutes) min") {
                    Button("Stop") { env.player.setSleepTimer(minutes: minutes, mode: .hardStop) }
                    Button("Fade out (10s)") { env.player.setSleepTimer(minutes: minutes, mode: .fadeOut) }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "moon.zzz")
                    .font(.system(size: 16, weight: .semibold))
                if let remaining = env.player.sleepTimerRemaining {
                    Text(formatTimer(remaining))
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                } else if env.player.endOfTrackArmed {
                    Text("EOT")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                }
            }
            .foregroundStyle(sleepTimerActive ? Theme.red : .white.opacity(0.7))
            .frame(height: 40)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(sleepTimerHelp)
    }

    /// Whether the sleep-timer affordance should render in its
    /// "armed" tint. Either there's a live countdown, or we've
    /// elapsed the countdown of an `endOfTrack` timer and are
    /// awaiting the next track-ended event.
    private var sleepTimerActive: Bool {
        env.player.sleepTimerRemaining != nil || env.player.endOfTrackArmed
    }

    /// Tooltip text — reflects the active mode + remaining time so the
    /// user doesn't have to open the menu to remember what they armed.
    private var sleepTimerHelp: String {
        if let remaining = env.player.sleepTimerRemaining {
            let suffix: String
            switch env.player.sleepTimerMode {
            case .fadeOut: suffix = " (fade out)"
            case .endOfTrack: suffix = " (end of track)"
            default: suffix = ""
            }
            return "Sleep in \(formatTimer(remaining))\(suffix)"
        }
        if env.player.endOfTrackArmed {
            return "Sleeping after current track"
        }
        return "Sleep timer"
    }

    private func formatTimer(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.up))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// "More" (•••) menu — surfaces Go to album / Go to artist / Start
    /// radio for the currently playing track without requiring the user
    /// to right-click. Mirrors YT Music's track-overflow affordance.
    private var moreMenu: some View {
        Menu {
            nowPlayingMenuItems
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 36, height: 40)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 36, height: 40)
        .disabled(env.player.currentTrack == nil)
        .help("More")
    }

    /// Reusable menu builder for the currently-playing track. Synthesizes
    /// a MediaItem from PlayerBridge.Track so we can defer to the shared
    /// TrackContextMenu component (Start radio / Play next / Add to queue
    /// / Go to album / Go to artist / Add to playlist).
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

    /// "Add to Playlist…" menu — only meaningful when signed in. Loads the
    /// user's playlists lazily on first open.
    private var addToPlaylistMenu: some View {
        Menu {
            if !env.isSignedIn {
                Text("Sign in to add tracks to your playlists.")
            } else {
                Button("New Playlist…") {
                    env.newPlaylistSource = .currentTrack
                    env.isNewPlaylistSheetPresented = true
                }
                Divider()
                if env.userPlaylistsLoading {
                    Text("Loading…")
                } else if env.userPlaylists.isEmpty {
                    Text("No playlists yet.")
                } else {
                    ForEach(env.userPlaylists) { pl in
                        Button(pl.title) {
                            Task {
                                try? await env.player.addCurrentTrackToPlaylist(playlistId: pl.id)
                            }
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "text.badge.plus")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 36, height: 40)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 36, height: 40)
        .onAppear { env.loadUserPlaylistsIfNeeded() }
        .help("Add to playlist")
    }

    /// Playback-speed picker. 1× by default; useful for podcasts at 1.25–2×.
    /// Replaces the inert shuffle button which we don't have a real backend
    /// for yet (YT Music's shuffle is server-driven inside the queue).
    private var playbackRateMenu: some View {
        Menu {
            ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0], id: \.self) { rate in
                Button {
                    Task { await env.player.setPlaybackRate(rate) }
                } label: {
                    let label = rate == 1.0 ? "Normal" : Self.formatRate(rate) + "×"
                    if env.player.playbackRate == rate {
                        Label(label, systemImage: "checkmark")
                    } else {
                        Text(label)
                    }
                }
            }
        } label: {
            Text(env.player.playbackRate == 1.0 ? "1×" : Self.formatRate(env.player.playbackRate) + "×")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(env.player.playbackRate == 1.0 ? .white.opacity(0.75) : Theme.red)
                .frame(width: 44, height: 40)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .frame(width: 60, height: 40)
        .help("Playback speed")
    }

    private static func formatRate(_ rate: Double) -> String {
        rate.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(rate))
            : String(format: "%g", rate)
    }

    private func controlButton(systemName: String, size: CGFloat, tint: Color, help: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help ?? "")
    }

    private func format(time: Double) -> String {
        guard time.isFinite, time >= 0 else { return "0:00" }
        let total = Int(time)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: - Tab content

    @State private var tunePopoverOpen: Bool = false
    /// "Recently played" only shows the most-recent few rows by default;
    /// scrolling back through every track played in the session was making
    /// the Up Next pane feel like a log file. Flips to true on "Show more".
    @State private var historyExpanded: Bool = false
    private static let historyDefaultLimit: Int = 3

    private var upNextContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header row: queue mode label on the left, "Tune" affordance
            // on the right — mirrors YT Music's popover-driven pattern
            // instead of always-visible mode pills.
            HStack(spacing: 6) {
                Text(queueModeHeader)
                    .font(.system(size: 11, weight: .semibold))
                    .textCase(.uppercase)
                    .tracking(1.2)
                    .foregroundStyle(.white.opacity(0.75))
                Spacer()
                // "Save queue" — YT Music's Up-Next save affordance.
                // Disabled when there's nothing to save, hidden when
                // the user is anonymous (the createPlaylist endpoint
                // requires a SAPISID cookie session anyway).
                if env.isSignedIn, !env.player.upNext.isEmpty {
                    Button {
                        env.newPlaylistSource = .queue
                        env.isNewPlaylistSheetPresented = true
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "square.and.arrow.down")
                                .font(.system(size: 11, weight: .semibold))
                            Text("Save")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.white.opacity(0.06))
                        .foregroundStyle(.white.opacity(0.85))
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Save these tracks as a new playlist")
                }
                // "✨ Build" — opens the AI Queue Builder sheet.
                // Discoverable but unobtrusive: same chip shape as
                // Save / Tune, sparkles icon hints at the AI nature.
                // Always visible (the sheet itself handles the
                // "no API key" empty state) so users can find the
                // feature before they've configured it.
                Button {
                    env.isQueueBuilderSheetPresented = true
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Build")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(0.06))
                    .foregroundStyle(.white.opacity(0.85))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Build a queue from a vibe with AI")

                Button {
                    tunePopoverOpen = true
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Tune")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(0.06))
                    .foregroundStyle(.white.opacity(0.85))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .popover(isPresented: $tunePopoverOpen, arrowEdge: .top) {
                    TunePopover(
                        chips: env.player.availableChips,
                        selectedChipId: env.player.selectedChipId,
                        onSelectChip: { chip in env.player.applyChip(chip) },
                        fallbackSelection: $queueMode
                    )
                }
            }

            // Compose the queue around the current track: previously played
            // above (faded), upcoming below. Both lists exclude the
            // currently-playing videoId so it never appears twice — going
            // back to a previously-played track was making it show in both
            // sections. The "upcoming" list source switches based on the
            // selected mode pill (see QueueMode docs).
            let currentId = env.player.currentTrack?.videoId
            let history = env.player.playedHistory.filter { $0.id != currentId }
            let upcoming = upcomingList(currentId: currentId)
            if history.isEmpty && upcoming.isEmpty {
                emptyHint(emptyHintText)
            } else {
                if !history.isEmpty, isDefaultLens {
                    // Recently played only makes sense in the default
                    // (Related / "All") lens — it's a chronological log
                    // of THIS session, not part of a tuned variant's
                    // curation.
                    //
                    // We cap the visible rows at `historyDefaultLimit`
                    // (currently 3) to keep the Up Next pane focused
                    // on what's coming next rather than dominating the
                    // viewport with session history. The cap shows the
                    // tail (most-recent N), since that's the part the
                    // user actually needs as quick rewind context. A
                    // "Show all / Show fewer" button reveals the full
                    // log on demand.
                    HStack(spacing: 6) {
                        Text("Recently played")
                            .font(.system(size: 10, weight: .semibold))
                            .textCase(.uppercase)
                            .tracking(1.2)
                            .foregroundStyle(.white.opacity(0.45))
                        Spacer()
                        if history.count > Self.historyDefaultLimit {
                            Button {
                                historyExpanded.toggle()
                            } label: {
                                Text(historyExpanded
                                     ? "Show fewer"
                                     : "Show all (\(history.count))")
                                    .font(.system(size: 10, weight: .semibold))
                                    .textCase(.uppercase)
                                    .tracking(1.2)
                                    .foregroundStyle(.white.opacity(0.75))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 4)
                    let visibleHistory: [MediaItem] = historyExpanded
                        ? history
                        : Array(history.suffix(Self.historyDefaultLimit))
                    queueList(visibleHistory, faded: true)
                    Divider().background(Color.white.opacity(0.08))
                        .padding(.vertical, 4)
                }
                if !upcoming.isEmpty {
                    Text(upcomingHeader)
                        .font(.system(size: 10, weight: .semibold))
                        .textCase(.uppercase)
                        .tracking(1.2)
                        .foregroundStyle(.white.opacity(0.45))
                        .padding(.horizontal, 4)
                    queueList(upcoming, faded: false)
                }
            }
        }
    }

    /// Returns the upcoming list excluding the currently-playing track.
    /// When YT served a chip cloud, `upNext` already reflects whichever
    /// chip is active (PlayerBridge.applyChip re-fetches /next on chip
    /// selection), so we just hand back upNext. Without chips we fall
    /// back to the local QueueMode lenses.
    private func upcomingList(currentId: String?) -> [MediaItem] {
        if !env.player.availableChips.isEmpty {
            return env.player.upNext.filter { $0.id != currentId }
        }
        switch queueMode {
        case .related:
            return env.player.upNext.filter { $0.id != currentId }
        case .discover:
            return env.player.related.filter { $0.id != currentId }
        case .familiar:
            // Build the set of artist names heard earlier in this session
            // and intersect with the radio queue. Case-insensitive so
            // "Bruno Mars" and "bruno mars" still match. Empty when the
            // user hasn't played anything yet — handled by the empty-hint
            // text below.
            let known = Set(env.player.playedHistory.map { $0.subtitle.lowercased() })
            return env.player.upNext.filter {
                $0.id != currentId && known.contains($0.subtitle.lowercased())
            }
        }
    }

    /// Section header shown above the upcoming list. "Up next" by default;
    /// the modes get their own labels so the user can tell at a glance
    /// which lens they're looking at.
    private var upcomingHeader: String {
        switch queueMode {
        case .related:  return "Up next"
        case .discover: return "More like this"
        case .familiar: return "From artists you've played"
        }
    }

    /// Top-of-pane label shown left of the Tune button. When YT served a
    /// chip cloud and one is selected, show that chip's label (e.g.
    /// "Discover" / "Telugu" / "2010s"). Otherwise fall back to the
    /// local QueueMode label.
    private var queueModeHeader: String {
        if let id = env.player.selectedChipId,
           let chip = env.player.availableChips.first(where: { $0.id == id }) {
            // "All" reads as just "Up next" to keep the default state quiet.
            return chip.id == "All" ? "Up next" : chip.label
        }
        switch queueMode {
        case .related:  return "Up next"
        case .discover: return "Discover"
        case .familiar: return "Familiar"
        }
    }

    /// True when we're in the default (untuned) lens — either YT's "All"
    /// chip is active, or no chips are available and the local mode is
    /// `.related`. Drives the "Recently played" gate.
    private var isDefaultLens: Bool {
        if !env.player.availableChips.isEmpty {
            return (env.player.selectedChipId ?? "All") == "All"
        }
        return queueMode == .related
    }

    /// Empty-state text varies by mode so we explain *why* nothing's
    /// here rather than a generic "Queue empty".
    private var emptyHintText: String {
        switch queueMode {
        case .related:
            return "Queue empty."
        case .discover:
            return "No discoveries yet — try again in a moment."
        case .familiar:
            return "Play a few tracks first so we know what's familiar."
        }
    }

    private var lyricsContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            // "Create card" only when there's something to put on a card.
            if !env.player.lyricsLoading,
               (!env.player.lyricsLines.isEmpty || (env.player.lyrics?.isEmpty == false)) {
                HStack {
                    Spacer()
                    Button {
                        env.isLyricCardSheetPresented = true
                    } label: {
                        Label("Create card", systemImage: "square.and.arrow.up")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.white.opacity(0.7))
                }
            }
            Group {
                if env.player.lyricsLoading {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Loading lyrics…")
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 16)
                } else if env.player.lyricsTimed && !env.player.lyricsLines.isEmpty {
                    syncedLyrics
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
    }

    /// Synced lyrics view — highlights the line whose time-range covers
    /// `env.player.elapsed` and auto-scrolls it into view as playback
    /// advances.
    private var syncedLyrics: some View {
        let lines = env.player.lyricsLines
        let activeIndex = activeLyricIndex(for: env.player.elapsed * 1000, in: lines)
        return ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(lines.enumerated()), id: \.element.id) { idx, line in
                    Text(line.text.isEmpty ? "♪" : line.text)
                        .font(.system(size: idx == activeIndex ? 14 : 13,
                                      weight: idx == activeIndex ? .semibold : .regular))
                        .foregroundStyle(
                            idx == activeIndex ? Color.white :
                            abs(idx - activeIndex) <= 1 ? Color.white.opacity(0.7) :
                            Color.white.opacity(0.4)
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .id(line.id)
                }
            }
            .onChange(of: activeIndex) { _, newIndex in
                guard newIndex >= 0, newIndex < lines.count else { return }
                withAnimation(.easeOut(duration: 0.25)) {
                    proxy.scrollTo(lines[newIndex].id, anchor: .center)
                }
            }
        }
    }

    /// Find the index of the line whose start time precedes `elapsedMs`
    /// and whose successor's start time exceeds it. Returns -1 when no
    /// line has started yet.
    private func activeLyricIndex(for elapsedMs: Double, in lines: [InnerTubeClient.LyricLine]) -> Int {
        guard !lines.isEmpty else { return -1 }
        var active = -1
        for (idx, line) in lines.enumerated() {
            guard let startMs = line.startMs else { continue }
            if Double(startMs) <= elapsedMs { active = idx } else { break }
        }
        return active
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

    private func queueList(_ items: [MediaItem], faded: Bool = false) -> some View {
        let currentId = env.player.currentTrack?.videoId
        return LazyVStack(alignment: .leading, spacing: 4) {
            ForEach(items) { item in
                let isCurrent = item.id == currentId
                Button {
                    Task { await env.player.play(item: item) }
                } label: {
                    queueRow(item: item, isCurrent: isCurrent)
                        .opacity(faded ? 0.6 : 1.0)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    // Full track menu plus queue-specific reorder/remove
                    // operations underneath. omitPrimaryPlay because the
                    // row's tap already plays it; keep "Start radio" so
                    // the user can break out of the current queue.
                    TrackContextMenu(item: item, omitPrimaryPlay: true)
                    Divider()
                    Button("Move Up") { env.player.moveInQueue(videoId: item.id, by: -1) }
                        .disabled(isCurrent)
                    Button("Move Down") { env.player.moveInQueue(videoId: item.id, by: 1) }
                        .disabled(isCurrent)
                    Button("Remove from Queue") {
                        Task { await env.player.removeFromQueue(videoId: item.id) }
                    }
                    .disabled(isCurrent)  // can't remove the playing track
                }
            }
        }
    }

    private func queueRow(item: MediaItem, isCurrent: Bool) -> some View {
        HStack(spacing: 10) {
            ZStack {
                AsyncImage(url: item.thumbnailURL) { phase in
                    if case .success(let img) = phase {
                        img.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Color.white.opacity(0.06)
                    }
                }
                .frame(width: 36, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                // Equalizer-style overlay on the active row.
                if isCurrent {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(.black.opacity(0.5))
                        .frame(width: 36, height: 36)
                    Image(systemName: env.player.isPlaying ? "speaker.wave.2.fill" : "pause.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.red)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 12, weight: isCurrent ? .semibold : .medium))
                    .foregroundStyle(isCurrent ? Theme.red : .white)
                    .lineLimit(1)
                Text(item.subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(isCurrent ? Theme.red.opacity(0.10) : Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func emptyHint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.white.opacity(0.75))
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

// MARK: - Tune popover

/// Popover that mirrors YT Music's "Tune your queue" affordance. Shown
/// when the user taps the Tune button at the top of the Up Next pane.
///
/// Two display modes:
///
/// 1. **Real chips** — when YT served a `subHeaderChipCloud` for the
///    current watch context (typical for radio queues), we render
///    every chip the server gave us. Tapping a chip re-issues `/next`
///    with that chip's protobuf-encoded `(playlistId, params)` and
///    refreshes Up Next with the resulting variant. This is exactly
///    what music.youtube.com does on the web.
///
/// 2. **Local fallback** — when no chip cloud was returned (e.g. on
///    explicit playlists or podcasts where YT doesn't offer a Tune
///    affordance), fall back to a 3-position picker driven entirely
///    by data Riff already has: All / Discover (related endpoint) /
///    Familiar (history-filtered radio queue). Less rich than YT's
///    chips but better than nothing.
private struct TunePopover: View {
    let chips: [InnerTubeClient.QueueChip]
    let selectedChipId: String?
    let onSelectChip: (InnerTubeClient.QueueChip) -> Void
    @Binding var fallbackSelection: NowPlayingView.QueueMode
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            Divider().background(Color.white.opacity(0.1))
            if chips.isEmpty {
                fallbackSection
            } else {
                chipsSection
            }
        }
        .padding(18)
        .frame(width: 320)
        .background(.regularMaterial)
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        HStack {
            Text("Tune your queue")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
            Spacer()
            Button("Done") { dismiss() }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.red)
        }
    }

    /// Real YT-served chips. We don't try to bucket them into
    /// "familiarity" vs "mood" sections — YT itself renders them as a
    /// single flat cloud, with "All" first and the rest in whatever
    /// order the server chose (the order encodes locality / language
    /// signals we shouldn't second-guess).
    private var chipsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Variant")
                .font(.system(size: 10, weight: .semibold))
                .textCase(.uppercase)
                .tracking(1.2)
                .foregroundStyle(.white.opacity(0.75))
            FlowLayout(spacing: 6) {
                ForEach(chips) { chip in
                    let isSelected = (selectedChipId ?? chips.first(where: \.isSelected)?.id) == chip.id
                    Button {
                        onSelectChip(chip)
                    } label: {
                        Text(chip.label)
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(isSelected ? Theme.red : Color.white.opacity(0.06))
                            .foregroundStyle(isSelected ? .white : .white.opacity(0.85))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            Text("Tap a chip to retune the queue. The currently-playing track keeps playing.")
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.75))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Local 3-position picker — used when YT didn't serve a chip cloud.
    /// Order goes Familiar → Mix → Discover so it reads as a continuum.
    private var fallbackSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Familiarity")
                .font(.system(size: 10, weight: .semibold))
                .textCase(.uppercase)
                .tracking(1.2)
                .foregroundStyle(.white.opacity(0.75))
            HStack(spacing: 6) {
                ForEach(NowPlayingView.QueueMode.allCases) { mode in
                    Button {
                        fallbackSelection = mode
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: icon(for: mode))
                                .font(.system(size: 13, weight: .semibold))
                            Text(label(for: mode))
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(fallbackSelection == mode ? Theme.red : Color.white.opacity(0.06))
                        .foregroundStyle(fallbackSelection == mode ? .white : .white.opacity(0.85))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }
            Text(description(for: fallbackSelection))
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.75))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Fallback metadata

    private func icon(for mode: NowPlayingView.QueueMode) -> String {
        switch mode {
        case .familiar: return "person.crop.circle.badge.checkmark"
        case .related:  return "music.note.list"
        case .discover: return "sparkles"
        }
    }

    private func label(for mode: NowPlayingView.QueueMode) -> String {
        switch mode {
        case .familiar: return "Familiar"
        case .related:  return "Mix"
        case .discover: return "Discover"
        }
    }

    private func description(for mode: NowPlayingView.QueueMode) -> String {
        switch mode {
        case .familiar:
            return "Only show tracks by artists you've already played this session."
        case .related:
            return "The default radio queue — a balanced mix anchored on the current track."
        case .discover:
            return "Lean into broader, less-familiar recommendations."
        }
    }
}

/// Lightweight flow layout — wraps chips onto multiple rows when they
/// don't fit horizontally. Used by the mood chips above.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for sv in subviews {
            let size = sv.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth.isFinite ? maxWidth : x, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var rowHeight: CGFloat = 0
        for sv in subviews {
            let size = sv.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            sv.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
