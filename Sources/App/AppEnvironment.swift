import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class AppEnvironment {
    let innerTube: InnerTubeClient
    let player: PlayerBridge
    let nowPlaying: NowPlayingCenter

    /// True when an OAuth Device Flow token (or a fallback SAPISID cookie)
    /// is present. Recomputed via `refreshSignedInState()` on app start
    /// and after sign-in/out.
    private(set) var isSignedIn: Bool = false

    func refreshSignedInState() {
        let hasToken = OAuthTokens.load() != nil
        let hasCookie = HTTPCookieStorage.shared.cookies?.contains(where: {
            ["SAPISID", "__Secure-3PAPISID"].contains($0.name)
        }) ?? false
        isSignedIn = hasToken || hasCookie
    }

    /// Sign out clears OAuth tokens + cookies and re-evaluates state.
    func signOut() {
        OAuthDeviceFlow.signOut()
        HTTPCookieStorage.shared.cookies?
            .filter { $0.domain.contains("youtube.com") || $0.domain.contains("google.com") }
            .forEach { HTTPCookieStorage.shared.deleteCookie($0) }
        refreshSignedInState()
    }

    /// Drives the manual presentation of the sign-in sheet. Set to true from
    /// the menu bar action or Library empty-state CTA. Sign-in is not
    /// auto-presented — the app works anonymously by default.
    var isSignInSheetPresented: Bool = false

    /// Drives the Settings sheet (custom OAuth credentials, sign-out).
    var isSettingsSheetPresented: Bool = false

    /// Per-tab navigation paths. Held here so the TopTabBar can pop a tab
    /// to its root when the user taps the already-active tab — standard
    /// "tap home to go home" behaviour.
    var homeNavPath = NavigationPath()
    var searchNavPath = NavigationPath()
    var libraryNavPath = NavigationPath()

    /// Cached user-owned playlists for "Add to Playlist" menus. Loaded on
    /// demand when a UI surface needs them; refreshed whenever the user
    /// signs in/out.
    private(set) var userPlaylists: [MediaItem] = []
    private(set) var userPlaylistsLoading = false
    func loadUserPlaylistsIfNeeded() {
        guard isSignedIn, !userPlaylistsLoading, userPlaylists.isEmpty else { return }
        userPlaylistsLoading = true
        Task { [innerTube] in
            let items = (try? await innerTube.library(section: .playlists)) ?? []
            await MainActor.run {
                userPlaylists = items.filter { $0.kind == .playlist }
                userPlaylistsLoading = false
            }
        }
    }

    init() {
        self.innerTube = InnerTubeClient()
        self.player = PlayerBridge(innerTube: innerTube)
        self.nowPlaying = NowPlayingCenter(player: player)
        self.refreshSignedInState()

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
