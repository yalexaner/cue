import Foundation
import SwiftData
import Testing

@testable import cue

/// Guid-addressable cancellation across queued, live and adopted attempts.
///
/// Every session-facing assertion uses the injected cancellation request or a
/// value-returning downloader seam. No test here constructs or touches a real
/// background session.
@MainActor
struct DownloadManagerCancellationTests {
    private func makeEpisodes(in context: ModelContext, guids: [String]) throws -> [Episode] {
        let podcast = Podcast(feedURL: testFeedURL, title: "Show")
        context.insert(podcast)
        let episodes = guids.map { guid in
            let episode = Episode(
                guid: guid, title: "Episode \(guid)",
                enclosureURL: "https://example.com/\(guid).mp3")
            episode.podcast = podcast
            context.insert(episode)
            return episode
        }
        try context.save()
        return episodes
    }

    private func response(for episode: Episode) throws -> HTTPURLResponse {
        let url = try #require(URL(string: episode.enclosureURL))
        return try #require(
            HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
    }

    private func stagedFile(in base: URL) throws -> URL {
        let url = base.appending(path: "cancelled-\(UUID().uuidString).tmp", directoryHint: .notDirectory)
        try Data("audio".utf8).write(to: url)
        return url
    }

    @Test func cancellingALiveTransferWaitsForItsOutcomeAndClearsState() async throws {
        try await withTemporaryBaseAsync { base in
            let context = try makeContext()
            let episode = try #require(makeEpisodes(in: context, guids: ["guid-1"]).first)
            let gate = GatedFileTransport(stagingDirectory: base)
            let manager = DownloadManager(
                context: context, store: EpisodeStore(baseDirectory: base), transport: gate.transport,
                cancellationRequest: gate.cancellationRequest)

            let download = Task { try await manager.download(episode) }
            await yieldUntil { gate.callCount == 1 }
            manager.registerAttempt(taskIdentifier: 1, forGUID: episode.guid)
            await manager.cancel(episode)

            await #expect(throws: CancellationError.self) { try await download.value }
            #expect(gate.cancellationRequests == ["guid-1"])
            #expect(manager.state(for: episode) == nil)
            #expect(manager.attempts[episode.guid] == nil)
            #expect(episode.localFilename == nil)
        }
    }

    @Test func cancellingAQueuedTransferIsImmediateAndCanRetryImmediately() async throws {
        try await withTemporaryBaseAsync { base in
            let context = try makeContext()
            let episodes = try makeEpisodes(in: context, guids: ["guid-1", "guid-2"])
            let first = try #require(episodes.first)
            let second = try #require(episodes.last)
            let gate = GatedFileTransport(stagingDirectory: base)
            let barriers = CancellationCount()
            let manager = DownloadManager(
                context: context, store: EpisodeStore(baseDirectory: base), transport: gate.transport,
                deliveryBarrier: { barriers.record() }, cancellationRequest: gate.cancellationRequest)

            let firstDownload = Task { try await manager.download(first) }
            await yieldUntil { gate.callCount == 1 }
            let queuedDownload = Task { try await manager.download(second) }
            await yieldUntil { manager.state(for: second) != nil }

            await manager.cancel(second)
            #expect(manager.state(for: second) == nil)
            #expect(barriers.count == 0)
            await #expect(throws: CancellationError.self) { try await queuedDownload.value }

            let retry = Task { try await manager.download(second) }
            await yieldUntil { manager.state(for: second)?.isDownloading == true }
            #expect(gate.callCount == 1)

            gate.open()
            try await firstDownload.value
            try await retry.value
            #expect(gate.callCount == 2)
            #expect(second.localFilename != nil)
            let persisted = try #require(try persistedEpisode(guid: second.guid, in: context))
            #expect(persisted.localFilename != nil)
            #expect(manager.state(for: second) == nil)
            #expect(barriers.count == 2)
        }
    }

