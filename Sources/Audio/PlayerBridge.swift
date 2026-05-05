import Foundation
import Observation

/// Public playback API. SwiftUI views call methods here; this class translates
/// to JS evaluations on the hidden WKWebView, and observes the page's events
/// back into observable state.
@Observable
@MainActor
final class PlayerBridge {
    private(set) var isPlaying: Bool = false
    private(set) var elapsed: Double = 0   // seconds
    private(set) var duration: Double = 0  // seconds; 0 until the page reports it
    var progress: Double { duration > 0 ? elapsed / duration : 0 }
    private(set) var currentTrack: Track? = nil
    private(set) var upNext: [MediaItem] = []
    /// Tracks that have played earlier in this session (most-recent last).
    /// Capped at `historyCap` so it doesn't grow unbounded.
    private(set) var playedHistory: [MediaItem] = []
    private(set) var related: [MediaItem] = []
    private(set) var lyrics: String? = nil
    private(set) var lyricsLines: [InnerTubeClient.LyricLine] = []
    private(set) var lyricsTimed: Bool = false
    private(set) var lyricsLoading: Bool = false
    private(set) var liked: Bool = false
    /// Whether the full-screen Now Playing view is presented.
    var isFullPlayerOpen: Bool = false
    var hasTrack: Bool { currentTrack != nil }

    /// Cached browse IDs from /next response — used to lazy-load lyrics
    /// and related songs only when the user opens those tabs.
    @ObservationIgnored private var lyricsBrowseId: String?
    @ObservationIgnored private var relatedBrowseId: String?
    /// Playlist ID extracted from the current /watch URL. Required to fetch
    /// the right Up Next queue when playing inside a playlist (without it,
    /// /next returns radio-style suggestions instead of the playlist's tracks).
    @ObservationIgnored private var currentPlaylistId: String?

    /// Fires after any state change (track, play/pause, progress). Used by
    /// AppEnvironment to drive NowPlayingCenter without coupling the two
    /// classes directly. @ObservationIgnored: this is plumbing, not state.
    @ObservationIgnored
    var onUpdate: (() -> Void)?

    @ObservationIgnored
    private let innerTube: InnerTubeClient

    @ObservationIgnored
    private let webBridge: HiddenPlayerWebView

    /// `window.musicBridge` doesn't exist until the JS user script has run.
    /// Eval calls before the bridge fires `ready` get queued; we flush on
    /// the first `ready` event. Without this, the very first click after
    /// app launch races against the initial music.youtube.com load and
    /// silently no-ops.
    @ObservationIgnored
    private var bridgeReady: Bool = false
    @ObservationIgnored
    private var pendingCommands: [String] = []

    init(innerTube: InnerTubeClient) {
        self.innerTube = innerTube
        // Restore playback prefs from prior launch.
        let storedVolume = UserDefaults.standard.object(forKey: Self.volumeKey) as? Double
        let storedRate   = UserDefaults.standard.object(forKey: Self.rateKey)   as? Double
        self.volume = storedVolume ?? 1.0
        self.playbackRate = storedRate ?? 1.0
        // Eager init: start loading music.youtube.com offscreen at app start,
        // so by the time the user clicks anything the page is loaded.
        self.webBridge = HiddenPlayerWebView()
        self.webBridge.onEvent = { [weak self] event in self?.handle(event) }
    }

    private static let volumeKey = "player.volume"
    private static let rateKey   = "player.rate"

    struct Track: Hashable {
        let videoId: String
        let title: String
        let subtitle: String
        let thumbnailURL: URL?
        let duration: Double
    }

    // MARK: - Commands

    func play(videoId: String) async {
        await navigate(watchURL(videoId: videoId, playlistId: nil))
    }

    /// Click-to-play with an item we already have full metadata for (search
    /// rows, home carousels, library lists). Pre-populates `currentTrack`
    /// so the mini-bar shows the right title/artist/artwork *immediately*,
    /// before the WebView even starts loading. Without this, anonymous YT
    /// Music plays 2-3 video ads first and the mini-bar flickers through
    /// each ad's metadata before settling on the real song.
    func play(item: MediaItem) async {
        currentTrack = Track(
            videoId: item.id,
            title: item.title,
            subtitle: item.subtitle,
            thumbnailURL: item.thumbnailURL,
            duration: 0
        )
        // Reset & pre-fetch surrounding context (queue + lyrics/related ids).
        upNext = []
        related = []
        lyrics = nil
        currentPlaylistId = nil
        userClickedAt = Date()
        refreshNextQueueAndIds(forVideoId: item.id, playlistId: nil)
        onUpdate?()
        await play(videoId: item.id)
    }

