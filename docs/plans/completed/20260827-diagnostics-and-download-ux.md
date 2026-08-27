# Diagnostics and download UX (ROADMAP step 4.6)

## Overview

Two things came out of the first real device session on `master` (steps 4 + 4.5):

1. **A download failed at 100% and the cause was unrecoverable.** The alert said
   "The download could not reach the server", which is what `downloadErrorMessage`
   says for *every* `URLError` — `.timedOut`, `.networkConnectionLost`,
   `.cannotWriteToFile` alike. The foreground download path records state and
   rethrows without logging, and the only download-failure log in the tree is on
   the relaunch route at `.private`. So the owner tested, hit a real bug twice,
   and neither he nor an agent can say what it was. The step whose stated purpose
   was diagnosability cannot diagnose.
2. **The transfer UI does not say enough to be usable.** `.waiting` covers both a
   queued transfer and a connecting one and renders as one literal "Waiting…", a
   progress bar carries no visible numbers, there is no phase at all for the
   window between the last byte and the file landing — which is exactly where the
   observed failure happened — refresh spins for the inherited 60 s before
   reporting a timeout, and the row's download indicator is a button only in its
   failed state, so starting a download requires a swipe or a long-press.

This step fixes both: a diagnostics log the owner can export and hand to an
agent, and the download/feed feedback surfaces that make a test session
self-explanatory. It is deliberately the step *before* the next device session,
because everything after it depends on being able to read what happened.

**Not in this step, by owner decision:**

- **Unsubscribe.** There is no way to remove a podcast at all today. Adding one
  means a cascade rule over episodes, files, played flags and sessions plus spec
  AC 15. It is the only backlog item that loses data irreversibly; its own step.
- **The duplicate-subscription bug.** Adding the same feed twice produced two
  library rows, which `#Unique` on `feedURL` plus the `allEpisodesOwnedElsewhere`
  guard should have prevented. Needs the two exact URLs that were pasted.
- **The 100%-then-fail download itself.** No fix is proposed because nobody knows
  the cause. Tasks 2–5 are what make the next attempt readable.

## Context (from discovery)

Read from `master` (`d64d55f0`) and re-verified line by line across two
adversarial review rounds. Claims the earlier drafts got wrong are marked.

- `cue/Views/DownloadErrorMessage.swift` — `downloadErrorMessage(for:)` maps
  `is URLError` to one sentence with no subdivision. `redactedAddress(_:)` beside
  it trims a URL to scheme + host and is the reuse target for logging.
- `cue/Download/DownloadManager.swift:97` — declares `static let logger`, category
  **`downloads`**. **Correction:** it is not uncalled; it is used from extensions
  at `DownloadFinish.swift:45` and `DownloadRelaunch.swift:106,134,166`. What is
  true is narrower: the *foreground* path logs nothing and the one failure log is
  `.private` on the relaunch route.
- **Existing `os_log` categories are only `downloads` and `storage`**
  (`DownloadManager.swift:97`, `BackgroundDownloader.swift:85`, `CueApp.swift:9`,
  `PodcastDetailView.swift:18`). **Correction:** `download`, `feed` and
  `playback` do not exist.
- `cue/Download/DownloadProgress.swift` — three cases: `.waiting`,
  `.indeterminate(bytesWritten:)`, `.fraction(bytesWritten:value:)`. The fraction
  case **carries no expected total**, only a clamped ratio, so "X of Y" cannot be
  reconstructed from it. `rendersDifferently(from:)` at line 44 returns **`false`
  for two same-case `.indeterminate` values**, so byte counts never republish
  there.
- **`.waiting` is referenced in eight source sites** —
  `DownloadAttempts.swift:34`, `DownloadProgress.swift:15,47`,
  `DownloadRelaunch.swift:83,123`, `DownloadManager.swift:190`,
  `PodcastDetailView.swift:245`, `DownloadsView.swift:260` — **and six test
  files**: `DownloadManagerOwnershipTests`, `DownloadManagerQueueTests`,
  `DownloadManagerProgressTests`, `DownloadManagerRelaunchTests`,
  `ActiveDownloadFormattingTests`, `DownloadListFormattingTests`.
  **`BackgroundDownloader.swift:287,317` also spells `.waiting`, but that is a
  different enum** (a pending-continuation state) and must not be touched.
- `cue/Download/DownloadAttempts.swift:74-79` — `handleProgress` accepts a report
  when bytes are `>=` the last, i.e. **equal counts are deliberately accepted**.
  Any "no new bytes for 30 s" rule refreshed on every accepted report never fires.
- `cue/Download/DownloadManager.swift:190` — publishes `.downloading(.waiting)`
  **before** `acquireSlot(forGUID:)`, so queued and connecting are
  indistinguishable today.
- `cue/Download/DownloadManager.swift:217` and `DownloadRelaunch.swift:35` — the
  background-delivery accounting (`deliveryBarrier()`, `completeDeliveredWork()`)
  is **synchronous and runs from `defer`**. It decides when iOS may suspend the
  app mid-finish.
- `cue/Download/DownloadQueue.swift` — main-actor FIFO with one slot; queue
  position is derivable from `waiting`.
- `cue/Views/DownloadsView.swift:59-67` — `activeTransfers` reads
  `downloads.states` **directly**, not through `state(for:)`. Anything that must
  appear as time passes has to arrive as a write to that map.
- `cue/Views/PodcastDetailView.swift:215-232` — **Correction:** the indicator is
  not wholly inert; the `.failed` case is **already a `Button`** presenting an
  alert whose only action is OK. The other three cases are inert.
- `cue/Views/DownloadListFormatting.swift:96-104` — `downloadAction(for:)` maps
  **`.failed` to `.download`**. Routing an indicator tap through it would replace
  today's show-detail with a silent retry.
