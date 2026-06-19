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
    }
}
