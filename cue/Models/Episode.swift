import Foundation
import SwiftData

@Model
final class Episode {
    #Unique<Episode>([\.guid])

    var guid: String  // RSS <guid>, fallback to enclosure URL
    var title: String
    var summary: String?
    var publishedAt: Date?
    var enclosureURL: String
    var feedDuration: TimeInterval?  // from <itunes:duration>; unreliable
    var assetDuration: TimeInterval?  // from AVAsset after download; authoritative

    // Download state — independent of played state
    var localFilename: String?  // RELATIVE. e.g. "3F2A....mp3". Never absolute.
    var downloadedAt: Date?

    // Played state — independent of download state
    var isPlayed: Bool = false
    var playedAt: Date?

    var podcast: Podcast?

    @Relationship(deleteRule: .cascade, inverse: \PlaybackSession.episode)
    var sessions: [PlaybackSession] = []

    init(guid: String, title: String, enclosureURL: String) {
        self.guid = guid
        self.title = title
        self.enclosureURL = enclosureURL
    }
}

// MARK: - Derived values (spec §4)

extension Episode {
    /// The asset's measured duration wins; the feed's `<itunes:duration>` is a fallback.
    var duration: TimeInterval? {
        assetDuration ?? feedDuration
    }

    /// Resume position, derived from the session log.
    ///
    /// There is no stored position field — the `endPosition` of the session with
    /// the latest `startedAt` is the position, `0` when nothing has been played.
    /// A SwiftData to-many relationship has no defined order, so the comparison
    /// is made total on `endPosition` — two sessions sharing a `startedAt` must
    /// not resolve to a different position between fetches.
    var currentPosition: TimeInterval {
        sessions.max {
            ($0.startedAt, $0.endPosition) < ($1.startedAt, $1.endPosition)
        }?.endPosition ?? 0
    }

    /// Marks the episode played or unplayed (spec §4).
    ///
    /// Played state is orthogonal to download state: this writes `isPlayed` and
    /// its timestamp and nothing else — marking an episode played never deletes
    /// the file, and unmarking it never restores one. `playedAt` follows the
    /// flag in both directions, so an unplayed episode carries no stale date.
    func setPlayed(_ played: Bool) {
        isPlayed = played
        playedAt = played ? .now : nil
    }

    /// Puts the played pair back exactly as a caller found it.
    ///
    /// `setPlayed(_:)` cannot undo itself: it derives `playedAt` from `.now`, so
    /// replaying the old flag would invent a new timestamp. A caller whose save
    /// failed needs the original pair restored verbatim, and the two fields
    /// still move together — that is the point of both methods.
    func restorePlayed(_ played: Bool, at date: Date?) {
        isPlayed = played
        playedAt = date
    }

    /// `localFilename` is set *and* the file is really on disk.
    ///
    /// Independent of `isPlayed`: this reads download state only, never played
    /// state, and reading it mutates neither those nor the file system.
    ///
    /// Throws when a stored filename cannot be resolved. Callers must not treat
    /// that as "not downloaded" — the reconciliation sweep clears download state
    /// on a `false`, so a swallowed error would wipe the library.
    ///
    /// The store is required, never defaulted: a default would resolve against
    /// the real Application Support, which a test must never touch.
    func isDownloaded(in store: EpisodeStore) throws -> Bool {
        guard let localFilename else { return false }
        return try store.fileExists(forRelativeFilename: localFilename)
    }

    /// What this episode's file occupies on disk, or `nil` when there is none.
    ///
    /// The one call for a size a screen has not already measured — the podcast
    /// detail list never scans the download directory, so a confirmation that
    /// names what is about to be deleted has to ask on demand.
    ///
    /// `nil` means positively no file: either no stored filename, or a file the
    /// store confirmed absent. Every other storage failure propagates, for the
    /// same reason `isDownloaded(in:)` throws — answering an unreadable file as
    /// zero bytes would tell the user a real download costs nothing.
    ///
    /// The store is required, never defaulted: a default would resolve against
    /// the real Application Support, which a test must never touch.
    func fileSize(in store: EpisodeStore) throws -> Int? {
        guard let localFilename else { return nil }
        return try store.fileSize(forRelativeFilename: localFilename)
    }
}
