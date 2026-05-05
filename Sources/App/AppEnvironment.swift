import Foundation
import Observation

@MainActor
@Observable
final class AppEnvironment {
    let innerTube: InnerTubeClient
    let player: PlayerBridge
    let nowPlaying: NowPlayingCenter

    /// Set to true once the user has signed in via the modal sheet. Persisted
    /// across launches; the InnerTube cookie sync runs on transitions.
    var hasSignedIn: Bool {
        didSet {
            UserDefaults.standard.set(hasSignedIn, forKey: Self.signedInKey)
            if hasSignedIn { Task { await CookieJar.syncFromWebView() } }
        }
    }

    private static let signedInKey = "riff.hasSignedIn"

    init() {
        self.innerTube = InnerTubeClient()
        self.player = PlayerBridge()
        self.nowPlaying = NowPlayingCenter(player: player)
        self.hasSignedIn = UserDefaults.standard.bool(forKey: Self.signedInKey)
    }
}
