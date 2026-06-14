import Foundation
import Observation
import SwiftUI
import AppKit

/// Top-level tab identifier. Lifted out of `MainTabs` so the app-level
/// `CommandGroup` (which doesn't see private nested types) can bind ⌘1/2/3
/// shortcuts to switch tabs.
enum AppTab: Hashable {
    case home, search, library
}

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

    /// Drives the "New playlist" name-prompt sheet.
    var isNewPlaylistSheetPresented: Bool = false

    /// Which source seeds the next-presented New Playlist sheet.
    /// Default is the historical behavior (add current track); the
    /// "Save queue" button on the Up Next pane flips this to `.queue`
    /// before raising `isNewPlaylistSheetPresented`.
    var newPlaylistSource: NewPlaylistSheet.Source = .currentTrack

    /// Per-tab navigation paths. Held here so the TopTabBar can pop a tab
    /// to its root when the user taps the already-active tab — standard
    /// "tap home to go home" behaviour.
    var homeNavPath = NavigationPath()
    var searchNavPath = NavigationPath()
    var libraryNavPath = NavigationPath()

    /// Currently-active main tab. Lifted out of MainTabs so the app-level
    /// CommandGroup can drive it via ⌘1 / ⌘2 / ⌘3 keyboard shortcuts.
    var activeTab: AppTab = .home

    /// Set of artist browseIds the user has chosen never to see again.
    /// Mirrors YT Music's "Don't recommend this artist" affordance —
    /// items whose `artistId` is in this set are filtered out of
    /// surfaces that show recommendations (Home carousels, Search
    /// results, /next radio queues, /related songs).
    ///
    /// Stored under `library.blockedArtistIds` in UserDefaults so it
    /// survives sign-out + relaunch. Server-side propagation isn't
    /// possible without a YT API for "block artist" (none documented),
    /// so this is client-side only — same caveat as `removeFromQueue`:
    /// the WebView's autoplay can still pick a blocked artist when
    /// the current track ends. We don't pretend otherwise; the
    /// settings panel explains the limit.
    private(set) var blockedArtistIds: Set<String> = []
    private static let blockedArtistIdsKey = "library.blockedArtistIds"

    func isBlocked(artistId: String?) -> Bool {
        guard let id = artistId, !id.isEmpty else { return false }
        return blockedArtistIds.contains(id)
    }

    func isBlocked(_ item: MediaItem) -> Bool {
        // Block by artist match OR when the item itself IS the blocked
        // artist (e.g. an Artist tile in a search-result list).
        if item.kind == .artist && blockedArtistIds.contains(item.id) { return true }
        return isBlocked(artistId: item.artistId)
    }

    func blockArtist(id: String) {
        guard !id.isEmpty else { return }
        blockedArtistIds.insert(id)
        persistBlockedArtists()
    }

    func unblockArtist(id: String) {
        blockedArtistIds.remove(id)
        persistBlockedArtists()
    }

    private func persistBlockedArtists() {
        let arr = Array(blockedArtistIds).sorted()  // sorted for deterministic on-disk form
        UserDefaults.standard.set(arr, forKey: Self.blockedArtistIdsKey)
    }

    private func loadBlockedArtists() {
        let arr = UserDefaults.standard.stringArray(forKey: Self.blockedArtistIdsKey) ?? []
        blockedArtistIds = Set(arr)
    }

    /// Navigate to a media item's detail page, regardless of where the
    /// caller is. Closes the full-screen Now Playing overlay (so the
    /// destination is actually visible) and pushes the item onto the
    /// active tab's NavigationStack. Used by "Go to album" / "Go to
    /// artist" context-menu actions, including from the player itself.
    func navigate(to item: MediaItem) {
        if player.isFullPlayerOpen {
            player.isFullPlayerOpen = false
        }
        switch activeTab {
        case .home:    homeNavPath.append(item)
        case .search:  searchNavPath.append(item)
        case .library: libraryNavPath.append(item)
        }
    }

    /// Convenience: navigate to an album / artist by its browseId,
    /// synthesizing a minimal `MediaItem`. Used when we have only the
    /// id (e.g. from a now-playing track's `albumId`) and not a full
    /// item to push.
    func navigateToBrowseId(_ id: String, kind: MediaItem.Kind, fallbackTitle: String = "") {
        let item = MediaItem(
            id: id,
            kind: kind,
            title: fallbackTitle,
            subtitle: "",
            thumbnailURL: nil
        )
        navigate(to: item)
    }

    /// Cached user-owned playlists for "Add to Playlist" menus. Loaded on
    /// demand when a UI surface needs them; refreshed whenever the user
    /// signs in/out.
    private(set) var userPlaylists: [MediaItem] = []
    private(set) var userPlaylistsLoading = false
    func loadUserPlaylistsIfNeeded() {
        guard isSignedIn, !userPlaylistsLoading, userPlaylists.isEmpty else { return }
        reloadUserPlaylists()
    }

    func reloadUserPlaylists() {
        guard isSignedIn else { return }
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
        self.loadBlockedArtists()
        // Subscribe to MetricKit on launch — Apple's built-in crash /
        // hang / perf reporter. Payloads land daily under
        // ~/Library/Application Support/Riff/diagnostics/. No network
        // exfiltration; user shares manually if asked.
        DiagnosticsCenter.shared.start()
        // Snapshot the playback session on app exit so "Continue
        // where you left off" survives a quit. The progress-driven
        // snapshot is rate-limited to once-per-5s; this catches the
        // delta between the last rate-limited write and quit.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [player] _ in
            MainActor.assumeIsolated { player.snapshotSession() }
        }

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
        // Hand PlayerBridge the predicate it uses to filter blocked
        // artists out of upNext / related. Closure captures self
        // weakly; if env is gone the filter falls back to "block
        // nothing" via the default initializer.
        self.player.shouldBlock = { [weak self] item in
            self?.isBlocked(item) ?? false
        }
    }
}
