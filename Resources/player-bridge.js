/*
 * player-bridge.js
 *
 * Injected into music.youtube.com at documentStart by the hidden WKWebView.
 * Exposes window.musicBridge.{playVideo, playAlbum, playPlaylist, playPodcast,
 * playArtistRadio, togglePlay, next, previous, seek, getState} so the Swift
 * side can drive playback through a stable surface, regardless of how YT Music
 * restructures its internals.
 *
 * Also wires navigator.mediaSession events back to Swift via
 * webkit.messageHandlers.bridge.postMessage(...).
 */

(function () {
    "use strict";

    function videoEl() { return document.querySelector("video"); }

    function postEvent(payload) {
        try {
            window.webkit.messageHandlers.bridge.postMessage(payload);
        } catch (_) {}
    }

    const api = {
        // Single navigation primitive: Swift builds the full /watch?v=&list=
        // URL (after resolving any browseId on the Swift side) and tells the
        // page to load it. The /watch route auto-plays.
        navigate(url) { location.href = url; },
        togglePlay() { const v = videoEl(); if (!v) return; v.paused ? v.play() : v.pause(); },
        setPlaybackRate(rate) { const v = videoEl(); if (v) v.playbackRate = rate; },
        skipBy(seconds) {
            const v = videoEl();
            if (v && isFinite(v.duration)) {
                v.currentTime = Math.max(0, Math.min(v.duration, v.currentTime + seconds));
            }
        },
        setVolume(level) {
            const v = videoEl();
            if (v) v.volume = Math.max(0, Math.min(1, level));
        },
        // Repeat-one is implemented natively on the <video> element via
        // the loop attribute. When loop=true, the browser restarts the
        // current source at end-of-stream and YT Music's autoplay
        // never fires — clean per-track repeat with no DOM dependence.
        // Repeat-off lets the page's natural autoplay continue.
        setRepeatLoop(enabled) {
            const v = videoEl();
            if (v) v.loop = !!enabled;
        },
        // Park a URL on the page so that when the current track ends,
        // the `ended` listener navigates synchronously to it —
        // beating YT Music's own autoplay handler. The empty string
        // (or any falsy value) clears it. Set by Swift whenever the
        // head of upNext is a user-queued track; cleared when the
        // user-queued track itself starts playing (Swift will push
        // the next user-queued URL, if any, or clear).
        setPendingNextURL(url) {
            window.__riffPendingNextUrl = url || null;
        },
        next()       { document.querySelector(".next-button")?.click(); },
        previous()   { document.querySelector(".previous-button")?.click(); },
        seek(fraction) {
            const v = videoEl();
            if (!v || !isFinite(v.duration)) return;
            v.currentTime = Math.max(0, Math.min(v.duration, v.duration * fraction));
        },
        getState() {
            const v = videoEl();
            return v ? { paused: v.paused, currentTime: v.currentTime, duration: v.duration } : null;
        },
    };

    window.musicBridge = api;

    // Autoplay override — TWO mechanisms because YT Music doesn't
    // fire the standard <video>.ended event. They advance tracks via
    // MSE source-swap (Media Source Extensions), which means our
    // capture-phase ended listener never gets to run.
    //
    // (a) Capture-phase ended listener — kept as a fallback for the
    //     rare case where ended actually does fire (some streaming
    //     transitions, some podcast contexts).
    // (b) timeupdate-based end-of-stream detection — the real workhorse.
    //     timeupdate fires ~4×/sec during playback. When currentTime
    //     approaches duration we fire the pending navigation ourselves,
    //     beating YT's MSE source-swap to the punch.
    window.addEventListener("ended", (e) => {
        const t = e.target;
        if (!t || (t.tagName !== "VIDEO" && t.tagName !== "AUDIO")) return;
        if (!window.__riffPendingNextUrl) return;
        e.stopImmediatePropagation();
        const url = window.__riffPendingNextUrl;
        window.__riffPendingNextUrl = null;
        try { t.pause(); } catch (_) {}
        postEvent({ event: "riffNavigatedTo", url: url, via: "ended" });
        location.href = url;
    }, true /* capture */);

    // (b) timeupdate-based intercept. Triggers when currentTime is
    // within `EOT_WINDOW` seconds of duration AND a pending URL is
    // set. Idempotent — once we navigate, the page unloads. A guard
    // flag prevents double-fires from rapid timeupdate events in
    // that small window.
    //
    // EOT_WINDOW = 0.6s: small enough that we don't pre-empt the
    // last bit of a song the user wants to hear; large enough that
    // even at 4Hz timeupdate cadence we catch it before YT advances.
    const EOT_WINDOW = 0.6;
    let __riffEotFired = false;
    window.addEventListener("timeupdate", (e) => {
        const t = e.target;
        if (!t || (t.tagName !== "VIDEO" && t.tagName !== "AUDIO")) return;
        const pending = window.__riffPendingNextUrl;
        if (!pending) {
            // Reset the fire flag whenever there's nothing pending —
            // so the next time a URL is parked, we can fire again.
            __riffEotFired = false;
            return;
        }
        if (__riffEotFired) return;
        const dur = t.duration;
        const cur = t.currentTime;
        if (!isFinite(dur) || dur <= 0) return;
        if (cur < dur - EOT_WINDOW) return;
        // End-of-stream window reached and a URL is parked. Fire.
        __riffEotFired = true;
        const url = pending;
        window.__riffPendingNextUrl = null;
        try { t.pause(); } catch (_) {}
        postEvent({ event: "riffNavigatedTo", url: url, via: "timeupdate" });
        location.href = url;
    }, true /* capture */);

    // Wire MediaSession + video element events back to Swift.
    function attachEvents() {
        const v = videoEl();
        if (!v || v.__bridgeAttached) return;
        v.__bridgeAttached = true;
        v.addEventListener("play",       () => postEvent({ event: "stateChanged", isPlaying: true }));
        v.addEventListener("pause",      () => postEvent({ event: "stateChanged", isPlaying: false }));
        v.addEventListener("timeupdate", () => postEvent({ event: "progress", currentTime: v.currentTime, duration: v.duration }));
        // Target-phase ended listener — fires alongside YT Music's
        // own listener but in arbitrary order. Used only for the
        // stateChanged notification + the "ended" event back to
        // Swift; the navigation override lives in a capture-phase
        // listener installed on `window` below (which fires BEFORE
        // any target-phase listener, including YT's).
        v.addEventListener("ended", () => {
            postEvent({ event: "ended" });
            postEvent({ event: "stateChanged", isPlaying: false });
        });
    }

    // Watch navigator.mediaSession.metadata + the URL videoId together — that
    // pair changes whenever the page advances to a new track. Polling is the
    // most reliable signal; YT Music doesn't fire a public event we can hook.
    // Track the last-seen playlistId across pollTrack ticks. YT Music's SPA
    // strips the `list` URL param once a track is playing, but the user
    // is still inside the playlist context — so we cache the last
    // non-null value and keep reporting it on subsequent ticks until the
    // user navigates somewhere that explicitly clears it.
    let stickyPlaylistId = null;
    let lastTrackKey = "";
    function findPlaylistId() {
        const url = new URL(location.href);
        // 1. Direct URL param (truthful right after navigation).
        let id = url.searchParams.get("list");
        if (id) return id;
        // 2. Sometimes YT Music keeps it in the hash route.
        if (location.hash) {
            const hashUrl = new URL(location.hash.slice(1), location.origin);
            id = hashUrl.searchParams.get("list");
            if (id) return id;
        }
        // 3. Look for a queue link in the DOM that includes ?list=.
        const link = document.querySelector('a[href*="list="]');
        if (link) {
            try {
                const href = new URL(link.href, location.origin);
                id = href.searchParams.get("list");
                if (id) return id;
            } catch (_) { /* ignore malformed */ }
        }
        return null;
    }
    function pollTrack() {
        const md = navigator.mediaSession && navigator.mediaSession.metadata;
        const url = new URL(location.href);
        const videoId = url.searchParams.get("v");
        const found = findPlaylistId();
        if (found) stickyPlaylistId = found;
        const playlistId = stickyPlaylistId;
        if (!md || !videoId) return;
        const key = videoId + "|" + (md.title || "") + "|" + (playlistId || "");
        if (key === lastTrackKey) return;
        lastTrackKey = key;
        const artwork = (md.artwork && md.artwork.length > 0) ? md.artwork[md.artwork.length - 1].src : null;
        postEvent({
            event: "trackChanged",
            videoId: videoId,
            playlistId: playlistId,
            title:   md.title  || "",
            artist:  md.artist || "",
            artwork: artwork,
        });
    }
    setInterval(pollTrack, 500);

    // Re-attach as the page reorders the DOM.
    new MutationObserver(attachEvents).observe(document.documentElement, { childList: true, subtree: true });
    document.addEventListener("DOMContentLoaded", () => {
        attachEvents();
        postEvent({ event: "ready" });
    });
})();
