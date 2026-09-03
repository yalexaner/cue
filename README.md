# cue

[![CI](https://github.com/yalexaner/cue/actions/workflows/ci.yml/badge.svg)](https://github.com/yalexaner/cue/actions/workflows/ci.yml)

A single-user iOS podcast client built around one idea: **playback position is
never lost**. Every listening session is recorded append-only; falling asleep
mid-episode never destroys where you actually were.

- Private feeds fetched directly from origin — no proxy, no account.
- Download-then-play only; offline is the primary case.
- iOS 26, SwiftUI, SwiftData, AVFoundation, MediaPlayer. No third-party dependencies.

**Status: in development** — the bullets above describe the finished v1, not
what runs today. Working now: subscribe to a feed by URL, browse a show's
episodes, mark played, pull to refresh, and download episodes over a background
`URLSession`. The Downloads tab shows active progress, safe failure details,
cancel and retry above completed episodes grouped by show, with a per-phase
transfer line (queued, connecting, downloading, stalled, finalizing) and an
exportable on-device diagnostics log for reporting a failure. Refresh says which
feed it is checking, downloaded rows show their own file size, and the add-feed
sheet offers to paste an address from the clipboard. Downloaded episodes play
offline with in-app seeking and rate controls plus lock-screen Now Playing and
play/pause integration. Every listening session is now recorded append-only, so
a pause, a seek mid-playback or a force-quit leaves the position intact. Not
built yet: the History screen that surfaces those sessions, played-on-completion,
the sleep timer, the storage reconciliation sweep, the mini-player, and OPML
import.
See `ROADMAP.md`.

## Build

Requires Xcode 26+ and [`just`](https://github.com/casey/just).

```sh
just build   # simulator build
just test    # unit tests (Swift Testing)
just ipa     # unsigned device .ipa in build/
```

## Development

Agents read `AGENTS.md` before working — it carries the command surface, the
frozen project file rule, and the spec invariants that must never be violated.

Lint and format tooling (`swift-format` ships with Xcode):

```sh
brew install just swiftlint gitleaks
```

```sh
just lint          # swiftlint --strict, config in .swiftlint.yml
just format        # swift-format in place, config in .swift-format
just format-check  # swift-format lint --strict, no writes
```

Secret hygiene — never commit a real feed URL; run `gitleaks detect --no-git`
before pushing. See `docs/SECRETS.md`.

See `SPEC.md` for what this app is and `ROADMAP.md` for how it is built.
