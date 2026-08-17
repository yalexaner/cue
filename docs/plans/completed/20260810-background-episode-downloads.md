# Background episode downloads (ROADMAP step 4)

## Overview

Implements ROADMAP step 4: episodes on disk, with state that survives
termination. A long-lived download manager drives a background `URLSession`
(single shared identifier, one download at a time), moves each finished file
into `Episodes/`, and only then writes `localFilename` and `downloadedAt`.
True duration is read from `AVURLAsset` into `assetDuration`. Delete clears the
download columns and removes the file, leaving `isPlayed` and sessions
untouched. The app grows its tab bar: Library plus a Downloads tab grouped by
podcast with total disk usage (spec §12). Download failures surface the HTTP
status code so a Boosty 403 is diagnosable (spec §6).

Satisfies spec AC 2 (download completes, file exists), AC 8 (played episode
stays in Downloads), AC 9 (delete preserves played state and sessions).

Primary rev commit message: `feat(downloads): background episode downloads`.

## Decisions (made during planning — do not re-litigate)

1. **UI scope is full spec §12**: `TabView` (Library, Downloads), Downloads
   grouped by podcast with total disk usage, download/delete actions and a
   downloaded indicator in the episode rows.
2. **Delete means one episode's download only.** Eager file cleanup on podcast
   deletion is step 9's bullet 3; no podcast-delete UI exists yet.
3. **Commit message carries a scope** (`feat(downloads): …`) per AGENTS.md and
   the precedent of steps 2–3, overriding the roadmap's scopeless form.
4. **`DownloadManager` is a long-lived `@MainActor @Observable final class`**,
   created once in `CueApp` (`@State`) and injected through the environment.
   This is a documented deviation from the cheap-struct service convention
   (AGENTS.md "Services … no shared instance"): a background session's delegate
   and its per-episode state need a lifetime longer than a call site. The
   deviation gets a doc comment on the type and an AGENTS.md note in the final
   task.
5. **The injection seam is the file-based transport from AGENTS.md**:
   `typealias FileTransport = @Sendable (URL) async throws -> (URL, URLResponse)`
   — a URL in, a temporary file URL plus `URLResponse` out. Tests inject a stub;
   no test constructs a real background session. The production closure wraps
   the background session and bridges its delegate callbacks through a
   continuation held by the manager.
6. **The relaunch path shares one finish function.** When iOS relaunches the
   app for a completed download, no continuation exists; the recreated
   session's delegate calls the same
   `finishDownload(tempURL:response:forGUID:)` path the transport route uses.
   Task-to-episode mapping rides in `URLSessionTask.taskDescription` (the
   episode `guid`), because the app that receives the callback may not be the
   app that started the task.
7. **Background completion delivery goes through `UIApplicationDelegateAdaptor`**
   with `application(_:handleEventsForBackgroundURLSession:completionHandler:)`.
   The repo has no AppDelegate yet; the adaptor is added to `CueApp` for exactly
   this one entry point. (SwiftUI's `.backgroundTask(.urlSession(_:))` was the
   alternative; the adaptor is the documented, debuggable path. If
   implementation finds the adaptor callback is not delivered on iOS 26, revisit
   with a ⚠️ note rather than silently switching.)
8. **No new `UIBackgroundModes` entry.** Background `URLSession` transfers are
   carried by the system daemon and do not require a background mode;
   `Info.plist` keeps `audio` only.
9. **Download progress/state is in-memory only.** No new SwiftData fields — the
   spec's schema has none, and `#Unique` upsert semantics make new columns a
   refresh hazard. Termination mid-download is recovered from the session
   (`getAllTasks`), not from the store.
10. **Filename generation lives on `EpisodeStore`**:
    `UUID().uuidString` + extension inferred from the enclosure URL path,
    fallback `mp3` (spec §5). Storage policy stays in the one type that owns
    paths.
11. **Download errors get their own `downloadErrorMessage(for:)`** free function
    beside `feedErrorMessage(for:)`, which stays feed-only. Cancellation is
    classified by the existing `isCancellation(_:)` and is never reported.
12. **`assetDuration` read failure is non-fatal.** If `AVURLAsset` cannot read a
    duration, the field stays `nil` (`duration` falls back to `feedDuration`)
    and the download still completes. No audio fixture is committed; tests
    cover the nil path with non-audio bytes.

## Context (from discovery)

