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

Keep every collection literal on a single line. `swift-format` requires a
trailing comma on the last element of a *multiline* collection literal, while
SwiftLint's default `trailing_comma` rule rejects one — so a multiline array or
dictionary cannot pass `just lint` and `just format-check` at the same time. If
a literal will not fit in 120 columns, split it into two named single-line
values or use a `switch` instead of a `Set` membership test. (Changing this
means disabling one of the two rules in `.swiftlint.yml` or `.swift-format`,
which is a project-wide decision, not a per-step workaround.)

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
- **Zero episodes is a failure only at the fetch boundary.**
  `FeedParser.parse(data:)` returns a zero-episode `ParsedFeed` without
  throwing — parsing is permissive by design, which is what satisfies the
  roadmap's `no-enclosures.rss` → "zero episodes, no error".
  `FeedParser.parse(data:sourceURL:)` adds `Failure.emptyFeed(sourceURL)`, and
  that is what satisfies spec §6's "surface an error naming the URL". Every
  caller that actually fetched the document must use the URL-aware entry; the
  data-only entry exists for tests and for callers with no URL to name.
- **A parsed duration is unbounded and may trap on conversion.**
  `DurationParser` computes in `TimeInterval` rather than `Int` precisely so a
  feed writing `Int.max` seconds yields a useless number instead of crashing the
  parse — which means an absurd `Episode.duration` is a value every consumer has
  to expect. Never hand it to `Int(_:)` unguarded: that traps, on every render of
  a row the feed itself authored, on every launch. `episodeDurationText(_:)`
  bounds it at 100 hours and shows anything past that as no duration at all.
- **A new subscription that would be empty is refused.** `guid` uniqueness is
  store-wide, so the same show re-added under a rotated token URL matches no
  existing `Podcast` yet has every episode skipped as owned elsewhere. `add`
  deletes the podcast it inserted in this merge and throws
  `Failure.allEpisodesOwnedElsewhere(url)` rather than leaving a permanently
  empty library row (spec §6). The guard is for *new* subscriptions only — an
  already-subscribed feed that contributes nothing is an ordinary no-op refresh,
  and refusing it would cascade-delete the show
  (`subscribedFeedContributingNothingIsKeptNotDeleted`).
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

## Networking

- **The network is an injected closure, never a session or a `URLProtocol`
  stack.** `FeedService.Transport` is
  `@Sendable (URL) async throws -> (Data, URLResponse)`, defaulting to
  `FeedService.sharedTransport` (a `URLSession.shared` wrapper). Tests pass a
  stub returning fixture bytes and a crafted `HTTPURLResponse`, so no test ever
  reaches the network and the service holds no session configuration. New code
  that fetches a *document* — a feed, an OPML file — follows the same shape.
- **Episode downloads are exempt from the `Data` transport.** Spec §7 requires a
  background `URLSession` on one shared identifier that writes to the session's
  temp location, which is then moved into `Episodes/`; buffering an audio file
  into `Data` would hold a whole episode in memory and give up background
  delivery, so `FeedService.Transport` is the wrong type there. What carries
  over is the injection, not the signature: the downloader takes its own
  file-based transport (a URL in, a temporary file URL plus `URLResponse` out),
  keeps the session configuration behind that closure, and no test constructs a
  real background session.
- **The default transport revalidates.** `FeedService.feedRequest(for:)` sets
  `cachePolicy = .reloadRevalidatingCacheData`, and that is a correctness
  requirement rather than a tuning knob: refresh is manual only (spec §6), so a
  pull-to-refresh has to reach the server. Under the default protocol policy a
  feed sending `Cache-Control: max-age` is answered from `URLCache` and the
  refresh reports success having fetched nothing. Revalidating still honours a
  304. The request is a named function so the policy is assertable.
- **Fetch failures name what failed.** Non-2xx throws
  `FeedService.Failure.httpStatus(status, url)`; an unparseable or non-http
  address throws `Failure.invalidURL(string)`; a new subscription whose every
  episode is owned elsewhere throws `Failure.allEpisodesOwnedElsewhere(url)`.
  Transport errors (`URLError`, ATS rejections) and `FeedParser.Failure`
  propagate unchanged — wrapping them hides the cause. `feedErrorMessage(for:)`
  is the single place those map to user-facing text.
- **Cancellation is not a failure to report.** `.refreshable`'s task is
  cancelled when its view goes away and `URLSession` surfaces that as
  `URLError.cancelled`; `isCancellation(_:)` (`cue/Views/FeedRefreshing.swift`)
  is the single classifier. Never pass a cancellation to
  `feedErrorMessage(for:)` — it pops an alert on a disappearing view, and inside
  a multi-feed sweep it becomes the reported error and masks the real one. A
  screen running one feed catches once and calls
  `reportableFeedErrorMessage(for:)`, which answers `nil` for cancellation, so
  the rule cannot be forgotten a `catch` clause at a time; the sweep's own
  version of it is `refreshAll(_:using:)`.
- Services that write to SwiftData are cheap `@MainActor` structs constructed at
  the call site with a `ModelContext` — same precedent as `EpisodeStore`, no
  shared instance.
