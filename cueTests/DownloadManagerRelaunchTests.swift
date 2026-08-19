import Foundation
import SwiftData
import Testing

@testable import cue

/// The relaunch route: what the manager does with a transfer that finished, or
/// failed, without a continuation to answer.
///
/// The route is exercised through `handleCompletion(_:forGUID:)` and
/// `adopt(inFlightAttempts:)` rather than through `connect(to:)`, so no test
/// constructs a real background session.
@MainActor
struct DownloadManagerRelaunchTests {
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

    private func makeManager(context: ModelContext, base: URL) -> DownloadManager {
        DownloadManager(
            context: context, store: EpisodeStore(baseDirectory: base), transport: failingFileTransport())
    }

    private func stagedFile(in base: URL) throws -> URL {
        let staged = base.appending(path: "staged-\(UUID().uuidString).tmp", directoryHint: .notDirectory)
        try Data("audio".utf8).write(to: staged)
        return staged
    }

    private func response(_ statusCode: Int) throws -> HTTPURLResponse {
        let url = try #require(URL(string: Self.enclosureURL))
        return try #require(
            HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil))
    }

    @Test func aCompletionDeliveredAfterRelaunchRecordsTheDownload() async throws {
        try await withTemporaryBaseAsync { base in
            let context = try makeContext()
            let store = EpisodeStore(baseDirectory: base)
            let episode = try makeEpisode(in: context)
            let manager = makeManager(context: context, base: base)
            let staged = try stagedFile(in: base)

            await manager.handleCompletion(.success((staged, try response(200))), forGUID: "guid-1")

            let filename = try #require(episode.localFilename)
            try #expect(store.fileExists(forRelativeFilename: filename) == true)
            #expect(episode.downloadedAt != nil)
            #expect(manager.state(for: episode) == nil)

            // committed, not merely pending: the relaunch route may be the last
            // thing this process does, so an unsaved write is a lost download
            let persisted = try #require(try persistedEpisode(guid: "guid-1", in: context))
            #expect(persisted.localFilename == filename)
            #expect(persisted.downloadedAt != nil)
        }
    }

    /// A transfer that failed while the app was gone has no continuation to
    /// throw to; leaving the state alone spins the row forever, and a row that
    /// reads `.downloading` offers neither a retry nor a delete.
    @Test func aFailedTransferDeliveredAfterRelaunchIsRecordedAsFailed() async throws {
        try await withTemporaryBaseAsync { base in
            let context = try makeContext()
            let episode = try makeEpisode(in: context)
            let manager = makeManager(context: context, base: base)
            manager.adopt(
                inFlightAttempts: [DownloadAttemptIdentity(taskIdentifier: 1, guid: "guid-1")])

            await manager.handleCompletion(.failure(StubTransportError.offline), forGUID: "guid-1")

            #expect(manager.state(for: episode) == .failed)
            #expect(episode.localFilename == nil)
        }
    }

    @Test func aCancelledTransferDeliveredAfterRelaunchClearsTheState() async throws {
        try await withTemporaryBaseAsync { base in
            let context = try makeContext()
            let episode = try makeEpisode(in: context)
            let manager = makeManager(context: context, base: base)
            manager.adopt(
                inFlightAttempts: [DownloadAttemptIdentity(taskIdentifier: 1, guid: "guid-1")])

            await manager.handleCompletion(.failure(CancellationError()), forGUID: "guid-1")

            #expect(manager.state(for: episode) == nil)
        }
    }

    @Test func aCompletionForAnEpisodeThatIsGoneDiscardsTheFile() async throws {
        try await withTemporaryBaseAsync { base in
            let context = try makeContext()
            let manager = makeManager(context: context, base: base)
            let staged = try stagedFile(in: base)

            await manager.handleCompletion(.success((staged, try response(200))), forGUID: "no-such-guid")

            #expect(!FileManager.default.fileExists(atPath: staged.path(percentEncoded: false)))
        }
    }

    /// The relaunch route is gated on the status the same way the transport
    /// route is: an error page arriving in the background is not an episode.
    @Test func finishingANon2xxTransferWritesNothingAndDiscardsTheFile() async throws {
        try await withTemporaryBaseAsync { base in
            let context = try makeContext()
            let episode = try makeEpisode(in: context)
            let manager = makeManager(context: context, base: base)
            let staged = try stagedFile(in: base)

            await #expect(throws: DownloadManager.Failure.httpStatus(403, Self.enclosureURL)) {
                try await manager.finishDownload(
                    tempURL: staged, response: try response(403), forGUID: "guid-1")
            }

            #expect(episode.localFilename == nil)
            #expect(episode.downloadedAt == nil)
            #expect(!FileManager.default.fileExists(atPath: staged.path(percentEncoded: false)))
        }
    }

    /// `connect(to:)` asks the session what is in flight across an `await`, so a
    /// completion can be routed between the answer and `adopt`. Marking that guid
    /// `.downloading` again would spin the row for the rest of the process, with
    /// no transfer left to clear it.
    @Test func adoptingATransferAlreadyResolvedDoesNotResurrectIt() async throws {
        try await withTemporaryBaseAsync { base in
            let context = try makeContext()
            let episode = try makeEpisode(in: context)
            let manager = makeManager(context: context, base: base)
            let staged = try stagedFile(in: base)

            await manager.handleCompletion(.success((staged, try response(200))), forGUID: "guid-1")
            manager.adopt(
                inFlightAttempts: [DownloadAttemptIdentity(taskIdentifier: 1, guid: "guid-1")])

            #expect(manager.state(for: episode) == nil)
        }
    }

    /// The relaunch finish suspends — it reads the asset's duration — and the
    /// row it is finishing must not read as idle while it does. Left unclaimed,
    /// a tap in that window starts a second transfer for the same guid, and the
    /// finish then clears the state that second transfer is holding: the row
    /// offers Delete with a transfer still running behind it.
    @Test func aTapWhileARelaunchFinishIsInFlightStartsNoSecondTransfer() async throws {
        try await withTemporaryBaseAsync { base in
            let context = try makeContext()
            let store = EpisodeStore(baseDirectory: base)
            let episode = try makeEpisode(in: context)
            let stub = DownloadTransportStub(stagingDirectory: base)
            let manager = DownloadManager(context: context, store: store, transport: stub.transport)
            let staged = try stagedFile(in: base)
            let delivered = try response(200)

            // both are enqueued on this actor before either can suspend, so the
            // finish claims the guid first and the tap has to be refused.
            // Asserted on the outcome rather than on a transient `.downloading`
            // marker: the finish only holds that marker while it is parked on
            // the asset read, and a read that answers without suspending closes
            // the window before this task is scheduled again — which is exactly
            // how the marker version passed here and failed in CI
            let finish = Task { await manager.handleCompletion(.success((staged, delivered)), forGUID: "guid-1") }
            let tap = Task { try await manager.download(episode) }

            try await tap.value
            await finish.value

            // the tap never reached the transport: without the claim it would
            // have started a second transfer for a guid already being finished
            #expect(stub.requestedURLStrings.isEmpty)
            #expect(manager.state(for: episode) == nil)
            let persisted = try persistedEpisode(guid: "guid-1", in: context)
            #expect(persisted?.localFilename != nil)
        }
    }

    /// A download interrupted by termination is recovered from the session, so
    /// what the session reports in flight is what the rows show.
    @Test func adoptedTransfersReadAsDownloading() async throws {
        try await withTemporaryBaseAsync { base in
            let context = try makeContext()
            let episode = try makeEpisode(in: context)
            let manager = makeManager(context: context, base: base)

            manager.adopt(
                inFlightAttempts: [DownloadAttemptIdentity(taskIdentifier: 1, guid: "guid-1")])

            #expect(manager.state(for: episode) == .downloading(.waiting))
        }
    }
}

