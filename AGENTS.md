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
  Resolution and existence checks go through `EpisodeStore` —
  `url(forRelativeFilename:)` and `fileExists(forRelativeFilename:)`. Never
  compose an episode path by hand; the store is the single place that rejects
  names which would resolve outside `Episodes/`. `EpisodeStore` is a cheap
  struct constructed at the call site — no shared singleton.
- **Resolving a path never touches the file system.** `episodesDirectory()`
  composes only; `prepareEpisodesDirectory()` is the sole mutating entry point
  (creates the directory, sets `isExcludedFromBackup`). A read such as
  `isDownloaded` must not create directories as a side effect. Because nothing
  else provisions, `CueApp.init()` calls `prepareEpisodesDirectory()` once at
  launch — spec §5's "created on first launch". The download path must call it
  again before writing rather than assume launch succeeded.
- **Storage errors are never answered as "not downloaded".**
  `Episode.isDownloaded(in:)` is a throwing *method*, not the property spec §4
  names — the disk check needs an `EpisodeStore`, and it cannot appear in a
  SwiftData `#Predicate`, so the Downloads view filters in memory. Callers must
  propagate the error: the reconciliation sweep clears download state on a
  `false`, so treating "cannot tell" as "absent" would wipe the library.
- **Refresh fetches before it writes.** `#Unique` makes a conflicting
  `context.insert` an upsert that overwrites *every* scalar with the new
  instance's value, including defaults — it clears `localFilename`,
  `downloadedAt`, `isPlayed` and `playedAt`. Match on `guid` with a fetch and
  mutate the allowed metadata fields; never blind-insert. The same holds for
  `Podcast.feedURL` — re-adding a subscribed feed wipes its author, summary,
  artwork and `addedAt`. Pinned by
  `uniqueGUIDUpsertOverwritesDownloadAndPlayedState` and
  `uniqueFeedURLUpsertOverwritesPodcastMetadata`. Note also that `guid`
  uniqueness is store-wide, not per podcast
  (`guidUniquenessIsGlobalNotPerPodcast`).
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
- Model tests build a fresh in-memory container per test:
  `ModelConfiguration(isStoredInMemoryOnly: true)` →
  `ModelContainer(for:configurations:)` → `ModelContext`. Never share one across
  tests. Suites touching SwiftData are `@MainActor`.
- Never let a test touch the real Application Support. Use
  `withTemporaryBase` (`cueTests/TemporaryDirectory.swift`) and construct
  `EpisodeStore(baseDirectory:)` against the directory it hands you.
- Inside a throwing closure, write `try #expect(…)` — `#expect(try …)` fails to
  compile there, though it works at the top level of a `throws` test function.
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

- One roadmap step per pull request. The finalizer decides the rev count by
  content: each rev is atomic and independently green (build + tests), review
  fixes are folded into the rev they fix, no plan artifacts or process commits.
  Small steps naturally collapse to one rev; large steps split into 2–4
  cohesive units.
- Conventional commits: `<type>(<scope>): <subject>` — lowercase, imperative,
  no trailing period. The commit message the roadmap step specifies becomes the
  PR title and the primary rev's message.
- CI (`checks` and `build-test`) must pass before merge. Do not merge red.