    @Test func cancellingAnAdoptedTransferRequestsTheSessionAndClearsOnFailure() async throws {
        try await withTemporaryBaseAsync { base in
            let context = try makeContext()
            let episode = try #require(makeEpisodes(in: context, guids: ["guid-1"]).first)
            let requests = CancellationRecorder()
            let manager = DownloadManager(
                context: context, store: EpisodeStore(baseDirectory: base),
                transport: failingFileTransport(), cancellationRequest: requests.request)
            manager.adopt(
                inFlightAttempts: [DownloadAttemptIdentity(taskIdentifier: 7, guid: episode.guid)])

            await manager.cancel(episode)
            #expect(requests.guids == [episode.guid])
            #expect(manager.state(for: episode)?.isDownloading == true)

            // Cancellation intent wins even if the terminal session error races
            // in as a non-cancellation failure.
            await manager.handleCompletion(.failure(StubTransportError.offline), forGUID: episode.guid)
            #expect(manager.state(for: episode) == nil)
            #expect(manager.attempts[episode.guid] == nil)
        }
    }

    @Test func cancellationRacingAnAdoptedSuccessCannotCommitTheFile() async throws {
        try await withTemporaryBaseAsync { base in
            let context = try makeContext()
            let episode = try #require(makeEpisodes(in: context, guids: ["guid-1"]).first)
            let staged = try stagedFile(in: base)
            let manager = DownloadManager(
                context: context, store: EpisodeStore(baseDirectory: base),
                transport: failingFileTransport())
            manager.adopt(
                inFlightAttempts: [DownloadAttemptIdentity(taskIdentifier: 8, guid: episode.guid)])

            await manager.cancel(episode)
            await manager.handleCompletion(
                .success((staged, try response(for: episode))), forGUID: episode.guid)

            #expect(manager.state(for: episode) == nil)
            #expect(episode.localFilename == nil)
            #expect(!FileManager.default.fileExists(atPath: staged.path(percentEncoded: false)))
        }
    }

    @Test func aCancelMissedByTheSessionSnapshotStopsAtTheNextCheckpoint() async throws {
        try await withTemporaryBaseAsync { base in
            let context = try makeContext()
            let episode = try #require(makeEpisodes(in: context, guids: ["guid-1"]).first)
            let gate = GatedFileTransport(stagingDirectory: base)
            let requests = CancellationRecorder()
            let manager = DownloadManager(
                context: context, store: EpisodeStore(baseDirectory: base), transport: gate.transport,
                cancellationRequest: requests.request)

            let download = Task { try await manager.download(episode) }
            await yieldUntil { gate.callCount == 1 }
            manager.registerAttempt(taskIdentifier: 2, forGUID: episode.guid)
            await manager.cancel(episode)
            gate.open()

            await #expect(throws: CancellationError.self) { try await download.value }
            #expect(requests.guids == [episode.guid])
            #expect(requests.identifiers == [2])
            #expect(episode.localFilename == nil)
            #expect(manager.state(for: episode) == nil)
        }
    }

    @Test func aCancelledAttemptDoesNotPoisonItsImmediateRetry() async throws {
        try await withTemporaryBaseAsync { base in
            let context = try makeContext()
            let episode = try #require(makeEpisodes(in: context, guids: ["guid-1"]).first)
            let gate = GatedFileTransport(stagingDirectory: base)
            let manager = DownloadManager(
                context: context, store: EpisodeStore(baseDirectory: base), transport: gate.transport,
                cancellationRequest: gate.cancellationRequest)

            let cancelled = Task { try await manager.download(episode) }
            await yieldUntil { gate.callCount == 1 }
            manager.registerAttempt(taskIdentifier: 3, forGUID: episode.guid)
            await manager.cancel(episode)
            await #expect(throws: CancellationError.self) { try await cancelled.value }

            let retry = Task { try await manager.download(episode) }
            await yieldUntil { gate.callCount == 2 }
            gate.open()
            try await retry.value

            #expect(episode.localFilename != nil)
            let persisted = try #require(try persistedEpisode(guid: episode.guid, in: context))
            #expect(persisted.localFilename != nil)
            #expect(manager.state(for: episode) == nil)
            #expect(manager.attempts[episode.guid] == nil)
        }
    }

