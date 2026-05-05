import Foundation
import Observation

/// Public playback API. SwiftUI views call methods here; this class translates
/// to JS evaluations on the hidden WKWebView, and observes the page's events
/// back into observable state.
@Observable
@MainActor
final class PlayerBridge {
    private(set) var isPlaying: Bool = false
    private(set) var progress: Double = 0  // 0...1
    private(set) var currentTrack: Track? = nil
    var hasTrack: Bool { currentTrack != nil }

    private lazy var webBridge: HiddenPlayerWebView = {
        let bridge = HiddenPlayerWebView()
        bridge.onEvent = { [weak self] event in self?.handle(event) }
        return bridge
    }()

    struct Track: Hashable {
        let videoId: String
        let title: String
        let subtitle: String
        let thumbnailURL: URL?
        let duration: Double
    }

    // MARK: - Commands

    func play(videoId: String) async {
        await eval("window.musicBridge.playVideo(\(videoId.jsonQuoted))")
    }

    func playAlbum(id: String)    async { await eval("window.musicBridge.playAlbum(\(id.jsonQuoted))") }
    func playPlaylist(id: String) async { await eval("window.musicBridge.playPlaylist(\(id.jsonQuoted))") }
    func playPodcast(id: String)  async { await eval("window.musicBridge.playPodcast(\(id.jsonQuoted))") }
    func playArtistRadio(id: String) async { await eval("window.musicBridge.playArtistRadio(\(id.jsonQuoted))") }

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
            progress = d > 0 ? t / d : 0
        case .trackChanged(let id, let title, let artist, let art):
            currentTrack = Track(videoId: id, title: title, subtitle: artist, thumbnailURL: art, duration: 0)
        }
    }
}

private extension String {
    var jsonQuoted: String {
        let data = try? JSONSerialization.data(withJSONObject: [self])
        let s = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return String(s.dropFirst().dropLast())
    }
}
