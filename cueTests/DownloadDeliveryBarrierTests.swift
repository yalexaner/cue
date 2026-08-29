import Foundation
import SwiftData
import Testing

@testable import cue

/// A bare counter behind a lock: the barrier is `@Sendable`, so it cannot
/// capture a `var`.
private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }

    func increment() {
        lock.withLock { count += 1 }
    }
}

/// The background-delivery accounting, after it moved out of `defer`.
///
/// The barrier decides when iOS may suspend the app, so it has exactly two
/// obligations: it must never fire for an exit that happened *before* the
/// session delivered anything — decrementing for a delivery that never happened
/// can drive another delivery's count to zero and answer UIKit mid-finish — and
/// it must fire exactly once for every exit that happened after (decision 8).
@MainActor
struct DownloadDeliveryBarrierTests {
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

    // MARK: - Pre-transport exits

    @Test func anInvalidEnclosureNeverReachesTheBarrier() async throws {
        try await withTemporaryBaseAsync { base in
            let context = try makeContext()
            let podcast = Podcast(feedURL: testFeedURL, title: "Show")
            context.insert(podcast)
            let episode = Episode(guid: "guid-1", title: "Episode", enclosureURL: "notaurl")
            episode.podcast = podcast
            context.insert(episode)
            try context.save()
            let barrier = CallCounter()
            let stub = DownloadTransportStub(stagingDirectory: base)
            let manager = DownloadManager(
                context: context, store: EpisodeStore(baseDirectory: base),
                transport: stub.transport, deliveryBarrier: { barrier.increment() })

            await #expect(throws: DownloadManager.Failure.self) { try await manager.download(episode) }

            #expect(barrier.value == 0)
        }
    }

    /// A container that cannot be provisioned fails before any bandwidth is
    /// spent, so the session has nothing to account for.
    @Test func aFailedDirectoryPreparationNeverReachesTheBarrier() async throws {
        try await withTemporaryBaseAsync { base in
            // a regular file where `Episodes/` has to be
            try Data("occupied".utf8).write(to: base.appending(path: "Episodes", directoryHint: .notDirectory))
            let context = try makeContext()
            let episode = try makeEpisode(in: context)
            let barrier = CallCounter()
            let stub = DownloadTransportStub(stagingDirectory: base)
            let manager = DownloadManager(
                context: context, store: EpisodeStore(baseDirectory: base),
                transport: stub.transport, deliveryBarrier: { barrier.increment() })

            await #expect(throws: (any Error).self) { try await manager.download(episode) }

            #expect(barrier.value == 0)
            #expect(stub.requestedURLStrings.isEmpty)
        }
    }

    /// A transfer cancelled while it is still queued never reached the session.
    @Test func aCancelledQueueWaitNeverReachesTheBarrier() async throws {
        try await withTemporaryBaseAsync { base in
            let context = try makeContext()
            let first = try makeEpisode(in: context, guid: "guid-1")
            let second = try makeEpisode(in: context, guid: "guid-2")
            let barrier = CallCounter()
            let gate = GatedFileTransport(stagingDirectory: base)
            let manager = DownloadManager(
                context: context, store: EpisodeStore(baseDirectory: base),
                transport: gate.transport, deliveryBarrier: { barrier.increment() },
                cancellationRequest: gate.cancellationRequest)

            let running = Task { try await manager.download(first) }
            await yieldUntil { gate.callCount == 1 }
            let queued = Task { try await manager.download(second) }
            await yieldUntil { !manager.waiting.isEmpty }
            await manager.cancel(second)
            _ = try? await queued.value

            // asserted before the held transfer is released, so the count can
            // only be the queued one's
            #expect(barrier.value == 0)
            #expect(gate.callCount == 1)

            gate.open()
            _ = try? await running.value
        }
    }

    // MARK: - Post-delivery exits

    @Test func aSuccessfulDeliveryCallsTheBarrierExactlyOnce() async throws {
        try await withTemporaryBaseAsync { base in
            let context = try makeContext()
            let episode = try makeEpisode(in: context)
            let barrier = CallCounter()
            let stub = DownloadTransportStub(stagingDirectory: base)
            let manager = DownloadManager(
                context: context, store: EpisodeStore(baseDirectory: base),
                transport: stub.transport, deliveryBarrier: { barrier.increment() })

            try await manager.download(episode)

            #expect(barrier.value == 1)
        }
    }

