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
    var hasTrack: Bool { currentTrack != nil }

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
        onUpdate?()
        await play(videoId: item.id)
    }

    /// Plays a known YT Music playlist (regular playlists where `id` is the
    /// playlistId itself). For album/podcast/artist tiles, see the resolver
    /// variants below.
    func playPlaylist(id: String) async {
        await navigate(watchURL(videoId: nil, playlistId: id))
    }

    func playAlbum(id: String)    async { await playByResolvingBrowseId(id) }
    func playPodcast(id: String)  async { await playByResolvingBrowseId(id) }
    func playArtistRadio(id: String) async { await playByResolvingBrowseId(id) }

    /// Resolves a browseId via InnerTube (first watchEndpoint in the
    /// response), then navigates to /watch?v=&list= so the page builds the
    /// queue. Silently no-ops if the browse has no playable item.
    private func playByResolvingBrowseId(_ browseId: String) async {
        guard let tuple = (try? await innerTube.playable(forBrowseId: browseId)) ?? nil else {
            #if DEBUG
            print("[Riff resolver] \(browseId) → no playable endpoint found")
            #endif
            return
        }
        let url = watchURL(videoId: tuple.videoId, playlistId: tuple.playlistId)
        #if DEBUG
        print("[Riff resolver] \(browseId) → v=\(tuple.videoId ?? "nil") list=\(tuple.playlistId ?? "nil") → \(url)")
        #endif
        await navigate(url)
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
        case .trackChanged(let id, let title, let artist, let art):
            // YT Music plays 2-3 video ads before each track for anonymous
            // sessions. Each ad fires trackChanged with its own metadata,
            // but the URL videoId stays at the song the user clicked.
            // Ignore events that match the videoId we already have — we
            // trust the MediaItem-derived metadata over the ad's. Only
            // adopt the JS-side metadata when the videoId actually changes
            // (autoplay advance).
            if currentTrack?.videoId == id {
                // Same track; refresh duration if we now have it but skip
                // title/artist/artwork churn.
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
                Task { [innerTube, weak self] in
                    let queue = (try? await innerTube.nextQueue(videoId: id, playlistId: nil)) ?? []
                    await MainActor.run { self?.upNext = queue }
                }
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
