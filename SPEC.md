# Podcast Player — v1 Specification

A single-user iOS podcast client. Built to fix three specific failures of existing
clients: lossy playback position, broken private feeds, and unplayable local
downloads when the network is unavailable.

---

## 1. Goals

1. **Non-destructive playback position.** Every listening session is recorded. The
   user can look at the history for an episode and jump back to where any earlier
   session began. Falling asleep must never destroy the position from before.
2. **Private feeds work.** Feeds are fetched directly from the origin server. No
   proxy, no server-side component, no account.
3. **Offline is the primary case.** A downloaded episode plays with the device in
   airplane mode, always. Network state must not be consulted on the playback path.

## 2. Non-Goals (v1)

Explicitly out of scope. Do not implement, do not scaffold for:

- Podcast directory / search. Feeds are added by pasted URL or OPML import.
- Streaming playback. Download-then-play only.
- CloudKit, iCloud sync, any multi-device support.
- Chapters, Smart Speed / silence trimming, volume boost, transcripts.
- Playlists, queue, up-next, auto-download rules.
- iPad, Mac, watchOS, CarPlay, widgets, Shortcuts.
- Custom visual design. System defaults, stock SwiftUI components.
- Any shared/extractable playback framework. Single app target.

## 3. Platform

- iOS 26, iPhone only, portrait only.
- SwiftUI, SwiftData, AVFoundation.
- No third-party dependencies. Feed parsing uses `XMLParser` from Foundation.
- Single device, single user, no backward compatibility burden.

Required capabilities: **Background Modes → Audio, AirPlay, and Picture in Picture.**

---

## 4. Data Model

```swift
import SwiftData
import Foundation

@Model
final class Podcast {
    #Unique<Podcast>([\.feedURL])

    var feedURL: String          // stored verbatim, may contain auth token
    var title: String
    var author: String?
    var summary: String?
    var artworkURL: String?
    var addedAt: Date
    var lastRefreshedAt: Date?

    @Relationship(deleteRule: .cascade, inverse: \Episode.podcast)
    var episodes: [Episode] = []

    init(feedURL: String, title: String) {
        self.feedURL = feedURL
        self.title = title
        self.addedAt = .now
    }
}

@Model
final class Episode {
    #Unique<Episode>([\.guid])

    var guid: String             // RSS <guid>, fallback to enclosure URL
    var title: String
    var summary: String?
    var publishedAt: Date?
    var enclosureURL: String
    var feedDuration: TimeInterval?   // from <itunes:duration>; unreliable
    var assetDuration: TimeInterval?  // from AVAsset after download; authoritative

    // Download state — independent of played state
    var localFilename: String?   // RELATIVE. e.g. "3F2A....mp3". Never absolute.
    var downloadedAt: Date?

    // Played state — independent of download state
    var isPlayed: Bool = false
    var playedAt: Date?

    var podcast: Podcast?

    @Relationship(deleteRule: .cascade, inverse: \PlaybackSession.episode)
    var sessions: [PlaybackSession] = []
}

@Model
final class PlaybackSession {
    var startedAt: Date
    var endedAt: Date?           // nil = session is live
    var startPosition: TimeInterval
    var endPosition: TimeInterval
    var rate: Double
    var episode: Episode?
}
```

### Derived values

- `Episode.duration` → `assetDuration ?? feedDuration`. Prefer the asset.
- `Episode.currentPosition` → `endPosition` of the session with the latest
  `startedAt`, else `0`. **There is no stored position field.** Position is always
  derived from the session log.
- `Episode.isDownloaded` → `localFilename != nil` **and** the file exists on disk.
  Check both; a restore can leave dangling rows.

### Critical invariant

`isPlayed` and `localFilename` are orthogonal. Neither is ever inferred from the
other. Marking an episode played must not delete the file. Deleting the file must
not mark the episode played. This is the specific bug being designed out.

---

## 5. File Storage

Directory: `Application Support/Episodes/`

- Created on first launch with `withIntermediateDirectories: true`.
- Marked `isExcludedFromBackup = true` on the directory. Podcast audio is
  re-downloadable and must not bloat device backups.