/// The orphan route's queueing, exercised without a background session.
///
/// Constructing a `BackgroundDownloader` does not create one — only touching its
/// session does, and nothing here does. Do not add a case that would.
struct BackgroundDownloaderRoutingTests {

    /// On a relaunch made to deliver a finished transfer the session is woken
    /// from the app delegate, which can happen before anything has registered a
    /// handler. Discarding there deletes the download the relaunch was for.
    @Test func aCompletionArrivingBeforeTheHandlerIsHeldNotDiscarded() throws {
        try withTemporaryBase { base in
            let downloader = BackgroundDownloader()
            let staged = base.appending(path: "staged.tmp", directoryHint: .notDirectory)
            try Data("audio".utf8).write(to: staged)
            let url = try #require(URL(string: "https://example.com/audio/1.mp3"))
            let response = try #require(
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))

            downloader.route(.success((staged, response)), forGUID: "guid-1")

            #expect(FileManager.default.fileExists(atPath: staged.path(percentEncoded: false)))

            let received = ReceivedCompletions()
            downloader.setOrphanedCompletionHandler { result, guid in received.record(result, guid: guid) }

            #expect(received.guids == ["guid-1"])
            #expect(received.succeeded == [true])
            #expect(FileManager.default.fileExists(atPath: staged.path(percentEncoded: false)))
        }
    }

    @Test func aFailureIsRoutedSoTheRowCanStopTransferring() {
        let downloader = BackgroundDownloader()
        let received = ReceivedCompletions()

        downloader.setOrphanedCompletionHandler { result, guid in received.record(result, guid: guid) }
        downloader.route(.failure(StubTransportError.offline), forGUID: "guid-1")

        #expect(received.guids == ["guid-1"])
        #expect(received.succeeded == [false])
    }
}

