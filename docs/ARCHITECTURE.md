# Architecture

> **ADR-001: Hidden WKWebView as audio engine, native SwiftUI for everything visible.**
> Status: Accepted · Date: 2026-05-04

## Context

Two existing open-source YouTube Music clients on macOS each illustrate a failure mode:

1. **[th-ch/youtube-music](https://github.com/th-ch/youtube-music)** (Electron) shows the entire YouTube Music web page in a `BrowserWindow`. The audio path is rock-solid (Widevine, login, Premium quality, ads, recommendations, sync — Google handles all of it). But the UI is a web page; the app has no original surface area.
2. **[sozercan/kaset](https://github.com/sozercan/kaset)** (SwiftUI) wraps a `WKWebView` in SwiftUI chrome (sidebar, player bar). It's "more native" at a glance, but the moment a user tries to do anything — click a thumbnail to play, right-click for context, swipe through carousels — they're poking at a web page through a thin Swift veneer. 44 open issues confirm this. The user's complaint: *"feels like a cheap Apple Music copy."*

Two extreme alternatives we considered and rejected:

- **Pure native player via stream extraction (yt-dlp / InnerTube `/player`).** Lets us build 100% native UI with no WebView at all. Rejected because: (a) Widevine-protected Premium-quality streams can't be extracted — Premium subscribers would get worse audio than the web page, (b) the InnerTube `/player` endpoint is hostile territory: it's been broken repeatedly by Google and killed [Beatbump](https://github.com/snuffyDev/Beatbump) and [Hyperpipe](https://codeberg.org/Hyperpipe/Hyperpipe), (c) the ToS posture is much worse — extracting and replaying a stream looks like circumvention; running the real page does not.
- **Pure WebView wrapper** (the th-ch approach). Reliable, but ships zero original UI value and is what a user can already get by command-clicking the YT Music PWA into a standalone window.

## Decision

The app has **two cleanly separated surfaces**:

```
┌─────────────────────────────────────────────────────────────┐
│  Visible UI — 100% SwiftUI                                  │
│  ─ Home, Search, Library, Album/Artist/Playlist details     │
│  ─ Mini Now Playing bar, full Now Playing view              │
│  ─ Settings, queue, lyrics                                  │
│  Data source: InnerTubeClient (Swift, hits HTTPS/JSON       │
│  endpoints at music.youtube.com/youtubei/v1/*)              │
└──────────────┬──────────────────────────────┬───────────────┘
               │                              │
       ┌───────▼────────┐             ┌───────▼─────────┐
       │ InnerTubeClient│             │ PlayerBridge    │
       │ ─ POST /search │             │ ─ evaluate JS   │
       │ ─ POST /browse │             │ ─ msg handler   │
       │ ─ POST /next   │             │   for events    │
       └───────┬────────┘             └───────┬─────────┘
               │                              │
       ┌───────▼────────┐             ┌───────▼─────────┐
       │  Google's      │             │ Hidden offscreen│
       │  InnerTube     │             │ WKWebView       │
       │  HTTP/JSON     │             │ (music.youtube  │
       │                │             │  .com, 1×1px,   │
       │                │             │  alpha 0)       │
       └────────────────┘             └─────────────────┘

       ┌──────────────────────────────────────────────┐
       │  NowPlayingCenter                            │
       │  ─ MPNowPlayingInfoCenter (Control Center)   │
       │  ─ MPRemoteCommandCenter (media keys, AirPods)│
       └──────────────────────────────────────────────┘
```

### Surface 1: Visible UI — pure SwiftUI fed by InnerTubeClient

Every list, grid, detail page, scrubber, and button is a SwiftUI view. Lists/grids render thumbnails decoded by `AsyncImage` (or a small `KingfisherSwiftUI`-style cache). Tapping any thumbnail invokes `PlayerBridge.play(videoId:)` directly — no DOM, no JS click simulation, no race with web-page hover state.

**Data via `InnerTubeClient`:**

- `search(query:filter:)` → `POST /youtubei/v1/search`
- `browseHome()` → `POST /youtubei/v1/browse` with `browseId: "FEmusic_home"`
- `browse(albumId:)`, `browse(artistId:)`, `browse(playlistId:)` → same endpoint, different `browseId`
- `next(videoId:playlistId:)` → `POST /youtubei/v1/next` (gets autoplay continuation + queue)
- `library()` → `POST /youtubei/v1/browse` with `browseId: "FEmusic_liked"` and friends

The client sends a hand-crafted `context` payload (client name `WEB_REMIX`, current client version) that mimics what the web app sends. Cookies are read from the shared `WKWebsiteDataStore` so the user's sign-in state in the hidden WebView is reused for InnerTube calls — single login, two consumers.

### Surface 2: Audio engine — hidden WKWebView

A single `WKWebView` is created at app launch, parented to an offscreen `NSWindow` (1×1px, `alphaValue = 0`, no backing store), and loaded with `https://music.youtube.com`. It is **never** put on screen after the initial sign-in flow. Its sole purpose is to actually play audio.

The page's own `<video>` element is the player. Communication is bidirectional:

**Swift → page** via `WKWebView.evaluateJavaScript`:
```js
// pseudo: load + play a video by id
document.querySelector('ytmusic-app').store.dispatch({type:'PLAYER_NAVIGATE',videoId:'…'})
// pseudo: control existing player
document.querySelector('video').play()
document.querySelector('video').currentTime = 42
```

The actual selectors and store actions are encapsulated in `Resources/player-bridge.js`, which is injected at `documentStart` via a `WKUserScript`. That script exposes a stable `window.musicBridge.{play, pause, seek, like, getState}` API regardless of how the YT Music page restructures internally.

**Page → Swift** via `WKScriptMessageHandler`:
```js
navigator.mediaSession.setActionHandler('play',  () => webkit.messageHandlers.bridge.postMessage({event:'play'}))
navigator.mediaSession.setActionHandler('pause', () => webkit.messageHandlers.bridge.postMessage({event:'pause'}))
// timeupdate, ended, metadata change → posted as messages
```

These messages drive `NowPlayingCenter`, which mirrors playback state into `MPNowPlayingInfoCenter` (artwork, title, artist, position, duration) and registers handlers on `MPRemoteCommandCenter` for play/pause/next/prev/skip.

### Authentication

The hidden WKWebView handles all auth. On first launch, we briefly *un-hide* it as a sheet for Google sign-in. Once cookies are set in `WKWebsiteDataStore`, the WebView is hidden again forever. `InnerTubeClient` reads the same cookie jar via `HTTPCookieStorage.shared` (after bridging from `WKHTTPCookieStore`).

### Resilience to Google-side breakage

YouTube has historically broken InnerTube clients. Mitigation:

1. **Versioned client identity** — `InnerTubeClient.clientVersion` is a single constant; bumping it across the codebase is one PR.
2. **Failure mode degrades gracefully** — if InnerTube starts returning unexpected shapes, the WebView still works. The app can fall back to a "WebView visible" mode where the user sees the YT Music page directly (Kaset-equivalent) until we ship a client-version bump. This is the *failure floor*, not the design target.
3. **Snapshot-tested decoding** — every InnerTube response we depend on has a captured fixture in tests. A real-world breakage shows up as a CI failure on a nightly job that hits live endpoints with a sentinel account.

## Consequences

**Positive:**
- The Kaset failure mode (web feel, can't click thumbnails) is structurally impossible — the visible UI has no DOM.
- Premium audio works without DRM heroics.
- The InnerTubeClient and PlayerBridge are independently testable and replaceable.

**Negative / risks:**
- We maintain two integrations against an unofficial API. (Mitigated by snapshot fixtures + nightly CI + WebView fallback.)
- The hidden WebView consumes ~50-80MB of RAM on top of the SwiftUI app. (Acceptable: still well under Electron's 250-350MB.)
- Some YT Music features that exist purely in the web app's React store (e.g. "this autoplay queue continuation") may need extra reverse-engineering to expose to InnerTubeClient. (Mitigation: `PlayerBridge` can read these from the page DOM as a fallback when the InnerTube response lacks them.)

## Non-goals

- We will not extract or download audio streams.
- We will not block ads at the audio level (a free-tier user hears ads, same as the web page). A user-level [SponsorBlock](https://github.com/ajayyy/SponsorBlock)-style plugin is a Phase-4 idea.
- We will not strip DRM.
- We will not ship a Linux or Windows port from this codebase. SwiftUI doesn't go there. A future port would be a separate codebase, decided in Phase 4.

## Related

- Plan: [`PLAN.md`](../PLAN.md)
- Product spec: [`docs/PRODUCT_SPEC.md`](PRODUCT_SPEC.md)
- Reference for InnerTube request shapes: [LuanRT/YouTube.js](https://github.com/LuanRT/YouTube.js)
- Reference for endpoint catalogue: [sigma67/ytmusicapi](https://github.com/sigma67/ytmusicapi)
