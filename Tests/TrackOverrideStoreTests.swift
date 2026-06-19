import XCTest
@testable import Riff

/// D2 — unit tests for `TrackOverrideStore`.
///
/// The store persists to `UserDefaults.standard` under
/// `library.trackOverrides`. We snapshot whatever lives at that key
/// before each test and restore it on teardown so a developer's real
/// override JSON isn't clobbered when the suite runs locally.
@MainActor
final class TrackOverrideStoreTests: XCTestCase {

    private var snapshot: Data? = nil

    override func setUp() async throws {
        try await super.setUp()
        snapshot = UserDefaults.standard.data(forKey: TrackOverrideStore.defaultsKey)
        UserDefaults.standard.removeObject(forKey: TrackOverrideStore.defaultsKey)
    }

    override func tearDown() async throws {
        if let snapshot {
            UserDefaults.standard.set(snapshot, forKey: TrackOverrideStore.defaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: TrackOverrideStore.defaultsKey)
        }
        try await super.tearDown()
    }

    // MARK: - Basic set / read

    func testSetOverrideStoresAllFields() {
        let store = TrackOverrideStore(loadFromDefaults: false)
        store.setOverride(videoId: "abc", title: "T", artist: "A", album: "AL")
        let o = store.override(for: "abc")
        XCTAssertEqual(o?.title, "T")
        XCTAssertEqual(o?.artist, "A")
        XCTAssertEqual(o?.album, "AL")
        XCTAssertTrue(store.hasOverride(for: "abc"))
    }

    func testPartialOverrideKeepsOtherFieldsNil() {
        let store = TrackOverrideStore(loadFromDefaults: false)
        store.setOverride(videoId: "abc", title: nil, artist: "A", album: nil)
        let o = store.override(for: "abc")
        XCTAssertNil(o?.title)
        XCTAssertEqual(o?.artist, "A")
        XCTAssertNil(o?.album)
        XCTAssertNil(store.overriddenTitle(for: "abc"))
        XCTAssertEqual(store.overriddenArtist(for: "abc"), "A")
    }

    func testEmptyAndWhitespaceFieldsAreNormalizedToNil() {
        let store = TrackOverrideStore(loadFromDefaults: false)
        store.setOverride(videoId: "abc", title: "  ", artist: "Real", album: "")
        let o = store.override(for: "abc")
        XCTAssertNil(o?.title)
        XCTAssertEqual(o?.artist, "Real")
        XCTAssertNil(o?.album)
    }

    func testAllEmptyFieldsRemovesEntry() {
        let store = TrackOverrideStore(loadFromDefaults: false)
        store.setOverride(videoId: "abc", title: "T", artist: nil, album: nil)
        XCTAssertTrue(store.hasOverride(for: "abc"))
        store.setOverride(videoId: "abc", title: "", artist: "", album: "")
        XCTAssertFalse(store.hasOverride(for: "abc"))
        XCTAssertNil(store.override(for: "abc"))
    }

    func testEmptyVideoIdIsIgnored() {
        let store = TrackOverrideStore(loadFromDefaults: false)
        store.setOverride(videoId: "", title: "T", artist: "A", album: nil)
        XCTAssertEqual(store.sortedVideoIds, [])
    }

    func testHasOverrideFalseWhenAllFieldsEmpty() {
        let store = TrackOverrideStore(loadFromDefaults: false)
        // Bypass setOverride's pruning by direct decode of an empty
        // stub — the load() path defends against this even if a hand-
        // edited plist sneaks one in.
        let stub = ["x": TrackOverrideStore.Override(title: nil, artist: nil, album: nil)]
        let data = try! JSONEncoder().encode(stub)
        UserDefaults.standard.set(data, forKey: TrackOverrideStore.defaultsKey)
        let store2 = TrackOverrideStore()
        XCTAssertFalse(store2.hasOverride(for: "x"))
        XCTAssertEqual(store2.sortedVideoIds, []) // empty stubs are dropped on load
    }

    // MARK: - Persistence

    func testPersistAndRoundTripThroughUserDefaults() {
        let store = TrackOverrideStore(loadFromDefaults: false)
        store.setOverride(videoId: "abc", title: "T", artist: "A", album: "AL")
        store.setOverride(videoId: "xyz", title: nil, artist: "Other", album: nil)
        // Spin up a fresh store that reads from defaults — verifies
        // both keys survived the JSON round-trip.
        let reloaded = TrackOverrideStore()
        XCTAssertEqual(reloaded.overriddenTitle(for: "abc"), "T")
        XCTAssertEqual(reloaded.overriddenArtist(for: "abc"), "A")
        XCTAssertEqual(reloaded.overriddenAlbum(for: "abc"), "AL")
        XCTAssertNil(reloaded.overriddenTitle(for: "xyz"))
        XCTAssertEqual(reloaded.overriddenArtist(for: "xyz"), "Other")
        XCTAssertEqual(Set(reloaded.sortedVideoIds), Set(["abc", "xyz"]))
    }

    func testClearOverrideRemovesEntry() {
        let store = TrackOverrideStore(loadFromDefaults: false)
        store.setOverride(videoId: "abc", title: "T", artist: "A", album: nil)
        store.clearOverride(videoId: "abc")
        XCTAssertFalse(store.hasOverride(for: "abc"))
        let reloaded = TrackOverrideStore()
        XCTAssertFalse(reloaded.hasOverride(for: "abc"))
    }

    func testClearAllWipesEverything() {
        let store = TrackOverrideStore(loadFromDefaults: false)
        store.setOverride(videoId: "a", title: "T1", artist: nil, album: nil)
        store.setOverride(videoId: "b", title: nil, artist: "A2", album: nil)
        store.clearAll()
        XCTAssertEqual(store.sortedVideoIds, [])
        let reloaded = TrackOverrideStore()
        XCTAssertEqual(reloaded.sortedVideoIds, [])
    }

    func testCorruptedBlobLeavesStoreEmptyButRecovers() {
        UserDefaults.standard.set(Data([0xff, 0x00, 0x42]), forKey: TrackOverrideStore.defaultsKey)
        let store = TrackOverrideStore()
        XCTAssertEqual(store.sortedVideoIds, [])
        // And we can still write — the next save overwrites the bad data.
        store.setOverride(videoId: "abc", title: "Fixed", artist: nil, album: nil)
        let reloaded = TrackOverrideStore()
        XCTAssertEqual(reloaded.overriddenTitle(for: "abc"), "Fixed")
    }

    func testSortedVideoIdsIsStable() {
        let store = TrackOverrideStore(loadFromDefaults: false)
        store.setOverride(videoId: "zeta", title: "T", artist: nil, album: nil)
        store.setOverride(videoId: "alpha", title: "T", artist: nil, album: nil)
        store.setOverride(videoId: "mike", title: "T", artist: nil, album: nil)
        XCTAssertEqual(store.sortedVideoIds, ["alpha", "mike", "zeta"])
    }
}
