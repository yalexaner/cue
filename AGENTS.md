# Agent conventions

Read this before changing anything. `SPEC.md` says what the app is; `ROADMAP.md`
says in what order it is built. Where they disagree, the spec wins.

## Command surface

Use the `just` recipes. Never type a raw `xcodebuild` invocation.

```sh
just build         # simulator build
just test          # Swift Testing suite
just ipa           # unsigned device .ipa in build/
just lint          # swiftlint --strict
just format        # swift-format in place
just format-check  # swift-format lint --strict, no writes
```

`just --list` shows the rest (`clean`, `destinations`).

## Project structure

- New `.swift` files anywhere under `cue/` or `cueTests/` compile automatically —
  both are `PBXFileSystemSynchronizedRootGroup`s. Create the file; nothing else
  is needed.
- Build settings live in `Config/{Shared,Debug,Release,Tests}.xcconfig`. Edit
  those freely. They are the only place build settings belong.
- **Never edit `cue.xcodeproj/project.pbxproj`** (or any `.xcworkspace`). The
  project file was authored once and is frozen; a Claude Code `PreToolUse` hook
  rejects edits to it.
- If the project structure genuinely must change — a new target, an extension,
  a resource that synchronized folders cannot pick up — stop and say so. That is
  a human-approved event, not something to work around.

## Spec invariants that must never be violated

These are not preferences. Each one is a bug being designed out.

- **`isPlayed` and `localFilename` are orthogonal. Neither is ever inferred from
  the other.** Marking an episode played must not delete the file. Deleting the
  file must not mark the episode played. (spec §4)
- **There is no stored position field.** `Episode.currentPosition` derives from
  the session log: `endPosition` of the session with the latest `startedAt`,
  else `0`. Never add a position column. (spec §4)
- **`localFilename` is relative.** The database stores the filename only; the
  absolute URL is rebuilt at every access from `episodesDirectory()`. The
  container path contains a UUID that changes on reinstall and restore, so
  persisting an absolute path guarantees breakage. (spec §5)
- **The playback path performs no network request and no reachability check.**
  `AVPlayerItem` is built from the local file URL. (spec §8)
- **Lock-screen scrubber and skip commands stay disabled.**
  `changePlaybackPositionCommand`, `skipForwardCommand` and
  `skipBackwardCommand` are `isEnabled = false` on purpose, so position cannot
  be lost to a pocket touch. This is a requirement, not an oversight — do not
  "fix" it. The in-app progress slider stays enabled. (spec §8)
- **No real feed URL enters the repository.** Not in fixtures, tests, comments,
  commit messages, or issue text. Fixtures use
  `https://example.com/feed?token=REDACTED_TEST_TOKEN`. See `docs/SECRETS.md`;
  run `gitleaks detect --no-git` before pushing.

Two more that follow from the same design and are easy to break by accident:

- Refresh is additive: match on `guid`, insert new episodes, update mutable
  metadata. Never delete local episodes, and never touch `isPlayed`,
  `localFilename`, or sessions on refresh. (spec §6)
- The Downloads view filters on file presence only, never on played state.
  (spec §7)

## Testing

- Swift Testing (`@Test`, `#expect`), not XCTest. No `XCTestCase` subclasses,
  no `XCTAssert`.
- Fixtures live in `cueTests/Fixtures/` and load from the test bundle via
  `Bundle(for:)` with a private marker class — see `cueTests/SmokeTests.swift`.
  Never read fixtures from a path on disk.
- Every step must leave `just build` and `just test` green.

## CodeRabbit (advisory reviewer)

- Open every PR as a **draft**; mark it ready for review only when CI is green.
  The ready transition triggers CodeRabbit's one automatic review, so the
  review lands on passing, final code instead of burning quota on red branches.
- Act on findings through their `Prompt for AI Agents` blocks: verify each
  against current code, fix what is still valid, skip the rest with a one-line
  reason. Request a re-review with `@coderabbitai review` only after the branch
  is final again.
- Never invoke `@coderabbitai autofix`, docstring/test generation, or any
  walkthrough checkbox that writes to the branch — those exercise the app's
  write permission and are prohibited here.
- Never put `@coderabbitai ignore` or `@coderabbitai pause` in a PR
  description, and never modify `.coderabbit.yaml` in an ordinary PR (CI
  guards both; config changes need the `coderabbit-config-change` label from a
  human).

## Workflow

- One roadmap step per pull request, one commit per step unless the step says
  otherwise.
- Conventional commits: `<type>(<scope>): <subject>` — lowercase, imperative,
  no trailing period. Use the commit message the roadmap step specifies.
- CI (`checks` and `build-test`) must pass before merge. Do not merge red.