- Files/components involved: `cue/Download/DownloadManager.swift` (new
  directory — synchronized groups pick it up automatically),
  `cue/Views/DownloadsView.swift`, `cue/Views/ContentView.swift` (becomes a
  `TabView`), `cue/Views/PodcastDetailView.swift` (row actions + indicator),
  `cue/Storage/EpisodeStore.swift` (move/remove/size/filename APIs),
  `cue/App/CueApp.swift` (manager ownership + delegate adaptor).
- `EpisodeStore` today: `episodesDirectory()` composes only,
  `prepareEpisodesDirectory()` is the sole mutating entry,
  `url(forRelativeFilename:)`/`fileExists(forRelativeFilename:)` guard against
  path traversal (rejects empty, `/`, `.`, `..`). No move/remove/size API
  exists. Never compose an episode path by hand.
- `Episode`: `localFilename` (relative), `downloadedAt`, `assetDuration`,
  `enclosureURL: String`, `isDownloaded(in:) throws -> Bool` (throwing method;
  a throw is never "not downloaded"). `setPlayed(_:)`/`restorePlayed(_:at:)`
  are the model-mutation precedent.
- `CueApp.init()` already calls `prepareEpisodesDirectory()` non-fatally and
  its comment pre-commits the download path to preparing the directory again
  and surfacing its own error.
- Service precedent: `FeedService` — `@MainActor struct`, injected transport
  typealias, `Failure` enum whose cases carry the offending value, assertable
  `static func feedRequest(for:)`, `@concurrent nonisolated static` for
  off-actor work, cancellation checked before the write and inside the `do`,
  `mergeOrDiscard`/`saveOrDiscard` discard rules.
- View precedent: `LibraryView`/`PodcastDetailView` — `ContentUnavailableView`
  empty states, `.refreshable`, `errorAlert(_:_:)`/`refreshErrorAlert(_:)`
  helpers, swipe + context-menu actions, per-view `Logger`, testable policy
  extracted into free functions under `cue/Views/`.
- Testing: Swift Testing only; shared `makeContext()`
  (`cueTests/InMemoryContainer.swift` — the one place a schema list would
  change), `withTemporaryBase` (synchronous today — an async overload is
  needed), one transport double per transport type, persistence asserted
  through a second `ModelContext`, cancelled-insert asserted on the primary
  context, `try #expect(…)` inside throwing closures.
- Lint traps: single-line collection literals (trailing-comma deadlock),
  `type_body_length` 400/600, default `file_length` warning 400 with
  `--strict`, `line_length` 120.

## Development Approach

- **Testing policy**: per task — code first
- **Verification policy**: per task (`just build` + `just test`)
- Complete each task fully before moving to the next
- Make small, focused changes
- **CRITICAL: every task MUST include new/updated tests** for code changes in
  that task
  - tests are not optional - they are a required part of the checklist
  - write unit tests for new functions/methods
  - write unit tests for modified functions/methods
  - add new test cases for new code paths
  - update existing test cases if behavior changes
  - tests cover both success and error scenarios
- **CRITICAL: all tests must pass before starting next task** - no exceptions
- **CRITICAL: update this plan file when scope changes during implementation**
- Run tests after each change
- Maintain backward compatibility with the shipped store schema — no new
  SwiftData fields

## Testing Strategy

- Unit tests required for every task (see Development Approach above).
- The real background `URLSession`, its delegate wiring, and the
  relaunch-completion path are exercised on a device (Post-Completion), never
  in tests — the seam is the injected `FileTransport`.
- Download-manager tests combine `makeContext()` with a temporary
  `EpisodeStore(baseDirectory:)`; an async `withTemporaryBase` overload is
  added first so async tests never touch the real Application Support.
- No e2e framework exists in this project; views are covered by the build, and
  every assertable policy (grouping, byte formatting, error mapping, row-action
  policy) is a tested free function.

## Progress Tracking

- Mark completed items with `[x]` immediately when done
- Add newly discovered tasks with ➕ prefix
- Document issues/blockers with ⚠️ prefix
- Update plan if implementation deviates from original scope
- Keep plan in sync with actual work done

## What Goes Where

- **Implementation Steps** (`[ ]` checkboxes): tasks achievable within this
  codebase - code changes, tests, documentation updates
- **Post-Completion** (no checkboxes): items requiring external action —
  on-device acceptance runs, PR workflow
- **Checkbox placement**: checkboxes belong only in Task sections

## Implementation Steps

