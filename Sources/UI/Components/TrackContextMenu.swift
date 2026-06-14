import SwiftUI

/// Standard YT-Music-style context menu for a track row. Used by
/// queue rows, search/library results, and detail-page tracklists so
/// the user gets the same affordances ("Play next", "Add to queue",
/// "Start radio", "Go to album", "Go to artist") everywhere.
///
/// Usage:
///   ```
///   .contextMenu { TrackContextMenu(item: track) }
///   ```
///
/// All actions are gated on data we actually have:
///   - Play / Start radio: always shown for songs/episodes
///   - Play next / Add to queue: shown when there's a current track
///     (so the queue exists). Local-only — same caveat as `removeFromQueue`.
///   - Go to album: only when the row's MediaItem carries `albumId`
///   - Go to artist: only when the row carries `artistId`
///   - Add to playlist: signed-in only
struct TrackContextMenu: View {
    @Environment(AppEnvironment.self) private var env
    let item: MediaItem
    /// When true, omits the Play action — useful for the queue's own
    /// rows where the row's primary tap already plays it.
    var omitPrimaryPlay: Bool = false

    var body: some View {
        if !omitPrimaryPlay {
            Button("Play") {
                Task { await env.player.play(item: item) }
            }
        }
        Button("Start radio") {
            Task { await env.player.startRadio(for: item) }
        }
        Divider()
        Button("Play next") {
            env.player.playNext(item: item)
        }
        .disabled(!env.player.hasTrack)
        Button("Add to queue") {
            env.player.addToQueueEnd(item: item)
        }
        .disabled(!env.player.hasTrack)
        if item.albumId != nil || item.artistId != nil {
            Divider()
            if let albumId = item.albumId {
                Button("Go to album") {
                    env.navigateToBrowseId(albumId, kind: .album)
                }
            }
            if let artistId = item.artistId {
                Button("Go to artist") {
                    env.navigateToBrowseId(artistId, kind: .artist)
                }
                // "Don't recommend this artist" — hides every future
                // surfacing of the artist (Home carousels, Search
                // results, /next radio, /related). Removable from
                // Settings → Library → Blocked Artists.
                Button("Don't recommend this artist") {
                    env.blockArtist(id: artistId)
                }
            }
        }
        if env.isSignedIn {
            Divider()
            addToPlaylistMenu
        }
    }

    /// Nested submenu mirroring the now-playing "Add to Playlist…" picker
    /// so the user can stash any track into a user-owned playlist
    /// without first making it the current track.
    private var addToPlaylistMenu: some View {
        Menu("Add to playlist") {
            Button("New Playlist…") {
                // The new-playlist sheet currently captures the *currently
                // playing* track. Make this row the current track first,
                // then prompt — keeps the existing flow intact without
                // duplicating sheet plumbing.
                Task {
                    await env.player.play(item: item)
                    env.newPlaylistSource = .currentTrack
                    env.isNewPlaylistSheetPresented = true
                }
            }
            if env.userPlaylistsLoading {
                Text("Loading…")
            } else if env.userPlaylists.isEmpty {
                Text("No playlists yet.")
            } else {
                Divider()
                ForEach(env.userPlaylists) { pl in
                    Button(pl.title) {
                        Task {
                            try? await env.innerTube.addToPlaylist(
                                videoId: item.id,
                                playlistId: pl.id
                            )
                        }
                    }
                }
            }
        }
        .onAppear { env.loadUserPlaylistsIfNeeded() }
    }
}
