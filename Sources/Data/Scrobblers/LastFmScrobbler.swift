import Foundation
import CryptoKit

/// last.fm scrobbler — implements `track.scrobble` and
/// `track.updateNowPlaying` against the last.fm 2.0 web service.
///
/// Spec: https://www.last.fm/api/show/track.scrobble
///       https://www.last.fm/api/show/track.updateNowPlaying
///       https://www.last.fm/api/authspec  (auth + signature)
///
/// Auth model
/// ----------
/// last.fm uses a desktop-app three-step flow:
///   1. Get an unauth'd token via `auth.getToken`.
///   2. User opens `https://www.last.fm/api/auth/?api_key=K&token=T`
///      in their browser and clicks Approve.
///   3. App calls `auth.getSession` with the now-approved token; gets
///      a permanent session key.
///
/// Because we don't ship our own API key (last.fm key registration is
/// per-developer), we BYO-key: user pastes their own API key + secret
/// from https://www.last.fm/api/account/create. They also paste their
/// last.fm username + the session key they got from a one-off OAuth
/// dance (we provide a helper inside this file for that). All four
/// values live in Keychain.
///
/// Signature
/// ---------
/// Every authenticated POST is signed: concatenate every (key, value)
/// pair in alphabetical order by key into one string, append the
/// shared secret, hash with MD5. The five params for scrobble are
/// `api_key`, `artist`, `method`, `sk`, `track`, `timestamp` (plus
/// optional `album`, `duration`). We sort over all of them — including
/// optionals when present.
///
/// Concurrency: this type is value-stateless. `URLSession` is Sendable
/// and the cached credentials are read fresh from Keychain on every
/// call (so a user pasting a new key/secret takes effect immediately).
/// Marked `final` + nonisolated.
final class LastFmScrobbler: ScrobblerService, Sendable {
    let displayName = "last.fm"

    static let apiURL = URL(string: "https://ws.audioscrobbler.com/2.0/")!
    static let authURL = "https://www.last.fm/api/auth/"

    private let session: URLSession

    init(session: URLSession? = nil) {
        self.session = session ?? Scrobblers.makeSession()
    }

    /// True when every required credential is populated AND the user
    /// hasn't toggled the service off in Settings.
    var isReady: Bool {
        guard UserDefaults.standard.bool(forKey: ScrobblerDefaults.lastFmEnabled) else { return false }
        return Self.storedCredentials() != nil
    }

    struct Credentials: Equatable, Sendable {
        let username: String
        let apiKey: String
        let apiSecret: String
        let sessionKey: String
    }

    static func storedCredentials() -> Credentials? {
        guard let username = Keychain.get(ScrobblerKeychain.lastFmUsername), !username.isEmpty,
              let apiKey = Keychain.get(ScrobblerKeychain.lastFmAPIKey), !apiKey.isEmpty,
              let apiSecret = Keychain.get(ScrobblerKeychain.lastFmSecret), !apiSecret.isEmpty,
              let sessionKey = Keychain.get(ScrobblerKeychain.lastFmSessionKey), !sessionKey.isEmpty
        else { return nil }
        return Credentials(username: username, apiKey: apiKey, apiSecret: apiSecret, sessionKey: sessionKey)
    }

    /// Save credentials atomically. Errors propagate so Settings can
    /// show a Keychain-denied banner.
    static func saveCredentials(
        username: String,
        apiKey: String,
        apiSecret: String,
        sessionKey: String
    ) throws {
        try Keychain.set(username, for: ScrobblerKeychain.lastFmUsername)
        try Keychain.set(apiKey, for: ScrobblerKeychain.lastFmAPIKey)
        try Keychain.set(apiSecret, for: ScrobblerKeychain.lastFmSecret)
        try Keychain.set(sessionKey, for: ScrobblerKeychain.lastFmSessionKey)
    }

    static func clearCredentials() {
        Keychain.delete(ScrobblerKeychain.lastFmUsername)
        Keychain.delete(ScrobblerKeychain.lastFmAPIKey)
        Keychain.delete(ScrobblerKeychain.lastFmSecret)
        Keychain.delete(ScrobblerKeychain.lastFmSessionKey)
    }

    // MARK: - ScrobblerService

    func updateNowPlaying(_ track: ScrobbleTrack) async {
        guard let creds = Self.storedCredentials() else { return }
        var params: [String: String] = [
            "method": "track.updateNowPlaying",
            "api_key": creds.apiKey,
            "sk": creds.sessionKey,
            "artist": track.artist,
            "track": track.title,
        ]
        if let album = track.album, !album.isEmpty { params["album"] = album }
        if let dur = track.durationSeconds, dur > 0 { params["duration"] = String(dur) }
        await post(params: params, secret: creds.apiSecret)
    }

