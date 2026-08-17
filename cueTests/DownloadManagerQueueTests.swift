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
            #expect(manager.state(for: episode) == .downloading)

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

            // the second one is still waiting its turn, and says so
            #expect(gate.callCount == 1)
            #expect(manager.state(for: second) == .downloading)

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
            try #require(manager.state(for: episode) == .downloading)

            // returns without queueing a second transfer, and without failing
            try await manager.download(episode)
            #expect(gate.callCount == 1)
            #expect(manager.state(for: episode) == .downloading)

            gate.open()
            try await download.value
            #expect(gate.callCount == 1)
            #expect(manager.state(for: episode) == nil)
            #expect(episode.localFilename != nil)
        }
    }

    /// A caller cancelled while it was queued must not wake up and fetch.
    ///
    /// The slot is a non-throwing continuation, so cancellation cannot resume it
    /// early: the queued call is handed the slot in the ordinary way and would
    /// run the whole transfer for a user who backed out, unless it checks.
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

            secondDownload.cancel()
            gate.open()
            try await firstDownload.value
            await #expect(throws: CancellationError.self) { try await secondDownload.value }

            #expect(gate.callCount == 1)
            #expect(second.localFilename == nil)
            #expect(manager.state(for: second) == nil)
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
}
