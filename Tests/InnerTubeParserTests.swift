import XCTest
@testable import Riff

/// Fixture-based tests for `InnerTubeClient`'s renderer-walking parsers.
///
/// The fixtures are hand-crafted minimal JSON dictionaries that mimic
/// the shape YT Music actually returns — small enough to inspect at a
/// glance, structured enough that a real protocol break (renderer key
/// rename, navigation-endpoint reshape) trips a test failure.
///
/// We test the static parser entrypoints directly (`parseListItem`,
/// `parseTwoRowItem`, `parseHomeShelf`, `endpointToIdKind`) rather
/// than going through `URLSession` — there's no value in mocking
/// the network for tests that exist to detect renderer drift.
final class InnerTubeParserTests: XCTestCase {

    // MARK: - endpointToIdKind

    func testWatchEndpointMapsToSong() {
        let endpoint: [String: Any] = ["watchEndpoint": ["videoId": "abc123"]]
        let resolved = InnerTubeClient.endpointToIdKind(endpoint)
        XCTAssertEqual(resolved?.0, "abc123")
        XCTAssertEqual(resolved?.1, .song)
    }

    func testBrowseEndpointAlbumPageType() {
        let endpoint: [String: Any] = [
            "browseEndpoint": [
                "browseId": "MPREb_test",
                "browseEndpointContextSupportedConfigs": [
                    "browseEndpointContextMusicConfig": [
                        "pageType": "MUSIC_PAGE_TYPE_ALBUM"
                    ]
                ]
            ]
        ]
        let resolved = InnerTubeClient.endpointToIdKind(endpoint)
        XCTAssertEqual(resolved?.0, "MPREb_test")
        XCTAssertEqual(resolved?.1, .album)
    }

    func testBrowseEndpointArtistPageType() {
        let endpoint: [String: Any] = [
            "browseEndpoint": [
                "browseId": "UC_test",
                "browseEndpointContextSupportedConfigs": [
                    "browseEndpointContextMusicConfig": [
                        "pageType": "MUSIC_PAGE_TYPE_ARTIST"
                    ]
                ]
            ]
        ]
        let resolved = InnerTubeClient.endpointToIdKind(endpoint)
        XCTAssertEqual(resolved?.0, "UC_test")
        XCTAssertEqual(resolved?.1, .artist)
    }

    /// Playlist browseIds come back as `VL<plid>`. The parser strips
    /// the VL prefix so the resulting MediaItem.id is the playable id.
    func testBrowseEndpointPlaylistStripsVLPrefix() {
        let endpoint: [String: Any] = [
            "browseEndpoint": [
                "browseId": "VLPLtest123",
                "browseEndpointContextSupportedConfigs": [
                    "browseEndpointContextMusicConfig": [
                        "pageType": "MUSIC_PAGE_TYPE_PLAYLIST"
                    ]
                ]
            ]
        ]
        let resolved = InnerTubeClient.endpointToIdKind(endpoint)
        XCTAssertEqual(resolved?.0, "PLtest123")
        XCTAssertEqual(resolved?.1, .playlist)
    }

    /// Heuristic fallback when YT omits the pageType — id-prefix sniff.
    func testBrowseEndpointFallsBackToIdPrefix() {
        let endpoint: [String: Any] = [
            "browseEndpoint": ["browseId": "MPREb_xyz"]
        ]
        let resolved = InnerTubeClient.endpointToIdKind(endpoint)
        XCTAssertEqual(resolved?.0, "MPREb_xyz")
        XCTAssertEqual(resolved?.1, .album)
    }

    func testNilEndpointReturnsNil() {
        XCTAssertNil(InnerTubeClient.endpointToIdKind(nil))
        XCTAssertNil(InnerTubeClient.endpointToIdKind([:]))
    }

    // MARK: - parseListItem (search / library row)

