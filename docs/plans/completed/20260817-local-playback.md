# Local playback with Now Playing integration (roadmap step 5)

## Overview

Audio plays from downloaded files, offline, with correct lock-screen behaviour
(spec §8, roadmap step 5). This step adds:

- `PlaybackEngine` — the app's second long-lived service, wrapping `AVPlayer`
  over the local file URL, owning the audio session and playback state.
- `NowPlayingController` — `MPNowPlayingInfoCenter` population and
  `MPRemoteCommandCenter` configuration with the scrubber and skip commands
  deliberately disabled.
- `PlayerView` — presented as a sheet from a new play action on downloaded
  episode rows in `PodcastDetailView` and `DownloadsView`; play/pause, enabled
  progress slider, elapsed/remaining, in-app ±30s skips, five-rate picker.

Acceptance (spec AC 4, AC 10): airplane-mode relaunch plays with no spinner or
error; lock-screen scrubber and skips are absent or inert while play/pause
works; rate changes take effect without pitch shift.

Revised 2026-08-19 against the step-4.5 (download diagnosability) tree after
an adversarial Codex review of the original draft; decisions 12–16 and the
task details they touch are that revision.

## Decisions (settled in planning — do not re-litigate)

1. **Scope is roadmap-minimal plus in-app ±30s skips.** Spec §12's player
   screen also lists a sleep timer and a history link; those belong to steps 8
   and 7 and are not pre-built, not even as disabled placeholders.
2. **No artwork in step 5.** Nothing in the repo downloads or caches images
   (`LibraryView` uses a deliberate placeholder), and the playback path must
   make no network request (spec §8, `.coderabbit.yaml`). Now Playing carries
   title, podcast title, duration, elapsed and rate only. Artwork arrives with
   a future artwork/caching step.
3. **Entry point: row play → sheet.** Downloaded rows in `PodcastDetailView`
   and `DownloadsView` get a play action that starts playback and presents
   `PlayerView` as a sheet. Dismissing the sheet keeps audio running; the same
   row reopens it. The mini-player is step 10.
4. **`PlaybackEngine` is a documented deviation from the cheap-struct rule.**
   AGENTS.md says `DownloadManager` is not a precedent; the engine's own
   argument: audio and Now Playing must outlive any view, and playback state
   (what is loaded, playing, at what rate) is deliberately in-memory only —
   the schema has no column for it and must not gain one. Created once in
   `CueApp.init()`, held as `@State`, injected with `.environment`, exactly
   the `DownloadManager` mechanism.
5. **Concrete engine, pure policy (approach A).** The engine wraps `AVPlayer`
   directly with no protocol seam. Everything assertable — the rate ladder,
   seek clamping, elapsed/remaining formatting, the Now Playing info
   dictionary, row play-eligibility, error mapping — lives in free functions
   or model methods and is unit-tested; AVPlayer/MediaPlayer/audio-session
   wiring is build-only-covered, per the existing convention.
6. **No session log in step 5.** `SessionRecorder`, the 10s heartbeat and
   session-boundary semantics are step 6. The engine exposes ordinary methods
   (`play`, `pause`, `seek`, `setRate`) that step 6 will observe; nothing is
   pre-built for it.
7. **Resume position is `Episode.currentPosition` at load.** The derived value
   is structurally `0` until step 6 writes sessions — correct behaviour now
   (start at the beginning) that lights up automatically later. No stored
   position anywhere, per the spec invariant.
8. **UI time updates are the engine's own periodic observer (~0.5s), not the
   step-6 heartbeat.** The 10s `addPeriodicTimeObserver` heartbeat in spec §9
   is session-log machinery and stays out; the UI observer only publishes
   elapsed time for the slider.
9. **Slider range prefers the player item's loaded duration.** When the item
   reports a finite positive duration, use it (authoritative, local); else
   fall back to `Episode.duration` guarded the way `episodeDurationText(_:)`
   guards — a feed-authored absurd duration must never reach `Int(_:)` or an
   unbounded slider.
10. **Rate is in-memory, five discrete values, default 1.0×.** Not persisted;
    spec records rate per session (step 6), never as a preference.
11. **Commit message carries a scope**: `feat(playback): local playback with
    now playing integration` — same deliberate override of the roadmap's
    scopeless form that step 4 recorded.
