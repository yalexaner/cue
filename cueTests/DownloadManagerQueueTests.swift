import Foundation
import SwiftData
import Testing

@testable import cue

/// The single transfer slot: what a queued episode reports while it waits, and
/// that a transfer which failed still hands the slot on.
///
/// Split off `DownloadManagerTests` to keep both files under the `file_length`
/// warning that `--strict` turns into an error.
@MainActor
struct DownloadManagerQueueTests {
    private func makeEpisode(in context: ModelContext, guid: String) throws -> Episode {
        let podcast = Podcast(feedURL: testFeedURL, title: "Show")
        context.insert(podcast)
        let episode = Episode(guid: guid, title: "Episode", enclosureURL: "https://example.com/\(guid).mp3")
        episode.podcast = podcast
        context.insert(episode)
        try context.save()
        return episode
    }

    @Test func aTransferInFlightReadsAsDownloading() async throws {
        try await withTemporaryBaseAsync { base in
            let context = try makeContext()
            let store = EpisodeStore(baseDirectory: base)
            let episode = try makeEpisode(in: context, guid: "guid-1")
            let gate = GatedFileTransport(stagingDirectory: base)
            let manager = DownloadManager(context: context, store: store, transport: gate.transport)

            let download = Task { try await manager.download(episode) }
            await yieldUntil { gate.callCount == 1 }

            try #require(gate.callCount == 1)
            #expect(manager.state(for: episode) == .downloading(.connecting))

            gate.open()
            try await download.value
            #expect(manager.state(for: episode) == nil)
        }
    }

    /// A queued transfer with no state reads as "not downloaded", so the row
    /// keeps offering Download and a second tap fetches the same episode twice.
    @Test func aQueuedTransferAlreadyReadsAsDownloading() async throws {
        try await withTemporaryBaseAsync { base in
            let context = try makeContext()
            let store = EpisodeStore(baseDirectory: base)
            let first = try makeEpisode(in: context, guid: "guid-1")
            let second = try makeEpisode(in: context, guid: "guid-2")
            let gate = GatedFileTransport(stagingDirectory: base)
            let manager = DownloadManager(context: context, store: store, transport: gate.transport)

            let firstDownload = Task { try await manager.download(first) }
            await yieldUntil { gate.callCount == 1 }
            let secondDownload = Task { try await manager.download(second) }
            await yieldUntil { manager.state(for: second) != nil }

            // the second one is still waiting its turn, and says where in line
            #expect(gate.callCount == 1)
            #expect(manager.state(for: second) == .downloading(.queued(position: 1)))

            gate.open()
            try await firstDownload.value
            try await secondDownload.value
            #expect(first.localFilename != nil)
            #expect(second.localFilename != nil)

            // committed, not merely pending
            let firstStored = try #require(try persistedEpisode(guid: "guid-1", in: context))
            let secondStored = try #require(try persistedEpisode(guid: "guid-2", in: context))
            #expect(firstStored.localFilename == first.localFilename)
            #expect(secondStored.localFilename == second.localFilename)
        }
    }

    /// A second request for an episode already in flight is a no-op.
    ///
    /// The row stops offering Download the moment the state is set, but a second
    /// tap can land before it re-renders. Two transfers for one guid race: the
    /// first to finish clears the shared state and exposes Delete while the
    /// second is still running, so a deletion can land between the second one's
    /// move and its write and leave a row pointing at a file the user deleted.
    @Test func aSecondRequestForAnEpisodeInFlightIsIgnored() async throws {
        try await withTemporaryBaseAsync { base in
            let context = try makeContext()
            let store = EpisodeStore(baseDirectory: base)
            let episode = try makeEpisode(in: context, guid: "guid-1")
            let gate = GatedFileTransport(stagingDirectory: base)
            let manager = DownloadManager(context: context, store: store, transport: gate.transport)

            let download = Task { try await manager.download(episode) }
            await yieldUntil { gate.callCount == 1 }
            try #require(manager.state(for: episode) == .downloading(.connecting))

            // returns without queueing a second transfer, and without failing
            try await manager.download(episode)
            #expect(gate.callCount == 1)
            #expect(manager.state(for: episode) == .downloading(.connecting))

            gate.open()
            try await download.value
            #expect(gate.callCount == 1)
            #expect(manager.state(for: episode) == nil)
            #expect(episode.localFilename != nil)
        }
    }

    /// A caller cancelled while it was queued fails immediately, without fetching.
    ///
    /// The waiter parks on a *throwing* continuation and the cancellation
    /// handler removes it, so the queued call must resolve while the running
    /// transfer is still parked — not wait its turn behind it and then check.
    @Test func aTransferCancelledWhileQueuedNeverReachesTheTransport() async throws {
        try await withTemporaryBaseAsync { base in
            let context = try makeContext()
            let store = EpisodeStore(baseDirectory: base)
            let first = try makeEpisode(in: context, guid: "guid-1")
            let second = try makeEpisode(in: context, guid: "guid-2")
            let gate = GatedFileTransport(stagingDirectory: base)
            let manager = DownloadManager(context: context, store: store, transport: gate.transport)

            let firstDownload = Task { try await manager.download(first) }
            await yieldUntil { gate.callCount == 1 }
            let secondDownload = Task { try await manager.download(second) }
            await yieldUntil { manager.state(for: second) != nil }
            try #require(gate.callCount == 1)

            // the gate stays shut: the queued call has to fail while the first
            // transfer is still holding the slot
            secondDownload.cancel()
            await #expect(throws: CancellationError.self) { try await secondDownload.value }
            #expect(gate.callCount == 1)

            gate.open()
            try await firstDownload.value

            #expect(gate.callCount == 1)
            #expect(second.localFilename == nil)
            #expect(manager.state(for: second) == nil)
        }
    }