    /// Last time `play(item:)` ran. Used to gate when we accept JS-side
    /// metadata updates for the *same* videoId — within `userClickGraceSeconds`
    /// we ignore them (catches pre-roll ads), after that window we trust
    /// them (catches autoplay advances where the URL videoId stays put).
    @ObservationIgnored private var userClickedAt: Date = .distantPast
    private static let userClickGraceSeconds: TimeInterval = 30
    private static let historyCap = 50

    private func archiveCurrent() {
        guard let old = currentTrack else {
            Log.bridge.debug("archiveCurrent: no current track to archive")
            return
        }
        let item = MediaItem(
            id: old.videoId, kind: .song,
            title: old.title, subtitle: old.subtitle,
            thumbnailURL: old.thumbnailURL
        )
        if playedHistory.last?.id == item.id {
            Log.bridge.debug("archiveCurrent: skip dup last=\(item.title, privacy: .public) (\(item.id, privacy: .public))")
            return
        }
        playedHistory.append(item)
        if playedHistory.count > Self.historyCap {
            playedHistory.removeFirst(playedHistory.count - Self.historyCap)
        }
        let size = playedHistory.count
        Log.bridge.debug("archiveCurrent: appended \(item.title, privacy: .public) (\(item.id, privacy: .public)); historySize=\(size)")
    }

    /// Pull /next for the given videoId — populates `upNext` and stashes
    /// browse IDs for lyrics + related which are loaded on demand.
    /// Pass `playlistId` when known so /next returns the playlist's track
    /// list instead of generic radio suggestions.
    private func refreshNextQueueAndIds(forVideoId id: String, playlistId: String?) {
        Task { [innerTube, weak self] in
            guard let response = try? await innerTube.nextQueue(videoId: id, playlistId: playlistId) else {
                Log.bridge.debug("refreshNextQueue: nextQueue threw or returned nil for v=\(id, privacy: .public)")
                return
            }
            Log.bridge.debug("refreshNextQueue v=\(id, privacy: .public) plid=\(playlistId ?? "nil", privacy: .public) → queue=\(response.queue.count) likeStatus=\(String(describing: response.likeStatus), privacy: .public)")
            await MainActor.run {
                self?.upNext = response.queue
                self?.lyricsBrowseId = response.lyricsBrowseId
                self?.relatedBrowseId = response.relatedBrowseId
                self?.liked = response.likeStatus == .like
                // Invalidate previously cached tab content for the old track.
                self?.lyrics = nil
                self?.lyricsLines = []
                self?.lyricsTimed = false
                self?.related = []
            }
        }
    }

    /// Toggle the like state on the current track. Optimistically updates
    /// `liked` so the UI feels immediate; rolls back on InnerTube error.
    func toggleLike() async {
        guard let track = currentTrack else { return }
        let wasLiked = liked
        liked.toggle()
        do {
            if wasLiked {
                try await innerTube.removeLike(videoId: track.videoId)
            } else {
                try await innerTube.like(videoId: track.videoId)
            }
        } catch {
            // Roll back on failure (e.g. needsReauth when not signed in).
            liked = wasLiked
        }
    }

    /// Lazy-load lyrics on tab open. Sets `lyricsLoading` while in flight.
    /// Populates either `lyricsLines` (with `lyricsTimed=true`) for synced
    /// lyrics or just the plain `lyrics` text fallback.
    func loadLyricsIfNeeded() {
        guard lyrics == nil, lyricsLines.isEmpty, !lyricsLoading, let id = lyricsBrowseId else { return }
        lyricsLoading = true
        Task { [innerTube, weak self] in
            let result = (try? await innerTube.lyrics(browseId: id)) ?? nil
            await MainActor.run {
                guard let self else { return }
                if let result {
                    self.lyricsLines = result.lines
                    self.lyricsTimed = result.timed
                    self.lyrics = result.lines.map(\.text).joined(separator: "\n")
                } else {
                    self.lyrics = "Lyrics not available."
                }
                self.lyricsLoading = false
            }
        }
    }

    /// Lazy-load related songs on tab open.
    func loadRelatedIfNeeded() {
        guard related.isEmpty, let id = relatedBrowseId else { return }
        Task { [innerTube, weak self] in
            let items = (try? await innerTube.related(browseId: id)) ?? []
            await MainActor.run { self?.related = items }
        }
    }

    /// Plays a YT Music playlist. Tries direct /watch?list= first (works
    /// for proper PL... / OLAK5uy_... ids); on failure falls back to the
    /// browseId resolver path which will fetch the playlist's first track
    /// and navigate /watch?v=&list= explicitly.
    func playPlaylist(id: String) async {
        // Strip a "VL" prefix if it's still attached — VL ids are browse
        // ids (used to fetch playlist details), not playable ids.
        let cleaned = id.hasPrefix("VL") ? String(id.dropFirst(2)) : id
        Log.resolver.debug("playPlaylist id=\(id, privacy: .public) cleaned=\(cleaned, privacy: .public)")
        await navigate(watchURL(videoId: nil, playlistId: cleaned))
    }