- `cue/Feed/FeedService.swift` — `feedRequest(for:)` sets only `cachePolicy`.
  **Correction:** `URLRequest` has **`timeoutInterval`**;
  `timeoutIntervalForRequest` is a `URLSessionConfiguration` property and does not
  compile here. It is an *idle* timeout, not a wall-clock deadline.
- **`FeedService` is constructed inside three views** —
  `AddFeedView.swift:77`, `PodcastDetailView.swift:172`, `LibraryView.swift:54` —
  never by `CueApp`. Anything injected into it has to reach those call sites.
- `cue/Views/FeedErrorMessage.swift:12,34` — `feedErrorMessage(for:)` and its
  `reportableFeedErrorMessage(for:)` wrapper take only an `Error`, and are called
  from `AddFeedView.swift:82`, `PodcastDetailView.swift:177`,
  `LibraryView.swift:55` and eighteen assertions in `FeedErrorMessageTests`.
  Changing that signature breaks all of them in the same commit.
- `cue/Views/FeedRefreshing.swift` — `refreshAll(_:using:)` returns only the first
  reportable error and reports nothing while it runs.
- `cue/Views/AddFeedView.swift` — URL-shaped placeholder (the blue link-looking
  text), no focus state, no clear control, no submit handling, no clipboard.
- `cue/Support/Info.plist` — exactly two keys, `UIBackgroundModes` and
  `NSAppTransportSecurity`. `Config/App.xcconfig:3-4` states the partial plist
  carries **only what `INFOPLIST_KEY_*` settings cannot express**.
- **Verified against the installed Xcode specification:**
  `INFOPLIST_KEY_LSSupportsOpeningDocumentsInPlace` **exists** as a build setting,
  and `INFOPLIST_KEY_UIFileSharingEnabled` **does not**. So the two keys go to
  different places — see Task 5.
- `cue/Storage/EpisodeStore.swift:28-40` — `Episodes/` lives under **Application
  Support**, so enabling Documents file sharing cannot expose it.
- **File lengths (measured).** `BackgroundDownloader.swift` **396**,
  `DownloadManagerProgressTests.swift` **394**, `DownloadManager.swift` **383**,
  `DownloadManagerRelaunchTests.swift` **363**, `DownloadsView.swift` **293**,
  `PodcastDetailView.swift` **260**. **Correction:** `AGENTS.md` claims the
  relaunch test file sits at exactly 400; it does not. The binding constraints are
  `BackgroundDownloader.swift` — which a stored sink alone would push over — and
  `DownloadManagerProgressTests.swift`, six lines from the cap in the suite this
  step adds to.
- Feed hosts from the device session are recorded outside this repository. Two
  public feeds were checked live; both return an accurate `Content-Length` (about
  13 MB and about 135 MB), one over three redirects from a plain-`http` enclosure
  to a signed CDN address. **No real feed or enclosure address appears in this
  plan**, per `docs/SECRETS.md`.

## Decisions (made during planning — do not re-litigate)

1. **The log is a file the app writes, not a network sink.** A write-only HTTPS
   endpoint on the owner's private VPS was considered and rejected: real new
   public surface for no gain over the share sheet.
2. **Redaction is structural, not a call-site habit.** A log field cannot be an
   arbitrary `String`: hosts and guids enter through opaque
   `DiagnosticsHost` / `DiagnosticsGUID` value types whose only initialisers
   sanitise, inside the diagnostics subsystem. A caller therefore *cannot* pass a
   raw address where a host is expected.
3. **A guid becomes a truncated SHA-256 digest over its UTF-8 bytes** — never a
   prefix of itself (a guid is feed-supplied and frequently a URL, so its first
   bytes can be a credential), and never Swift's `Hasher`, which is per-process
   randomised and would break correlation across the relaunches this log exists
   to explain.
4. **`os_log` stays.** The file is an additional sink, not a replacement.
5. **The file survives relaunch** — why it is a file and not
   `OSLogStore(scope: .currentProcessIdentifier)`.
6. **The writer is injected, never reached for.** A `DiagnosticsSink` protocol
   with a no-op default keeps every existing test off disk. One production
   instance exists so a single serial writer owns the file — a file-coordination
   reason, deliberately narrower than `BackgroundDownloader`'s (a duplicate
   background-session identifier is an OS-level runtime error; a second log
   writer is merely wrong).
7. **Logging never throws and never fails a caller.** A write failure degrades to
   `os_log` and is otherwise swallowed.
8. **The background-delivery barrier fires after logging, and awaits a flush.**
   An earlier draft of this plan declined to touch it, on the grounds that
   restructuring the app's suspension accounting for the benefit of logging is a
   bad trade. That reasoning was wrong about *which* records are at risk.
   `defer { deliveryBarrier() }` is registered inside the inner `do` at
   `DownloadManager.swift:217`, so it fires when that scope exits — **before**
   the outer `catch` at line 238 writes the failure state. The orphan route has
   the same shape at `DownloadRelaunch.swift:35`. So the records left unprotected
   are precisely the terminal ones — `failed`, `file moved`, `finished` — which
   are the entire evidence for the 100%-then-fail bug this step exists to
   diagnose. The barrier callback stays synchronous, but it moves out of `defer`
   to an explicit one-shot invoked after failure-state and log handling, with
   `await sink.flush()` before it, on both routes. A flush failure must still
   complete delivery — a lost log is survivable, a never-answered UIKit handler
   is not.
9. **Progress publishing stays throttled**, gains trailing delivery so a
   transfer cannot end on a stale row, and **exempts lifecycle transitions** —
   queued→connecting, queue reindex, stalled, finalizing and terminal states
   publish immediately. Only repeated byte/rate updates are rate-limited.
