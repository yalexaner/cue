import Foundation
import SwiftData
import Testing

@testable import cue

/// The measured-duration half of the finish path: `assetDuration` is written
/// from the downloaded file when it can be read, and its absence is never
/// allowed to fail a download.
///
/// No audio fixture is committed, so every case here goes through bytes the
/// asset reader cannot make sense of — which is exactly the path that has to
/// stay non-fatal. Split off `DownloadManagerTests` to keep both files under the
/// `file_length` warning that `--strict` turns into an error.
@MainActor
struct DownloadManagerDurationTests {
    private static let enclosureURL = "https://example.com/audio/1.mp3"

    private func makeEpisode(in context: ModelContext, guid: String = "guid-1") throws -> Episode {
        let podcast = Podcast(feedURL: testFeedURL, title: "Show")
        context.insert(podcast)
        let episode = Episode(guid: guid, title: "Episode", enclosureURL: Self.enclosureURL)
        episode.podcast = podcast
        context.insert(episode)
        try context.save()
        return episode
    }

    /// Decision 12: an unreadable duration is not a failed download.
    @Test func nonAudioBytesCompleteTheDownloadWithNoAssetDuration() async throws {
        try await withTemporaryBaseAsync { base in
            let context = try makeContext()
            let store = EpisodeStore(baseDirectory: base)
            let episode = try makeEpisode(in: context)
            episode.feedDuration = 1800
            let stub = DownloadTransportStub(data: Data("not audio".utf8), stagingDirectory: base)
            let manager = DownloadManager(context: context, store: store, transport: stub.transport)

            try await manager.download(episode)

            let filename = try #require(episode.localFilename)
            try #expect(store.fileExists(forRelativeFilename: filename) == true)
            #expect(episode.downloadedAt != nil)
            #expect(episode.assetDuration == nil)
            // the feed's value is what a consumer sees while nothing better exists
            #expect(episode.duration == 1800)

            let fresh = ModelContext(context.container)
            var descriptor = FetchDescriptor<Episode>(predicate: #Predicate { $0.guid == "guid-1" })
            descriptor.fetchLimit = 1
            let persisted = try #require(try fresh.fetch(descriptor).first)
            #expect(persisted.assetDuration == nil)
            #expect(persisted.localFilename == filename)
        }
    }

    /// A failed move leaves the episode untouched, measurement included — the
    /// read happens after the move, from the moved file, or not at all.
    @Test func aFailedMoveLeavesAnExistingAssetDurationAlone() async throws {
        try await withTemporaryBaseAsync { base in
            let context = try makeContext()
            let store = EpisodeStore(baseDirectory: base)
            let episode = try makeEpisode(in: context)
            episode.assetDuration = 42
            try context.save()
            let manager = DownloadManager(
                context: context, store: store, transport: missingFileTransport(in: base))

            await #expect(throws: (any Error).self) { try await manager.download(episode) }

            #expect(episode.assetDuration == 42)
            #expect(episode.localFilename == nil)
            #expect(episode.downloadedAt == nil)
        }
    }

    @Test func aDurationThatCannotBeReadAnswersNilRatherThanThrowing() async throws {
        try await withTemporaryBaseAsync { base in
            let missing = base.appending(path: "no-such-file.mp3", directoryHint: .notDirectory)
            #expect(await DownloadManager.assetDuration(at: missing) == nil)

            let garbage = base.appending(path: "garbage.mp3", directoryHint: .notDirectory)
            try Data("not audio".utf8).write(to: garbage)
            #expect(await DownloadManager.assetDuration(at: garbage) == nil)
        }
    }
}
