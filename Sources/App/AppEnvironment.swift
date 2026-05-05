import Foundation
import Observation

@Observable
final class AppEnvironment {
    let innerTube: InnerTubeClient
    let player: PlayerBridge
    let nowPlaying: NowPlayingCenter

    init() {
        self.innerTube = InnerTubeClient()
        self.player = PlayerBridge()
        self.nowPlaying = NowPlayingCenter(player: player)
    }
}
