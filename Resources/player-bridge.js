/*
 * player-bridge.js
 *
 * Injected into music.youtube.com at documentStart by the hidden WKWebView.
 * Exposes window.musicBridge.{...} so the Swift side can drive playback
 * through a stable surface, regardless of how YT Music restructures its
 * internals.
 *
 * Architecture (rewritten 2026-06 based on research into
 * th-ch/youtube-music + sozercan/kaset, both of which converged on this
 * approach):
 *
 *   1. Track-change detection — subscribe to YT's own
 *      `playerApi.addEventListener('videodatachange', …)`. This is the
 *      canonical event YT itself dispatches on MSE source-swap, the same
 *      moment the underlying audio source changes. It fires reliably
 *      where <video>.ended does NOT (YT's MSE pipeline doesn't end the
 *      stream — it just swaps the source mid-flight).
 *
 *   2. State change + end-of-track — subscribe to
 *      `playerApi.addEventListener('onStateChange', …)`. State codes:
 *        -1 unstarted, 0 ENDED, 1 PLAYING, 2 PAUSED, 3 BUFFERING, 5 CUED
 *      State 0 is the real "natural end of track" signal — fires before
 *      YT's own autoplay handler advances the source. Replaces the
 *      window-capture-phase `ended` listener and the timeupdate
 *      EOT-window heuristic that were patched in earlier rounds.
 *
 *   3. Setup gate — the playerApi + ytmusic-player-bar elements don't
 *      exist until YT's app upgrades. We poll-with-backoff until they
 *      appear before wiring listeners. Fixes the race that documentStart
 *      injection always lost.
 *
 *   4. Fallback to mediaSession polling — only if playerApi never
 *      materializes (defensive; YT has changed selector names in the
 *      past). When fallback fires it's logged so we know.
 *
 * The old `__riffPendingNextUrl` + capture-phase ended + timeupdate
 * EOT-window code is GONE from this rewrite. Commit 2 replaces it
 * entirely with Redux-store queue dispatch (the real fix).
 */

