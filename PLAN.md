# YouTube Music for macOS — Strategic Plan

## Context

**Goal:** Open-source, native macOS desktop client for YouTube Music with the look-and-feel of the **YouTube Music iOS app** (not Apple Music). MVP-first, then iterate to feature parity with the iOS app.

**Why this exists:** No first-party YT Music app on macOS App Store. The leading OSS options each fail in a specific way:

- **[th-ch/youtube-music](https://github.com/th-ch/youtube-music)** (31.5k★, Electron) — pure `BrowserWindow` wrapper around `music.youtube.com`. No original UI, just plugins around the web page.
- **[sozercan/kaset](https://github.com/sozercan/kaset)** (~1k★, SwiftUI + WKWebView) — Swift chrome around a web page. Failure modes confirmed by the user and by 44 open issues: can't play a song/album from a thumbnail (#226, #224), feels like a "cheap Apple Music copy" because the SwiftUI shell is shallow and the underlying view is still a web page.

**Differentiated wedge:** SwiftUI-first UI where the WKWebView is **invisible** and used purely as an audio/DRM engine. All browse/search/library surfaces are real SwiftUI views fed by an InnerTube client. This is the inversion of Kaset's architecture.

**Decisions locked in (from clarifying Q&A):**
- Stack: **SwiftUI native, macOS 14+** (single platform, single language)
- Scope: **macOS-only** for MVP and Phase 2; cross-platform deferred
- Tooling: **selective import** of agents + orchestration from [thisizmsk-png/claude-cortex](https://github.com/thisizmsk-png/claude-cortex) into `.claude/`
- **Content scope**: songs, albums, artists, **playlists**, **podcasts** — all four are first-class media types (YT Music's full catalogue, not just music)
- **AI**: dual-track — Apple Intelligence (free, on-device, system-integrated) + BYO-LLM (user picks Anthropic/OpenAI/Gemini/Ollama). Deferred to Phase 3 for build, but advertised in README from day 1.

---

## Architecture (the Kaset-inversion)

```
┌─────────────────────────────────────────────────────────────┐
│  SwiftUI App (visible UI — Home, Search, Library, Player)   │
│  ─ All views native, all data via InnerTubeClient           │
└──────────────┬──────────────────────────────┬───────────────┘
               │                              │
       ┌───────▼────────┐             ┌───────▼─────────┐
       │ InnerTubeClient│             │ AudioEngine     │
       │ (Swift)        │             │ (PlayerBridge)  │
       │ ─ search       │             │ ─ JS-injected   │
       │ ─ home/browse  │             │   commands      │
       │ ─ playlist     │             │ ─ event stream  │
       │ ─ track meta   │             │   from page     │
       └───────┬────────┘             └───────┬─────────┘
               │                              │
       ┌───────▼────────┐             ┌───────▼─────────┐
       │ music.youtube  │             │ Hidden          │
       │ .com /youtubei │             │ WKWebView       │
       │ /v1 endpoints  │             │ (offscreen,     │
       │ (HTTPS+JSON)   │             │  music.youtube  │
       │                │             │  .com, plays    │
       │                │             │  via Widevine)  │
       └────────────────┘             └─────────────────┘

       ┌──────────────────────────────────────────────┐
       │  MPNowPlayingInfoCenter + MPRemoteCommand    │
       │  Center (native macOS Now Playing + media    │
       │  keys + Control Center, fed by AudioEngine)  │
       └──────────────────────────────────────────────┘
```

**Why both InnerTubeClient AND a hidden WKWebView (not one or the other):**
- **InnerTubeClient** powers the *visible* UI — fast, native rendering, full control over thumbnails/lists/click handlers. This is what kills the "can't play from thumbnail" problem.
- **Hidden WKWebView** is the audio engine — only WebKit's Widevine/FairPlay path can play **YT Premium DRM tracks**. Stream-extraction (yt-dlp/InnerTube /player) breaks Premium, violates ToS more clearly, and Google has historically killed these libs (Beatbump and Hyperpipe both went dead). Webview audio is also auth-free for the user — they sign in once via the page.
- **Bridge**: SwiftUI sends `evaluateJavaScript` calls (`window.location.href = 'music.youtube.com/watch?v=…'` or operate the page's `<video>` element directly). The page's MediaSession events bubble back via `WKScriptMessageHandler`, feeding `MPNowPlayingInfoCenter`.

---

## MVP (Phase 1) — 3-4 weeks

**Bar:** A user opens the app, signs in, browses a real YT Music home feed in native SwiftUI, **clicks any thumbnail and the song plays**. Media keys work. Now Playing in Control Center works. The app does not look like Kaset or Apple Music.

### MVP feature list (cut anything not on this list)

1. **App shell** — SwiftUI window, top nav bar with three tabs: Home, Search, Library. (Top tabs, not sidebar — that's the Apple Music tell. YT Music iOS uses bottom tabs; on Mac, top tabs read as the closest faithful translation.)
2. **Sign in** — present the WKWebView modally for Google sign-in only on first launch. Cookies persist via shared `WKWebsiteDataStore`.
3. **Home tab** — real data from InnerTube `browse` endpoint (Quick picks, Listen again, Mixed for you carousels).
4. **Search tab** — tabs for Songs / Albums / Playlists / Artists, real InnerTube `search` endpoint.
5. **Library tab (read-only for MVP)** — Liked songs + user playlists + subscribed podcasts list. Editing deferred to Phase 2.
6. **Click-to-play from any thumbnail** — the Kaset gap. Tapping a song/episode thumbnail anywhere instantly plays it; tapping an album/playlist/podcast plays it from track 1 and queues the rest.
7. **Podcasts play as audio** — InnerTube returns podcast episodes alongside music in search/browse; they route through the same player. No dedicated podcast UI yet (deferred to Phase 2).
8. **Mini Now Playing bar** — pinned to bottom: thumbnail, title/artist, scrubber, prev/play/next, like.
9. **Full Now Playing view** — opens on click of mini bar: large artwork, controls, "Up Next" list, basic lyrics tab (deferred if InnerTube lyrics extraction is non-trivial — fall back to "Lyrics coming soon").
10. **macOS Now Playing integration** — `MPNowPlayingInfoCenter` updated on every track change; `MPRemoteCommandCenter` handles play/pause/skip from Control Center, AirPods, keyboard media keys, Touch Bar.
11. **Visual fidelity to YT Music iOS** — dark theme default, red `#FF0033` accent, large rounded thumbnails (12pt corner radius), generous 16-20pt spacing, SF Pro fonts, blurred hero backdrops on Now Playing view.

### Explicitly OUT of MVP (parked for Phase 2+)

Queue editing • playlist editing • adding to library • lyrics syncing • mini-player floating window • PiP • cast/AirPlay • settings page • theme switcher • offline downloads • smart radio • plugins • dedicated podcast UI (speed control, episode descriptions) • AI features (Apple Intelligence + BYO-LLM).

---

## Phase 2 — Core parity (4-6 weeks)

- **Sign-in via OAuth Device Flow** — Google actively blocks WKWebView sign-in (`navigator.webdriver` / network-stack fingerprinting); UA spoofing doesn't beat it. The TV-app-style flow is the only path that works end-to-end: user opens a verification URL on another device, enters a 6-digit code, Riff polls for a token. Requires registering a Google OAuth client (TV/limited-input device type) + token-refresh plumbing + Keychain storage.
- **Queue management** — reorder, remove, jump-to. SwiftUI drag-drop on Up Next list.
- **Library write operations** — like/unlike, add-to-playlist, create playlist, remove from playlist.
- **Synced lyrics** — InnerTube lyrics endpoint + word-level timing render.
- **Album / Artist / Playlist detail pages** — full SwiftUI, header art + track list.
- **Podcasts (dedicated UX)** — Podcasts section under Library, episode list with show notes/descriptions, **playback speed** (0.75x/1.0x/1.25x/1.5x/2.0x), **skip ±15/30s** buttons, "continue listening" position memory per episode. Subscribe/unsubscribe.
- **Mini player window** — detachable always-on-top floating window (NSPanel with `.floatingPanel` style mask).
- **Settings panel** — audio quality, theme, keyboard shortcuts, sign-out.
- **History tab** under Library.
- **Search filters** (year, duration, type=song/album/podcast/episode/playlist).

---

## Phase 3 — iOS feature parity + AI layer (2-3 months)

### iOS parity
- **Recommendations explorer** ("Mix for me", smart radio, autoplay continuations).
- **Activities / Moods / Genres** browse hubs.
- **Samples** (YT Music's short-video discovery surface) — may defer if InnerTube exposure is poor.
- **AirPlay 2 / system audio routing** via `AVAudioSession`.
- **Profile + multi-account switching**.
- **Background playback when window closed** (NSApp activation policy tweak).
- **Keyboard shortcut customization** + global shortcuts.
- **Audio normalization / EQ** (AVAudioEngine tap on the WKWebView audio device).

### AI integration (the differentiated layer)

**Track A — Apple Intelligence (free, on-device, macOS 15.1+):**
- **App Intents** — register `PlaySongIntent`, `PlayAlbumIntent`, `PlayPlaylistIntent`, `PlayPodcastIntent`, `SearchIntent`, `LikeCurrentIntent`. This unlocks:
  - Siri: *"Hey Siri, play Taylor Swift on YouTube Music"*
  - Spotlight: typing a song name surfaces a "Play on YouTube Music" action
  - Shortcuts.app: users build their own automations (e.g. *"morning routine: open YT Music + play Lofi Beats"*)
- **Writing Tools** integration on playlist description fields — system "Rewrite/Proofread" menus appear automatically once the field uses `TextEditor` with the right modifier.
- **Smart Reply** for the "share with friend" copy field.
- Cost: zero. No API key. No network. Falls back gracefully on macOS <15.1.

**Track B — BYO-LLM (user picks their provider):**
- **Provider abstraction** — `LLMProvider` Swift protocol with implementations for Anthropic, OpenAI, Google Gemini, and Ollama (local). User pastes their API key in Settings; key stored in macOS Keychain (never in plaintext, never synced).
- **AI features unlocked once a key is configured:**
  - **Natural-language queue builder** — *"build me a 30-min focus mix from my likes that ramps energy down toward the end"*. The LLM gets a JSON list of the user's liked songs (titles + artists + tags from InnerTube) and returns an ordered videoId list, which is then enqueued.
  - **Lyrics meaning / explainer** — paste current lyrics + song metadata, ask "what's this song about?" Renders inline in the Now Playing lyrics tab.
  - **"What should I play next?"** — given listening history, get LLM recommendations expressed as InnerTube search queries; auto-enqueue the top result for each.
  - **Mood-tag your library** — batch job: tag every liked song with mood/energy/genre via LLM; enables faceted local search ("show me my mellow Saturday-morning likes").
  - **Voice-to-search** — pipe macOS Speech Recognition output into the search bar (no extra LLM needed for this one).
- **Privacy stance** — only metadata (titles, artists, lyrics) goes to the user's chosen LLM. Audio never leaves the device. Settings panel discloses exactly what is sent per feature.
- **Default = no AI** — every AI feature is opt-in; the app works fully without any AI provider configured.

**Why split into two tracks:** Apple Intelligence is "no-friction, free, narrow" — system integration. BYO-LLM is "high-friction, paid, broad" — creative features. Users who don't want AI keep a clean app; users who do get the most flexible setup of any music client (no other YT Music client offers BYO-LLM as of 2026).

---

## Phase 4 — Beyond iOS (open-ended)

- **Plugin system** (SwiftPM-loaded bundles): SponsorBlock-style ad-skip, Discord Rich Presence, Last.fm scrobble, custom themes.
- **Local lyric editor**.
- **Advanced AI** — sing/hum-to-search via on-device audio model (e.g. Whisper variant); LLM-generated playlist artwork via local Stable Diffusion or BYO image API; conversational music-history Q&A *("when did I last listen to this album?")*.
- **Cross-platform fork point** — at this stage, evaluate whether to port to Electron/Tauri for Linux/Windows or fork the codebase. Document the decision as an ADR. Do NOT try to keep SwiftUI cross-platform via Skip or similar — the design will diverge.

---

## Risk register

| Risk | Likelihood | Mitigation |
|---|---|---|
| Kaset failure mode (UI feels web-y, can't click thumbnails) | High if not vigilant | Architectural rule: **WKWebView is never visible after sign-in.** Every list/grid is SwiftUI fed by InnerTubeClient. PR review checklist enforces this. |
| Google breaks InnerTube endpoints | Medium (killed Beatbump + Hyperpipe) | Versioned `InnerTubeClient` with replaceable client-version constant; `WKWebView`-only fallback mode that loads `music.youtube.com` directly so audio + Premium keep working even when custom UI breaks. |
| DRM blocks Premium-quality playback | Low (WKWebView path works) | Never extract streams; always play through WKWebView. |
| Sign-in cookie expiry / Cloudflare CAPTCHA | Medium (Kaset issue #229) | Detect 401/CAPTCHA in InnerTubeClient, surface "re-auth" sheet that re-presents the WKWebView. |
| Kaset / th-ch already cover most user need | Medium | Wedge is **iOS-faithful UI + click-anywhere-to-play**. Demo videos at every release showing this differentiation. |
| Solo-maintainer burnout | High (open-source norm) | Lean on selective cortex agents for review and triage; document architecture clearly so contributors can ramp; resist Phase-3 scope creep until Phase-2 stable. |
| ToS / takedown | Low for code, Medium for distribution | License is irrelevant to YT ToS; users use their own Google account. Add CLEAR README disclaimer. Do not host an Apple-signed installer that auto-updates without user action — distribute as `.dmg` + Homebrew cask. |
| BYO-LLM cost surprise (user runs up an LLM bill) | Medium | Settings panel shows estimated tokens/cost per feature run; hard cap on tokens per request; default to cheapest model per provider; "AI off" is the default. |
| AI features leak private data | Medium | Disclose exactly what is sent per feature; never send audio; never send full library unless user explicitly runs the batch mood-tag job. Default to Ollama (local) in onboarding when present. |

---

## Critical files / packages to scaffold

```
Riff/
├── App/
│   ├── RiffApp.swift                   # @main entry, Scene wiring
│   └── AppEnvironment.swift            # @Observable container: clients, player, account
├── UI/
│   ├── Home/HomeView.swift
│   ├── Search/SearchView.swift
│   ├── Library/LibraryView.swift
│   ├── Player/MiniPlayerView.swift
│   ├── Player/NowPlayingView.swift
│   └── Components/ThumbnailButton.swift # the "play on tap" primitive — used everywhere
├── Data/
│   ├── InnerTube/
│   │   ├── InnerTubeClient.swift       # POST /youtubei/v1/{search,browse,next,player}
│   │   ├── Endpoints.swift             # typed endpoints
│   │   └── Models/                     # Codable for the responses we use
│   └── Auth/CookieJar.swift            # bridge to WKWebsiteDataStore
├── Audio/
│   ├── PlayerBridge.swift              # JS-eval API into the hidden WKWebView
│   ├── HiddenPlayerWebView.swift       # offscreen WKWebView, msg handlers
│   └── NowPlayingCenter.swift          # MPNowPlayingInfoCenter + MPRemoteCommandCenter wiring
├── Intents/                            # Phase 3 — Apple Intelligence
│   ├── PlaySongIntent.swift
│   ├── PlayPlaylistIntent.swift
│   └── SearchIntent.swift
├── AI/                                 # Phase 3 — BYO-LLM
│   ├── LLMProvider.swift               # protocol
│   ├── Providers/{Anthropic,OpenAI,Gemini,Ollama}Provider.swift
│   ├── KeychainStore.swift             # API-key storage
│   └── Features/{QueueBuilder,LyricsExplainer,Recommender}.swift
└── Resources/
    └── player-bridge.js                # injected into the YT Music page; surfaces play/pause/seek/progress events
```

**Reference / learn-from (do not vendor):**
- Kaset architecture, especially `WebViewBridge` patterns — but **invert** the visible/hidden ratio.
- th-ch/youtube-music's `src/plugins/notifications` for MediaSession→native bridging patterns.
- [LuanRT/YouTube.js](https://github.com/LuanRT/YouTube.js) — read its InnerTube request shapes; reimplement minimally in Swift.
- [sigma67/ytmusicapi](https://github.com/sigma67/ytmusicapi) — read its endpoint catalogue as documentation; do NOT bundle Python.

---

## Tooling: cortex selective import

Copy into `Riff/.claude/`:
- **Agents** (8 of 17 from cortex/agents): PM, Principal SDE, Frontend SDE, UI Critic, Red Team, QA, Security Reviewer, Code Reviewer. Skip team-bloat duplicates.
- **Orchestration**: `chakravyuha.yaml` (parallel DAG — run frontend-design + critique + design-auditor + polish concurrently against YT Music iOS reference screenshots) and `feature-development.yaml` (sequential pipeline for feature PRs).
- **Templates**: `COMPANY_ORDER.md` → repurpose as `ROLES.md` describing maintainer-bot roles in PR triage.
- **Skip**: `skills/` directory — already present in user's local install.

Workflow once imported: each PR feature triggers `feature-development.yaml`; UI PRs additionally trigger `chakravyuha.yaml` with reference iOS screenshots in `.claude/refs/ytm-ios/` so design fidelity gets multi-agent review on every UI change.

---

## Pre-Phase-1 setup (week 0, ~2 days)

1. `git init`, MIT or AGPL-3.0 license decision (AGPL recommended for OSS music apps — same as ViMusic, prevents proprietary forks).
2. `xcodebuild -showsdks` confirm macOS 14+ SDK; create `Riff.xcodeproj` with App + Tests targets.
3. Pull cortex assets per above; verify `.claude/agents/*.md` load.
4. Author a 1-page **Product Spec** (use local `product-spec` skill) lifting the MVP feature list above.
5. Capture **YT Music iOS reference screenshots** for the UI critic agent: home, search results, now playing, queue. Store under `.claude/refs/ytm-ios/`.
6. Stand up a `docs/ARCHITECTURE.md` ADR for the hidden-webview-as-audio-engine decision.

---

## Verification plan (how we know MVP is done)

End-to-end manual checklist on a fresh macOS install:

1. **Cold install** — `.dmg` opens, app launches, sign-in sheet appears, Google login completes, sheet dismisses, Home tab populated within 3s.
2. **Click-to-play** — from Home, click any song thumbnail → audio plays within 2s, mini-bar populates, Now Playing shows artwork in Control Center, AirPods play/pause works.
3. **Album play** — click an album thumbnail → first track plays, queue contains remaining tracks in order.
4. **Search → play** — type query, results appear <1s after typing stops, click result, plays.
5. **Library read** — Library tab shows real liked songs + playlists from the signed-in account.
6. **Now Playing full view** — click mini-bar expands to full view, scrubber works, prev/next works.
7. **Premium quality check** — on a Premium account, audio bitrate matches expected (no extraction = Widevine path = full quality).
8. **No visible web page anywhere** — grep the running app's view hierarchy: WKWebView is offscreen, never in a visible NSView.
9. **Memory** — idle <150MB, playing <250MB.
10. **Side-by-side with Kaset** — same 5 actions; ours feels native, Kaset feels web-y. Record demo video for the README.

Automated:
- `swift test` for InnerTubeClient request/response decoding (snapshot fixtures of real responses).
- UI snapshot tests for Home/Search/Player on default theme via `swift-snapshot-testing`.
- A nightly CI job hitting real InnerTube endpoints with a sentinel account to detect Google-side breakage.