12. **Play gates on the disk, not the column.** `play` calls
    `try episode.isDownloaded(in: store)` before building the item: a
    confirmed-missing file throws `.fileMissing`, an indeterminate storage
    error propagates — never answered as "not downloaded" (the AGENTS.md
    rule). This is a local disk check, not a prohibited network or
    reachability check.
13. **`play` is idempotent on (guid, localFilename) — after the disk gate.**
    The engine tracks the loaded episode's guid *and* relative filename —
    after 4.5 a re-download keeps the guid but swaps the filename. Decision
    12's disk gate runs on *every* call, before idempotence, so a same-pair
    play whose file was deleted underneath still throws `.fileMissing`. Then:
    same pair with a live item (not failed, not ended) → ensure playing and
    let the caller re-present the sheet; ended item → restart from zero;
    different filename, failed item, or nothing loaded → full reload. This is
    what makes "the same row reopens the player without restarting" true.
14. **Play never appears on an Active Transfers row.** 4.5 split Downloads
    into Active Transfers (row state derived with `localFilename: nil` on
    purpose) and the completed list. The play policy is total over the 4.5
    row states — `.downloaded` and nothing else — and is attached only to
    podcast-detail rows and completed `DownloadedEpisodeRow`s.
15. **Deleting or replacing the loaded file unloads the engine first.** 4.5's
    re-download removes the previous file after the save (`DownloadFinish`),
    and delete removes it outright — either can unlink the file under a live
    `AVPlayerItem`. Every file-mutating action asks the engine to
    `unload(ifGUID:)` first. **As built,** no view asks directly: the request
    goes through `DownloadManager`'s injected `prepareForFileMutation`
    callback, invoked in `download(_:)` before transfer state is published
    (same main-actor turn, so no row can reload the old file in between), again
    in the shared finish path before the move — which additionally covers a
    background completion delivered with no scene alive — and in
    `deleteDownload(for:)` immediately before `store.removeFile`, after the
    cleared columns are committed, so a save that failed leaves audio playing
    over the file it left on disk. Relying on the player surviving an unlinked
    file is undocumented behaviour.
16. **Playback error text is fixed sentences.** 4.5 removed the
    `localizedDescription` pass-through from the download mapper because an
    arbitrary description can carry a URL-shaped credential, and wrote that
    into AGENTS.md. `playbackErrorMessage(for:)` follows the same rule from
    day one: every unknown category gets a fixed sentence.

## Context (from discovery, refreshed against the 4.5 tree)

Original inventory: `/tmp/cue-step5-playback-plan/findings.md` (2026-08-17
session artifact; row-action and error-mapper bullets superseded by 4.5).

- No `cue/Playback/` directory, no `MediaPlayer` import, no play affordance on
  any row.
- `UIBackgroundModes = [audio]` shipped; 4.5 added an ATS exception to the
  same `cue/Support/Info.plist` (plain-http feeds/enclosures) — irrelevant to
  playback, which never leaves the local disk.
- The one AVFoundation precedent: `DownloadPolicy.assetDuration(at:)` —
  `@concurrent nonisolated`, every failure answers `nil`.
- File URLs come only from `EpisodeStore.url(forRelativeFilename:)` (throws);
  never compose a path by hand. Disk presence comes only from
  `Episode.isDownloaded(in:)` (throws; "cannot tell" is never "absent").
- Long-lived service mechanism to copy: `CueApp.init()` builds the container,
  constructs the manager, `_downloads = State(initialValue:)`,
  `.environment(downloads)`.
- **4.5 row-state model** (`cue/Views/DownloadListFormatting.swift`):
  `EpisodeDownloadState` is `.notDownloaded / .downloading(DownloadProgress)
  / .downloaded / .failed(message:)`; `downloadAction(for:)` is a total
  `.download / .cancel / .delete` policy. `DownloadProgress` carries
  `.waiting / .indeterminate / .fraction` payloads.
- **4.5 Downloads screen**: an Active Transfers section
  (`cue/Views/ActiveDownloadFormatting.swift`, rows derive state with
  `localFilename: nil` on purpose — a failed retry over an episode that still
  has its old file shows Retry above while the completed list offers the old
  file below) plus the completed list.
- **4.5 error mapping** (`cue/Views/DownloadErrorMessage.swift`): fixed
  sentences for `URLError`/`CocoaError`/unknown; the raw
  `localizedDescription` pass-through is gone and AGENTS.md now forbids it.
- **4.5 stale-callback precedent**: async progress callbacks are guarded by
  attempt identity so a superseded attempt cannot overwrite newer state; the
  playback engine's async callbacks get the equivalent (decision 13's pair +
  a load generation).