    func testParseListItemSongRow() {
        let row: [String: Any] = [
            "musicResponsiveListItemRenderer": [
                "flexColumns": [
                    [
                        "musicResponsiveListItemFlexColumnRenderer": [
                            "text": [
                                "runs": [[
                                    "text": "Hello",
                                    "navigationEndpoint": [
                                        "watchEndpoint": ["videoId": "song123"]
                                    ]
                                ]]
                            ]
                        ]
                    ],
                    [
                        "musicResponsiveListItemFlexColumnRenderer": [
                            "text": [
                                "runs": [
                                    [
                                        "text": "Adele",
                                        "navigationEndpoint": [
                                            "browseEndpoint": [
                                                "browseId": "UCadele",
                                                "browseEndpointContextSupportedConfigs": [
                                                    "browseEndpointContextMusicConfig": [
                                                        "pageType": "MUSIC_PAGE_TYPE_ARTIST"
                                                    ]
                                                ]
                                            ]
                                        ]
                                    ],
                                    ["text": " • "],
                                    [
                                        "text": "25",
                                        "navigationEndpoint": [
                                            "browseEndpoint": [
                                                "browseId": "MPREb_25",
                                                "browseEndpointContextSupportedConfigs": [
                                                    "browseEndpointContextMusicConfig": [
                                                        "pageType": "MUSIC_PAGE_TYPE_ALBUM"
                                                    ]
                                                ]
                                            ]
                                        ]
                                    ]
                                ]
                            ]
                        ]
                    ]
                ]
            ]
        ]
        let item = InnerTubeClient.parseListItem(row)
        XCTAssertEqual(item?.id, "song123")
        XCTAssertEqual(item?.kind, .song)
        XCTAssertEqual(item?.title, "Hello")
        XCTAssertEqual(item?.artistId, "UCadele",
            "Artist run's browseId should be lifted into MediaItem.artistId")
        XCTAssertEqual(item?.albumId, "MPREb_25",
            "Album run's browseId should be lifted into MediaItem.albumId")
    }

    /// "Go to album / Go to artist" only show up on context menus when
    /// the parser surfaced these IDs, so this is the high-signal test
    /// that protects that whole feature.
    func testParseListItemMissingFlexColumnEndpointsFallsBackToMenu() {
        let row: [String: Any] = [
            "musicResponsiveListItemRenderer": [
                "flexColumns": [
                    [
                        "musicResponsiveListItemFlexColumnRenderer": [
                            "text": [
                                "runs": [[
                                    "text": "Some Song",
                                    "navigationEndpoint": [
                                        "watchEndpoint": ["videoId": "vidx"]
                                    ]
                                ]]
                            ]
                        ]
                    ]
                ],
                "menu": [
                    "menuRenderer": [
                        "items": [
                            [
                                "menuNavigationItemRenderer": [
                                    "navigationEndpoint": [
                                        "browseEndpoint": [
                                            "browseId": "UCfromMenu",
                                            "browseEndpointContextSupportedConfigs": [
                                                "browseEndpointContextMusicConfig": [
                                                    "pageType": "MUSIC_PAGE_TYPE_ARTIST"
                                                ]
                                            ]
                                        ]
                                    ]
                                ]
                            ]
                        ]
                    ]
                ]
            ]
        ]
        let item = InnerTubeClient.parseListItem(row)
        XCTAssertEqual(item?.artistId, "UCfromMenu",
            "Menu fallback must pick up artist when flexColumns don't")
    }

    // MARK: - parseTwoRowItem (carousel tile)

    func testParseTwoRowItemTileWithSubtitleEndpoints() {
        let tile: [String: Any] = [
            "musicTwoRowItemRenderer": [
                "title": ["runs": [["text": "Levitating"]]],
                "subtitle": [
                    "runs": [
                        [
                            "text": "Dua Lipa",
                            "navigationEndpoint": [
                                "browseEndpoint": [
                                    "browseId": "UCdua",
                                    "browseEndpointContextSupportedConfigs": [
                                        "browseEndpointContextMusicConfig": [
                                            "pageType": "MUSIC_PAGE_TYPE_ARTIST"
                                        ]
                                    ]
                                ]
                            ]
                        ],
                        ["text": " • "],
                        [
                            "text": "Future Nostalgia",
                            "navigationEndpoint": [
                                "browseEndpoint": [
                                    "browseId": "MPREb_fn",
                                    "browseEndpointContextSupportedConfigs": [
                                        "browseEndpointContextMusicConfig": [
                                            "pageType": "MUSIC_PAGE_TYPE_ALBUM"
                                        ]
                                    ]
                                ]
                            ]
                        ]
                    ]
                ],
                "navigationEndpoint": ["watchEndpoint": ["videoId": "lev123"]]
            ]
        ]
        let item = InnerTubeClient.parseTwoRowItem(tile)
        XCTAssertEqual(item?.id, "lev123")
        XCTAssertEqual(item?.kind, .song)
        XCTAssertEqual(item?.title, "Levitating")
        XCTAssertEqual(item?.subtitle, "Dua Lipa • Future Nostalgia")
        XCTAssertEqual(item?.artistId, "UCdua")
        XCTAssertEqual(item?.albumId, "MPREb_fn")
    }

