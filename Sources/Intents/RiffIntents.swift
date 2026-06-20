import AppIntents
import Foundation

// MARK: - Shared error

// Errors surfaced to the user from any Riff intent. AppIntents renders
// `localizedStringResource` in the Shortcuts UI and Siri dialog, so the
// associated value carries the human-readable message.
enum IntentError: Error, CustomLocalizedStringResourceConvertible {
    case noResults(String)
    case noEnvironment

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .noResults(let msg): return LocalizedStringResource(stringLiteral: msg)
        case .noEnvironment:      return "Riff isn't ready yet — open the app and try again."
        }
    }
}

// MARK: - AppEnvironment lookup helper

// Reach the live AppEnvironment from an intent body. Intents below are
// marked @MainActor so this is safe to call. Throws when the app hasn't
// finished initializing (rare — intents only fire after the host
// process is running).
@MainActor
private func liveEnvironment() throws -> AppEnvironment {
    guard let env = AppEnvironment.current else {
        throw IntentError.noEnvironment
    }
    return env
}

// MARK: - PlayTrackIntent

// Play "<query>" on Riff — searches songs and plays the first result.
struct PlayTrackIntent: AppIntent {
    static let title: LocalizedStringResource = "Play Song"
    static let description = IntentDescription(
        "Search YouTube Music and play the first matching song in Riff.",
        categoryName: "Playback"
    )
    // Bring Riff to the foreground when invoked from Spotlight / Siri.
    static let openAppWhenRun: Bool = true

    // @Parameter overload-matching is fragile — combining `title:` +
    // `description:` for a plain String binds the AppEntity/AppEnum
    // overload (which requires entity types). The minimal `title:`-only
    // form binds the String overload. The user-facing description was
    // never user-visible in Spotlight anyway — it surfaces in the
    // Shortcuts editor only.
    @Parameter(title: "Song")
    var query: String

    static var parameterSummary: some ParameterSummary {
        Summary("Play \(\.$query) on Riff")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let env = try liveEnvironment()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw IntentError.noResults("Could not find that on Riff")
        }
        let results = (try? await env.innerTube.search(query: trimmed, filter: .songs)) ?? []
        guard let first = results.first(where: { $0.kind == .song }) ?? results.first else {
            throw IntentError.noResults("Could not find that on Riff")
        }
        await env.player.play(item: first)
        let artistFragment = first.subtitle.isEmpty ? "" : " by \(first.subtitle)"
        return .result(dialog: IntentDialog("Playing \(first.title)\(artistFragment)"))
    }
}

// MARK: - PlayArtistRadioIntent

// Start a radio station for "<artist>" on Riff.
struct PlayArtistRadioIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Artist Radio"
    static let description = IntentDescription(
        "Search for an artist and start an endless radio station based on them.",
        categoryName: "Playback"
    )
    static let openAppWhenRun: Bool = true

    @Parameter(title: "Artist")
    var artist: String

    static var parameterSummary: some ParameterSummary {
        Summary("Start a radio station for \(\.$artist) on Riff")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let env = try liveEnvironment()
        let trimmed = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw IntentError.noResults("Could not find that artist on Riff")
        }
        let results = (try? await env.innerTube.search(query: trimmed, filter: .artists)) ?? []
        guard let artistItem = results.first(where: { $0.kind == .artist }) ?? results.first else {
            throw IntentError.noResults("Could not find that artist on Riff")
        }
        await env.player.playArtistRadio(id: artistItem.id)
        return .result(dialog: IntentDialog("Starting a radio station for \(artistItem.title)"))
    }
}

// MARK: - ResumePlaybackIntent

// Resume Riff — toggles play. If nothing is loaded, the bridge no-ops
// (the underlying `togglePlay()` targets the current <video>).
struct ResumePlaybackIntent: AppIntent {
    static let title: LocalizedStringResource = "Resume Riff"
    static let description = IntentDescription(
        "Resume playback in Riff.",
        categoryName: "Playback"
    )

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let env = try liveEnvironment()
        await env.player.togglePlay()
        if let track = env.player.currentTrack {
            return .result(dialog: IntentDialog("Resuming \(track.title)"))
        }
        return .result(dialog: IntentDialog("Resuming Riff"))
    }
}

