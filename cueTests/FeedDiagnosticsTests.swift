import Foundation
import SwiftData
import Testing

@testable import cue

/// What a feed fetch writes to the diagnostics sink.
///
/// The address is the credential here (spec §6), so every case checks not only
/// that a record was written but that the tokenised URL the test subscribed to
/// did not reach any field of it.
@MainActor
struct FeedDiagnosticsTests {
    private func stub(named fixture: String, statusCode: Int = 200) throws -> FeedTransportStub {
        let stub = FeedTransportStub(data: try fixtureData(named: fixture, withExtension: "rss"))
        stub.serve(statusCode: statusCode)
        return stub
    }

    private func expectNoAddressLeak(_ sink: RecordingDiagnosticsSink) {
        for record in sink.records {
            for field in record.fields {
                #expect(!field.value.contains("REDACTED_TEST_TOKEN"))
                #expect(!field.value.contains("/feed"))
            }
        }
    }

    @Test func aSuccessfulFetchRecordsTheHostTheStatusAndItsDuration() async throws {
        let context = try makeContext()
        let sink = RecordingDiagnosticsSink()
        let service = FeedService(
            context: context, transport: try stub(named: "simple").transport, diagnostics: sink)

        _ = try await service.add(urlString: testFeedURL)

        #expect(sink.eventNames == ["feed.fetch_started", "feed.fetch_succeeded"])
        let started = try #require(sink.records(named: "feed.fetch_started").first)
        #expect(started.fieldsByKey["host"] == "https://example.com")
        let succeeded = try #require(sink.records(named: "feed.fetch_succeeded").first)
        #expect(succeeded.level == .info)
        #expect(succeeded.fieldsByKey["status"] == "200")
        let elapsed = try #require(succeeded.fieldsByKey["ms"].flatMap(Int.init))
        #expect(elapsed >= 0)
        expectNoAddressLeak(sink)
    }

    @Test func aNonSuccessStatusIsRecordedAtErrorLevelWithItsStatus() async throws {
        let context = try makeContext()
        let sink = RecordingDiagnosticsSink()
        let service = FeedService(
            context: context, transport: try stub(named: "simple", statusCode: 403).transport,
            diagnostics: sink)

        await #expect(throws: FeedService.Failure.self) {
            _ = try await service.add(urlString: testFeedURL)
        }

        let record = try #require(sink.records(named: "feed.http_status").first)
        #expect(record.level == .error)
        #expect(record.fieldsByKey["status"] == "403")
        #expect(record.fieldsByKey["host"] == "https://example.com")
        #expect(sink.records(named: "feed.fetch_succeeded").isEmpty)
        expectNoAddressLeak(sink)
    }

    /// A transport error is recorded by domain and code — never by description,
    /// which for an ATS rejection or a `URLError` names the address.
    @Test func aTransportFailureIsRecordedByDomainAndCode() async throws {
        let context = try makeContext()
        let sink = RecordingDiagnosticsSink()
        let service = FeedService(
            context: context, transport: failingTransport(URLError(.timedOut)), diagnostics: sink)

        await #expect(throws: URLError.self) {
            _ = try await service.add(urlString: testFeedURL)
        }

        let record = try #require(sink.records(named: "feed.fetch_failed").first)
        #expect(record.level == .error)
        #expect(record.fieldsByKey["domain"] == URLError.errorDomain)
        #expect(record.fieldsByKey["code"] == String(URLError.Code.timedOut.rawValue))
        #expect(record.fieldsByKey["host"] == "https://example.com")
        expectNoAddressLeak(sink)
    }

    /// An address that never becomes a URL is rejected before anything is
    /// fetched, so there is nothing to time and nothing to record.
    @Test func anInvalidAddressRecordsNothing() async throws {
        let context = try makeContext()
        let sink = RecordingDiagnosticsSink()
        let service = FeedService(
            context: context, transport: try stub(named: "simple").transport, diagnostics: sink)

        await #expect(throws: FeedService.Failure.self) {
            _ = try await service.add(urlString: "notaurl")
        }

        #expect(sink.records.isEmpty)
    }

    /// A response with no status to judge is still a completed fetch; the log
    /// says so with a status of zero rather than by omitting the record.
    @Test func aNonHTTPResponseIsRecordedWithAZeroStatus() async throws {
        let context = try makeContext()
        let sink = RecordingDiagnosticsSink()
        let data = try fixtureData(named: "simple", withExtension: "rss")
        let service = FeedService(
            context: context, transport: nonHTTPTransport(data: data), diagnostics: sink)

        _ = try await service.add(urlString: testFeedURL)

        let succeeded = try #require(sink.records(named: "feed.fetch_succeeded").first)
        #expect(succeeded.fieldsByKey["status"] == "0")
    }

    /// The default is the no-op, so no existing suite writes to disk by
    /// accident — the reason every service test above had to opt in.
    @Test func theDefaultSinkIsTheNoOp() async throws {
        let context = try makeContext()
        let service = FeedService(context: context, transport: try stub(named: "simple").transport)

        _ = try await service.add(urlString: testFeedURL)
    }
}