10. **A finalizing phase exists.** The interval between the last byte and the file
    landing is precisely where the reported failure occurs; leaving it rendered as
    ordinary 100% would reproduce the confusion this step exists to remove.
11. **Row tap is left inert.** Step 5 (unmerged) claims it for playback. The
    *indicator* becomes the control, with its own activation policy — the shared
    `downloadAction(for:)` maps `.failed` to `.download` and would turn today's
    show-detail tap into a silent retry.
12. **Failed stays show-detail on tap, and the alert gains an explicit Retry
    action** — so retry is reachable without a swipe, but never accidental.
13. **Deleting is confirmed on tap, immediate on swipe.**
14. **No ETA.** Speed and byte counts only.
15. **The add-feed sheet reads the clipboard deliberately**, allowing iOS to
    present its permission UI when it chooses to.
    `detectPatterns(for:)` decides whether to offer paste and does not prompt; a
    detection failure means no offer, never a blind read; the value is
    revalidated after the read because the clipboard can change in between.
16. **Stall threshold 30 s; feed idle timeout 20 s; rate window 5 s.**
17. **cue is English-only for now.** New strings are literals, and the queue
    position is worded without an ordinal so no ordinal formatting is needed.

## Development Approach

- **Testing policy**: per task, code first — every task ends by writing tests for
  what it added.
- **Verification policy**: per task — every task ends with `just build` and
  `just test`, both green, before the next task starts.
- Complete each task fully before moving to the next.
- Make small, focused changes.
- **CRITICAL: every task MUST include new/updated tests** for code changes in
  that task
  - tests are not optional — they are a required part of the checklist
  - write unit tests for new functions/methods
  - write unit tests for modified functions/methods
  - add new test cases for new code paths
  - update existing test cases if behavior changes
  - tests cover both success and error scenarios
- **CRITICAL: all tests must pass before starting next task** — no exceptions.
- **CRITICAL: update this plan file when scope changes during implementation.**
- Maintain backward compatibility with everything already merged.

### Project rules that constrain every task

From `AGENTS.md`, not negotiable inside this plan:

- Views are covered by the build only. Anything assertable — formatting, phase
  vocabulary, error mapping, row policy, activation policy — is extracted into a
  free function or small value type and tested directly.
- Keep every collection literal on one line.
- `just lint` runs `--strict`, so the 400-line `file_length` warning fails the
  build. **Measured headroom is in the Context section. Task 1 and Task 6 are
  pure-move splits that create room before anything is added.**
- Never edit `cue.xcodeproj/project.pbxproj`. New `.swift` files under `cue/` and
  `cueTests/` compile automatically.
- One transport double per transport type; one fixture loader; one `makeContext()`.
- Inside a throwing closure write `try #expect(…)`, not `#expect(try …)`.
- A `#require` must be bound to a `let` first.
- No real feed URL in fixtures, tests, comments or commit messages.

## Testing Strategy

- **Unit tests**: required for every task.
- Every new behaviour lands as a free function or small value type: the record
  formatter and its escaping, the guid digest, rotation, the phase model, the
  throttle, the rate window, the status vocabulary, the sweep summary, the
  activation policy, the paste-offer decision, the export assembly, the size
  formatter.
- **Time is injected everywhere it matters.** Stall deadlines, the throttle and
  the rate window are time-dependent; no test may sleep. The formatter takes its
  timestamp as an input rather than reading the clock.
- The writer is tested against a temporary directory through the existing
  `withTemporaryBase` / `withTemporaryBaseAsync` helpers; every service test keeps
  the no-op sink. Never touch the real Application Support or Documents.
- No test constructs a background `URLSession`.
- **E2E tests**: the project has none and none are added.
- **Device verification is where this step is really judged** — see
  Post-Completion.

## Progress Tracking

- Mark completed items with `[x]` immediately when done.
- Add newly discovered tasks with ➕ prefix.
- Document issues/blockers with ⚠️ prefix.
- Update plan if implementation deviates from original scope.
- Keep plan in sync with actual work done.

## What Goes Where

- **Implementation Steps** (`[ ]` checkboxes): code, tests, docs.
- **Post-Completion** (no checkboxes): the device session, the signing
  round-trip, anything needing the owner's phone.

## Implementation Steps

### Task 1: Source splits for headroom

Behaviour-preserving moves. **Access-control-only changes are expected and
permitted** — a `private` member cannot be reached from an extension in another
file, and `DownloadsView` cannot reference a row type that stays file-private
after being moved. Nothing else changes: no signatures, no logic, no tests.

- [x] split `cue/Download/BackgroundDownloader.swift` (396 lines) by topic — the
      session and configuration half from the routing half — since Task 3 adds
      stored state and would otherwise cross the strict 400-line cap
- [x] promote exactly the routing state and types the moved extension needs from
      `private` to `internal` — at minimum `pending`, `orphanedCompletion`,
      `attemptRegistration`, `progressHandler`, `unroutedCompletions`,
      `UnroutedCompletion` and `TransferSlot` (`BackgroundDownloader.swift:54-95`)
      — and enumerate them in the commit message so the widening is auditable
- [x] decide and record where the private `Delivery` type
      (`BackgroundDownloader.swift:76`) and the `logger`
      (`BackgroundDownloader.swift:83`) land: either they stay with their current
      callers or they join the widened list. Do not leave it implicit — an
      unplanned widening here is how the audit list stops being trustworthy
- [x] move `DownloadManager.deleteDownload` and its helpers out of the 383-line
      `cue/Download/DownloadManager.swift` into `cue/Download/DownloadDeletion.swift`,
      following the `DownloadFinish` / `DownloadOwnership` precedent
      (leaves the manager at roughly 318 lines)
