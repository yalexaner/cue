# Append-only playback session log (roadmap step 6)

## Overview

Step 6 records every listening session so no playback position is ever
destroyed — the feature the app exists for (spec §1, §9). It adds:

- `Playback/SessionEvent.swift` — a small value type the engine emits at every
  session boundary, keeping the engine SwiftData-free.
- `Playback/SessionRecorder.swift` — a cheap `@MainActor` struct over a
  `ModelContext` that maps events to `PlaybackSession` writes: open on start,
  close on stop, close-and-reopen on manual seek and rate change, heartbeat
  `endPosition` writes, and the launch sweep that closes abandoned sessions.
- `PlaybackEngine` integration — event emissions at the existing transition
  sites, a dedicated 10 s heartbeat observer, and the `CueApp` wiring.

Acceptance (spec AC 5, AC 6, AC 12): play/pause/play/pause yields two sessions
with contiguous positions; a manual seek preserves the pre-seek session's end
and opens a new session at the target; a force-quit mid-playback leaves the
position at most 10 s behind and no live session after relaunch.

This step ships no UI — step 7 (History) is the user-facing half.

## Decisions (settled in planning — do not re-litigate)

1. **Commit message is scoped**: `feat(playback): add append-only session log`.
   The roadmap's scopeless `feat: append-only playback session log` is overridden
   the same way steps 4, 4.5 and 5 overrode theirs (step-5 plan decision 11).
2. **The engine stays SwiftData-free.** It emits `SessionEvent` values through an
   injected `@ObservationIgnored var sessionEvents: ((SessionEvent) -> Void)?`
   seam — the `nowPlayingController` / `prepareForFileMutation` precedent for
   wiring long-lived services without a direct dependency. `CueApp` wires it to a
   `SessionRecorder`; tests wire a recording closure and assert emissions with no
   SwiftData in sight.
3. **`SessionRecorder` is a cheap struct, not a third long-lived service.**
   AGENTS.md is explicit that `DownloadManager` and `PlaybackEngine` are not a
   precedent. The recorder holds a `ModelContext` and no other state: the live
   session is always re-found by fetching `endedAt == nil`, which is also what
   makes "never more than one live session" enforceable at every write.
4. **One open site, one close helper.** `startLoadedPlayback()` is the only
   transition that sets `isPlaying = true`, so it is the only place a session
   opens (`startPosition = elapsed`, `rate` at open). Eight sites set
   `isPlaying = false`; they are funnelled through one private engine helper that
   sets the flag and emits `.stopped(position: elapsed)` only on a true→false
   transition, so already-stopped paths stay no-ops and no site can be missed.
5. **Interruptions, route loss, item/player/remote failures close the session.**
   Spec §9's table names pause, manual seek, episode switch, rate change, end of
   file and termination; it is silent on the other stop sites. They all end
   audible playback, which is what a session measures — and falling asleep into
   an alarm must not orphan a live session. The close funnel (decision 4) makes
   this the default rather than six special cases.