    func scrobble(_ track: ScrobbleTrack) async {
        guard let creds = Self.storedCredentials() else { return }
        let ts = Int(track.startedAt.timeIntervalSince1970)
        var params: [String: String] = [
            "method": "track.scrobble",
            "api_key": creds.apiKey,
            "sk": creds.sessionKey,
            "artist": track.artist,
            "track": track.title,
            "timestamp": String(ts),
        ]
        if let album = track.album, !album.isEmpty { params["album"] = album }
        if let dur = track.durationSeconds, dur > 0 { params["duration"] = String(dur) }
        await post(params: params, secret: creds.apiSecret)
    }

    // MARK: - Signed POST

    /// Sign + send. last.fm returns XML by default and we don't parse
    /// the response — both endpoints are fire-and-forget. We log
    /// non-2xx as a debug breadcrumb but otherwise swallow errors so a
    /// scrobble failure can't crash the app.
    private func post(params: [String: String], secret: String) async {
        var signed = params
        signed["api_sig"] = Self.signature(params: params, secret: secret)
        // Ask for a JSON response so the server gives us something easy
        // to introspect if we ever do want to read it.
        signed["format"] = "json"

        var request = URLRequest(url: Self.apiURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Scrobblers.formEncode(signed)

        do {
            let (_, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                Log.bridge.debug("last.fm POST \(params["method"] ?? "?", privacy: .public) → HTTP \(http.statusCode, privacy: .public)")
            }
        } catch {
            // No retry — scrobble races against the user's next track,
            // and a stale retry is worse than a dropped scrobble. The
            // user's network problems are not our problem to solve.
            Log.bridge.debug("last.fm POST failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// MD5 signature over the alphabetically-sorted concatenation of
    /// every (key + value) pair, followed by the shared secret.
    /// Exposed `internal` so unit tests can verify against the canonical
    /// example from the last.fm auth spec.
    static func signature(params: [String: String], secret: String) -> String {
        var buf = ""
        for key in params.keys.sorted() {
            buf.append(key)
            buf.append(params[key] ?? "")
        }
        buf.append(secret)
        let digest = Insecure.MD5.hash(data: Data(buf.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - One-off OAuth helpers

    /// Step 1 of the desktop-app flow. Returns the unauth'd token.
    static func fetchToken(apiKey: String, apiSecret: String, session: URLSession? = nil) async throws -> String {
        let s = session ?? Scrobblers.makeSession()
        let params: [String: String] = ["method": "auth.getToken", "api_key": apiKey]
        let signed: [String: String] = [
            "method": "auth.getToken",
            "api_key": apiKey,
            "api_sig": signature(params: params, secret: apiSecret),
            "format": "json",
        ]
        var url = URLComponents(url: apiURL, resolvingAgainstBaseURL: false)!
        url.queryItems = signed.keys.sorted().map { URLQueryItem(name: $0, value: signed[$0]) }
        var req = URLRequest(url: url.url!)
        req.httpMethod = "GET"
        let (data, _) = try await s.data(for: req)
        struct TokenResp: Decodable { let token: String }
        return try JSONDecoder().decode(TokenResp.self, from: data).token
    }

    /// Step 3 of the desktop-app flow. Exchanges an approved token for
    /// a permanent (username, sessionKey) pair.
    static func fetchSession(token: String, apiKey: String, apiSecret: String, session: URLSession? = nil) async throws -> (username: String, sessionKey: String) {
        let s = session ?? Scrobblers.makeSession()
        let params: [String: String] = [
            "method": "auth.getSession",
            "api_key": apiKey,
            "token": token,
        ]
        var signed = params
        signed["api_sig"] = signature(params: params, secret: apiSecret)
        signed["format"] = "json"

        var url = URLComponents(url: apiURL, resolvingAgainstBaseURL: false)!
        url.queryItems = signed.keys.sorted().map { URLQueryItem(name: $0, value: signed[$0]) }
        var req = URLRequest(url: url.url!)
        req.httpMethod = "GET"
        let (data, _) = try await s.data(for: req)
        struct SessionResp: Decodable {
            struct Inner: Decodable { let name: String; let key: String }
            let session: Inner
        }
        let decoded = try JSONDecoder().decode(SessionResp.self, from: data)
        return (decoded.session.name, decoded.session.key)
    }

    /// Build the URL the user opens in their browser to approve the
    /// API key (step 2 of the flow). They get redirected to last.fm,
    /// click Allow, then come back to Riff and click "Done" so we
    /// trigger step 3.
    static func authorizationURL(apiKey: String, token: String) -> URL {
        var c = URLComponents(string: authURL)!
        c.queryItems = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "token", value: token),
        ]
        return c.url!
    }
}