// MARK: - PausePlaybackIntent

// Pause Riff — toggles play when playing. We intentionally use the
// same `togglePlay()` entrypoint as Resume; we guard against pausing
// an already-paused player by checking `isPlaying` first.
struct PausePlaybackIntent: AppIntent {
    static let title: LocalizedStringResource = "Pause Riff"
    static let description = IntentDescription(
        "Pause playback in Riff.",
        categoryName: "Playback"
    )

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let env = try liveEnvironment()
        if env.player.isPlaying {
            await env.player.togglePlay()
        }
        return .result(dialog: IntentDialog("Paused Riff"))
    }
}

// MARK: - SkipNextIntent

// Skip on Riff — advance to the next track in the queue.
struct SkipNextIntent: AppIntent {
    static let title: LocalizedStringResource = "Skip to Next Track"
    static let description = IntentDescription(
        "Skip to the next track in the Riff queue.",
        categoryName: "Playback"
    )

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let env = try liveEnvironment()
        await env.player.next()
        if let track = env.player.currentTrack {
            return .result(dialog: IntentDialog("Skipped — now playing \(track.title)"))
        }
        return .result(dialog: IntentDialog("Skipped to the next track"))
    }
}

// MARK: - WhatsPlayingIntent

// Returns the current track + artist as both a dialog and a string
// `IntentResult.value` so users can pipe it into other Shortcuts
// (e.g. "Save now-playing to a note"). Reads from `currentTrack` only —
// the bridge owns the authoritative state; we do not eval the JS.
struct WhatsPlayingIntent: AppIntent {
    static let title: LocalizedStringResource = "What's Playing"
    static let description = IntentDescription(
        "Returns the title and artist of the currently playing track in Riff.",
        categoryName: "Playback"
    )
    // Read-only intent — does not need to foreground the app.
    static let openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some ReturnsValue<String> & ProvidesDialog {
        let env = try liveEnvironment()
        guard let track = env.player.currentTrack else {
            return .result(value: "", dialog: IntentDialog("Nothing is playing on Riff right now"))
        }
        // `Track.subtitle` is YT's "Artist · Album · Year" string. Pull
        // the first segment as the artist so the spoken/text answer is
        // tight ("Song by Artist"), and surface the full subtitle as the
        // returned value so power users get the album + year too.
        let artist = track.subtitle.split(separator: "·", maxSplits: 1).first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        let combined = artist.isEmpty ? track.title : "\(track.title) by \(artist)"
        return .result(value: combined, dialog: IntentDialog("\(combined)"))
    }
}

// MARK: - PlayPlaylistIntent

// Plays one of the user's saved playlists by name. Strategy: pull the
// signed-in user's Library → Playlists list first (so "my Focus mix"
// resolves to *their* playlist, not a stranger's), match by case-
// insensitive exact / prefix / substring. If nothing matches (or the
// user is signed out), fall back to a public search with the .playlists
// filter — covers users who want to play a famous public playlist by
// name.
struct PlayPlaylistIntent: AppIntent {
    static let title: LocalizedStringResource = "Play Playlist"
    static let description = IntentDescription(
        "Find a playlist by name in your Riff library and play it. Falls back to public playlists when none match.",
        categoryName: "Playback"
    )
    static let openAppWhenRun: Bool = true

    @Parameter(title: "Playlist")
    var name: String

    static var parameterSummary: some ParameterSummary {
        Summary("Play playlist \(\.$name) on Riff")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let env = try liveEnvironment()
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw IntentError.noResults("Could not find that playlist on Riff")
        }
        let needle = trimmed.lowercased()

        // Library lookup first — exact beats prefix beats substring.
        var library: [MediaItem] = []
        if env.isSignedIn {
            library = (try? await env.innerTube.library(section: .playlists)) ?? []
        }
        let libraryMatch =
            library.first { $0.title.lowercased() == needle } ??
            library.first { $0.title.lowercased().hasPrefix(needle) } ??
            library.first { $0.title.lowercased().contains(needle) }

