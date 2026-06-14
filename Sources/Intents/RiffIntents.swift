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
    static var title: LocalizedStringResource = "Play Song"
    static var description = IntentDescription(
        "Search YouTube Music and play the first matching song in Riff.",
        categoryName: "Playback"
    )
    // Bring Riff to the foreground when invoked from Spotlight / Siri.
    static var openAppWhenRun: Bool = true

    @Parameter(
        title: "Song",
        description: "Title or 'title artist' — same string you'd type into Search.",
        requestValueDialog: "What would you like to play?"
    )
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
    static var title: LocalizedStringResource = "Start Artist Radio"
    static var description = IntentDescription(
        "Search for an artist and start an endless radio station based on them.",
        categoryName: "Playback"
    )
    static var openAppWhenRun: Bool = true

    @Parameter(
        title: "Artist",
        description: "Artist name to seed a radio station.",
        requestValueDialog: "Which artist?"
    )
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
    static var title: LocalizedStringResource = "Resume Riff"
    static var description = IntentDescription(
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
    static var title: LocalizedStringResource = "Pause Riff"
    static var description = IntentDescription(
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
    static var title: LocalizedStringResource = "Skip to Next Track"
    static var description = IntentDescription(
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
        AppShortcut(
            intent: PlayTrackIntent(),
            phrases: [
                "Play \(\.$query) on \(.applicationName)",
                "Play \(\.$query) with \(.applicationName)",
                "Play \(\.$query) in \(.applicationName)"
            ],
            shortTitle: "Play Song",
            systemImageName: "play.circle.fill"
        )
        AppShortcut(
            intent: PlayArtistRadioIntent(),
            phrases: [
                "Start a radio station for \(\.$artist) on \(.applicationName)",
                "Play \(\.$artist) radio on \(.applicationName)",
                "Start \(\.$artist) radio in \(.applicationName)"
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