    func testParseTwoRowItemReturnsNilOnMissingNavigation() {
        let tile: [String: Any] = [
            "musicTwoRowItemRenderer": [
                "title": ["runs": [["text": "Untitled"]]]
                // no navigationEndpoint at all
            ]
        ]
        XCTAssertNil(InnerTubeClient.parseTwoRowItem(tile),
            "Tiles without a navigation endpoint can't be played or opened, so the parser should drop them rather than returning a half-broken MediaItem")
    }

    // MARK: - parseHomeShelf

    func testParseHomeShelfCarouselWithTitle() {
        let shelf: [String: Any] = [
            "musicCarouselShelfRenderer": [
                "header": [
                    "musicCarouselShelfBasicHeaderRenderer": [
                        "title": ["runs": [["text": "Listen Again"]]]
                    ]
                ],
                "contents": [
                    [
                        "musicTwoRowItemRenderer": [
                            "title": ["runs": [["text": "Track A"]]],
                            "subtitle": ["runs": [["text": "Artist A"]]],
                            "navigationEndpoint": ["watchEndpoint": ["videoId": "a1"]]
                        ]
                    ],
                    [
                        "musicTwoRowItemRenderer": [
                            "title": ["runs": [["text": "Track B"]]],
                            "subtitle": ["runs": [["text": "Artist B"]]],
                            "navigationEndpoint": ["watchEndpoint": ["videoId": "b1"]]
                        ]
                    ]
                ]
            ]
        ]
        let section = InnerTubeClient.parseHomeShelf(shelf)
        XCTAssertEqual(section?.title, "Listen Again")
        XCTAssertEqual(section?.items.count, 2)
        XCTAssertEqual(section?.items.first?.id, "a1")
        XCTAssertEqual(section?.items.last?.id, "b1")
    }

    func testParseHomeShelfDropsEmpty() {
        let shelf: [String: Any] = [
            "musicCarouselShelfRenderer": [
                "header": [
                    "musicCarouselShelfBasicHeaderRenderer": [
                        "title": ["runs": [["text": "Empty Rail"]]]
                    ]
                ],
                "contents": []
            ]
        ]
        XCTAssertNil(InnerTubeClient.parseHomeShelf(shelf),
            "Shelves with no parsable items must be dropped — otherwise empty rails leak into Home")
    }

    // MARK: - parseRelatedSections

