import Foundation
import Observation
import SwiftUI
import AppKit

/// Top-level tab identifier. Lifted out of `MainTabs` so the app-level
/// `CommandGroup` (which doesn't see private nested types) can bind
/// ⌘1/2/3/4 shortcuts to switch tabs.
enum AppTab: Hashable {
    case home, explore, search, library
}

@MainActor
@Observable
final class AppEnvironment {
    /// Process-wide weak reference to the currently-live AppEnvironment.
    /// **Intents-only.** The SwiftUI environment-injected instance is the
    /// canonical one; AppIntents has no access to SwiftUI's environment, so
    /// `AppEnvironment.init` populates this so `RiffIntents` can reach the
    /// live PlayerBridge / InnerTubeClient without spinning up a duplicate
    /// WKWebView. Do not consume this from view code.
    ///
    /// MainActor-isolated like the rest of the class; intent `perform()`
    /// bodies are `@MainActor`, so they read this safely.
    static weak var current: AppEnvironment?

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

    /// Drives the "Your Riff Highlights" recap sheet. Raised from the
    /// Help menu entry; consumed by a `.sheet` on RootView.
    var isRecapSheetPresented: Bool = false

    /// Drives the "Create lyric card" sheet. Raised from the lyrics
    /// tab in NowPlayingView; consumed by a `.sheet` on RootView.
    var isLyricCardSheetPresented: Bool = false

    /// Drives the AI Queue Builder sheet (vibe → queue). Raised from
    /// the "✨ Build" button in the Up Next pane header. Independent
    /// of `isNewPlaylistSheetPresented` so the two can't collide.
    var isQueueBuilderSheetPresented: Bool = false

    /// Whether the menu bar mini player (`MenuBarExtra` scene in
    /// `RiffApp`) is inserted into the system menu bar. Defaults to
    /// true; persisted to UserDefaults so the user's preference
    /// survives quit. Mutating this property auto-persists and the
    /// `MenuBarExtra` `.isInserted` binding reacts.
    var menuBarExtraEnabled: Bool = true {
        didSet {
            UserDefaults.standard.set(menuBarExtraEnabled, forKey: Self.menuBarExtraEnabledKey)
        }
    }
    private static let menuBarExtraEnabledKey = "ui.menuBarExtraEnabled"

    /// Lazy LLM provider. The provider type itself is stateless —
    /// secrets live in Keychain and are read fresh on every `chat()`
    /// call so a key rotation doesn't require rebuilding the provider.
    /// Lazy so app launch stays fast for users who never touch AI
    /// features (no Keychain read on startup).
    ///
    /// @ObservationIgnored because @Observable can't synthesize
    /// observation for `lazy var` (the macro rewrites property
    /// access in a way that's incompatible with Swift's lazy
    /// initialization). Provider identity never changes anyway,
    /// so nothing to observe.
    @ObservationIgnored
    lazy var llmProvider: any LLMProvider = AnthropicProvider()

    /// True when an Anthropic API key is configured. Drives the
    /// "AI features" visibility in Settings + the Queue Builder
    /// button affordance in the player.
    var hasLLMAPIKey: Bool {
        (AnthropicProvider.storedAPIKey()?.isEmpty == false)
    }

    /// Lyrics translation engine (B3). Caches per `(videoId, language)`
    /// in memory; no persistence across launches. @ObservationIgnored
    /// for the same `lazy var` reason as `llmProvider`. The translator
    /// is NOT `@Observable` — views read its output via the
    /// `translate()` async call, not by observing internal state, so
    /// the SwiftUI dependency graph doesn't need to track it.
    @ObservationIgnored
    lazy var lyricsTranslator: LyricsTranslator = LyricsTranslator()

    /// Target language for the lyrics-translation toggle. Persisted to
    /// UserDefaults under `lyrics.translationLanguage`. Defaults to
    /// "English" on first launch.
    var translationLanguage: String = "English" {
        didSet {
            UserDefaults.standard.set(translationLanguage, forKey: LyricsTranslator.languageKey)
        }
    }

