import Foundation

/// Tiny client for `oauth2/v3/userinfo` — Google's identity endpoint
/// that returns the signed-in user's email and (optionally) display
/// name. Surfaced in Settings so a user with multiple Google accounts
/// can tell which one Riff is currently authed against.
///
/// Two auth modes need different handling:
///   - **OAuth Device Flow** (`OAuthTokens.load()`) — bearer token, can
///     hit `oauth2.googleapis.com/oauth2/v3/userinfo` directly.
///   - **WebView SAPISID** (cookie-based) — userinfo requires bearer,
///     so we have no clean path. Returns nil; the Settings UI shows
///     a generic "Signed in via WebView" line in that case.
@MainActor
enum UserInfoService {

    /// Cached result so we don't refetch on every Settings open.
    /// Cleared on sign-out (see SettingsView's signOut tap).
    static var cachedEmail: String? = nil

    struct UserInfo: Codable {
        let email: String?
        let name: String?
        let picture: String?
    }

    /// Fetch from Google. nil when:
    ///   - Not signed in via Device Flow (cookie-based session).
    ///   - Network failure (transient — caller can retry).
    ///   - 401 (token refresh failed → user needs to re-auth).
    static func fetch() async -> UserInfo? {
        guard let token = await OAuthDeviceFlow.refreshIfNeeded() else {
            return nil
        }
        let url = URL(string: "https://www.googleapis.com/oauth2/v3/userinfo")!
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            let info = try JSONDecoder().decode(UserInfo.self, from: data)
            cachedEmail = info.email
            return info
        } catch {
            return nil
        }
    }

    /// Returns the cached email if available, otherwise fetches.
    /// Keeps Settings render snappy on second open.
    static func emailIfAvailable() async -> String? {
        if let cachedEmail { return cachedEmail }
        return await fetch()?.email
    }
}
