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

`just lint` runs `--strict`, so SwiftLint's default 400-line `file_length`
*warning* fails the build. `.swiftlint.yml` overrides `type_body_length` but not
`file_length`: split a long file or suite by topic — `DownloadPolicy.swift`,
`DownloadPacing.swift`, `DownloadPhases.swift`, `DownloadQueue.swift`,
`DownloadDeletion.swift`, `BackgroundDownloaderRouting.swift`,
`DownloadManagerRelaunchTests.swift`, `DownloadManagerDurationTests.swift`,
`DownloadDiagnostics.swift`, `DownloadRows.swift`, `DiagnosticsExportButton.swift`,
`DownloadManagerAttemptIdentityTests.swift`, `DownloadManagerStallTests.swift`
`DownloadCancellationDiagnosticsTests.swift`, `DownloadDeletionTests.swift`,
`FeedDiagnostics.swift`
and `DownloadManagerThrottleTests.swift` are all splits, not designs — rather than raising the limit. Do not carry a
remembered line count for any of them: the numbers move every step, and an
earlier draft of this file was cited as claiming the relaunch suite sits at
exactly 400 lines when it does not (363 at the time of writing). Measure with
`wc -l` before deciding a file has room.

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
  Resolution, existence, move, remove, size *and naming* go through
  `EpisodeStore` — `url(forRelativeFilename:)`,
  `fileExists(forRelativeFilename:)`, `moveFile(at:toRelativeFilename:)`
  (overwrite-safe, so a crash between the move and the model write cannot block
  a retry), `removeFile(forRelativeFilename:)` (a confirmed not-found is
  success), `fileSize(forRelativeFilename:)` (`nil` only on a confirmed
  not-found, otherwise it throws rather than contributing a silent zero) and
  `downloadFilename(forEnclosureURL:)` (spec §5: a fresh UUID plus an extension
  inferred from the enclosure path, fallback `mp3`, composing only). Never
  compose an episode path by hand, and never reach for `FileManager` on an
  episode file directly; the store is the single place that rejects names which
  would resolve outside `Episodes/`. `EpisodeStore` is a cheap struct
  constructed at the call site — no shared singleton.
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
  `Episode.fileSize(in:)` is the same shape and the same rule: `nil` means
  positively no file (no stored filename, or one the store confirmed absent),
  and every other storage failure propagates — reporting an unmeasurable file as
  zero bytes tells the user a real download costs nothing. Because the read
  throws, the size behind a delete confirmation is measured on the screen's
  error path, never inside a view builder that would have to swallow it.
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
  `AVPlayerItem` is built from the local file URL. Now Playing has no artwork in
  this step because the app has no downloaded artwork pipeline; adding a fetch
  there would violate offline playback. (spec §8)
- **Play gates on the disk before it considers reusing an item.** Every
  `PlaybackEngine.play(_:store:)` call requires a `localFilename` and calls the
  throwing `Episode.isDownloaded(in:)`; a confirmed absence is `.fileMissing`,
  while an indeterminate storage error propagates. Only after that check may the
  engine reuse the loaded `(guid, localFilename)` pair. The same live pair keeps
  its position, an ended pair restarts from zero, and a changed filename reloads
  even when the guid is unchanged.
- **Unload playback before removing or replacing an episode file.** No view
  does this itself. `DownloadManager` owns an injected guid-based preparation
  callback wired to the engine (`CueApp` supplies
  `{ guid in playback.unload(ifGUID: guid) }`), and every file mutation goes
  through it: an accepted foreground download invokes it immediately before
  publishing transfer state, the shared finish path invokes it again before
  moving a completed file, and `deleteDownload(for:)` invokes it after the
  cleared columns are committed and immediately before `store.removeFile`. The
  finish-path call covers orphaned background completions, where a relaunched
  app can load the old file after the original process is gone; the delete-path
  call is what keeps the invariant off two untested screens and out of reach of
  a failed save, which leaves the file on disk and must leave audio playing.
  Active Transfers retries follow the same manager-owned path. A new
  file-mutating operation calls `prepareForFileMutation(guid)`, never
  `PlaybackEngine.unload(ifGUID:)` directly.
