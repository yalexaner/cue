# Add feed by URL, and the library (ROADMAP step 3)

## Overview

First interactive milestone: paste a feed URL, see episodes. Implements
`FeedService` (fetch → parse → persist, with additive refresh), a Library list
with pull-to-refresh and an add-feed sheet, and a podcast detail view listing
episodes newest first.

- Satisfies spec AC 1 (add a public feed → episodes appear) and the first half
  of AC 2 (add the Boosty feed → episodes appear).
- Step 3's own acceptance also requires: refresh twice → no duplicates; mark an
  episode played, refresh → the flag survives.
- Commit message for the primary rev: `feat: add feeds by url and browse episodes`

## Decisions (made during planning — do not re-litigate)

1. **Navigation**: `ContentView` hosts a `NavigationStack` rooted at
   `LibraryView`; `PodcastDetailView` pushes onto it. No `TabView` yet — the tab
   bar arrives when a second tab exists (step 4).
2. **Episode rows** show title, date, duration, and a **played indicator with a
   mark played/unplayed action** (swipe action or context menu). No downloaded
   indicator — that is step 4's `EpisodeStore` wiring.
3. **Transport is an injected closure**:
   `@Sendable (URL) async throws -> (Data, URLResponse)`, defaulting to a
   `URLSession.shared` wrapper. Tests inject stubs; no `URLProtocol` machinery.
   ➕ *During review*: the default wrapper builds its request through
   `FeedService.feedRequest(for:)` with `cachePolicy =
   .reloadRevalidatingCacheData`. Refresh is manual only (spec §6), so a feed
   sending `Cache-Control: max-age` would otherwise make pull-to-refresh a
   silent no-op. Named function so the policy is assertable.
4. **Fetch errors carry the HTTP status and the URL**:
   `FeedService.Failure.httpStatus(Int, String)` for non-2xx responses — makes a
   Boosty 401/403 diagnosable at add time (serves AC 2). Unparseable input →
   `Failure.invalidURL(String)`. Transport errors (`URLError`, ATS rejections)
   propagate as-is; parser errors (`FeedParser.Failure`) propagate as-is.
   ➕ *During review*: a third case,
   `Failure.allEpisodesOwnedElsewhere(String)` — see decision 7.
5. **URL input**: the string is stored and requested verbatim (spec §6),
   including tokens. Validation only checks `URL(string:)` parses and the scheme
   is `http`/`https`; a plain-http feed proceeds and fails at fetch with the
   transport's own error (no ATS exception exists in this project).
6. **Add of an already-subscribed feed is a refresh**, not an error and never a
   blind insert: fetch the existing `Podcast` by `feedURL` and merge. The
   destructive `#Unique` upsert (pinned by
   `uniqueFeedURLUpsertOverwritesPodcastMetadata`) must never be triggered.
7. **Store-wide `guid` collisions**: an incoming episode whose `guid` already
   exists on a *different* podcast is **skipped, never stolen or overwritten**.
   This preserves the known trade-off pinned by
   `guidUniquenessIsGlobalNotPerPodcast`; resolving it is out of scope.
   ➕ *During review*: one consequence had to be handled — when *every* episode
   of a **new** subscription is skipped that way (the rotated-token case), the
   add would insert a permanently empty library row and report success. It now
   deletes the podcast it inserted and throws `allEpisodesOwnedElsewhere`. An
   already-subscribed feed contributing nothing stays an ordinary no-op refresh;
   refusing it would cascade-delete the show. Still out of scope: any UI to
   re-point a subscription at a rotated URL, so the message is currently a dead
   end for that user.
8. **Ordering**: episodes sort newest first by `publishedAt`, `nil` dates last,
   via an in-memory sort helper (testable, avoids `SortDescriptor`-on-optional
   ambiguity). Library sorts podcasts by `addedAt`, oldest first.
9. **`lastRefreshedAt`** is stamped on the podcast after every successful
   add/refresh merge, and only on success.
10. **`FeedService` is a `@MainActor` struct** constructed at the call site with
    a `ModelContext` (matches the `EpisodeStore` cheap-struct precedent; SwiftData
    `@Model` mutation stays on the main actor; the test suites are already
    `@MainActor`).
