import Foundation

/// Translates an InnerTube browseId (album / playlist / artist /
/// podcast) into a `(videoId?, playlistId?)` tuple that we can pass
/// to `/watch?v=&list=` and have YT Music start playing the right
/// thing.
///
/// Extracted from `PlayerBridge.playByResolvingBrowseId` per the audit
/// (§6.8) so the resolution logic — primary path + VL-strip fallback +
/// last-ditch browse-page fallback — sits in one place that's easy to
/// test and reason about. PlayerBridge keeps the navigation side
/// (which constructs the watch URL and drives the WKWebView); this
/// type owns the *what to play* decision.
enum BrowseIdResolver {

    /// One of three destinations:
    ///   - `.watch(videoId, playlistId)` — pass to `/watch?v=…&list=…`.
    ///     Either field may be nil; at least one is non-nil.
    ///   - `.directPlaylist(playlistId)` — VL-stripped playlist;
    ///     navigate `/watch?list=<plid>` directly.
    ///   - `.browsePage(URL)` — last-resort: drop the user on the
    ///     entity's page so they can press Play manually. Used when
    ///     resolution failed entirely.
    enum Destination: Equatable {
        case watch(videoId: String?, playlistId: String?)
        case directPlaylist(playlistId: String)
        case browsePage(URL)
    }

    /// Resolve `browseId` via InnerTube, falling through three paths
    /// before declaring "best we can do is open the browse page":
    ///
    ///   1. `innerTube.playable(forBrowseId:)` — primary path. Looks
    ///      at the browse response's `microformat.urlCanonical` to
    ///      pull (videoId?, playlistId?). Most reliable.
    ///   2. **VL-prefix strip** — `VL<plid>` is the YT Music
    ///      convention for "browse this playlist"; the playable id is
    ///      the suffix. If the resolver missed (returned nil), we
    ///      try the strip ourselves.
    ///   3. **Browse-page fallback** — drop the user on the entity's
    ///      `/browse/<browseId>` URL. Not autoplay, but at least the
    ///      page loads and the user has a Play button to press.
    static func resolve(
        _ browseId: String,
        via innerTube: InnerTubeClient
    ) async -> Destination {
        // Path 1: ask InnerTube.
        if let tuple = (try? await innerTube.playable(forBrowseId: browseId)) ?? nil {
            return .watch(videoId: tuple.videoId, playlistId: tuple.playlistId)
        }
        // Path 2: VL-prefix strip → direct playlist.
        if browseId.hasPrefix("VL") {
            return .directPlaylist(playlistId: String(browseId.dropFirst(2)))
        }
        // Path 3: at least navigate to the entity's page.
        let url = URL(string: "https://music.youtube.com/browse/\(browseId)")!
        return .browsePage(url)
    }
}