- **Every asynchronous playback callback is generation-guarded, and a failed
  item is an error rather than silence.** `PlaybackEngine` bumps
  `loadGeneration` on each load and unload and `seekGeneration` on each seek;
  the item-status, end-of-item, periodic-time and seek-completion seams capture
  the generation current when they were installed and return without touching
  state when it is stale, so an older item's failure cannot resurface after a
  reload cleared it and a superseded seek cannot undo the newer target. New
  callbacks follow that shape. `AVPlayer.status` is observed alongside
  `AVPlayerItem.status` because the player is an error surface of its own: a
  player-level failure stops audio without touching the item, so unobserved it
  would leave `isPlaying` true and Now Playing publishing a rate over silence.
  A seek that reports `finished == false` gives back the `itemEnded` clear it
  applied optimistically and stops the player with it — the playhead may still
  be at the end, so a restart that never landed must restart again rather than
  leave Pause showing and a rate published over silence.
  `play(_:store:)` reloads a failed pair, but the
  resume paths (`resumeLoaded()`, `togglePlayPause()`) cannot reload, so
  `startLoadedPlayback()` throws on a failed item — returning quietly left the
  player sheet's and the lock screen's Play button dead with no feedback.
- **The engine owns the audio session and does not deactivate it in this step.**
  Activation happens in the one internal start transition (category
  `.playback`, mode `.spokenAudio`); deactivation belongs to the sleep-timer
  step. Two lifetime observers reconcile state with the system: an interruption
  pauses on `.began` and deliberately does not resume on `.ended` (a call must
  never silently restart audio in a pocket), and a route change pauses on
  `.oldDeviceUnavailable`, which the system acts on without posting an
  interruption at all — without it, unplugging headphones leaves the button
  showing Pause for silence. `AVPlayerItem.audioTimePitchAlgorithm =
  .timeDomain` is what makes the rate ladder change speed without pitch shift
  (spec §8) — a requirement, not a default worth tidying away.
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
  a row the feed itself authored, on every launch. The bound is one shared
  constant, `maximumReasonableEpisodeDuration` in
  `cue/Playback/PlaybackPolicy.swift`, and every consumer guards independently
  of the parser: `episodeDurationText(_:)` shows anything past it as no
  duration at all, `playerTimeText(_:)` as `0:00`, `playerDuration(itemDuration:episodeDuration:)`
  rejects a feed value past it, and `isPlaybackDurationUsable(_:)` is the one
  predicate the player's three duration consumers share —
  `playerSliderUpperBound(duration:)` answers a placeholder bound on it,
  `playerRemainingTimeText(elapsed:duration:)` answers `--:--` on it, and
  `PlayerView` disables the slider on it. They must not disagree: `playerDuration`
  deliberately passes an item-reported duration through unbounded, so a slider
  disabled on `duration == nil` alone renders live over `0...1` while elapsed
  runs past it, and a bound derived from the elapsed time would instead pin the
  thumb at the far end and leave a control that can only seek backwards. Never
  re-declare a local copy.
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
- The completed list in Downloads filters on file presence only, never on played
  state. The Active Transfers section is separate and derives directly from the
  in-memory transfer states. (spec §7)

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
  real background session. That seam is
  `DownloadManager.FileTransport = @Sendable (URL) async throws -> (URL, URLResponse)`;
  the production closure is `BackgroundDownloader.shared.transport`, and every
  download test injects a stub over it. A download's temporary file is claimed
  inside the delegate callback, before it returns — the system deletes it after.
  Because `FileTransport` carries a URL and nothing else, the episode identity a
  task needs travels out of band: `DownloadTaskIdentity.currentGUID` (a task-local
  set around the transport call) stamps `URLSessionTask.taskDescription`, which is
  how a relaunched app maps a finished task back to an `Episode`.
- **`DownloadManager` is one of two long-lived services, on purpose.** It is a
  `@MainActor @Observable final class` created once in `CueApp` and injected with
  `.environment`, not a struct built at the call site: a background session's
  delegate and the in-memory per-guid transfer state have to outlive any view,
  and transfer state is deliberately not persisted (the spec's schema has no
  column for it and `#Unique` upserts make new columns a refresh hazard —
  a mid-download termination is recovered from the session, not the store).
  `BackgroundDownloader` is a singleton for a harder reason: a background session
  identifier is process-global, so a second instance is a runtime error (the
  session itself is created behind a lock rather than by a `lazy var`, whose
  initialisation is not atomic and which the app delegate and the transport can
  reach at the same moment).
- **`PlaybackEngine` is the other long-lived service, on purpose.** It is a
  `@MainActor @Observable final class` created once in `CueApp`, held in
  `@State`, and injected with `.environment`: audio, the loaded item and Now
  Playing integration must outlive the player sheet. Its playback state is
  deliberately in-memory only; do not add a stored position or another schema
  field. These two long-lived services are not a precedent for anything else —
  every other service stays a cheap struct.
