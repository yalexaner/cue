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
}