/// The accounting the UIKit background-events handler waits on.
///
/// An outcome answered through a live continuation — the app was suspended, not
/// terminated — is delivered work too: the move and the model write happen after
/// the transport returns, so the barrier is what keeps the system from
/// suspending the app in the middle of them.
@MainActor
struct DownloadManagerDeliveryBarrierTests {
    private func makeEpisode(in context: ModelContext, enclosureURL: String) throws -> Episode {
        let podcast = Podcast(feedURL: testFeedURL, title: "Show")
        context.insert(podcast)
        let episode = Episode(guid: "guid-1", title: "Episode", enclosureURL: enclosureURL)
        episode.podcast = podcast
        context.insert(episode)
        try context.save()
        return episode
    }

    private func makeManager(
        context: ModelContext, base: URL, transport: @escaping DownloadManager.FileTransport,
        releases: ReleaseCount
    ) -> DownloadManager {
        DownloadManager(
            context: context, store: EpisodeStore(baseDirectory: base), transport: transport,
            deliveryBarrier: { releases.record() })
    }

    @Test func aFinishedDownloadReleasesTheBarrierOnce() async throws {
        try await withTemporaryBaseAsync { base in
            let context = try makeContext()
            let episode = try makeEpisode(in: context, enclosureURL: "https://example.com/audio/1.mp3")
            let releases = ReleaseCount()
            let stub = DownloadTransportStub(stagingDirectory: base)
            let manager = makeManager(
                context: context, base: base, transport: stub.transport, releases: releases)

            try await manager.download(episode)

            #expect(releases.count == 1)
        }
    }

    /// A failure is an outcome the session handed over just as much as a success
    /// is, so it is accounted for the same way — otherwise the handler is never
    /// answered and the app loses its background assertion.
    @Test func aFailedTransferStillReleasesTheBarrier() async throws {
        try await withTemporaryBaseAsync { base in
            let context = try makeContext()
            let episode = try makeEpisode(in: context, enclosureURL: "https://example.com/audio/1.mp3")
            let releases = ReleaseCount()
            let manager = makeManager(
                context: context, base: base, transport: failingFileTransport(), releases: releases)

            await #expect(throws: StubTransportError.offline) { try await manager.download(episode) }

            #expect(releases.count == 1)
        }
    }

    /// Nothing was delivered when the request never reached the transport, so
    /// releasing there would let the handler be answered while a *different*
    /// transfer is still being finished.
    @Test func aRequestThatNeverReachedTheTransportReleasesNothing() async throws {
        try await withTemporaryBaseAsync { base in
            let context = try makeContext()
            let episode = try makeEpisode(in: context, enclosureURL: "file:///tmp/audio.mp3")
            let releases = ReleaseCount()
            let stub = DownloadTransportStub(stagingDirectory: base)
            let manager = makeManager(
                context: context, base: base, transport: stub.transport, releases: releases)

            await #expect(throws: DownloadManager.Failure.invalidEnclosureURL("file:///tmp/audio.mp3")) {
                try await manager.download(episode)
            }

            #expect(releases.count == 0)
        }
    }
}

/// How many times the delivery barrier was released.
private final class ReleaseCount: @unchecked Sendable {
    private let lock = NSLock()
    private var released = 0

    var count: Int { lock.withLock { released } }

    func record() {
        lock.withLock { released += 1 }
    }
}

/// What the orphan handler was handed, in order.
///
/// Not private: `BackgroundDownloaderTransferTests` asserts the same thing about
/// the same route, and a second copy of a recorder is the duplication the shared
/// doubles exist to avoid.
final class ReceivedCompletions: @unchecked Sendable {
    private let lock = NSLock()
    private var received: [(guid: String, succeeded: Bool)] = []

    var guids: [String] { lock.withLock { received }.map(\.guid) }
    var succeeded: [Bool] { lock.withLock { received }.map(\.succeeded) }

    func record(_ result: Result<(URL, URLResponse), Error>, guid: String) {
        let succeeded: Bool
        switch result {
        case .success: succeeded = true
        case .failure: succeeded = false
        }
        lock.withLock { received.append((guid, succeeded)) }
    }
}