    /// A finish held by a displaced attempt writes nothing.
    ///
    /// The checkpoint matches on the token, not only on the guid: a delayed
    /// finish from an attempt the retry replaced would otherwise commit its own
    /// filename over the transfer that displaced it, and orphan the newer file.
    @Test func aDisplacedAttemptCannotFinishOverTheRetryThatReplacedIt() async throws {
        try await withTemporaryBaseAsync { base in
            let context = try makeContext()
            let episode = try #require(makeEpisodes(in: context, guids: ["guid-1"]).first)
            let manager = DownloadManager(
                context: context, store: EpisodeStore(baseDirectory: base),
                transport: failingFileTransport())

            let displaced = try #require(manager.claimOwnership(of: episode.guid))
            #expect(manager.releaseOwnership(of: episode.guid, heldBy: displaced))
            _ = try #require(manager.claimOwnership(of: episode.guid))

            let staged = try stagedFile(in: base)
            await #expect(throws: CancellationError.self) {
                try await manager.finishDownload(
                    tempURL: staged, response: try response(for: episode), forGUID: episode.guid,
                    heldBy: displaced)
            }

            #expect(episode.localFilename == nil)
            #expect(episode.downloadedAt == nil)
            #expect(!FileManager.default.fileExists(atPath: staged.path))
        }
    }

    @Test func cancellingALiveTaskReleasesDeliveredWorkExactlyOnce() async throws {
        try await withTemporaryBaseAsync { base in
            let context = try makeContext()
            let episode = try #require(makeEpisodes(in: context, guids: ["guid-1"]).first)
            let gate = GatedFileTransport(stagingDirectory: base)
            let barriers = CancellationCount()
            let manager = DownloadManager(
                context: context, store: EpisodeStore(baseDirectory: base), transport: gate.transport,
                deliveryBarrier: { barriers.record() }, cancellationRequest: gate.cancellationRequest)

            let download = Task { try await manager.download(episode) }
            await yieldUntil { gate.callCount == 1 }
            manager.registerAttempt(taskIdentifier: 4, forGUID: episode.guid)
            await manager.cancel(episode)
            await #expect(throws: CancellationError.self) { try await download.value }

            #expect(barriers.count == 1)
        }
    }

    @Test func adoptedCancellationReleasesTheUIKitHandlerExactlyOnce() async throws {
        try await withTemporaryBaseAsync { base in
            let context = try makeContext()
            let episode = try #require(makeEpisodes(in: context, guids: ["guid-1"]).first)
            let downloader = BackgroundDownloader()
            let manager = DownloadManager(
                context: context, store: EpisodeStore(baseDirectory: base),
                transport: failingFileTransport())
            manager.registerCompletionRoute(with: downloader)
            manager.adopt(
                inFlightAttempts: [DownloadAttemptIdentity(taskIdentifier: 9, guid: episode.guid)])
            let completions = CancellationCount()
            #expect(downloader.storeBackgroundEventsCompletion({ completions.record() }).isEmpty)

            await manager.cancel(episode)
            downloader.route(.failure(CancellationError()), forGUID: episode.guid)
            #expect(downloader.noteBackgroundEventsDelivered().isEmpty)
            await yieldUntil { completions.count == 1 }

            #expect(manager.state(for: episode) == nil)
            #expect(completions.count == 1)
            #expect(downloader.finishDeliveredWork().isEmpty)
            #expect(completions.count == 1)
        }
    }
}

private final class CancellationCount: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int { lock.withLock { value } }

    func record() {
        lock.withLock { value += 1 }
    }
}
