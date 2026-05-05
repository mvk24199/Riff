import Foundation

struct MediaItem: Identifiable, Hashable {
    enum Kind: String, Hashable { case song, album, playlist, artist, podcast, episode }

    let id: String
    let kind: Kind
    let title: String
    let subtitle: String
    let thumbnailURL: URL?
}