- **Download progress is a six-phase vocabulary, in-memory and attempt-guarded.**
  `DownloadProgress` distinguishes `.queued(position:)`, `.connecting`,
  `.indeterminate(bytesWritten:bytesPerSecond:)`,
  `.fraction(bytesWritten:expectedBytes:bytesPerSecond:)`,
  `.stalled(bytesWritten:expectedBytes:)` and `.finalizing(bytesWritten:)`;
  never collapse those into `Double?`, and never merge queued with connecting —
  telling a queued transfer from a connecting one is the point. `.finalizing`
  covers the window between the last byte and the file landing in `Episodes/`,
  which is where a real device failure was observed; rendering it as an ordinary
  100 % is the confusion it exists to remove. Progress and failure state stay out
  of SwiftData. A progress callback applies
  only to the registered live attempt for its guid while that attempt remains
  `.downloading`; delayed callbacks from retired or older attempts are dropped,
  and lower byte counts never replace newer progress. The attempt records every
  accepted report, but the observed `states` map is written only when the row
  would render differently (`DownloadProgress.rendersDifferently(from:)`,
  compared over every displayed field — phase, queue position, byte count,
  expected total, whole percent and whole-kilobyte rate bucket; the flood a
  coarser comparison used to hold off is held off by the throttle instead):
  observation invalidates on assignment rather than on
  inequality, and both download screens read that map, so publishing every byte
  callback costs a library-wide body pass tens of times a second. Throttling
  there is deliberate — do not "restore" a write per callback.
- **The throttle is trailing, generation-guarded and lifecycle-exempt.**
  Repeated byte and rate publications are limited to one per
  `DownloadPacing.publishInterval` with at most one pending trailing
  publication per attempt, so a transfer cannot end on a stale row. *Lifecycle*
  transitions — queued to connecting, a queue reindex, stalled, finalizing and
  every terminal state — bypass the throttle entirely and invalidate any pending
  byte publication: a change the user caused must not wait for the next
  callback, and a callback must not undo it. Before a deferred publication
  writes it must match its own publication generation *and* the guid *and* the
  attempt token *and* an actively moving phase — "still downloading" is not
  enough, because `.stalled` and `.finalizing` are both downloading states.
- **Stall detection and rate go through an injected `DownloadClock`, never
  `Date` or a bare `Task.sleep`.** The attempt keeps a monotonic last-increase
  timestamp updated only on a strict byte increase; a deadline task scoped to
  the attempt and tagged with a generation writes `.stalled` after
  `DownloadPacing.stallThreshold`. `now()` is monotonic uptime on purpose — the
  deadline compares two readings taken across a suspension, and a wall-clock
  adjustment between them would either stall a moving transfer or postpone
  stalling forever. `TransferRateWindow` measures across a bounded trailing
  window rather than between the last two callbacks, which can be milliseconds
  apart. No test may sleep to exercise any of this.
- **Download cancellation is guid-addressable but attempt-scoped.** An adopted
  background transfer has no in-process `Task`, so cancellation enumerates
  session tasks by the guid in `taskDescription`, while queued transfers are
  removed from the guid-keyed waiter list. The request names the cancelled
  attempt's task identifier alongside the guid and both must match; there is no
  guid-wide form. Enumerating the session suspends, and by the time it answers
  that attempt may have retired and a retry — whose task carries the same guid —
  may hold it, so guid matching alone would cancel the transfer the user just
  started. A task is created off the main actor and registered back onto it, so
  an attempt can be cancelled before it has an identifier to name: that request
  is not widened to the guid but re-issued from `registerStartedAttempt`, which
  runs before the task is resumed. Cancellation intent belongs to the attempt
  record and is checked through finalisation; it is cleared when that exact
  attempt retires so a retry is not poisoned.
- **A failed download state carries its safe display message.** Every failure
  write goes through `downloadErrorMessage(for:)`; cancellation produces no
  failed state, and the fallback for an unknown error is always a fixed message,
  never its raw description. Raw descriptions and full enclosure URLs may
  contain credentials and must not reach the UI or a `.public` log entry.
