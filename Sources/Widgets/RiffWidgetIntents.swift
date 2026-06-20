import AppIntents
import Foundation

// AppIntents the Notification Center widget binds to its transport
// buttons. The widget extension is a separate process — it has no
// PlayerBridge / WKWebView, so it can't drive playback directly.
//
// Transport pattern:
//   1. Tapping a button runs the intent in the widget's process.
//   2. perform() writes a "pending command" into the shared App
//      Group defaults [WidgetCommandStore].
//   3. openAppWhenRun = true brings the Riff app to the foreground.
//   4. AppEnvironment subscribes to UserDefaults changes on the
//      shared suite; when a pending command arrives, it routes it
//      to PlayerBridge and clears the pending field.
//
// This indirection is necessary on macOS — there's no Live Activity
// container that lets the widget itself drive playback in-process,
// and we don't ship a separate "playback service" daemon.

// Enum of widget-driven transport commands. Codable through a small
// string raw value so we can serialize through plain UserDefaults
// without dragging Codable inference noise into the widget side.
public enum WidgetCommand: String, Codable, Sendable {
    case togglePlay
    case next
    case previous
}

// Storage for the pending-command field. Lives in the App Group
// alongside the snapshot so the writer and reader share one suite.
public enum WidgetCommandStore {
    public static let pendingKey = "widget.pendingCommand.v1"
    public static let pendingAtKey = "widget.pendingCommand.at.v1"

    public static func enqueue(_ command: WidgetCommand) {
        guard let defaults = NowPlayingSnapshotStore.sharedDefaults() else { return }
        defaults.set(command.rawValue, forKey: pendingKey)
        defaults.set(Date().timeIntervalSince1970, forKey: pendingAtKey)
    }

    // Returns and consumes the pending command if one exists and is
    // fresh [enqueued within the last 30s — older commands are
    // assumed orphaned, e.g. the app was force-quit before
    // processing them, and we don't want to play music ten minutes
    // later because the user tapped Play during a stale session].
    public static func dequeue(maxAge: TimeInterval = 30) -> WidgetCommand? {
        guard let defaults = NowPlayingSnapshotStore.sharedDefaults() else { return nil }
        guard let raw = defaults.string(forKey: pendingKey),
              let cmd = WidgetCommand(rawValue: raw) else { return nil }
        let stamp = defaults.double(forKey: pendingAtKey)
        let age = Date().timeIntervalSince1970 - stamp
        defaults.removeObject(forKey: pendingKey)
        defaults.removeObject(forKey: pendingAtKey)
        guard age >= 0, age <= maxAge else { return nil }
        return cmd
    }
}

// Toggle play/pause from the widget.
public struct WidgetTogglePlayIntent: AppIntent {
    public static let title: LocalizedStringResource = "Toggle Riff Playback"
    public static let openAppWhenRun: Bool = true
    public init() {}
    public func perform() async throws -> some IntentResult {
        WidgetCommandStore.enqueue(.togglePlay)
        return .result()
    }
}

// Skip forward.
public struct WidgetSkipNextIntent: AppIntent {
    public static let title: LocalizedStringResource = "Riff: Skip Next"
    public static let openAppWhenRun: Bool = true
    public init() {}
    public func perform() async throws -> some IntentResult {
        WidgetCommandStore.enqueue(.next)
        return .result()
    }
}

// Skip backwards.
public struct WidgetPreviousIntent: AppIntent {
    public static let title: LocalizedStringResource = "Riff: Previous Track"
    public static let openAppWhenRun: Bool = true
    public init() {}
    public func perform() async throws -> some IntentResult {
        WidgetCommandStore.enqueue(.previous)
        return .result()
    }
}