- Free-function pattern and homes: `cue/Views/EpisodeListFormatting.swift`,
  `DownloadListFormatting.swift`, `DownloadErrorMessage.swift`.
- CodeRabbit path instructions specifically flag: any stored position, any
  network/artwork fetch on the playback path, anything making the Now Playing
  timeline interactive.
- Lint traps: 400-line `file_length` under `--strict`; collection literals stay
  on a single line (the five-rate ladder must be one line or a `switch`).

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
  - exception: AVPlayer/MediaPlayer/audio-session *wiring* is build-only by
    convention — its policy inputs (dictionaries, clamps, ladders, mappers)
    are what gets asserted
- **CRITICAL: all tests must pass before starting next task** - no exceptions
- **CRITICAL: update this plan file when scope changes during implementation**
- Run tests after each change
- Maintain backward compatibility

## Testing Strategy

- **Unit tests**: required for every task (see Development Approach above).
  Swift Testing only; suites touching SwiftData are `@MainActor` and use the
  shared `makeContext()`; file access goes through `withTemporaryBase` /
  `withTemporaryBaseAsync` with `EpisodeStore(baseDirectory:)`; bounded waits
  reuse `yieldUntil(_:)`, never a new scheduler-wait utility.
- Assertable surface: `playbackRates`, `clampedPlaybackPosition`,
  `playerDuration`, elapsed/remaining formatting,
  `nowPlayingInfo(title:podcastTitle:duration:elapsed:rate:)`
  dictionary contents, `playAction(for:)` row policy,
  `playbackErrorMessage(for:)`, and every `PlaybackEngine.play` path that
  throws before AVPlayer work (nil filename, invalid filename, confirmed
  missing file), plus idempotence, unload, and input-validation state
  transitions.
- Build-only surface: AVPlayer construction and KVO, audio-session
  category/mode/activation, `MPRemoteCommandCenter` handler registration,
  `MPNowPlayingInfoCenter` singleton writes, `PlayerView` layout. No test
  touches the `MPNowPlayingInfoCenter`/`MPRemoteCommandCenter` singletons.
- No audio fixture is committed (existing policy,
  `DownloadManagerDurationTests.swift`); engine tests use paths that fail
  before playback or bytes the asset reader rejects.
- **E2E tests**: none exist in this project.

## Progress Tracking

- Mark completed items with `[x]` immediately when done
- Add newly discovered tasks with ➕ prefix
- Document issues/blockers with ⚠️ prefix
- Update plan if implementation deviates from original scope
- Keep plan in sync with actual work done

## What Goes Where

- **Implementation Steps** (`[ ]` checkboxes): code changes, tests,
  documentation updates achievable in this codebase
- **Post-Completion** (no checkboxes): device acceptance (AC 4, AC 10), lock
  screen behaviour, audible rate/pitch verification
- **Checkbox placement**: checkboxes only in Task sections

## Implementation Steps

### Task 1: Playback policy and formatting free functions

- [x] create `cue/Playback/PlaybackPolicy.swift`: `playbackRates` — the five
      discrete rates 1.0/1.25/1.5/1.75/2.0 as a single-line literal;
      `clampedPlaybackPosition(_:duration:)` — clamps any position target
      (resume, manual seek, skip) into `0...duration`; a non-finite target
      answers `0`, a non-finite or absurd duration clamps the lower bound
      only; `playerDuration(itemDuration:episodeDuration:)` — prefers a
      finite positive item duration, else a bounded episode duration (same
      100-hour bound as `episodeDurationText`), else `nil`;
      `isValidPlaybackRate(_:)` — membership in `playbackRates`
- [x] create `cue/Views/PlayerFormatting.swift`: `playerTimeText(_:)` and
      `playerRemainingTimeText(elapsed:duration:)` — `h:mm:ss`/`m:ss`,
      total-safe against NaN/infinity/absurd values, never trapping in
      `Int(_:)`; `playbackRateText(_:)` for the rate picker labels
- [x] write tests for `playbackRates`, `clampedPlaybackPosition` (negative,
      past-end, non-finite target, non-finite duration), `playerDuration`
      (item wins, fallback, absurd feed duration answers nil),
      `isValidPlaybackRate` (each ladder value, an off-ladder value)
- [x] write tests for the formatting functions (zero, h:mm:ss rollover,
      NaN/infinite/absurd inputs, rate labels)
