---
name: Bug report
about: Something doesn't work the way it should
labels: bug
---

## What happened

<!-- One or two sentences. -->

## What I expected

<!-- One sentence. -->

## How to reproduce

1. …
2. …
3. …

## Environment

- macOS version:
- Riff version (Riff → About): 
- Built from source / DMG: 
- Signed in via: WebView / Device Flow / not signed in

## Logs

If the bug is reproducible, the unified log is the highest-signal
attachment. Run this *before* triggering the bug, then capture the
output as the bug happens:

```sh
log stream --predicate 'subsystem == "dev.riff.app"' --info --debug
```

Paste the relevant lines (or attach as a file). Redact any URLs that
contain personal `videoId`s if you'd rather keep them private.

## Anything else
