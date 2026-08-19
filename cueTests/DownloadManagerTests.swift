import Foundation
import SwiftData
import Testing

@testable import cue

/// The download manager's fetch, finish and delete paths, over a stubbed
/// `FileTransport` and a temporary `Episodes/` directory — no test constructs a
/// real background session or touches the real Application Support.
@MainActor
struct DownloadManagerTests {
    private static let enclosureURL = "https://example.com/audio/1.mp3"

    private func makeEpisode(
        in context: ModelContext,
        guid: String = "guid-1",
        enclosureURL: String = DownloadManagerTests.enclosureURL
    ) throws -> Episode {
        let podcast = Podcast(feedURL: testFeedURL, title: "Show")
        context.insert(podcast)
        let episode = Episode(guid: guid, title: "Episode", enclosureURL: enclosureURL)
        episode.podcast = podcast
        context.insert(episode)
        try context.save()
        return episode
    }

    // MARK: - download

    @Test func downloadLandsTheFileAndWritesBothColumns() async throws {
        try await withTemporaryBaseAsync { base in
            let context = try makeContext()
            let store = EpisodeStore(baseDirectory: base)
            let episode = try makeEpisode(in: context)
            let stub = DownloadTransportStub(data: Data("audio".utf8), stagingDirectory: base)
            let manager = DownloadManager(context: context, store: store, transport: stub.transport)

            try await manager.download(episode)

            let filename = try #require(episode.localFilename)
            try #expect(store.fileExists(forRelativeFilename: filename) == true)
            try #expect(Data(contentsOf: store.url(forRelativeFilename: filename)) == Data("audio".utf8))
            #expect(episode.downloadedAt != nil)
            #expect(stub.requestedURLStrings == [Self.enclosureURL])
            #expect(manager.state(for: episode) == nil)

            // committed, not merely pending
            let stored = try persistedEpisode(guid: "guid-1", in: context)
            let persisted = try #require(stored)
            #expect(persisted.localFilename == filename)
            #expect(persisted.downloadedAt != nil)
        }
    }

    @Test func downloadRunsOneTransferAtATime() async throws {
        try await withTemporaryBaseAsync { base in
            let context = try makeContext()
            let store = EpisodeStore(baseDirectory: base)
            let first = try makeEpisode(in: context, guid: "guid-1")
            let second = try makeEpisode(in: context, guid: "guid-2")
            let stub = DownloadTransportStub(stagingDirectory: base)
            let manager = DownloadManager(context: context, store: store, transport: stub.transport)

            // `Task {}` rather than `async let`: it inherits this suite's main
            // actor, so the two `@Model` values are never sent anywhere
            let firstDownload = Task { try await manager.download(first) }
            let secondDownload = Task { try await manager.download(second) }
            try await firstDownload.value
            try await secondDownload.value

            #expect(stub.peakInFlight == 1)
            #expect(first.localFilename != nil)
            #expect(second.localFilename != nil)
            #expect(first.localFilename != second.localFilename)
        }
    }

