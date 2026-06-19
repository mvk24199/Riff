import Foundation

/// D2 — On-device metadata overrides.
///
/// Per-videoId overrides for title / artist / album. Local-only by
/// design: nothing here ever propagates to YouTube. The user is fixing
/// metadata for *their* presentation of the catalog (mis-credited
/// "feat." chaos, transliteration, classical attribution); pushing
/// edits server-side would (a) be impossible — InnerTube has no
/// public edit-track endpoint — and (b) violate the "no telemetry"
/// rule even if it weren't.
///
/// Storage shape:
///
///   `{ videoId: { title?: String, artist?: String, album?: String } }`
///
/// Partial overrides are supported: a user can correct only the artist
/// and leave title alone. An override field set to the empty string is
/// treated as "no override" (the user cleared the field in the edit
/// sheet) and pruned on save so the JSON stays tidy.
///
/// Persisted as JSON under the `library.trackOverrides` UserDefaults
/// key. Codable, Sendable. The store is `@MainActor` because all
/// callers (Edit sheet save, env render helpers) already are.
@MainActor
@Observable
final class TrackOverrideStore {
    struct Override: Codable, Hashable, Sendable {
        var title: String?
        var artist: String?
        var album: String?

        var isEmpty: Bool {
            (title?.isEmpty ?? true) && (artist?.isEmpty ?? true) && (album?.isEmpty ?? true)
        }
    }

    /// Map from videoId → override. Read-only externally; mutations
    /// go through `setOverride(...)` / `clearOverride(...)` so the
    /// persistence side-effect lives in one place.
    private(set) var overrides: [String: Override] = [:]

    /// UserDefaults key. Per the heads-up — "library.trackOverrides".
    static let defaultsKey = "library.trackOverrides"

    init(loadFromDefaults: Bool = true) {
        if loadFromDefaults {
            load()
        }
    }

    // MARK: - Reads

    func override(for videoId: String) -> Override? {
        guard !videoId.isEmpty else { return nil }
        return overrides[videoId]
    }

    func hasOverride(for videoId: String) -> Bool {
        guard let o = override(for: videoId) else { return false }
        return !o.isEmpty
    }

    /// Returns the override title if present and non-empty, otherwise nil.
    /// Callers fall back to the original title.
    func overriddenTitle(for videoId: String) -> String? {
        guard let t = override(for: videoId)?.title, !t.isEmpty else { return nil }
        return t
    }

    func overriddenArtist(for videoId: String) -> String? {
        guard let a = override(for: videoId)?.artist, !a.isEmpty else { return nil }
        return a
    }

    func overriddenAlbum(for videoId: String) -> String? {
        guard let a = override(for: videoId)?.album, !a.isEmpty else { return nil }
        return a
    }

    // MARK: - Writes

    /// Save partial overrides. Empty / whitespace-only inputs are
    /// treated as "no override" for that field — so leaving a TextField
    /// blank in the edit sheet clears whatever override was previously
    /// there. If every field ends up empty, the videoId is removed
    /// entirely (rather than leaving an empty stub in the dictionary).
    func setOverride(videoId: String, title: String?, artist: String?, album: String?) {
        guard !videoId.isEmpty else { return }
        let cleaned = Override(
            title: normalize(title),
            artist: normalize(artist),
            album: normalize(album)
        )
        if cleaned.isEmpty {
            overrides.removeValue(forKey: videoId)
        } else {
            overrides[videoId] = cleaned
        }
        persist()
    }

    func clearOverride(videoId: String) {
        guard overrides.removeValue(forKey: videoId) != nil else { return }
        persist()
    }

    func clearAll() {
        guard !overrides.isEmpty else { return }
        overrides.removeAll()
        persist()
    }

    /// Sorted videoIds, exposed for the Settings list so iteration is
    /// stable across renders.
    var sortedVideoIds: [String] {
        overrides.keys.sorted()
    }

    // MARK: - Private

    private func normalize(_ s: String?) -> String? {
        guard let s else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func persist() {
        // Encode to JSON Data so the on-disk shape is the JSON the
        // heads-up specified, even though UserDefaults would happily
        // round-trip the `[String: Override]` via PLIST. JSON also
        // makes the file inspectable for power users.
        do {
            let data = try JSONEncoder().encode(overrides)
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        } catch {
            // Encoding failures here would mean the Codable contract
            // itself broke (the only non-Codable values we touch are
            // already nil-filtered). Silent ignore matches the rest
            // of the persistence call sites in this app.
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.defaultsKey) else { return }
        do {
            let decoded = try JSONDecoder().decode([String: Override].self, from: data)
            // Defensive: drop any entries that decoded into all-empty
            // overrides (shouldn't happen given `setOverride` prunes,
            // but old data or hand-edited plists could carry stubs).
            overrides = decoded.filter { !$0.value.isEmpty }
        } catch {
            // Corrupted blob — leave overrides empty. The next save
            // will overwrite the bad data.
        }
    }
}
