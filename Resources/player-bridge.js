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

    // Capture-phase autoplay override. The DOM event model runs capture
    // listeners (top → target) BEFORE target-phase listeners. YT Music
    // attached its target-phase ended listener when its app initialized;
    // installing ours here in capture phase on `window` guarantees we
    // run first. If a user-queued URL is pending we consume it, stop
    // propagation so YT's listener never fires, and navigate ourselves.
    //
    // Done at documentStart (this IIFE runs before YT's app boot) so
    // the listener is in place before any <video> exists. Listening on
    // `window` because the actual <video> element is created later by
    // YT's app code; capture phase walks from window → document → ...
    // → video, so we catch ended at the topmost capture point.
    window.addEventListener("ended", (e) => {
        const t = e.target;
        if (!t || (t.tagName !== "VIDEO" && t.tagName !== "AUDIO")) return;
        const pending = window.__riffPendingNextUrl;
        if (!pending) return;
        // Stop YT Music's target-phase ended handler from running so
        // it can't trigger its own autoplay before we navigate.
        e.stopImmediatePropagation();
        window.__riffPendingNextUrl = null;
        // Pause to make sure the page doesn't keep playing the just-
        // ended media into the navigation window. location.href will
        // unload the page anyway, but the pause is belt-and-braces.
        try { t.pause(); } catch (_) {}
        postEvent({ event: "riffNavigatedTo", url: pending });
        location.href = pending;
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
