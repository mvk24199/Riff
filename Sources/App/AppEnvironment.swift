import Foundation
import Observation

@MainActor
@Observable
final class AppEnvironment {
    let innerTube: InnerTubeClient
    let player: PlayerBridge
    let nowPlaying: NowPlayingCenter

    /// Inferred from the `SAPISID` cookie set by an in-flight WebView
    /// session. Recomputed each access; not persisted directly because the
    /// cookie itself is the source of truth.
    var isSignedIn: Bool {
        let names: Set<String> = ["SAPISID", "__Secure-3PAPISID"]
        return HTTPCookieStorage.shared.cookies?.contains(where: { names.contains($0.name) }) ?? false
    }

    /// Drives the manual presentation of the sign-in sheet. Set to true from
    /// the menu bar action or Library empty-state CTA. Sign-in is not
    /// auto-presented — the app works anonymously by default. See plan
    /// "Phase E.0 — Anonymous-first sign-in pivot" for context.
    var isSignInSheetPresented: Bool = false

    init() {
        self.innerTube = InnerTubeClient()
        self.player = PlayerBridge(innerTube: innerTube)
        self.nowPlaying = NowPlayingCenter(player: player)

        // Mirror PlayerBridge state into MPNowPlayingInfoCenter on every
        // change. NowPlayingCenter holds a strong ref to player; here we go
        // the other way without retaining nowPlaying strongly inside player.
        self.player.onUpdate = { [weak self] in
            guard let self, let track = self.player.currentTrack else { return }
            self.nowPlaying.update(
                title: track.title,
                artist: track.subtitle,
                artwork: track.thumbnailURL,
                duration: self.player.duration,
                elapsed: self.player.elapsed
            )
        }
    }
}
