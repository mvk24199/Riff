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
    private lazy var webBridge: HiddenPlayerWebView = {
        let bridge = HiddenPlayerWebView()
        bridge.onEvent = { [weak self] event in self?.handle(event) }
        return bridge
    }()

    init(innerTube: InnerTubeClient) {
        self.innerTube = innerTube
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
        guard let tuple = (try? await innerTube.playable(forBrowseId: browseId)) ?? nil else { return }
        await navigate(watchURL(videoId: tuple.videoId, playlistId: tuple.playlistId))
    }

    private func watchURL(videoId: String?, playlistId: String?) -> String {
        var components = URLComponents(string: "https://music.youtube.com/watch")!
        var items: [URLQueryItem] = []
        if let videoId { items.append(URLQueryItem(name: "v", value: videoId)) }
        if let playlistId { items.append(URLQueryItem(name: "list", value: playlistId)) }
        components.queryItems = items
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
        _ = try? await webBridge.webView.evaluateJavaScript(js)
    }

    // MARK: - Event handling

    private func handle(_ event: HiddenPlayerWebView.BridgeEvent) {
        switch event {
        case .ready:
            break
        case .stateChanged(let playing):
            isPlaying = playing
        case .progress(let t, let d):
            elapsed = t
            duration = d
        case .trackChanged(let id, let title, let artist, let art):
            currentTrack = Track(videoId: id, title: title, subtitle: artist, thumbnailURL: art, duration: duration)
            Task { [innerTube, weak self] in
                let queue = (try? await innerTube.nextQueue(videoId: id, playlistId: nil)) ?? []
                await MainActor.run { self?.upNext = queue }
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