- **A relaunch delivery is never dropped, and never answered early.** iOS may
  relaunch the app *only* to hand over a finished background transfer, so:
  `AppDelegate` — the app's one UIKit *lifecycle* entry point, via
  `@UIApplicationDelegateAdaptor`, for
  `application(_:handleEventsForBackgroundURLSession:completionHandler:)` and
  nothing else — stores the handler and wakes the session; `CueApp.init()`
  installs the completion route (`DownloadManager.registerCompletionRoute(with:)`)
  before any scene exists, because a background launch may never present one;
  `BackgroundDownloader` still *queues* an orphaned outcome that arrives before a
  handler is registered rather than deleting its file; failures are routed
  alongside successes, since a completion nobody hears about leaves its row
  transferring forever; and the stored UIKit handler is called only once the
  session has delivered every event *and* `completeDeliveredWork()` says the
  finishes are done — answering it early lets the system suspend the app
  mid-move. That accounting covers *both* routes: a suspended-not-terminated app
  still holds the continuation, so an awaited outcome is counted at delivery too
  and released by `DownloadManager`'s `DeliveryBarrier`, which is injected beside
  the transport (a stub transport gets the default no-op) and fired exactly once
  per transport call, failures included. UIKit handlers *queue* rather than
  replace each other, and the "events delivered" signal is consumed only when
  handlers actually leave: a handler handed over after its events were already
  delivered — the suspended-not-terminated order — is answered at registration,
  and answering a replaced handler inline would report "safe to suspend" while a
  finish is still running. Background transfers are carried by the
  system daemon and need no `UIBackgroundModes` entry: `UIBackgroundModes` stays
  `audio` only. The partial plist carries exactly three keys — that one, the
  `NSAppTransportSecurity` exception (spec §6) and `UIFileSharingEnabled` for
  the diagnostics export — because none has an `INFOPLIST_KEY_*` equivalent.
  `LSSupportsOpeningDocumentsInPlace` does have one, so it lives in
  `Config/App.xcconfig` instead.
- **The app builds its own `ModelContainer`.** `CueApp.init()` constructs it and
  passes it to `.modelContainer(container)` rather than `.modelContainer(for:)`,
  because `DownloadManager` needs `mainContext` before the scene body runs; a
  container that cannot open is a deliberate `fatalError` (the modifier traps
  too). Adding a model means updating two schema lists: `CueApp.init()` and
  `makeContext()` in `cueTests/InMemoryContainer.swift`.
- **The default transport revalidates.** `FeedService.feedRequest(for:)` sets
  `cachePolicy = .reloadRevalidatingCacheData`, and that is a correctness
  requirement rather than a tuning knob: refresh is manual only (spec §6), so a
  pull-to-refresh has to reach the server. Under the default protocol policy a
  feed sending `Cache-Control: max-age` is answered from `URLCache` and the
  refresh reports success having fetched nothing. Revalidating still honours a
  304. The request is a named function so the policy is assertable.
  It also sets `timeoutInterval = FeedService.requestTimeout` (20 s). That is an
  *idle* timeout — Apple restarts the clock on every byte — so it bounds a
  silent server, never a large feed that keeps arriving; the inherited 60 s
  default is a full minute of a spinner saying nothing. Both the policy and the
  timeout are asserted.
- **Fetch failures name what failed.** Non-2xx throws
  `FeedService.Failure.httpStatus(status, url)`; an unparseable or non-http
  address throws `Failure.invalidURL(string)`; a new subscription whose every
  episode is owned elsewhere throws `Failure.allEpisodesOwnedElsewhere(url)`.
  Transport errors (`URLError`, ATS rejections) and `FeedParser.Failure`
  propagate unchanged — wrapping them hides the cause.
  `feedErrorMessage(for:host:)` is the single place those map to user-facing
  text. Download failures map
  through `downloadErrorMessage(for:)` (`cue/Views/DownloadErrorMessage.swift`)
  instead — it covers `DownloadManager.Failure`, `EpisodeStore.Failure`,
  `CocoaError` (storage) and `URLError`, answers every other
  error with a fixed sentence rather than its description, and
  returns `String?` so cancellation cannot be reported by forgetting a `catch`,
  the same shape as `reportableFeedErrorMessage(for:host:)`. `URLError` is split into
  the four categories that change what a person does next — timed out,
  connection lost or unreachable, could not be saved to storage, and a fixed
  sentence for anything else. Never collapse them back into one line: answering
  every `URLError` with "could not reach the server" is exactly what made the
  first device session undiagnosable. The feed mapper stays feed-only, and so
  does the export's: `diagnosticsExportErrorMessage(for:)`
  (`cue/Views/DiagnosticsExportErrorMessage.swift`) is a third function rather
  than a reuse, because handed a `CocoaError` the download mapper tells the user
  a *download* failed under an alert titled *Could Not Export Diagnostics*. It
  is non-optional, unlike the other two — the export is one tap that either
  produces a file or does not, so a `nil` would only let the button fail
  silently. Playback failures map through `playbackErrorMessage(for:)`
  (`cue/Views/PlaybackErrorMessage.swift`) — `PlaybackEngine.Failure`,
  `EpisodeStore.Failure`, `CocoaError`, and a fixed sentence for anything else,
  for the same credential reason. Each mapper stays domain-only; do not merge
  them.