- [x] move `ActiveDownloadRow` and `DownloadedEpisodeRow` out of the 293-line
      `cue/Views/DownloadsView.swift` into **`cue/Views/DownloadRows.swift`**,
      making them `internal` (leaves the view at roughly 229 lines).
      **Tasks 7, 8, 9 and 11 reference that new file, not `DownloadsView.swift`,
      for row rendering**
- [x] run `just build` and `just test` — must pass before next task

### Task 2: Diagnostics record, safe field types and the writer

- [x] create `cue/Diagnostics/DiagnosticsRecord.swift` — the concrete value
      `record(_:)` accepts, so this task compiles with no dependency on the event
      vocabulary that arrives in Task 3
- [x] create `cue/Diagnostics/DiagnosticsSafeFields.swift` — opaque
      `DiagnosticsHost` and `DiagnosticsGUID` types whose only initialisers
      sanitise: the host built through `redactedAddress(_:)`, the guid as a
      truncated SHA-256 digest over UTF-8. A raw `String` must not be usable where
      either is expected
- [x] create `cue/Diagnostics/DiagnosticsSink.swift` — a `Sendable` protocol with
      a non-throwing `record(_:)`, an async `flush()`, and a no-op implementation
      used as the default everywhere
- [x] define the export capability **here, before anything needs it**: a separate
      `DiagnosticsSnapshotSource` abstraction returning the serialized contents of
      both generations. The Downloads view cannot get a snapshot by downcasting
      the sink, and widening `DiagnosticsSink` would force every conformance —
      including the no-op — to answer a question it has no business answering
- [x] create `cue/Diagnostics/DiagnosticsLine.swift` — a pure formatter taking an
      **explicit timestamp** plus level, category, event and ordered fields,
      escaping every control character, the field delimiter and `=` reversibly
- [x] create `cue/Diagnostics/DiagnosticsFileWriter.swift` implementing the sink
      over a **single serial executor that owns the file handle**: append, flush,
      close/reopen, rotation and snapshot all run on it, so rotation cannot race a
      held handle and no write blocks the main actor or the delegate queue
- [x] **make `record(_:)` a fence, not merely serialized.** It must synchronously
      enqueue into the writer's ordered mailbox before returning, and `flush()`
      must wait behind every prior enqueue. A serial executor alone does not give
      this: if `record` hands off by launching an unstructured task, a following
      `flush()` can reach the executor first and the delivery barrier fires before
      the terminal record is appended — silently losing the one record the whole
      step exists to capture
- [x] write a test that a `record(_:)` immediately followed by `await flush()`
      always yields a snapshot containing that record, exercised under
      contention
- [x] rotate at 1 MB keeping one previous generation, take an injectable base
      directory, and degrade a write failure to `os_log` rather than throwing
- [x] write tests for the formatter: field order, and adversarial values
      containing newlines, tabs, control characters, `=` and the delimiter
- [x] write tests proving `DiagnosticsGUID` is deterministic across constructions
      and that a guid whose secret starts at byte zero cannot be reconstructed
- [x] write tests for `DiagnosticsHost` dropping path, query and userinfo
- [x] write tests for rotation against a temporary directory: crossing the cap
      rotates, the previous generation survives, a third is discarded
- [x] write a test that a writer whose directory is unwritable still returns
      normally
- [x] run `just build` and `just test` — must pass before next task

### Task 3: Inject the sink and instrument the download and feed paths

- [x] define the event vocabulary in `cue/Diagnostics/DiagnosticsEvent.swift`,
      every case taking `DiagnosticsHost` / `DiagnosticsGUID` and scalars — **no
      case may accept a URL, an arbitrary host `String`, or an `Error`
      description**
- [x] add a sink parameter defaulting to the no-op to `DownloadManager` and
      `FeedService`
- [x] reach `FeedService`'s three view call sites (`AddFeedView.swift:77`,
      `PodcastDetailView.swift:172`, `LibraryView.swift:54`) with a SwiftUI
      environment value carrying the sink, set once by `CueApp`; the service stays
      a cheap struct constructed at the call site
- [x] **route background-delegate logging through the handlers `DownloadManager`
      already installs on `BackgroundDownloader`** (`registerCompletionRoute(with:)`)
      rather than storing a sink on the downloader — this avoids depending on
      undocumented initialisation order for `BackgroundDownloader.shared` and
      keeps its file below the cap
- [x] record launch once from `CueApp.init()` with the build identifier
- [x] instrument `DownloadManager` (requested, queued, started, cancelled,
      deleted), `DownloadFinish` (file moved, finished), `DownloadRelaunch`
      (adopted, failed) and the delegate (first byte, decile crossings)
- [x] **scope first-byte and decile events explicitly to registered live
      attempts**, and say so in the code. A progress callback has no equivalent of
      the completion queue: one arriving before the handler is installed is
      discarded (`BackgroundDownloader.swift:94,162`), and one arriving before
      `adopt` creates the attempt is rejected by `handleProgress`. The contract is
      therefore **exactly the reports `handleProgress` accepts before the attempt
      retires** — not "every byte", since progress arrives on separate unstructured
      main-actor tasks that can land after retirement and be rejected. On the
      relaunch path an adopted transfer's early progress is not logged at all.
      Both are accepted gaps, recorded here rather than papered over with
      buffering that would add a second delivery queue. Terminal records are not
      best-effort; progress records are
- [x] move the terminal `deliveryBarrier()` / `completeDeliveredWork()` calls out
      of `defer` on both routes so they fire **after** failure-state and log
      handling, preceded by `await sink.flush()`, as one-shots that cannot
      double-fire or be skipped (decision 8)