11. **Refresh mutable metadata** — exactly: podcast `title`, `author`, `summary`,
    `artworkURL`; episode `title`, `summary`, `publishedAt`, `enclosureURL`,
    `feedDuration`. Never `isPlayed`, `playedAt`, `localFilename`,
    `downloadedAt`, `assetDuration`, `sessions`, `addedAt`. Never delete episodes.

## Context (from discovery)

- Full discovery lived in the session scratchpad and is gone with it; what
  survived of it is this plan.
- New files: `cue/Feed/FeedService.swift`, `cue/Views/LibraryView.swift`,
  `cue/Views/AddFeedView.swift`, `cue/Views/PodcastDetailView.swift`; edited:
  `cue/Views/ContentView.swift`. New test file: `cueTests/FeedServiceTests.swift`.
- `FeedParser().parse(data:sourceURL:)` is the **mandatory** entry for fetched
  documents (throws `Failure.emptyFeed(url)`; AGENTS.md pins this, and step 2's
  plan pre-committed step 3 to it). `parse(data:)` is for tests only.
- `ParsedFeed(title:author:summary:artworkURL:episodes:)`,
  `ParsedEpisode(guid:title:summary:publishedAt:enclosureURL:duration:)`.
  Field-name trap: `ParsedEpisode.duration` maps to `Episode.feedDuration`
  (`Episode.duration` is a derived read-only property).
- Model inits: `Podcast(feedURL:title:)` (sets `addedAt = .now` itself),
  `Episode(guid:title:enclosureURL:)`; other fields assigned after construction;
  `episode.podcast = podcast` links the relationship.
- `#Unique` insert is a destructive upsert for both `Podcast.feedURL` and
  `Episode.guid` — three ModelTests pin this. **Always fetch-then-mutate.**
- This is the repo's first network, first async, and first real-UI code. Swift 6
  strict concurrency (`SWIFT_VERSION = 6.0`). No `#Preview`, `@Query`, or
  navigation precedent exists.
- Test conventions: Swift Testing; `@MainActor` suites; per-suite private
  `makeContext()` building an in-memory `ModelContainer` with the **variadic**
  type list; fixtures via `fixtureData(named:withExtension:)`; the constant
  `https://example.com/feed?token=REDACTED_TEST_TOKEN` for feed URLs;
  `try #expect(…)` inside throwing closures; no force unwraps or `try!` anywhere
  including tests (swiftlint opt-in rules).
- Style: every collection literal on a single line (swift-format vs SwiftLint
  trailing-comma deadlock); 120 cols; `///` doc comments citing `(spec §N)`;
  alphabetized imports; nested `enum Failure: Error, Equatable` precedent
  (`EpisodeStore`, `FeedParser`); `OSLog` for non-fatal errors.
- No real feed URL anywhere in the repo; `gitleaks detect --no-git` before push.

## Development Approach

- **Testing policy**: per-task, code first
- **Verification policy**: per-task (`just build` + `just test`)
- Complete each task fully before moving to the next
- Make small, focused changes
- **CRITICAL: every task MUST include new/updated tests** for code changes in that task
  - tests are not optional - they are a required part of the checklist
  - write unit tests for new functions/methods
  - write unit tests for modified functions/methods
  - add new test cases for new code paths
  - update existing test cases if behavior changes
  - tests cover both success and error scenarios
- **CRITICAL: all tests must pass before starting next task** - no exceptions
- **CRITICAL: update this plan file when scope changes during implementation**
- Run tests after each change
- SwiftUI views get build coverage; extract any view logic worth asserting
  (sorting, formatting) into plain testable helpers instead of testing views

## Testing Strategy

- **Unit tests**: required for every task (see Development Approach above)
- All `FeedService` tests run against an in-memory `ModelContainer` and a stub
  transport closure returning fixture `Data` (e.g. `simple.rss`, `itunes.rss`,
  `tokenised.rss`) or a crafted `HTTPURLResponse` — zero network in tests
- No e2e framework exists in this project; simulator/manual checks are
  Post-Completion
- `just lint` and `just format-check` must also pass before the step is done
  (CI runs both)

## Progress Tracking

- Mark completed items with `[x]` immediately when done
- Add newly discovered tasks with ➕ prefix
- Document issues/blockers with ⚠️ prefix
- Update plan if implementation deviates from original scope
- Keep plan in sync with actual work done

