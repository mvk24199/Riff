# Product Spec — MVP

> One-page spec for the **MVP (Phase 1)** of Riff. Scope-locked. Anything not listed here is parked for Phase 2+ (see [`../PLAN.md`](../PLAN.md)).

## Problem

A power user of YouTube Music on macOS today has three options:

1. **Browser tab** — works but doesn't integrate with macOS Now Playing, media keys are flaky, and the UI is heavy.
2. **th-ch/youtube-music** — Electron wrapper with plugins; great audio path but the UI is just the web page.
3. **Kaset** — SwiftUI shell over the same web page; looks more native but you can't click a thumbnail to play, and the UI feels like a knockoff Apple Music.

There is **no** YouTube Music app for macOS that feels native, looks like the YouTube Music iOS app, and lets you actually click on things to play them.

## Target user

Someone who uses YouTube Music daily on iOS or web, has Premium (or doesn't), works on a Mac, and wants their music app to feel as polished as the rest of macOS without giving up the YouTube Music catalogue and recommendations.

## Success criteria for MVP

The MVP is done when a fresh installer demonstrates these ten things, end-to-end, on a clean macOS 14+ machine:

1. Installer opens, app launches, sign-in sheet appears, Google login completes, sheet dismisses.
2. Home tab populates with real Quick picks / Listen again / Mixed for you carousels within 3 seconds of sign-in.
3. **Clicking any song thumbnail starts playing it within 2 seconds** — anywhere in the app.
4. Clicking an album/playlist/podcast thumbnail plays the first track and queues the rest.
5. The Mini Now Playing bar shows the current track's artwork, title, artist, scrubber, and prev/play/next.
6. macOS Control Center shows the current track. Pressing the play/pause media key works. AirPods double-tap works.
7. Clicking the Mini bar opens the full Now Playing view with large artwork, controls, and an Up Next list.
8. Search finds songs/albums/artists/playlists, and clicking any result plays it.
9. Library tab shows the signed-in user's liked songs, playlists, and subscribed podcasts (read-only).
10. A side-by-side demo against Kaset doing the same five actions: ours feels native, Kaset feels web-y.

If any of those ten don't work cleanly, the MVP isn't done.

## Anti-criteria (signs the MVP is failing)

- A user can see a web page anywhere except the one-time sign-in sheet.
- A user has to right-click or use a context menu to play something.
- The sidebar reads as Apple Music.
- Mini bar is missing or is non-clickable artwork.
- Audio quality is below 256kbps for a Premium account.

## In-scope (MVP)

| # | Feature | Notes |
|---|---|---|
| 1 | App shell — top tabs (Home, Search, Library) | Top tabs, not sidebar. iOS-style on a Mac. |
| 2 | Sign-in via WebView sheet | First launch only; cookies in shared `WKWebsiteDataStore`. |
| 3 | Home tab with real InnerTube data | Quick picks, Listen again, Mixed for you. |
| 4 | Search tab — Songs / Albums / Playlists / Artists tabs | Real `search` endpoint. |
| 5 | Library tab (read-only) — Liked, Playlists, Podcasts | Editing is Phase 2. |
| 6 | Click-to-play from any thumbnail | The killer differentiator. |
| 7 | Podcasts play as audio | No dedicated podcast UI yet. |
| 8 | Mini Now Playing bar | Pinned bottom, always visible when playing. |
| 9 | Full Now Playing view | Modal/sheet from mini bar; large artwork + Up Next. |
| 10 | macOS Now Playing + Control Center + media keys | `MPNowPlayingInfoCenter` + `MPRemoteCommandCenter`. |
| 11 | YouTube Music iOS visual fidelity | Dark theme, red `#FF0033` accent, 12pt rounded thumbnails, generous spacing, SF Pro. |

## Out of scope (parked)

Queue editing • playlist editing • adding to library • lyrics syncing • mini-player floating window • PiP • cast/AirPlay • settings page • theme switcher • offline downloads • smart radio / Mix for me · Activities / moods · Samples · multi-account · plugins · dedicated podcast UX (speed, skip ±15/30s, descriptions) · Apple Intelligence · BYO-LLM.

These are tracked in [`../PLAN.md`](../PLAN.md), Phases 2-4.

## Constraints

- macOS 14+ only (SwiftUI features needed).
- No backend service. Single-binary native app.
- AGPL-3.0 license — contributors retain copyright but downstream forks must remain open.
- No telemetry. Zero phone-home in MVP.

## Open questions

- **Distribution** — `.dmg` direct download + Homebrew cask; Mac App Store deferred (sandbox + ToS questions).
- **Code signing** — initial releases unsigned (user must right-click → Open); Developer ID signing decision deferred to first release.