- **`@MainActor` on a service is about SwiftData, not about its work.** Model
  mutations stay on the main actor, so the merge does. A step that touches no
  model and no context — parsing, hashing, asset inspection — takes `Data` and
  returns a `Sendable` value, and must not run inline: a large feed parsed on
  the UI thread stalls navigation, the refresh indicator and Cancel for the
  length of the parse. `FeedService.parse(data:sourceURL:)` is the shape. Spell
  the hop `@concurrent nonisolated`, never bare `nonisolated`: an async
  `nonisolated` function hops to the concurrent executor under the current
  language mode, but that default is exactly what
  `NonisolatedNonsendingByDefault` inverts, and the hop must not be lost to a
  language-mode change.
- **Cancellation is checked before the write, not only during the fetch.** A
  transport that already answered leaves the merge free to commit work the user
  backed out of — Cancel dismisses the add sheet, a pop cancels a refresh.
  `FeedService.fetch(urlString:)` ends with `try Task.checkCancellation()` so
  add and refresh both inherit it, pinned by
  `addCancelledAfterTheResponseCommitsNothing`. That check is not sufficient on
  its own: the merge runs synchronously after it — measured at ~19 s for a
  4000-episode feed — and a cancel landing in that window was silently ignored
  and the subscription committed. So `saveOrDiscard()` checks again, and the
  second check sits *inside* its `do` rather than above it: thrown from above,
  cancellation skips the discard and autosave commits the merge at the next
  resign-active, which is the same bug wearing an error message.
- **A service discards its pending changes when a step after the first write
  fails.** The main context autosaves, so an un-discarded failure is committed
  seconds after the user was told it failed. That covers the save
  (`FeedService.saveOrDiscard()`) and the merge itself (`mergeOrDiscard()`),
  which inserts the podcast and rewrites its metadata before its lookups can
  throw. Because `rollback()` is context-wide it also drops edits the service
  never made, so: a view that mutates a model outside a service saves at the
  point of mutation rather than leaning on autosave
  (`PodcastDetailView.setPlayed(_:on:)`) — a played flag left pending is a
  played flag a failed refresh can discard — and cancelling a single
  just-inserted, never-saved model is `context.delete` on that model, not
  `rollback()` (`add`'s `allEpisodesOwnedElsewhere` path).

## Testing

- Swift Testing (`@Test`, `#expect`), not XCTest. No `XCTestCase` subclasses,
  no `XCTAssert`.
- Views are covered by the build only. Anything worth asserting — sorting,
  formatting, error-message mapping, and the policy behind a view action (which
  failures stop a loop, which one gets reported, what a pasted address may be
  rewritten to) — is extracted into a plain free function
  (`cue/Views/EpisodeListFormatting.swift`, `cue/Views/FeedErrorMessage.swift`,
  `cue/Views/FeedRefreshing.swift`, `cue/Views/FeedAddress.swift`) and tested
  directly. Model mutations a view triggers live on the model
  (`Episode.setPlayed(_:)`), so invariants stay pinned by model tests.
- Fixtures live in `cueTests/Fixtures/` and load through the shared
  `fixtureData(named:withExtension:)` helper in `cueTests/FixtureLoading.swift`,
  which resolves the test bundle via `Bundle(for:)` with a private marker class.
  Never read fixtures from a path on disk, and never re-declare a local loader.
- There is one transport double, `FeedTransportStub`
  (`cueTests/FeedTransportStub.swift`), and one `StubTransportError`. Same rule
  as the fixture loader: never re-declare a per-suite copy. A stub that cannot
  build its `HTTPURLResponse` throws — degrading to a plain `URLResponse` reads
  as "no status to judge" and quietly sends a status test down the 2xx path.
  That constrains `FeedTransportStub` itself, not every transport a test may
  construct: `failingTransport(_:)` and `nonHTTPTransport(data:)` live in the
  same file precisely so the cases the stub must never produce by accident can
  still be produced on purpose. A suite-local factory over those shared pieces
  is fine; a second copy of the stub or the loader is not.
- Assert persistence through a second `ModelContext(container)`. The context
  that did the inserting cannot tell a committed store from pending changes —
  and for the same reason, a test about an insert being *cancelled* must assert
  on the primary context, which is the only one that can see it pending.
- Model tests build a fresh in-memory container per test through the shared
  `makeContext()` in `cueTests/InMemoryContainer.swift`
  (`ModelConfiguration(isStoredInMemoryOnly: true)` →
  `ModelContainer(for:configurations:)` → `ModelContext`), alongside the shared
  `testFeedURL`. Same rule as the fixture loader and the transport stub: never
  re-declare a per-suite copy — the schema list is the part that changes, and a
  suite left behind silently runs against a different store. Never share a
  container across tests. Suites touching SwiftData are `@MainActor`.
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
  fixes are folded into the rev they fix, no process commits. Small steps
  naturally collapse to one rev; large steps split into 2–4 cohesive units. The
  step's completed plan under `docs/plans/completed/` is the one artifact that
  travels with the PR, as its own rev; no other plan file does.
- Conventional commits: `<type>(<scope>): <subject>` — lowercase, imperative,
  no trailing period. The commit message the roadmap step specifies becomes the
  primary rev's message.
- PR title and description are delegated to CodeRabbit: open PRs with
  `gh pr create --draft --title "@coderabbitai"` and body `@coderabbitai summary`;
  when its review runs, the bot replaces the title placeholder and inserts the
  generated summary where the `@coderabbitai summary` placeholder sits in the
  body.
- CI (`checks` and `build-test`) must pass before merge. Do not merge red.