        if let hit = libraryMatch {
            await env.player.playPlaylist(id: hit.id)
            return .result(dialog: IntentDialog("Playing \(hit.title)"))
        }

        // Fallback — public search scoped to playlists.
        let results = (try? await env.innerTube.search(query: trimmed, filter: .playlists)) ?? []
        guard let first = results.first(where: { $0.kind == .playlist }) ?? results.first else {
            throw IntentError.noResults("Could not find a playlist matching \(trimmed)")
        }
        await env.player.playPlaylist(id: first.id)
        return .result(dialog: IntentDialog("Playing \(first.title)"))
    }
}

// MARK: - SetPlaybackRateIntent

// Set the playback speed. Clamped to the same 0.5x...2.0x band the
// in-app rate menu offers. Stored under the current kind (music vs.
// spoken) so the next track of that kind keeps the new rate, matching
// the in-app menu's persistence behavior.
struct SetPlaybackRateIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Playback Speed"
    static let description = IntentDescription(
        "Set Riff's playback speed between 0.5× and 2.0×.",
        categoryName: "Playback"
    )
    static let openAppWhenRun: Bool = false

    @Parameter(title: "Speed", default: 1.0, inclusiveRange: (0.5, 2.0))
    var rate: Double

    static var parameterSummary: some ParameterSummary {
        Summary("Set Riff playback speed to \(\.$rate)×")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let env = try liveEnvironment()
        let clamped = max(0.5, min(2.0, rate))
        await env.player.setPlaybackRate(clamped)
        let formatted = String(format: "%.2f", clamped)
            .replacingOccurrences(of: ".00", with: "")
        return .result(dialog: IntentDialog("Set playback speed to \(formatted)×"))
    }
}

// MARK: - ToggleLikeIntent

// Like / unlike the currently-playing track. `toggleLike` requires
// sign-in (the InnerTube like endpoint needs the SAPISID cookie); the
// bridge rolls back the optimistic state-flip on failure so a Shortcuts
// invocation that fires while signed-out reports the resulting state
// honestly.
struct ToggleLikeIntent: AppIntent {
    static let title: LocalizedStringResource = "Toggle Like on Current Track"
    static let description = IntentDescription(
        "Like the currently-playing track in Riff (or remove the like if already liked).",
        categoryName: "Playback"
    )
    static let openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let env = try liveEnvironment()
        guard let track = env.player.currentTrack else {
            throw IntentError.noResults("Nothing is playing — start a song first")
        }
        let wasLiked = env.player.liked
        await env.player.toggleLike()
        let nowLiked = env.player.liked
        if nowLiked == wasLiked {
            // The bridge rolled back — likely a sign-in failure.
            throw IntentError.noResults("Couldn't update like — sign in to YouTube Music first")
        }
        let verb = nowLiked ? "Liked" : "Unliked"
        return .result(dialog: IntentDialog("\(verb) \(track.title)"))
    }
}

// MARK: - SkipBack15Intent

// Podcast-style 15-second rewind. The bridge's `skip(by:)` accepts a
// signed offset and the JS clamp handles the lower boundary at zero.
struct SkipBack15Intent: AppIntent {
    static let title: LocalizedStringResource = "Skip Back 15 Seconds"
    static let description = IntentDescription(
        "Rewind Riff by 15 seconds.",
        categoryName: "Playback"
    )
    static let openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let env = try liveEnvironment()
        await env.player.skip(by: -15)
        return .result(dialog: IntentDialog("Skipped back 15 seconds"))
    }
}

// MARK: - SkipForward30Intent

// Podcast-style 30-second skip-forward. Same caveat as above — the JS
// bridge owns the clamp at duration.
struct SkipForward30Intent: AppIntent {
    static let title: LocalizedStringResource = "Skip Forward 30 Seconds"
    static let description = IntentDescription(
        "Skip Riff forward by 30 seconds.",
        categoryName: "Playback"
    )
    static let openAppWhenRun: Bool = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let env = try liveEnvironment()
        await env.player.skip(by: 30)
        return .result(dialog: IntentDialog("Skipped forward 30 seconds"))
    }
}

// MARK: - SetVolumeIntent

