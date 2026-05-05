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
    private(set) var related: [MediaItem] = []
    private(set) var lyrics: String? = nil
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
        // Eager init: start loading music.youtube.com offscreen at app start,
        // so by the time the user clicks anything the page is loaded.
        self.webBridge = HiddenPlayerWebView()
        self.webBridge.onEvent = { [weak self] event in self?.handle(event) }
    }

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
        refreshNextQueueAndIds(forVideoId: item.id, playlistId: nil)
        onUpdate?()
        await play(videoId: item.id)
    }

    /// Pull /next for the given videoId — populates `upNext` and stashes
    /// browse IDs for lyrics + related which are loaded on demand.
    /// Pass `playlistId` when known so /next returns the playlist's track
    /// list instead of generic radio suggestions.
    private func refreshNextQueueAndIds(forVideoId id: String, playlistId: String?) {
        Task { [innerTube, weak self] in
            guard let response = try? await innerTube.nextQueue(videoId: id, playlistId: playlistId) else { return }
            await MainActor.run {
                self?.upNext = response.queue
                self?.lyricsBrowseId = response.lyricsBrowseId
                self?.relatedBrowseId = response.relatedBrowseId
                self?.liked = response.likeStatus == .like
                // Invalidate previously cached tab content for the old track.
                self?.lyrics = nil
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
    func loadLyricsIfNeeded() {
        guard lyrics == nil, !lyricsLoading, let id = lyricsBrowseId else { return }
        lyricsLoading = true
        Task { [innerTube, weak self] in
            let text = (try? await innerTube.lyrics(browseId: id)) ?? nil
            await MainActor.run {
                self?.lyrics = text ?? "Lyrics not available."
                self?.lyricsLoading = false
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
        await eval("window.musicBridge.setPlaybackRate(\(rate))")
    }

    /// Skip ±N seconds — podcast-style transport. Negative skips back.
    func skip(by seconds: Double) async {
        await eval("window.musicBridge.skipBy(\(seconds))")
    }

    /// Volume 0.0...1.0. Persisted across track changes within the session
    /// (defaults to 1.0 on launch, the WebView's natural state).
    private(set) var volume: Double = 1.0
    func setVolume(_ level: Double) async {
        let clamped = max(0.0, min(1.0, level))
        volume = clamped
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
                Task { await flushPending() }
            }
        case .stateChanged(let playing):
            isPlaying = playing
        case .progress(let t, let d):
            elapsed = t
            duration = d
        case .trackChanged(let id, let playlistId, let title, let artist, let art):
            if currentTrack?.videoId == id {
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
                currentTrack = Track(videoId: id, title: title, subtitle: artist, thumbnailURL: art, duration: duration)
                currentPlaylistId = playlistId
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