- **A feed or enclosure URL never reaches the log at `.public` privacy.** Private
  feeds are pre-signed (spec §6), so those URLs are tokens, and `os_log` renders
  an error's associated values — `DownloadManager.Failure.httpStatus(_, url)`
  carries one. Log at the default (private) privacy, or log the status and the
  guid instead; `.public` entries persist in the device log and in a
  sysdiagnose. See `docs/SECRETS.md`.
- **Cancellation is not a failure to report.** `.refreshable`'s task is
  cancelled when its view goes away and `URLSession` surfaces that as
  `URLError.cancelled`; `isCancellation(_:)` (`cue/Views/FeedRefreshing.swift`)
  is the single classifier. Never pass a cancellation to
  `feedErrorMessage(for:host:)` — it pops an alert on a disappearing view, and
  inside a multi-feed sweep it becomes the reported error and masks the real
  one. A screen running one feed catches once and calls
  `reportableFeedErrorMessage(for:host:)`, which answers `nil` for cancellation,
  so the rule cannot be forgotten a `catch` clause at a time; the sweep's own
  version of it is `refreshAll(_:using:onStep:)`, which counts a cancellation as
  neither a refresh nor a failure. A *cancelled* fetch is also not a
  record: `FeedService` skips `feed.fetch_failed` for one, the same line
  `recordTerminalFailure` draws on the download route — logged as a failure it
  fills the export with error-level lines for deliberate user actions.
- **Naming a feed in user-facing text goes through `DiagnosticsHost`, not a
  `String`.** `feedErrorMessage(for:host:)` and
  `reportableFeedErrorMessage(for:host:)` consult it only for errors that carry
  no address of their own — a `URLError` says "the request timed out" and
  nothing more, which inside a sweep over several subscriptions does not say
  *which* feed timed out. The type is the guard: a full private-feed URL cannot
  be passed where scheme-and-host is meant (spec §6), and `nil` is for callers
  with no address to name. The same value travels on `FeedRefreshFailure` and
  `FeedRefreshPhase`.
- **A sweep reports counts, not just its first error.**
  `refreshAll(_:using:onStep:)` returns a `FeedRefreshSummary` — refreshed,
  failed, and a structured first failure. A screen shows
  `feedRefreshSummaryText(refreshed:failed:)` *as well as* the alert when both
  counts are non-zero: the alert names one dead feed and on its own reads as
  "the refresh failed" when four other shows did update. That summary must be
  dismissible — the library list is the navigation root, so its state lives for
  the whole session and an undismissable banner becomes permanent chrome.
  `onStep` is a plain closure rather than a stream because the caller is a
  `.refreshable` body that has to stay one `await`. The status model's
  five-second "still waiting" transition runs on the injected `DownloadClock` —
  the seam for anything that *waits* on time, so no test sleeps. Measuring an
  *elapsed* duration is a different job with its own source:
  `FeedService.elapsedMilliseconds(since:)` reads `ContinuousClock` directly
  (monotonic, so a wall-clock adjustment mid-fetch cannot log a negative
  duration), and `DiagnosticsFileWriter` takes its own `now: () -> Date` for
  record timestamps, which have to be wall-clock to mean anything to a reader.
  Three sources, on purpose; do not collapse them.
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

## Diagnostics

The device log exists so a failure the owner hits once can be read back by an
agent. Everything here follows from that and from `docs/SECRETS.md`.

- **The sink is injected with a no-op default.** `DiagnosticsSink` has
  `record(_:)` and `flush()`; `NoOpDiagnosticsSink` is the default everywhere, so
  no existing test writes to disk by accident. `DownloadManager` takes one
  beside its transport; `FeedService` — a cheap struct built inside three views
  and never by `CueApp` — reads it from `\.diagnostics` in the environment.
  Production has exactly one `DiagnosticsFileWriter` so a single serial writer
  owns the file. That is a file-coordination reason and deliberately narrower
  than `BackgroundDownloader`'s: a second log writer is merely wrong, a second
  background session identifier is an OS-level runtime error.