- **Not** `Caches/` — iOS evicts that under storage pressure, which reintroduces
  the exact failure mode this app exists to avoid.

Filename: `UUID().uuidString` + extension inferred from the enclosure URL path
(fallback `.mp3`).

The database stores the filename only. The absolute URL is rebuilt at every access:

```swift
func episodesDirectory() throws -> URL {
    let base = try FileManager.default.url(
        for: .applicationSupportDirectory,
        in: .userDomainMask,
        appropriateFor: nil,
        create: true
    )
    return base.appending(path: "Episodes", directoryHint: .isDirectory)
}
```

Rationale: the app container path contains a UUID that can change on reinstall and
restore. Persisting an absolute path guarantees breakage.

### Reconciliation sweep

Run once at launch, after the model container is ready. Cheap enough to always run.

1. **Dangling rows** — for every `Episode` with a non-nil `localFilename` whose
   file is absent from disk, clear `localFilename` and `downloadedAt`. Leave
   `isPlayed` and all sessions untouched. Expected after a device restore, since
   the audio directory is excluded from backup while the SwiftData store is not.
2. **Orphaned files** — build the set of filenames referenced by any `Episode`,
   list the contents of `Episodes/`, and delete every file not in that set.

Case 2 is the one that actually reclaims disk. It catches two failure modes:
a download that landed on disk before a crash prevented the SwiftData commit, and
files left behind when a `Podcast` deletion cascades its `Episode` rows away
without anyone removing the audio.

Podcast and episode deletion should still remove files eagerly — the sweep is a
backstop, not the primary mechanism.

---

## 6. Feeds

### Parsing

`XMLParser`, RSS 2.0 plus the `itunes` namespace.

| Field | Source |
|---|---|
| Podcast title | `/rss/channel/title` |
| Podcast author | `itunes:author`, fallback `managingEditor` |
| Podcast artwork | `itunes:image[@href]`, fallback `/rss/channel/image/url` |
| Episode guid | `item/guid`, fallback `enclosure[@url]` |
| Episode title | `item/title` |
| Episode date | `item/pubDate` (RFC 822) |
| Episode audio | `item/enclosure[@url]` |
| Episode duration | `itunes:duration` — accepts `SS`, `MM:SS`, `HH:MM:SS` |

Atom feeds are out of scope. If parsing yields zero episodes, surface an error
naming the URL rather than adding an empty podcast.

### Private feeds

The feed URL is stored and requested verbatim, including any embedded token
(the Boosty case). Enclosure URLs from such feeds are also expected to be
pre-signed and are requested as-is.

If enclosure downloads return 401/403 while the feed itself fetches successfully,
that assumption is wrong and a `FeedCredential` type is needed. Surface the HTTP
status code in the download error so this is diagnosable rather than a silent
failure.

### Refresh

Manual only in v1 — pull-to-refresh on the podcast list (refreshes all) and on a
podcast detail view (refreshes one). No background refresh.

Refresh is additive: match on `guid`, insert new episodes, update mutable metadata
on existing ones. **Never** delete local episodes because they fell out of the
feed window, and never touch `isPlayed`, `localFilename`, or sessions on refresh.

### OPML import

Import via `.fileImporter`. Parse `<outline>` elements carrying `xmlUrl`. Add each
as a podcast, skipping duplicates by URL, then fetch each feed sequentially.
Report a summary: added / skipped / failed.

This exists so the initial library can be moved over from Overcast without typing
feed URLs by hand.

---

## 7. Downloads

- `URLSession` with a **background** configuration, single shared identifier.
- Download to the session's temp location, then move into `Episodes/`. Only after
  a successful move are `localFilename` and `downloadedAt` written.
- After the move, read the true duration from `AVURLAsset` and store it in
  `assetDuration`.
