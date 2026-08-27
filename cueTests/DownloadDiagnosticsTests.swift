import Foundation
import SwiftData
import Testing

@testable import cue

/// What the download and feed routes write to the diagnostics sink, and the
/// background-delivery accounting that had to move for those records to survive.
///
/// Its own suite rather than an addition to `DownloadManagerTests` (384 lines)
/// or `DownloadManagerRelaunchTests` (363): both sit close enough to the
/// 400-line `file_length` warning `--strict` turns into an error that this
/// task's cases would push one over.
@MainActor
struct DownloadDiagnosticsTests {
    private static let enclosureURL = "https://example.com/audio/1.mp3"
    private static let tokenBearingEnclosure =
        "https://example.com/audio/1.mp3?token=REDACTED_TEST_TOKEN#fragment"

    private func makeEpisode(
        in context: ModelContext, guid: String = "guid-1",
        enclosureURL: String = DownloadDiagnosticsTests.enclosureURL
    ) throws -> Episode {
        let podcast = Podcast(feedURL: testFeedURL, title: "Show")
        context.insert(podcast)
        let episode = Episode(guid: guid, title: "Episode", enclosureURL: enclosureURL)
        episode.podcast = podcast
        context.insert(episode)
        try context.save()
        return episode
    }

    // MARK: - The event vocabulary

    /// Every case reduces to safe fields: a digest for a guid, scheme plus host
    /// for an address, a domain and a code for an error — never a description.
    @Test func everyEventReducesToRedactedFields() {
        let guid = DiagnosticsGUID("https://example.com/item?token=REDACTED_TEST_TOKEN")
        let attempt = DiagnosticsAttemptID(token: UUID())
        let host = DiagnosticsHost(Self.tokenBearingEnclosure)

        let started = DiagnosticsEvent.downloadStarted(guid: guid, attempt: attempt, host: host).record
        #expect(started.event == "download.started")
        #expect(started.category == .downloads)
        #expect(started.level == .info)
        #expect(started.fields.map(\.key) == ["guid", "attempt", "host"])
        #expect(started.fieldsByKey["guid"] == guid.digest)
        #expect(started.fieldsByKey["attempt"] == attempt.value)
        #expect(started.fieldsByKey["host"] == "https://example.com")

        let queued = DiagnosticsEvent.downloadQueued(guid: guid, attempt: attempt, position: 2).record
        #expect(queued.fieldsByKey["position"] == "2")

        let decile = DiagnosticsEvent.downloadDecile(
            guid: guid, attempt: attempt, decile: 7, bytes: 4096
        ).record
        #expect(decile.fields.map(\.key) == ["guid", "attempt", "decile", "bytes"])
        #expect(decile.fieldsByKey["bytes"] == "4096")

        let launch = DiagnosticsEvent.launch(build: "0.1.0 (1)").record
        #expect(launch.category == .storage)
        #expect(launch.fieldsByKey["build"] == "0.1.0 (1)")
    }

    /// A failure record carries the bridged domain and code and nothing else.
    /// `URLError.timedOut` is `NSURLErrorDomain` / -1001; neither says anything
    /// about the address that timed out.
    @Test func aFailureRecordCarriesOnlyADomainAndACode() {
        let guid = DiagnosticsGUID("guid-1")
        let attempt = DiagnosticsAttemptID(token: UUID())
        let code = DiagnosticsErrorCode(URLError(.timedOut))

        let record = DiagnosticsEvent.downloadFailed(guid: guid, attempt: attempt, code: code).record

        #expect(record.level == .error)
        #expect(record.fields.map(\.key) == ["guid", "attempt", "domain", "code"])
        #expect(record.fieldsByKey["domain"] == URLError.errorDomain)
        #expect(record.fieldsByKey["code"] == String(URLError.Code.timedOut.rawValue))
    }

    /// A hostile domain cannot smuggle text past the field vocabulary.
    @Test func anErrorDomainIsSanitisedAndBounded() {
        let hostile = NSError(
            domain: "https://example.com/leak?token=REDACTED_TEST_TOKEN\tand a\nnewline",
            code: 7)

        let code = DiagnosticsErrorCode(hostile)

        #expect(code.code == 7)
        #expect(!code.domain.contains("?"))
        #expect(!code.domain.contains("\t"))
        #expect(!code.domain.contains("\n"))
        #expect(code.domain.count <= DiagnosticsErrorCode.maximumDomainLength)
    }

