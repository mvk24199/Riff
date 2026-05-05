import Foundation
import CryptoKit

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
/// Stability notes: every endpoint we depend on has a snapshot fixture in
/// tests. A nightly CI job hits live endpoints with a sentinel account to
/// surface Google-side breakage early.
final class InnerTubeClient: Sendable {
    static let baseURL = URL(string: "https://music.youtube.com/youtubei/v1/")!
    static let origin = "https://music.youtube.com"

    /// Bumped together when Google changes the protocol on us.
    static let clientName = "WEB_REMIX"
    static let clientVersion = "1.20260501.00.00"
    static let clientNameID = "67"  // X-YouTube-Client-Name for WEB_REMIX

    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    enum InnerTubeError: Error {
        case http(Int)
        case decoding
        case needsReauth  // 401 / Cloudflare CAPTCHA — re-present sign-in sheet.
    }

    // MARK: - Public API

    func browseHome() async throws -> [HomeSection] {
        let body = try await postRaw(.browse, body: ["browseId": BrowseID.home])
        let shelves = Parsing.array(body, "contents",
            "singleColumnBrowseResultsRenderer", "tabs", "0", "tabRenderer",
            "content", "sectionListRenderer", "contents") ?? []
        return shelves.compactMap(Self.parseHomeShelf)
    }

    func search(query: String, filter: SearchView.SearchFilter) async throws -> [MediaItem] {
        var payload: [String: Any] = ["query": query]
        if let token = filter.paramsToken { payload["params"] = token }
        let body = try await postRaw(.search, body: payload)
        let shelves = Parsing.array(body, "contents",
            "tabbedSearchResultsRenderer", "tabs", "0", "tabRenderer",
            "content", "sectionListRenderer", "contents") ?? []
        return shelves.flatMap { shelf -> [MediaItem] in
            let items = Parsing.array(shelf, "musicShelfRenderer", "contents") ?? []
            return items.compactMap(Self.parseListItem)
        }
    }

    func library(section: LibraryView.Section) async throws -> [MediaItem] {
        let browseId: String
        switch section {
        case .liked:     browseId = BrowseID.likedSongs
        case .playlists: browseId = BrowseID.likedPlaylists
        case .albums:    browseId = BrowseID.libraryAlbums
        case .artists:   browseId = BrowseID.libraryArtists
        case .podcasts:  browseId = BrowseID.libraryPodcasts
        }
        let body = try await postRaw(.browse, body: ["browseId": browseId])
        let shelves = Parsing.array(body, "contents",
            "singleColumnBrowseResultsRenderer", "tabs", "0", "tabRenderer",
            "content", "sectionListRenderer", "contents") ?? []
        return shelves.flatMap { shelf -> [MediaItem] in
            // Liked Songs → musicShelfRenderer (list); Playlists/Albums →
            // gridRenderer (tiles). Try both shapes.
            if let items = Parsing.array(shelf, "musicShelfRenderer", "contents") {
                return items.compactMap(Self.parseListItem)
            }
            if let items = Parsing.array(shelf, "gridRenderer", "items") {
                return items.compactMap(Self.parseTwoRowItem)
            }
            if let items = Parsing.array(shelf, "musicCarouselShelfRenderer", "contents") {
                return items.compactMap(Self.parseTwoRowItem)
            }
            return []
        }
    }

    func nextQueue(videoId: String, playlistId: String?) async throws -> [MediaItem] {
        var payload: [String: Any] = ["videoId": videoId]
        if let pid = playlistId { payload["playlistId"] = pid }
        let body = try await postRaw(.next, body: payload)
        let items = Parsing.array(body, "contents",
            "singleColumnMusicWatchNextResultsRenderer", "tabbedRenderer",
            "watchNextTabbedResultsRenderer", "tabs", "0", "tabRenderer",
            "content", "musicQueueRenderer", "content", "playlistPanelRenderer",
            "contents") ?? []
        return items.compactMap { item -> MediaItem? in
            guard let r = item["playlistPanelVideoRenderer"] as? [String: Any] else { return nil }
            let videoId = Parsing.string(r, "videoId") ?? ""
            guard !videoId.isEmpty else { return nil }
            let title = Parsing.runs(r, "title") ?? ""
            let subtitle = Parsing.runs(r, "longBylineText") ?? Parsing.runs(r, "shortBylineText") ?? ""
            let thumb = Parsing.thumbnailURL(r["thumbnail"] as? [String: Any])
            return MediaItem(id: videoId, kind: .song, title: title, subtitle: subtitle, thumbnailURL: thumb)
        }
    }

    // MARK: - Parse helpers (private)

    /// `musicCarouselShelfRenderer` → `HomeSection`.
    private static func parseHomeShelf(_ shelf: [String: Any]) -> HomeSection? {
        guard let r = shelf["musicCarouselShelfRenderer"] as? [String: Any] else { return nil }
        let title = Parsing.runs(r, "header", "musicCarouselShelfBasicHeaderRenderer", "title") ?? ""
        let contents = r["contents"] as? [[String: Any]] ?? []
        let items = contents.compactMap(parseTwoRowItem)
        guard !items.isEmpty else { return nil }
        return HomeSection(id: title.isEmpty ? UUID().uuidString : title, title: title, items: items)
    }

