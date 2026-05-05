import Foundation
import Observation

/// Drives the OAuth 2.0 Device Authorization Flow against Google so users can
/// sign in without an embedded webview. The Google YouTube Data scope is
/// what InnerTube needs for personalized endpoints (library, history, likes).
///
/// **Why Device Flow**: Google blocks Google-account sign-in inside any
/// embedded webview as an anti-account-takeover measure. The TV-app-style
/// device flow is the only path that works end-to-end without a real
/// browser embedding — the user enters a 6-character code on
/// google.com/device in their everyday browser, and we poll Google's token
/// endpoint until they confirm.
///
/// **Client identity**: we re-use the public client_id/secret pair shipped
/// with the YouTube TV app. Same approach as `ytmusicapi`, `youtube-music`
/// (th-ch), and most other open-source YT clients. Google publishes these
/// values; they are not secret.
@MainActor
@Observable
final class OAuthDeviceFlow {
    enum State: Equatable {
        case idle
        case requesting
        case awaitingUser(userCode: String, verificationURL: URL)
        case success
        case failure(String)
    }

    private(set) var state: State = .idle

    // YouTube TV client (same one ytmusicapi documents). Public values.
    private static let clientId     = "861556708454-d6dlm3lh05idd8npek18k6be8ba3oc68.apps.googleusercontent.com"
    private static let clientSecret = "SboVhoG9s0rNafixCSGGKXAT"
    private static let scope        = "https://www.googleapis.com/auth/youtube"

    private static let deviceCodeURL = URL(string: "https://oauth2.googleapis.com/device/code")!
    private static let tokenURL      = URL(string: "https://oauth2.googleapis.com/token")!

    private var pollingTask: Task<Void, Never>?

    func start() async {
        cancel()
        state = .requesting
        do {
            let resp = try await requestDeviceCode()
            guard let url = URL(string: resp.verification_url) else {
                state = .failure("Invalid verification URL")
                return
            }
            state = .awaitingUser(userCode: resp.user_code, verificationURL: url)
            pollingTask = Task { [weak self] in
                await self?.pollForToken(deviceCode: resp.device_code, interval: resp.interval, expiresIn: resp.expires_in)
            }
        } catch {
            state = .failure(error.localizedDescription)
        }
    }

    func cancel() {
        pollingTask?.cancel()
        pollingTask = nil
        if case .awaitingUser = state { state = .idle }
    }

    static func signOut() {
        OAuthTokens.clear()
    }

    /// Refresh an expired access token using the stored refresh token.
    /// Returns the new access token, or nil if refresh failed (caller should
    /// then prompt the user to sign in again).
    static func refreshIfNeeded() async -> String? {
        guard let current = OAuthTokens.load() else { return nil }
        if !current.isExpired { return current.accessToken }
        guard let refreshToken = current.refreshToken else { return nil }
        do {
            let resp = try await refresh(token: refreshToken)
            let new = OAuthTokens(
                accessToken: resp.access_token,
                refreshToken: refreshToken,  // Google omits this on refresh; keep the original
                expiresAt: Date().addingTimeInterval(TimeInterval(resp.expires_in))
            )
            try new.save()
            return new.accessToken
        } catch {
            return nil
        }
    }

    // MARK: - Private

    private struct DeviceCodeResponse: Decodable {
        let device_code: String
        let user_code: String
        let verification_url: String
        let expires_in: Int
        let interval: Int
    }

    private struct TokenResponse: Decodable {
        let access_token: String
        let refresh_token: String?
        let expires_in: Int
    }

    private struct ErrorResponse: Decodable {
        let error: String
    }

    private struct RefreshResponse: Decodable {
        let access_token: String
        let expires_in: Int
    }

    private func requestDeviceCode() async throws -> DeviceCodeResponse {
        var req = URLRequest(url: Self.deviceCodeURL)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = formEncode([
            "client_id": Self.clientId,
            "scope": Self.scope,
        ])
        let (data, _) = try await URLSession.shared.data(for: req)
        return try JSONDecoder().decode(DeviceCodeResponse.self, from: data)
    }

    private func pollForToken(deviceCode: String, interval: Int, expiresIn: Int) async {
        let deadline = Date().addingTimeInterval(TimeInterval(expiresIn))
        while !Task.isCancelled, Date() < deadline {
            do {
                try await Task.sleep(nanoseconds: UInt64(interval) * NSEC_PER_SEC)
            } catch { return }
            do {
                var req = URLRequest(url: Self.tokenURL)
                req.httpMethod = "POST"
                req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                req.httpBody = formEncode([
                    "client_id": Self.clientId,
                    "client_secret": Self.clientSecret,
                    "code": deviceCode,
                    "grant_type": "http://oauth.net/grant_type/device/1.0",
                ])
                let (data, response) = try await URLSession.shared.data(for: req)
                let http = response as? HTTPURLResponse
                if http?.statusCode == 200, let token = try? JSONDecoder().decode(TokenResponse.self, from: data) {
                    let tokens = OAuthTokens(
                        accessToken: token.access_token,
                        refreshToken: token.refresh_token,
                        expiresAt: Date().addingTimeInterval(TimeInterval(token.expires_in))
                    )
                    try tokens.save()
                    state = .success
                    return
                }
                if let err = try? JSONDecoder().decode(ErrorResponse.self, from: data) {
                    switch err.error {
                    case "authorization_pending", "slow_down":
                        continue  // expected — keep polling
                    case "access_denied":
                        state = .failure("Sign-in was denied")
                        return
                    case "expired_token":
                        state = .failure("Code expired. Please try again.")
                        return
                    default:
                        state = .failure(err.error)
                        return
                    }
                }
            } catch {
                // Transient network blip; the loop will retry.
                continue
            }
        }
        if !Task.isCancelled {
            state = .failure("Sign-in timed out. Please try again.")
        }
    }

    private static func refresh(token: String) async throws -> RefreshResponse {
        var req = URLRequest(url: tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = formEncode([
            "client_id": clientId,
            "client_secret": clientSecret,
            "refresh_token": token,
            "grant_type": "refresh_token",
        ])
        let (data, _) = try await URLSession.shared.data(for: req)
        return try JSONDecoder().decode(RefreshResponse.self, from: data)
    }
}

private func formEncode(_ pairs: [String: String]) -> Data {
    let encoded = pairs.map { k, v in
        let ke = k.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? k
        let ve = v.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? v
        return "\(ke)=\(ve)"
    }.joined(separator: "&")
    return Data(encoded.utf8)
}