// Sets the WKWebView's `<video>.volume` via the JS bridge. We accept a
// percent 0...100 because that matches user mental models and the
// Shortcuts UI handles the integer step naturally; the bridge owns the
// clamp to 0.0...1.0.
struct SetVolumeIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Riff Volume"
    static let description = IntentDescription(
        "Set Riff's playback volume to a percent between 0 and 100.",
        categoryName: "Playback"
    )
    static let openAppWhenRun: Bool = false

    @Parameter(title: "Volume (%)", default: 100, inclusiveRange: (0, 100))
    var percent: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Set Riff volume to \(\.$percent)%")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let env = try liveEnvironment()
        let clamped = max(0, min(100, percent))
        await env.player.setVolume(Double(clamped) / 100.0)
        return .result(dialog: IntentDialog("Set volume to \(clamped)%"))
    }
}

// MARK: - OpenStationForIntent

// Start a radio station for an artist OR a genre keyword. We search
// the .artists filter first so a clean artist name hits the canonical
// station; if no artist matches similarly (or the input looks more like
// a genre — "lo-fi", "synthwave", "focus"), fall back to a .songs
// search and auto-radio off the first track via `play(item:)`, which
// appends the `RDAMVM…` playlist that triggers the server-generated
// radio queue.
struct OpenStationForIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Station"
    static let description = IntentDescription(
        "Start a radio station for an artist or genre on Riff.",
        categoryName: "Playback"
    )
    static let openAppWhenRun: Bool = true

    @Parameter(title: "Artist or genre")
    var seed: String

    static var parameterSummary: some ParameterSummary {
        Summary("Open a station for \(\.$seed) on Riff")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let env = try liveEnvironment()
        let trimmed = seed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw IntentError.noResults("Could not find a station for that on Riff")
        }
        let needle = trimmed.lowercased()

        // Artist-first pass — only accept a "clean" artist hit (title
        // overlaps the user's seed) so a genre word like "synthwave"
        // doesn't accidentally lock onto an unrelated artist named
        // "Synthwave Joe" and lose the genre semantics the user wanted.
        let artistHits = (try? await env.innerTube.search(query: trimmed, filter: .artists)) ?? []
        if let artist = artistHits.first(where: { $0.kind == .artist }),
           Self.namesAreSimilar(artist.title.lowercased(), needle) {
            await env.player.playArtistRadio(id: artist.id)
            return .result(dialog: IntentDialog("Starting a station for \(artist.title)"))
        }

        // Fallback — search songs and auto-radio off the first track.
        let songHits = (try? await env.innerTube.search(query: trimmed, filter: .songs)) ?? []
        guard let song = songHits.first(where: { $0.kind == .song }) ?? songHits.first else {
            throw IntentError.noResults("Could not find a station for \(trimmed)")
        }
        await env.player.play(item: song)
        return .result(dialog: IntentDialog("Starting a \(trimmed) station"))
    }

    // Soft "looks like the same name" check. Either name contains the
    // other as a substring, or the Jaccard overlap of their words is
    // ≥ 0.5. Pure helper so the artist-vs-genre fallback policy stays
    // inspectable from tests.
    static func namesAreSimilar(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        if a.contains(b) || b.contains(a) { return true }
        let aw = Set(a.split { !$0.isLetter && !$0.isNumber }.map(String.init))
        let bw = Set(b.split { !$0.isLetter && !$0.isNumber }.map(String.init))
        guard !aw.isEmpty, !bw.isEmpty else { return false }
        let intersection = aw.intersection(bw).count
        let union = aw.union(bw).count
        return Double(intersection) / Double(union) >= 0.5
    }
}

// MARK: - AppShortcutsProvider