    func playAlbum(id: String)    async { await playByResolvingBrowseId(id) }
    func playPodcast(id: String)  async { await playByResolvingBrowseId(id) }
    func playArtistRadio(id: String) async { await playByResolvingBrowseId(id) }

    /// Resolves a browseId via InnerTube to a playable (videoId, playlistId)
    /// tuple, then navigates /watch?v=&list=. Has multiple fallback paths
    /// so unresponsive entities are rare:
    ///   1. innerTube.playable(forBrowseId:) — primary path (microformat)
    ///   2. If browseId starts with "VL", strip and try as direct playlist
    ///   3. Last resort: navigate /browse/<id> so the user lands on the
    ///      detail page even if we can't auto-play.
    private func playByResolvingBrowseId(_ browseId: String) async {
        if let tuple = (try? await innerTube.playable(forBrowseId: browseId)) ?? nil {
            let url = watchURL(videoId: tuple.videoId, playlistId: tuple.playlistId)
            Log.resolver.debug("\(browseId, privacy: .public) → v=\(tuple.videoId ?? "nil", privacy: .public) list=\(tuple.playlistId ?? "nil", privacy: .public) → \(url, privacy: .public)")
            await navigate(url)
            return
        }
        // Fallback 1: VL-prefix strip → direct playlist play.
        if browseId.hasPrefix("VL") {
            let plid = String(browseId.dropFirst(2))
            Log.resolver.debug("\(browseId, privacy: .public) → resolver failed; falling back to direct playlist plid=\(plid, privacy: .public)")
            await navigate(watchURL(videoId: nil, playlistId: plid))
            return
        }
        // Fallback 2: at least put the user on the entity's page so they
        // can manually press Play if our resolver missed.
        Log.resolver.debug("\(browseId, privacy: .public) → no playable endpoint and no fallback; navigating to browse page")
        await navigate("https://music.youtube.com/browse/\(browseId)")
    }

    private func watchURL(videoId: String?, playlistId: String?) -> String {
        var components = URLComponents(string: "https://music.youtube.com/watch")!
        var items: [URLQueryItem] = []
        if let videoId, !videoId.isEmpty { items.append(URLQueryItem(name: "v", value: videoId)) }
        if let playlistId, !playlistId.isEmpty { items.append(URLQueryItem(name: "list", value: playlistId)) }
        components.queryItems = items.isEmpty ? nil : items
        return components.url?.absoluteString ?? "https://music.youtube.com/"
    }

    private func navigate(_ url: String) async {
        await eval("window.musicBridge.navigate(\(url.jsonQuoted))")
    }

    func togglePlay() async { await eval("window.musicBridge.togglePlay()") }
    func next()       async { await eval("window.musicBridge.next()") }
    func previous()   async { await eval("window.musicBridge.previous()") }
    func seek(to fraction: Double) async {
        await eval("window.musicBridge.seek(\(fraction))")
    }

    /// Playback rate (0.5x – 2.0x). Useful for podcasts; works for music
    /// too. Persists across track changes within the same WebView session.
    private(set) var playbackRate: Double = 1.0
    func setPlaybackRate(_ rate: Double) async {
        playbackRate = rate
        UserDefaults.standard.set(rate, forKey: Self.rateKey)
        await eval("window.musicBridge.setPlaybackRate(\(rate))")
    }

    /// Skip ±N seconds — podcast-style transport. Negative skips back.
    func skip(by seconds: Double) async {
        await eval("window.musicBridge.skipBy(\(seconds))")
    }

    /// Add the currently-playing track to a user-owned playlist. Caller
    /// supplies the target playlistId. Requires sign-in (SAPISID cookie).
    func addCurrentTrackToPlaylist(playlistId: String) async throws {
        guard let videoId = currentTrack?.videoId else { return }
        try await innerTube.addToPlaylist(videoId: videoId, playlistId: playlistId)
    }

    /// Create a fresh user-owned playlist and add the currently-playing
    /// track to it. Returns the new playlistId on success.
    @discardableResult
    func createPlaylistWithCurrentTrack(title: String) async throws -> String? {
        guard let videoId = currentTrack?.videoId else { return nil }
        let plid = try await innerTube.createPlaylist(title: title)
        if let plid {
            try await innerTube.addToPlaylist(videoId: videoId, playlistId: plid)
        }
        return plid
    }