    /// Whether the lyrics-translation toggle on the Now Playing lyrics
    /// tab is engaged. Persisted under `lyrics.translationEnabled` so
    /// the user's preference survives quit.
    var lyricsTranslationEnabled: Bool = false {
        didSet {
            UserDefaults.standard.set(lyricsTranslationEnabled, forKey: LyricsTranslator.enabledKey)
        }
    }

    /// X-Ray context cards service (B4). Generates 3-6 magazine-style
    /// cards (people / place / era / sample / trivia) for the current
    /// track via the user's configured `LLMProvider`. Same shape as
    /// `lyricsTranslator` — @MainActor, in-memory cache keyed by
    /// videoId. @ObservationIgnored for the `lazy var` reason.
    @ObservationIgnored
    lazy var xrayCardsService: XRayCardsService = XRayCardsService()

    /// Which source seeds the next-presented New Playlist sheet.
    /// Default is the historical behavior (add current tvamsrack); the
    /// "Save queue" button on the Up Next pane flips this to `.queue`
    /// before raising `isNewPlaylistSheetPresented`.
    var newPlaylistSource: NewPlaylistSheet.Source = .currentTrack

    /// Per-tab navigation paths. Held here so the TopTabBar can pop a tab
    /// to its root when the user taps the already-active tab — standard
    /// "tap home to go home" behaviour.
    var homeNavPath = NavigationPath()
    var exploreNavPath = NavigationPath()
    var searchNavPath = NavigationPath()
    var libraryNavPath = NavigationPath()

    /// Currently-active main tab. Lifted out of MainTabs so the app-level
    /// CommandGroup can drive it via ⌘1 / ⌘2 / ⌘3 keyboard shortcuts.
    var activeTab: AppTab = .home

    /// Map of artist browseId → display name for artists the user has
    /// chosen never to see again. Items whose `artistId` is in the map
    /// get filtered from Home carousels, Search results, /next radio
    /// queues, and /related songs.
    ///
    /// We store the name alongside the id (rather than just the id, as
    /// the original `Set<String>` did) so Settings can render a useful
    /// row label instead of opaque `UCxx…` ids.
    ///
    /// Stored under `library.blockedArtists` in UserDefaults — a fresh
    /// key, so the legacy `library.blockedArtistIds` set is silently
    /// migrated on first load (names default to the id until the user
    /// re-encounters and re-blocks the artist).
    ///
    /// Client-side only: server-side propagation isn't possible
    /// without a YT API for "block artist" (none documented). YT
    /// Music's autoplay can still pick a blocked artist when the
    /// current track ends — settings text spells that out.
    private(set) var blockedArtists: [String: String] = [:]
    private static let blockedArtistsKey = "library.blockedArtists"
    private static let legacyBlockedArtistIdsKey = "library.blockedArtistIds"

    /// Sorted ids, exposed read-only for views that need stable iteration.
    var blockedArtistIds: [String] { blockedArtists.keys.sorted() }

    func blockedArtistName(id: String) -> String {
        blockedArtists[id] ?? id  // fall back to id when migrating from legacy storage
    }

    func isBlocked(artistId: String?) -> Bool {
        guard let id = artistId, !id.isEmpty else { return false }
        return blockedArtists[id] != nil
    }

    func isBlocked(_ item: MediaItem) -> Bool {
        // Block by artist match OR when the item itself IS the blocked
        // artist (e.g. an Artist tile in a search-result list).
        if item.kind == .artist && blockedArtists[item.id] != nil { return true }
        return isBlocked(artistId: item.artistId)
    }

    /// Block by id + capture the human-readable name in one call.
    /// Callers from track context menus already have both (the
    /// MediaItem carries title for artist tiles, or carries the
    /// subtitle which holds the artist name for song rows).
    func blockArtist(id: String, name: String) {
        guard !id.isEmpty else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        // Don't let an empty name overwrite an existing one — if the
        // caller passes "" we keep whatever name we previously knew.
        blockedArtists[id] = trimmed.isEmpty ? (blockedArtists[id] ?? id) : trimmed
        persistBlockedArtists()
    }

    func unblockArtist(id: String) {
        blockedArtists.removeValue(forKey: id)
        persistBlockedArtists()
    }