- [x] run `just build` and `just test` - must pass before task 2

### Task 2: PlaybackEngine

- [x] create `cue/Playback/PlaybackEngine.swift` and the topical
      `cue/Playback/PlaybackSeeking.swift` split: `@MainActor @Observable final
      class` with a doc comment arguing the long-lived deviation
      (decision 4); state: `episodeGUID: String?`, the loaded relative
      filename (decision 13), an ended flag (end-of-item reached),
      `episodeTitle` / `podcastTitle`, `isPlaying`, `elapsed`, `duration`,
      `rate`, `playbackError` (published async item failures);
      `enum Failure: Error, Equatable` with cases `notDownloaded` and
      `fileMissing` — an ordinary multiline enum (the single-line rule is
      about collection literals, not case lists)
- [x] pure decision helper in `PlaybackPolicy.swift`:
      `playLoadDecision(loadedGUID:loadedFilename:requestedGUID:
      requestedFilename:itemFailed:itemEnded:) -> PlayLoadAction`
      (`.reuse` / `.restart` / `.reload`) — the engine switches on it, tests
      assert it exhaustively without an audio fixture or player seam
- [x] `play(_ episode: Episode, store: EpisodeStore) throws`, in this order
      (decisions 12 then 13 — the disk gate is never bypassed): 1. guard
      `localFilename` else `.notDownloaded`; 2. `try episode.isDownloaded(in:
      store)` — confirmed-missing throws `.fileMissing`, an indeterminate
      storage error propagates unchanged; 3. `playLoadDecision` — `.reuse`
      hands off to the shared start operation and returns, `.restart` clears
      the ended flag, seeks to zero and starts; 4. `.reload`: resolve via
      `store.url(forRelativeFilename:)`; build `AVPlayerItem` with
      `audioTimePitchAlgorithm = .timeDomain`; seek to
      `clampedPlaybackPosition(episode.currentPosition, duration:)`; clear
      `playbackError` and the ended flag; start via the shared operation.
      No network call, no reachability check, no directory creation
- [x] one internal start operation is the **only** transition to playing —
      used by all three `playLoadDecision` outcomes, `resumeLoaded()` and
      `togglePlayPause()`: activates the audio session (category `.playback`,
      mode `.spokenAudio`) and starts at the stored rate; a no-op when
      already playing; never resumes a failed item
- [x] item lifecycle: observe item status — `.readyToPlay` refreshes
      `duration` through `playerDuration`, `.failed` publishes
      `playbackError` and stops; `AVPlayerItemDidPlayToEndTime` sets
      `isPlaying = false`, `elapsed = duration`, the ended flag — and does
      **not** mark the episode played (step 8); every async callback
      (periodic observer, status, end notification) captures the load
      generation and is ignored when a newer load superseded it (4.5's
      attempt-identity precedent) — so an older item's failure can never
      resurface after a reload cleared it
