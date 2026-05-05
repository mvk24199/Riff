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

    // Wire MediaSession + video element events back to Swift.
    function attachEvents() {
        const v = videoEl();
        if (!v || v.__bridgeAttached) return;
        v.__bridgeAttached = true;
        v.addEventListener("play",       () => postEvent({ event: "stateChanged", isPlaying: true }));
        v.addEventListener("pause",      () => postEvent({ event: "stateChanged", isPlaying: false }));
        v.addEventListener("timeupdate", () => postEvent({ event: "progress", currentTime: v.currentTime, duration: v.duration }));
        v.addEventListener("ended",      () => postEvent({ event: "stateChanged", isPlaying: false }));
    }

    // Watch navigator.mediaSession.metadata + the URL videoId together — that
    // pair changes whenever the page advances to a new track. Polling is the
    // most reliable signal; YT Music doesn't fire a public event we can hook.
    let lastTrackKey = "";
    function pollTrack() {
        const md = navigator.mediaSession && navigator.mediaSession.metadata;
        const videoId = new URL(location.href).searchParams.get("v");
        if (!md || !videoId) return;
        const key = videoId + "|" + (md.title || "");
        if (key === lastTrackKey) return;
        lastTrackKey = key;
        const artwork = (md.artwork && md.artwork.length > 0) ? md.artwork[md.artwork.length - 1].src : null;
        postEvent({
            event: "trackChanged",
            videoId: videoId,
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
