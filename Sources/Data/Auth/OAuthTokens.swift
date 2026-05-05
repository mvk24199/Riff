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

    private static let keychainKey = "oauth.youtube.tokens"

    static func load() -> OAuthTokens? {
        guard let json = Keychain.get(keychainKey),
              let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder.iso8601.decode(OAuthTokens.self, from: data)
    }

    func save() throws {
        let data = try JSONEncoder.iso8601.encode(self)
        guard let json = String(data: data, encoding: .utf8) else { return }
        try Keychain.set(json, for: Self.keychainKey)
    }

    static func clear() {
        Keychain.delete(keychainKey)
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
