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

    /// When we attach a Bearer token from Device Flow, the audience of that
    /// token is the YouTube TV client (`861556708454-...`) — InnerTube
    /// rejects `WEB_REMIX + Bearer` as INVALID_ARGUMENT because the
    /// clientName doesn't match the token's origin. Switching to the TV
    /// client identifiers lets InnerTube accept the combination.
    static let tvClientName = "TVHTML5_SIMPLY_EMBEDDED_PLAYER"
    static let tvClientVersion = "2.0"
    static let tvClientNameID = "85"

    /// Pretend to be Chrome on macOS. YouTube Music gates its web app
    /// (and several InnerTube endpoints) to Chrome — Safari/WebKit gets a
    /// "not optimized for your browser" interstitial. We use the same UA
    /// across the InnerTube HTTP client, the sign-in WKWebView, and the
    /// hidden audio WKWebView so the three are indistinguishable to YT.
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    enum InnerTubeError: Error {
        case http(Int)
        case decoding
        case needsReauth  // 401 / Cloudflare CAPTCHA — re-present sign-in sheet.
        case dataAPINotEnabled  // Library needs custom OAuth credentials with Data API v3 enabled.
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

        let results: [MediaItem] = shelves.flatMap { shelf -> [MediaItem] in
            // Try each known shelf shape. List-shaped shelves
            // (musicShelfRenderer) hold rows; grid-shaped (gridRenderer) and
            // carousel-shaped (musicCarouselShelfRenderer) hold tiles. Album
            // results in particular sometimes come back in a card shelf.
            if let items = Parsing.array(shelf, "musicShelfRenderer", "contents") {
                return items.compactMap(Self.parseListItem)
            }
            if let items = Parsing.array(shelf, "musicCardShelfRenderer", "contents") {
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

        Log.innertube.debug("search filter=\(String(describing: filter), privacy: .public) shelves=\(shelves.count) results=\(results.count)")
        if results.isEmpty, !shelves.isEmpty {
            for (i, shelf) in shelves.enumerated() {
                Log.innertube.debug("  search shelf[\(i)] keys=\(Array(shelf.keys), privacy: .public)")
            }
        }
        return results
    }

    /// Library contents — InnerTube `/browse` with the section-specific
    /// browseId. Auth comes from the SAPISID cookie set by the WebView
    /// sign-in (Kaset's pattern); without it the response is anonymous
    /// and library sections come back empty.
    func library(section: LibraryView.Section) async throws -> [MediaItem] {
        let browseId: String
        switch section {
        case .liked:     browseId = BrowseID.likedSongs
        case .playlists: browseId = BrowseID.likedPlaylists
        case .albums:    browseId = BrowseID.libraryAlbums
        case .artists:   browseId = BrowseID.libraryArtists
        case .podcasts:  browseId = BrowseID.libraryPodcasts
        }
        Log.innertube.debug("library section=\(String(describing: section), privacy: .public) browseId=\(browseId, privacy: .public)")
        let body = try await postRaw(.browse, body: ["browseId": browseId])
        let shelves = Parsing.array(body, "contents",
            "singleColumnBrowseResultsRenderer", "tabs", "0", "tabRenderer",
            "content", "sectionListRenderer", "contents") ?? []
        let results = shelves.flatMap { shelf -> [MediaItem] in
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
        Log.innertube.debug("library section=\(String(describing: section), privacy: .public) shelves=\(shelves.count) results=\(results.count)")
        if results.isEmpty, !shelves.isEmpty {
            Log.innertube.debug("  library empty: shelf[0] keys=\(Array(shelves[0].keys), privacy: .public)")
        }
        return results
    }

    // MARK: - YouTube Data API v3 (Bearer auth, googleapis.com)

    private static let dataAPIBase = URL(string: "https://www.googleapis.com/youtube/v3/")!

    /// `playlistItems?playlistId=LL` — "LL" is YouTube's special ID for the
    /// signed-in user's Liked Videos playlist.
    private func likedVideos() async throws -> [MediaItem] {
        let resp = try await dataAPI("playlistItems", params: [
            "playlistId": "LL",
            "part": "snippet,contentDetails",
            "maxResults": "50",
        ])
        let items = (resp["items"] as? [[String: Any]]) ?? []
        return items.compactMap { item -> MediaItem? in
            let snippet = item["snippet"] as? [String: Any]
            let videoId = (item["contentDetails"] as? [String: Any])?["videoId"] as? String
                ?? (snippet?["resourceId"] as? [String: Any])?["videoId"] as? String
            guard let videoId else { return nil }
            let title = snippet?["title"] as? String ?? ""
            let artist = snippet?["videoOwnerChannelTitle"] as? String
                ?? snippet?["channelTitle"] as? String ?? ""
            let thumb = Self.dataAPIThumbnail(snippet?["thumbnails"] as? [String: Any])
            return MediaItem(id: videoId, kind: .song, title: title, subtitle: artist, thumbnailURL: thumb)
        }
    }

    private func myPlaylists() async throws -> [MediaItem] {
        let resp = try await dataAPI("playlists", params: [
            "mine": "true",
            "part": "snippet,contentDetails",
            "maxResults": "50",
        ])
        let items = (resp["items"] as? [[String: Any]]) ?? []
        return items.compactMap { item -> MediaItem? in
            guard let id = item["id"] as? String else { return nil }
            let snippet = item["snippet"] as? [String: Any]
            let title = snippet?["title"] as? String ?? ""
            let count = (item["contentDetails"] as? [String: Any])?["itemCount"] as? Int ?? 0
            let subtitle = count > 0 ? "\(count) tracks" : (snippet?["channelTitle"] as? String ?? "")
            let thumb = Self.dataAPIThumbnail(snippet?["thumbnails"] as? [String: Any])
            return MediaItem(id: id, kind: .playlist, title: title, subtitle: subtitle, thumbnailURL: thumb)
        }
    }

    private func mySubscriptions() async throws -> [MediaItem] {
        let resp = try await dataAPI("subscriptions", params: [
            "mine": "true",
            "part": "snippet",
            "maxResults": "50",
        ])
        let items = (resp["items"] as? [[String: Any]]) ?? []
        return items.compactMap { item -> MediaItem? in
            let snippet = item["snippet"] as? [String: Any]
            let resourceId = snippet?["resourceId"] as? [String: Any]
            guard let channelId = resourceId?["channelId"] as? String else { return nil }
            let title = snippet?["title"] as? String ?? ""
            let thumb = Self.dataAPIThumbnail(snippet?["thumbnails"] as? [String: Any])
            return MediaItem(id: channelId, kind: .artist, title: title, subtitle: "Channel", thumbnailURL: thumb)
        }
    }

    /// Pick the highest-resolution thumbnail from Data API v3's
    /// `{default, medium, high, standard, maxres}` shape.
    private static func dataAPIThumbnail(_ thumbs: [String: Any]?) -> URL? {
        guard let thumbs else { return nil }
        for key in ["maxres", "standard", "high", "medium", "default"] {
            if let t = thumbs[key] as? [String: Any], let url = t["url"] as? String, let u = URL(string: url) {
                return u
            }
        }
        return nil
    }

    /// GET against `googleapis.com/youtube/v3/<path>` with the OAuth
    /// Bearer token. Throws `needsReauth` on 401/403 so the UI can
    /// re-present the sign-in sheet.
    private func dataAPI(_ path: String, params: [String: String]) async throws -> [String: Any] {
        guard let token = await OAuthDeviceFlow.refreshIfNeeded() else {
            throw InnerTubeError.needsReauth
        }
        var components = URLComponents(url: Self.dataAPIBase.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        components.queryItems = params.map { URLQueryItem(name: $0.key, value: $0.value) }
        var req = URLRequest(url: components.url!)
        req.httpMethod = "GET"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        Log.innertube.debug("→ data/v3/\(path, privacy: .public) auth=bearer")

        let (data, response) = try await session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if !(200..<300).contains(status) {
            let preview = String(data: data, encoding: .utf8)?.prefix(400) ?? ""
            Log.innertube.error("← data/v3/\(path, privacy: .public) status=\(status) body=\(preview, privacy: .public)")
            if status == 401 || status == 403 { throw InnerTubeError.needsReauth }
            throw InnerTubeError.http(status)
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw InnerTubeError.decoding
        }
        return json
    }

    /// Resolve a browseId (album / podcast / artist) into a playable
    /// `(videoId?, playlistId?)` tuple. The page auto-plays when we
    /// navigate to `/watch` with at least one of those set.
    ///
    /// Strategy:
    ///  1. Album/podcast pages expose the audio playlist via
    ///     `microformat.microformatDataRenderer.urlCanonical` =
    ///     `https://music.youtube.com/playlist?list=<id>`. That's the
    ///     canonical "play this thing" pointer — most reliable.
    ///  2. Some artist pages instead carry a `/watch?v=&list=` canonical.
    ///  3. As a last resort, recursive watchEndpoint scan. This is fragile
    ///     because the first match might be a sidebar suggestion rather
    ///     than the page's primary content; we use it only when 1+2 fail.
    func playable(forBrowseId browseId: String) async throws -> (videoId: String?, playlistId: String?)? {
        let body = try await postRaw(.browse, body: ["browseId": browseId])

        // 1+2: microformat urlCanonical
        if let canonical = Parsing.string(body, "microformat", "microformatDataRenderer", "urlCanonical"),
           let url = URLComponents(string: canonical) {
            let v = url.queryItems?.first(where: { $0.name == "v" })?.value
            let pl = url.queryItems?.first(where: { $0.name == "list" })?.value
            if v != nil || pl != nil {
                return (v, pl)
            }
        }

        // 3: recursive fallback
        if let (vid, pid) = Self.findFirstWatchEndpoint(body) {
            return (vid, pid)
        }
        return nil
    }

    /// Strip a leading "VL" — that's the YT Music convention for a
    /// playlist *browse* ID (`VL<playlistId>`); the playable ID is the
    /// suffix.
    private static func unwrapVLPrefix(_ id: String) -> String {
        id.hasPrefix("VL") ? String(id.dropFirst(2)) : id
    }

    private static func findFirstWatchEndpoint(_ root: Any?) -> (String, String?)? {
        if let dict = root as? [String: Any] {
            if let watch = dict["watchEndpoint"] as? [String: Any],
               let vid = watch["videoId"] as? String {
                return (vid, watch["playlistId"] as? String)
            }
            for (_, v) in dict {
                if let r = findFirstWatchEndpoint(v) { return r }
            }
        }
        if let arr = root as? [Any] {
            for v in arr {
                if let r = findFirstWatchEndpoint(v) { return r }
            }
        }
        return nil
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

        // Songs put the navigation on the title cell's first run
        // (watchEndpoint, "click the title to play"). Albums / artists /
        // playlists put it at the row level (browseEndpoint, "click the row
        // to open the page"). Try cell first, then row.
        let titleEndpoint = Parsing.dig(cols.first, ["musicResponsiveListItemFlexColumnRenderer", "text", "runs", "0", "navigationEndpoint"]) as? [String: Any]
        let rowEndpoint = r["navigationEndpoint"] as? [String: Any]
        guard let resolved = endpointToIdKind(titleEndpoint) ?? endpointToIdKind(rowEndpoint) else { return nil }
        let (id, kind) = resolved
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
            case "MUSIC_PAGE_TYPE_PLAYLIST":          return (Self.unwrapVLPrefix(browseId), .playlist)
            default:
                if browseId.hasPrefix("MPRE") { return (browseId, .album) }   // album browseId pattern
                if browseId.hasPrefix("UC") || browseId.hasPrefix("UCMO") { return (browseId, .artist) }
                if browseId.hasPrefix("VL") || browseId.hasPrefix("PL") { return (Self.unwrapVLPrefix(browseId), .playlist) }
                return nil
            }
        }
        return nil
    }

    // MARK: - Request plumbing

    private func postRaw(_ endpoint: Endpoint, body: [String: Any]) async throws -> [String: Any] {
        // SAPISIDHASH cookie auth when we have a SAPISID cookie (set by
        // the WebView sign-in — Kaset's pattern). Otherwise anonymous.
        // OAuth Bearer is *not* attached: empirically InnerTube returns
        // 400 INVALID_ARGUMENT for every Bearer-authed request regardless
        // of clientName claimed.
        var req = URLRequest(url: Self.baseURL.appendingPathComponent(endpoint.rawValue))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(Self.origin, forHTTPHeaderField: "Origin")
        req.setValue("\(Self.origin)/", forHTTPHeaderField: "Referer")
        req.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue(Self.clientNameID, forHTTPHeaderField: "X-YouTube-Client-Name")
        req.setValue(Self.clientVersion, forHTTPHeaderField: "X-YouTube-Client-Version")
        req.setValue("0", forHTTPHeaderField: "X-Goog-AuthUser")

        let authMode: String
        if let sapisid = Self.sapisidHashAuthHeader() {
            req.setValue(sapisid, forHTTPHeaderField: "Authorization")
            authMode = "sapisid"
        } else {
            authMode = "anonymous"
        }
        Log.innertube.debug("→ \(endpoint.rawValue, privacy: .public) auth=\(authMode, privacy: .public)")

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
            if !(200..<300).contains(http.statusCode) {
                let preview = String(data: data, encoding: .utf8)?.prefix(400) ?? ""
                Log.innertube.error("← \(endpoint.rawValue, privacy: .public) status=\(http.statusCode) auth=\(authMode, privacy: .public) body=\(preview, privacy: .public)")
                if http.statusCode == 401 || http.statusCode == 403 { throw InnerTubeError.needsReauth }
                throw InnerTubeError.http(http.statusCode)
            }
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw InnerTubeError.decoding
        }
        return json
    }

    /// `Bearer <access_token>` if we have a valid OAuth token (or can
    /// refresh the stored one). Async because refresh hits the network.
    private static func bearerAuthHeader() async -> String? {
        guard let token = await OAuthDeviceFlow.refreshIfNeeded() else { return nil }
        return "Bearer \(token)"
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