- [x] **arm that one-shot only once `delivered` has been formed**
      (`DownloadManager.swift:192` onward), as a single linear post-delivery
      epilogue — not from the outer `catch`, which also catches pre-transport
      exits like a cancelled queue wait or a failed `prepareEpisodesDirectory()`.
      Decrementing the accounting for a delivery that never happened can drive
      another delivery's count to zero and answer UIKit early, which is the exact
      mid-finish suspension the accounting exists to prevent
- [x] write tests that **every pre-transport exit calls the barrier zero times**
      and every post-delivery exit calls it exactly once
- [x] write tests that the UIKit handler is answered exactly once, is not answered
      early, and is still answered when the flush fails
- [x] define decile logging precisely: a per-attempt record of the highest decile
      already logged, so repeated callbacks log once, a multi-decile jump logs only
      the newly reached bucket, an unknown total logs none, and the record is
      dropped when the attempt retires
- [x] give each attempt a correlation identifier derived from its existing token —
      not an ordinal counter, which does not exist, and not the task identifier,
      which iOS may reuse
- [x] instrument `FeedService.fetch` and its failure path with host, status and
      elapsed milliseconds
- [x] use the categories that exist — `downloads` and `storage` — rather than
      inventing names
- [x] put this task's tests in a **new `cueTests/DownloadDiagnosticsTests.swift`**
      rather than the existing suites — `DownloadManagerTests.swift` is 384 lines
      and `DownloadManagerRelaunchTests.swift` 363, and Task 6 splits only the
      progress suite
- [x] write tests with a recording in-memory sink asserting each event's exact
      field set
- [x] write tests for decile bucketing: repeated callbacks, a multi-bucket jump,
      an unknown total, and retirement
- [x] write a test that a `httpStatus` record carries status and hashed guid and
      no address beyond scheme and host
- [x] run `just build` and `just test` — must pass before next task

➕ The event vocabulary needed two more safe field types than the plan named —
      `DiagnosticsAttemptID` (the attempt correlation identifier, derived from
      the ownership token) and `DiagnosticsErrorCode` (a bridged `NSError`
      domain, sanitised, plus its code) — so a case can carry an error without
      accepting one. Both live in `DiagnosticsSafeFields.swift` beside
      `DiagnosticsHost` and `DiagnosticsGUID`.
➕ The task's tests landed in three new files rather than one:
      `cueTests/DownloadDiagnosticsTests.swift` (vocabulary, deciles, the
      recorded arc), `cueTests/DownloadDeliveryBarrierTests.swift` (the barrier
      and the UIKit handler) and `cueTests/FeedDiagnosticsTests.swift`, plus the
      shared `cueTests/RecordingDiagnosticsSink.swift` double. One file would
      have passed the 400-line `file_length` cap.
➕ `DownloadManager`'s post-delivery epilogue and the decile policy live in a new
      `cue/Download/DownloadDiagnostics.swift`, for the same headroom reason as
      the Task 1 splits.

### Task 4: Tell the truth about download failures

Scope is **download** failures only. The feed mapper changes in Task 12, where
its callers change anyway.

- [x] split `is URLError` in `downloadErrorMessage(for:)` into timed out,
      connection lost or unreachable, cannot write or move the file, and
      everything else keeping today's fixed sentence
- [x] keep cancellation returning `nil` and the unknown-error fallback fixed
      rather than a passed-through description
- [x] record domain and code through the sink at the download failure sites
      instrumented in Task 3 — **explicitly not** the storage-scan, delete,
      played-save or export catches (`DownloadsView.swift:202,210`,
      `PodcastDetailView.swift:127,145`), which stay uninstrumented in this step
      and are listed here so the omission is deliberate rather than forgotten
- [x] write tests covering each new `URLError` branch and that `.cancelled` still
      maps to `nil`
- [x] write a test pinning that no branch returns a raw `localizedDescription`
- [x] run `just build` and `just test` — must pass before next task


➕ The reachability branch covers `.networkConnectionLost`,
      `.notConnectedToInternet`, `.cannotConnectToHost`, `.cannotFindHost`,
      `.dnsLookupFailed`, `.internationalRoamingOff`, `.dataNotAllowed` and
      `.secureConnectionFailed`; the storage branch covers the six
      `cannot*File` codes. Everything else — `.badServerResponse` among them —
      keeps the original sentence rather than a guess.
➕ The third item needed no code: Task 3's `recordTerminalFailure` already
      writes `DiagnosticsErrorCode(error)` (domain plus code) on both the
      transport and the relaunch routes, and the catches this item lists as
      deliberately uninstrumented remain so.

### Task 5: Export the diagnostics file

- [x] add `INFOPLIST_KEY_LSSupportsOpeningDocumentsInPlace = YES` to
      `Config/App.xcconfig` — **verified to exist** in the installed Xcode
      specification, so per `App.xcconfig:3-4` it belongs there, not in the plist
- [x] add `UIFileSharingEnabled` to `cue/Support/Info.plist`, which has **no**
      `INFOPLIST_KEY_` equivalent, taking the partial plist to three keys, and say
      so in its comment
- [x] add `cue/Diagnostics/DiagnosticsExport.swift` assembling the export as a
      pure function over supplied text: header (build, device model, iOS version,
      timestamp) then the rotated generation then the current one
- [x] read both generations through the `DiagnosticsSnapshotSource` defined in
      Task 2 — injected alongside the sink, backed by the same production writer,
      never obtained by downcasting the sink
- [x] take an **injected destination directory** so no test writes to real
      Documents, `await` the writer's `flush()` first, and replace the previous
      export rather than accumulating one file per tap