    /// `musicResponsiveListItemRenderer` (list rows in search/liked songs).
    private static func parseListItem(_ wrapper: [String: Any]) -> MediaItem? {
        guard let r = wrapper["musicResponsiveListItemRenderer"] as? [String: Any] else { return nil }
        let cols = r["flexColumns"] as? [[String: Any]] ?? []
        let title = Parsing.runs(cols.first, "musicResponsiveListItemFlexColumnRenderer", "text") ?? ""
        let subtitle = cols.count > 1
            ? (Parsing.runs(cols[1], "musicResponsiveListItemFlexColumnRenderer", "text") ?? "")
            : ""

        // Determine kind + id from the navigationEndpoint of the title cell.
        let endpoint = Parsing.dig(cols.first, ["musicResponsiveListItemFlexColumnRenderer", "text", "runs", "0", "navigationEndpoint"]) as? [String: Any]
        guard let (id, kind) = endpointToIdKind(endpoint) else { return nil }
        let thumb = Parsing.thumbnailURL(Parsing.dig(r, ["thumbnail", "musicThumbnailRenderer", "thumbnail"]) as? [String: Any])
        return MediaItem(id: id, kind: kind, title: title, subtitle: subtitle, thumbnailURL: thumb)
    }

    /// `musicTwoRowItemRenderer` (carousel tiles in home / library grids).
    private static func parseTwoRowItem(_ wrapper: [String: Any]) -> MediaItem? {
        guard let r = wrapper["musicTwoRowItemRenderer"] as? [String: Any] else { return nil }
        let title = Parsing.runs(r, "title") ?? ""
        let subtitle = Parsing.runs(r, "subtitle") ?? ""
        let endpoint = r["navigationEndpoint"] as? [String: Any]
        guard let (id, kind) = endpointToIdKind(endpoint) else { return nil }
        let thumb = Parsing.thumbnailURL(Parsing.dig(r, ["thumbnailRenderer", "musicThumbnailRenderer", "thumbnail"]) as? [String: Any])
        return MediaItem(id: id, kind: kind, title: title, subtitle: subtitle, thumbnailURL: thumb)
    }

    /// Map a navigationEndpoint to (id, kind). Returns nil if we don't
    /// recognise the endpoint shape.
    private static func endpointToIdKind(_ endpoint: [String: Any]?) -> (String, MediaItem.Kind)? {
        guard let endpoint else { return nil }
        if let watch = endpoint["watchEndpoint"] as? [String: Any],
           let videoId = watch["videoId"] as? String {
            return (videoId, .song)
        }
        if let watchPL = endpoint["watchPlaylistEndpoint"] as? [String: Any],
           let pid = watchPL["playlistId"] as? String {
            return (pid, .playlist)
        }
        if let browse = endpoint["browseEndpoint"] as? [String: Any],
           let browseId = browse["browseId"] as? String {
            let pageType = (Parsing.dig(browse, ["browseEndpointContextSupportedConfigs",
                                                 "browseEndpointContextMusicConfig",
                                                 "pageType"]) as? String) ?? ""
            switch pageType {
            case "MUSIC_PAGE_TYPE_ALBUM":             return (browseId, .album)
            case "MUSIC_PAGE_TYPE_ARTIST":            return (browseId, .artist)
            case "MUSIC_PAGE_TYPE_PODCAST_SHOW_DETAIL_PAGE": return (browseId, .podcast)
            case "MUSIC_PAGE_TYPE_PLAYLIST":          return (browseId, .playlist)
            default:
                if browseId.hasPrefix("MPRE") { return (browseId, .album) }   // album browseId pattern
                if browseId.hasPrefix("UC") || browseId.hasPrefix("UCMO") { return (browseId, .artist) }
                if browseId.hasPrefix("VL") || browseId.hasPrefix("PL") { return (browseId, .playlist) }
                return nil
            }
        }
        return nil
    }

    // MARK: - Request plumbing

    private func postRaw(_ endpoint: Endpoint, body: [String: Any]) async throws -> [String: Any] {
        var req = URLRequest(url: Self.baseURL.appendingPathComponent(endpoint.rawValue))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(Self.origin, forHTTPHeaderField: "Origin")
        req.setValue("\(Self.origin)/", forHTTPHeaderField: "Referer")
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue(Self.clientNameID, forHTTPHeaderField: "X-YouTube-Client-Name")
        req.setValue(Self.clientVersion, forHTTPHeaderField: "X-YouTube-Client-Version")
        req.setValue("0", forHTTPHeaderField: "X-Goog-AuthUser")
        if let auth = Self.sapisidHashAuthHeader() {
            req.setValue(auth, forHTTPHeaderField: "Authorization")
        }

        var payload = body
        payload["context"] = [
            "client": [
                "clientName": Self.clientName,
                "clientVersion": Self.clientVersion,
                "hl": Locale.current.language.languageCode?.identifier ?? "en",
                "gl": Locale.current.region?.identifier ?? "US",
            ],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await session.data(for: req)
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 401 || http.statusCode == 403 { throw InnerTubeError.needsReauth }
            guard (200..<300).contains(http.statusCode) else { throw InnerTubeError.http(http.statusCode) }
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw InnerTubeError.decoding
        }
        return json
    }

    /// SAPISIDHASH `<ts>_<sha1(ts + " " + sapisid + " " + origin)>` per
    /// google.com auth scheme. Required for signed-in endpoints (library);
    /// returns nil if no SAPISID cookie exists yet (pre-sign-in).
    private static func sapisidHashAuthHeader() -> String? {
        let sapisid = HTTPCookieStorage.shared.cookies?.first(where: { $0.name == "SAPISID" })?.value
            ?? HTTPCookieStorage.shared.cookies?.first(where: { $0.name == "__Secure-3PAPISID" })?.value
        guard let sapisid else { return nil }
        let ts = String(Int(Date().timeIntervalSince1970))
        let raw = "\(ts) \(sapisid) \(Self.origin)"
        let hash = Insecure.SHA1.hash(data: Data(raw.utf8))
        let hex = hash.map { String(format: "%02x", $0) }.joined()
        return "SAPISIDHASH \(ts)_\(hex)"
    }
}
