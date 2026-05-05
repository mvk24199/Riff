import Foundation

/// Native Swift client for YouTube Music's InnerTube endpoints.
///
/// All visible UI in the app is fed by this client. The hidden WKWebView is
/// the audio engine; this client is the data engine. The two share cookies via
/// `WKWebsiteDataStore` ↔ `HTTPCookieStorage`.
///
/// Reference for request shapes:
///   - https://github.com/LuanRT/YouTube.js
///   - https://github.com/sigma67/ytmusicapi (endpoint catalogue)
///
/// Stability notes: every endpoint we depend on has a snapshot fixture in tests.
/// A nightly CI job hits live endpoints with a sentinel account to surface
/// Google-side breakage early.
final class InnerTubeClient: Sendable {
    static let baseURL = URL(string: "https://music.youtube.com/youtubei/v1/")!

    /// Bumped together when Google changes the protocol on us.
    static let clientName = "WEB_REMIX"
    static let clientVersion = "1.20260501.00.00"

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    // MARK: - Public API (stubs — fill in during MVP)

    func browseHome() async throws -> [HomeSection] {
        // POST /browse with browseId="FEmusic_home"
        // Decode the "sectionListRenderer" → "musicCarouselShelfRenderer" path.
        []
    }

    func search(query: String, filter: SearchView.SearchFilter) async throws -> [MediaItem] {
        // POST /search with appropriate params token per filter.
        []
    }

    func library(section: LibraryView.Section) async throws -> [MediaItem] {
        // POST /browse with browseId mapping per section
        // (FEmusic_liked_videos, FEmusic_liked_playlists, FEmusic_library_corpus_track_artists, …)
        []
    }

    func nextQueue(videoId: String, playlistId: String?) async throws -> [MediaItem] {
        // POST /next — returns watchNextRenderer with the autoplay queue
        []
    }

    // MARK: - Request plumbing

    private func post<T: Decodable>(endpoint: Endpoint, body: [String: Any]) async throws -> T {
        var req = URLRequest(url: Self.baseURL.appendingPathComponent(endpoint.rawValue))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("https://music.youtube.com", forHTTPHeaderField: "Origin")
        req.setValue("https://music.youtube.com/", forHTTPHeaderField: "Referer")

        var payload = body
        payload["context"] = [
            "client": [
                "clientName": Self.clientName,
                "clientVersion": Self.clientVersion,
                "hl": Locale.current.language.languageCode?.identifier ?? "en",
                "gl": Locale.current.region?.identifier ?? "US"
            ]
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, _) = try await session.data(for: req)
        return try JSONDecoder().decode(T.self, from: data)
    }
}
