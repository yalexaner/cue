import Foundation
import Testing

@testable import cue

/// What a single-feed screen does with the error it caught. The sweep's own
/// policy is `FeedRefreshSweepTests`; this is the one-feed half of it.
struct ReportableFeedErrorMessageTests {

    /// Cancellation is silence: the sheet is already dismissed, or the view the
    /// alert would land on is gone.
    @Test func cancellationIsNotReported() {
        #expect(reportableFeedErrorMessage(for: CancellationError(), host: nil) == nil)
        #expect(reportableFeedErrorMessage(for: URLError(.cancelled), host: nil) == nil)
    }

    /// Everything else is reported, with the same text the mapper produces —
    /// a real failure must not be swallowed as if it were a cancellation.
    @Test func realFailuresAreReportedVerbatim() {
        let failure = FeedService.Failure.httpStatus(403, testFeedURL)
        #expect(
            reportableFeedErrorMessage(for: failure, host: nil) == feedErrorMessage(for: failure, host: nil))
        #expect(reportableFeedErrorMessage(for: URLError(.timedOut), host: nil) != nil)
        #expect(reportableFeedErrorMessage(for: FeedParser.Failure.malformedXML, host: nil) != nil)
    }
}

struct FeedErrorMessageTests {

    // MARK: - FeedService.Failure

    @Test func invalidURLMessageNamesTheInput() {
        let message = feedErrorMessage(for: FeedService.Failure.invalidURL("not a url"), host: nil)
        #expect(message.contains("not a url"))
    }

    @Test func httpStatusMessageNamesStatusAndURL() {
        let message = feedErrorMessage(for: FeedService.Failure.httpStatus(403, testFeedURL), host: nil)
        #expect(message.contains("403"))
        #expect(message.contains(testFeedURL))
    }

    @Test func allEpisodesOwnedElsewhereMessageNamesTheURLAndTheReason() {
        let failure = FeedService.Failure.allEpisodesOwnedElsewhere(testFeedURL)
        let message = feedErrorMessage(for: failure, host: nil)
        #expect(message.contains(testFeedURL))
        #expect(message.contains("another subscription"))
    }

    // MARK: - FeedParser.Failure

    @Test func emptyFeedMessageNamesTheURL() {
        let message = feedErrorMessage(for: FeedParser.Failure.emptyFeed(testFeedURL), host: nil)
        #expect(message.contains(testFeedURL))
        #expect(message.contains("No episodes"))
    }

    /// Non-empty and distinct is not enough — the message has to still describe
    /// the failure it belongs to.
    @Test func malformedXMLHasItsOwnMessage() {
        let message = feedErrorMessage(for: FeedParser.Failure.malformedXML, host: nil)
        #expect(message.contains("readable RSS document"))
        #expect(message != feedErrorMessage(for: FeedParser.Failure.missingChannelTitle, host: nil))
    }

    @Test func missingChannelTitleHasItsOwnMessage() {
        let message = feedErrorMessage(for: FeedParser.Failure.missingChannelTitle, host: nil)
        #expect(message.contains("no title"))
        #expect(message != feedErrorMessage(for: FeedParser.Failure.emptyFeed(testFeedURL), host: nil))
    }

    // MARK: - Everything else

    @Test func transportErrorFallsBackToItsOwnDescription() {
        let error = URLError(.notConnectedToInternet)
        #expect(feedErrorMessage(for: error, host: nil) == error.localizedDescription)
    }

    @Test func unknownErrorStillProducesAMessage() {
        struct Unexpected: Error {}
        #expect(!feedErrorMessage(for: Unexpected(), host: nil).isEmpty)
    }

    /// A `URLError` says "the request timed out" and nothing about where, so a
    /// sweep over several subscriptions could not say which one broke.
    @Test func aTransportErrorNamesTheHostWhenOneIsKnown() {
        let error = URLError(.timedOut)
        let message = feedErrorMessage(for: error, host: DiagnosticsHost(testFeedURL))
        #expect(message.contains("example.com"))
        #expect(message.contains(error.localizedDescription))
    }

    /// Only scheme and host: the rest of a private feed's URL is its credential,
    /// and this text goes on screen.
    @Test func aNamedHostCarriesNoPathOrQuery() {
        let message = feedErrorMessage(for: URLError(.timedOut), host: DiagnosticsHost(testFeedURL))
        #expect(!message.contains("REDACTED_TEST_TOKEN"))
        #expect(!message.contains("token"))
    }

    /// An error that names its own address is left alone — prefixing the host
    /// would say it twice.
    @Test func anErrorThatAlreadyNamesItsAddressIsNotPrefixed() {
        let failure = FeedService.Failure.httpStatus(403, testFeedURL)
        let named = feedErrorMessage(for: failure, host: DiagnosticsHost(testFeedURL))
        #expect(named == feedErrorMessage(for: failure, host: nil))
    }
}
