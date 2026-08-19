# cue — Implementation Roadmap

Step-by-step build order for `cue`, derived from `SPEC.md`. Each step is
self-contained: it has a stated goal, a bounded set of files, an acceptance check
that can be run before moving on, and a commit message. No step requires a later
step to be verifiable.

**Read `SPEC.md` first.** This file says *when* and *in what order*. The spec says
*what*. Where they disagree, the spec wins.

## Conventions

- One step per pull request. The rev count is decided by content, per
  `AGENTS.md`: each rev atomic and independently green, small steps collapsing
  to one, large ones splitting into 2–4 cohesive units.
- Every step must leave `just build` and `just test` green. A step that cannot is
  split.
- Steps 0.1–0.9 are infrastructure. Steps 1–10 are the app.
- Every step is headless. The Xcode GUI is never required; the project file is
  authored once in step 0.2 and frozen afterwards.

## Project facts

| | |
|---|---|
| App name | cue |
| Bundle identifier | `dev.yachmenev.cue` |
| Deployment target | iOS 26 |
| Devices | iPhone only, portrait only |
| Repo | public, MIT |
| Test framework | Swift Testing |
| Dependencies | none |
| Distribution | unsigned `.ipa`, installed via an external re-signing service |

---

# Phase 0 — Prerequisites

## 0.1 Repository scaffold

**Goal.** A git repository with the correct ignore rules in place *before* any
Xcode artifacts exist, so build output and user state are never committed.

**Files.**

```
.gitignore
LICENSE          # MIT
README.md        # skeleton: name, one-line description, build instructions
.gitattributes   # optional; mark *.pbxproj as binary to suppress diff noise
```

`.gitignore` must cover at minimum:

```
# Xcode
build/
DerivedData/
*.xcuserstate
xcuserdata/
*.xcscmblueprint
*.xccheckout

# macOS
.DS_Store

# Local secrets — see 0.5
Secrets/
*.local.json
```

**Tasks.**

1. `git init`, initial commit before creating the Xcode project.
2. Enable **Secret scanning** and **Push protection** in repository settings.
   Free on public repositories and the cheapest possible insurance given the
   nature of private podcast feed URLs.

**Acceptance.** `git status` is clean. Repository is public on GitHub with push
protection enabled.

**Commit.** `chore: repository scaffold`

---

## 0.2 Xcode project — authored headlessly, then frozen

**Goal.** A buildable single-target iOS app with the correct capabilities,
authored once as a checked-in `.xcodeproj` written directly by the agent — no
Xcode GUI. Verified viable on this exact toolchain (Xcode 26.6, macOS 26): a
hand-authored `project.pbxproj` with synchronized folders builds, tests, and
produces an unsigned device `.app`.

**Structure.**

1. `cue.xcodeproj/project.pbxproj` — `objectVersion = 77`, two
   `PBXFileSystemSynchronizedRootGroup`s (`cue/`, `cueTests/`) attached to the
   app and test targets via `fileSystemSynchronizedGroups`, and
   `TargetAttributes { cueTests = { TestTargetID = cue } }`. No `.xcscheme`
   file — `xcodebuild` synthesizes an implicit scheme.
2. All build settings in `Config/{Shared,Debug,Release,Tests}.xcconfig`
   (outside the synchronized folders), referenced via
   `baseConfigurationReferenceRelativePath`: `PRODUCT_BUNDLE_IDENTIFIER`,
   `IPHONEOS_DEPLOYMENT_TARGET = 26.0`, `TARGETED_DEVICE_FAMILY = 1`,
   `INFOPLIST_KEY_UISupportedInterfaceOrientations_iPhone` (portrait only),
   `GENERATE_INFOPLIST_FILE = YES`, and `ENABLE_TESTABILITY = YES` in Debug
   (without it, `@testable import` fails with a misleading module error).