- **Reading the log back is a separate capability.** `DiagnosticsSnapshotSource`
  is its own protocol (`\.diagnosticsSnapshots`), not a member of the sink.
  Widening the sink would force every conformance — the no-op included — to
  answer a question it has no business answering, and the export screen must
  never reach a snapshot by downcasting a sink it was handed for writing.
- **A log field cannot be an arbitrary `String`.** Hosts and guids enter through
  `DiagnosticsHost` and `DiagnosticsGUID`, whose only initialisers sanitise, and
  an error reduces to `DiagnosticsErrorCode` — bridged `NSError` domain and code
  only, never `localizedDescription`. Redaction is structural: a call site
  *cannot* pass a full address where a host is expected. A guid is a truncated
  SHA-256 digest of its UTF-8 bytes — never a prefix of itself (a guid is
  feed-supplied and frequently a URL, so its leading bytes can be a credential)
  and never Swift's `Hasher`, which is per-process randomised and would break
  the cross-relaunch correlation the file exists for. An attempt identifier is
  derived from the ownership token, not from the reusable task identifier.
- **Every terminal outcome leaves a line, including the ones that are not
  failures.** A transfer that ends without an episode to record it on — the guid
  was unsubscribed mid-flight, or another writer in this process already owns it
  — returns *normally*, so nothing downstream writes a terminal record on its
  behalf, and the exported log would show the request and its deciles and then
  stop. That silence is the exact ambiguity the file exists to remove, so those
  paths write `download.discarded` with a `DiagnosticsDiscardReason` (a fixed
  vocabulary, never free text) rather than nothing. The relaunch route's failed
  episode lookup is the sharper case: it puts a *user-visible* failed row on
  screen and never reaches `recordTerminalFailure`, so it records its own
  `download.failed` — or `download.not_started` when the outcome arrived before
  ownership was claimed and there is no attempt to name.
- **The writer appends because it seeks, so a failed seek is a failed open.**
  `FileHandle(forWritingTo:)` opens at offset 0. Swallowing `seekToEnd()` caches
  a handle at the head of an existing log: later records overwrite earlier ones
  and the byte cap is measured from a size the file does not have, so it can
  reach roughly twice `byteCap` before rotating. Treat the seek as part of the
  open and let the next record retry.
- **Logging never throws and never fails a caller.** A write failure degrades to
  `os_log` and is otherwise swallowed: a broken log must not turn a working
  download into a broken one. `os_log` stays — the file is an additional sink,
  not a replacement — and the file rather than
  `OSLogStore(scope: .currentProcessIdentifier)` because the transfers this
  explains often finish in a different process than the one that started them.
- **`record(_:)` is a fence, not merely serialized.** It enqueues synchronously
  into a lock-protected mailbox that the writer's actor drains, so a following
  `await flush()` is guaranteed to wait behind it.
- **The background-delivery barrier fires after logging and awaits a flush, but
  must complete even when the flush fails.** It is an explicit one-shot invoked
  after failure-state and log handling, never `defer`: a `defer` inside the
  inner `do` fires *before* the outer `catch` writes the failure, which leaves
  exactly the terminal records — failed, file moved, finished — unprotected. A
  lost log is survivable; a never-answered UIKit handler is not.
- **A failed rotation must not reset the size bound.** `currentSize` is zeroed
  only when the move actually happened: telling the writer an oversized file is
  empty grants another whole `byteCap` of growth before the next attempt, and
  repeated failures remove the bound entirely. Keeping the size retries the
  rotation on the next append instead, so the failure is logged once per streak
  rather than once per record.
- **The log lives in `Application Support/Diagnostics/`, never `Caches/`** —
  iOS evicts caches under storage pressure. One current generation with a byte
  cap plus one retained previous generation; the export assembles a header and
  every generation into one replaced file, so a second export replaces the
  first rather than growing a pile in Files.
- **The export needs two bundle settings.** Which one lives in the partial
  plist and which in `Config/App.xcconfig` is recorded once, with the relaunch
  rule under Networking — do not restate the key list here, because the next
  plist change will update one copy and leave the other stale.

## User-facing behaviour

