## What

<!-- One or two sentences. The diff shows the *what* — focus this
     section on the user-visible change. -->

## Why

<!-- The reason. If this is a bug fix, the root cause. If it's a
     feature, the user need it addresses. -->

## Architectural notes

<!-- Anything reviewers should look at carefully? Did you touch:
     - InnerTubeClient parsers? Add a fixture test.
     - PlayerBridge / QueueManager? Note any state lifecycle changes.
     - The WKWebView surface? **It must not become user-visible.**
     - clientVersion? Why? -->

## Test plan

- [ ] `xcodebuild test` passes
- [ ] Manually exercised the change on macOS 14+
- [ ] No regressions in: Home browse / Search / Library / click-to-play
      / queue management / sign-in
- [ ] Logs (`log stream --predicate 'subsystem == "dev.riff.app"'`)
      look clean during normal operation

## Screenshots / logs

<!-- For UI changes: before / after. For bug fixes: log line that
     proves the issue is gone. -->
