# Plan: Tier 2-5 Backlog Rollout

slug: tier-2-5-roadmap
created: 2026-06-13T23:15:00Z
status: executing        # draft → approved → executing → done

## Findings

- `BrowseID.explore` and `BrowseID.moodsAndGenres` constants exist in
  [Endpoints.swift](../../Sources/Data/InnerTube/Endpoints.swift) but no
  `InnerTubeClient` method consumes them yet. Explore tab is "wire it up +
  add views" not "discover endpoints."
- Uncommitted Sleep Timer + Continue-Where-You-Left-Off code from the
  interrupted prior turn lives in `PlayerBridge.swift`, `AppEnvironment.swift`,
  `NowPlayingView.swift`. Build hit a sandbox issue (DerivedData write
  blocked), never a real compile error. Step 1 verifies + commits.
- `MediaItem` has no `duration` / `year` fields — both Search filters (#4)
  AND Year-end Recap (#5) want them; a single parser pass adds them once.
- No block-list anywhere. "Don't recommend artist" is new persisted state on
  `AppEnvironment`, enforced by post-fetch filtering of `upNext` / `related`
  / Home / Search.
- `AppTab` is at `Sources/App/AppEnvironment.swift:8` with `.home / .search /
  .library`. Explore tab = 1-line enum case + `TopTabBar` entry + ⌘4 shortcut.
- CI green on `main` (last `f07c092`). Twenty-five tests passing. Each step
  must end green before the next starts.

## Steps

- [x] **1. Verify + commit Sleep Timer + Continue Where You Left Off**
      files: PlayerBridge.swift, AppEnvironment.swift, NowPlayingView.swift
      verification: CI green on the pushed commit
- [ ] **2. "Don't recommend artist" block-list**
      files: AppEnvironment.swift, PlayerBridge.swift, TrackContextMenu.swift,
             HomeView.swift, SearchView.swift, SettingsView.swift
- [ ] **3. MediaItem.duration + year (data-model precursor)**
      files: Models/MediaItem.swift, InnerTubeClient.swift, InnerTubeParserTests.swift
- [ ] **4. Search filters: year + duration** (depends on #3)
      files: SearchView.swift, SearchResultRow.swift
- [ ] **5. Year-end Recap** (depends on #3 for richness)
      files: new Sources/UI/Recap/RecapView.swift, AppEnvironment.swift, RiffApp.swift
- [ ] **6. Mixed-for-you Library section**
      files: LibraryView.swift, InnerTubeClient.swift
      prework: confirm `FEmusic_mixed_for_you` browseId against live YT Music
- [ ] **7. Explore tab** (largest single step)
      files: AppEnvironment.swift, RiffApp.swift, new Sources/UI/Explore/ExploreView.swift,
             InnerTubeClient.swift (new explore() + moodsAndGenres())
- [ ] **8. Volume normalization toggle (approximate)**
      files: PlayerBridge.swift, Resources/player-bridge.js, SettingsView.swift
- [ ] **9. Per-kind playback rate defaults**
      files: PlayerBridge.swift, NowPlayingView.swift, Tests/QueueAndResolverTests.swift
- [ ] **10. Share URL + Lyric image cards**
      files: PlayerBridge.swift, TrackContextMenu.swift, new Sources/UI/LyricCardSheet.swift
- [ ] **11. Phase 3 — App Intents (Spotlight + Siri + Shortcuts)**
      files: new Sources/Intents/RiffIntents.swift, project.yml
- [ ] **12. Phase 3 — BYO-LLM (Anthropic + queue builder)**
      files: new Sources/AI/LLMProvider.swift, AnthropicProvider.swift,
             SettingsView.swift, new Sources/UI/Player/QueueBuilderSheet.swift

## Out of scope

- Sound Search (hum-to-find)
- App Store / Sparkle / Notarization (gated on Apple Developer account)
- Repeat-all mode
- Server-sync of playNext / removeFromQueue
- Drag-and-drop Up Next reorder

## Verification (between every step)

1. Push commit → CI must go green at <https://github.com/mvk24199/Riff/actions>.
2. Test suite stays ≥25 passing, growing as each step adds tests.
3. Smoke-test in the running app for UI-visible changes.
4. `/vajra review` on the diff before commit for steps 4 / 5 / 7 / 11 / 12.

End-of-plan exit: all steps checked, CI green on the final commit,
phase back to `explore`.
