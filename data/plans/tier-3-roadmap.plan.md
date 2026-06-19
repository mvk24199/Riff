# Plan: Tier 3 Backlog

slug: tier-3-roadmap
created: 2026-06-18T22:50:00Z
status: draft

## Findings

Two streams of work consolidated here:

1. End-to-end audit of Riff (UX polish, bugs, parity gaps).
2. Competitor UX research across Spotify, Apple Music, YT Music + Amazon Music, and niche/emerging players (Tidal, SoundCloud, Marvis, Doppler, Roon, last.fm, Pandora, Bandcamp, Endel).

Cross-cutting takeaways:

- The single biggest near-term win is restoring the audio-to-video toggle. Riff currently hides YT Music's defining feature.
- BYO-LLM is under-leveraged. The Anthropic key is wired to Queue Builder only; X-Ray cards, lyric translation, Smart Sections, AI DJ commentary, magazine artist bios, and "ask about your year" all sit on the same hook.
- macOS-native chrome (Mini Player window, menu bar, Notification Center widget, expanded Shortcuts) is the moat against the YT Music webapp.
- Three P0 bugs and five 15-min UX wins are blocking polish. Fix that batch before adding anything new.

The CLAUDE.md architectural rule still holds: WKWebView is audio-only and invisible except for sign-in. The audio-to-video toggle is the one scoped exception, surfaced as a discrete dismissible video pane on Now Playing.

## Steps

### Tier A: Ship next 2 weeks (P0 fixes + highest-leverage features)

- [x] **A1. P0 bug fixes** — force-unwraps on URL construction (PlayerBridge.swift:725, InnerTubeClient.swift:373-375), add 10s timeout to InnerTubeClient URLSession, max-attempts cap on OAuth Device Flow polling (OAuthDeviceFlow.swift:147).
  - note: Replaced both URL force-unwraps with safe `guard` fallbacks (home URL for player, `InnerTubeError.decoding` for Data API). Swapped `URLSession.shared` for a configured `URLSession` with 10s request / 30s resource timeouts; tests still inject custom sessions via `URLSession?` default. Added 400-attempt cap to OAuth polling loop with distinct timeout vs. max-attempts failure messages.
- [x] **A2. UX quick-wins batch** — help tooltips on icon-only buttons, bump secondary text contrast to opacity 0.75, restore menu-indicator automatic on dropdown buttons, ellipsis plus tooltip on tile subtitles, empty-state when search field cleared.
  - note: Threaded a `help:` parameter through `controlButton` in MiniPlayer/NowPlaying and added tooltips on play/pause, prev/next, skip, like, shuffle, repeat, more, add-to-playlist, sleep timer, playback rate, and the Library sort menu. Swept secondary `foregroundStyle(.white.opacity(0.5/0.55/0.6))` → `0.75` across 15 UI files. Removed `.menuIndicator(.hidden)` on the three label-style dropdowns (Library sort, sleep timer, playback rate) while keeping it hidden on icon-only overflow menus (•••, add-to-playlist plus). Added `.help(title — subtitle)` and explicit tail truncation on `ThumbnailButton` tiles. Added `InitialSearchState` "Find your music" empty state so the Search tab no longer renders blank before the user types.
