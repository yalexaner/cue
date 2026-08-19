import Foundation
import SwiftData
import Testing

@testable import cue

/// Missing-episode and failed-lookup policy for background outcomes.
///
/// The route is exercised without touching a real background session.
@MainActor
struct DownloadManagerOrphanTests {
    private func makeEpisode(in context: ModelContext) throws -> Episode {
        let podcast = Podcast(feedURL: testFeedURL, title: "Show")
        context.insert(podcast)
        let episode = Episode(
            guid: "guid-1", title: "Episode",
            enclosureURL: "https://example.com/audio/1.mp3")
        episode.podcast = podcast
        context.insert(episode)
        try context.save()
        return episode
    }

    private func makeManager(
        context: ModelContext, base: URL,
        episodeLookup: ((String) throws -> Episode?)? = nil
    ) -> DownloadManager {
        DownloadManager(
            context: context, store: EpisodeStore(baseDirectory: base),
            transport: failingFileTransport(), episodeLookup: episodeLookup)
    }

    private func stagedFile(in base: URL) throws -> URL {
        let staged = base.appending(path: "staged-\(UUID().uuidString).tmp", directoryHint: .notDirectory)
        try Data("audio".utf8).write(to: staged)
        return staged
    }

    private func okResponse() throws -> HTTPURLResponse {
        let url = try #require(URL(string: "https://example.com/audio/1.mp3"))
        return try #require(
            HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
    }

    /// Two outcomes for one adopted guid must not both finish it.
    ///
    /// An adopted attempt lends its token to the relaunch route, and the token
    /// is what authorises the write — so a second outcome arriving while the
    /// first suspends on the asset read would be handed the same token, and
    /// both would move a file into `Episodes/` and write `localFilename`,
    /// orphaning the loser's file (`DownloadOwnership.swift`).
    @Test func aSecondOutcomeIsDiscardedWhileTheAdoptedFinishRuns() async throws {
        try await withTemporaryBaseAsync { base in
            let context = try makeContext()
            let store = EpisodeStore(baseDirectory: base)
            let episode = try makeEpisode(in: context)
            let manager = makeManager(context: context, base: base)
            manager.adopt(
                inFlightAttempts: [DownloadAttemptIdentity(taskIdentifier: 1, guid: episode.guid)])
            let firstFile = try stagedFile(in: base)
            let secondFile = try stagedFile(in: base)
            let response = try okResponse()
            let guid = episode.guid

            async let first: Void = manager.handleCompletion(.success((firstFile, response)), forGUID: guid)
            async let second: Void = manager.handleCompletion(.success((secondFile, response)), forGUID: guid)
            _ = await (first, second)

            let filename = try #require(episode.localFilename)
            try #expect(store.fileExists(forRelativeFilename: filename) == true)
            // neither staged file is left behind: one was moved, one discarded
            #expect(FileManager.default.fileExists(atPath: firstFile.path) == false)
            #expect(FileManager.default.fileExists(atPath: secondFile.path) == false)
            let recorded = try FileManager.default.contentsOfDirectory(
                at: try store.episodesDirectory(), includingPropertiesForKeys: nil)
            #expect(recorded.count == 1)
            #expect(manager.attempts[guid] == nil)
        }
    }

    @Test func aFailureForAnEpisodeThatIsGoneClearsItsAdoptedState() async throws {
        try await withTemporaryBaseAsync { base in
            let context = try makeContext()
            let manager = makeManager(context: context, base: base)
            manager.adopt(
                inFlightAttempts: [DownloadAttemptIdentity(taskIdentifier: 1, guid: "no-such-guid")])

            await manager.handleCompletion(
                .failure(StubTransportError.offline), forGUID: "no-such-guid")

            #expect(manager.states["no-such-guid"] == nil)
            #expect(manager.attempts["no-such-guid"] == nil)
        }
    }

    @Test func aFailedEpisodeLookupKeepsASafeFailureAndReleasesUIKitOnce() async throws {
        try await withTemporaryBaseAsync { base in
            let context = try makeContext()
            let episode = try makeEpisode(in: context)
            let downloader = BackgroundDownloader()
            let manager = makeManager(
                context: context, base: base,
                episodeLookup: { _ in throw StubTransportError.offline })
            manager.registerCompletionRoute(with: downloader)
            manager.adopt(
                inFlightAttempts: [DownloadAttemptIdentity(taskIdentifier: 1, guid: episode.guid)])
            let completions = OrphanCompletionCount()
            #expect(downloader.storeBackgroundEventsCompletion({ completions.record() }).isEmpty)

            downloader.route(.failure(StubTransportError.offline), forGUID: episode.guid)
            #expect(downloader.noteBackgroundEventsDelivered().isEmpty)
            await yieldUntil { completions.count == 1 }

            #expect(
                manager.state(for: episode)
                    == .failed(message: DownloadManager.episodeLookupFailureMessage))
            #expect(manager.attempts[episode.guid] == nil)
            #expect(completions.count == 1)
            #expect(downloader.finishDeliveredWork().isEmpty)
            #expect(completions.count == 1)
        }
    }

    /// The transport route's `catch` only records the failure, so the finish
    /// path itself has to let go of the file it was handed when the lookup
    /// throws — otherwise a whole episode stays in `tmp`, referenced by nothing.
    @Test func aThrowingLookupDiscardsTheDeliveredFile() async throws {
        try await withTemporaryBaseAsync { base in
            let manager = makeManager(
                context: try makeContext(), base: base,
                episodeLookup: { _ in throw StubTransportError.offline })
            let staged = try stagedFile(in: base)
            let response = try okResponse()

            await #expect(throws: StubTransportError.offline) {
                try await manager.finishDownload(
                    tempURL: staged, response: response, forGUID: "guid-1", heldBy: UUID())
            }

            #expect(!FileManager.default.fileExists(atPath: staged.path))
        }
    }
}

private final class OrphanCompletionCount: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int { lock.withLock { value } }

    func record() {
        lock.withLock { value += 1 }
    }
}
