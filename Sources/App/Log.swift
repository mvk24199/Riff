import Foundation
import os

/// Unified-log Loggers per area. Using `os.Logger` instead of `print()` so
/// log lines reach macOS's unified logging system — visible in Xcode's
/// console *and* readable from the terminal via:
///
///     log show --predicate 'subsystem == "dev.riff.app"' --last 5m
///
/// which lets us iterate on bugs without staring at the Xcode UI. All
/// loggers share `dev.riff.app` as the subsystem; categories carve up the
/// surface so we can grep them independently.
enum Log {
    static let bridge   = Logger(subsystem: "dev.riff.app", category: "bridge")
    static let oauth    = Logger(subsystem: "dev.riff.app", category: "oauth")
    static let innertube = Logger(subsystem: "dev.riff.app", category: "innertube")
    static let resolver = Logger(subsystem: "dev.riff.app", category: "resolver")
}