### Task 1: EpisodeStore file operations and filename policy

- [x] add `EpisodeStore.downloadFilename(forEnclosureURL:)` — `UUID().uuidString`
      plus the extension of the enclosure URL's path, fallback `mp3` (spec §5)
- [x] add `EpisodeStore.moveFile(at:toRelativeFilename:)` — moves a temporary
      file into `Episodes/` through the traversal guard; overwrite-safe
      (a leftover file of the same name is replaced, not an error)
- [x] add `EpisodeStore.removeFile(forRelativeFilename:)` — removes through the
      guard; a confirmed not-found is success (the goal state), other errors
      propagate
- [x] add `EpisodeStore.fileSize(forRelativeFilename:)` — bytes via
      `URLResourceValues`; confirmed not-found answers `nil`, other errors throw
      (storage errors are never answered as "absent")
- [x] add an async overload of `withTemporaryBase` in
      `cueTests/TemporaryDirectory.swift`
      — ⚠️ landed as a separately named `withTemporaryBaseAsync(_:)`, not an
      overload: two same-named functions taking only a closure are ambiguous at
      a trailing-closure call site and `swift-format --strict` rejects that
      (`AmbiguousTrailingClosureOverload`). Later tasks call
      `withTemporaryBaseAsync`.
- [x] write tests for filename generation (extension inference, query strings,
      extensionless path → `mp3`, uniqueness)
- [x] write tests for move/remove/size success cases
- [x] write tests for error cases (traversal names throw, remove of a missing
      file succeeds, size of a missing file is `nil`, size propagates a
      permission error)
- [x] run `just build` and `just test` - must pass before task 2

### Task 2: DownloadManager core — fetch, finish, delete

- [x] create `cue/Download/DownloadManager.swift`: `@MainActor @Observable
      final class`, holding `ModelContext`, `EpisodeStore`, an injected
      `FileTransport` (`@Sendable (URL) async throws -> (URL, URLResponse)`),
      and an in-memory per-guid state map (`downloading` / `failed`); doc
      comment records the lifetime deviation from the cheap-struct convention
- [x] `enum Failure: Error, Equatable` with cases carrying the offending value:
      `invalidEnclosureURL(String)`, `httpStatus(Int, String)` — transport
      errors propagate unchanged
- [x] `download(_ episode:)`: serialize (one active transfer; later requests
      queue in order), call `prepareEpisodesDirectory()` before writing
      (surfacing its own error — never assume launch succeeded), run the
      transport, gate on 2xx, then hand off to the shared finish path
      — the slot is a main-actor FIFO of `CheckedContinuation`s
      (`acquireSlot`/`releaseSlot`), and the 2xx gate is the shared
      `statusFailure(for:enclosureURL:)` so task 4's relaunch route inherits it
- [x] `finishDownload(tempURL:response:forGUID:)`: move via
      `EpisodeStore.moveFile` first; only after a successful move write
      `localFilename` and `downloadedAt`, then save; on a failed save restore
      the pair and rethrow (the model must not disagree with the disk); check
      `Task.checkCancellation()` before the move, inside the `do`
      — ➕ the failure path also removes the just-moved file (its name is a
      fresh UUID, so nothing else points at it) and a successful re-download
      removes the superseded one, so neither route orphans audio
- [x] `deleteDownload(for episode:)`: capture the pair, clear `localFilename`
      and `downloadedAt`, save at the point of mutation, then remove the file;
      a failed save restores the pair; `isPlayed`, `playedAt` and sessions are
      never touched
- [x] write tests: a stubbed transport download lands the file and writes both
      columns (asserted through a second `ModelContext`)
- [x] write tests: non-2xx surfaces `Failure.httpStatus` with the status and
      URL, and writes nothing (AC for the Boosty 403)
- [x] write tests: cancellation after the transport answers commits nothing,
      asserted on the primary context
- [x] write tests: delete clears the columns, removes the file, and leaves
      `isPlayed`/`playedAt`/sessions untouched (AC 9); a second download after
      delete works
- [x] write tests: a failed move writes neither column; a played episode's
      download keeps its file and columns (AC 8)