- [x] define an empty log as a header-only success, not an error
- [x] add an *Export Diagnostics* toolbar item to the Downloads tab presenting a
      share sheet, surfacing failure through the existing `errorAlert`
- [x] write tests for the assembly: header present, both generations in order, a
      missing rotated generation is not an error, an empty log yields the header
- [x] write a test that a second export replaces the first
- [x] write a hosted-bundle assertion that both new settings reach the built
      product, following the existing ATS plist assertion precedent
- [x] run `just build` and `just test` — must pass before next task

➕ The export button lives in its own `cue/Views/DiagnosticsExportButton.swift`
      (with the `UIActivityViewController` representable and the `Identifiable`
      URL wrapper `sheet(item:)` needs) rather than as more state on the
      228-line `DownloadsView`, which only gains a three-line toolbar item.
➕ `buildIdentifier` moved from `CueApp` to `DiagnosticsExport`, since the
      export header is the other thing that stamps it; `CueApp` now calls
      `DiagnosticsExport.buildIdentifier` for the launch record.
➕ The snapshot source reaches the view through a second environment entry,
      `\.diagnosticsSnapshots`, defaulting to a new
      `EmptyDiagnosticsSnapshotSource` — so a preview or a view under test
      offers an export that succeeds and contains nothing, the same rule the
      no-op sink follows.
➕ The device model is the `utsname` hardware identifier rather than
      `UIDevice.model`, which answers "iPhone" for every iPhone and so cannot
      say which device a bug was seen on.

### Task 6: Split the progress test suite before it grows

- [x] split `cueTests/DownloadManagerProgressTests.swift` (394 lines, six from the
      cap) into balanced topic files, following the existing relaunch and duration
      split precedent
- [x] change no assertions and no production code — a pure move
- [x] run `just build` and `just test` — must pass before next task

### Task 7: Phase model, part one — queued and connecting

Split from Task 8 at the only seam that is genuinely forced: an enum case and its
exhaustive switches must land together, but temporal behaviour need not.

- [x] replace `DownloadProgress.waiting` with distinct queued and connecting
      phases, carrying queue position on the queued phase
- [x] carry **expected total bytes** on the moving phase — the current
      `.fraction(bytesWritten:value:)` clamps its ratio, so "X of Y" cannot be
      reconstructed from it at zero or after over-delivery
- [x] update every source reference in this commit: `DownloadAttempts.swift:34`,
      `DownloadProgress.swift`, `DownloadRelaunch.swift:83,123`,
      `DownloadManager.swift:190`, and the exhaustive switches at
      `PodcastDetailView.swift:245` and the active-row switch **now living in
      `cue/Views/DownloadRows.swift`** after Task 1 — rendering may stay minimal
      here; Task 9 makes it good
- [x] leave `BackgroundDownloader.swift:287,317` alone — a different enum
- [x] derive queue position from `DownloadQueue`'s FIFO array, recomputed when the
      array changes, and publish a reindex immediately
- [x] migrate the six test files that reference `.waiting` in this same commit
- [x] update `episodeDownloadState(localFilename:transfer:)` and
      `downloadAction(for:)` for the new phases
- [x] write tests for queued → connecting → downloading and for position
      derivation and reindexing
- [x] run `just build` and `just test` — must pass before next task

### Task 8: Phase model, part two — stalled, finalizing, rate and throttle

- [x] add a stalled phase and a **finalizing** phase, the latter published on both
      the live and relaunch success paths before `finishDownload` runs, so the
      window between the last byte and the file landing is visible rather than
      showing as ordinary 100%
- [x] record a monotonic last-increase timestamp on the attempt, updated **only on
      a strict byte increase** — `DownloadAttempts.swift:74-79` accepts equal
      counts, so refreshing on every accepted report would postpone stalling
      forever
- [x] publish stalled as an **actual state write** from an attempt-scoped deadline
      — deriving it on read cannot work, because elapsed time invalidates nothing
      and `DownloadsView.swift:59-67` reads `states` directly
- [x] guard the deadline with **both the attempt token and a deadline generation**:
      a rescheduled deadline shares its predecessor's token, so token alone lets a
      stale task mark fresh progress stalled
- [x] compute a smoothed rate over a **5-second trailing window** with a bounded
      sample count, a minimum time delta to avoid division by zero, and a defined
      bucket granularity for render comparison; carry the published rate on the
      phase rather than recomputing it in the view
- [x] redefine `rendersDifferently(from:)` over **every displayed field** — phase,
      whole percent, byte count, expected total and rate bucket — since it
      currently answers `false` for two `.indeterminate` values whose bytes differ
- [x] update the two exhaustive switches — `PodcastDetailView.swift:245` and the
      active-row switch in `cue/Views/DownloadRows.swift` — plus
      `DownloadProgress`'s own internal switches, with temporary minimal rendering
      for the two new phases **in this commit**, so it builds independently;
      Task 9 replaces that rendering
- [x] throttle repeated byte/rate publications to at most once per second **with
      trailing delivery**; keep **one pending publication per attempt**, carrying
      its **own publication generation that every lifecycle transition
      invalidates**. Matching on "still downloading" is not enough — stalled and
      finalizing are downloading states, so a publication that has already passed
      its sleep would overwrite either of them. Require the generation, the guid,
      the token and an *actively moving* phase when it fires, and cancel it inside
      a successful `releaseOwnership`
- [x] exempt lifecycle transitions from the throttle — queued→connecting, reindex,
      stalled, finalizing and terminal states publish immediately and cancel any
      incompatible pending progress
- [x] inject a clock so all of this is tested without sleeping
- [x] write tests for stalled → resumed, for equal-byte reports not deferring the
      deadline, and for a stale deadline generation being ignored