    /// Spec §6: the enclosure address is pre-signed, so a 403 has to be readable
    /// from the status and the host alone.
    @Test func anHTTPStatusRecordCarriesTheStatusTheDigestAndNoAddressBeyondTheHost() async throws {
        try await withTemporaryBaseAsync { base in
            let context = try makeContext()
            let episode = try makeEpisode(
                in: context, enclosureURL: Self.tokenBearingEnclosure)
            let sink = RecordingDiagnosticsSink()
            let stub = DownloadTransportStub(stagingDirectory: base)
            stub.serve(statusCode: 403)
            let manager = DownloadManager(
                context: context, store: EpisodeStore(baseDirectory: base),
                transport: stub.transport, diagnostics: sink)

            await #expect(throws: DownloadManager.Failure.self) { try await manager.download(episode) }

            let record = try #require(sink.records(named: "download.http_status").first)
            #expect(record.level == .error)
            #expect(record.fieldsByKey["status"] == "403")
            #expect(record.fieldsByKey["guid"] == DiagnosticsGUID(episode.guid).digest)
            #expect(record.fieldsByKey["host"] == "https://example.com")
            for field in record.fields {
                #expect(!field.value.contains("REDACTED_TEST_TOKEN"))
                #expect(!field.value.contains("/audio/"))
            }
        }
    }

    /// The remaining cases, so the whole vocabulary's field set is pinned in one
    /// place rather than only where a route happens to write it.
    @Test func theRemainingEventsCarryExactlyTheirDocumentedFields() {
        let guid = DiagnosticsGUID("guid-1")
        let attempt = DiagnosticsAttemptID(token: UUID())
        let host = DiagnosticsHost("https://example.com/audio/1.mp3?token=REDACTED_TEST_TOKEN")

        let requested = DiagnosticsEvent.downloadRequested(guid: guid, host: host).record
        #expect(requested.event == "download.requested")
        #expect(requested.fields.map(\.key) == ["guid", "host"])
        #expect(requested.fieldsByKey["host"] == "https://example.com")

        let firstByte = DiagnosticsEvent.downloadFirstByte(guid: guid, attempt: attempt, bytes: 1).record
        #expect(firstByte.event == "download.first_byte")
        #expect(firstByte.fields.map(\.key) == ["guid", "attempt", "bytes"])

        // spelled one per line rather than as a literal: a multiline collection
        // literal cannot satisfy `swift-format` and SwiftLint at once (AGENTS.md)
        let cancelled = DiagnosticsEvent.downloadCancelled(guid: guid, attempt: attempt).record
        let moved = DiagnosticsEvent.downloadFileMoved(guid: guid, attempt: attempt).record
        let finished = DiagnosticsEvent.downloadFinished(guid: guid, attempt: attempt).record
        #expect(cancelled.fields.map(\.key) == ["guid", "attempt"])
        #expect(moved.fields.map(\.key) == ["guid", "attempt"])
        #expect(finished.fields.map(\.key) == ["guid", "attempt"])
        #expect(cancelled.level == .info)

        let adopted = DiagnosticsEvent.downloadAdopted(guid: guid, attempt: attempt, taskIdentifier: 3).record
        #expect(adopted.fields.map(\.key) == ["guid", "attempt", "task"])
        #expect(DiagnosticsEvent.downloadDeleted(guid: guid).record.fields.map(\.key) == ["guid"])

        let feedStarted = DiagnosticsEvent.feedFetchStarted(host: host).record
        #expect(feedStarted.fields.map(\.key) == ["host"])
        let feedFailed = DiagnosticsEvent.feedFetchFailed(
            host: host, code: DiagnosticsErrorCode(URLError(.timedOut)), elapsedMilliseconds: 5
        ).record
        #expect(feedFailed.fields.map(\.key) == ["host", "domain", "code", "ms"])
    }

    /// The correlation identifier is the attempt's own ownership token, so it is
    /// stable for one attempt and different for the retry that replaces it.
    @Test func theCorrelationIdentifierIsDerivedFromTheAttemptToken() {
        let token = UUID()

        #expect(DiagnosticsAttemptID(token: token) == DiagnosticsAttemptID(token: token))
        #expect(DiagnosticsAttemptID(token: token) != DiagnosticsAttemptID(token: UUID()))
        #expect(DiagnosticsAttemptID(token: token).value.count == DiagnosticsAttemptID.length)
        #expect(!DiagnosticsAttemptID(token: token).value.contains("-"))
    }

    // MARK: - Decile bucketing

    @Test func repeatedCallbacksInsideOneDecileLogOnce() {
        let first = DownloadProgress.fraction(bytesWritten: 30, value: 0.31)
        let again = DownloadProgress.fraction(bytesWritten: 35, value: 0.38)

        #expect(crossedDecile(for: first, lastLogged: nil) == 3)
        #expect(crossedDecile(for: again, lastLogged: 3) == nil)
    }

    /// Only the bucket actually reached, not every one skipped over.
    @Test func aMultiDecileJumpLogsOnlyTheBucketReached() {
        let jumped = DownloadProgress.fraction(bytesWritten: 900, value: 0.94)

        #expect(crossedDecile(for: jumped, lastLogged: 1) == 9)
    }