- Serial queue, one active download at a time. Sufficient for one user.
- Manual trigger only. Tap an episode → Download. No auto-download rules.
- Transfer progress is in-memory and has three visible states: waiting for the
  first byte, determinate when the total size is known, and indeterminate when
  bytes are arriving without a known total. Progress belongs to one registered
  transfer attempt; a delayed update from an older attempt must be ignored.
- A transfer can be cancelled while queued, active, or adopted after relaunch.
  Cancellation is addressed by episode guid because an adopted transfer has no
  in-process task handle. A two-hour resource timeout bounds abandoned transfers.
- A failed transfer keeps a safe user-facing message and offers retry. HTTP
  failures name the status and at most the enclosure URL's scheme and host;
  arbitrary error descriptions are never rendered because they may contain a
  private-feed credential.
- Delete clears `localFilename` and `downloadedAt`, removes the file, and leaves
  `isPlayed` and all sessions untouched.

The Downloads view begins with an Active Transfers section containing every
in-flight and failed transfer, with progress, cancel, failure detail, and retry.
Below it, the completed-download list contains episodes where
`isDownloaded == true`; that list filters on file presence **only** — never on
played state. Transfer and failure state are not persisted in SwiftData.

---

## 8. Playback

### Engine

`AVPlayer` with an `AVPlayerItem` built from the local file URL. The playback path
must not perform any network request or reachability check.

Audio session: category `.playback`, mode `.spokenAudio`, activated on play.
`.spokenAudio` gives correct ducking and route behavior for speech content.

### Now Playing / remote commands

Populate `MPNowPlayingInfoCenter` with title, podcast title, artwork, duration,
elapsed time, and playback rate. Update on play, pause, seek, and rate change.

`MPRemoteCommandCenter` configuration:

```swift
let c = MPRemoteCommandCenter.shared()
c.playCommand.isEnabled = true
c.pauseCommand.isEnabled = true
c.changePlaybackPositionCommand.isEnabled = false  // deliberate
c.skipForwardCommand.isEnabled = false             // deliberate
c.skipBackwardCommand.isEnabled = false            // deliberate
```

The scrubber and skip buttons are disabled on the lock screen **on purpose**, to
make it impossible to lose position by accident through a pocket touch. This is a
requirement, not an oversight.

### Speed

Rate control in-app: 1.0×, 1.25×, 1.5×, 1.75×, 2.0×. Set
`audioTimePitchAlgorithm = .timeDomain` for intelligible speech at speed.

---

## 9. Session Tracking

The core feature. An append-only log; positions are never overwritten in place.

### A session opens when

- Playback starts from a stopped or paused state.

`startPosition` is the position playback begins from. `rate` is the rate at open.

### A session closes when

| Trigger | Note |
|---|---|
| Pause | |
| Manual seek | The seek target opens a new session immediately |
| Episode switch | |
| Playback rate change | Keeps `rate` meaningful per session |
| Reaching end of file | |
| App termination | Via the last heartbeat write |

A session does **not** close on backgrounding or screen lock — audio continues,
so the session is still live.

Note that manual seek closing a session is what makes revert work: a seek is
precisely the discontinuity the user may want to jump back across.

### Heartbeat

`addPeriodicTimeObserver` at 10s intervals writes `endPosition` on the live
session. Without this, a force-quit or crash leaves a session with a stale end.

On launch, any session with `endedAt == nil` is closed by setting `endedAt` to its
last modification. Never leave more than one live session in the store.

### Revert UI

On the episode view, a "History" section lists that episode's sessions,
newest first:

```
14:32 → 51:08   today, 22:10   (36m)
02:15 → 14:32   today, 21:47   (12m)
00:00 → 02:15   yesterday      (2m)
```

Tapping a row seeks to that session's `startPosition`. That seek closes the
current session and opens a new one, so reverting is itself recorded and
reversible.

---

## 10. Played State

- Marked played when `AVPlayerItemDidPlayToEndTime` fires, or by manual toggle.
- **No percentage threshold.** `itunes:duration` is frequently wrong and players
  routinely stop short of the nominal end; the end-of-item notification is the
  only reliable signal.
- Manual toggle works in both directions and is always available.
- Marking played does not delete the file, does not clear sessions, and does not
  remove the episode from the Downloads list.

