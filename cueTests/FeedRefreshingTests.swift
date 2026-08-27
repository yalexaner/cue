import Foundation
import SwiftData
import Testing

@testable import cue

private let firstFeedURL = "https://example.com/first"
private let secondFeedURL = "https://example.com/second"

@MainActor
private func subscribedPodcasts(in context: ModelContext) throws -> [Podcast] {
    let first = Podcast(feedURL: firstFeedURL, title: "First")
    let second = Podcast(feedURL: secondFeedURL, title: "Second")
    context.insert(first)
    context.insert(second)
    try context.save()
    return [first, second]
}

@MainActor
private func sweepStub(failures: [String: any Error] = [:]) throws -> FeedTransportStub {
    FeedTransportStub(
        data: try fixtureData(named: "simple", withExtension: "rss"), failures: failures)
}

@MainActor
struct FeedRefreshSweepTests {

    /// A dead feed does not strand the rest of the library: the sweep carries on
    /// and the healthy show is still merged.
    @Test func aFailingFeedDoesNotStopTheOthers() async throws {
        let context = try makeContext()
        let podcasts = try subscribedPodcasts(in: context)
        let failures: [String: any Error] = [firstFeedURL: StubTransportError.unreachable(firstFeedURL)]
        let transport = try sweepStub(failures: failures)
        let service = FeedService(context: context, transport: transport.transport)

        let summary = await refreshAll(podcasts, using: service)

        #expect((summary.firstFailure?.error as? StubTransportError) == .unreachable(firstFeedURL))
        #expect(summary.refreshed == 1)
        #expect(summary.failed == 1)
        #expect(transport.requestedURLStrings == [firstFeedURL, secondFeedURL])
        #expect(podcasts[1].episodes.count == 3)
    }

    /// The alert names the feed that broke first, not whichever broke last.
    @Test func theFirstFailureIsTheOneReported() async throws {
        let context = try makeContext()
        let podcasts = try subscribedPodcasts(in: context)
        let firstFailure = StubTransportError.unreachable(firstFeedURL)
        let secondFailure = StubTransportError.unreachable(secondFeedURL)
        let failures: [String: any Error] = [firstFeedURL: firstFailure, secondFeedURL: secondFailure]
        let transport = try sweepStub(failures: failures)
        let service = FeedService(context: context, transport: transport.transport)

        let summary = await refreshAll(podcasts, using: service)

        #expect((summary.firstFailure?.error as? StubTransportError) == .unreachable(firstFeedURL))
        #expect(summary.firstFailure?.host == DiagnosticsHost(firstFeedURL))
        #expect(summary.failed == 2)
    }

    /// Nothing reported, and every feed actually visited — an early return that
    /// merged nothing would otherwise satisfy "reports nothing" perfectly.
    @Test func anEntirelyHealthySweepReportsNothing() async throws {
        let context = try makeContext()
        let podcasts = try subscribedPodcasts(in: context)
        let transport = try sweepStub()
        let service = FeedService(context: context, transport: transport.transport)

        let summary = await refreshAll(podcasts, using: service)

        #expect(summary.firstFailure == nil)
        #expect(summary.refreshed == 2)
        #expect(summary.failed == 0)
        #expect(transport.requestedURLStrings == [firstFeedURL, secondFeedURL])
        #expect(podcasts[0].episodes.count == 3)
        #expect(try context.fetch(FetchDescriptor<Episode>()).count == 3)
    }

    /// Navigating away cancels the sweep. That is not a failure to alert on, and
    /// it must stop the loop rather than hammering the remaining feeds.
    @Test func cancellationStopsTheSweepAndReportsNothing() async throws {
        let context = try makeContext()
        let podcasts = try subscribedPodcasts(in: context)
        let failures: [String: any Error] = [firstFeedURL: URLError(.cancelled)]
        let transport = try sweepStub(failures: failures)
        let service = FeedService(context: context, transport: transport.transport)

        let summary = await refreshAll(podcasts, using: service)

        #expect(summary.firstFailure == nil)
        #expect(summary.failed == 0)
        #expect(summary.refreshed == 0)
        #expect(transport.requestedURLStrings == [firstFeedURL])
    }