    /// The transport answering with an error is still a delivery: the session
    /// handed the outcome over, and the accounting has to be balanced.
    @Test func aDeliveredFailureCallsTheBarrierExactlyOnce() async throws {
        try await withTemporaryBaseAsync { base in
            let context = try makeContext()
            let episode = try makeEpisode(in: context)
            let barrier = CallCounter()
            let manager = DownloadManager(
                context: context, store: EpisodeStore(baseDirectory: base),
                transport: failingFileTransport(), deliveryBarrier: { barrier.increment() })

            await #expect(throws: StubTransportError.self) { try await manager.download(episode) }

            #expect(barrier.value == 1)
        }
    }

    @Test func aNonSuccessStatusCallsTheBarrierExactlyOnce() async throws {
        try await withTemporaryBaseAsync { base in
            let context = try makeContext()
            let episode = try makeEpisode(in: context)
            let barrier = CallCounter()
            let stub = DownloadTransportStub(stagingDirectory: base)
            stub.serve(statusCode: 500)
            let manager = DownloadManager(
                context: context, store: EpisodeStore(baseDirectory: base),
                transport: stub.transport, deliveryBarrier: { barrier.increment() })

            await #expect(throws: DownloadManager.Failure.self) { try await manager.download(episode) }

            #expect(barrier.value == 1)
        }
    }

    /// The whole point of moving it out of `defer`: the terminal record is
    /// written, and flushed, before the system is told it may suspend us.
    @Test func theBarrierFiresAfterTheFailureRecordAndTheFlush() async throws {
        try await withTemporaryBaseAsync { base in
            let context = try makeContext()
            let episode = try makeEpisode(in: context)
            let sink = RecordingDiagnosticsSink()
            let barrier = CallCounter()
            let manager = DownloadManager(
                context: context, store: EpisodeStore(baseDirectory: base),
                transport: failingFileTransport(), deliveryBarrier: { barrier.increment() },
                diagnostics: sink)

            await #expect(throws: StubTransportError.self) { try await manager.download(episode) }

            #expect(sink.records(named: "download.failed").count == 1)
            #expect(sink.flushCount == 1)
            #expect(barrier.value == 1)
        }
    }

    /// A flush that achieves nothing must still complete delivery: a lost log is
    /// survivable, a never-answered UIKit handler is not.
    @Test func aFlushThatAchievesNothingStillCompletesDelivery() async throws {
        try await withTemporaryBaseAsync { base in
            let context = try makeContext()
            let episode = try makeEpisode(in: context)
            let sink = RecordingDiagnosticsSink(flushSilentlyFails: true)
            let barrier = CallCounter()
            let manager = DownloadManager(
                context: context, store: EpisodeStore(baseDirectory: base),
                transport: failingFileTransport(), deliveryBarrier: { barrier.increment() },
                diagnostics: sink)

            await #expect(throws: StubTransportError.self) { try await manager.download(episode) }

            // the flush was asked for and drained nothing — and the barrier
            // fired anyway, which is the whole obligation
            #expect(sink.flushAttemptCount == 1)
            #expect(sink.flushCount == 0)
            #expect(barrier.value == 1)
        }
    }

    // MARK: - The UIKit handler

    /// Answered once the session's events are delivered *and* the finish they
    /// started is done — never before.
    @Test func theOrphanRouteAnswersTheUIKitHandlerExactlyOnceAndNotEarly() async throws {
        try await withTemporaryBaseAsync { base in
            let context = try makeContext()
            let episode = try makeEpisode(in: context)
            let sink = RecordingDiagnosticsSink(flushSilentlyFails: true)
            let manager = DownloadManager(
                context: context, store: EpisodeStore(baseDirectory: base),
                transport: failingFileTransport(), diagnostics: sink)
            let downloader = BackgroundDownloader()
            manager.registerCompletionRoute(with: downloader)
            let answers = CallCounter()
            #expect(downloader.noteBackgroundEventsDelivered().isEmpty)

            downloader.route(.failure(StubTransportError.offline), forGUID: episode.guid)
            // the finish has not run yet, so the handler is held rather than
            // answered inline
            #expect(downloader.storeBackgroundEventsCompletion({ answers.increment() }).isEmpty)
            #expect(answers.value == 0)

            await yieldUntil { answers.value > 0 }

            #expect(answers.value == 1)
            // attempts, not drains: this sink's flush silently achieves nothing
            #expect(sink.flushAttemptCount == 1)
            #expect(manager.states[episode.guid]?.isFailed == true)
            // the relaunch route records its own terminal failure
            #expect(sink.records(named: "download.failed").count == 1)
        }
    }
}