    /// Remove a track from the local Up Next list. Doesn't (yet) sync the
    /// removal to YT Music's server-side queue — InnerTube's queue-mutation
    /// endpoint isn't documented for our client; the WebView's queue still
    /// holds the original list. Treat this as a local-UX hint until we
    /// implement a JS bridge into the page's queue API.
    func removeFromQueue(videoId: String) async {
        upNext.removeAll { $0.id == videoId }
    }

    /// Local-only reorder. Same caveat as removeFromQueue: this only
    /// affects the Up Next list Riff displays, not the WebView's actual
    /// playback queue. Useful for users who want to inspect / curate
    /// what's coming up.
    func moveInQueue(videoId: String, by offset: Int) {
        guard let index = upNext.firstIndex(where: { $0.id == videoId }) else { return }
        let newIndex = max(0, min(upNext.count - 1, index + offset))
        guard newIndex != index else { return }
        let item = upNext.remove(at: index)
        upNext.insert(item, at: newIndex)
    }

    /// Volume 0.0...1.0. Persisted across track changes within the session
    /// (defaults to 1.0 on launch, the WebView's natural state).
    private(set) var volume: Double = 1.0
    func setVolume(_ level: Double) async {
        let clamped = max(0.0, min(1.0, level))
        volume = clamped
        UserDefaults.standard.set(clamped, forKey: Self.volumeKey)
        await eval("window.musicBridge.setVolume(\(clamped))")
    }

    private func eval(_ js: String) async {
        guard bridgeReady else {
            pendingCommands.append(js)
            return
        }
        _ = try? await webBridge.webView.evaluateJavaScript(js)
    }

    private func flushPending() async {
        let cmds = pendingCommands
        pendingCommands.removeAll()
        for cmd in cmds {
            _ = try? await webBridge.webView.evaluateJavaScript(cmd)
        }
    }

    // MARK: - Event handling

    private func handle(_ event: HiddenPlayerWebView.BridgeEvent) {
        switch event {
        case .ready:
            if !bridgeReady {
                bridgeReady = true
                Task {
                    await flushPending()
                    // Re-apply persisted prefs to the freshly-loaded page.
                    if volume != 1.0 {
                        _ = try? await webBridge.webView.evaluateJavaScript("window.musicBridge.setVolume(\(volume))")
                    }
                    if playbackRate != 1.0 {
                        _ = try? await webBridge.webView.evaluateJavaScript("window.musicBridge.setPlaybackRate(\(playbackRate))")
                    }
                }
            }
        case .stateChanged(let playing):
            isPlaying = playing
        case .progress(let t, let d):
            elapsed = t
            duration = d
        case .trackChanged(let id, let playlistId, let title, let artist, let art):
            // Time-gated dedupe. Within 30s of a play(item:), we trust the
            // user-clicked metadata over JS-side reports for the same
            // videoId — catches pre-roll ads (which all happen in the
            // first ~10s). After the grace window, we trust JS reports —
            // catches autoplay advances where YT Music's SPA may keep the
            // URL videoId stable but advance mediaSession.metadata.
            let sameVideoId = currentTrack?.videoId == id
            let titleChanged = currentTrack?.title != title
            let withinClickGrace = Date().timeIntervalSince(userClickedAt) < Self.userClickGraceSeconds

            if sameVideoId && !titleChanged {
                // Identical event (re-poll). Just refresh duration if it's
                // newly available.
                if duration > 0, let existing = currentTrack, existing.duration == 0 {
                    currentTrack = Track(
                        videoId: existing.videoId,
                        title: existing.title,
                        subtitle: existing.subtitle,
                        thumbnailURL: existing.thumbnailURL,
                        duration: duration
                    )
                }
            } else if sameVideoId && withinClickGrace {
                // Pre-roll ad / startup churn. Keep the user's clicked
                // metadata; just absorb duration if we got it.
                if duration > 0, let existing = currentTrack, existing.duration == 0 {
                    currentTrack = Track(
                        videoId: existing.videoId,
                        title: existing.title,
                        subtitle: existing.subtitle,
                        thumbnailURL: existing.thumbnailURL,
                        duration: duration
                    )
                }
            } else {
                // New track — different videoId, OR same videoId but
                // outside the click-grace window (autoplay advance).
                // Archive the previous track to history before replacing.
                archiveCurrent()
                currentTrack = Track(videoId: id, title: title, subtitle: artist, thumbnailURL: art, duration: duration)
                currentPlaylistId = playlistId
                userClickedAt = .distantPast  // stop being protective
                refreshNextQueueAndIds(forVideoId: id, playlistId: playlistId)
            }
        }
        onUpdate?()
    }
}

private extension String {
    var jsonQuoted: String {
        let data = try? JSONSerialization.data(withJSONObject: [self])
        let s = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return String(s.dropFirst().dropLast())
    }
}