- **The indicator's activation policy is a separate question from
  `downloadAction(for:)`.** `downloadIndicatorActivation(for:)` answers what a
  *tap* does; `downloadAction(for:)` answers what a chosen swipe action or
  context-menu item does. They differ in exactly two places, on purpose. A
  failed row is `.showFailure` for a tap and `.download` for a menu item spelled
  "Retry Download": an unlabelled triangle must not silently start a transfer
  over a connection that just failed, so retry is one explicit button further
  in. A downloaded row is `.confirmDelete` for a tap and immediate for a swipe:
  the swipe gesture is itself the confirmation, a tap is not. Both screens use
  `downloadIndicatorMinimumTapTarget` so the same control cannot get two
  different tap targets.
- **Every download indicator is built from a row state, never hard-wired.** No
  control may assume what its row is from the section it sits in. The Downloads
  tab's completed list is built on file presence alone, so a re-download appears
  there *and* in Active Transfers at the same time; an indicator wired straight
  to delete because "this is the downloaded section" offers an immediate removal
  under the running move, which clears the columns and the file just before the
  finish writes the new filename back over them — the episode returns seconds
  after the user removed it. Both of that row's controls resolve it through
  `episodeDownloadState(localFilename:transfer:)` first (`fileRowState(for:)`),
  so the tap target and the swipe action cannot disagree about what the row is,
  and `DownloadedEpisodeRow` takes its indicator from the screen rather than
  building one. Pinned by
  `aStoredFileBeingReDownloadedCancelsRatherThanDeletes`.
- **Row tap itself stays inert.** Step 5 claims it for playback.
- **The clipboard is detected, never blind-read.**
  `UIPasteboard.detectedPatterns(for:)` asks what *shape* the clipboard holds
  and does not prompt; reading its contents may, so the read happens only inside
  the Paste button's own action. A detection that fails offers nothing rather
  than falling back to a read the user did not ask for, the offer is withdrawn
  once the field has text (`shouldOfferFeedPaste(detection:fieldText:)`), and
  the value is revalidated through `pastedFeedAddress(fromClipboard:)` on the
  way in because the clipboard can change between the offer and the tap. A
  pasted address goes through the same normalisation a typed one does — the
  inner token of a private feed is never rewritten (spec §6).
- **`DiagnosticsShareSheet` is the view tree's only `UIViewControllerRepresentable`.**
  SwiftUI has no share sheet that takes a file URL and stays a toolbar item, so
  the export wraps `UIActivityViewController`. It is not a precedent: reach for
  a representable only where SwiftUI has no equivalent at all.
- **cue is English-only for now.** New strings are literals and no localisation
  machinery is introduced. Wordings avoid constructs that would need a formatter
  — the queue position is worded without an ordinal — so adding localisation
  later is a translation job, not a rewrite. This is a decision, not drift.

## Testing

- Swift Testing (`@Test`, `#expect`), not XCTest. No `XCTestCase` subclasses,
  no `XCTAssert`.
- Concrete `AVPlayer`, audio-session and MediaPlayer wiring is build-only
  covered. Do not make tests touch the `MPNowPlayingInfoCenter` or
  `MPRemoteCommandCenter` singletons. Extract and test the policy inputs instead:
  playback rates and clamps, Now Playing dictionaries, row actions, formatting
  and error mapping; engine tests cover state transitions and failures before
  AVPlayer work where practical.
- Views are covered by the build only. Anything worth asserting — sorting,
  formatting, error-message mapping, and the policy behind a view action (which
  failures stop a loop, which one gets reported, what a pasted address may be
  rewritten to) — is extracted into a plain free function
  (`cue/Views/EpisodeListFormatting.swift`, `cue/Views/FeedErrorMessage.swift`,
  `cue/Views/FeedRefreshing.swift`, `cue/Views/FeedAddress.swift`,
  `cue/Views/DownloadListFormatting.swift`, `cue/Views/DownloadErrorMessage.swift`,
  `cue/Views/ActiveDownloadFormatting.swift`,
  `cue/Views/DownloadIndicatorActivation.swift`, `cue/Views/FeedPasteOffer.swift`,
  `cue/Views/DiagnosticsExportErrorMessage.swift`,
  `cue/Views/PlayerFormatting.swift`, `cue/Views/PlayerRowPolicy.swift`,
  `cue/Views/PlaybackErrorMessage.swift`, and
  `cue/Views/FeedRefreshStatus.swift` — the one exception, a small `@Observable`
  model rather than a bare function, because the five-second "still waiting"
  transition is time-driven and nothing arrives to trigger it)
  and tested directly — including the policy the two download screens must not
  answer differently: a transfer in flight outranks a stored file, and a row
  mid-transfer offers Cancel rather than Delete. The Active Transfers section
  asks that same function with no filename, deliberately: it is the transfer's
  own view of itself, so a failed retry is listed there with Retry while the
  completed list below still offers Delete for the file that is really on disk. Model mutations a view triggers
  live on the model (`Episode.setPlayed(_:)`), so invariants stay pinned by model
  tests.
