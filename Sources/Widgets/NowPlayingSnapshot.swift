import Foundation

// Kind identifier shared between the main app (which calls
// WidgetCenter.shared.reloadTimelines) and the widget extension
// (which registers its Widget with this kind). Lifted out of
// NowPlayingSnapshotWriter so the widget target — which does not
// link the writer file — can reference it without a missing-symbol
// error.
public enum NowPlayingWidgetIdentifier {
    public static let kind = "dev.riff.nowPlayingWidget"
}

// Wire-format the main app writes and the widget reads. Lives in a
// separate target-shared file so both the Riff app target and the
// RiffWidget extension can encode/decode the same shape without
// dragging in PlayerBridge / WKWebView / SwiftUI dependencies.
//
// Persisted via UserDefaults suite against the shared App Group
// container [group.dev.riff.app]. The widget process is sandboxed
// away from the app's MainActor isolation, so this struct is
// intentionally Sendable and Codable with only value-type fields —
// no Track / PlayerBridge references.
public struct NowPlayingSnapshot: Codable, Sendable, Equatable {
    public var videoId: String
    public var title: String
    public var subtitle: String
    // Absolute string of the thumbnail URL. Stored as String not URL
    // so a malformed value can't break decoding on the widget side;
    // the widget re-parses defensively before any network use.
    public var thumbnailURLString: String?
    public var isPlaying: Bool
    // Wall-clock instant when this snapshot was written. Used by the
    // widget to extrapolate elapsed between TimelineProvider ticks
    // [WidgetKit schedules them, not us].
    public var updatedAt: Date
    public var elapsed: Double
    public var duration: Double

    public init(
        videoId: String,
        title: String,
        subtitle: String,
        thumbnailURLString: String?,
        isPlaying: Bool,
        updatedAt: Date,
        elapsed: Double,
        duration: Double
    ) {
        self.videoId = videoId
        self.title = title
        self.subtitle = subtitle
        self.thumbnailURLString = thumbnailURLString
        self.isPlaying = isPlaying
        self.updatedAt = updatedAt
        self.elapsed = elapsed
        self.duration = duration
    }

    // Convenience that re-parses the stored thumbnail string. Returns
    // nil for missing / malformed values rather than throwing — the
    // widget renders a placeholder in that case.
    public var thumbnailURL: URL? {
        guard let s = thumbnailURLString, !s.isEmpty else { return nil }
        return URL(string: s)
    }

    // Elapsed seconds projected forward from updatedAt to now.
    // Clamped to the 0...duration band so a stale snapshot can't
    // claim negative progress or run past the track end. We
    // deliberately extrapolate only while isPlaying — pausing freezes
    // the timeline at whatever was last reported.
    public func projectedElapsed(at now: Date = Date()) -> Double {
        guard isPlaying else { return elapsed }
        let delta = max(0, now.timeIntervalSince(updatedAt))
        let projected = elapsed + delta
        guard duration > 0 else { return max(0, projected) }
        return min(duration, max(0, projected))
    }
}

// Storage keys and the App Group suite name are kept in one place so
// host + widget can't drift. If we ever rename the group, e.g. team
// prefix changes, this is the single edit point.
public enum NowPlayingSnapshotStore {
    public static let appGroupID = "group.dev.riff.app"
    public static let defaultsKey = "widget.nowPlayingSnapshot.v1"

    // Returns the shared UserDefaults instance, or nil if the App
    // Group isn't provisioned [development build without the
    // entitlement, simulator-only edge cases]. Callers should treat
    // nil as "widget data unavailable" rather than fatal — the app
    // continues to work without a widget.
    public static func sharedDefaults() -> UserDefaults? {
        UserDefaults(suiteName: appGroupID)
    }

    public static func write(_ snapshot: NowPlayingSnapshot) {
        guard let defaults = sharedDefaults() else { return }
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: defaultsKey)
    }

    public static func read() -> NowPlayingSnapshot? {
        guard let defaults = sharedDefaults() else { return nil }
        guard let data = defaults.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(NowPlayingSnapshot.self, from: data)
    }

    // Clear the persisted snapshot. Called from the app on sign-out
    // or "stop playback" so the widget doesn't keep advertising the
    // last-played track indefinitely.
    public static func clear() {
        guard let defaults = sharedDefaults() else { return }
        defaults.removeObject(forKey: defaultsKey)
    }
}