    private func persistBlockedArtists() {
        UserDefaults.standard.set(blockedArtists, forKey: Self.blockedArtistsKey)
    }

    /// Set of MediaItem ids the user has explicitly pinned to the top
    /// of their Library section grid. Persisted under `library.pinned`
    /// in UserDefaults as a sorted `[String]` (Set is not a PLIST type).
    ///
    /// Pinning is purely client-side and cross-section: the same set is
    /// consulted by every Library section (playlists, albums, podcasts,
    /// artists). An item with id "X" pinned in the Playlists view stays
    /// pinned if it ever shows up in Albums — which it won't, but the
    /// id-based shape makes that trivially correct.
    ///
    /// We deliberately don't gate pinning on `isSignedIn`: anonymous
    /// users still see a Library tab (it just renders the empty state),
    /// and the moment they sign in their pins are already in place.
    private(set) var pinnedLibraryIds: Set<String> = []
    private static let pinnedLibraryIdsKey = "library.pinned"

    func isPinned(_ id: String) -> Bool {
        !id.isEmpty && pinnedLibraryIds.contains(id)
    }

    /// Toggle the pin state of a Library item. The Pin / Unpin button
    /// in `TrackContextMenu` and `ThumbnailButton`'s context menu both
    /// route through here so the persistence side-effect lives in one
    /// place.
    func togglePinned(id: String) {
        guard !id.isEmpty else { return }
        if pinnedLibraryIds.contains(id) {
            pinnedLibraryIds.remove(id)
        } else {
            pinnedLibraryIds.insert(id)
        }
        persistPinnedLibrary()
    }

    private func persistPinnedLibrary() {
        UserDefaults.standard.set(pinnedLibraryIds.sorted(), forKey: Self.pinnedLibraryIdsKey)
    }

    private func loadPinnedLibrary() {
        if let arr = UserDefaults.standard.stringArray(forKey: Self.pinnedLibraryIdsKey) {
            pinnedLibraryIds = Set(arr)
        }
    }

    private func loadBlockedArtists() {
        if let dict = UserDefaults.standard.dictionary(forKey: Self.blockedArtistsKey) as? [String: String] {
            blockedArtists = dict
            return
        }
        // One-time migration from the legacy Set<String> shape. Names
        // default to the id; the next "Don't recommend" tap on the
        // same artist will upgrade the entry with a real name.
        if let arr = UserDefaults.standard.stringArray(forKey: Self.legacyBlockedArtistIdsKey) {
            blockedArtists = Dictionary(uniqueKeysWithValues: arr.map { ($0, $0) })
            persistBlockedArtists()
            UserDefaults.standard.removeObject(forKey: Self.legacyBlockedArtistIdsKey)
        }
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
        case .explore: exploreNavPath.append(item)
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
        self.loadPinnedLibrary()
        // Honor the persisted menu-bar-extra toggle. The key defaults to
        // `true` when absent (first launch / never-toggled), preserving
        // the "show by default" behavior. Read via `object(forKey:)` so
        // we can distinguish "absent" from "explicitly set to false".
        if let stored = UserDefaults.standard.object(forKey: Self.menuBarExtraEnabledKey) as? Bool {
            self.menuBarExtraEnabled = stored
        }
        // Lyrics-translation preferences (B3). Read via `object(forKey:)`
        // so an absent key (first launch) doesn't shadow the property's
        // default value. Setting via the property's `didSet` would
        // re-persist; we go around it by assigning directly to avoid
        // a no-op write on every launch.
        if let lang = UserDefaults.standard.string(forKey: LyricsTranslator.languageKey),
           !lang.isEmpty {
            self.translationLanguage = lang
        }
        if let toggle = UserDefaults.standard.object(forKey: LyricsTranslator.enabledKey) as? Bool {
            self.lyricsTranslationEnabled = toggle
        }
        // Publish ourselves as the process-wide handle for AppIntents.
        // RiffApp creates exactly one AppEnvironment; if that ever
        // changes, the weak ref naturally tracks the latest instance.
        Self.current = self
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
