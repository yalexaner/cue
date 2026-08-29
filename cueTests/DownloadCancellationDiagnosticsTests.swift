import Foundation
import SwiftData
import Testing

@testable import cue

/// What a user-initiated cancel writes to the log.
///
/// Its own suite rather than more cases in `DownloadDiagnosticsTests`, which
/// sits against the 400-line `file_length` warning `--strict` turns into an
/// error. The distinction it pins is request versus outcome: an active transfer
/// stays `.downloading` until the delegate delivers its sole terminal result, so
/// the two are different moments and one event for both makes a single cancel
/// read as two — or hides a request the session ignored because the transfer had
/// already finished.
@MainActor
struct DownloadCancellationDiagnosticsTests {
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

    @Test func cancellingALiveTransferRecordsTheRequestAndTheOutcomeSeparately() async throws {
        try await withTemporaryBaseAsync { base in
            let context = try makeContext()
            let episode = try makeEpisode(in: context)
            let sink = RecordingDiagnosticsSink()
            let gate = GatedFileTransport(stagingDirectory: base)
            let manager = DownloadManager(
                context: context, store: EpisodeStore(baseDirectory: base),
                transport: gate.transport, cancellationRequest: gate.cancellationRequest,
                diagnostics: sink)

            let running = Task { try await manager.download(episode) }
            await yieldUntil { gate.callCount == 1 }
            // only a task this attempt owns may be named, and a stub transport
            // registers none — without this `cancel` returns before it can
            // reach the gate and the transfer is never released
            manager.registerAttempt(taskIdentifier: 1, forGUID: episode.guid)
            await manager.cancel(episode)
            _ = try? await running.value

            #expect(sink.records(named: "download.cancel_requested").count == 1)
            #expect(sink.records(named: "download.cancelled").count == 1)
            #expect(sink.records(named: "download.failed").isEmpty)
        }
    }

    /// A queued attempt never reaches the delivery epilogue, so its terminal
    /// record has to be written where the waiter is resumed. Left to the
    /// epilogue it is never written at all, and the export shows a request with
    /// no outcome — the ambiguity the file exists to remove.
    @Test func cancellingAQueuedTransferStillRecordsAnOutcome() async throws {
        try await withTemporaryBaseAsync { base in
            let context = try makeContext()
            let first = try makeEpisode(in: context, guid: "guid-1")
            let second = try makeEpisode(in: context, guid: "guid-2")
            let sink = RecordingDiagnosticsSink()
            let gate = GatedFileTransport(stagingDirectory: base)
            let manager = DownloadManager(
                context: context, store: EpisodeStore(baseDirectory: base),
                transport: gate.transport, cancellationRequest: gate.cancellationRequest,
                diagnostics: sink)

            let running = Task { try await manager.download(first) }
            await yieldUntil { gate.callCount == 1 }
            let queued = Task { try await manager.download(second) }
            await yieldUntil { !manager.waiting.isEmpty }
            await manager.cancel(second)
            _ = try? await queued.value

            #expect(sink.records(named: "download.cancel_requested").count == 1)
            #expect(sink.records(named: "download.cancelled").count == 1)
            #expect(sink.records(named: "download.failed").isEmpty)

            gate.open()
            _ = try? await running.value
        }
    }
}