    /// A cancellation part-way through must not become the reported error and
    /// mask nothing, nor be reported ahead of a real failure that preceded it.
    @Test func cancellationAfterARealFailureStillReportsTheFailure() async throws {
        let context = try makeContext()
        let podcasts = try subscribedPodcasts(in: context)
        let firstFailure = StubTransportError.unreachable(firstFeedURL)
        let failures: [String: any Error] = [firstFeedURL: firstFailure, secondFeedURL: CancellationError()]
        let transport = try sweepStub(failures: failures)
        let service = FeedService(context: context, transport: transport.transport)

        let summary = await refreshAll(podcasts, using: service)

        #expect((summary.firstFailure?.error as? StubTransportError) == .unreachable(firstFeedURL))
        #expect(summary.failed == 1)
    }

    /// A task cancelled before the loop begins issues no request at all — the
    /// pre-loop check, which the error paths above can never reach because they
    /// only ever cancel by *throwing* from a request already in flight.
    @Test func aSweepCancelledBeforeItStartsIssuesNoRequests() async throws {
        let context = try makeContext()
        let podcasts = try subscribedPodcasts(in: context)
        let transport = try sweepStub()
        let service = FeedService(context: context, transport: transport.transport)

        // both this test and the task body are main-actor isolated, and nothing
        // between them suspends, so the body cannot have begun by the time
        // `cancel()` lands — no gate needed to make that deterministic
        let sweep = Task { @MainActor in await refreshAll(podcasts, using: service) }
        sweep.cancel()

        #expect(await sweep.value.firstFailure == nil)
        #expect(await sweep.value.refreshed == 0)
        #expect(transport.requestedURLStrings.isEmpty)
    }

    /// The status line needs to know which feed is outstanding *before* the
    /// fetch, not after it — reporting it afterwards would name the feed that
    /// already answered.
    @Test func eachStepIsReportedBeforeItsFeedIsFetched() async throws {
        let context = try makeContext()
        let podcasts = try subscribedPodcasts(in: context)
        let transport = try sweepStub()
        let service = FeedService(context: context, transport: transport.transport)
        var steps: [FeedRefreshStep] = []

        _ = await refreshAll(podcasts, using: service) { step in
            steps.append(step)
            // reported before the fetch: the first callback lands with nothing
            // requested yet, the second with exactly one request behind it
            #expect(transport.requestedURLStrings.count == step.index)
        }

        #expect(steps.map(\.host.redacted) == ["https://example.com", "https://example.com"])
        #expect(steps.map(\.index) == [0, 1])
        #expect(steps.allSatisfy { $0.total == 2 })
    }

    /// A dead feed among healthy ones is a partial success, and the summary is
    /// what lets the screen say so instead of "the refresh failed".
    @Test func aPartialSweepIsSummarisedAsBothCounts() async throws {
        let context = try makeContext()
        let podcasts = try subscribedPodcasts(in: context)
        let failures: [String: any Error] = [secondFeedURL: StubTransportError.unreachable(secondFeedURL)]
        let transport = try sweepStub(failures: failures)
        let service = FeedService(context: context, transport: transport.transport)

        let summary = await refreshAll(podcasts, using: service)

        #expect(summary.refreshed == 1)
        #expect(summary.failed == 1)
        #expect(feedRefreshSummaryText(refreshed: summary.refreshed, failed: summary.failed) != nil)
    }

    @Test func anEmptyLibrarySweepsCleanly() async throws {
        let context = try makeContext()
        let transport = try sweepStub()
        let service = FeedService(context: context, transport: transport.transport)

        #expect(await refreshAll([], using: service).firstFailure == nil)
        #expect(transport.requestedURLStrings.isEmpty)
        #expect(try context.fetch(FetchDescriptor<Podcast>()).isEmpty)
    }
}

struct CancellationClassificationTests {

    @Test func cooperativeCancellationIsRecognised() {
        #expect(isCancellation(CancellationError()))
        #expect(isCancellation(URLError(.cancelled)))
    }

    @Test func realFailuresAreNotCancellation() {
        #expect(!isCancellation(URLError(.notConnectedToInternet)))
        #expect(!isCancellation(URLError(.timedOut)))
        #expect(!isCancellation(FeedService.Failure.invalidURL("")))
        #expect(!isCancellation(FeedParser.Failure.malformedXML))
    }
}
