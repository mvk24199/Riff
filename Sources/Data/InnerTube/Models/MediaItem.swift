import Foundation

struct MediaItem: Identifiable, Hashable, Sendable, Codable {
    enum Kind: String, Hashable, Sendable, Codable { case song, album, playlist, artist, podcast, episode }

    let id: String
    let kind: Kind
    let title: String
    let subtitle: String
    let thumbnailURL: URL?
    /// For `.song` rows, the album browseId (e.g. `MPREb_…`) when YT
    /// included one in the row's metadata. Drives the "Go to album"
    /// context-menu action. nil for non-songs and for songs whose
    /// source row didn't carry album navigation (some search shelves).
    var albumId: String? = nil
    /// For `.song` and `.album` rows, the primary artist's browseId
    /// (e.g. `UCxx…`). Drives "Go to artist". nil when YT didn't
    /// include an artist navigationEndpoint on the row.
    var artistId: String? = nil
}