- Fixtures live in `cueTests/Fixtures/` and load through the shared
  `fixtureData(named:withExtension:)` helper in `cueTests/FixtureLoading.swift`,
  which resolves the test bundle via `Bundle(for:)` with a private marker class.
  Never read fixtures from a path on disk, and never re-declare a local loader.
- There is one transport double *per transport type*: `FeedTransportStub`
  (`cueTests/FeedTransportStub.swift`) for `FeedService.Transport` and
  `DownloadTransportStub` (`cueTests/DownloadTransportStub.swift`) for
  `DownloadManager.FileTransport`, sharing one `StubTransportError`. The download
  stub writes fresh bytes per call because the manager *moves* what it is handed,
  and it records peak concurrency so spec §7's one-transfer-at-a-time rule is
  assertable; the cases it must never produce by accident live beside it as
  `failingFileTransport(_:)` and `missingFileTransport(in:)`. Same rule
  as the fixture loader: never re-declare a per-suite copy. A stub that cannot
  build its `HTTPURLResponse` throws — degrading to a plain `URLResponse` reads
  as "no status to judge" and quietly sends a status test down the 2xx path.
  That constrains `FeedTransportStub` itself, not every transport a test may
  construct: `failingTransport(_:)` and `nonHTTPTransport(data:)` live in the
  same file precisely so the cases the stub must never produce by accident can
  still be produced on purpose. A suite-local factory over those shared pieces
  is fine; a second copy of the stub or the loader is not.
- The same one-double-per-seam rule covers the other injected seams:
  `RecordingDiagnosticsSink` (`cueTests/RecordingDiagnosticsSink.swift`) for
  `DiagnosticsSink` — its `flushSilentlyFails` models the only failure a sink
  can have, since `flush()` cannot throw, and it must stay observable
  (`flushAttemptCount` counts the asks, `flushCount` only the drains) or a test
  named for "a flush that achieves nothing" silently exercises the working path
  — and `ManualDownloadClock` (`cueTests/ManualDownloadClock.swift`) for
  `DownloadClock`, driven with `advance(by:)` and `wake()`. No test may sleep
  for a 30 s stall deadline or a 1 s throttle interval. Shared setup for the
  split progress suites lives in `cueTests/DownloadProgressSupport.swift`.
- **A test that only calls a timed body has not tested the task that calls it.**
  `flushPendingProgress` and `markStalled` are separated so they are assertable
  without a sleep, but a suite that *only* calls them directly covers neither the
  arming nor the firing: delete the call inside either armed `Task` and every
  such test still passes while no row ever updates and no transfer ever stalls.
  At least one case per timed path goes through the public entry point and
  releases the clock — `wake(_:until:)` in `cueTests/YieldUntil.swift`, which
  retries because an armed `Task` has not necessarily reached its `sleep` when
  a bare `wake()` arrives.
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
  `withTemporaryBase` for synchronous bodies and `withTemporaryBaseAsync` for
  awaiting ones (`cueTests/TemporaryDirectory.swift`), and construct
  `EpisodeStore(baseDirectory:)` against the directory it hands you. They are two
  names rather than an overload on purpose — two same-named functions taking only
  a closure are ambiguous at a trailing-closure call site, which
  `swift-format --strict` rejects — and the async one carries
  `isolation: isolated (any Actor)? = #isolation` so a `@MainActor` suite can
  hand it a closure over `@Model` values without the compiler treating them as
  sent across an isolation boundary. Do not drop that parameter.
- The relaunch route is tested through its own seams —
  `DownloadManager.handleCompletion(_:forGUID:)`, `adopt(inFlightAttempts:)` and
  `BackgroundDownloader.route(_:forGUID:)` — never through `connect(to:)`, so no
  test constructs a background session. Constructing a `BackgroundDownloader`
  does not create one; touching its `session` does, and no test may.
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
