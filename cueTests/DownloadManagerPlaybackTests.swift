import Foundation
import Testing

@testable import cue

@MainActor
struct DownloadManagerPlaybackTests {
    @Test func replacementUnloadsPlaybackBeforePublishingTransferState() async throws {
        try await withTemporaryBaseAsync { base in
            let context = try makeContext()
            let podcast = Podcast(feedURL: testFeedURL, title: "Show")
            let episode = Episode(
                guid: "guid-1",
                title: "Episode",
                enclosureURL: "https://example.com/audio/1.mp3"
            )
            episode.localFilename = "old.mp3"
            episode.downloadedAt = .now
            episode.podcast = podcast
            context.insert(podcast)
            context.insert(episode)
            try context.save()

            let store = EpisodeStore(baseDirectory: base)
            try store.prepareEpisodesDirectory()
            try installRejectedAudio(named: "old.mp3", in: store, base: base)
            let playback = PlaybackEngine()
            try playback.play(episode, store: store)
            let stub = DownloadTransportStub(stagingDirectory: base)
            var downloads: DownloadManager?
            var preparationCount = 0
            downloads = DownloadManager(
                context: context,
                store: store,
                transport: stub.transport,
                prepareForFileMutation: { guid in
                    if preparationCount == 0 {
                        #expect(playback.episodeGUID == episode.guid)
                        #expect(downloads?.state(for: episode) == nil)
                    } else {
                        #expect(playback.episodeGUID == nil)
                        #expect(downloads?.state(for: episode)?.isDownloading == true)
                    }
                    preparationCount += 1
                    playback.unload(ifGUID: guid)
                }
            )
            let manager = try #require(downloads)

            try await manager.download(episode)

            #expect(playback.episodeGUID == nil)
            #expect(preparationCount == 2)
            let replacement = try #require(episode.localFilename)
            #expect(replacement != "old.mp3")

            // committed, not merely pending
            let persisted = try #require(try persistedEpisode(guid: "guid-1", in: context))
            #expect(persisted.localFilename == replacement)
        }
    }

    @Test func deletingADownloadUnloadsPlaybackBeforeTheFileGoesAway() async throws {
        try await withTemporaryBaseAsync { base in
            let context = try makeContext()
            let podcast = Podcast(feedURL: testFeedURL, title: "Show")
            let episode = Episode(
                guid: "guid-1",
                title: "Episode",
                enclosureURL: "https://example.com/audio/1.mp3"
            )
            episode.localFilename = "old.mp3"
            episode.downloadedAt = .now
            episode.podcast = podcast
            context.insert(podcast)
            context.insert(episode)
            try context.save()

            let store = EpisodeStore(baseDirectory: base)
            try store.prepareEpisodesDirectory()
            try installRejectedAudio(named: "old.mp3", in: store, base: base)
            let playback = PlaybackEngine()
            try playback.play(episode, store: store)
            let stub = DownloadTransportStub(stagingDirectory: base)
            var preparedGUIDs: [String] = []
            let manager = DownloadManager(
                context: context,
                store: store,
                transport: stub.transport,
                prepareForFileMutation: { guid in
                    // the columns are already cleared, but the file must still
                    // be there: an unload after the removal is the forbidden order
                    #expect((try? store.fileExists(forRelativeFilename: "old.mp3")) == true)
                    preparedGUIDs.append(guid)
                    playback.unload(ifGUID: guid)
                }
            )

            try manager.deleteDownload(for: episode)

            #expect(preparedGUIDs == ["guid-1"])
            #expect(playback.episodeGUID == nil)
            #expect(try store.fileExists(forRelativeFilename: "old.mp3") == false)
            #expect(episode.localFilename == nil)

            // committed, not merely pending
            let persisted = try #require(try persistedEpisode(guid: "guid-1", in: context))
            #expect(persisted.localFilename == nil)
        }
    }
}
