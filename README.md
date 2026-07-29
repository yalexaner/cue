# cue

A single-user iOS podcast client built around one idea: **playback position is
never lost**. Every listening session is recorded append-only; falling asleep
mid-episode never destroys where you actually were.

- Private feeds fetched directly from origin — no proxy, no account.
- Download-then-play only; offline is the primary case.
- iOS 26, SwiftUI, SwiftData, AVFoundation. No third-party dependencies.

## Build

Requires Xcode 26+ and [`just`](https://github.com/casey/just).

```sh
just build   # simulator build
just test    # unit tests (Swift Testing)
just ipa     # unsigned device .ipa in build/
```

## Development

Lint and format tooling (`swift-format` ships with Xcode):

```sh
brew install just swiftlint
```

```sh
just lint          # swiftlint --strict, config in .swiftlint.yml
just format        # swift-format in place, config in .swift-format
just format-check  # swift-format lint --strict, no writes
```

See `SPEC.md` for what this app is and `ROADMAP.md` for how it is built.