    /// An indeterminate report is the server declining to say how big the file
    /// is; there is no decile to be in.
    @Test func anUnknownTotalHasNoDecile() {
        #expect(crossedDecile(for: .indeterminate(bytesWritten: 4096), lastLogged: nil) == nil)
        #expect(crossedDecile(for: .waiting, lastLogged: nil) == nil)
        #expect(crossedDecile(for: .fraction(bytesWritten: 1, value: 0.04), lastLogged: nil) == nil)
    }

    /// The highest logged decile lives on the attempt, so a retry — a new
    /// attempt for the same guid — starts again from nothing.
    @Test func aRetiredAttemptDropsItsDecileRecord() async throws {
        try await withTemporaryBaseAsync { base in
            let context = try makeContext()
            let episode = try makeEpisode(in: context)
            let sink = RecordingDiagnosticsSink()
            let stub = DownloadTransportStub(stagingDirectory: base)
            let manager = DownloadManager(
                context: context, store: EpisodeStore(baseDirectory: base),
                transport: stub.transport, diagnostics: sink)

            stub.reportOnNextAnswer(.fraction(bytesWritten: 60, value: 0.6))
            stub.setAttemptRegistrationHandler { identifier, guid in
                await manager.registerStartedAttempt(taskIdentifier: identifier, forGUID: guid)
            }
            stub.setProgressHandler { identifier, guid, progress in
                Task { @MainActor in
                    manager.handleProgress(taskIdentifier: identifier, guid: guid, progress: progress)
                }
            }
            try await manager.download(episode)
            await yieldUntil { !sink.records(named: "download.decile").isEmpty }

            #expect(manager.attempts[episode.guid] == nil)
            let deciles = sink.records(named: "download.decile")
            #expect(deciles.count == 1)
            #expect(deciles.first?.fieldsByKey["decile"] == "6")
            #expect(sink.records(named: "download.first_byte").count == 1)
        }
    }

    // MARK: - A whole transfer

    @Test func aSuccessfulDownloadRecordsItsWholeArc() async throws {
        try await withTemporaryBaseAsync { base in
            let context = try makeContext()
            let episode = try makeEpisode(in: context)
            let sink = RecordingDiagnosticsSink()
            let stub = DownloadTransportStub(stagingDirectory: base)
            let manager = DownloadManager(
                context: context, store: EpisodeStore(baseDirectory: base),
                transport: stub.transport, diagnostics: sink)

            try await manager.download(episode)

            let expected = ["download.requested", "download.started", "download.file_moved", "download.finished"]
            #expect(sink.eventNames == expected)
            let digest = DiagnosticsGUID(episode.guid).digest
            #expect(sink.records.allSatisfy { $0.fieldsByKey["guid"] == digest })
        }
    }

    @Test func aDeletedDownloadIsRecorded() async throws {
        try await withTemporaryBaseAsync { base in
            let context = try makeContext()
            let episode = try makeEpisode(in: context)
            let sink = RecordingDiagnosticsSink()
            let stub = DownloadTransportStub(stagingDirectory: base)
            let manager = DownloadManager(
                context: context, store: EpisodeStore(baseDirectory: base),
                transport: stub.transport, diagnostics: sink)
            try await manager.download(episode)

            try manager.deleteDownload(for: episode)

            #expect(sink.records(named: "download.deleted").count == 1)
        }
    }

    /// Adoption is the only trace a transfer this process never started leaves
    /// before its outcome arrives.
    @Test func anAdoptedTransferIsRecordedWithItsTaskIdentifier() async throws {
        try await withTemporaryBaseAsync { base in
            let context = try makeContext()
            let episode = try makeEpisode(in: context)
            let sink = RecordingDiagnosticsSink()
            let manager = DownloadManager(
                context: context, store: EpisodeStore(baseDirectory: base),
                transport: failingFileTransport(), diagnostics: sink)

            manager.adopt(
                inFlightAttempts: [DownloadAttemptIdentity(taskIdentifier: 42, guid: episode.guid)])

            let record = try #require(sink.records(named: "download.adopted").first)
            #expect(record.fieldsByKey["task"] == "42")
            #expect(record.fieldsByKey["guid"] == DiagnosticsGUID(episode.guid).digest)
        }
    }

    /// Cancellation is the user backing out, not a failure: it must never be
    /// written at `.error`, and never as a `download.failed`.
    @Test func cancellationIsRecordedAsItselfRatherThanAsAFailure() async throws {
        try await withTemporaryBaseAsync { base in
            let context = try makeContext()
            let episode = try makeEpisode(in: context)
            let sink = RecordingDiagnosticsSink()
            let manager = DownloadManager(
                context: context, store: EpisodeStore(baseDirectory: base),
                transport: failingFileTransport(CancellationError()), diagnostics: sink)

            await #expect(throws: CancellationError.self) { try await manager.download(episode) }

            #expect(sink.records(named: "download.failed").isEmpty)
            #expect(sink.records(named: "download.cancelled").count == 1)
        }
    }
}
