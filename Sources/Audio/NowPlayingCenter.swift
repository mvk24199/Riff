import Foundation
import MediaPlayer

/// Mirrors PlayerBridge state into MPNowPlayingInfoCenter and registers
/// MPRemoteCommandCenter handlers so Control Center, AirPods, keyboard media
/// keys, and Touch Bar can drive playback.
@MainActor
final class NowPlayingCenter {
    private let player: PlayerBridge

    init(player: PlayerBridge) {
        self.player = player
        registerCommands()
    }

    private func registerCommands() {
        let cc = MPRemoteCommandCenter.shared()
        cc.playCommand.addTarget   { [weak self] _ in Task { await self?.player.togglePlay() }; return .success }
        cc.pauseCommand.addTarget  { [weak self] _ in Task { await self?.player.togglePlay() }; return .success }
        cc.nextTrackCommand.addTarget     { [weak self] _ in Task { await self?.player.next() };     return .success }
        cc.previousTrackCommand.addTarget { [weak self] _ in Task { await self?.player.previous() }; return .success }
        cc.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent,
                  let self = self,
                  let track = self.player.currentTrack,
                  track.duration > 0 else { return .commandFailed }
            Task { await self.player.seek(to: event.positionTime / track.duration) }
            return .success
        }
    }

    /// Call after a track change with up-to-date metadata.
    func update(title: String, artist: String, artwork: URL?, duration: Double, elapsed: Double) {
        let info: [String: Any] = [
            MPMediaItemPropertyTitle: title,
            MPMediaItemPropertyArtist: artist,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: player.isPlaying ? 1.0 : 0.0,
        ]
        // Artwork loading deferred until we wire the image fetcher.
        _ = artwork
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}
