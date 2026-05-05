import Foundation

/// User-configurable OAuth client credentials. Defaults to the public
/// YouTube TV `client_id`/`secret` pair (works for sign-in but the GCP
/// project doesn't have YouTube Data API v3 enabled, so Library reads
/// 403). Users who want Library access register their own OAuth Limited-
/// Input Device client at console.cloud.google.com, enable the YouTube
/// Data API v3, and paste the credentials here.
struct OAuthClientConfig: Sendable {
    let clientId: String
    let clientSecret: String

    /// True iff the user has set custom credentials (i.e. not the TV
    /// defaults). Library access via Data API v3 needs this.
    var isCustom: Bool {
        clientId != Self.tvClientId
    }

    /// **NOT a secret.** This is the publicly-known YouTube TV OAuth
    /// client pair — Google ships these IDs in the YouTube TV / Apple
    /// TV / game console apps and they're widely embedded in
    /// open-source clients (yt-dlp, NewPipe, etc.). The "secret" is
    /// only used to identify the *application*, not the user — actual
    /// authorization happens via Device Flow where the user enters a
    /// one-time code on their phone. Safe to commit.
    static let tvClientId     = "861556708454-d6dlm3lh05idd8npek18k6be8ba3oc68.apps.googleusercontent.com"
    static let tvClientSecret = "SboVhoG9s0rNafixCSGGKXAT"

    static let `default` = OAuthClientConfig(clientId: tvClientId, clientSecret: tvClientSecret)

    private static let idKey = "oauth.client.id"
    private static let secretKey = "oauth.client.secret"

    static func load() -> OAuthClientConfig {
        let id = UserDefaults.standard.string(forKey: idKey)
        let secret = UserDefaults.standard.string(forKey: secretKey)
        if let id, !id.isEmpty, let secret, !secret.isEmpty {
            return OAuthClientConfig(clientId: id, clientSecret: secret)
        }
        return .default
    }

    func save() {
        if isCustom {
            UserDefaults.standard.set(clientId, forKey: Self.idKey)
            UserDefaults.standard.set(clientSecret, forKey: Self.secretKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.idKey)
            UserDefaults.standard.removeObject(forKey: Self.secretKey)
        }
    }

    static func reset() {
        UserDefaults.standard.removeObject(forKey: idKey)
        UserDefaults.standard.removeObject(forKey: secretKey)
    }
}