- [x] **A3. Sleep timer: fade-out + end-of-track modes** — extend existing timer with gentle 10s volume ramp to silence, and "stop after current track ends". Spotify still does not ship this on desktop.
  - note: Added `PlayerBridge.SleepTimerMode` (`.hardStop` / `.fadeOut` / `.endOfTrack`) and a `setSleepTimer(minutes:mode:)` overload defaulting to `.hardStop` for back-compat. `.fadeOut` runs a 10-step linear ramp on `<video>.volume` (multiplying the user's current volume by an interpolated factor so the fade scales with whatever level they picked), then pauses and re-pushes the persisted volume to the JS bridge. `.endOfTrack` flips a new `endOfTrackArmed` flag; the existing `.ended` event handler honors it by pausing instead of advancing to user-queued items. `cancelSleepTimer` restores the JS-side volume if cancel lands mid-fade. NowPlaying sleep menu refactored into per-duration `Stop` / `Fade out (10s)` submenus plus a top-level "End of current track" entry; tooltip + small `EOT` chip surface the active mode without reopening the menu. Added `SleepTimerModeTests` to guard the enum + 10s constant against silent renames.
- [x] **A4. Audio-to-Video toggle on Now Playing** — pill at top of Now Playing that swaps between audio-only and the official music video, preserving currentTime. YT Music's defining feature; currently hidden.
  - note: Added `PlayerBridge.isVideoVisible` (defaults false) plus a `hostedWebView` accessor and `reattachWebViewOffscreen()` helper that delegates to a new `HiddenPlayerWebView.reattachToOffscreenWindow()`. NowPlaying's top bar gains a Song / Video segmented pill (Theme.red highlight on the active side); flipping to Video swaps the 320×320 artwork for a new `VideoPaneView` NSViewRepresentable that reparents the existing offscreen WKWebView into a 480×270 (16:9) rounded pane. Same `<video>` keeps playing so currentTime / audio are preserved across the toggle with no seek. Coordinator + `dismantleNSView` reattach the WebView to its 1×1 offscreen window when the pane is removed; `.onDisappear` + the Close / ESC paths also force `isVideoVisible = false` so the architectural rule (WebView never visible outside this opt-in pane) holds on next open. Strict Swift 6: VideoPaneView's makeNSView / updateNSView / Coordinator are explicitly `@MainActor`; `dismantleNSView` uses `MainActor.assumeIsolated`.
- [x] **A5. "Other performances" row** — surface live, acoustic, and cover versions from /next response. We already fetch this data and throw it away.
  - note: Added `InnerTubeClient.relatedSections(browseId:)` + a static `parseRelatedSections(_:)` helper that walks the Related-tab browse response (single-column, two-column desktop, and the bare `sectionListRenderer` shape) and returns each `musicCarouselShelfRenderer` as a titled `HomeSection`, reusing `parseHomeShelf` so the visual treatment matches Home rails. Previously `related(browseId:)` flattened everything via `scanForMediaItems` and dropped the shelf titles on the floor — the live / acoustic / cover variants were in the response all along. PlayerBridge gained a `relatedSections: [HomeSection]` field (blocked-artist filtered just like `related`), reset on every track change, and `loadRelatedIfNeeded()` now fetches both flat items and sections in parallel via `async let` so the Related tab opens in the same single round-trip. NowPlayingView's `relatedContent` looks up the shelf whose title contains "other version" / "other performance" (case-insensitive, locale-tolerant) and renders it as a compact 110×110 horizontal rail above the flat related queue, with TrackContextMenu on each tile so users can queue a variant without leaving Now Playing. Added `InnerTubeParserTests.testParseRelatedSectionsSurfacesTitledShelves` + `testParseRelatedSectionsEmptyOnUnknownShape` to guard the parser against renderer drift.
- [x] **A6. Floating Mini Player window** — SwiftUI WindowGroup with floating level, resizable down to a compact tile, hover-reveal controls. Cmd-Opt-M opens.
  - note: Reworked `FloatingMiniPlayerView` from a fixed 360×70 strip into a resizable artwork tile. Artwork fills the window (`AsyncImage` + `aspectRatio(.fill)` + `clipped`); a bottom gradient hosts title/subtitle so the resting state stays glanceable. Transport row (prev / play / next) is hover-reveal — `@State private var isHovering` toggled by `.onHover`, scrim + buttons fade in via `.opacity` + `.animation(.easeInOut(duration: 0.15))`, and `.allowsHitTesting(isHovering)` prevents the invisible scrim from intercepting window-drag gestures when the pointer is outside. Tile carries `frame(minWidth: 280, minHeight: 140)` to enforce the spec's compact minimum. RiffApp's `Window` scene swapped `defaultSize(360×70)` → `defaultSize(320×180)` and `windowResizability(.contentSize)` → `.contentMinSize` so the user can grow the tile freely but not shrink below the 280×140 minimum. ⌥⌘M shortcut (`MiniPlayerMenuItem`) + `.floating` level + all-spaces collection behavior + right-click `TrackContextMenu` all preserved from the previous incarnation. No second WKWebView — the window is a pure SwiftUI surface onto the same `env.player`, satisfying the architectural rule.
- [x] **A7. Menu bar mini player** — MenuBarExtra with artwork, title, scrubber, transport. Quintessential macOS power-user feature.
  - note: Added a `MenuBarExtra` scene to `RiffApp.swift` (alongside the main `WindowGroup` and the A6 floating `Window("Mini Player")`) plus a new `Sources/UI/Player/MenuBarMiniPlayer.swift` housing the popover view (`MenuBarMiniPlayer`) and the menu-bar glyph (`MenuBarMiniPlayerLabel`). Popover is fixed-width 280pt: 44×44 artwork tile + title/subtitle, a Theme.red progress capsule with `m:ss` elapsed / `-m:ss` remaining timestamps (monospaced digits so they don't shove the bar around), prev / play-pause / next transport row, and a footer with "Open Mini Player" (`openWindow(id: "mini-player")`, ⌥⌘M to match A6) + "Quit Riff" (⌘Q). Reads from the same `env.player` — no second WKWebView, honors the architectural rule. Empty state stays intentional: artwork shows a `music.note` SF Symbol, transport buttons disable via `!env.player.hasTrack`, progress strip collapses. The menu-bar label is an SF Symbol that mirrors transport state (`play.fill` playing, `pause.fill` paused, `music.note` idle) so users can read playback state at a glance without opening the popover. Style is `.menuBarExtraStyle(.window)` for the rich popover, not the menu style. Runtime-toggleable via a new `AppEnvironment.menuBarExtraEnabled` (defaults true, persisted under `ui.menuBarExtraEnabled` in UserDefaults, `object(forKey:)` read so first-launch absence is distinguishable from explicit-false), bound through a hand-rolled `Binding<Bool>` into the scene's `isInserted:` so the menu bar item appears/disappears live without relaunch. Added an "Interface" section to `SettingsView` between Playback and Library access with the toggle + a one-paragraph rationale.
- [x] **A8. Block-artist button inline on Artist detail page** — already in Settings and context menu; surfacing inline saves two clicks.
  - note: Added an inline `blockArtistButton(page:)` helper to `DetailView` and conditionally render it in the header action row alongside Play / Shuffle when `item.kind == .artist`. State-aware: SF Symbol + label flip between `hand.thumbsdown` "Don't Recommend" and `hand.thumbsup` "Recommend Again" based on `env.isBlocked(artistId:)`, so the same control is also the unblock affordance — no Settings round-trip to undo a misclick. Uses `page.title` (with `item.title` fallback) for the captured human-readable name to avoid the stale-subtitle problem when arriving via "Go to artist" from a song row where the artist segment may have been truncated. `.help(...)` tooltip explains the across-Home/Search/radio scope and points to Settings → Library for bulk management. Mirrors `env.blockArtist(id:name:)` / `env.unblockArtist(id:)` — same code paths the context menu and Settings already exercise, no new model surface.
- [ ] **A9. Mood / activity chip row on Home** — render the mood chips InnerTube already returns ("Focus", "Workout", "Sleep", "Commute") as a horizontal strip above Home carousels.

### Tier B: Ship next month (parity + macOS-native moves)

- [ ] **B1. Always-on Stats / Replay dashboard** — keep Recap's stats math but expose year-round with 7-day, 30-day, 90-day views. Apple Music does this.
- [ ] **B2. Live time-synced lyrics (karaoke-style)** — word-by-word highlight (not just line-by-line), tap to seek. Apple Music's Sing feature, minus the vocal-attenuation we cannot do.
- [ ] **B3. Lyric translation + pronunciation (BYO-LLM)** — toggle on lyrics tab; Claude translates each line to a user-selected language, optional romanized pronunciation below. Cache per videoId.
- [ ] **B4. X-Ray context cards (BYO-LLM)** — swipe-up panel on Now Playing; Claude generates cards for lyric references (people, places, events). No licensed data needed.
- [ ] **B5. Smart Shuffle with plus badge** — when shuffle is on, every Nth slot in upNext is a recommendation from /related, marked with a plus badge. Spotify's pattern.
- [ ] **B6. Pinned Library + smart filters** — drag-pin items to top of Library, treat Liked Songs as a real filterable playlist (sort by play count, recently added, last played).
- [ ] **B7. Smart sorts on every list surface** — Recently Added, Last Played, Play Count, A-Z, Duration menus, sticky per surface.
- [ ] **B8. Crossfade between tracks** — JS-side cross-fade by overlapping volume ramp on track-end. 80% of Apple's AutoMix quality without needing raw audio.
- [ ] **B9. Notification Center Now Playing widget** — WidgetKit ControlWidget.
- [ ] **B10. AirPlay / output device picker** — AVRoutePicker on the transport row.
- [ ] **B11. Endless scroll on Home / Library / Search** — InnerTube continuation tokens are supported; we currently single-shot every browse.

### Tier C: Differentiators (longer-form / experimental)

- [ ] **C1. AI DJ voice narrator (BYO-LLM + TTS)** — between tracks, Claude generates 8-15s commentary, AVSpeechSynthesizer voices it, PlayerBridge ducks the next track's intro.
- [ ] **C2. Daylist with flavor-text titles** — auto-refreshing playlist updates 4-6x per day with a Claude-authored evocative title. The title IS the magic.
- [ ] **C3. Smart Sections (custom user-defined Home rows)** — user writes a prompt ("post-rock albums I haven't played in 6 months"), Claude compiles to a query over local history plus InnerTube search, renders as a permanent Home row. Marvis Pro's killer feature, un-replicable by the big four.
- [ ] **C4. "Explain this queue" / "Ask about your year" panel** — button in Up Next header; Claude reads the queue and writes a 2-3 sentence vibe summary. Also a chat over local play history.
- [ ] **C5. Magazine-style Artist pages (Roon-inspired)** — BYO-LLM-generated artist bio, long-form layout with discography arc, top tracks rail.
- [ ] **C6. Track Credits drill-through (Tidal-inspired)** — producer, engineer, songwriter chips on each track; tap to see every other track that person touched.
- [ ] **C7. Album Collections (Doppler-inspired)** — user-grouped album bundles separate from playlists.
- [ ] **C8. Wrapped-style cinematic Stats stories** — full-screen tap-to-advance cards of listening data with motion + aura colors. Annual viral moment, re-usable for monthly recaps.

### Tier D: Open-ecosystem / power-user

- [ ] **D1. last.fm + ListenBrainz scrobbling** — optional sign-in via API key. Frees users from Riff's data silo. Distinctive "this respects you" signal.
- [ ] **D2. On-device metadata overrides** — user edits title, artist, album per track; Riff respects override everywhere. Fixes mislabeled "feat." chaos, transliteration, classical attribution.
- [ ] **D3. Followed-artist feed (Bandcamp-inspired)** — chronological feed of new releases from subscribed artists.
- [ ] **D4. AppleScript / Shortcuts.app expansion** — extend the App Intents foundation; add "what's playing", "play playlist X", "set rate", "open station for X".
- [ ] **D5. Local-web Remote (Cider-inspired)** — phone-as-remote via a local web page over Wi-Fi.
- [ ] **D6. Hum-to-Search via ShazamKit** — tap waveform icon, record 10s, ShazamKit matches, route the result through InnerTube.search. Apple-native APIs, no audio-extraction concerns.
- [ ] **D7. Auto context-mode (Endel-inspired, BYO-LLM-routed)** — time-of-day + calendar + focus state auto-selects a YT Music mood mix.
- [ ] **D8. Drag-to-reorder Up Next** — SwiftUI onMove on the upNext list.
- [ ] **D9. EQ presets** — BiquadFilterNode chain in the existing Web Audio graph we built for volume normalization; ship 5-6 presets.

### Tier E: Previously-skipped, user-reopened (scope-with-blockers)

User reopened these on 2026-06-18 after they had been initially deferred. Each one has a real blocker; the scope below is what we CAN realistically ship within Riff's constraints (no audio extraction, no telemetry server, no Premium paywall data).

- [ ] **E1. Blend / Jam / Friend Activity** — full implementation needs identity + a sync server (incompatible with no-telemetry rule). **Scoped target:** local-network co-listening over Bonjour. Two Riff instances on the same Wi-Fi can discover each other, share an Up Next queue, and one drives playback for both (the other mirrors via the local-web Remote primitive — depends on D5). A "Friend Activity" rail surfaces who is currently listening on the LAN. No cloud, no identity beyond a per-instance display name.
- [ ] **E2. Samples vertical short-video feed** — full vertical-TikTok UX is awkward on a 27" Mac display. **Scoped target:** a "Discover clips" horizontal rail on the Explore tab — same data source (30-second music-video previews from /next continuations), but laid out as a horizontal carousel with autoplay-on-hover. Tap to play the full song; star to add to a Discover playlist. Keep the swipeable-card variant behind a Settings toggle for the users who DO want full vertical.
- [ ] **E3. Background "new release" notifications** — macOS doesn't run our process in the background without a LaunchAgent (which has user-trust implications). **Scoped target:** foreground-only refresh — when Riff is running, poll subscribed-artists once an hour and post a UserNotification for any release dated in the last 24h. No background daemon. Document the trade-off (must keep Riff open to receive) in the Settings toggle copy.
- [ ] **E4. Local file playback** — large scope (file picker, indexer, mixed queue, metadata extraction, format support). **Scoped first cut:** drag-and-drop a single file onto the player to play it via a separate AVPlayer (NOT the WKWebView audio path). No library indexing yet. Mixed queue (local + YT in same Up Next) is deferred until format coverage settles. ID3 tag extraction via AVAsset for the Now Playing strip.
- [ ] **E5. Crossfade between tracks (covers part of "AutoMix")** — beat-matched AutoMix needs raw audio WKWebView hides; vocal attenuation for karaoke needs DSP on raw audio. **Scoped target:** the JS-side volume crossfade already in B8. Track this as the realistic delivery; mark beat-match + vocal attenuation as permanently blocked by the architectural rule. If a future re-architecture surfaces raw audio (e.g., InnerTube returns a direct stream URL), revisit then.
- [ ] **E6. Personal timestamped annotations on tracks** — public-track-wide comments require a server graph we don't run, and YT doesn't expose its own comment graph for arbitrary tracks via InnerTube. **Scoped target:** PRIVATE timestamped notes per track ("the drop", "use for intro"), stored locally per videoId. Renders as small markers on the scrubber. Personal-only — no sharing, no public surface.

Each E-item carries a real trade-off in its scope statement — the Ralph agent picking these up should respect those scopes and not try to ship the full-fat version that the original Skip-list entry rejected.

### Permanently blocked (no realistic scope under current architecture)

- **Beat-matched AutoMix** — needs raw audio access (time-stretch, beat detection). WKWebView's `<video>` element exposes volume control only. Re-evaluate if we ever stop using the WebView as the audio engine.
- **Vocal attenuation in karaoke mode** — same underlying constraint (DSP on raw PCM). The Lyrics tab still ships a karaoke surface (B2) without the vocal-pull-down.
- **Public comments on YT tracks** — no source. We don't run a server with a comment graph; YT's own comment data isn't exposed via InnerTube for music tracks (only for the video twin, and not via any of the endpoints we currently call). Personal annotations (E6) are the achievable alternative.

## Sequencing recommendation

**Week 1**: A1 (bugs) + A2 (UX wins). Pure cleanup.

**Week 2**: A4 (audio-to-video) + A5 (other performances) + A8 (block inline) + A9 (mood chips). Free wins from data we already fetch.

**Week 3**: A6 (Mini Player window) + A7 (Menu bar). macOS-native chrome.

**Week 4**: A3 (sleep modes) + B1 (Always-on Stats) + B6 (Pinned Library). Library polish.

Beyond that: pick from Tier B in any order. Tier C (BYO-LLM-heavy) is the differentiation play once the foundation feels solid. Tier D is opportunistic — D1 (scrobbling) is the cheapest and most-distinctive.
