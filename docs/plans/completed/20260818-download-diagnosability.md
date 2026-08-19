# Download diagnosability and transfer visibility (ROADMAP step 4.5)

## Overview

Step 4 shipped downloads that work but cannot be observed or recovered. On-device
testing produced a transfer that spun indefinitely with no progress, no cancel and
no error, then failed silently into an orange triangle carrying no message —
and a separate class of feeds that refuse to be added at all. This step makes a
transfer legible and recoverable, and unblocks plain-http feeds.

Five changes:

1. **ATS exception** — plain `http://` feeds and enclosures are blocked by iOS.
2. **Byte progress** — a moving transfer must be distinguishable from a stalled one.
3. **Failure detail** — a failed row must say why, including on the relaunch route.
4. **Cancel + resource timeout** — an escape hatch, and a backstop so an
   abandoned transfer eventually fails on its own.
5. **Active-transfers section on the Downloads tab** — every in-flight and failed
   transfer in one place, rather than one spinner buried per podcast.

This is not a spec feature; it is the diagnosability step 4 deferred. It gates
step 5, whose acceptance (AC 4: download, airplane mode, force-quit, play)
requires a successfully downloaded episode on the device — which is currently
unobtainable.

Primary rev commit message: `feat(downloads): progress, failure detail and cancel`.

## Decisions (made during planning — do not re-litigate)

1. **`NSAllowsArbitraryLoads`, not per-domain exceptions.** Distribution is an
   unsigned `.ipa` through a re-signing service, so there is no App Store review
   to justify it to, and per-domain exceptions are unmanageable for arbitrary
   user-pasted feeds. `DownloadPolicy.downloadURL(for:)` already admits the
   `http` scheme deliberately — the app config simply never granted it.
2. **The ATS dictionary goes in `cue/Support/Info.plist`.** No
   `INFOPLIST_KEY_NSAppTransportSecurity` build setting exists (verified against
   Xcode's `CoreBuildSystem.xcspec`: all 95 `INFOPLIST_KEY_*` settings
   enumerated, absent). This is the same limitation `UIBackgroundModes` hit in
   ROADMAP 0.2, and the partial plist is already wired via `INFOPLIST_FILE`
   (`Config/App.xcconfig:5`). **No `project.pbxproj` edit is needed.**
3. **Cancel is guid-addressable, not `Task`-handle-based.** `DownloadManager`
   stores no `Task` handles and `BackgroundDownloader` stores no
   `URLSessionTask`; `pending` is keyed by `taskIdentifier` and holds
   continuations. More decisively: a transfer *adopted* after relaunch has no
   in-process `Task` at all, and that is precisely the state a user needs to
   escape. Cancel therefore enumerates `session.allTasks` and matches
   `taskDescription` — the mechanism `adoptInFlightTasks()`
   (`BackgroundDownloader.swift:147-149`) already half-implements. Session
   cancel is best-effort (`allTasks` is a snapshot): the attempt record's
   cancellation checkpoints (Decision 8) close the windows the snapshot misses,
   so a cancel landing mid-finalisation cannot commit the file.
4. **The transfer queue is cancellation-aware, not merely checked-after-wake.**
   `acquireSlot()` parks on a continuation, and a queued transfer has no session
   task yet, so `allTasks` cannot reach it — and a cancelled-set consulted only
   after the slot arrives would leave Cancel apparently ignored until every
   earlier transfer finishes. Waiters therefore carry their guid and park on
   *throwing* continuations; cancel removes the matching waiter and resumes it
   with `CancellationError` immediately, releasing its ownership through the
   normal catch. The existing `try Task.checkCancellation()` after
   `acquireSlot()` stays.
5. **Progress travels through an installed handler, not a task-local.**
   `DownloadTaskIdentity.currentGUID` is unreadable from a delegate callback.
   Progress maps task to guid via `taskDescription`, exactly as `deliver(_:for:)`
   does, and reaches the `@MainActor` state through a `@Sendable` handler
   installed on the downloader — copying `registerCompletionRoute(with:)`
   (`DownloadManager.swift:220-235`). The session uses `delegateQueue: nil`, so
   the callback is off-main.