## What Goes Where

- **Implementation Steps** (`[ ]` checkboxes): tasks achievable within this codebase
- **Post-Completion** (no checkboxes): manual/simulator verification, PR workflow
- Checkboxes belong only in Task sections

## Implementation Steps

### Task 1: FeedService — add(urlString:)

- [x] create `cue/Feed/FeedService.swift`: `@MainActor` struct constructed with
      `ModelContext` and a transport closure
      `@Sendable (URL) async throws -> (Data, URLResponse)` defaulting to a
      `URLSession.shared` wrapper; nested `enum Failure: Error, Equatable` with
      `invalidURL(String)` and `httpStatus(Int, String)`
- [x] implement `add(urlString:)`: validate URL (parses, http/https scheme) →
      fetch via transport → check `HTTPURLResponse` status is 2xx else throw
      `httpStatus` → `FeedParser().parse(data:sourceURL:)` → merge (below) →
      save
- [x] implement the shared merge: fetch `Podcast` by `feedURL` (create via
      `Podcast(feedURL:title:)` only when absent), update podcast mutable
      metadata, then per `ParsedEpisode` fetch `Episode` by `guid` store-wide —
      absent: insert and link to this podcast; present on this podcast: update
      episode mutable metadata; present on another podcast: skip. Stamp
      `lastRefreshedAt` on success. Never blind-insert either model
- [x] write tests (`cueTests/FeedServiceTests.swift`, stub transport + in-memory
      container): add success persists podcast + episodes with correct fields
      incl. `feedDuration`; tokenised URL stored verbatim
- [x] write error-path tests: invalid/non-http input throws `invalidURL`;
      403 response throws `httpStatus(403, url)`; `no-enclosures.rss` throws
      `FeedParser.Failure.emptyFeed(url)` and persists nothing; transport error
      propagates
- [x] write dedup tests: adding an already-subscribed feed does not wipe
      `author`/`summary`/`artworkURL`/`addedAt` and creates no duplicate
      episodes; a guid already owned by another podcast is skipped, not stolen
- [x] write ownership-guard tests: a *new* subscription whose every episode is
      owned elsewhere throws `allEpisodesOwnedElsewhere(url)` and deletes the
      podcast it inserted; an *already-subscribed* feed that contributes nothing
      stays a no-op refresh and is kept, not deleted (decision 7)
- [x] run `just build` and `just test` - must pass before task 2

➕ note: the merge also guards a feed that repeats a `guid` within one document
   (tracked in-merge, since a pending insert is not reliably fetchable), and a
   `parse(data:)` failure such as `malformedXML` is covered by its own test.

➕ *During review*: the dedup tests split into their own
   `cueTests/FeedServiceDedupTests.swift` (the same 400-line `file_length` cap),
   backed by a new `duplicate-guid.rss` fixture. Parsing hops off the main actor
   — `FeedService.parse(data:sourceURL:)` is `@concurrent nonisolated`, since
   `@MainActor` on the service is about SwiftData and nothing else; the rule is
   now in `AGENTS.md`. `fetch(urlString:)` ends with `Task.checkCancellation()`
   so a response that beats Cancel cannot still commit the subscription, and
   `saveOrDiscard()` checks a second time inside its `do` — the merge is
   synchronous, so a cancel arriving while it runs is observable nowhere else,
   and checking above the `do` would skip the discard and let autosave commit
   the merge anyway. `Failure` gained a third case,
   `allEpisodesOwnedElsewhere(String)`: a *new*
   subscription whose every episode is owned elsewhere is refused rather than
   left as a permanently empty library row (decision 7).

### Task 2: FeedService — refresh(_:)

- [x] implement `refresh(_ podcast:)` reusing the merge from task 1: fetch the
      podcast's `feedURL`, parse URL-aware, merge additively
- [x] write tests: refresh twice → no duplicate episodes; new feed items are
      inserted; mutable episode metadata (title, summary, publishedAt,
      enclosureURL, feedDuration) is updated
- [x] write invariant tests: refresh never deletes an episode that fell out of
      the feed window; never touches `isPlayed`, `playedAt`, `localFilename`,
      `downloadedAt`, `assetDuration`, or `sessions` on existing episodes;
      `lastRefreshedAt` stamped on success and untouched on a failed fetch
