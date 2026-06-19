import Foundation

/// ListenBrainz scrobbler — implements `POST /1/submit-listens`
/// against the ListenBrainz public API.
///
/// Spec: https://listenbrainz.readthedocs.io/en/latest/users/api/core.html#post--1-submit-listens
///
/// Auth model
/// ----------
/// ListenBrainz is significantly simpler than last.fm: there's no
/// signature, no session-key dance, and no separate API key + secret.
/// The user pastes a single user-token (found at
/// `https://listenbrainz.org/profile/`) and we send it as a bearer
/// header on every request.
///
/// Payload shape
/// -------------
/// Both real-listen and now-playing use the same endpoint, distinguished
/// by the top-level `listen_type` field:
///   - `single`: a real listen. Carries `listened_at` (UNIX epoch seconds).
///   - `playing_now`: now-playing hint. `listened_at` is omitted.
///
/// Required fields under `track_metadata`: `track_name`, `artist_name`.
/// Optional: `release_name` (album), and an `additional_info` blob that
/// can carry `duration_ms`, MBIDs, etc. We populate `duration_ms` when
/// we know it.
///
/// Concurrency: same shape as `LastFmScrobbler`. Value-stateless,
/// Sendable, internal URLSession.
final class ListenBrainzScrobbler: ScrobblerService, Sendable {
    let displayName = "ListenBrainz"

    static let submitURL = URL(string: "https://api.listenbrainz.org/1/submit-listens")!
    static let validateTokenURL = URL(string: "https://api.listenbrainz.org/1/validate-token")!

    private let session: URLSession

    init(session: URLSession? = nil) {
        self.session = session ?? Scrobblers.makeSession()
    }

    var isReady: Bool {
        guard UserDefaults.standard.bool(forKey: ScrobblerDefaults.listenBrainzEnabled) else { return false }
        return Self.storedToken()?.isEmpty == false
    }

    static func storedToken() -> String? {
        Keychain.get(ScrobblerKeychain.listenBrainzToken)
    }

    static func saveToken(_ token: String) throws {
        try Keychain.set(token, for: ScrobblerKeychain.listenBrainzToken)
    }

    static func clearToken() {
        Keychain.delete(ScrobblerKeychain.listenBrainzToken)
        UserDefaults.standard.removeObject(forKey: ScrobblerDefaults.listenBrainzUsername)
    }

    // MARK: - ScrobblerService

    func updateNowPlaying(_ track: ScrobbleTrack) async {
        guard let token = Self.storedToken() else { return }
        let payload = Self.buildPayload(track: track, listenType: .playingNow)
        await post(payload: payload, token: token)
    }

    func scrobble(_ track: ScrobbleTrack) async {
        guard let token = Self.storedToken() else { return }
        let payload = Self.buildPayload(track: track, listenType: .single)
        await post(payload: payload, token: token)
    }

    // MARK: - Payload

    enum ListenType: String { case single, playingNow = "playing_now" }

    /// Build the JSON payload. Internal for testability — the parser
    /// tests round-trip this through `JSONSerialization` to verify the
    /// shape against the documented schema.
    static func buildPayload(track: ScrobbleTrack, listenType: ListenType) -> [String: Any] {
        var trackMetadata: [String: Any] = [
            "track_name": track.title,
            "artist_name": track.artist,
        ]
        if let album = track.album, !album.isEmpty {
            trackMetadata["release_name"] = album
        }
        if let dur = track.durationSeconds, dur > 0 {
            trackMetadata["additional_info"] = ["duration_ms": dur * 1000]
        }
        var listen: [String: Any] = ["track_metadata": trackMetadata]
        if listenType == .single {
            listen["listened_at"] = Int(track.startedAt.timeIntervalSince1970)
        }
        return [
            "listen_type": listenType.rawValue,
            "payload": [listen],
        ]
    }

    private func post(payload: [String: Any], token: String) async {
        var request = URLRequest(url: Self.submitURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
        guard let body = try? JSONSerialization.data(withJSONObject: payload, options: []) else { return }
        request.httpBody = body
        do {
            let (_, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                Log.bridge.debug("ListenBrainz POST \(payload["listen_type"] as? String ?? "?", privacy: .public) → HTTP \(http.statusCode, privacy: .public)")
            }
        } catch {
            Log.bridge.debug("ListenBrainz POST failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Token validation (used by Settings)

    struct ValidateResult: Sendable, Equatable {
        let valid: Bool
        let username: String?
        let message: String
    }

    /// Hit `/1/validate-token` to confirm the user pasted a working
    /// token + capture their username for display. Used by the
    /// Settings "Test connection" button.
    static func validate(token: String, session: URLSession? = nil) async -> ValidateResult {
        let s = session ?? Scrobblers.makeSession()
        var req = URLRequest(url: validateTokenURL)
        req.httpMethod = "GET"
        req.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
        do {
            let (data, resp) = try await s.data(for: req)
            let http = resp as? HTTPURLResponse
            if let http, !(200...299).contains(http.statusCode) {
                return ValidateResult(valid: false, username: nil, message: "HTTP \(http.statusCode)")
            }
            struct Resp: Decodable {
                let valid: Bool?
                let user_name: String?
                let message: String?
                // Older API shape uses `code` for an outer success/fail.
                let code: Int?
            }
            let decoded = (try? JSONDecoder().decode(Resp.self, from: data))
            let valid = decoded?.valid ?? (decoded?.code == 200)
            return ValidateResult(
                valid: valid,
                username: decoded?.user_name,
                message: decoded?.message ?? (valid ? "Token is valid." : "Token is not valid.")
            )
        } catch {
            return ValidateResult(valid: false, username: nil, message: error.localizedDescription)
        }
    }
}