6. **Progress is a three-state value, not `Double?`.** A background session
   never fails fast: connection-level failures are retried silently by the
   system daemon (which exposes no callback for those retries) until
   `timeoutIntervalForResource`. The one observable moment is the first
   `didWriteData` callback — and `Double?` cannot carry the distinction between
   "no bytes yet" and "bytes flowing, total unknown"
   (`totalBytesExpectedToWrite == NSURLSessionTransferSizeUnknown`, -1). So a
   dedicated value:

   ```swift
   enum DownloadProgress: Equatable {
       case waiting
       case indeterminate(bytesWritten: Int64)
       case fraction(bytesWritten: Int64, value: Double)
   }
   ```

   The row renders waiting ("Waiting…" — the user's cue to check the network),
   a percentage, or an indeterminate bar. Raw bytes resolve unordered
   main-actor hops: reject only *lower* byte counts — an equal-count update is
   applied, since it can carry richer information (an unknown total becoming
   known, a corrected total). `totalBytesExpectedToWrite` is an `Int64` and
   cannot be non-finite; the guards are `expectedBytes > 0` and
   `bytesWritten >= 0`, with the *derived* `Double` fraction required finite
   and clamped to `0...1` (`NaN` is never equal to itself, which destabilises
   synthesized `Equatable`).
7. **Lifecycle decisions use case predicates, never payload equality.** With
   associated values, `states[guid] != .downloading` (the duplicate guard,
   `DownloadManager.swift:133`) and the `.failed` comparison on the delete path
   (`:343`) stop compiling — and equality against `.downloading(.waiting)`
   would readmit a duplicate the moment progress arrives. `isDownloading` /
   `isFailed` predicates replace them.
8. **Progress and cancellation hang off one attempt record with an explicit
   lifecycle.** The ownership token (`DownloadOwnership.swift`) exists so an
   old orphan completion cannot write over a newer live transfer for the same
   guid; progress and cancellation extend that model rather than bypass it: an
   in-memory attempt record per guid carries the ownership token, the session
   task identifier once known, a cancellation flag, and the current progress.
   The lifecycle is explicit, because a progress event must never nominate
   itself as the live attempt:
   - **register** `(taskIdentifier, guid)` before the session task is resumed —
     a start-registration seam beside the transport, so the live-attempt map
     exists before the first callback can possibly arrive;
   - **adoption** returns `(taskIdentifier, guid)` pairs, not bare guids, so an
     adopted attempt is addressable exactly like a started one;
   - **retire** the exact attempt on any terminal outcome — success, failure,
     cancellation — clearing its cancellation flag with it, so a cancelled
     attempt cannot poison a later retry;
   - progress for an unregistered or retired attempt is dropped, and an update
     is applied only while its attempt is the guid's live one *and* the state
     is still `.downloading` — a delayed hop must not overwrite `.failed`,
     `nil`, or a newer attempt's progress.
   Cancellation intent lives on the record (attempt-scoped, never a bare guid
   flag) and is checked at four points: before transport creation, after the
   transport returns, before the move, and after the asset-duration await — so
   a cancel the `allTasks` snapshot missed is still honoured at the next
   checkpoint instead of letting the transfer run to commit.
9. **`timeoutIntervalForResource` is 2 hours, and it is not the stall remedy.**
   The property is a *total-transfer* deadline — it also runs while the daemon
   waits for connectivity — so a tight value kills legitimately slow large
   episodes that are still receiving bytes. The user-facing remedy for a stall
   is the waiting state plus cancel; the timeout only bounds the silent 7-day
   default so an abandoned transfer eventually fails on its own.
10. **The file split widens crossed `private` members deliberately.** Swift
    `private` is file-scoped, so moving the delegate extension and the relaunch
    route into their own files cannot keep every access level verbatim; each
    member the split crosses (`lock`, the accounting fields, `deliver`,
    `states`' setter, `resolvedGUIDs`, …) is widened to `internal` explicitly,
    with the widening reviewed and documented rather than asserted away.
11. **The two oversized files are split before anything else.**
    `BackgroundDownloader.swift` is 396/400 and `DownloadManager.swift` 388/400
    against SwiftLint's `file_length` under `--strict`
    (`ignore_comment_only_lines: false`). Splitting by topic is the documented
    house move, and doing it first keeps every later task's diff about
    behaviour. New download tests go into new topic files
    (`DownloadManagerProgressTests.swift`, `DownloadManagerCancellationTests.swift`):
    the existing suites are themselves at 371 and 354 lines.
12. **The active-transfers section derives directly from the observed `states`
    map.** `DownloadsView`'s `rebuild()` cache is keyed by `downloadSignature`,
    which carries no transfer state — routing the section through it would miss
    every pure progress change. The section is a section, not a new tab or a
    hidden toolbar hub; the downloaded list below keeps filtering on file
    presence only, so the spec invariant survives. Order: downloading before
    failed; within each group podcast title ascending, then published date
    newest-first with undated episodes last (the episode-list precedent), then
    guid ascending.
13. **Failed transfers live in that same section**, with the message and a
    retry — deliberately most of the "error hub" idea without a new screen.
    Feed-*add* failures are out of scope: they have no download row. An outcome
    for a guid whose episode no longer exists must not leak: episode existence
    is resolved before an orphan outcome is recorded, and state for a
    confirmed-missing episode is cleared. A *failed* existence fetch is not a
    confirmed miss: keep the failure state with a fixed safe message and a
    `.private` log — `handleCompletion` stays non-throwing (it has no caller to
    receive an error) and the delivery barrier completes exactly once on every
    path.
14. **The failure message is never a raw `localizedDescription`.** An arbitrary
    error description can embed the failing URL, and an enclosure URL is a
    credential (spec §6). `downloadErrorMessage(for:)` loses its pass-through
    fallback in favour of fixed per-category messages; redaction is asserted by
    a test whose error description contains a token-bearing URL. Feed-add
    errors deliberately keep naming the feed URL (spec §6's own requirement) —
    the redaction rule here is about enclosure/download surfaces.
15. **No new SwiftData columns.** Progress, failure text and cancellation are
    in-memory only, for the reason step 4 recorded: the spec's schema has none,
    and `#Unique` upsert semantics make a new column a refresh hazard.

## Context (from discovery)

- `DownloadState` (`cue/Download/DownloadManager.swift:46-51`): 10 writes, 7
  reads. `.failed` is written at **three** sites — the invalid-URL guard before
  ownership is claimed (`:135-137`), the live catch, and the relaunch catch —
  all three go through one shared helper (Task 4). 16 bare-case comparisons
  break: 2 in app code, 14 test assertions.
- `EpisodeDownloadState` (`cue/Views/DownloadListFormatting.swift:58-64`): 5 app
  callers. "A transfer in flight outranks a stored file" is pinned at
  `DownloadListFormattingTests.swift:170-174` and survives semantically. "A row
  mid-transfer offers neither action" is pinned at `:194-198` — that test **and
  its doc comment** assert the absence of cancel, and `DownloadListFormatting.swift:94-95`
  repeats the claim in prose. All three are rewrites.
- 10 download test files (~75 `@Test`) plus 3 shared doubles.
  `DownloadTransportStub` has no progress hook; `GatedFileTransport` parks on a
  non-cancellable `CheckedContinuation<Void, Never>`, so it gains keyed
  cancellation support before any cancel test can exist.
- Three test files carry a standing "no test may touch `session`" instruction, so
  every new mechanism needs a value-carrying seam testable without a background
  session — the same discipline as `deliver(_:forTaskIdentifier:taskDescription:)`.
- `DownloadsView` shows a "No Downloads" `ContentUnavailableView` whenever
  `groups.isEmpty` — with one active transfer and no completed files it would
  cover the new section, so its condition must include the active rows.
- The delivery barrier (`deliveredWorkInFlight`,
  `takeBackgroundEventsCompletionsIfReady`) counts every delivered outcome
  exactly once; cancellation must not add a second producer of outcomes — the
  delegate remains the only one.
- `swiftlint --strict` is currently clean (0 violations, 61 files).

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
- Maintain backward compatibility

## Testing Strategy

- Unit tests required for every task (see Development Approach above).
- No test may construct or touch a real background `URLSession`. Every new
  mechanism — progress delivery, guid-addressable cancel — gets a
  value-returning seam on `BackgroundDownloader` testable in isolation, matching
  `deliver(_:forTaskIdentifier:taskDescription:)` and `route(_:forGUID:)`.
- `DownloadTransportStub` gains a progress hook; `GatedFileTransport` gains
  keyed cancellation and carries the cancel tests. Never re-declare a per-suite
  copy of either.
- New download suites go into new topic files
  (`DownloadManagerProgressTests.swift`, `DownloadManagerCancellationTests.swift`)
  — the existing suites are at 371 and 354 of the 400-line limit.
- Views stay covered by the build; the assertable policy (row state, row action,
  what the active section lists and in what order) lives in free functions under
  `cue/Views/` and is tested directly.
- ATS is asserted through `Bundle.main` in the hosted test target rather than by
  eye. If the key proves unreadable there, drop the assertion and record it in
  Post-Completion as device-verified — do not fake it.
- The real delegate wiring, background relaunch, and ATS behaviour against a live
  server are device-verified in Post-Completion, never in tests.
- No e2e framework exists in this project.

## Progress Tracking

- Mark completed items with `[x]` immediately when done
- Add newly discovered tasks with plus prefix
- Document issues/blockers with warning prefix
- Update plan if implementation deviates from original scope
- Keep plan in sync with actual work done

## Implementation Steps

### Task 1: Split the two oversized download files

- [x] move the `URLSessionDownloadDelegate` extension and the background-events
      accounting out of `cue/Download/BackgroundDownloader.swift` into
      `cue/Download/BackgroundDownloaderDelegate.swift`, by topic, no behaviour change
- [x] move the relaunch/orphan route (`registerCompletionRoute(with:)`,
      `handleCompletion(_:forGUID:)`, `adopt(inFlightAttempts:)`) out of
      `cue/Download/DownloadManager.swift` into `cue/Download/DownloadRelaunch.swift`
- [x] list every `private` member the split crosses and widen each to `internal`
      deliberately, with a doc-comment note on why (Decision 10); keep doc
      comments verbatim otherwise
- [x] run `just lint` - must report 0 violations and no file over 400 lines
- [x] run `just build` and `just test` - all existing download tests must pass unchanged

### Task 2: ATS exception for plain-http feeds and enclosures

- [x] add `NSAppTransportSecurity` / `NSAllowsArbitraryLoads = true` to
      `cue/Support/Info.plist`
- [x] extend the comment at `Config/App.xcconfig:3-4` to name ATS as the second
      key with no `INFOPLIST_KEY_*` equivalent
- [x] write a test asserting the key is present and true via `Bundle.main`
      (hosted test target); if unreadable, remove it and note why in Post-Completion
- [x] run `just build` and `just test` - must pass before next task

### Task 3: Byte progress from the session to the row

- [x] add `DownloadProgress` (`.waiting` / `.indeterminate(bytesWritten:)` /
      `.fraction(bytesWritten:value:)`) and change `DownloadState.downloading`
      to carry it, starting at `.waiting`
- [x] add `isDownloading` / `isFailed` predicates and replace the two lifecycle
      comparisons (`DownloadManager.swift:133`, `:343`) — payload equality must
      not decide the duplicate guard or the delete path (Decision 7)
- [x] implement `urlSession(_:downloadTask:didWriteData:totalBytesWritten:totalBytesExpectedToWrite:)`
      in the delegate file, mapping task to guid via `taskDescription`
- [x] add a `@Sendable` progress-handler seam on `BackgroundDownloader` carrying
      (taskIdentifier, guid, progress), installed by `DownloadManager`, hopping
      to `@MainActor` per Decision 5
- [x] add the attempt-record lifecycle (Decision 8): a start-registration seam
      registering (taskIdentifier, guid) before `task.resume()`, adoption
      returning (taskIdentifier, guid) pairs, retirement on every terminal
      outcome
- [x] apply a progress update only while its attempt is the guid's live
      registered one and the state is still `.downloading`; reject only lower
      byte counts — equal-count updates apply (unknown total becoming known,
      corrected totals); guards: `expectedBytes > 0`, `bytesWritten >= 0`,
      derived fraction finite and clamped (Decision 6)
- [x] update `EpisodeDownloadState` and `episodeDownloadState(localFilename:transfer:)`
      to carry the three progress states
- [x] render the three states in the episode row: a "Waiting…" label before the
      first byte, a determinate bar for a known fraction, the indeterminate
      `ProgressView()` for an unknown total
- [x] add a progress hook to `DownloadTransportStub`
- [x] write tests (in `DownloadManagerProgressTests.swift`): guid mapping,
      unknown total, invalid totals, out-of-order hops, equal-byte
      unknown-to-known and changed-total transitions, registration preceding
      the first progress event, progress for unregistered and retired attempts
      dropped, duplicate suppression at waiting / known-fraction /
      unknown-total, stale progress after success, after failure, after cancel,
      and from an old task during a retry
- [x] update the breaking bare-case assertions across the existing suites
- [x] run `just build` and `just test` - must pass before next task

### Task 4: A failed row that says what failed

- [x] change `DownloadState.failed` to carry `message: String`
- [x] add one manager helper converting a non-cancellation error into
      `.failed(message:)` via `downloadErrorMessage(for:)`, used at **all
      three** failure writes: the invalid-URL guard (`DownloadManager.swift:135-137`),
      the live catch, and the relaunch catch
- [x] replace the raw `error.localizedDescription` fallback in
      `downloadErrorMessage(for:)` with fixed per-category messages — an
      arbitrary description can embed the failing URL (Decision 14)
- [x] write a redaction test: an error whose description contains
      `https://example.com/feed?token=REDACTED_TEST_TOKEN` yields a message
      showing at most scheme and host
- [x] extend `EpisodeDownloadState.failed` to carry the message and surface it -
      tappable indicator presenting the text
- [x] confirm the relaunch route still logs at `.private` privacy
- [x] write tests for the message surviving the relaunch route and for each of
      the three failure sites independently
- [x] run `just build` and `just test` - must pass before next task

### Task 5: Cancel a transfer, and bound an abandoned one

- [x] set `timeoutIntervalForResource` to 2 hours on the background
      configuration, with a comment per Decision 9 (total-transfer deadline,
      runs while waiting for connectivity, default 7 days; the stall remedy is
      the waiting state plus cancel)
- [x] make the transfer queue cancellation-aware per Decision 4: waiters carry
      their guid and park on throwing continuations; cancelling a queued
      transfer removes its waiter and resumes it with `CancellationError`
      immediately, releasing ownership through the normal catch — no waiting
      behind the running transfer, and an immediate retry must work
- [x] add guid-addressable session cancel on `BackgroundDownloader` (enumerate
      `allTasks`, match `taskDescription`, `task.cancel()`), exposed to the
      manager as an injected cancel seam beside the transport — the manager
      never reaches the singleton directly, and tests inject their own
- [x] cancellation only *requests* `cancel()`; the delegate remains the sole
      producer of outcomes, so the delivery-barrier accounting keeps its
      exactly-once invariant
- [x] store cancellation intent on the attempt record and check it at the four
      Decision 8 checkpoints (before transport creation, after the transport
      returns, before the move, after the asset-duration await), cleared with
      the record on every terminal outcome
- [x] add `.cancel` to `DownloadRowAction`, return it from `downloadAction(for:)`
      for `.downloading`, and wire it through both row-action sites (swipe and
      context menu) in both screens
- [x] rewrite `DownloadListFormattingTests.swift:194-198` and its doc comment,
      and the prose at `DownloadListFormatting.swift:94-95`, to state the new rule
- [x] confirm a cancelled transfer lands in `nil` state, not `.failed`
      (`isCancellation(_:)` already draws that line)
- [x] extend `GatedFileTransport` with keyed cancellation support
- [x] write tests (in `DownloadManagerCancellationTests.swift`): cancel
      in-flight, cancel queued (immediate effect, immediate retry), cancel after
      adoption, cancel racing completion, a cancel missed by the `allTasks`
      snapshot honoured at the next checkpoint, a cancelled attempt not
      poisoning an immediate retry
- [x] write barrier-accounting tests: live-task cancel, adopted-task cancel,
      queued cancel contributing no delivered-work increment, UIKit handler
      released exactly once
- [x] run `just build` and `just test` - must pass before next task

### Task 6: Active-transfers section on the Downloads tab

- [x] add a free function in `cue/Views/` deciding what the active section lists
      and in what order: downloading before failed; podcast title ascending,
      published date newest-first with undated last, guid ascending (Decision 12)
- [x] derive the section directly from the observed `states` map — never through
      `rebuild()` / `downloadSignature`, which carries no transfer state
- [x] resolve guid to `Episode` through one dictionary built from the view's
      existing episode query, not a fetch per guid
- [x] resolve episode existence before recording an orphan outcome: clear state
      for a confirmed-missing episode; on a *failed* existence fetch keep a
      fixed safe failure message, log `.private`, and complete the delivery
      barrier exactly once (Decision 13)
- [x] update the empty-state overlay: "No Downloads" only when both the
      downloaded groups and the active section are empty
- [x] render the section above the grouped list, hidden when empty: in-flight
      rows with progress and cancel, failed rows with message and retry
- [x] confirm the downloaded list below still filters on file presence only
- [x] write tests for the section policy: ordering, empty case, mixed states,
      unknown-guid success and unknown-guid failure
- [x] write tests for a failed row offering retry and an in-flight row offering cancel
- [x] run `just build` and `just test` - must pass before next task

### Task 7: Verify acceptance criteria

- [x] verify all five changes from Overview are implemented
- [x] verify no enclosure URL beyond scheme and host reaches the UI, and none
      reaches the log at `.public` privacy (feed-add errors deliberately keep
      naming the feed URL per spec §6 — out of scope here)
- [x] verify no new SwiftData column was added
- [x] run full test suite
- [x] run `just lint` and `just format-check` - all issues must be fixed
- [x] run `gitleaks detect --no-git` - must exit clean

### Task 8: [Final] Update documentation

- [x] add a step 4.5 section to `ROADMAP.md` between steps 4 and 5
- [x] amend `SPEC.md` §7 and §12 for the active-transfers section (owner-approved
      wording; the downloaded list still filters on file presence only)
- [x] update `AGENTS.md` with the new invariants: progress is in-memory,
      three-state and attempt-guarded; cancel is guid-addressable because
      adopted transfers have no `Task`; a failed state carries its message; the
      error-message fallback never renders a raw description
- [x] update `README.md` if needed

## Technical Details

- `DownloadState` becomes `.downloading(DownloadProgress)` and
  `.failed(message: String)`; `DownloadProgress` is `.waiting` /
  `.indeterminate(bytesWritten:)` / `.fraction(bytesWritten:value:)`.
  `Equatable` synthesis survives; the 16 bare-case comparisons do not, and
  lifecycle decisions move to `isDownloading` / `isFailed` predicates.
- Progress delivery: delegate (off-main) to `@Sendable` handler to
  `Task { @MainActor [weak self] }` to `states[guid]`, gated by attempt
  identity (the Decision 8 attempt record) and by the state still being
  `.downloading`. Out-of-order hops reject only lower byte counts.
- Cancel: an injected seam over `session.allTasks` filtered by
  `DownloadTaskIdentity.guid(fromTaskDescription:)` for session tasks, plus
  guid-keyed throwing waiters for transfers still queued behind the slot; the
  attempt record's four cancellation checkpoints close the snapshot and
  finalisation races.
- ATS: a two-key dictionary in the partial plist; generated keys merge into it.

## Post-Completion

*Items requiring manual intervention or external systems - no checkboxes*

**Device verification** (the whole point of this step):

- An `http://`-only feed adds successfully, and an `http://` enclosure downloads.
- A running download shows "Waiting…" until bytes flow, then a moving
  percentage — and the waiting state is the network-diagnosis cue (VPN on/off).
- A stalled download shows "Waiting…" and cancels immediately; an abandoned
  transfer fails on its own within the 2-hour backstop rather than in 7 days.
- Cancel stops an in-flight transfer, a queued transfer immediately, and one
  adopted after force-quit and relaunch - the case that has no in-process `Task`.
- Two downloads started from different podcasts both appear in the Downloads
  tab's active section, correctly ordered.
- The failure message names the HTTP status for a 403/404 enclosure and never
  shows more than the server's scheme and host.
- Background-session progress callback frequency and ordering on a real device
  (the unordered-hop guard is code-verified only).

**Unverified, carried forward from step 4** (not addressed here):

- `URLSessionTask.taskIdentifier` reuse across a recreated background session -
  `BackgroundDownloader.pending` is keyed by it, and Apple documents it as unique
  only *within* a session. Needs a device probe: start a download, kill the app,
  relaunch, log `allTasks` identifiers beside a freshly created task's. Attempt
  identity (Decision 8) narrows the blast radius but does not settle the probe.

**Deferred by owner decision:**

- A general error hub for failures with no download row (feed add, OPML import),
  with badge and redacted export. Revisit after retesting with failure text visible.
- The visual design pass (already v1.1 in the spec).

**PR workflow**: finalize revs per AGENTS.md (this plan travels as its own rev),
draft PR titled `@coderabbitai` with body `@coderabbitai summary`, CI green
before ready-for-review; merge is the owner's call.