- [x] `pause()`, `togglePlayPause()` and `resumeLoaded()` (both through the
      shared start operation, so an ended item restarts from zero rather than
      resuming at the end; `resumeLoaded()` is the remote play handler's
      target and answers a no-op when nothing is loaded), `seek(to:)` and
      `skip(by:)` (both through `clampedPlaybackPosition`; a seek or skip
      landing away from the end clears the ended flag), `setRate(_:)` (rejects values
      failing `isValidPlaybackRate`; applies immediately when playing,
      remembered when paused), `unload(ifGUID:)` (decision 15 — stops, tears
      down observers, clears engine/player state and `playbackError` when the
      guid matches; Now Playing clearing is task 3's integration); periodic
      time observer (~0.5s) publishing `elapsed`; observers torn down on item
      swap and unload
- [x] wire into `cue/App/CueApp.swift`: construct in `init()`, hold as
      `@State`, inject with `.environment` beside `downloads`
- [x] write tests: `play` with `localFilename == nil` throws `.notDownloaded`;
      invalid filename propagates `EpisodeStore.Failure`; a confirmed-missing
      file throws `.fileMissing`; an indeterminate storage error propagates
      unchanged (the permission-denied pattern from
      `EpisodeStoreTests.fileExistsThrowsWhenTheFileSystemCannotAnswer`) —
      each leaving state untouched (all via `withTemporaryBaseAsync` +
      `EpisodeStore(baseDirectory:)`); `playLoadDecision` exhaustively:
      same pair live → `.reuse`, same pair ended → `.restart`, same pair
      failed → `.reload`, same guid new filename → `.reload`, nothing loaded
      → `.reload`; ended-flag transitions: restart → the next `play` answers
      `.reuse`, a backward seek after end-of-item → `.reuse`, resume after
      end-of-item starts from zero; `setRate` rejects an off-ladder value and
      updates state while paused; `unload(ifGUID:)` clears state for the
      matching guid and no-ops otherwise; idempotent re-`play` of the loaded
      (guid, filename) does not reset `elapsed`
- [x] run `just build` and `just test` - must pass before task 3

### Task 3: Now Playing and remote commands

- [x] create `cue/Playback/NowPlayingController.swift`: configures
      `MPRemoteCommandCenter` once — `playCommand` calls
      `engine.resumeLoaded()` (never `togglePlayPause()`: a duplicate Play
      event must not pause), `pauseCommand` calls `pause()`, both answering
      `.noActionableNowPlayingItem` when nothing is loaded and dispatching to
      the main actor; `changePlaybackPositionCommand`, `skipForwardCommand`,
      `skipBackwardCommand` `isEnabled = false` with `// deliberate` comments
      (spec §8 — a requirement, not an oversight)
- [x] free function `nowPlayingInfo(title:podcastTitle:duration:elapsed:rate:)
      -> [String: Any]` (in `PlaybackPolicy.swift` or beside the controller if
      file length demands): title, podcast title, duration, elapsed, rate; no
      artwork key (decision 2); omits duration when unknown rather than
      writing 0
- [x] engine updates the info center on play, pause, seek, rate change,
      item readiness (the loaded duration becoming known replaces a missing
      or feed-derived one), end-of-item and item failure through the
      controller, and clears it on unload; nothing else writes the singleton
- [x] write tests for `nowPlayingInfo`: exact keys present, no artwork key,
      rate reflects pause (0) vs play (rate), unknown duration omitted
- [x] run `just build` and `just test` - must pass before task 4

### Task 4: PlayerView and row play actions

- [x] create `cue/Views/PlayerRowPolicy.swift`: `playAction(for:
      EpisodeDownloadState) -> Bool` (or a small enum if a second action
      emerges) — a **total** switch: `.downloaded` offers play; `.notDownloaded`,
      every `.downloading(DownloadProgress)` payload and `.failed(message:)`
      offer none. Attached to podcast-detail rows and completed
      `DownloadedEpisodeRow`s only — never `ActiveDownloadRow` (decision 14)
- [x] create `cue/Views/PlayerView.swift`: title + podcast title, enabled
      progress slider bound to engine elapsed/duration (seek on release),
      elapsed and remaining labels, play/pause, ±30s buttons, five-rate
      picker from `playbackRates`, playback-error alert fed by the engine's
      published error; no artwork, no sleep timer, no history link
- [x] create `cue/Views/PlaybackErrorMessage.swift`:
      `playbackErrorMessage(for:) -> String?` covering
      `PlaybackEngine.Failure` (both cases), `EpisodeStore.Failure`,
      `CocoaError` (local file trouble) and a fixed fallback sentence —
      never `localizedDescription` (decision 16); feed and download mappers
      stay untouched
- [x] add the play action to `PodcastDetailView` rows (swipe + context menu,
      beside the existing actions) and completed rows in `DownloadsView`; the
      action calls `engine.play` (idempotent per decision 13), alerts through
      `playbackErrorMessage`, and presents `PlayerView` as a sheet;
      dismissing the sheet does not stop audio
- [x] route file-mutating actions through the engine (decision 15): delete
      actions on both screens call `engine.unload(ifGUID:)`; the long-lived
      download manager owns an injected guid-based callback that unloads before
      foreground transfer-state publication and again in the shared finish path
      before a file move, covering podcast-detail downloads, Active Transfers
      retries and orphaned completions delivered after relaunch
- [x] write tests for `playAction(for:)` — total over `.downloaded`,
      `.notDownloaded`, `.downloading` with `.waiting`/`.indeterminate`/
      `.fraction`, `.failed(message:)`; plus the 4.5 seam case: a failed
      transfer over an episode that still has its file is unplayable in
      Active Transfers (`localFilename: nil` → `.failed`) while the completed
      row (`localFilename` set, same transfer) stays `.downloaded` → playable
- [x] write tests for `playbackErrorMessage(for:)` — each failure case, and
      an arbitrary error whose description carries a URL-shaped string maps
      to the fixed sentence with the URL absent from the output
- [x] run `just build` and `just test` - must pass before task 5

### Task 5: Verify acceptance criteria

- [x] verify every Overview requirement is implemented; re-read spec §8 and
      AGENTS.md invariants against the diff (no stored position, no network
      on the playback path, scrubber/skips disabled, slider enabled, fixed
      error sentences)
- [x] verify edge cases: absurd feed duration in the player, seek past end,
      play a row whose file was deleted underneath (`.fileMissing` alert, no
      crash), delete/re-download of the loaded episode unloads cleanly, and
      an Active Transfers retry of the loaded episode unloads before its old
      file is replaced
- [x] run full test suite
- [x] run `just lint` and `just format-check` - all issues fixed
- [x] run `gitleaks detect --no-git` - clean

### Task 6: Update documentation

- [x] update `README.md` status paragraph (playback no longer "not built")
- [x] add the step-5 conventions to `AGENTS.md`: PlaybackEngine's long-lived
      argument (mirroring the DownloadManager entry), play's disk gate and
      idempotence pair, the unload-before-file-mutation rule, the no-artwork
      decision, the build-only boundary for MediaPlayer wiring

## Technical Details

- **Engine API surface** (step 6 will observe these seams; do not pre-build
  session hooks): `play(_:store:)`, `pause()`, `togglePlayPause()`,
  `resumeLoaded()`, `seek(to:)`, `skip(by:)`, `setRate(_:)`,
  `unload(ifGUID:)`; published `episodeGUID`, `isPlaying`, `elapsed`,
  `duration`, `rate`, `playbackError`.
- **Load generation**: a monotonically increasing token captured by every
  async callback; a callback whose generation is stale returns without
  touching state. The loaded identity for idempotence is (guid, relative
  filename) — decision 13; reuse/restart/reload is decided by the pure
  `playLoadDecision` helper so the branch is exhaustively testable.
- **Seek generation**: every asynchronous seek completion carries both the
  current load and seek generations. Periodic samples are ignored while a seek
  is pending, and a superseded completion cannot overwrite the newer target.
  The raw session resume position is retained until the local item reports its
  authoritative duration, then clamped and applied again against that value.
- **Isolation**: the engine is `@MainActor`; AVPlayer calls are cheap. The
  only potentially slow work (none identified in this step) would follow the
  `@concurrent nonisolated` rule — never bare `nonisolated`.
- **Audio session**: `AVAudioSession.sharedInstance()`, category `.playback`,
  mode `.spokenAudio`, `setActive(true)` on play. Deactivation on expiry is
  step 8 (sleep timer); step 5 does not deactivate.
- **Slider**: bound to `elapsed` over `0...duration`; while dragging, the
  label follows the drag and the seek commits on release, so the 0.5s
  observer does not fight the thumb.
- **End of item**: playback stops at the end with state consistent; the
  ended flag clears on restart, reload, or a seek landing away from the end,
  so a restarted episode is reusable, not restarted twice. Marking the
  episode played on `AVPlayerItemDidPlayToEndTime` is step 8 and must not be
  added here.
- **Start operation**: the single internal transition to playing — audio
  session activation plus the stored rate — shared by `play`'s three
  outcomes, `resumeLoaded()` and `togglePlayPause()`; a no-op when already
  playing.
- **Logging**: this step needs no playback log entries. Future playback logging
  uses a `playback` category and never places a URL at `.public` privacy — file
  URLs embed nothing secret but the convention is uniform.
- **File lengths**: engine, controller, and view each stay under 400 lines;
  split by topic if approached (`DownloadPolicy.swift` is the precedent).

## Post-Completion

*No checkboxes — external verification.*

**Device acceptance (owner, on iPhone):**
- AC 4: download an episode, enable airplane mode, force-quit, relaunch,
  play — no spinner, no error, no delay.
- AC 10: play with the phone locked — lock-screen scrubber and skip controls
  absent or inert; play/pause works.
- Rate: switch 1.0× → 2.0× mid-playback — speed changes audibly without pitch
  shift; backgrounded audio keeps playing (background mode already shipped).
- Sheet flow: dismiss the player — audio continues; reopen from the row
  without the position resetting.
- Delete the currently playing episode's download — playback stops cleanly,
  no crash, no dangling Now Playing entry.

**Deferred by decision (not bugs):**
- Now Playing artwork (needs an artwork pipeline; decision 2).
- Sleep timer, history link (steps 8, 7); session log and true resume
  (step 6); mini-player (step 10).