- [x] write tests for the rate window: pruning, zero elapsed time, a stall, and a
      resumed transfer
- [x] write tests that a trailing publish is cancelled at retirement, and that a
      delayed one delivered **after a stalled transition and after a finalizing
      transition** is discarded rather than overwriting either
- [x] write a test that indeterminate byte updates now reach the row
- [x] run `just build` and `just test` — must pass before next task

### Task 9: Show that vocabulary in both download surfaces

- [x] add `transferStatusText(_:)` to `cue/Views/ActiveDownloadFormatting.swift`
      producing the full line — queued with its position worded without an ordinal,
      connecting, bytes of total with percent and rate, finalizing, and stalled
      with **fixed wording** ("no data for 30s or more") rather than a counting
      duration: the stalled phase is one state write, and nothing invalidates the
      row again while it holds, so a live-looking counter would freeze
- [x] add a compact variant for the podcast-detail row: small bar plus percent,
      and bytes with a spinner when the total is unknown
- [x] render the full line in the active row and the compact one in the episode row
- [x] give the failure label an explicit line limit
- [x] write tests for `transferStatusText` across every phase including unknown
      total, zero bytes, stalled and finalizing
- [x] write tests for byte and rate formatting matching `diskUsageText`'s
      file-style units
- [x] run `just build` and `just test` — must pass before next task

### Task 10: Per-episode size, plumbed before anything needs it

- [x] carry the per-episode byte count the Downloads scan already measures through
      to the row rather than only into the group and total sums
- [x] render it alongside date and duration, showing nothing rather than a zero
      when the size could not be measured
- [x] expose one call answering an episode's size on demand through
      `EpisodeStore.fileSize`, propagating a storage error rather than reporting
      zero — the podcast-detail screen has no measured size and Task 11's
      confirmation needs one there
- [x] write tests for the subtitle assembly with and without a known size
- [x] write a test that a storage error propagates rather than becoming a zero
- [x] run `just build` and `just test` — must pass before next task

### Task 11: Make the row indicator a control

- [x] add `cue/Views/DownloadIndicatorActivation.swift` — a policy free function
      answering what an **indicator tap** does, separately from
      `downloadAction(for:)`, which maps `.failed` to `.download`
- [x] make the indicator a button in every phase, keeping failed as show-detail
- [x] **give the failure alert an explicit Retry action** beside OK, so retry is
      reachable from the indicator without being accidental
- [x] confirm a delete triggered by tap, naming the episode and its size from
      Task 10; leave the swipe delete immediate
- [x] apply the same control to the Downloads tab
- [x] leave the row's own tap gesture unbound — step 5 claims it
- [x] give each phase an explicit accessibility label, hint and value, and a
      practical minimum tap target
- [x] write tests for the activation policy across every phase, including that
      failed activates detail rather than retry
- [x] write tests for the confirmation message assembly and the per-phase
      accessibility text
- [x] run `just build` and `just test` — must pass before next task

### Task 12: Refresh that answers quickly and says what it is doing

- [x] set `request.timeoutInterval = 20` in `FeedService.feedRequest(for:)`,
      keeping the revalidating policy, asserting both — documented as an **idle**
      timeout, which is what Apple defines it as
- [x] add `cue/Views/FeedRefreshStatus.swift` with the status vocabulary as free
      functions plus a small cancellable clock-driven model — a formatting function
      alone cannot produce the five-second "still waiting" transition
- [x] give `refreshAll(_:using:)` a **progress callback** reporting the feed about
      to be fetched and its index, and return a summary of refreshed count, failed
      count and a **structured first failure carrying both the unchanged `Error`
      and its safe host**
- [x] add the host parameter to `feedErrorMessage` and `reportableFeedErrorMessage`
      and **migrate all callers in this same commit** —
      `AddFeedView.swift:82`, `PodcastDetailView.swift:177`, `LibraryView.swift:55`
      and `FeedErrorMessageTests` — so the checkpoint stays green
- [x] show the status on both `LibraryView` and `PodcastDetailView` while a
      refresh runs, and report a partial sweep with both counts
- [x] write tests for the status model over an injected clock, including the
      five-second transition and cancellation
- [x] write tests for the sweep summary: all-fail, partial, and a cancellation not
      counted as a failure
- [x] run `just build` and `just test` — must pass before next task

### Task 13: Repair the add-feed sheet

- [x] replace the URL-shaped placeholder with plain descriptive text and move the
      example into the section footer as help text
- [x] focus the field and raise the keyboard on appear, add a clear button while
      there is text, and make the return key submit
- [x] add `cue/Views/FeedPasteOffer.swift` deciding from
      `UIPasteboard.detectPatterns(for:)` whether to offer paste — that call does
      not prompt; a detection failure means no offer
- [x] on tap, read the clipboard, allowing iOS to present its permission UI when
      it chooses to, **revalidate the value** (the clipboard can change between
      detection and read) and pass it through `normalisedFeedAddress(_:)`
- [x] leave the inline error presentation as it is
- [x] write tests for the paste-offer decision including detection failure and a
      clipboard with no URL
- [x] write tests that a pasted address is normalised exactly as a typed one and
      that an inner token survives byte for byte
- [x] run `just build` and `just test` — must pass before next task

### Task 14: Verify acceptance criteria

- [x] verify every **instrumented** failure path records domain and code, and that
      no recorded line in any test output contains a path, query, userinfo or an
      unhashed guid
- [x] verify all six phases are reachable and that both download screens answer a
      row with the **same semantic phase and action** — their presentation differs
      by design, full line versus compact, which is not a defect