---

## 11. Sleep Timer

Options: 5, 10, 15, 30, 45, 60 minutes, and "end of episode".

On expiry: pause playback (which closes the session normally) and deactivate the
audio session. Fade the last 5 seconds if trivial to do; otherwise a hard pause is
acceptable.

Included in v1 because it prevents the problem the session log cures after the
fact.

---

## 12. Screens

Five screens, stock components throughout.

1. **Library** — list of podcasts, artwork + title. Pull to refresh. Toolbar: add
   feed (URL paste), import OPML.
2. **Podcast detail** — episode list, newest first. Per row: title, date, duration,
   and state indicators for downloading (waiting, or progress), downloaded,
   failed (tap for the failure detail) and played. Actions: download, cancel
   download, delete download, mark played/unplayed, play.
3. **Player** — artwork, title, elapsed/remaining, progress slider (enabled
   in-app; only the lock-screen scrubber is disabled), play/pause, ±30s, rate
   picker, sleep timer, link to history.
4. **History** — session list for the current episode, tap to revert.
5. **Downloads** — an Active Transfers section for every in-flight or failed
   transfer, with progress, cancel, failure detail, and retry; followed by every
   episode with a local file, grouped by podcast, with total disk usage. The
   completed list is filtered on file presence only.

A persistent mini-player above the tab bar when something is loaded.

---

## 13. Acceptance Criteria

Each is independently verifiable and should be checked by hand before v1 is
considered done.

1. Add a public feed by URL → episodes appear with correct titles and dates.
2. Add the Boosty feed by URL → episodes appear; download one → it completes.
3. Import an OPML export from Overcast → all feeds added, count reported.
4. Download an episode, enable airplane mode, force-quit, relaunch → the episode
   plays. No spinner, no error, no delay.
5. Play 5 minutes, pause, play again, pause → two sessions recorded with
   contiguous positions.
6. Play, seek forward manually, play on → the pre-seek session is preserved with
   its original end position, and a new session starts at the seek target.
7. Play until sleep, wake with the episode at the end → History shows the last
   session; tapping the row before it returns to where consciousness was lost.
8. Mark an episode played → it remains in Downloads with its file intact.
9. Delete a download → the episode's played state and full session history remain.
10. Play with the phone locked → the lock-screen scrubber and skip controls are
    absent or inert; play/pause works.
11. Set a 5-minute sleep timer → playback stops at 5 minutes and the session is
    closed with the correct end position.
12. Force-quit mid-playback, relaunch → position is at most 10 seconds behind
    where audio actually stopped, and no live session remains open.
13. Delete the app, reinstall, restore → known limitation: local files are gone.
    The app must not crash or show dangling downloaded-state rows. `isDownloaded`
    checks disk, so rows self-correct.
14. Drop an unreferenced file into `Episodes/` by hand, relaunch → the file is
    deleted by the sweep and Downloads disk usage is unchanged.
15. Delete a podcast that has downloaded episodes → the audio files are removed
    and total disk usage drops accordingly.

---

## 14. Build Order

1. SwiftData models + storage directory helper.
2. Feed parser + add-by-URL. Verify against a public feed and the Boosty feed.
3. Episode list UI.
4. Background downloader + Downloads view.
5. Playback engine, audio session, remote commands.
6. Session log + heartbeat.
7. History view + revert.
8. Sleep timer.
9. OPML import.
10. Mini-player.

Steps 1–6 constitute the minimum usable app. Everything after is convenience.

---

## 15. Known Constraints

- **Signing.** Builds are intentionally unsigned (`CODE_SIGNING_ALLOWED=NO`).
  Installation is handled by an external re-signing service with its own
  certificate; the Mac holds no signing identity, and the free-account 7-day
  expiry does not apply to this workflow.
- **No sync.** Single device by design. Listening history exists only on the
  phone and is not in iCloud backup (the audio directory is excluded, but the
  SwiftData store is not, so sessions do survive a device restore even though
  the audio files do not).
