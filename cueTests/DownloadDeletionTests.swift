import Foundation
import SwiftData
import Testing

@testable import cue

/// The deletion branches `DownloadManagerTests` has no room left for.
///
/// Its own file rather than more cases there: that suite sits against the
/// 400-line `file_length` warning `--strict` turns into an error.
@MainActor
struct DownloadDeletionTests {
    private func makeEpisode(in context: ModelContext) throws -> Episode {
        let podcast = Podcast(feedURL: testFeedURL, title: "Show")
        context.insert(podcast)
        let episode = Episode(
            guid: "guid-1", title: "Episode", enclosureURL: "https://example.com/audio/1.mp3")
        episode.podcast = podcast
        context.insert(episode)
        try context.save()
        return episode
    }

    /// A `downloadedAt` with no file behind it is still a write, and one left
    /// pending for autosave is a write a context-wide `rollback()` elsewhere can
    /// discard — so it is committed here, not merely assigned. Deleting the
    /// branch entirely leaves every other deletion case green.
    @Test func deleteClearsAnOrphanedDownloadedAtAndCommitsIt() async throws {
        try await withTemporaryBaseAsync { base in
            let context = try makeContext()
            let episode = try makeEpisode(in: context)
            episode.downloadedAt = Date(timeIntervalSince1970: 1)
            try context.save()
            let manager = DownloadManager(
                context: context, store: EpisodeStore(baseDirectory: base),
                transport: failingFileTransport())

            try manager.deleteDownload(for: episode)

            #expect(episode.downloadedAt == nil)
            let persisted = try #require(try persistedEpisode(guid: "guid-1", in: context))
            #expect(persisted.downloadedAt == nil)
        }
    }
}