(function () {
    "use strict";

    // ---- Element finders ---------------------------------------------------

    function videoEl() { return document.querySelector("video"); }

    /**
     * Find YT Music's player API object. Two known seams, in preference order:
     *   - ytmusic-player element's .playerApi (modern, post-2023 ish)
     *   - #movie_player element directly (older; some YT Music builds still
     *     expose it). Both share the same surface: getVideoData(),
     *     addEventListener('videodatachange'|'onStateChange', fn),
     *     setVolume(0..100), playVideo(), pauseVideo(), etc.
     */
    function playerApi() {
        const ytp = document.querySelector("ytmusic-player");
        if (ytp && typeof ytp.playerApi === "object" && ytp.playerApi) {
            return ytp.playerApi;
        }
        const mp = document.getElementById("movie_player");
        if (mp && typeof mp.getVideoData === "function") {
            return mp;
        }
        return null;
    }

    function playerBar() { return document.querySelector("ytmusic-player-bar"); }

    function postEvent(payload) {
        try { window.webkit.messageHandlers.bridge.postMessage(payload); } catch (_) {}
    }

    // ---- Public API (window.musicBridge) -----------------------------------

    const api = {
        // Single navigation primitive — Swift builds the full /watch?v=&list=
        // URL and tells the page to load it. The /watch route auto-plays.
        navigate(url) { location.href = url; },

        togglePlay() {
            const v = videoEl();
            if (!v) return;
            v.paused ? v.play() : v.pause();
        },

        setPlaybackRate(rate) {
            const v = videoEl();
            if (v) v.playbackRate = rate;
        },

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

        // Repeat-one via the <video>.loop attribute. When loop=true the
        // browser restarts the source at end-of-stream and YT Music's
        // autoplay never fires. Clean per-track repeat with no DOM
        // dependence.
        setRepeatLoop(enabled) {
            const v = videoEl();
            if (v) v.loop = !!enabled;
        },

        // Park a URL the JS-side onStateChange===0 (ended) handler
        // consumes when the current track ends. Still the workhorse
        // for "Play next" / "Add to queue" because direct Redux
        // dispatch into YT's queue store requires constructing full
        // QueueItem payloads (shape undocumented; needs live page
        // inspection). The autoplay-interception path is reliable
        // now that onStateChange replaced the unreliable <video>.ended
        // we were waiting on. See queueAddViaPage below for the
        // experimental Redux path that runs alongside this as a
        // (currently best-effort) primary.
        setPendingNextURL(url) {
            window.__riffPendingNextUrl = url || null;
        },

        /**
         * Attempt to inject a track into YT Music's own queue via
         * direct Redux dispatch. If it works, YT's natural autoplay
         * picks our injected item up and we don't need
         * __riffPendingNextUrl at all. If it doesn't, the autoplay-
         * interception path remains as a fallback.
         *
         * Returns true on a successful dispatch, false otherwise.
         * Both outcomes are logged via the `diagnostic` event so we
         * can iterate from `log show` output.
         *
         * The payload shape used here mirrors what th-ch's
         * music-together plugin observed YT dispatching internally
         * (action type 'ADD_ITEMS'). The `items` array expects full
         * QueueItem objects; we approximate with the minimal shape
         * YT seems to tolerate (videoId + a synthetic playlistPanel
         * wrapper). If YT rejects this shape the dispatch is a no-op
         * — no crash, just a diagnostic.
         */
        queueAddViaPage(videoId, position) {
            const insertAfter = position === 'next';
            // Try several known queue-element seams.
            const candidates = [
                () => document.querySelector('ytmusic-player-bar'),
                () => document.querySelector('ytmusic-app-layout #queue'),
                () => document.querySelector('ytmusic-player-queue'),
                () => document.querySelector('ytmusic-app'),
            ];
            let dispatcher = null;
            let where = null;
            for (const c of candidates) {
                try {
                    const el = c();
                    if (!el) continue;
                    // Two known dispatch paths:
                    //   el.dispatch(...)              — high-level helper on the element
                    //   el.queue.store.store.dispatch — direct Redux store access
                    if (typeof el.dispatch === 'function') {
                        dispatcher = (action) => el.dispatch(action);
                        where = el.tagName + '.dispatch';
                        break;
                    }
                    if (el.queue && el.queue.store && el.queue.store.store && typeof el.queue.store.store.dispatch === 'function') {
                        dispatcher = (action) => el.queue.store.store.dispatch(action);
                        where = el.tagName + '.queue.store.store.dispatch';
                        break;
                    }
                } catch (_) {}
            }
            if (!dispatcher) {
                postEvent({ event: "diagnostic", msg: "queueAddViaPage: no dispatcher found for any queue-element candidate" });
                return false;
            }
            const action = {
                type: 'ADD_ITEMS',
                payload: {
                    // YT's reducer (CZ(d).navigationEndpoint per the
                    // first-pass diagnostic) expects each item to carry
                    // a watchEndpoint navigation node. The minimal
                    // shape YT accepts looks like a stripped-down
                    // playlistPanelVideoRenderer.
                    items: [{
                        videoId: videoId,
                        navigationEndpoint: {
                            watchEndpoint: { videoId: videoId },
                        },
                        // Wrap in the renderer envelope YT uses
                        // internally — sometimes the reducer keys
                        // off `.playlistPanelVideoRenderer` on the
                        // item rather than the item itself.
                        playlistPanelVideoRenderer: {
                            videoId: videoId,
                            navigationEndpoint: {
                                watchEndpoint: { videoId: videoId },
                            },
                        },
                    }],
                    nextQueueItemId: insertAfter ? null : undefined,
                    index: insertAfter ? 0 : undefined,
                    shuffleEnabled: false,
                    shouldAssignIds: true,
                },
            };
            try {
                dispatcher(action);
                postEvent({ event: "diagnostic", msg: "queueAddViaPage dispatched via " + where + ": " + videoId + " (" + position + ")" });
                return true;
            } catch (e) {
                postEvent({ event: "diagnostic", msg: "queueAddViaPage dispatch threw at " + where + ": " + (e && e.message ? e.message : String(e)) });
                return false;
            }
        },

        next()     { document.querySelector(".next-button")?.click(); },
        previous() { document.querySelector(".previous-button")?.click(); },

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

    // ---- Track-change + state-change handling ------------------------------

    let lastVideoId = "";
    let lastEmittedHadTitle = false;
    let stickyPlaylistId = null;

    function findPlaylistId() {
        // 1. Direct URL param (truthful right after navigation).
        const url = new URL(location.href);
        let id = url.searchParams.get("list");
        if (id) return id;
        // 2. Hash route — some YT Music transitions keep it there.
        if (location.hash) {
            try {
                const hashUrl = new URL(location.hash.slice(1), location.origin);
                id = hashUrl.searchParams.get("list");
                if (id) return id;
            } catch (_) { /* malformed; fall through */ }
        }
        // 3. DOM scan for any list= link.
        const link = document.querySelector('a[href*="list="]');
        if (link) {
            try {
                const href = new URL(link.href, location.origin);
                id = href.searchParams.get("list");
                if (id) return id;
            } catch (_) {}
        }
        return null;
    }

    /**
     * Fire a `trackChanged` event to Swift.
     * Pulls metadata from playerApi.getVideoData() — the canonical YT source —
     * with mediaSession.metadata as a fallback for the artwork (videoData
     * sometimes omits it).
     */
    function emitTrackChanged(reason) {
        const api = playerApi();
        if (!api) return;
        let vd;
        try { vd = api.getVideoData(); } catch (_) { return; }
        if (!vd || !vd.video_id) return;
        const found = findPlaylistId();
        if (found) stickyPlaylistId = found;
        const playlistId = stickyPlaylistId;
        // Compose the best title/artist we currently have from the
        // two sources. videodatachange's 'dataloaded' event often
        // fires BEFORE getVideoData populates title/author — the
        // canonical data lands on the subsequent 'dataupdated'
        // event. mediaSession.metadata fills in on its own clock.
        const md = navigator.mediaSession && navigator.mediaSession.metadata;
        const title = vd.title || (md && md.title) || "";
        const artist = vd.author || (md && md.artist) || "";
        // Dedup gating: skip if the videoId matches the last emit AND
        // we already emitted with non-empty title. This allows a
        // re-emit when an earlier emit had empty metadata (track
        // change just landed, getVideoData still empty) and now has
        // populated data — so Swift never gets stuck with a blank
        // title row.
        if (vd.video_id === lastVideoId && lastEmittedHadTitle && reason !== "force") return;
        lastVideoId = vd.video_id;
        lastEmittedHadTitle = title !== "";
        let artwork = null;
        if (md && md.artwork && md.artwork.length > 0) {
            artwork = md.artwork[md.artwork.length - 1].src;
        }
        postEvent({
            event: "trackChanged",
            videoId: vd.video_id,
            playlistId: playlistId,
            title: title,
            artist: artist,
            artwork: artwork,
        });
    }

    function emitState(state) {
        // YT's IFrame Player API state codes (the same set ytmusic-player.playerApi uses):
        //  -1 unstarted, 0 ENDED, 1 PLAYING, 2 PAUSED, 3 BUFFERING, 5 CUED
        if (state === 1) {
            postEvent({ event: "stateChanged", isPlaying: true });
        } else if (state === 0 || state === 2) {
            postEvent({ event: "stateChanged", isPlaying: false });
        }
        if (state === 0) {
            postEvent({ event: "ended" });
            // Legacy: drain __riffPendingNextUrl if set. Commit 2 removes
            // the Swift-side push that fills it, at which point this branch
            // becomes dead code.
            const pending = window.__riffPendingNextUrl;
            if (pending) {
                window.__riffPendingNextUrl = null;
                postEvent({ event: "riffNavigatedTo", url: pending, via: "onStateChange" });
                location.href = pending;
            }
        }
    }

    /**
     * Subscribe to playerApi event bus. The event names differ slightly
     * across YT builds — `videodatachange` is the canonical track-change
     * event in modern builds; `onStateChange` is universal.
     *
     * On `videodatachange` we get (name, videoData) where `name` ∈
     * {'newdata', 'dataloaded', 'dataupdated'}. We treat any non-empty
     * videoData with a new video_id as a track change.
     */
    function subscribeToPlayerApi(api) {
        if (api.__riffSubscribed) return;
        api.__riffSubscribed = true;
        try {
            api.addEventListener("videodatachange", (_name, _videoData) => {
                emitTrackChanged("videodatachange");
            });
        } catch (e) { postEvent({ event: "diagnostic", msg: "videodatachange subscribe failed: " + e }); }
        try {
            api.addEventListener("onStateChange", (state) => {
                emitState(state);
            });
        } catch (e) { postEvent({ event: "diagnostic", msg: "onStateChange subscribe failed: " + e }); }
        // Initial sync — emit what's currently loaded so Swift gets a track
        // immediately on (re)attach instead of waiting for the first
        // playerApi event.
        emitTrackChanged("force");
        // Safety-net poll: videodatachange's 'dataupdated' event isn't
        // always reliable — th-ch documents the same. A 2s poll
        // re-evaluates and re-emits if metadata finally landed (the
        // dedup gate in emitTrackChanged guards against redundant
        // emits when nothing changed). Cheap enough to leave running.
        if (!window.__riffSafetyPollId) {
            window.__riffSafetyPollId = setInterval(() => emitTrackChanged("safety-poll"), 2000);
        }
    }

    // ---- <video> listeners (progress only — state moved to onStateChange) --

    function attachVideoListeners() {
        const v = videoEl();
        if (!v || v.__riffAttached) return;
        v.__riffAttached = true;
        // Progress is fine to read directly off the element — it fires
        // ~4Hz and we use it for the scrubber, not for end-of-track
        // decisions.
        v.addEventListener("timeupdate", () => {
            postEvent({ event: "progress", currentTime: v.currentTime, duration: v.duration });
        });
    }

    // ---- Setup gate: poll until playerApi + player-bar exist ---------------

    let setupAttempts = 0;
    const SETUP_MAX_ATTEMPTS = 60;       // 30s at 500ms cadence
    const SETUP_INTERVAL_MS = 500;
    let setupDone = false;

    function setup() {
        if (setupDone) return;
        const api = playerApi();
        const bar = playerBar();
        if (!api || !bar) {
            setupAttempts++;
            if (setupAttempts > SETUP_MAX_ATTEMPTS) {
                // Defensive: if playerApi never appears (YT changed selectors,
                // page broken, etc.) fall back to the legacy mediaSession poll
                // so Riff doesn't silently lose track-change events. The
                // fallback's lower fidelity is acceptable; the alert tells us
                // the primary path is dead.
                postEvent({ event: "diagnostic", msg: "playerApi never appeared after " + SETUP_MAX_ATTEMPTS + " attempts; falling back to mediaSession poll" });
                startMediaSessionFallback();
                setupDone = true;
                postEvent({ event: "ready" });
                return;
            }
            setTimeout(setup, SETUP_INTERVAL_MS);
            return;
        }
        setupDone = true;
        subscribeToPlayerApi(api);
        attachVideoListeners();
        // Re-attach video listeners as YT swaps the element (rare but happens
        // across some SPA transitions). MutationObserver watching the body's
        // childList is overkill for this; the videodatachange event will
        // already fire on the new element, and we just need to grab the
        // new element's timeupdate.
        new MutationObserver(() => {
            attachVideoListeners();
            // Also rebind playerApi listeners if the playerApi instance
            // changed (defensive — YT sometimes recreates the player on
            // certain navigations).
            const fresh = playerApi();
            if (fresh && !fresh.__riffSubscribed) {
                subscribeToPlayerApi(fresh);
            }
        }).observe(document.documentElement, { childList: true, subtree: true });
        postEvent({ event: "ready" });
    }

    // ---- Fallback: legacy mediaSession + URL polling -----------------------
    //
    // Only used when the playerApi seam never materializes. Lower fidelity
    // but better than nothing.

    let fallbackTimerId = null;
    function startMediaSessionFallback() {
        if (fallbackTimerId) return;
        let fallbackKey = "";
        fallbackTimerId = setInterval(() => {
            const md = navigator.mediaSession && navigator.mediaSession.metadata;
            const url = new URL(location.href);
            const videoId = url.searchParams.get("v");
            if (!md || !videoId) return;
            const found = findPlaylistId();
            if (found) stickyPlaylistId = found;
            const key = videoId + "|" + (md.title || "") + "|" + (stickyPlaylistId || "");
            if (key === fallbackKey) return;
            fallbackKey = key;
            const artwork = (md.artwork && md.artwork.length > 0) ? md.artwork[md.artwork.length - 1].src : null;
            postEvent({
                event: "trackChanged",
                videoId: videoId,
                playlistId: stickyPlaylistId,
                title: md.title || "",
                artist: md.artist || "",
                artwork: artwork,
            });
        }, 500);
        // Also attach the <video> ended listener as best-effort EOT signal in
        // fallback mode (in case YT does fire it on some non-MSE contexts
        // like ads).
        const v = videoEl();
        if (v && !v.__riffFallbackAttached) {
            v.__riffFallbackAttached = true;
            v.addEventListener("ended", () => {
                postEvent({ event: "ended" });
                postEvent({ event: "stateChanged", isPlaying: false });
            });
        }
    }

    // ---- Kick off ---------------------------------------------------------

    if (document.readyState === "loading") {
        document.addEventListener("DOMContentLoaded", setup);
    } else {
        setup();
    }
})();
