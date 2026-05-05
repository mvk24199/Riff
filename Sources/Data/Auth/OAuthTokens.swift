import Foundation

/// Persisted OAuth credentials for the YouTube Data scope. Stored as JSON in
/// the macOS Keychain. Access tokens expire (~1h); the refresh token is the
/// long-lived secret we use to mint new access tokens.
struct OAuthTokens: Codable, Sendable {
    let accessToken: String
    let refreshToken: String?
    /// Absolute time at which the access token stops being valid.
    let expiresAt: Date

    var isExpired: Bool { Date() >= expiresAt.addingTimeInterval(-30) }

    /// Storage key in UserDefaults. Was originally the Keychain — but
    /// ad-hoc-signed dev builds get a fresh code signature on every Xcode
    /// build, so macOS treats each build as a different requestor and
    /// re-prompts "Riff wants to access keychain" on every launch. Until
    /// we have proper code signing, plain UserDefaults storage is the
    /// pragmatic choice: device-local, not synced via iCloud, and the
    /// access tokens it holds expire on their own (1h).
    private static let defaultsKey = "oauth.youtube.tokens"

    static func load() -> OAuthTokens? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder.iso8601.decode(OAuthTokens.self, from: data)
    }

    func save() throws {
        let data = try JSONEncoder.iso8601.encode(self)
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }
}

private extension JSONDecoder {
    static let iso8601: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

private extension JSONEncoder {
    static let iso8601: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
}