- [x] run `just build` and `just test` - must pass before task 3

➕ note: the refresh suite lives in its own `cueTests/FeedServiceRefreshTests.swift`
   (SwiftLint's 400-line `file_length` cap), backed by two new fixtures
   `refresh-initial.rss` / `refresh-updated.rss`. The swappable answer is the
   shared `FeedTransportStub` (`serve(data:)` / `serve(statusCode:)` /
   `fail(with:)`, lock-guarded); no per-suite double was added.

➕ *During review*: `refresh-stripped.rss` is a third fixture here, covering a
   document that stops carrying optional metadata.

### Task 3: Library — list, add-feed sheet, navigation root

- [x] create `cue/Views/LibraryView.swift`: `@Query` podcast list (artwork
      placeholder + title, sorted by `addedAt`), `.refreshable` refreshing all
      podcasts sequentially, toolbar add button presenting the sheet,
      `NavigationLink` to `PodcastDetailView`, empty state for zero podcasts,
      alert surfacing refresh errors
- [x] create `cue/Views/AddFeedView.swift`: sheet with a URL text field, add
      button calling `FeedService.add(urlString:)`, in-progress state, inline
      error text naming what failed (invalid URL / HTTP status / empty feed),
      dismiss on success
- [x] edit `cue/Views/ContentView.swift`: host a `NavigationStack` rooted at
      `LibraryView`
- [x] extract any non-trivial formatting/error-message mapping into a plain
      testable helper and write tests for it (e.g. `Failure` → user-facing
      message)
- [x] run `just build` and `just test` - must pass before task 4

➕ note: `cue/Views/PodcastDetailView.swift` is created here as a placeholder
   shell (title + empty state) so the library's `navigationDestination` compiles
   and the task stays independently green; task 4 fills it in. The error-message
   helper is the free function `feedErrorMessage(for:)` in
   `cue/Views/FeedErrorMessage.swift`, covered by `cueTests/FeedErrorMessageTests.swift`.

➕ note: `AddFeedView` trims surrounding whitespace/newlines from the pasted
   address before handing it to `FeedService` — a paste artifact, not part of
   the URL; tokens and query strings are still sent verbatim (decision 5).

➕ note: `refreshAll()` continues past a failing feed and reports the first
   error in the alert, so one broken subscription cannot block the rest.

➕ *During review*: `refreshAll` moved out of `LibraryView` into the free
   function `refreshAll(_:using:)` in `cue/Views/FeedRefreshing.swift`, so the
   continue-past-failure and first-error-wins policy is asserted rather than
   assumed; it also stops on cancellation and never reports one
   (`isCancellation(_:)`, same file). The whitespace trim became
   `normalisedFeedAddress(_:)` in `cue/Views/FeedAddress.swift` for the same
   reason. `AddFeedView`'s Cancel button cancels the in-flight task instead of
   being disabled — a black-holed host otherwise froze the sheet for the whole
   `URLSession` timeout with no way out. The two refresh alerts share
   `cue/Views/ErrorAlert.swift` — titled `RefreshErrorAlert.swift` at this point
   in the work, renamed once the title became a parameter and the detail screen
   needed a second, non-refresh alert.

### Task 4: Podcast detail — episode list

- [x] add a testable sort helper: episodes newest first by `publishedAt`, `nil`
      dates last (deterministic tie-break by `guid`)
- [x] create `cue/Views/PodcastDetailView.swift`: episode rows with title,
      formatted date, formatted duration (from `Episode.duration`), played
      indicator; mark played/unplayed action (sets `isPlayed` + `playedAt`
      both directions); `.refreshable` refreshing this podcast; empty state;
      refresh-error alert
- [x] write tests for the sort helper (mixed nil/non-nil dates, ordering,
      tie-break) and for the played toggle mutation (both directions,
      `playedAt` set/cleared, no side effects on download fields or sessions)
- [x] run `just build` and `just test` - must pass before task 5

➕ note: the sort helper and a duration formatter live together in
   `cue/Views/EpisodeListFormatting.swift` (`episodesNewestFirst(_:)`,
   `episodeDurationText(_:)`), covered by `cueTests/EpisodeListFormattingTests.swift`.
   The played toggle is `Episode.setPlayed(_:)` on the model — a mutation the
   view calls rather than view logic — so the orthogonality invariant (spec §4)
   is pinned by a model test, not by a view.

➕ *During review*: `episodeDurationText(_:)` bounds the duration at 100 hours.
   `DurationParser` can legitimately deliver `TimeInterval(Int.max)`, and
   `Int(_: Double)` traps on it — a crash on every render of a row the feed
   itself authored. The row's second line became `episodeSubtitle(_:_:)` in the
   same file. `PodcastDetailView` saves the played flag at the point of
   mutation rather than leaving it to autosave, where `FeedService`'s
   context-wide `rollback()` could discard it.

### Task 5: Verify acceptance criteria

- [x] verify all requirements from Overview are implemented (roadmap step 3
      tasks 1–4, decisions 1–11 honored)
- [x] verify the step-3 acceptance flows are covered by tests where automatable:
      refresh-twice-no-duplicates, played-flag-survives-refresh
- [x] run full test suite via `just test`
- [x] run `just lint` and `just format-check` - all issues must be fixed
- [x] run `gitleaks detect --no-git` - clean

### Task 6: Update documentation

- [x] update `AGENTS.md` only if a new durable convention emerged (e.g. the
      transport-injection pattern); otherwise no doc churn
- [x] update README.md if needed

➕ note: `AGENTS.md` gained a `## Networking` section (injected transport closure,
   failures that name what failed, `@MainActor` service structs) and a testing
   bullet recording that views are build-covered while their logic is extracted
   into tested free functions. README needed no change — its Build/Development
   sections still describe the repo accurately and it defers to `AGENTS.md`.

➕ *During review*: `AGENTS.md` gained the conventions this round established —
   the revalidating cache policy, the empty-new-subscription refusal, the
   cancellation classifier, the discard-on-failed-save rule, the unbounded
   parsed duration, the single transport stub, and the primary-vs-observer
   context assertion rule. README gained a one-line status marker: its feature
   bullets read as present-tense capability while downloads and playback do not
   exist yet.

➕ *During review, second pass*: `AGENTS.md` also gained the off-main-actor rule
   for non-model work, the pre-write cancellation check, the widened discard rule
   (merge as well as save, `context.delete` vs context-wide `rollback()`), and
   the shared `cueTests/InMemoryContainer.swift` helper. `ROADMAP.md`'s
   one-commit-per-step line now defers to `AGENTS.md`, and README's install line
   includes `gitleaks`, which its own secret-hygiene step requires.

*Note: ralphex automatically moves completed plans to `docs/plans/completed/`*

## Technical Details

- `FeedService.Failure: Error, Equatable` — `invalidURL(String)`,
  `httpStatus(Int, String)`, `allEpisodesOwnedElsewhere(String)`; all three carry
  the offending value so messages can name it (matches `emptyFeed(String)` /
  `invalidFilename(String)` precedent)
- Transport default wraps `URLSession.shared.data(for: feedRequest(for: url))`,
  not `data(from:)` — `FeedService.feedRequest(for:)` is what carries the
  `.reloadRevalidatingCacheData` policy, so the request-taking overload is the
  invariant; the closure type keeps `FeedService` free of any session
  configuration concern
- Merge fetches use `FetchDescriptor` with `#Predicate` on `feedURL` / `guid`
  (both plain stored strings — predicable, unlike `isDownloaded`)
- Episode insert path: `Episode(guid:title:enclosureURL:)` → assign `summary`,
  `publishedAt`, `feedDuration` → `episode.podcast = podcast` → `context.insert`
- All new collection literals stay on a single line; if one exceeds 120 cols,
  split into two named single-line values

## Post-Completion

*No checkboxes — external or manual actions.*

**Manual verification (simulator or device):**
- Add a real public feed → episodes appear with correct titles and dates (AC 1)
- Add the Boosty feed → episodes appear (AC 2, first half); on failure the
  HTTP status is visible in the error
- Pull-to-refresh on library and on detail; mark played from the row; confirm
  the flag survives a refresh
- No real feed URL may appear in any commit, test, or PR text while verifying

**PR workflow (after ralphex + finalize):**
- Rev chain finalized per AGENTS.md (plan artifacts stripped, revs atomic and
  green), then published via /pr-workout: draft PR titled `@coderabbitai`, body
  `@coderabbitai summary`, ready when CI green