3. `UIBackgroundModes` **cannot** be expressed as an `INFOPLIST_KEY_*` build
   setting — no such setting exists. Use a partial `cue/Support/Info.plist`
   (outside the synchronized source folders, or Xcode reports "Multiple
   commands produce Info.plist") containing only `UIBackgroundModes = [audio]`,
   referenced via `INFOPLIST_FILE`; Xcode merges the generated keys into it.
4. After this step the project file is **frozen**: a Claude Code `PreToolUse`
   hook rejects edits matching `\.(pbxproj|xcworkspace)$`. Structural changes
   (a new target, an extension) are a deliberate human-approved event — and the
   trigger to reconsider XcodeGen.

**Directory layout** to establish now, since synchronized folders mirror the disk:

```
Config/           # xcconfigs — the only place build settings live
cue/
  Support/        # partial Info.plist (not compiled, not synchronized)
  App/            # entry point, root view
  Models/         # SwiftData models
  Feed/           # RSS + OPML parsing
  Storage/        # paths, reconciliation
  Download/       # URLSession background
  Playback/       # AVFoundation, session log
  Views/
cueTests/
  Fixtures/       # committed sample feeds
```

**Acceptance.** `xcodebuild build` and `xcodebuild test` succeed headlessly
against the iPhone 17 simulator. `plutil -p` on the built `.app`'s `Info.plist`
shows `UIBackgroundModes` as an **array** containing `audio`, `UIDeviceFamily`
`[1]`, and portrait-only orientations. An unsigned device build
(`CODE_SIGNING_ALLOWED=NO`) produces an arm64 `cue.app`.

**Commit.** `chore: headless xcode project with background audio capability`

---

## 0.3 Command surface

**Goal.** Stable verbs so no human or agent ever types an `xcodebuild`
incantation from memory. This is the step that actually enables headless
development — more so than any project generation tool.

**Files.** `justfile`

```just
scheme := "cue"
destination := "platform=iOS Simulator,name=iPhone 17"

default:
    @just --list

build:
    xcodebuild build -scheme {{scheme}} -destination '{{destination}}' \
        -quiet CODE_SIGNING_ALLOWED=NO

test:
    xcodebuild test -scheme {{scheme}} -destination '{{destination}}' \
        -quiet CODE_SIGNING_ALLOWED=NO

lint:
    swiftlint lint --strict

format:
    swift format --recursive --in-place cue cueTests

format-check:
    swift format lint --recursive --strict cue cueTests

ipa:
    xcodebuild archive -scheme {{scheme}} -configuration Release \
        -destination 'generic/platform=iOS' -archivePath build/cue.xcarchive \
        -quiet CODE_SIGNING_ALLOWED=NO
    rm -rf build/Payload build/cue.ipa
    cp -R "build/cue.xcarchive/Products/Applications" build/Payload
    cd build && zip -qry cue.ipa Payload

clean:
    xcodebuild clean -scheme {{scheme}}
    rm -rf DerivedData build

destinations:
    xcodebuild -scheme {{scheme}} -showdestinations
```

`CODE_SIGNING_ALLOWED=NO` keeps builds from requiring a signing identity — on
simulator builds for CI, and on `ipa` by design: the artifact is deliberately
unsigned, and an external re-signing service signs and installs it. `just ipa`
ends at `build/cue.ipa`; what happens to the file afterwards is out of the
justfile's scope.

**Acceptance.** `just build` and `just test` both succeed from a clean checkout.
`just ipa` produces `build/cue.ipa` containing an arm64 `cue.app` under
`Payload/`. `just --list` shows every recipe.

**Commit.** `chore: justfile command surface`

---

## 0.4 Lint and format configuration

**Goal.** Mechanical style enforcement so review attention goes to logic.

**Files.** `.swiftlint.yml`, `.swift-format`

Keep SwiftLint close to defaults. Worth enabling beyond the defaults:
`force_unwrapping`, `force_try`, `implicitly_unwrapped_optional`. Worth relaxing:
`line_length` to 120, `type_body_length` for SwiftData models.

`swift format` ships with Xcode, so it needs no install. SwiftLint does —
document `brew install swiftlint` in the README.

**Acceptance.** `just lint` and `just format-check` pass on the current tree.

**Commit.** `chore: swiftlint and swift-format configuration`

---

## 0.5 Secret hygiene

**Goal.** Make it structurally impossible to leak a private feed URL into a public
repository.

This is the highest-consequence infrastructure step. A Boosty feed URL contains an
authentication token in the URL itself. Committed to a public repo, it is
compromised immediately and permanently — git history is public and archived by
third parties within minutes.

**Rules.**

1. **No real feed URL appears anywhere in the repository.** Not in fixtures, not
   in tests, not in comments, not in commit messages, not in issue text.
2. Private feeds are added at runtime through the app UI and stored only in the
   on-device SwiftData store.
3. Fixtures use `https://example.com/feed?token=REDACTED_TEST_TOKEN`.
4. If a real URL is ever committed, treat the token as burned: regenerate it at
   Boosty first, then worry about history.

**Files.** `.gitleaks.toml` with a custom rule matching feed-shaped URLs carrying
query tokens, in addition to the default rule set.

**Acceptance.** `gitleaks detect --no-git` exits clean. Deliberately add a
token-bearing URL to a scratch file, confirm gitleaks flags it, then remove it.

**Commit.** `chore: gitleaks configuration and secrets policy`

---

## 0.6 Test fixtures

**Goal.** Committed inputs so feed parsing is testable without a network.

**Files.**

```
cueTests/Fixtures/
  simple.rss           # minimal valid feed, 3 episodes
  itunes.rss           # full itunes namespace, artwork, author, summary
  durations.rss        # episodes covering SS, MM:SS, HH:MM:SS, and missing
  tokenised.rss        # REDACTED token in feed and enclosure URLs
  malformed.rss        # truncated XML, for error-path tests
  no-enclosures.rss    # items with no audio, must be skipped not crashed
  sample.opml          # 5 feeds, one duplicate
```

Derive these from real public feeds, then **strip every real URL**. They are test
inputs, not archives.

**Acceptance.** Fixtures load as `Data` in a test target helper. No test yet —
parsing arrives at step 2.

**Commit.** `test: rss and opml fixtures`

---

## 0.7 Continuous integration

**Goal.** Every PR is linted, scanned, built, and tested before merge.

Public repository means GitHub-hosted runners are free and unmetered, including
macOS. Even so, split the cheap checks onto Linux — they fail faster and give
quicker feedback than waiting on a Mac runner to provision.

**Files.** `.github/workflows/ci.yml`

```yaml
name: CI
on:
  pull_request:
  push:
    branches: [master]

concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true

jobs:
  checks:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with: { fetch-depth: 0 }
      - name: Scan for secrets
        uses: gitleaks/gitleaks-action@v2
      - name: Lint
        run: |
          brew install swiftlint || true
          swiftlint lint --strict

  build-test:
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v4
      - name: Select Xcode
        run: sudo xcode-select -s /Applications/Xcode.app
      - name: Build
        run: just build
      - name: Test
        run: just test
```

Notes.

- Pin the Xcode version explicitly rather than trusting the runner default; a
  runner image update that bumps Xcode should be a deliberate change.
- `fetch-depth: 0` is required for gitleaks to scan history rather than only the
  tip commit.
- SwiftLint on Linux needs a different install path than `brew`; either move the
  lint job to macOS or use the official SwiftLint container image.

**Branch protection.** Require both jobs to pass before merge to `master`.

**README badges.** CI status is the only one carrying information. License,
platform, and Swift version are acceptable garnish. Do not add a coverage badge
without a coverage job — a stale badge is worse than no badge.

**Acceptance.** Open a trivial PR. Both jobs run and pass. Push a deliberate lint
violation and confirm the PR goes red.

**Commit.** `ci: lint, secret scan, build and test on pull requests`

---

## 0.8 Agent conventions

**Goal.** Give an LLM agent the invariants it cannot infer from the code.

**Files.** `AGENTS.md`

Contents:

- Command surface: use `just`, never raw `xcodebuild`.
- New files are picked up automatically via synchronized (buildable) folders.
  Build settings live in `Config/*.xcconfig` — edit those freely. Never edit
  `project.pbxproj` (a PreToolUse hook enforces this). If the project structure
  genuinely must change, stop and say so rather than editing the file.
- **The invariants from the spec that must never be violated:**
  - `isPlayed` and `localFilename` are orthogonal. Neither is ever inferred from
    the other.
  - There is no stored playback position field. Position derives from the session
    log.
  - `localFilename` is relative. Absolute paths are never persisted.
  - The playback path performs no network request and no reachability check.
  - Lock-screen scrubber and skip commands stay disabled.
  - No real feed URL enters the repository.
- Test with Swift Testing (`@Test`, `#expect`), not XCTest.
- One step per PR, matching this roadmap.

**Acceptance.** File exists and is referenced from the README.

**Commit.** `docs: agent conventions`

---

## 0.9 CodeRabbit as an advisory second reviewer

**Goal.** A second, non-human opinion on every PR — configured before its first
review, and structurally unable to gate a merge. All PRs here are LLM-authored,
so the value is the `🤖 Prompt for AI Agents` block on each finding: it turns a
review comment into a work item without the human transcribing it. The hard spec
invariants stay enforced in CI. Path instructions are guidance, never a gate.

**Files.** `.coderabbit.yaml`, `.github/workflows/ci.yml`

**Tasks.**

1. `.coderabbit.yaml` at the repository root — nowhere else is read. The
   non-default choices that matter: `profile: assertive`,
   `request_changes_workflow: false`, `slop_detection.enabled: false` (its
   default would annotate every PR in this repo), `enable_prompt_for_ai_agents:
   true`, `chat.allow_non_org_members: false` (defaults to *true* on public
   repos), `auto_review.auto_incremental_review: false` (the rate-limit lever —
   agent fixup pushes must not each burn an hourly review unit), walkthrough
   noise off (poem, sequence diagrams, fortune, effort estimate),
   `tools.swiftlint.enabled: false` (CI owns it), and `path_instructions`
   restating the spec invariants for `**/*.swift` and for the test tree.
2. A CI guard step in the `checks` job, `pull_request` only, dependency-free
   shell. It fails when the PR diff touches `.coderabbit.yaml` without the
   human-applied `coderabbit-config-change` label, or when the PR description
   contains `@coderabbitai ignore` / `@coderabbitai pause`. CodeRabbit reads its
   config from the branch under review, so without this guard a PR can weaken
   the reviewer meant to catch it. `.github/workflows` is the right place: the
   app holds no Workflows permission and cannot edit it.
3. Owner-side, by hand and once: install the GitHub App with **Only select
   repositories → `cue`**; sign in at `app.coderabbit.ai` (a separate OAuth
   grant); confirm the tier on the first PR walkthrough and with
   `@coderabbitai rate limit`; run `@coderabbitai configuration` on the first PR
   to verify the committed file actually wins. Add **no** CodeRabbit check to
   branch protection — the app holds `checks: write`.
4. Owner-side, Organization Settings → **Global Overrides** (priority 1, beats
   the repository file): pin `auto_review.enabled`, `slop_detection.enabled`,
   and `chat.allow_non_org_members`. This is the only structural defence against
   an agent editing the reviewer's own config.
5. Agent rules, already in `AGENTS.md`'s workflow section: re-review explicitly
   with `@coderabbitai review` after CI is green (incremental auto-review is
   off); consume the `Prompt for AI Agents` block, fix what is still valid, and
   reply on the thread with a one-line reason for anything skipped — those
   replies become repo-scoped Learnings. Never invoke `@coderabbitai autofix`,
   `generate docstrings`, `fix-ci` or `resolve merge conflict`, and never tick a
   walkthrough checkbox: those are the only paths by which the app's
   `contents: write` permission touches this repo.
6. Log every finding, per PR, as `real-bug` / `spec-violation` / `nit` / `wrong`.
   Revisit thresholds over the first 10 PRs: **uninstall** if `wrong` exceeds 30%
   of findings, if `real-bug` + `spec-violation` is zero, or if PRs routinely
   wait on the OSS hourly review limit (there is no overflow to buy).
   **Downgrade** `profile: assertive` → `quiet` first if `nit` + `wrong` exceeds
   ~50% while `real-bug` is non-zero; the poem, the verbosity and the vendor's
   press are not reasons to remove it.

**Acceptance.** CodeRabbit reviews a real PR and the review shows the config took
effect: no slop-detection annotation, no poem or sequence diagram, a collapsed
walkthrough, and a `🤖 Prompt for AI Agents` block on each inline finding;
`@coderabbitai configuration` echoes the committed values. The draft flow is
verified: a draft PR receives no review, and marking it ready (with CI green)
triggers exactly one automatic review; a subsequent push triggers none. The guard is
red-tested both ways: a PR touching `.coderabbit.yaml` without the label fails
`checks` and passes once the label is applied, and a PR whose description
contains `@coderabbitai pause` fails. This step's own PR adds `.coderabbit.yaml`,
so it carries the `coderabbit-config-change` label — that is the intended
override, not a workaround.

**Commit.** `chore: coderabbit configuration`

---

# Phase 1 — Foundations

## 1 SwiftData models and storage paths

**Goal.** The persistence layer and the path helpers, with no UI.

**Files.** `Models/Podcast.swift`, `Models/Episode.swift`,
`Models/PlaybackSession.swift`, `Storage/EpisodeStore.swift`,
`App/CueApp.swift` (attach `.modelContainer`)

**Tasks.**

1. Implement the three models exactly as specified in spec §4, including the
   `#Unique` constraints and cascade rules.
2. `EpisodeStore` per spec §5, splitting resolution from provisioning:
   `episodesDirectory()` composes the path and resolves a relative filename to an
   absolute URL on demand without touching disk; `prepareEpisodesDirectory()`
   creates the directory and sets `isExcludedFromBackup`, and is called once at
   launch from `CueApp.init()`.
3. Derived helpers: `Episode.duration`, `Episode.currentPosition`,
   `Episode.isDownloaded` (checks disk, not just the column).

**Acceptance.** Tests: inserting and fetching each model round-trips; deleting a
`Podcast` cascades its `Episode` rows; deleting an `Episode` cascades its
sessions; `prepareEpisodesDirectory()` creates the directory and the
backup-exclusion flag reads back as set, while `episodesDirectory()` leaves the
file system untouched; `isDownloaded` is false when the column is populated but
the file is absent.

**Commit.** `feat: swiftdata models and episode storage paths`

---

## 2 Feed parsing

**Goal.** RSS in, structured episodes out. Pure logic, fully testable.

**Files.** `Feed/FeedParser.swift`, `Feed/ParsedFeed.swift`,
`Feed/DurationParser.swift`

**Tasks.**

1. `XMLParser` delegate producing a `ParsedFeed` value type — not SwiftData
   models. Keep parsing free of persistence so it can be tested in isolation.
2. Field mapping per spec §6, including fallbacks.
3. `itunes:duration` across `SS`, `MM:SS`, `HH:MM:SS`; nil on anything else.
4. RFC 822 date parsing, tolerant of the several formats feeds use in practice.
5. Items with no `enclosure` are skipped, not fatal.
6. Zero parsed episodes surfaces a typed error naming the URL.

**Acceptance.** Tests against every fixture from 0.6. Parameterised test over the
duration formats. `malformed.rss` produces an error rather than a crash.
`no-enclosures.rss` yields a feed with zero episodes and no error.

**Commit.** `feat: rss feed parser`

---

## 3 Add feed by URL, and the library

**Goal.** First interactive milestone. Paste a URL, see episodes.

**Files.** `Feed/FeedService.swift`, `Views/LibraryView.swift`,
`Views/AddFeedView.swift`, `Views/PodcastDetailView.swift` — plus whatever view
logic those screens push out into free functions under `Views/`, which is where
anything assertable has to live (see `AGENTS.md`).

**Tasks.**

1. `FeedService.add(urlString:)` — fetch, parse, persist `Podcast` + `Episode`
   rows, deduplicating on `feedURL` and `guid`.
2. `FeedService.refresh(_:)` — additive per spec §6. Never deletes local
   episodes, never touches `isPlayed`, `localFilename`, or sessions.
3. Library list with pull-to-refresh and an add-feed sheet.
4. Podcast detail: episodes newest first, with date and duration.

**Acceptance.** Add a public feed → episodes appear correctly (spec AC 1). Add the
Boosty feed → episodes appear (first half of AC 2). Refresh twice → no
duplicates. Manually mark an episode played, refresh, confirm the flag survives.

**Commit.** `feat: add feeds by url and browse episodes`

---

## 4 Downloads

**Goal.** Episodes on disk, with state that survives termination.

**Files.** `Download/DownloadManager.swift`, `Views/DownloadsView.swift`

**Tasks.**

1. `URLSession` background configuration, single shared identifier, serial queue.
2. On completion: move from the temp location into `Episodes/`, then write
   `localFilename` and `downloadedAt`. Never before the move succeeds.
3. Read true duration from `AVURLAsset`, store as `assetDuration`.
4. Delete clears the download columns and removes the file, leaving `isPlayed`
   and sessions untouched.
5. Downloads view filters on file presence only — never on played state.
6. Surface the HTTP status code on failure. This is what makes a Boosty 403
   diagnosable rather than a silent nothing.

**Acceptance.** Download completes and the file exists (spec AC 2). Background the
app mid-download → it completes. Delete a download → played state and session
history survive (AC 9). Mark an episode played → it stays in Downloads with its
file (AC 8).

**Commit.** `feat: background episode downloads`

---

## 4.5 Download diagnosability and transfer visibility

**Goal.** Make every background transfer observable, actionable and bounded,
including plain-http feeds and enclosures.

**Files.** `Support/Info.plist`, `Download/BackgroundDownloader.swift`,
`Download/BackgroundDownloaderDelegate.swift`, `Download/DownloadManager.swift`,
`Download/DownloadAttempts.swift`, `Download/DownloadProgress.swift`,
`Download/DownloadQueue.swift`, `Download/DownloadRelaunch.swift`,
`Views/DownloadsView.swift`, `Views/ActiveDownloadFormatting.swift`,
`Views/PodcastDetailView.swift`

**Tasks.**

1. Allow arbitrary HTTP loads so user-supplied plain-http feeds and enclosures
   are not rejected by ATS.
2. Report byte progress as waiting, determinate or indeterminate state, kept in
   memory and guarded by the live transfer attempt.
3. Keep a safe failure message on failed rows, including background completions,
   without rendering a raw error description or credential-bearing enclosure URL.
4. Let the user cancel queued, active and adopted transfers by episode guid, and
   bound abandoned transfers with a two-hour resource timeout.
5. Show all in-flight and failed transfers in an Active Transfers section on the
   Downloads tab, with progress, cancel, failure detail and retry actions; the
   podcast detail rows gain the same progress, cancel and failure detail.
6. Split the two download files that sat against the 400-line `file_length`
   limit by topic, before any behaviour change.

**Acceptance.** A plain-http enclosure can download. A transfer visibly moves
from waiting to byte progress, can be cancelled even after relaunch, and surfaces
a safe actionable failure. The Downloads tab shows every active or failed
transfer while its completed list remains based on file presence only.

**Commit.** `feat(downloads): progress, failure detail and cancel`

---

## 5 Playback

**Goal.** Audio plays from local files, offline, with correct lock-screen
behaviour.

**Files.** `Playback/PlaybackEngine.swift`, `Playback/NowPlayingController.swift`,
`Views/PlayerView.swift`

**Tasks.**

1. `AVPlayer` over the local file URL. **No network call on this path.**
2. `AVAudioSession` category `.playback`, mode `.spokenAudio`, activated on play.
3. `MPNowPlayingInfoCenter` populated and updated on play, pause, seek, rate
   change.
4. `MPRemoteCommandCenter` per spec §8 — scrubber and skip commands explicitly
   **disabled**. This is a requirement, not an omission; do not "fix" it.
5. Rate control 1.0×–2.0× with `audioTimePitchAlgorithm = .timeDomain`.
6. In-app progress slider is enabled. Only the lock-screen scrubber is disabled.

**Acceptance.** Download, enable airplane mode, force-quit, relaunch, play — no
spinner, no error (spec AC 4). Lock the screen: scrubber and skip absent or
inert, play/pause works (AC 10). Rate changes take effect without pitch shift.

**Commit.** `feat: local playback with now playing integration`

---

## 6 Session log

**Goal.** The feature the app exists for.

**Files.** `Playback/SessionRecorder.swift`, plus `PlaybackEngine` integration

**Tasks.**

1. Open a session on play from stopped or paused.
2. Close on pause, manual seek, episode switch, rate change, end of file, and app
   termination. **Not** on backgrounding — audio continues, the session is live.
3. A manual seek closes the current session and opens a new one at the target.
4. Heartbeat via `addPeriodicTimeObserver` at 10s, writing `endPosition`.
5. On launch, close any session with `endedAt == nil`. Never leave more than one
   live session in the store.

**Acceptance.** Play 5m, pause, play, pause → two sessions with contiguous
positions (spec AC 5). Seek forward mid-playback → pre-seek session retains its
original end, new session starts at the target (AC 6). Force-quit mid-playback →
position within 10s of actual, no live session remains (AC 12).

**Commit.** `feat: append-only playback session log`

---

## 7 History and revert

**Goal.** The user-facing half of step 6.

**Files.** `Views/HistoryView.swift`

**Tasks.**

1. Sessions for the current episode, newest first, formatted per spec §9.
2. Tap a row → seek to `startPosition`. That seek closes the current session and
   opens a new one, so reverting is itself recorded and reversible.

**Acceptance.** The sleep scenario from spec AC 7: play to the end while asleep,
open History, tap the session before the long one, land where you left off.

**Commit.** `feat: session history with revert`

---

## 8 Played state and sleep timer

**Goal.** Completion tracking and the preventive half of the sleep problem.

**Files.** `Playback/PlaybackEngine.swift`, `Playback/SleepTimer.swift`

**Tasks.**

1. Mark played on `AVPlayerItemDidPlayToEndTime` or manual toggle. **No
   percentage threshold.**
2. Manual toggle works both directions, always available.
3. Sleep timer: 5/10/15/30/45/60 minutes and end-of-episode. On expiry, pause —
   which closes the session through the normal path — and deactivate the audio
   session.

**Acceptance.** Play to the end → marked played, file retained (spec AC 8). Set a
5-minute timer → stops at 5 minutes with the session correctly closed (AC 11).
Toggle played off and on → no side effects on downloads or sessions.

**Commit.** `feat: played state and sleep timer`

---

## 9 Reconciliation sweep

**Goal.** Self-healing storage.

**Files.** `Storage/Reconciler.swift`, called from app launch

**Tasks.**

1. Dangling rows: `localFilename` set but file absent → clear the download
   columns, leave played state and sessions alone.
2. Orphaned files: any file in `Episodes/` not referenced by an `Episode` → delete.
3. Podcast and episode deletion still remove files eagerly. The sweep is a
   backstop, not the mechanism.

**Acceptance.** Drop an unreferenced file into `Episodes/`, relaunch → deleted
(spec AC 14). Delete a podcast with downloads → files removed, disk usage drops
(AC 15). Simulate a restore by deleting `Episodes/` contents with the store
intact → rows self-correct, no crash (AC 13).

**Commit.** `feat: storage reconciliation on launch`

---

## 10 OPML import and mini-player

**Goal.** Make the library portable in, and playback reachable from anywhere.

**Files.** `Feed/OPMLParser.swift`, `Views/MiniPlayerView.swift`

**Tasks.**

1. `.fileImporter`, parse `<outline>` elements with `xmlUrl`, add each skipping
   duplicates, fetch sequentially, report added/skipped/failed.
2. Persistent mini-player above the tab bar whenever something is loaded.

**Acceptance.** Import an Overcast OPML export → all feeds added with an accurate
count (spec AC 3). Duplicate entries are skipped, not duplicated. Mini-player
appears on load and drives play/pause.

**Commit.** `feat: opml import and mini player`

---

# Milestones

**Usable** — after step 6. Feeds, downloads, offline playback, and a session log
that survives falling asleep. Everything before this is required; everything after
is convenience.

**Complete v1** — after step 10, with all 15 acceptance criteria in spec §13
passing by hand.

# Deferred

Not in this roadmap by design. See spec §2 for the full list. The nearest
candidates for a v1.1: background feed refresh, chapter support, and a real visual
design pass.
