# Riff — a YouTube Music client for macOS

A native, open-source **YouTube Music desktop app for macOS**, built in SwiftUI, designed to feel like the YouTube Music **iOS** app — not Apple Music.

## Why this exists

There's no first-party YouTube Music app on the Mac App Store. The two leading open-source options each fall short:

- **[th-ch/youtube-music](https://github.com/th-ch/youtube-music)** is an Electron `BrowserWindow` wrapping `music.youtube.com`. It works, but it's a web page in a chrome.
- **[sozercan/kaset](https://github.com/sozercan/kaset)** is SwiftUI chrome around the same web page. It looks more native at a glance, but you can't click a thumbnail to play, and the UI ends up reading as a "cheap Apple Music clone."

This project inverts that architecture: **all** browse, search, library, and player UI is real SwiftUI fed by an InnerTube client. The WKWebView is **invisible** — it exists only to play audio, including DRM-protected YouTube Premium tracks via Widevine.

## Differentiators

- 🎯 **Click any thumbnail to play.** The single biggest gap in Kaset is filled here.
- 🎨 **YouTube Music iOS aesthetic.** Dark theme, large rounded thumbnails, generous spacing, red `#FF0033` accent — not Apple Music's sidebar.
- 🎙 **Podcasts as first-class.** YT Music's full catalogue (songs, albums, artists, playlists, podcasts), not just music.
- 🍎 **Apple Intelligence integration** *(Phase 3)* — Siri, Spotlight, Shortcuts via App Intents. *"Hey Siri, play my Focus playlist."*
- 🤖 **Bring-your-own-LLM** *(Phase 3)* — paste an Anthropic / OpenAI / Gemini key, or run Ollama locally. Unlocks natural-language queue building, lyrics explainers, mood-tagging your library. The first YT Music client where the AI is fully under your control.
- 🔒 **Premium-quality audio** via Widevine. No stream extraction, no fragile InnerTube `/player` workarounds.
- 🛠 **Open source under AGPL-3.0** — same license as ViMusic; prevents proprietary forks.

## Status

🚧 **Pre-MVP.** See [`PLAN.md`](PLAN.md), [`docs/PRODUCT_SPEC.md`](docs/PRODUCT_SPEC.md), and [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

> **Sign-in note**: Google blocks Google-account sign-in inside embedded
> webviews on macOS. Anonymous browse + click-to-play work fully today; the
> Library tab requires sign-in, which is implemented as a stub that surfaces
> the wall. Proper Phase 2 fix is OAuth Device Flow (TV-style code entry),
> tracked in PLAN.md.

## Roadmap

| Phase | Scope | Target |
|---|---|---|
| **MVP (Phase 1)** | Sign-in · Home · Search · read-only Library · click-to-play from thumbnails · Mini Now Playing bar · macOS Now Playing / media keys · YT Music iOS look | 3-4 weeks |
| **Phase 2** | Queue editing · Playlist editing · Synced lyrics · Album/Artist/Playlist detail pages · Dedicated Podcasts UX (speed, skip ±15/30s) · Floating mini player · Settings · History | 4-6 weeks |
| **Phase 3** | Smart radio · Activities/moods · AirPlay 2 · Multi-account · Background playback · EQ — **plus** Apple Intelligence (App Intents, Writing Tools) and BYO-LLM (Anthropic/OpenAI/Gemini/Ollama) | 2-3 months |
| **Phase 4** | Plugin system · advanced AI (hum-to-search, AI artwork) · cross-platform fork point | open-ended |

## Building

> Once XcodeGen is wired up:
>
> ```sh
> brew install xcodegen
> xcodegen generate
> open Riff.xcodeproj
> ```

Requires macOS 14+ and Xcode 15+.

## Architecture in one paragraph

SwiftUI app. All visible views are real SwiftUI — no embedded web pages. An `InnerTubeClient` (Swift, native) hits `music.youtube.com/youtubei/v1/{search,browse,next,player}` for data. A hidden, offscreen `WKWebView` loaded with `music.youtube.com` is the audio engine; SwiftUI controls it via `evaluateJavaScript`, and the page's MediaSession events bubble back through `WKScriptMessageHandler` into `MPNowPlayingInfoCenter`. Premium DRM works because audio plays through WebKit's native Widevine path. Full design rationale: [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

## Disclaimer

This project is not affiliated with, endorsed by, or sponsored by Google or YouTube. Users supply their own Google/YouTube account and must comply with YouTube's Terms of Service. The app does not download, redistribute, or DRM-strip any audio.

## License

AGPL-3.0. See [`LICENSE`](LICENSE).