- [x] verify a feed request carries the 20 s idle timeout and the revalidating
      policy, and that a sweep reports partial success with a host — the timeout
      was unpinned, so `theProductionRequestRevalidatesTimesOutAndKeepsTheURLVerbatim`
      now asserts it
- [x] verify the indicator activation policy differs from `downloadAction` only
      where intended, and that only the tap path confirms a delete
- [x] verify the export contains its header and both generations and that a second
      export replaces the first
- [x] verify no source or test file exceeds 400 lines
- [x] run the full test suite — must pass
- [x] run `just lint` and `just format-check` — all issues fixed
- [x] run `gitleaks detect --no-git` — must be clean

### Task 15: [Final] Update documentation

- [x] add a ROADMAP entry for step 4.6 describing goal, files and acceptance,
      inserted after 4.5 the way 4.5 itself was
- [x] add the diagnostics conventions to `AGENTS.md`: the sink is injected with a
      no-op default, host and guid are opaque sanitising types, the guid is a
      truncated SHA-256 digest, logging never throws, the delivery barrier fires
      after logging and awaits a flush but must complete even when the flush
      fails, snapshot is a separate capability from the sink, and the plist now
      carries three keys with the fourth setting in `App.xcconfig`
- [x] record the phase vocabulary, the lifecycle-exempt trailing throttle, the
      deadline generation guard and the injected clock beside the existing
      progress-throttle rule
- [x] record the indicator activation policy as distinct from `downloadAction`
- [x] **correct `AGENTS.md`'s stale claim** that
      `DownloadManagerRelaunchTests.swift` sits at exactly 400 lines
- [x] note in `docs/SECRETS.md` that an exported diagnostics file is shareable
      output, and what it may and may not contain
- [x] record the English-only decision so it is not rediscovered as drift
- [x] update `README.md` if the export is worth naming there

## Technical Details

**Log line shape.** One line, fixed field order, every control character and
delimiter escaped reversibly:

As shipped (`\t` marks a literal tab, `DiagnosticsLine.fieldDelimiter`):

```text
ts=2026-08-27T14:03:11.412Z\tlevel=error\tcategory=downloads\tevent=download.failed\tguid=a3f19c2b1d4e5f60\tattempt=7f2c9a1b3d4e\tdomain=NSURLErrorDomain\tcode=-1005
```

Every field is keyed, `ts`, `level` and `category` included; the level is the
full word and the event is the dotted name from `DiagnosticsEvent.name`.
Category is one that exists in the tree. `guid` is a truncated SHA-256 digest;
`attempt` is derived from the attempt token, not an ordinal and not the reusable
task identifier.

**Rotation and durability.** One serial executor owns the handle; rotation moves
the current file aside and reopens on that executor. `flush()` is awaited by the
export **and by both background-delivery routes**, which now call their one-shot
barrier after failure handling rather than from `defer` — the terminal records
are the whole point of the log, and `defer` fired before the failure was even
written (decision 8). A flush failure still completes delivery.

**Stall detection.** The attempt gains a monotonic last-increase timestamp,
updated only on a strict byte increase. A deadline task scoped to the attempt and
tagged with a generation writes the stalled phase into the observed map.

**Throttle.** Repeated byte/rate publications: at most once per second with one
pending trailing publication per attempt. When it fires it must match its own
publication generation — invalidated by *every* lifecycle transition — plus the
guid, the token, and an actively moving phase; "still downloading" is not enough,
since stalled and finalizing are downloading states. Cancelled at retirement.
Lifecycle transitions bypass the throttle entirely.

**Nothing here touches the schema.** No new SwiftData model, no new column.

## Post-Completion

*Items requiring manual intervention or external systems — no checkboxes.*

**Ordering, by owner decision:** built, then **tested on device before any PR is
opened**. Fixes found in that session land on top of this work, and the PR opens
only once the owner is satisfied. A deliberate departure from the usual
finalize-then-publish flow.

**Blocking prerequisite:** the signing-service round-trip has never been done end
to end. The build is unsigned by design; getting it onto the phone gates
everything below.

**Device session — the point of this step:**

- Reproduce the 100 %-then-fail download on both feeds, export the log, read the
  actual domain and code, and check whether the failure lands in the finalizing
  phase or before it. That is the question this step exists to answer.
- Confirm the phases are distinguishable: queue two downloads and check the
  waiting one says it is queued and the connecting one says it is connecting.
- Kill the network mid-transfer and confirm the row reaches stalled after 30 s
  and still cancels.
- Refresh with the VPN off and confirm the failure arrives in about 20 s naming
  the host, instead of a silent minute.
- Confirm the export is retrievable through the share sheet **and** in the Files
  app — the Files location is what Apple's documentation does not guarantee from
  the settings alone.
- Confirm the terminal records actually survive a background finish: the barrier
  now flushes before answering UIKit (decision 8), but whether that holds under
  real suspension and file protection is a device question.
- Confirm the paste permission dialog behaviour; iOS controls it and prior user
  choices affect it, so it is observed, not asserted.
- Judge the transfer line, tap targets, truncation and Dynamic Type as a user.

**Still unresolved after this step:**

- The duplicate-subscription bug — needs the two exact URLs that were pasted.
- Unsubscribe — its own step, with the cascade decision.
- `URLSessionTask.taskIdentifier` reuse across a recreated background session —
  still needs an instrumented probe, which this step's log makes far easier.
- Whether the writer stays durable while the phone is locked and iOS suspends a
  background-relaunched process, including file-protection behaviour.
- The storage-scan, delete, played-save and export catches remain uninstrumented.
- An adopted transfer's progress before `adopt` registers its attempt is not
  logged; only its terminal outcome is. Accepted in Task 3 rather than solved
  with a second delivery queue.