    /// The three phases before a byte arrives are distinguishable.
    ///
    /// One literal "Waiting…" covering a queue and a connection that never
    /// opened is what made a device session unreadable: a transfer parked
    /// behind the slot says so and names its place in line, the one holding the
    /// slot reads as connecting, and the first byte moves it on.
    @Test func aTransferMovesFromQueuedThroughConnectingToDownloading() async throws {
        try await withTemporaryBaseAsync { base in
            let context = try makeContext()
            let store = EpisodeStore(baseDirectory: base)
            let first = try makeEpisode(in: context, guid: "guid-1")
            let second = try makeEpisode(in: context, guid: "guid-2")
            let gate = GatedFileTransport(stagingDirectory: base)
            let manager = DownloadManager(context: context, store: store, transport: gate.transport)

            let firstDownload = Task { try await manager.download(first) }
            await yieldUntil { gate.callCount == 1 }
            // uncontended: it never queues at all
            try #require(manager.state(for: first) == .downloading(.connecting))

            let secondDownload = Task { try await manager.download(second) }
            await yieldUntil { manager.state(for: second) != nil }
            try #require(manager.state(for: second) == .downloading(.queued(position: 1)))

            gate.open()
            try await firstDownload.value
            // the slot was handed on, so the queued transfer is now connecting
            await yieldUntil { manager.state(for: second) == .downloading(.connecting) }
            #expect(manager.state(for: second) == .downloading(.connecting))

            try await secondDownload.value
            #expect(second.localFilename != nil)
        }
    }

    /// Positions come from the FIFO array, so a departure renumbers the rest.
    ///
    /// Derived rather than stored on the attempt: a stored number left behind by
    /// a cancellation would have a row claiming to be third in a queue of one.
    @Test func cancellingAQueuedTransferRenumbersTheOnesBehindIt() async throws {
        try await withTemporaryBaseAsync { base in
            let context = try makeContext()
            let store = EpisodeStore(baseDirectory: base)
            let running = try makeEpisode(in: context, guid: "guid-1")
            let second = try makeEpisode(in: context, guid: "guid-2")
            let third = try makeEpisode(in: context, guid: "guid-3")
            let gate = GatedFileTransport(stagingDirectory: base)
            let manager = DownloadManager(context: context, store: store, transport: gate.transport)

            let runningDownload = Task { try await manager.download(running) }
            await yieldUntil { gate.callCount == 1 }
            let secondDownload = Task { try await manager.download(second) }
            await yieldUntil { manager.state(for: second) != nil }
            let thirdDownload = Task { try await manager.download(third) }
            await yieldUntil { manager.state(for: third) != nil }

            try #require(manager.state(for: second) == .downloading(.queued(position: 1)))
            try #require(manager.state(for: third) == .downloading(.queued(position: 2)))

            secondDownload.cancel()
            await #expect(throws: CancellationError.self) { try await secondDownload.value }

            // the one behind it moved up, immediately, with the gate still shut
            #expect(manager.state(for: third) == .downloading(.queued(position: 1)))

            gate.open()
            try await runningDownload.value
            try await thirdDownload.value
            #expect(third.localFilename != nil)
        }
    }

    /// The slot is released by a failed transfer too — otherwise every later
    /// download parks forever on a continuation nothing resumes.
    @Test func aFailedTransferHandsTheSlotOn() async throws {
        try await withTemporaryBaseAsync { base in
            let context = try makeContext()
            let store = EpisodeStore(baseDirectory: base)
            let first = try makeEpisode(in: context, guid: "guid-1")
            let second = try makeEpisode(in: context, guid: "guid-2")
            let stub = DownloadTransportStub(stagingDirectory: base)
            stub.serve(statusCode: 500)
            let manager = DownloadManager(context: context, store: store, transport: stub.transport)

            await #expect(throws: DownloadManager.Failure.self) { try await manager.download(first) }
            stub.serve(statusCode: 200)
            try await manager.download(second)

            #expect(second.localFilename != nil)
            #expect(manager.state(for: second) == nil)
        }
    }

    /// `download.queued` and the place in line it names.
    ///
    /// The queue suite above asserts the queued *state*'s position and the
    /// diagnostics suite constructs the event by hand, so nothing runs a
    /// contended download through the sink: an off-by-one in `queuePosition`, or
    /// a dropped `record` call, ships a log that names the wrong place in line —
    /// or omits queueing entirely, which is the exact ambiguity between "queued"
    /// and "connecting" this step removed.
    @Test func onlyAContendedTransferRecordsAQueuedEventAndItsPosition() async throws {
        try await withTemporaryBaseAsync { base in
            let context = try makeContext()
            let store = EpisodeStore(baseDirectory: base)
            let first = try makeEpisode(in: context, guid: "guid-1")
            let second = try makeEpisode(in: context, guid: "guid-2")
            let gate = GatedFileTransport(stagingDirectory: base)
            let sink = RecordingDiagnosticsSink()
            let manager = DownloadManager(
                context: context, store: store, transport: gate.transport, diagnostics: sink)

            let firstDownload = Task { try await manager.download(first) }
            await yieldUntil { gate.callCount == 1 }
            let secondDownload = Task { try await manager.download(second) }
            await yieldUntil { manager.state(for: second) != nil }

            let queued = sink.records(named: "download.queued")
            #expect(queued.count == 1)
            let record = try #require(queued.first)
            #expect(record.fieldsByKey["guid"] == DiagnosticsGUID("guid-2").digest)
            #expect(record.fieldsByKey["position"] == "1")

            gate.open()
            try await firstDownload.value
            try await secondDownload.value
        }
    }
}