// Surfaces the intent set to Spotlight, Siri, and the Shortcuts app.
// AppIntents auto-discovers this struct at launch via the protocol
// conformance; no Info.plist key is required.
//
// Phrases must include `\(.applicationName)` so the system can route
// the utterance to Riff specifically (otherwise other music apps with
// similar shortcuts can win the dispatch).
struct RiffAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        // NOTE on parameter interpolation: `\(\.$query)` /
        // `\(\.$artist)` inside a phrase template only compiles when
        // the parameter type is AppEntity or AppEnum. For plain
        // String parameters the phrase has to be parameter-less;
        // Siri / Spotlight will prompt for the value conversationally
        // once the phrase matches. Worth revisiting later by wrapping
        // the query in an AppEntity if voice triggering with the
        // song name inline becomes important.
        AppShortcut(
            intent: PlayTrackIntent(),
            phrases: [
                "Play a song on \(.applicationName)",
                "Play music in \(.applicationName)",
                "Search for a song on \(.applicationName)"
            ],
            shortTitle: "Play Song",
            systemImageName: "play.circle.fill"
        )
        AppShortcut(
            intent: PlayArtistRadioIntent(),
            phrases: [
                "Start a radio station on \(.applicationName)",
                "Play artist radio on \(.applicationName)",
                "Start artist radio in \(.applicationName)"
            ],
            shortTitle: "Artist Radio",
            systemImageName: "dot.radiowaves.left.and.right"
        )
        AppShortcut(
            intent: ResumePlaybackIntent(),
            phrases: [
                "Resume \(.applicationName)",
                "Resume playback in \(.applicationName)",
                "Continue playing on \(.applicationName)"
            ],
            shortTitle: "Resume",
            systemImageName: "play.fill"
        )
        AppShortcut(
            intent: PausePlaybackIntent(),
            phrases: [
                "Pause \(.applicationName)",
                "Pause playback in \(.applicationName)",
                "Stop \(.applicationName)"
            ],
            shortTitle: "Pause",
            systemImageName: "pause.fill"
        )
        AppShortcut(
            intent: SkipNextIntent(),
            phrases: [
                "Skip on \(.applicationName)",
                "Next track on \(.applicationName)",
                "Skip this song on \(.applicationName)"
            ],
            shortTitle: "Skip",
            systemImageName: "forward.fill"
        )
        AppShortcut(
            intent: WhatsPlayingIntent(),
            phrases: [
                "What's playing on \(.applicationName)",
                "What's playing in \(.applicationName)",
                "What song is playing on \(.applicationName)"
            ],
            shortTitle: "What's Playing",
            systemImageName: "music.quarternote.3"
        )
        AppShortcut(
            intent: PlayPlaylistIntent(),
            phrases: [
                // Plain String param — no `\(\.$name)` interpolation, the
                // system will prompt for the playlist name conversationally.
                "Play a playlist on \(.applicationName)",
                "Play playlist in \(.applicationName)",
                "Open a playlist on \(.applicationName)"
            ],
            shortTitle: "Play Playlist",
            systemImageName: "music.note.list"
        )
        AppShortcut(
            intent: ToggleLikeIntent(),
            phrases: [
                "Like this song on \(.applicationName)",
                "Toggle like on \(.applicationName)",
                "Like the current track on \(.applicationName)"
            ],
            shortTitle: "Like Track",
            systemImageName: "hand.thumbsup.fill"
        )
        AppShortcut(
            intent: SkipForward30Intent(),
            phrases: [
                "Skip forward 30 seconds on \(.applicationName)",
                "Skip ahead 30 seconds on \(.applicationName)",
                "Go forward 30 on \(.applicationName)"
            ],
            shortTitle: "Forward 30s",
            systemImageName: "goforward.30"
        )
        // SetPlaybackRateIntent (Double param), SetVolumeIntent (Int
        // param), and SkipBack15Intent are intentionally NOT registered
        // here. Apple caps AppShortcutsProvider.appShortcuts at 10
        // entries per app (we ship 13 intents, including these three).
        // The intents themselves still ship — users can find them in
        // the Shortcuts.app editor — they just lose the voice-trigger
        // phrase. Numeric-param shortcuts voice-prompt poorly anyway.
        AppShortcut(
            intent: OpenStationForIntent(),
            phrases: [
                // Plain String param — same caveat as PlayPlaylist;
                // Siri / Spotlight will prompt for the seed.
                "Open a station on \(.applicationName)",
                "Start a station in \(.applicationName)",
                "Play a radio station on \(.applicationName)"
            ],
            shortTitle: "Open Station",
            systemImageName: "dot.radiowaves.left.and.right"
        )
    }
}
