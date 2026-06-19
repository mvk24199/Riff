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
- [ ] **A4. Audio-to-Video toggle on Now Playing** — pill at top of Now Playing that swaps between audio-only and the official music video, preserving currentTime. YT Music's defining feature; currently hidden.
- [ ] **A5. "Other performances" row** — surface live, acoustic, and cover versions from /next response. We already fetch this data and throw it away.
- [ ] **A6. Floating Mini Player window** — SwiftUI WindowGroup with floating level, resizable down to a compact tile, hover-reveal controls. Cmd-Opt-M opens.
- [ ] **A7. Menu bar mini player** — MenuBarExtra with artwork, title, scrubber, transport. Quintessential macOS power-user feature.
- [ ] **A8. Block-artist button inline on Artist detail page** — already in Settings and context menu; surfacing inline saves two clicks.
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

### Skip list (explicit non-goals)

- Blend / Jam / Friend Activity (Spotify social) — requires identity + server infrastructure incompatible with no-telemetry rule.
- Samples vertical short-video feed — awkward UX on a 27 inch Mac display; horizontal "Discover clips" carousel covers the value.
- Background notifications for new releases — until we have a background-refresh story.
- Local file playback — large scope; defer to Phase 4.
- Beat-matched AutoMix and karaoke vocal attenuation — need raw audio access WKWebView hides from us.
- Public timestamped comments — no comment graph exists for YT tracks.

## Sequencing recommendation

**Week 1**: A1 (bugs) + A2 (UX wins). Pure cleanup.

**Week 2**: A4 (audio-to-video) + A5 (other performances) + A8 (block inline) + A9 (mood chips). Free wins from data we already fetch.

**Week 3**: A6 (Mini Player window) + A7 (Menu bar). macOS-native chrome.

**Week 4**: A3 (sleep modes) + B1 (Always-on Stats) + B6 (Pinned Library). Library polish.

Beyond that: pick from Tier B in any order. Tier C (BYO-LLM-heavy) is the differentiation play once the foundation feels solid. Tier D is opportunistic — D1 (scrobbling) is the cheapest and most-distinctive.