- [x] run `just build` and `just test` - must pass before task 3
      — ⚠️ `withTemporaryBaseAsync` needed an
      `isolation: isolated (any Actor)? = #isolation` parameter: without it a
      `@MainActor` suite sending a closure over `@Model` values is a Swift 6
      data-race error. For the same reason the serialization test uses
      `Task {}` (inherits the suite's actor) rather than `async let`.

### Task 3: assetDuration from AVURLAsset

- [x] add `@concurrent nonisolated static func assetDuration(at url: URL) async
      -> TimeInterval?` on `DownloadManager` using `AVURLAsset.load(.duration)`;
      any failure answers `nil` — a non-finite or non-positive duration counts
      as unreadable too, so an indefinite stream cannot write a junk value
- [x] call it from the finish path after the move; write `assetDuration` only
      when non-nil, alongside the same save; a nil read still completes the
      download
      — ⚠️ `finishDownload(tempURL:response:forGUID:)` became `async throws`,
      since the read is awaited inside its `do`. Task 4's relaunch route calls
      it from a `Task` in the delegate. The restore path now also puts
      `assetDuration` back with the other two fields.
- [x] write tests: non-audio bytes complete the download with `assetDuration`
      still `nil` and `duration` falling back to `feedDuration`
- [x] write tests: the duration read never runs when the move failed
      — asserted as "a pre-existing `assetDuration` survives a failed move"
      (the observable consequence), plus a direct test that
      `assetDuration(at:)` answers `nil` for a missing and for a garbage file.
      New suite `cueTests/DownloadManagerDurationTests.swift`, split off
      `DownloadManagerTests` for `file_length`.
- [x] run `just build` and `just test` - must pass before task 4

### Task 4: Background session, delegate, and relaunch delivery

- [x] build the production `FileTransport` over a background
      `URLSessionConfiguration` with the single shared identifier
      (`dev.yachmenev.cue.downloads`), session configuration behind the
      closure; delegate bridges `didFinishDownloadingTo`/`didCompleteWithError`
      to the awaiting continuation; the temp file is moved (or claimed) inside
      the delegate callback, before it returns
      — landed as `cue/Download/BackgroundDownloader.swift`, a
      `BackgroundDownloader.shared` singleton: a background session identifier
      is process-global, so a second instance would be a runtime error. It
      publishes only `transport`; continuations are keyed by `taskIdentifier`
      and cancellation is bridged with `withTaskCancellationHandler`
- [x] stamp `taskDescription` with the episode guid when a task is created;
      on relaunch, resolve the guid back to an `Episode` and route through
      `finishDownload` — no continuation exists on that path
      — ⚠️ `FileTransport` takes a URL and nothing else (decision 5), so the
      guid reaches the transport through a task-local,
      `DownloadTaskIdentity.currentGUID`, set by `download(_:)` around the one
      call. The task-local lives on `DownloadTaskIdentity` rather than on
      `DownloadManager` because a `@TaskLocal` on a `@MainActor` type keeps its
      projected value main-actor isolated, which a transport running off the
      main actor cannot read
- [x] reconnect at launch: recreate the session with the same identifier and
      adopt in-flight tasks via `getAllTasks` so a mid-download termination
      resumes reporting into the state map
      — `DownloadManager.connect(to:)` registers the orphan handler and adopts
      via `session.allTasks` (the async property; `getAllTasks`'s callback form
      is the pre-concurrency spelling of the same thing)
- [x] add a minimal `AppDelegate` (`UIApplicationDelegateAdaptor` in `CueApp`)
      implementing
      `application(_:handleEventsForBackgroundURLSession:completionHandler:)`:
      store the handler, recreate the session, call the handler when the
      delegate reports `urlSessionDidFinishEvents`
      — ➕ the handler UIKit passes is not `Sendable`; it is bridged with a
      `nonisolated(unsafe)` local and only ever called back on the main actor,
      which is where UIKit requires it
- [x] `CueApp` owns the manager (`@State`) and injects it via `.environment`
      — ➕ `CueApp` now builds the `ModelContainer` itself instead of using
      `.modelContainer(for:)`, because the manager needs `mainContext` in
      `init()`, before the scene body runs. `.task` on the root view calls
      `connect(to: .shared)`
- [x] write tests for the guid round-trip through `taskDescription` (encode and
      resolve; unknown guid is ignored, not a crash) — extracted as a testable
      function; the session and delegate themselves are device-verified only
      — `cueTests/DownloadTaskIdentityTests.swift`: round-trip, a guid
      containing colons, an unstamped task, a description written by something
      else, the bare marker, plus the task-local hand-off. The unknown-guid
      route was already pinned by `finishingAnUnknownGUIDIsIgnored`
- [x] run `just build` and `just test` - must pass before task 5

### Task 5: Views — tab bar, Downloads screen, row actions

- [x] `ContentView` becomes a `TabView`: Library (existing `NavigationStack`)
      and Downloads (new `NavigationStack` over `DownloadsView`); update its
      doc comment
- [x] `DownloadsView`: episodes with `isDownloaded == true`, filtered in
      memory through `Episode.isDownloaded(in:)` (it cannot appear in a
      `#Predicate`; a storage throw surfaces as an alert, never as an empty
      list), grouped by podcast, with total disk usage from
      `EpisodeStore.fileSize`; delete action per row; empty state via
      `ContentUnavailableView`
      — the scan runs in `rebuild()` off
      `.onChange(of: downloadSignature, initial: true)` rather than in the body:
      `@Query` re-runs the body for any episode change, and a played flag must
      not cost a directory scan. A failed scan leaves the previous list standing
      (and alerts) instead of emptying it, and the empty state is shown only
      after a scan that actually succeeded
- [x] extract assertable policy into tested free functions
      (`cue/Views/DownloadListFormatting.swift`): grouping by podcast,
      per-group and total byte formatting (`ByteCountFormatStyle`), row sort
      order
      — ➕ two more policies landed in the same file because they are decisions
      the two screens must not answer differently:
      `episodeDownloadState(localFilename:transfer:)` (a transfer in flight
      outranks a stored file; a failed retry over an existing file is still
      `downloaded`) and `downloadAction(for:)` (mid-transfer offers neither
      action). The detail row reads `localFilename`, never the file system: a
      throwing per-row disk check on every render is both slow and a
      swallowed-error hazard, so `DownloadsView` is where presence is verified
- [x] `PodcastDetailView`: downloaded indicator on `EpisodeRow`, and
      Download / Delete Download swipe + context-menu actions driven by the
      environment manager, mirroring the `playedLabel(for:)` pattern; failures
      set a download alert message
- [x] add `downloadErrorMessage(for:)` in `cue/Views/DownloadErrorMessage.swift`
      mapping `DownloadManager.Failure` (status + URL named), `EpisodeStore`
      failures, and transport errors to user text; cancellation answers `nil`
      via the existing `isCancellation(_:)`
      — returns `String?` (not `String`) so cancellation cannot be reported by
      forgetting a `catch` clause, matching `reportableFeedErrorMessage(for:)`
- [x] write tests for the formatting/grouping free functions (empty, one
      podcast, several podcasts, byte totals)
- [x] write tests for `downloadErrorMessage(for:)` (httpStatus names status and
      URL, cancellation is nil, unknown errors fall back)
- [x] run `just build` and `just test` - must pass before task 6

### Task 6: Verify acceptance criteria

- [x] verify all requirements from Overview are implemented (spec §7 list,
      §12 Downloads screen, §6 status surfacing)
      — §7: background session on one identifier
      (`BackgroundDownloader`, `dev.yachmenev.cue.downloads`), temp file moved
      before `localFilename`/`downloadedAt` are written
      (`DownloadManager.finishDownload`), `assetDuration` read from
      `AVURLAsset` after the move, one active transfer
      (`acquireSlot`/`releaseSlot`, pinned by `downloadRunsOneTransferAtATime`),
      manual trigger only (row actions), delete clears both columns and removes
      the file while leaving `isPlayed`/sessions alone. §12: `ContentView` is a
      `TabView` (Library, Downloads); `DownloadsView` groups by podcast with
      per-group and total disk usage. §6: `Failure.httpStatus(Int, String)` is
      surfaced by `downloadErrorMessage(for:)` naming status and URL
- [x] verify edge cases: dangling row shows as not downloaded; a storage error
      alerts instead of wiping the list; re-download after delete; played and
      downloaded state never cross (AC 8/9 invariant tests still green)
      — `DownloadsView.rebuild()` filters through `Episode.isDownloaded(in:)`
      (disk), so a row whose file is gone drops out; a throw sets
      `storageErrorMessage` and leaves the previous list standing, and the
      empty state renders only after a scan that succeeded. Re-download after
      delete: `downloadingAgainAfterADeleteWorks`,
      `aRedownloadReplacesThePreviousFile`. AC 8/9:
      `markingPlayedKeepsTheFileAndTheColumns`,
      `downloadingAPlayedEpisodeLeavesPlayedStateAlone`,
      `deleteClearsTheColumnsAndPreservesPlayedStateAndSessions`
- [x] run full test suite via `just test` — 237 tests in 31 suites passed
- [x] run `just lint` - all issues must be fixed — 0 violations in 50 files
- [x] run `just format-check` - must pass — clean
- [x] run `gitleaks detect --no-git` - no findings — no leaks found

### Task 7: Update documentation

- [x] README.md status paragraph: downloads move from "not built" to built
- [x] AGENTS.md: record the `DownloadManager` lifetime deviation (long-lived
      `@Observable` class owning the background session) and the
      `FileTransport` seam as the download-networking convention
      — the seam bullet also records the out-of-band identity path
      (`DownloadTaskIdentity.currentGUID` → `taskDescription`) and why
      `BackgroundDownloader` is a singleton (process-global session identifier)
- [x] update `ContentView`/`PodcastDetailView` doc comments that promised
      "arrives with downloads" features
      — ⚠️ already current: both were rewritten in task 5 when the tab bar and
      the row actions landed. A sweep of `cue/` found no remaining
      forward-looking download text; `LibraryView`'s artwork-placeholder note is
      about images, not downloads, and stays

*Note: ralphex automatically moves completed plans to `docs/plans/completed/`*

## Technical Details

- `FileTransport` = `@Sendable (URL) async throws -> (URL, URLResponse)`;
  production closure owns the background session; tests inject stubs (a
  suite factory over shared pieces; the double lives in
  `cueTests/DownloadTransportStub.swift`).
- Serial execution: the manager keeps a FIFO of pending guids and one active
  transfer; spec §7 "one active download at a time".
- Finish path ordering: cancellation check → move → model writes
  (`localFilename`, `downloadedAt`, then `assetDuration` if readable) → save →
  state-map cleanup. The save failure path restores captured values so the
  store never claims a file it did not verify.
- Delete ordering: clear columns → save → remove file. A file whose row
  clearing committed but whose removal failed is an orphan the step-9 sweep
  will collect; the reverse order could leave a row pointing at nothing, which
  is the direction the design forbids.
- Byte totals use `URLResourceValues.fileSize` per episode, summed per podcast
  group; formatting via `ByteCountFormatStyle` in a free function.
- New files: `cue/Download/DownloadManager.swift`,
  `cue/Download/BackgroundDownloader.swift`,
  `cue/Download/DownloadTaskIdentity.swift`, `cue/App/AppDelegate.swift`,
  `cueTests/DownloadTaskIdentityTests.swift`,
  `cue/Views/DownloadsView.swift`, `cue/Views/DownloadListFormatting.swift`,
  `cue/Views/DownloadErrorMessage.swift`, `cueTests/DownloadManagerTests.swift`,
  `cueTests/DownloadListFormattingTests.swift`,
  `cueTests/DownloadErrorMessageTests.swift`,
  `cueTests/DownloadTransportStub.swift`, plus
  `cueTests/EpisodeStoreFileOperationsTests.swift` (task 1, split off
  `EpisodeStoreTests` for `file_length`) and
  `cueTests/DownloadManagerDurationTests.swift` (task 3, same reason). Watch the
  400-line `file_length` warning under `--strict`; split suites the way step 3
  did.
  — ➕ review follow-up added `cue/Download/DownloadPolicy.swift` (the stateless
  download decisions, split off `DownloadManager.swift` for `file_length`),
  `cueTests/DownloadManagerQueueTests.swift` and
  `cueTests/DownloadManagerRelaunchTests.swift`.

## Post-Completion

*Items requiring manual intervention or external systems - no checkboxes,
informational only*

**On-device acceptance** (the roadmap's acceptance list needs a real feed on a
real device):

- Add the Boosty feed, download an episode → completes, file exists (AC 2).
- Background the app mid-download → the download completes.
- Force-quit vs background: force-quit cancels transfers (expected iOS
  behavior); backgrounding must not.
- Delete a download → played state and session history survive (AC 9).
- Mark an episode played → it stays in Downloads with its file (AC 8).
- A 403 from a token-rotated enclosure shows the status code in the alert.
- Verify the adaptor's completion handler actually fires on iOS 26 when a
  download finishes with the app suspended (Decision 7's contingency).

**PR workflow**: finalize revs per AGENTS.md (this plan travels as its own
rev), draft PR titled `@coderabbitai` with body `@coderabbitai summary`, CI
green before ready-for-review; merge is the owner's call.