    @Test func downloadRejectsAnEnclosureThatIsNotAnHTTPURL() async throws {
        try await withTemporaryBaseAsync { base in
            let context = try makeContext()
            let store = EpisodeStore(baseDirectory: base)
            let episode = try makeEpisode(in: context, enclosureURL: "file:///etc/passwd")
            let stub = DownloadTransportStub(stagingDirectory: base)
            let manager = DownloadManager(context: context, store: store, transport: stub.transport)

            await #expect(throws: DownloadManager.Failure.invalidEnclosureURL("file:///etc/passwd")) {
                try await manager.download(episode)
            }
            #expect(stub.requestedURLStrings.isEmpty)
            #expect(episode.localFilename == nil)
            let message = try #require(
                downloadErrorMessage(
                    for: DownloadManager.Failure.invalidEnclosureURL("file:///etc/passwd")))
            #expect(manager.state(for: episode) == .failed(message: message))
        }
    }

    /// The Boosty case: a token-rotated enclosure answers 403, and the status
    /// has to reach the message (spec §6).
    @Test func downloadSurfacesTheHTTPStatusAndWritesNothing() async throws {
        try await withTemporaryBaseAsync { base in
            let context = try makeContext()
            let store = EpisodeStore(baseDirectory: base)
            let episode = try makeEpisode(in: context)
            let stub = DownloadTransportStub(stagingDirectory: base)
            stub.serve(statusCode: 403)
            let manager = DownloadManager(context: context, store: store, transport: stub.transport)

            await #expect(throws: DownloadManager.Failure.httpStatus(403, Self.enclosureURL)) {
                try await manager.download(episode)
            }

            #expect(episode.localFilename == nil)
            #expect(episode.downloadedAt == nil)
            let message = try #require(
                downloadErrorMessage(
                    for: DownloadManager.Failure.httpStatus(403, Self.enclosureURL)))
            #expect(manager.state(for: episode) == .failed(message: message))
            let stored = try persistedEpisode(guid: "guid-1", in: context)
            let persisted = try #require(stored)
            #expect(persisted.localFilename == nil)
        }
    }

    @Test func downloadPropagatesATransportError() async throws {
        try await withTemporaryBaseAsync { base in
            let context = try makeContext()
            let store = EpisodeStore(baseDirectory: base)
            let episode = try makeEpisode(in: context)
            let manager = DownloadManager(
                context: context, store: store, transport: failingFileTransport())

            await #expect(throws: StubTransportError.offline) {
                try await manager.download(episode)
            }
            #expect(episode.localFilename == nil)
            let message = try #require(downloadErrorMessage(for: StubTransportError.offline))
            #expect(manager.state(for: episode) == .failed(message: message))
        }
    }

    /// Cancel dismisses the screen while the transfer may already be answered;
    /// the response winning the race is not consent.
    @Test func cancellationAfterTheTransportAnswersCommitsNothing() async throws {
        try await withTemporaryBaseAsync { base in
            let context = try makeContext()
            let store = EpisodeStore(baseDirectory: base)
            let episode = try makeEpisode(in: context)
            let stub = DownloadTransportStub(stagingDirectory: base)
            let manager = DownloadManager(context: context, store: store, transport: stub.transport)

            let task = Task { try await manager.download(episode) }
            // safe to arm after creating the task: its body cannot start until
            // this main-actor run suspends at the await below
            stub.whenAnswering { task.cancel() }

            await #expect(throws: CancellationError.self) { try await task.value }

            // pending state is only visible on the context that would have made
            // the write, so this assertion cannot move to a second context
            #expect(episode.localFilename == nil)
            #expect(episode.downloadedAt == nil)
            #expect(manager.state(for: episode) == nil)
            // and the file the transport already staged is gone: a cancelled
            // download must not leave a full episode behind in the temporary
            // directory, where nothing references it
            let staged = try FileManager.default
                .contentsOfDirectory(atPath: base.path(percentEncoded: false))
                .filter { $0.hasPrefix("staged-") }
            #expect(staged.isEmpty)
        }
    }

    @Test func aFailedMoveWritesNeitherColumn() async throws {
        try await withTemporaryBaseAsync { base in
            let context = try makeContext()
            let store = EpisodeStore(baseDirectory: base)
            let episode = try makeEpisode(in: context)
            let manager = DownloadManager(
                context: context, store: store, transport: missingFileTransport(in: base))

            await #expect(throws: (any Error).self) { try await manager.download(episode) }

            #expect(episode.localFilename == nil)
            #expect(episode.downloadedAt == nil)
            #expect(
                manager.state(for: episode)
                    == .failed(
                        message:
                            "The download file could not be read or written. Check available storage and try again."))
            let stored = try persistedEpisode(guid: "guid-1", in: context)
            let persisted = try #require(stored)
            #expect(persisted.localFilename == nil)
            #expect(persisted.downloadedAt == nil)
        }
    }

    @Test func aRedownloadReplacesThePreviousFile() async throws {
        try await withTemporaryBaseAsync { base in
            let context = try makeContext()
            let store = EpisodeStore(baseDirectory: base)
            let episode = try makeEpisode(in: context)
            let stub = DownloadTransportStub(stagingDirectory: base)
            let manager = DownloadManager(context: context, store: store, transport: stub.transport)

            try await manager.download(episode)
            let firstFilename = try #require(episode.localFilename)
            stub.serve(data: Data("fresher audio".utf8))
            try await manager.download(episode)

            let secondFilename = try #require(episode.localFilename)
            #expect(secondFilename != firstFilename)
            try #expect(store.fileExists(forRelativeFilename: firstFilename) == false)
            let url = try store.url(forRelativeFilename: secondFilename)
            try #expect(Data(contentsOf: url) == Data("fresher audio".utf8))
        }
    }

    // MARK: - finishDownload

    /// A background completion can arrive for an episode that is no longer
    /// there; relaunching the app to crash it is not an option.
    @Test func finishingAnUnknownGUIDIsIgnored() async throws {
        try await withTemporaryBaseAsync { base in
            let context = try makeContext()
            let store = EpisodeStore(baseDirectory: base)
            let manager = DownloadManager(
                context: context, store: store, transport: failingFileTransport())
            let staged = base.appending(path: "staged.tmp", directoryHint: .notDirectory)
            try Data("audio".utf8).write(to: staged)

            await #expect(throws: Never.self) {
                try await manager.finishDownload(tempURL: staged, response: nil, forGUID: "no-such-guid")
            }
            #expect(!FileManager.default.fileExists(atPath: staged.path(percentEncoded: false)))
        }
    }

    // MARK: - deleteDownload

    /// AC 9: deleting a download keeps played state and the session log.
    @Test func deleteClearsTheColumnsAndPreservesPlayedStateAndSessions() async throws {
        try await withTemporaryBaseAsync { base in
            let context = try makeContext()
            let store = EpisodeStore(baseDirectory: base)
            let episode = try makeEpisode(in: context)
            let stub = DownloadTransportStub(stagingDirectory: base)
            let manager = DownloadManager(context: context, store: store, transport: stub.transport)
            try await manager.download(episode)
            let filename = try #require(episode.localFilename)

            episode.setPlayed(true)
            let playedAt = episode.playedAt
            let session = PlaybackSession(startedAt: .now, startPosition: 0, endPosition: 42, rate: 1)
            session.episode = episode
            context.insert(session)
            try context.save()

            try manager.deleteDownload(for: episode)

            #expect(episode.localFilename == nil)
            #expect(episode.downloadedAt == nil)
            try #expect(store.fileExists(forRelativeFilename: filename) == false)
            #expect(episode.isPlayed)
            #expect(episode.playedAt == playedAt)
            #expect(episode.sessions.count == 1)
            #expect(episode.currentPosition == 42)

            let stored = try persistedEpisode(guid: "guid-1", in: context)
            let persisted = try #require(stored)
            #expect(persisted.localFilename == nil)
            #expect(persisted.downloadedAt == nil)
            #expect(persisted.isPlayed)
            #expect(persisted.sessions.count == 1)
        }
    }

    @Test func deleteOfAnUndownloadedEpisodeIsANoOp() async throws {
        try await withTemporaryBaseAsync { base in
            let context = try makeContext()
            let store = EpisodeStore(baseDirectory: base)
            let episode = try makeEpisode(in: context)
            let manager = DownloadManager(
                context: context, store: store, transport: failingFileTransport())

            #expect(throws: Never.self) { try manager.deleteDownload(for: episode) }
            #expect(episode.localFilename == nil)
        }
    }

    /// A removal that could not be performed leaves the file on disk, so the row
    /// has to go on claiming it: cleared, the Downloads filter drops the episode
    /// and no screen can offer the delete again.
    @Test func aFailedRemovalLeavesTheEpisodeStillClaimingItsFile() async throws {
        try await withTemporaryBaseAsync { base in
            let context = try makeContext()
            let store = EpisodeStore(baseDirectory: base)
            let episode = try makeEpisode(in: context)
            let stub = DownloadTransportStub(stagingDirectory: base)
            let manager = DownloadManager(context: context, store: store, transport: stub.transport)
            try await manager.download(episode)
            let downloaded = try #require(episode.localFilename)
            let downloadedAt = try #require(episode.downloadedAt)

            // a name the store refuses to resolve: `removeFile` throws before it
            // reaches the file system, which is the shape of every removal that
            // could not be performed — the file is still there afterwards
            episode.localFilename = "../escape"
            try context.save()

            #expect(throws: EpisodeStore.Failure.invalidFilename("../escape")) {
                try manager.deleteDownload(for: episode)
            }

            #expect(episode.localFilename == "../escape")
            #expect(episode.downloadedAt == downloadedAt)
            let persisted = try #require(try persistedEpisode(guid: "guid-1", in: context))
            #expect(persisted.localFilename == "../escape")
            #expect(persisted.downloadedAt == downloadedAt)
            try #expect(store.fileExists(forRelativeFilename: downloaded) == true)
        }
    }

    @Test func downloadingAgainAfterADeleteWorks() async throws {
        try await withTemporaryBaseAsync { base in
            let context = try makeContext()
            let store = EpisodeStore(baseDirectory: base)
            let episode = try makeEpisode(in: context)
            let stub = DownloadTransportStub(stagingDirectory: base)
            let manager = DownloadManager(context: context, store: store, transport: stub.transport)

            try await manager.download(episode)
            try manager.deleteDownload(for: episode)
            try await manager.download(episode)

            let filename = try #require(episode.localFilename)
            try #expect(store.fileExists(forRelativeFilename: filename) == true)
        }
    }

    /// AC 8: marking an episode played leaves the download exactly where it is.
    @Test func markingPlayedKeepsTheFileAndTheColumns() async throws {
        try await withTemporaryBaseAsync { base in
            let context = try makeContext()
            let store = EpisodeStore(baseDirectory: base)
            let episode = try makeEpisode(in: context)
            let stub = DownloadTransportStub(stagingDirectory: base)
            let manager = DownloadManager(context: context, store: store, transport: stub.transport)
            try await manager.download(episode)
            let filename = try #require(episode.localFilename)
            let downloadedAt = episode.downloadedAt

            episode.setPlayed(true)
            try context.save()

            #expect(episode.localFilename == filename)
            #expect(episode.downloadedAt == downloadedAt)
            try #expect(episode.isDownloaded(in: store) == true)
        }
    }

    /// Downloading an already-played episode is the same operation; played
    /// state is neither read nor written by the download path.
    @Test func downloadingAPlayedEpisodeLeavesPlayedStateAlone() async throws {
        try await withTemporaryBaseAsync { base in
            let context = try makeContext()
            let store = EpisodeStore(baseDirectory: base)
            let episode = try makeEpisode(in: context)
            episode.setPlayed(true)
            let playedAt = episode.playedAt
            try context.save()
            let stub = DownloadTransportStub(stagingDirectory: base)
            let manager = DownloadManager(context: context, store: store, transport: stub.transport)

            try await manager.download(episode)

            #expect(episode.isPlayed)
            #expect(episode.playedAt == playedAt)
            try #expect(episode.isDownloaded(in: store) == true)
        }
    }
}