    /// Mimic the /next Related-tab browse response shape: a
    /// `singleColumnBrowseResultsRenderer` with a single tab whose
    /// `sectionListRenderer.contents` hold one or more
    /// `musicCarouselShelfRenderer` shelves. A real response carries
    /// an "Other versions" shelf (live / acoustic / cover variants)
    /// + "Recommended tracks"; we verify both are surfaced as
    /// titled HomeSections with their items intact.
    func testParseRelatedSectionsSurfacesTitledShelves() {
        let body: [String: Any] = [
            "contents": [
                "singleColumnBrowseResultsRenderer": [
                    "tabs": [[
                        "tabRenderer": [
                            "content": [
                                "sectionListRenderer": [
                                    "contents": [
                                        [
                                            "musicCarouselShelfRenderer": [
                                                "header": [
                                                    "musicCarouselShelfBasicHeaderRenderer": [
                                                        "title": ["runs": [["text": "Other versions"]]]
                                                    ]
                                                ],
                                                "contents": [[
                                                    "musicTwoRowItemRenderer": [
                                                        "title": ["runs": [["text": "Sample Song (Live)"]]],
                                                        "subtitle": ["runs": [["text": "Artist"]]],
                                                        "navigationEndpoint": ["watchEndpoint": ["videoId": "live1"]]
                                                    ]
                                                ], [
                                                    "musicTwoRowItemRenderer": [
                                                        "title": ["runs": [["text": "Sample Song (Acoustic)"]]],
                                                        "subtitle": ["runs": [["text": "Artist"]]],
                                                        "navigationEndpoint": ["watchEndpoint": ["videoId": "acou1"]]
                                                    ]
                                                ]]
                                            ]
                                        ],
                                        [
                                            "musicCarouselShelfRenderer": [
                                                "header": [
                                                    "musicCarouselShelfBasicHeaderRenderer": [
                                                        "title": ["runs": [["text": "Recommended tracks"]]]
                                                    ]
                                                ],
                                                "contents": [[
                                                    "musicTwoRowItemRenderer": [
                                                        "title": ["runs": [["text": "Other Song"]]],
                                                        "subtitle": ["runs": [["text": "Other Artist"]]],
                                                        "navigationEndpoint": ["watchEndpoint": ["videoId": "rec1"]]
                                                    ]
                                                ]]
                                            ]
                                        ]
                                    ]
                                ]
                            ]
                        ]
                    ]]
                ]
            ]
        ]
        let sections = InnerTubeClient.parseRelatedSections(body)
        XCTAssertEqual(sections.count, 2)
        XCTAssertEqual(sections.first?.title, "Other versions")
        XCTAssertEqual(sections.first?.items.count, 2)
        XCTAssertEqual(sections.first?.items.map(\.id), ["live1", "acou1"])
        XCTAssertEqual(sections.last?.title, "Recommended tracks")
        XCTAssertEqual(sections.last?.items.first?.id, "rec1")
    }

    /// Empty / unrecognized response — parser must not crash and must
    /// return an empty array so callers can fall back to flat related.
    func testParseRelatedSectionsEmptyOnUnknownShape() {
        XCTAssertTrue(InnerTubeClient.parseRelatedSections([:]).isEmpty)
        XCTAssertTrue(InnerTubeClient.parseRelatedSections(["contents": "garbage"]).isEmpty)
    }

    // MARK: - MediaItem Codable round-trip

    /// Played-history persistence relies on this. If MediaItem ever
    /// gains a non-Codable field, this catches it before users lose
    /// their history on next launch.
    func testMediaItemCodableRoundTrip() throws {
        let item = MediaItem(
            id: "vid",
            kind: .song,
            title: "Song",
            subtitle: "Artist",
            thumbnailURL: URL(string: "https://example.com/a.jpg"),
            albumId: "MPREb",
            artistId: "UC",
            durationSeconds: 222,
            year: 2024
        )
        let data = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(MediaItem.self, from: data)
        XCTAssertEqual(item, decoded)
    }

    // MARK: - parseDurationString

    func testParseDurationMMSS() {
        XCTAssertEqual(InnerTubeClient.parseDurationString("3:42"), 222)
        XCTAssertEqual(InnerTubeClient.parseDurationString("0:30"), 30)
        XCTAssertEqual(InnerTubeClient.parseDurationString("10:00"), 600)
    }

    func testParseDurationHMMSS() {
        XCTAssertEqual(InnerTubeClient.parseDurationString("1:23:45"), 5025)
        XCTAssertEqual(InnerTubeClient.parseDurationString("2:00:00"), 7200)
    }

    func testParseDurationRejectsGarbage() {
        XCTAssertNil(InnerTubeClient.parseDurationString(""))
        XCTAssertNil(InnerTubeClient.parseDurationString("LIVE"))
        XCTAssertNil(InnerTubeClient.parseDurationString("3:42:00:00"))
        XCTAssertNil(InnerTubeClient.parseDurationString("0:00"),
            "Zero-length not a real duration; rejecting it avoids fake matches on placeholders")
        XCTAssertNil(InnerTubeClient.parseDurationString(":42"))
        XCTAssertNil(InnerTubeClient.parseDurationString("3:"))
    }