6. **The manual-seek boundary is `seek(to:)` / `skip(by:)`**
   (`PlaybackSeeking.swift`), never `seekPlayer(to:)`, which also serves load
   resume, restart and duration reclamping. A manual seek while a session is
   live closes it at the pre-seek `elapsed` and opens a new one at the clamped
   target immediately (spec §9's note — this is what makes revert work). A
   manual seek while paused touches no session: none is live, and the next
   open reads the moved `elapsed` as its `startPosition`.
7. **Rate change closes and reopens only on an actual change while live.**
   `setRate(_:)` has no same-value guard, so the emission compares
   `newRate != rate` before firing. When paused, nothing is live: the new rate
   is simply what the next open records (spec: "keeps `rate` meaningful per
   session").
8. **The heartbeat is its own 10 s `addPeriodicTimeObserver`.** Spec §9 and the
   roadmap name the API and the interval; step-5 decision 8 deliberately kept it
   out of the 0.5 s UI observer. It installs and tears down with the existing
   observer machinery, is generation-guarded like every other callback, and
   funnels through an internal `handleHeartbeat` seam so tests can drive it
   without media.
9. **No termination observer.** Spec §9 closes a terminated session "via the
   last heartbeat write" — the 10 s heartbeat plus the launch sweep *is* the
   mechanism, and AC 12's "at most 10 seconds behind" is exactly that tolerance.
   `AppDelegate`'s doc comment says nothing else about the lifecycle belongs
   there; this step honours it.
10. **The launch sweep runs in `CueApp.init()`**, right after the container is
    built — a background launch for a download delivery may never present a
    scene, so a scene `.task` is the wrong home. The sweep closes *every*
    session with `endedAt == nil` (defensive plural), setting
    `endedAt = startedAt + max(0, (endPosition - startPosition) / rate)` — the
    best wall-clock estimate derivable from the recorded fields. No new column:
    the schema has no modification timestamp, and adding one is schema churn
    that CodeRabbit's stored-position invariant would rightly interrogate.
    A sweep failure is logged and non-fatal, the `prepareEpisodesDirectory()`
    precedent.
11. **Recorder writes save explicitly and never throw into playback.** AC 12's
    10-second bound cannot lean on autosave timing, and `mainContext` pending
    writes sit in reach of `FeedService`'s context-wide `rollback()` — the
    `setPlayed` save-at-mutation precedent. Every recorder operation ends in
    `context.save()`; a failed open deletes the just-inserted session
    (`add`'s `allEpisodesOwnedElsewhere` precedent, not `rollback()`); failures
    are logged under a `playback` category with no URL and playback continues —
    a session-log write must never stop audio.
12. **Episode resolution is fetch-by-guid with an injectable lookup seam**, the
    `DownloadFinish.episode(forGUID:)` precedent — a `ModelContext` cannot be
    made to throw on demand, so the seam is what makes failure paths testable.
    A missing episode at open logs and records nothing.
13. **Defensive double-open closes first.** If open finds a live session (a bug,
    not a plan), it closes it with its current heartbeat data before inserting —
    "never leave more than one live session" is enforced at the write, not
    assumed from call ordering.
14. **`PlaybackEngine.swift` makes room by relocating the audio-session
    handlers.** The file is at 398 of the 400-line `file_length` limit that
    `just lint --strict` fails on. The interruption / route-change /
    remote-failure handlers move to a new `Playback/PlaybackAudioSession.swift`
    extension (the `PlaybackSeeking.swift` precedent) before any emission is
    added. `cueTests/PlaybackEngineTests.swift` (383 lines) gets no new tests —
    session-emission tests live in their own suite.

## Context (from discovery)

Research artifact: `/tmp/cue-step6-scratch/step6-research.md` (2026-08-22
session artifact).

- `PlaybackSession` model (`cue/Models/PlaybackSession.swift`): six fields, no
  `#Unique`; `endedAt` and `episode` are assigned post-init. Already present in
  **both** schema lists (`CueApp.swift:41`, `cueTests/InMemoryContainer.swift:20`)
  — no schema change needed.
- `Episode.currentPosition` (`cue/Models/Episode.swift:51-55`) derives from
  `sessions.max` on `(startedAt, endPosition)` and ignores `endedAt` — a live
  session's heartbeat is already the resume mechanism; step 5 wired
  `requestedResumePosition = episode.currentPosition` at load.
- Open funnel: `startLoadedPlayback()` (`PlaybackEngine.swift:216-228`) is the
  only site setting `isPlaying = true`; guarded `!isPlaying`, so reuse, restart
  and reload all pass through it exactly once per start.
- Close sites (eight, `isPlaying = false`): `pause()` (:100), `unload(ifGUID:)`
  (:151), `load` (:192), `publishLoadFailure` (:319), `handleItemEnded` (:329),
  `handleAudioSessionInterruption` (:366), `handleAudioRouteChange` (:377),
  `handleRemotePlaybackFailure` (:384).
- Seek split: `seek(to:)` / `skip(by:)` (`PlaybackSeeking.swift:6,14`) are
  user-initiated; `seekPlayer(to:)` (:239) also serves internal resume/restart/
  reclamp and must not emit.
- The existing periodic observer runs at 0.5 s (`PlaybackObservers.swift:40-47`)
  and is UI machinery; `handlePeriodicTime` is the internal seam pattern to
  copy for the heartbeat.
- Generation guards: every async callback captures `loadGeneration` at install
  and checks it on entry; the heartbeat observer must do the same.
- Context wiring precedent: `CueApp.init()` builds the container, constructs
  `PlaybackEngine` first, then hands `container.mainContext` to
  `DownloadManager` alongside injected closures (`CueApp.swift:41-54`).
- Test conventions: engine tests drive internal `handle*` seams directly with a
  real `AVPlayer` over rejected non-audio bytes (`withLoadedEngine`,
  `installRejectedAudio`); model tests use the shared `makeContext()`;
  persistence asserts through a second `ModelContext`; `yieldUntil(_:)` is the
  only sanctioned wait.
- Lint traps: `file_length` 400 warning fails `--strict`
  (`PlaybackEngine.swift` at 398, `PlaybackEngineTests.swift` at 383);
  multiline collection literals cannot pass both formatters — keep them
  single-line.

## Development Approach

- **Testing policy**: per task, code first
- **Verification policy**: per task (`just build` + `just test` green before
  the next task)
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
  - AVPlayer/MediaPlayer/audio-session *wiring* is build-only by convention —
    its policy inputs and the internal callback seams are what gets asserted
- **CRITICAL: all tests must pass before starting next task** - no exceptions
- **CRITICAL: update this plan file when scope changes during implementation**
- Run tests after each change
- Maintain backward compatibility

## Testing Strategy

- **Unit tests**: required for every task (see Development Approach above).
- Engine emission tests wire a recording closure into `sessionEvents` and drive
  the public methods plus the internal `handle*` seams — no SwiftData, no
  media fixtures.
- Recorder tests build a fresh in-memory container via the shared
  `makeContext()`, feed events directly, and assert rows; committed state is
  asserted through a second `ModelContext(container)`, pending state on the
  primary.
- The launch sweep is a plain function over a context — tested directly with
  crafted live/closed session rows.
- One cross-service suite (the `DownloadManagerPlaybackTests` precedent) plays a
  real engine over rejected audio wired to a real recorder and asserts the AC 5
  and AC 6 row shapes end to end.
- Failure paths use the injectable episode-lookup seam
  (`DownloadFinish` precedent) — a `ModelContext` cannot be made to throw on
  demand.
- **E2E tests**: none exist in this project.

## Progress Tracking

- Mark completed items with `[x]` immediately when done
- Add newly discovered tasks with ➕ prefix
- Document issues/blockers with ⚠️ prefix
- Update plan if implementation deviates from original scope
- Keep plan in sync with actual work done

## What Goes Where

- **Implementation Steps** (`[ ]` checkboxes): code, tests, docs achievable in
  this codebase
- **Post-Completion** (no checkboxes): device acceptance and external checks
- **Checkbox placement**: checkboxes only in Task sections

## Implementation Steps

### Task 1: Session events from the engine

- [x] create `cue/Playback/SessionEvent.swift`: a `SessionEvent` enum —
      `started(guid: String, position: TimeInterval, rate: Double)`,
      `stopped(position: TimeInterval)`,
      `seeked(from: TimeInterval, to: TimeInterval)`,
      `rateChanged(position: TimeInterval, newRate: Double)`,
      `heartbeat(position: TimeInterval)` — `Equatable`, no SwiftData import
- [x] relocate `handleAudioSessionInterruption` and `handleAudioRouteChange`
      from `PlaybackEngine.swift` into a new
      `cue/Playback/PlaybackAudioSession.swift` extension, unchanged, to clear
      the 400-line ceiling before emissions are added
      - ⚠️ deviation: `handleRemotePlaybackFailure` stayed in
        `PlaybackEngine.swift`. It is the only one of the three that writes
        `playbackError`, whose `private(set)` setter is file-scoped, so moving
        it would have meant widening that setter module-wide. The ceiling was
        cleared instead by splitting `PlaybackEngine.Failure` into
        `cue/Playback/PlaybackFailure.swift` and moving `restartLoadedItem()`
        to `PlaybackSeeking.swift` (394 lines).
      - ⚠️ deviation: the event is `.seeked(from:target:)`, not
        `.seeked(from:to:)` — SwiftLint's `identifier_name` rejects a
        two-character label.
- [x] add `@ObservationIgnored var sessionEvents: ((SessionEvent) -> Void)?` to
      the engine; emit `.started` at the end of `startLoadedPlayback()`
- [x] funnel every `isPlaying = false` site through one private helper that
      emits `.stopped(position: elapsed)` only on a true→false transition;
      in `handleItemEnded`, stop after `elapsed` is set to the duration so the
      close carries the end position
- [x] emit `.seeked(from:to:)` from `seek(to:)` for the clamped target when a
      session is live (`isPlaying`), before `seekPlayer(to:)` runs; `skip(by:)`
      inherits it; internal `seekPlayer` callers emit nothing
- [x] emit `.rateChanged` from `setRate(_:)` only when the accepted value
      differs from the current rate and `isPlaying`
- [x] install a second `addPeriodicTimeObserver` at 10 s in
      `PlaybackObservers.swift`, generation-guarded, torn down alongside the
      0.5 s observer, calling an internal `handleHeartbeat(_:generation:)` that
      emits `.heartbeat(position: elapsed)` while playing
- [x] write emission tests in a new `cueTests/PlaybackSessionEventTests.swift`:
      started on play / resume / restart, stopped on pause / unload / load /
      ended / interruption / route change / failures, exactly-once semantics
      for repeated stops, seek emits close-then-open pair only while playing,
      paused seek emits nothing, same-rate `setRate` emits nothing, paused rate
      change emits nothing, heartbeat seam emits while playing and is
      generation-guarded
- [x] run `just build` and `just test` - must pass before task 2

### Task 2: SessionRecorder

- [x] create `cue/Playback/SessionRecorder.swift`: `@MainActor` struct holding a
      `ModelContext` and an injectable test-only episode lookup
      (`DownloadFinish` precedent); a single `handle(_ event: SessionEvent)`
      entry point
- [x] open (`.started`): resolve the episode by guid, close any lingering live
      session first (decision 13), insert a `PlaybackSession` with
      `startedAt = now`, `startPosition`, `endPosition = startPosition`,
      `rate`, link `episode`, save; failed save deletes the inserted row;
      missing episode logs and records nothing
- [x] close (`.stopped`): fetch the live session (`endedAt == nil`); if none,
      no-op; write `endPosition`, set `endedAt = now`, save
- [x] `.seeked`: close the live session at `from`, open a new one at `to` with
      the current rate; no-op when nothing is live
- [x] `.rateChanged`: close the live session at `position`, open a new one at
      `position` with `newRate`
- [x] `.heartbeat`: write `endPosition` on the live session, save; no-op when
      nothing is live
- [x] launch sweep `closeAbandonedSessions()`: close every `endedAt == nil` row
      with `endedAt = startedAt + max(0, (endPosition - startPosition) / rate)`,
      save once; safe on an empty store
- [x] all failures log under a `playback` category at default privacy — no URL,
      no raw error description at `.public`
- [x] write recorder tests in `cueTests/SessionRecorderTests.swift`: each event
      maps to the specified writes; open links the episode; heartbeat updates
      `endPosition` without touching `endedAt`; stopped with no live session is
      a no-op; double-open closes the first; the sweep closes multiple live
      sessions with the derived `endedAt` and leaves closed rows alone; a
      failing episode lookup records nothing and does not throw; persistence
      asserted through a second context
- [x] run `just build` and `just test` - must pass before task 3

### Task 3: Wiring and end-to-end acceptance shapes

- [x] `CueApp.init()`: construct `SessionRecorder(context: container.mainContext)`
      after the container, run `closeAbandonedSessions()` (logged, non-fatal),
      and wire `playback.sessionEvents = { recorder.handle($0) }`
- [x] write cross-service tests in `cueTests/SessionRecordingFlowTests.swift`
      (the `DownloadManagerPlaybackTests` precedent — real engine, rejected
      audio, real recorder over `makeContext()`): AC 5 shape — play, pause,
      play, pause yields two closed sessions with contiguous positions; AC 6
      shape — play, manual seek forward, pause preserves the pre-seek session's
      end and a new session starting at the target; AC 12 shape — a live
      session with heartbeat-advanced `endPosition` is closed by the sweep and
      `Episode.currentPosition` answers the heartbeat value
      - ⚠️ deviation: the AC 6 test drives `handleSeekCompletion` through its
        seam after `seek(to:)`. Periodic reports are suppressed while
        `pendingSeekGeneration` is set, so a post-seek position cannot be
        observed until the seek lands — the same reason the engine suite drives
        its callbacks directly.
- [x] verify existing suites still pass unchanged — refresh, download-delete
      and cascade tests already pin that sessions survive those paths
- [x] run `just build` and `just test` - must pass before task 4
      - ➕ `just format-check` fixed pre-existing `UseLetInEveryBoundCaseVariable`
        errors in `SessionRecorder.swift`'s switch (task 2 left them); `just lint`
        clean

### Task 4: Verify acceptance criteria

- [x] re-read spec §9 and AGENTS.md against the full diff — every close trigger
      in the table covered, no stored position anywhere, append-only holds
      - pause, episode switch (`load`), end of file (`handleItemEnded`, after
        `elapsed = duration`) and every failure/interruption path reach
        `stopPlaying()`, the one remaining `isPlaying = false` in the module;
        manual seek emits from `seek(to:)` only, rate change from `setRate(_:)`
        only, termination from the 10 s heartbeat plus the launch sweep
      - no position column added: `Episode.currentPosition` still derives from
        `sessions`, and the recorder's only delete is the row a failed open
        just inserted, so the log stays append-only
- [x] verify edge cases: rate re-selection, paused seek, double stop, launch
      sweep with zero and multiple live sessions, session write failure leaves
      audio playing
      - each is pinned by a named test: `reselectingTheLiveRateReportsNoBoundary`,
        `aSeekWhilePausedReportsNoBoundary`,
        `repeatedStopsCloseTheSessionExactlyOnce`,
        `theSweepIsSafeOnAnEmptyStore`,
        `theSweepClosesEveryLiveSessionWithTheDerivedEnd`,
        `aFailingEpisodeLookupRecordsNothingAndDoesNotThrow`; no recorder
        entry point throws, so no write can stop audio
- [x] run full test suite
- [x] run `just lint` and `just format-check` - all issues fixed
- [x] run `gitleaks detect --no-git`

### Task 5: Update documentation

- [x] update the README status paragraph (session tracking arrives; sleep timer
      and OPML remain)
- [x] add the session-log conventions to AGENTS.md (event seam, recorder shape,
      close funnel, heartbeat, sweep) in the house one-invariant-per-bullet
      style

## Technical Details

- **Event seam**: `SessionEvent` carries positions and rates only — no model
  types — so the engine keeps its no-SwiftData property and emission tests need
  no container.
- **Open/close invariant**: at most one live session exists at any time;
  enforced at open (close-first), at close (fetch-one), and at launch (sweep).
  `currentPosition` ignores `endedAt`, so the live session's heartbeat is the
  resume position by construction.
- **Ordering inside the engine**: `.started` emits after `isPlaying = true` and
  audio-session activation succeed; `.stopped` emits from the funnel helper at
  the moment of transition, after `elapsed` reflects the stop position
  (`handleItemEnded` sets `elapsed = duration` first).
- **Heartbeat**: second observer, 10 s, `queue: .main`, generation captured at
  install; suppressed while a seek is pending (`pendingSeekGeneration`), same
  as the UI observer.
- **Contiguity (AC 5)**: session N+1's `startPosition` equals session N's
  `endPosition` because open reads `elapsed`, which the close just recorded.
- **File lengths**: `PlaybackEngine.swift` stays under 400 via the audio-session
  relocation; new tests go to new suites, not `PlaybackEngineTests.swift`.
- **Logging**: `playback` category, default privacy, no URLs (AGENTS.md secrets
  rule).

## Post-Completion

*No checkboxes — external verification.*

**Device acceptance (owner, on iPhone):**

- AC 5: play 5 minutes, pause, play, pause → History (via a debug fetch or
  step 7) shows two sessions with contiguous positions.
- AC 6: seek forward mid-playback → pre-seek session keeps its original end, new
  session starts at the target.
- AC 12: force-quit mid-playback, relaunch → resume position at most 10 s
  behind, no live session in the store.
- Backgrounding and screen lock during playback leave the session live (no
  close row appears).

**Deferred by decision (not bugs):**

- History UI and revert — step 7.
- Played-on-end and sleep timer — step 8 (its pause closes the session through
  the normal path).
- Any termination observer — spec §9 covers termination via the heartbeat.
