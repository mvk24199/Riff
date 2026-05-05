import SwiftUI

/// Riff brand tokens. The single source of truth for color and spacing
/// constants used across the player and tile UIs. Inspired by YT Music
/// iOS — dark, generous spacing, bright red as the only chromatic accent.
enum Theme {
    /// YouTube Music brand red. Used for the active play state, like
    /// buttons, primary CTAs.
    static let red = Color(red: 1.0, green: 0.0, blue: 0.2)

    static let surface = Color.white.opacity(0.04)
    static let surfaceHover = Color.white.opacity(0.08)
    static let divider = Color.white.opacity(0.08)
}

extension Color {
    static let riffRed = Theme.red
}