    func testParseDurationTrimsWhitespace() {
        XCTAssertEqual(InnerTubeClient.parseDurationString("  3:42  "), 222)
    }

    // MARK: - duration + year via parseListItem

    /// List-row songs (search "Songs" shelf, library liked-songs)
    /// carry duration in fixedColumns and year in flexColumns. This
    /// fixture mimics a real row with both populated.
    func testParseListItemExtractsDurationAndYear() {
        let row: [String: Any] = [
            "musicResponsiveListItemRenderer": [
                "flexColumns": [
                    [
                        "musicResponsiveListItemFlexColumnRenderer": [
                            "text": [
                                "runs": [[
                                    "text": "Sample Song",
                                    "navigationEndpoint": [
                                        "watchEndpoint": ["videoId": "v1"]
                                    ]
                                ]]
                            ]
                        ]
                    ],
                    [
                        "musicResponsiveListItemFlexColumnRenderer": [
                            "text": [
                                "runs": [
                                    ["text": "Some Artist"],
                                    ["text": " • "],
                                    ["text": "2021"]
                                ]
                            ]
                        ]
                    ]
                ],
                "fixedColumns": [
                    [
                        "musicResponsiveListItemFixedColumnRenderer": [
                            "text": ["runs": [["text": "3:42"]]]
                        ]
                    ]
                ]
            ]
        ]
        let item = InnerTubeClient.parseListItem(row)
        XCTAssertEqual(item?.durationSeconds, 222)
        XCTAssertEqual(item?.year, 2021)
    }

    /// Year run with a navigationEndpoint must NOT be parsed as a
    /// year. Real-world case: artist named "1975" (the band) — their
    /// artist run has a browseEndpoint, so we have to ignore it.
    func testYearExtractorIgnoresLinkedNumericRuns() {
        let row: [String: Any] = [
            "musicResponsiveListItemRenderer": [
                "flexColumns": [
                    [
                        "musicResponsiveListItemFlexColumnRenderer": [
                            "text": [
                                "runs": [[
                                    "text": "Song",
                                    "navigationEndpoint": [
                                        "watchEndpoint": ["videoId": "v2"]
                                    ]
                                ]]
                            ]
                        ]
                    ],
                    [
                        "musicResponsiveListItemFlexColumnRenderer": [
                            "text": [
                                "runs": [
                                    [
                                        "text": "1975",
                                        "navigationEndpoint": [
                                            "browseEndpoint": [
                                                "browseId": "UC1975",
                                                "browseEndpointContextSupportedConfigs": [
                                                    "browseEndpointContextMusicConfig": [
                                                        "pageType": "MUSIC_PAGE_TYPE_ARTIST"
                                                    ]
                                                ]
                                            ]
                                        ]
                                    ]
                                ]
                            ]
                        ]
                    ]
                ]
            ]
        ]
        let item = InnerTubeClient.parseListItem(row)
        XCTAssertNil(item?.year, "Linked numeric runs are artist refs, not years")
    }

    // MARK: - year via parseTwoRowItem

    func testParseTwoRowItemExtractsYearFromSubtitle() {
        let tile: [String: Any] = [
            "musicTwoRowItemRenderer": [
                "title": ["runs": [["text": "Some Album"]]],
                "subtitle": [
                    "runs": [
                        ["text": "Artist"],
                        ["text": " • "],
                        ["text": "2019"]
                    ]
                ],
                "navigationEndpoint": [
                    "browseEndpoint": [
                        "browseId": "MPREb_sa",
                        "browseEndpointContextSupportedConfigs": [
                            "browseEndpointContextMusicConfig": [
                                "pageType": "MUSIC_PAGE_TYPE_ALBUM"
                            ]
                        ]
                    ]
                ]
            ]
        ]
        let item = InnerTubeClient.parseTwoRowItem(tile)
        XCTAssertEqual(item?.year, 2019)
    }
}
