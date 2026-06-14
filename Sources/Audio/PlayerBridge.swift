import Foundation
import Observation
import WebKit

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

    /// Owns Up Next + played-history. `let` because the manager itself
    /// is immutable; @Observable still tracks accesses to its own
    /// properties (queue.upNext / queue.playedHistory) so SwiftUI
    /// re-renders on mutation through the pass-throughs below.
    let queue = QueueManager()

    /// Pass-through accessors. Existing views read `env.player.upNext`
    /// and `env.player.playedHistory` — keeping the API stable while
    /// the actual storage moves to `QueueManager`.
    var upNext: [MediaItem] { queue.upNext }
    var playedHistory: [MediaItem] { queue.playedHistory }

    private(set) var related: [MediaItem] = []
    /// Tune chips parsed from the latest `/next` response (e.g. All,
    /// Familiar, Discover, Popular, Telugu, 2010s, …). Empty when YT
    /// didn't include a chip cloud for the current watch context.
    private(set) var availableChips: [InnerTubeClient.QueueChip] = []
    /// Id of the chip currently driving `upNext`. nil before the first
    /// `/next` lands or when the user hasn't selected one explicitly —
    /// in which case we treat the YT-marked `isSelected` chip as the
    /// active one for highlighting purposes.
    private(set) var selectedChipId: String? = nil
    private(set) var lyrics: String? = nil
    private(set) var lyricsLines: [InnerTubeClient.LyricLine] = []
    private(set) var lyricsTimed: Bool = false
    private(set) var lyricsLoading: Bool = false
    private(set) var liked: Bool = false
    /// Whether the full-screen Now Playing view is presented.
    var isFullPlayerOpen: Bool = false
    var hasTrack: Bool { currentTrack != nil }

    /// Cached browse IDs from /next response — used to lazy-load lyrics
    /// and related songs only when the user opens those tabs.
    @ObservationIgnored private var lyricsBrowseId: String?
    @ObservationIgnored private var relatedBrowseId: String?
    /// Playlist ID extracted from the current /watch URL. Required to fetch
    /// the right Up Next queue when playing inside a playlist (without it,
    /// /next returns radio-style suggestions instead of the playlist's tracks).
    @ObservationIgnored private var currentPlaylistId: String?

    /// In-flight `/next` refresh, if any. Held so we can cancel-and-replace
    /// when the user clicks rapidly through tracks — without this, multiple
    /// concurrent `/next` requests race and the last-to-complete wins,
    /// which may not be the most-recent click.
    @ObservationIgnored private var nextQueueTask: Task<Void, Never>?

    /// Fires after any state change (track, play/pause, progress). Used by
    /// AppEnvironment to drive NowPlayingCenter without coupling the two
    /// classes directly. @ObservationIgnored: this is plumbing, not state.
    @ObservationIgnored
    var onUpdate: (() -> Void)?

    /// Closure that returns true when a given (artistId, item) should
    /// be filtered out of recommendations. Set by AppEnvironment
    /// (which owns the block-list) post-init. Defaults to "block
    /// nothing" so unit tests don't need to wire it. Called from the
    /// queue assignment + related-songs assignment paths.
    @ObservationIgnored
    var shouldBlock: (MediaItem) -> Bool = { _ in false }

    /// VideoIds of tracks the user has explicitly inserted into upNext
    /// via "Play next" / "Add to queue". When the current `<video>`
    /// reaches `ended`, we navigate to the first match instead of
    /// letting YT Music's natural autoplay pick a different radio
    /// suggestion. Cleared on consume so the same item only takes
    /// priority once. Tracks NOT in this set advance via the page's
    /// normal autoplay (no interception, no race).
    @ObservationIgnored
    private var userQueuedIds: Set<String> = []

    @ObservationIgnored
    private let innerTube: InnerTubeClient

    @ObservationIgnored
    private let webBridge: HiddenPlayerWebView

    /// `window.musicBridge` doesn't exist until the JS user script has run.
    /// Eval calls before the bridge fires `ready` get queued; we flush on
    /// the first `ready` event. Without this, the very first click after
    /// app launch races against the initial music.youtube.com load and
    /// silently no-ops.
    @ObservationIgnored
    private var bridgeReady: Bool = false
    @ObservationIgnored
    private var pendingCommands: [String] = []

    init(innerTube: InnerTubeClient) {
        self.innerTube = innerTube
        // Restore playback prefs from prior launch.
        let storedVolume = UserDefaults.standard.object(forKey: Self.volumeKey) as? Double
        let storedRate   = UserDefaults.standard.object(forKey: Self.rateKey)   as? Double
        self.volume = storedVolume ?? 1.0
        self.playbackRate = storedRate ?? 1.0
        if let raw = UserDefaults.standard.string(forKey: Self.repeatKey),
           let mode = RepeatMode(rawValue: raw) {
            self.repeatMode = mode
        }
        self.shuffleEnabled = UserDefaults.standard.bool(forKey: Self.shuffleKey)
        // Eager init: start loading music.youtube.com offscreen at app start,
        // so by the time the user clicks anything the page is loaded.
        self.webBridge = HiddenPlayerWebView()
        self.webBridge.onEvent = { [weak self] event in self?.handle(event) }
        // QueueManager loads its own persisted history; nothing to do
        // here besides depending on the `let queue = QueueManager()`
        // initializer that already ran.
        // Restore "what was playing" so the mini bar isn't empty on
        // launch. Doesn't auto-play — the WebView won't navigate
        // until the user presses play.
        restoreLastSession()
    }

    private static let volumeKey = "player.volume"
    private static let rateKey   = "player.rate"
    private static let repeatKey = "player.repeat"
    private static let shuffleKey = "player.shuffle"
    private static let lastSessionKey = "player.lastSession"

    /// Snapshot of "what was playing when the user quit" — mirrors YT
    /// Music's behavior of showing your last-played track on the mini
    /// bar at app launch. Press play to resume from the saved position.
    /// Not auto-resumed: launching the app shouldn't blast audio at
    /// you; the user has to opt in by pressing play.
    private struct LastSession: Codable {
        let videoId: String
        let title: String
        let subtitle: String
        let thumbnailURL: URL?
        let albumId: String?
        let artistId: String?
        let elapsed: Double
        let duration: Double
        let savedAt: Date
    }

    /// (videoId, elapsed) pending playback. Set during init when a
    /// LastSession was restored; consumed by the next user-initiated
    /// play action (`togglePlay` checks for it first). nil otherwise.
    @ObservationIgnored
    private var pendingResume: (videoId: String, elapsed: Double)? = nil

    /// Persist a snapshot of the currently-playing track. Called on
    /// every progress event (rate-limited via `lastSnapshotAt`) and on
    /// app exit. UserDefaults write is atomic so a crash mid-write
    /// can't corrupt the snapshot.
    @ObservationIgnored private var lastSnapshotAt: Date = .distantPast
    private static let snapshotEverySeconds: TimeInterval = 5

    private func snapshotSessionIfDue() {
        let now = Date()
        guard now.timeIntervalSince(lastSnapshotAt) >= Self.snapshotEverySeconds else { return }
        snapshotSession()
    }

    /// Force a snapshot — used on app exit and on every track change
    /// regardless of the snapshot rate-limit.
    func snapshotSession() {
        guard let track = currentTrack else { return }
        lastSnapshotAt = Date()
        let snap = LastSession(
            videoId: track.videoId,
            title: track.title,
            subtitle: track.subtitle,
            thumbnailURL: track.thumbnailURL,
            albumId: track.albumId,
            artistId: track.artistId,
            elapsed: elapsed,
            duration: duration,
            savedAt: Date()
        )
        if let data = try? JSONEncoder().encode(snap) {
            UserDefaults.standard.set(data, forKey: Self.lastSessionKey)
        }
    }

    private func restoreLastSession() {
        guard let data = UserDefaults.standard.data(forKey: Self.lastSessionKey),
              let snap = try? JSONDecoder().decode(LastSession.self, from: data) else {
            return
        }
        // Don't restore if the session is older than 7 days — at that
        // point the user has likely moved on, and showing a stale
        // mini-bar on launch is more confusing than helpful.
        if Date().timeIntervalSince(snap.savedAt) > 7 * 24 * 60 * 60 { return }
        currentTrack = Track(
            videoId: snap.videoId,
            title: snap.title,
            subtitle: snap.subtitle,
            thumbnailURL: snap.thumbnailURL,
            duration: snap.duration,
            albumId: snap.albumId,
            artistId: snap.artistId
        )
        elapsed = snap.elapsed
        duration = snap.duration
        // Stash the resume target — consumed by the first user play.
        if snap.elapsed > 1 {
            pendingResume = (videoId: snap.videoId, elapsed: snap.elapsed)
        }
    }

    /// Repeat modes. `.off` is YT Music's natural autoplay; `.one`
    /// loops the current `<video>` source via the browser's native
    /// loop attribute. Repeat-all isn't shipped yet — it would
    /// require intercepting end-of-queue and racing the page's
    /// autoplay, which is fragile. Track for v1.1.
    enum RepeatMode: String, Sendable {
        case off, one
    }
    private(set) var repeatMode: RepeatMode = .off
    private(set) var shuffleEnabled: Bool = false

    /// Cycle through repeat modes. Two states for now (off → one →
    /// off); a future `.all` slot will splice in here.
    func toggleRepeat() async {
        let next: RepeatMode = (repeatMode == .off) ? .one : .off
        repeatMode = next
        UserDefaults.standard.set(next.rawValue, forKey: Self.repeatKey)
        await eval("window.musicBridge.setRepeatLoop(\(next == .one ? "true" : "false"))")
    }

    /// Toggle shuffle. Affects only what `next()` does — see the
    /// implementation note there. We don't permute `upNext` itself
    /// because the row order on screen is part of the user's mental
    /// model ("I see this is coming up next"); shuffling it would
    /// confuse more than help.
    func toggleShuffle() {
        shuffleEnabled.toggle()
        UserDefaults.standard.set(shuffleEnabled, forKey: Self.shuffleKey)
    }

    struct Track: Hashable {
        let videoId: String
        let title: String
        let subtitle: String
        let thumbnailURL: URL?
        let duration: Double
        /// Album browseId, when known. Drives "Go to album" from the
        /// now-playing menu. Sourced from the MediaItem the user clicked,
        /// or backfilled from the `/next` queue row that matches videoId.
        var albumId: String? = nil
        /// Artist browseId, when known. Drives "Go to artist".
        var artistId: String? = nil
    }

    // MARK: - Commands

    /// YT Music's auto-radio playlist prefix. Tacked onto the watch URL
    /// when a song is played with no other playlist context — the browser
    /// does the same: clicking a single tile navigates to
    /// `?v=<id>&list=RDAMVM<id>`, which triggers a server-generated radio
    /// queue (25-50 related tracks that auto-extends). Without it, /next
    /// returns just the current track and Up Next sits empty.
    private static func radioPlaylistId(for videoId: String) -> String {
        "RDAMVM" + videoId
    }

    func play(videoId: String) async {
        let radio = Self.radioPlaylistId(for: videoId)
        currentPlaylistId = radio
        await navigate(watchURL(videoId: videoId, playlistId: radio))
    }

    /// Click-to-play with an item we already have full metadata for (search
    /// rows, home carousels, library lists). Pre-populates `currentTrack`
    /// so the mini-bar shows the right title/artist/artwork *immediately*,
    /// before the WebView even starts loading. Without this, anonymous YT
    /// Music plays 2-3 video ads first and the mini-bar flickers through
    /// each ad's metadata before settling on the real song.
    func play(item: MediaItem) async {
        currentTrack = Track(
            videoId: item.id,
            title: item.title,
            subtitle: item.subtitle,
            thumbnailURL: item.thumbnailURL,
            duration: 0,
            albumId: item.albumId,
            artistId: item.artistId
        )
        // Reset & pre-fetch surrounding context (queue + lyrics/related ids).
        // Use the auto-radio playlist (RDAMVM<videoId>) so /next returns a
        // proper YT-Music-style radio queue instead of just the current
        // track. play(videoId:) below sets currentPlaylistId; we mirror it
        // here so the queue refresh has the right context immediately.
        //
        // BUG-1 fix: a wholesale `queue.clearQueue()` here would drop
        // any user-queued items (Play next / Add to queue) the user
        // had pending against the *previous* track. Filter the clear
        // so user-tagged items survive into refreshNextQueueAndIds,
        // where they get merged into the head of the fresh /next
        // response. The just-promoted track itself is excluded — it
        // already became currentTrack, no need to leave a duplicate
        // in upNext.
        let preservedUserQueued = upNext.filter { entry in
            userQueuedIds.contains(entry.id) && entry.id != item.id
        }
        queue.replaceQueue(preservedUserQueued)
        related = []
        lyrics = nil
        // Tune chips are per-watch-context. Clear them so the popover
        // doesn't briefly show the previous track's chips while the new
        // /next is in flight.
        availableChips = []
        selectedChipId = nil
        // Reset progress so the scrubber starts at 0 instead of carrying
        // over the previous track's elapsed/duration. The JS bridge will
        // populate fresh values once the new media loads.
        elapsed = 0
        duration = 0
        lastTrackChangeAt = Date()
        let radio = Self.radioPlaylistId(for: item.id)
        currentPlaylistId = radio
        userClickedAt = Date()
        refreshNextQueueAndIds(forVideoId: item.id, playlistId: radio)
        onUpdate?()
        await play(videoId: item.id)
    }

    /// Last time `play(item:)` ran. Used to gate when we accept JS-side
    /// metadata updates for the *same* videoId — within `userClickGraceSeconds`
    /// we ignore them (catches pre-roll ads), after that window we trust
    /// them (catches autoplay advances where the URL videoId stays put).
    @ObservationIgnored private var userClickedAt: Date = .distantPast
    private static let userClickGraceSeconds: TimeInterval = 30
    private static let historyCap = 50

    /// Last time we transitioned to a NEW track (different videoId, post-
    /// click-grace). Used to filter out stale `progress` events from the
    /// just-ended track while YT Music's SPA swaps the `<video>` element's
    /// media source. Without this, the elapsed/duration UI briefly shows
    /// the previous track's tail end (e.g. "6:43 / 8:42" on a fresh song).
    @ObservationIgnored private var lastTrackChangeAt: Date = .distantPast
    /// Ignore progress events for this long after a track change. Tuned
    /// against the typical 500ms `timeupdate` cadence; the JS bridge will
    /// report fresh values on the next tick after YT loads the new media.
    private static let trackChangeGraceSeconds: TimeInterval = 1.2

    private func archiveCurrent() {
        guard let old = currentTrack else {
            Log.bridge.debug("archiveCurrent: no current track to archive")
            return
        }
        let item = MediaItem(
            id: old.videoId, kind: .song,
            title: old.title, subtitle: old.subtitle,
            thumbnailURL: old.thumbnailURL,
            albumId: old.albumId, artistId: old.artistId
        )
        // QueueManager handles dedup-against-tail + cap + persist
        // synchronously, so we don't have to.
        let prevSize = queue.playedHistory.count
        queue.archive(item)
        let newSize = queue.playedHistory.count
        if newSize == prevSize {
            Log.bridge.debug("archiveCurrent: skip dup last=\(item.title, privacy: .public) (\(item.id, privacy: .public))")
        } else {
            Log.bridge.debug("archiveCurrent: appended \(item.title, privacy: .public) (\(item.id, privacy: .public)); historySize=\(newSize)")
        }
    }

    /// Pull /next for the given videoId — populates `upNext` and stashes
    /// browse IDs for lyrics + related which are loaded on demand.
    /// Pass `playlistId` when known so /next returns the playlist's track
    /// list instead of generic radio suggestions.
    private func refreshNextQueueAndIds(forVideoId id: String, playlistId: String?) {
        // Cancel-and-replace: clicking 5 tracks in 2 seconds shouldn't fan out
        // 5 concurrent `/next` requests where the last-to-complete wins.
        nextQueueTask?.cancel()
        nextQueueTask = Task { [innerTube, weak self] in
            guard let response = try? await innerTube.nextQueue(videoId: id, playlistId: playlistId) else {
                Log.bridge.debug("refreshNextQueue: nextQueue threw or returned nil for v=\(id, privacy: .public)")
                return
            }
            // Bail if we were superseded by a newer click while awaiting.
            if Task.isCancelled { return }
            Log.bridge.debug("refreshNextQueue v=\(id, privacy: .public) plid=\(playlistId ?? "nil", privacy: .public) → queue=\(response.queue.count) likeStatus=\(String(describing: response.likeStatus), privacy: .public)")

            // /next sometimes returns just the currently-playing track in
            // its queue (especially right after navigation, before the
            // page populates the full panel). When we know we're inside
            // a playlist (including the auto-radio "RDAMVM" prefix that
            // play(item:) attaches for single-song clicks), fall back to
            // fetching the playlist's own tracklist via /browse so Up
            // Next isn't empty. (`fetched` rather than `queue` to avoid
            // shadowing the QueueManager property name.)
            var fetched = response.queue
            if fetched.count <= 1, let plid = playlistId, !plid.isEmpty {
                if let detail = try? await innerTube.playlistDetail(playlistId: plid) {
                    if Task.isCancelled { return }
                    Log.bridge.debug("refreshNextQueue: fallback to playlistDetail \(plid, privacy: .public) → \(detail.tracks.count) tracks")
                    fetched = detail.tracks
                }
            }

            if Task.isCancelled { return }
            await MainActor.run {
                guard let self, !Task.isCancelled else { return }
                // BUG-1 fix: preserve any user-queued tracks across
                // the wholesale replace. Items the user explicitly
                // added via "Play next" / "Add to queue" (tagged in
                // userQueuedIds) get spliced into the head of the
                // new server queue, so a routine /next refresh from
                // autoplay doesn't drop them. Order among preserved
                // items is the order they currently appear in upNext
                // — which matches the order the user added them
                // (playNext inserts at head, addToEnd appends).
                let curId = self.currentTrack?.videoId
                let preserved = self.upNext.filter { item in
                    self.userQueuedIds.contains(item.id) && item.id != curId
                }
                let preservedIds = Set(preserved.map(\.id))
                // De-dupe: if /next happened to surface a track we're
                // about to splice back, take our copy (preserves the
                // user-queued tag) and drop the server's duplicate.
                let merged = preserved + fetched.filter { !preservedIds.contains($0.id) }
                // Drop blocked-artist tracks before they reach the
                // UI. The currentTrack itself is never filtered —
                // the user is already listening to it; pulling it
                // out of upNext just causes the "what's playing"
                // strip to misalign.
                let visible = merged.filter { item in
                    item.id == curId || !self.shouldBlock(item)
                }
                self.queue.replaceQueue(visible)
                // Backfill the current track's album/artist IDs if /next
                // returned them and the track we have on screen is missing
                // them — common when the user clicks a carousel tile whose
                // parent shelf didn't carry album navigation.
                if let cur = self.currentTrack,
                   (cur.albumId == nil || cur.artistId == nil),
                   let match = fetched.first(where: { $0.id == cur.videoId }),
                   (match.albumId != nil || match.artistId != nil) {
                    self.currentTrack = Track(
                        videoId: cur.videoId,
                        title: cur.title,
                        subtitle: cur.subtitle,
                        thumbnailURL: cur.thumbnailURL,
                        duration: cur.duration,
                        albumId: cur.albumId ?? match.albumId,
                        artistId: cur.artistId ?? match.artistId
                    )
                }
                self.lyricsBrowseId = response.lyricsBrowseId
                self.relatedBrowseId = response.relatedBrowseId
                self.liked = response.likeStatus == .like
                self.availableChips = response.chips
                // Sync selected chip with whichever YT marked active —
                // chips are per-watch-context, so old selections from a
                // previous track don't carry forward.
                self.selectedChipId = response.chips.first(where: \.isSelected)?.id
                // Invalidate previously cached tab content for the old track.
                self.lyrics = nil
                self.lyricsLines = []
                self.lyricsTimed = false
                self.related = []
            }
        }
    }

    /// Apply a Tune chip — re-issues `/next` with the chip's (playlistId,
    /// params) and replaces `upNext` with the resulting queue. The
    /// currently-playing track keeps playing (we don't navigate the
    /// WebView), only the suggested-next queue changes.
    func applyChip(_ chip: InnerTubeClient.QueueChip) {
        guard let videoId = currentTrack?.videoId else { return }
        // Optimistically reflect the selection in the UI before the
        // network round-trip completes.
        selectedChipId = chip.id
        nextQueueTask?.cancel()
        nextQueueTask = Task { [innerTube, weak self] in
            guard let response = try? await innerTube.nextQueue(videoId: videoId, playlistId: nil, chip: chip) else {
                Log.bridge.debug("applyChip: nextQueue threw for chip=\(chip.id, privacy: .public)")
                return
            }
            if Task.isCancelled { return }
            Log.bridge.debug("applyChip \(chip.id, privacy: .public) → queue=\(response.queue.count)")
            await MainActor.run {
                guard let self, !Task.isCancelled else { return }
                // Tune-chip selection reshapes the radio recommendations
                // but user intent on "Play next" / "Add to queue" still
                // overrides — same preservation logic as
                // refreshNextQueueAndIds. The user explicitly said
                // "play X next"; switching chips shouldn't drop X.
                let curId = self.currentTrack?.videoId
                let preserved = self.upNext.filter { item in
                    self.userQueuedIds.contains(item.id) && item.id != curId
                }
                let preservedIds = Set(preserved.map(\.id))
                let merged = preserved + response.queue.filter { !preservedIds.contains($0.id) }
                let visible = merged.filter { item in
                    item.id == curId || !self.shouldBlock(item)
                }
                self.queue.replaceQueue(visible)
                // Refresh chip set: YT returns the same cloud back, but
                // with a different chip's `isSelected=true`.
                if !response.chips.isEmpty {
                    self.availableChips = response.chips
                }
            }
        }
    }

    /// Toggle the like state on the current track. Optimistically updates
    /// `liked` so the UI feels immediate; rolls back on InnerTube error.
    func toggleLike() async {
        guard let track = currentTrack else { return }
        let wasLiked = liked
        liked.toggle()
        do {
            if wasLiked {
                try await innerTube.removeLike(videoId: track.videoId)
            } else {
                try await innerTube.like(videoId: track.videoId)
            }
        } catch {
            // Roll back on failure (e.g. needsReauth when not signed in).
            liked = wasLiked
        }
    }

    /// Lazy-load lyrics on tab open. Sets `lyricsLoading` while in flight.
    /// Populates either `lyricsLines` (with `lyricsTimed=true`) for synced
    /// lyrics or just the plain `lyrics` text fallback.
    func loadLyricsIfNeeded() {
        guard lyrics == nil, lyricsLines.isEmpty, !lyricsLoading, let id = lyricsBrowseId else { return }
        lyricsLoading = true
        Task { [innerTube, weak self] in
            let result = (try? await innerTube.lyrics(browseId: id)) ?? nil
            await MainActor.run {
                guard let self else { return }
                if let result {
                    self.lyricsLines = result.lines
                    self.lyricsTimed = result.timed
                    self.lyrics = result.lines.map(\.text).joined(separator: "\n")
                } else {
                    self.lyrics = "Lyrics not available."
                }
                self.lyricsLoading = false
            }
        }
    }

    /// Lazy-load related songs on tab open.
    func loadRelatedIfNeeded() {
        guard related.isEmpty, let id = relatedBrowseId else { return }
        Task { [innerTube, weak self] in
            let items = (try? await innerTube.related(browseId: id)) ?? []
            await MainActor.run {
                guard let self else { return }
                self.related = items.filter { !self.shouldBlock($0) }
            }
        }
    }

    /// Plays a YT Music playlist. Tries direct /watch?list= first (works
    /// for proper PL... / OLAK5uy_... ids); on failure falls back to the
    /// browseId resolver path which will fetch the playlist's first track
    /// and navigate /watch?v=&list= explicitly.
    func playPlaylist(id: String) async {
        // Strip a "VL" prefix if it's still attached — VL ids are browse
        // ids (used to fetch playlist details), not playable ids.
        let cleaned = id.hasPrefix("VL") ? String(id.dropFirst(2)) : id
        Log.resolver.debug("playPlaylist id=\(id, privacy: .public) cleaned=\(cleaned, privacy: .public)")
        await navigate(watchURL(videoId: nil, playlistId: cleaned))
    }

    func playAlbum(id: String)    async { await playByResolvingBrowseId(id) }
    func playPodcast(id: String)  async { await playByResolvingBrowseId(id) }
    func playArtistRadio(id: String) async { await playByResolvingBrowseId(id) }

    /// Hand off browseId resolution to `BrowseIdResolver` and navigate
    /// the WKWebView to the resolved destination. The resolver owns
    /// the resolution policy (primary path / VL strip / browse-page
    /// fallback); this method owns the navigation side only.
    private func playByResolvingBrowseId(_ browseId: String) async {
        let destination = await BrowseIdResolver.resolve(browseId, via: innerTube)
        switch destination {
        case let .watch(videoId, playlistId):
            let url = watchURL(videoId: videoId, playlistId: playlistId)
            Log.resolver.debug("\(browseId, privacy: .public) → v=\(videoId ?? "nil", privacy: .public) list=\(playlistId ?? "nil", privacy: .public) → \(url, privacy: .public)")
            await navigate(url)
        case let .directPlaylist(plid):
            Log.resolver.debug("\(browseId, privacy: .public) → resolver failed; falling back to direct playlist plid=\(plid, privacy: .public)")
            await navigate(watchURL(videoId: nil, playlistId: plid))
        case let .browsePage(url):
            Log.resolver.debug("\(browseId, privacy: .public) → no playable endpoint and no fallback; navigating to browse page")
            await navigate(url.absoluteString)
        }
    }

    private func watchURL(videoId: String?, playlistId: String?) -> String {
        var components = URLComponents(string: "https://music.youtube.com/watch")!
        var items: [URLQueryItem] = []
        if let videoId, !videoId.isEmpty { items.append(URLQueryItem(name: "v", value: videoId)) }
        if let playlistId, !playlistId.isEmpty { items.append(URLQueryItem(name: "list", value: playlistId)) }
        components.queryItems = items.isEmpty ? nil : items
        return components.url?.absoluteString ?? "https://music.youtube.com/"
    }

    private func navigate(_ url: String) async {
        await eval("window.musicBridge.navigate(\(url.jsonQuoted))")
    }

    func togglePlay() async {
        // Consume a pending resume from the restored session: the
        // WebView hasn't navigated to the saved track yet, so a plain
        // togglePlay would target an empty <video>. Instead navigate
        // to the track and seek to the saved position once playback
        // begins.
        if let resume = pendingResume {
            pendingResume = nil
            let savedElapsed = resume.elapsed
            await play(videoId: resume.videoId)
            // Seek after a brief delay to let the new media source
            // load — the JS bridge's seek() targets the current
            // <video>'s currentTime, which is 0 until the media is
            // ready. 1.5s is empirically enough for warm WebView; if
            // the load is slow the seek lands at 0 which is the same
            // as "play from start" (acceptable fallback).
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if duration > 0, savedElapsed < duration {
                await seek(to: savedElapsed / duration)
            }
            return
        }
        await eval("window.musicBridge.togglePlay()")
    }
    /// Advance to the next track. With shuffle ON we pick a random
    /// upcoming item and play it directly via `play(item:)` — that
    /// gives the user-driven "Next" press a randomized order even
    /// though the visible Up Next list stays in its server order.
    /// (We deliberately don't permute the on-screen list — see
    /// `toggleShuffle` for the rationale.)
    /// With shuffle OFF, fall through to the page's `.next-button`
    /// click as before.
    func next() async {
        // Priority 1: a user-queued "Play next" / "Add to queue"
        // item always wins. This is the same path autoplay-on-ended
        // uses; consuming through user-skip just preempts it.
        if await advanceToUserQueuedIfAny() { return }
        if shuffleEnabled, !upNext.isEmpty {
            let currentId = currentTrack?.videoId
            let candidates = upNext.filter { $0.id != currentId }
            if let pick = candidates.randomElement() {
                await play(item: pick)
                return
            }
        }
        await eval("window.musicBridge.next()")
    }
    func previous()   async { await eval("window.musicBridge.previous()") }
    func seek(to fraction: Double) async {
        await eval("window.musicBridge.seek(\(fraction))")
    }

    /// Playback rate (0.5x – 2.0x). Useful for podcasts; works for music
    /// too. Persists across track changes within the same WebView session.
    private(set) var playbackRate: Double = 1.0
    func setPlaybackRate(_ rate: Double) async {
        playbackRate = rate
        UserDefaults.standard.set(rate, forKey: Self.rateKey)
        await eval("window.musicBridge.setPlaybackRate(\(rate))")
    }

    /// Skip ±N seconds — podcast-style transport. Negative skips back.
    func skip(by seconds: Double) async {
        await eval("window.musicBridge.skipBy(\(seconds))")
    }

    /// Add the currently-playing track to a user-owned playlist. Caller
    /// supplies the target playlistId. Requires sign-in (SAPISID cookie).
    func addCurrentTrackToPlaylist(playlistId: String) async throws {
        guard let videoId = currentTrack?.videoId else { return }
        try await innerTube.addToPlaylist(videoId: videoId, playlistId: playlistId)
    }

    /// Create a fresh user-owned playlist and add the currently-playing
    /// track to it. Returns the new playlistId on success.
    @discardableResult
    func createPlaylistWithCurrentTrack(title: String) async throws -> String? {
        guard let videoId = currentTrack?.videoId else { return nil }
        let plid = try await innerTube.createPlaylist(title: title)
        if let plid {
            try await innerTube.addToPlaylist(videoId: videoId, playlistId: plid)
        }
        return plid
    }

    /// "Save queue as playlist" — YT Music's Up-Next save action.
    /// Creates a fresh private playlist and adds every track currently
    /// in `upNext` (in order). Adds are sequential because YT
    /// Music's editPlaylist ACTION_ADD_VIDEO doesn't accept a batch
    /// list — one round-trip per track. Returns the new playlistId.
    /// Errors after the playlist is created are non-fatal (the
    /// playlist exists with whatever subset got added before the
    /// error); we surface the first error to the caller.
    @discardableResult
    func savePlaylistFromQueue(title: String) async throws -> String? {
        // Snapshot the queue so a /next refresh that lands during
        // this method doesn't change the membership we're saving.
        let snapshot = upNext
        guard !snapshot.isEmpty else { return nil }
        guard let plid = try await innerTube.createPlaylist(title: title) else {
            return nil
        }
        var firstError: Error?
        for track in snapshot {
            do {
                try await innerTube.addToPlaylist(videoId: track.id, playlistId: plid)
            } catch {
                if firstError == nil { firstError = error }
                Log.bridge.error("savePlaylistFromQueue: add failed for \(track.id, privacy: .public): \(error.localizedDescription, privacy: .public)")
                // Keep going — partial-saved is better than zero-saved.
            }
        }
        if let firstError { throw firstError }
        return plid
    }

    /// Insert `item` at the top of the local Up Next list — YT
    /// Music's "Play next". Tagged in `userQueuedIds` so when the
    /// current track ends the `ended` event handler navigates to it
    /// instead of letting YT Music's natural autoplay pick something
    /// else. (Earlier versions of this method documented a local-only
    /// caveat: the WebView's server queue wasn't mutated, so YT's
    /// autoplay won and the user-queued track was silently skipped.
    /// The autoplay-interception path above is the fix for that.)
    func playNext(item: MediaItem) {
        queue.playNext(item)
        userQueuedIds.insert(item.id)
        Task { await syncPendingNextURL() }
    }

    /// Append `item` to the bottom of the local Up Next list — YT
    /// Music's "Add to queue". Same autoplay-interception semantics
    /// as `playNext` — when the current track ends, the head of
    /// `userQueuedIds` (which includes everything the user has added)
    /// gets played; the order in `upNext` is the play order.
    func addToQueueEnd(item: MediaItem) {
        queue.addToEnd(item)
        userQueuedIds.insert(item.id)
        Task { await syncPendingNextURL() }
    }

    /// Advance to the head user-queued item if one exists. Returns
    /// `true` if it navigated, `false` if no user-queued item is
    /// queued (caller falls through to the natural autoplay path).
    /// Consumes the id from the tracking set so a single click of
    /// "Play next" only takes priority once.
    @discardableResult
    private func advanceToUserQueuedIfAny() async -> Bool {
        // Walk upNext in order; the first item whose id is in
        // userQueuedIds is "the user's explicit next". Skipping
        // current item is implicit — the current track is removed
        // from upNext by the queue's own filter elsewhere.
        for item in upNext {
            if userQueuedIds.contains(item.id) {
                userQueuedIds.remove(item.id)
                await syncPendingNextURL()
                await play(item: item)
                return true
            }
        }
        return false
    }

    /// Push the head user-queued track's watch URL into the page's
    /// `window.__riffPendingNextUrl` so the JS-side ended listener
    /// can navigate synchronously when YT Music's autoplay would
    /// otherwise win the race. Called every time `userQueuedIds`
    /// changes (insert / remove / advanced-by-end / consumed-by-skip).
    /// Pushes an empty string when nothing is pending, which the JS
    /// treats as "clear" and falls back to YT's natural autoplay.
    private func syncPendingNextURL() async {
        let curId = currentTrack?.videoId
        let head = upNext.first { userQueuedIds.contains($0.id) && $0.id != curId }
        let url: String
        if let head {
            // Use the same auto-radio playlist scheme as play(item:) so
            // /next on the new track produces a proper radio queue
            // instead of just the track itself.
            let radio = Self.radioPlaylistId(for: head.id)
            url = watchURL(videoId: head.id, playlistId: radio)
        } else {
            url = ""  // clear
        }
        Log.bridge.debug("syncPendingNextURL → \(url, privacy: .public)")
        await eval("window.musicBridge.setPendingNextURL(\(url.jsonQuoted))")
    }

    /// Explicitly start the auto-radio for `item` — same flow as
    /// `play(item:)` since RDAMVM is our default. Kept as a separate
    /// entry point so context-menu code reads naturally and so we can
    /// later differentiate "play in album context" vs "start radio"
    /// without touching every call site.
    func startRadio(for item: MediaItem) async {
        await play(item: item)
    }

    /// Remove a track from the local Up Next list. Doesn't (yet) sync the
    /// removal to YT Music's server-side queue — InnerTube's queue-mutation
    /// endpoint isn't documented for our client; the WebView's queue still
    /// holds the original list. Treat this as a local-UX hint until we
    /// implement a JS bridge into the page's queue API.
    func removeFromQueue(videoId: String) async {
        queue.remove(videoId: videoId)
        // If the user removed a row they had earlier "Play next"'d,
        // drop it from the priority set so a later /next refresh that
        // reintroduces the same videoId doesn't resurrect the priority.
        userQueuedIds.remove(videoId)
        await syncPendingNextURL()
    }

    /// Local-only reorder. Same caveat as removeFromQueue: this only
    /// affects the Up Next list Riff displays, not the WebView's actual
    /// playback queue. Useful for users who want to inspect / curate
    /// what's coming up.
    func moveInQueue(videoId: String, by offset: Int) {
        queue.move(videoId: videoId, by: offset)
    }

    // MARK: - Sleep timer

    /// Seconds remaining before the sleep timer fires, or nil when no
    /// timer is set. Updated once per second by `sleepTimerTask` so
    /// the UI can display a live countdown.
    private(set) var sleepTimerRemaining: TimeInterval? = nil

    @ObservationIgnored private var sleepTimerTask: Task<Void, Never>?

    /// Arm a sleep timer that pauses playback after `minutes`. Replaces
    /// any existing timer. Intentionally not persisted across launches
    /// — sleep timers are session-scoped by every other player's
    /// convention (Apple Music, YT Music mobile, Spotify).
    func setSleepTimer(minutes: Int) {
        cancelSleepTimer()
        let totalSeconds = TimeInterval(minutes * 60)
        sleepTimerRemaining = totalSeconds
        let startedAt = Date()
        sleepTimerTask = Task { [weak self] in
            // Tick once per second so the UI shows live countdown.
            // Loop instead of one big sleep so cancellation is prompt.
            while !Task.isCancelled {
                let elapsed = Date().timeIntervalSince(startedAt)
                let remaining = max(0, totalSeconds - elapsed)
                await MainActor.run { self?.sleepTimerRemaining = remaining }
                if remaining <= 0 { break }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                if self.isPlaying {
                    Task { await self.togglePlay() }
                }
                self.sleepTimerRemaining = nil
                self.sleepTimerTask = nil
            }
        }
    }

    func cancelSleepTimer() {
        sleepTimerTask?.cancel()
        sleepTimerTask = nil
        sleepTimerRemaining = nil
    }

    /// Volume 0.0...1.0. Persisted across track changes within the session
    /// (defaults to 1.0 on launch, the WebView's natural state).
    private(set) var volume: Double = 1.0
    func setVolume(_ level: Double) async {
        let clamped = max(0.0, min(1.0, level))
        volume = clamped
        UserDefaults.standard.set(clamped, forKey: Self.volumeKey)
        await eval("window.musicBridge.setVolume(\(clamped))")
    }

    /// Per-call timeout for JS evaluation. A hung WKWebView (e.g. an
    /// unresponsive page) shouldn't leave our awaiting Task pending forever
    /// — that's how UI commands silently stop working without an error to
    /// surface. 5s is generous: a healthy bridge resolves in <50ms.
    private static let jsEvalTimeoutSeconds: UInt64 = 5

    private func eval(_ js: String) async {
        guard bridgeReady else {
            pendingCommands.append(js)
            return
        }
        await evalWithTimeout(js: js)
    }

    private func flushPending() async {
        let cmds = pendingCommands
        pendingCommands.removeAll()
        for cmd in cmds {
            await evalWithTimeout(js: cmd)
        }
    }

    /// Race the JS eval against a sleep — whichever wins, the other is
    /// cancelled. We don't surface the timeout as an error (callers `try?`'d
    /// the original) but we log it so a hung bridge is debuggable.
    private func evalWithTimeout(js: String) async {
        let webView = webBridge.webView
        let timeoutNs = Self.jsEvalTimeoutSeconds * 1_000_000_000
        let evalTask = Task { @MainActor in
            _ = try? await webView.evaluateJavaScript(js)
        }
        let timeoutTask = Task {
            try? await Task.sleep(nanoseconds: timeoutNs)
        }
        // Whichever completes first wins; cancel the loser.
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { await evalTask.value; return true }
            group.addTask { await timeoutTask.value; return false }
            if let first = await group.next() {
                if first == false {
                    Log.bridge.debug("eval timed out after \(Self.jsEvalTimeoutSeconds)s; js prefix=\(js.prefix(80), privacy: .public)")
                    evalTask.cancel()
                } else {
                    timeoutTask.cancel()
                }
                group.cancelAll()
            }
        }
    }

    // MARK: - Event handling

    private func handle(_ event: HiddenPlayerWebView.BridgeEvent) {
        switch event {
        case .ready:
            if !bridgeReady {
                bridgeReady = true
                Task { [weak self] in
                    guard let self else { return }
                    await self.flushPending()
                    // Re-apply persisted prefs to the freshly-loaded page.
                    if self.volume != 1.0 {
                        await self.evalWithTimeout(js: "window.musicBridge.setVolume(\(self.volume))")
                    }
                    if self.playbackRate != 1.0 {
                        await self.evalWithTimeout(js: "window.musicBridge.setPlaybackRate(\(self.playbackRate))")
                    }
                    // Re-arm the <video> loop attribute on every page
                    // load — YT Music's SPA reuses the same element
                    // across navigations but doesn't preserve our
                    // overrides. Cheap and idempotent.
                    if self.repeatMode == .one {
                        await self.evalWithTimeout(js: "window.musicBridge.setRepeatLoop(true)")
                    }
                }
            }
        case .stateChanged(let playing):
            isPlaying = playing
        case .ended:
            // Track reached end-of-stream. If the user explicitly
            // queued a track via "Play next" / "Add to queue", play
            // it now. The race against YT Music's natural autoplay
            // (which also fires on the same video.ended) is now won
            // proactively in the JS bridge — see setPendingNextURL
            // below; this Swift-side handler is a belt-and-braces
            // fallback for the case where the JS interception didn't
            // fire (e.g. user clicked Play next within a few ms of
            // end-of-stream and we didn't have time to push the URL).
            Log.bridge.debug(".ended fired; userQueuedIds=\(self.userQueuedIds, privacy: .public) upNextHeadIds=\(self.upNext.prefix(3).map(\.id), privacy: .public)")
            Task { [weak self] in
                guard let self else { return }
                let advanced = await self.advanceToUserQueuedIfAny()
                Log.bridge.debug(".ended → advanceToUserQueuedIfAny returned \(advanced, privacy: .public)")
            }
        case .progress(let t, let d):
            // Filter stale events that arrive in the window right after a
            // track change. YT Music's SPA can keep firing `timeupdate`
            // events with the previous track's currentTime/duration for
            // ~500-1000ms before the new media source loads — without this
            // guard the scrubber jumps to the previous track's tail.
            let inGrace = Date().timeIntervalSince(lastTrackChangeAt) < Self.trackChangeGraceSeconds
            if inGrace, t > 5 {
                return
            }
            elapsed = t
            duration = d
            // Snapshot for "Continue where you left off" — rate-limited
            // to one write per `snapshotEverySeconds` so we're not
            // writing UserDefaults every 500 ms.
            snapshotSessionIfDue()
        case .trackChanged(let id, let playlistId, let title, let artist, let art):
            // If this is the user-queued track playing, drop the
            // priority tag now — the user's intent has been honored
            // and we don't want it to re-fire on a future round-trip
            // (e.g. /next reintroducing the same id back into upNext).
            userQueuedIds.remove(id)
            // Always resync the pending URL after a track change:
            // page navigations reset window.__riffPendingNextUrl
            // (new page = new window), so we have to push the next
            // user-queued URL on every fresh load. Cheap — one JS
            // eval that's effectively a no-op when nothing's queued.
            Task { await syncPendingNextURL() }
            // Time-gated dedupe. Within 30s of a play(item:), we trust the
            // user-clicked metadata over JS-side reports for the same
            // videoId — catches pre-roll ads (which all happen in the
            // first ~10s). After the grace window, we trust JS reports —
            // catches autoplay advances where YT Music's SPA may keep the
            // URL videoId stable but advance mediaSession.metadata.
            let sameVideoId = currentTrack?.videoId == id
            let titleChanged = currentTrack?.title != title
            let withinClickGrace = Date().timeIntervalSince(userClickedAt) < Self.userClickGraceSeconds

            if sameVideoId && !titleChanged {
                // Identical event (re-poll). Just refresh duration if it's
                // newly available.
                if duration > 0, let existing = currentTrack, existing.duration == 0 {
                    currentTrack = Track(
                        videoId: existing.videoId,
                        title: existing.title,
                        subtitle: existing.subtitle,
                        thumbnailURL: existing.thumbnailURL,
                        duration: duration,
                        albumId: existing.albumId,
                        artistId: existing.artistId
                    )
                }
            } else if sameVideoId && withinClickGrace {
                // Pre-roll ad / startup churn. Keep the user's clicked
                // metadata; just absorb duration if we got it.
                if duration > 0, let existing = currentTrack, existing.duration == 0 {
                    currentTrack = Track(
                        videoId: existing.videoId,
                        title: existing.title,
                        subtitle: existing.subtitle,
                        thumbnailURL: existing.thumbnailURL,
                        duration: duration,
                        albumId: existing.albumId,
                        artistId: existing.artistId
                    )
                }
            } else {
                // New track — different videoId, OR same videoId but
                // outside the click-grace window (autoplay advance).
                // Archive the previous track to history before replacing.
                archiveCurrent()
                // Reset progress to 0 immediately. Stale `<video>`
                // currentTime/duration from the previous track will
                // bleed through `timeupdate` events for up to ~1s while
                // YT Music's SPA swaps media sources; the grace window
                // checked in the .progress branch suppresses those.
                elapsed = 0
                duration = 0
                lastTrackChangeAt = Date()
                // JS bridge doesn't surface album/artist IDs (they're not
                // on `<video>` or mediaSession.metadata). Backfill from
                // the queue if it has them — typical when autoplaying
                // through an Up Next that came back from /next with
                // longBylineText nav endpoints intact.
                let queueMatch = upNext.first(where: { $0.id == id })
                currentTrack = Track(
                    videoId: id,
                    title: title,
                    subtitle: artist,
                    thumbnailURL: art,
                    duration: 0,
                    albumId: queueMatch?.albumId,
                    artistId: queueMatch?.artistId
                )
                currentPlaylistId = playlistId
                userClickedAt = .distantPast  // stop being protective
                refreshNextQueueAndIds(forVideoId: id, playlistId: playlistId)
                // New track → snapshot now (rather than waiting for
                // the rate-limited progress snapshot) so a quick
                // skip-then-quit still captures the latest track.
                snapshotSession()
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
