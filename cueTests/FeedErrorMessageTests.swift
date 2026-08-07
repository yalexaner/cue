import Foundation
import Testing

@testable import cue

/// What a single-feed screen does with the error it caught. The sweep's own
/// policy is `FeedRefreshSweepTests`; this is the one-feed half of it.
struct ReportableFeedErrorMessageTests {

    /// Cancellation is silence: the sheet is already dismissed, or the view the
    /// alert would land on is gone.
    @Test func cancellationIsNotReported() {
        #expect(reportableFeedErrorMessage(for: CancellationError()) == nil)
        #expect(reportableFeedErrorMessage(for: URLError(.cancelled)) == nil)
    }

    /// Everything else is reported, with the same text the mapper produces —
    /// a real failure must not be swallowed as if it were a cancellation.
    @Test func realFailuresAreReportedVerbatim() {
        let failure = FeedService.Failure.httpStatus(403, testFeedURL)
        #expect(reportableFeedErrorMessage(for: failure) == feedErrorMessage(for: failure))
        #expect(reportableFeedErrorMessage(for: URLError(.timedOut)) != nil)
        #expect(reportableFeedErrorMessage(for: FeedParser.Failure.malformedXML) != nil)
    }
}

struct FeedErrorMessageTests {

    // MARK: - FeedService.Failure

    @Test func invalidURLMessageNamesTheInput() {
        let message = feedErrorMessage(for: FeedService.Failure.invalidURL("not a url"))
        #expect(message.contains("not a url"))
    }

    @Test func httpStatusMessageNamesStatusAndURL() {
        let message = feedErrorMessage(for: FeedService.Failure.httpStatus(403, testFeedURL))
        #expect(message.contains("403"))
        #expect(message.contains(testFeedURL))
    }

    @Test func allEpisodesOwnedElsewhereMessageNamesTheURLAndTheReason() {
        let failure = FeedService.Failure.allEpisodesOwnedElsewhere(testFeedURL)
        let message = feedErrorMessage(for: failure)
        #expect(message.contains(testFeedURL))
        #expect(message.contains("another subscription"))
    }

    // MARK: - FeedParser.Failure

    @Test func emptyFeedMessageNamesTheURL() {
        let message = feedErrorMessage(for: FeedParser.Failure.emptyFeed(testFeedURL))
        #expect(message.contains(testFeedURL))
        #expect(message.contains("No episodes"))
    }

    /// Non-empty and distinct is not enough — the message has to still describe
    /// the failure it belongs to.
    @Test func malformedXMLHasItsOwnMessage() {
        let message = feedErrorMessage(for: FeedParser.Failure.malformedXML)
        #expect(message.contains("readable RSS document"))
        #expect(message != feedErrorMessage(for: FeedParser.Failure.missingChannelTitle))
    }

    @Test func missingChannelTitleHasItsOwnMessage() {
        let message = feedErrorMessage(for: FeedParser.Failure.missingChannelTitle)
        #expect(message.contains("no title"))
        #expect(message != feedErrorMessage(for: FeedParser.Failure.emptyFeed(testFeedURL)))
    }

    // MARK: - Everything else

    @Test func transportErrorFallsBackToItsOwnDescription() {
        let error = URLError(.notConnectedToInternet)
        #expect(feedErrorMessage(for: error) == error.localizedDescription)
    }

    @Test func unknownErrorStillProducesAMessage() {
        struct Unexpected: Error {}
        #expect(!feedErrorMessage(for: Unexpected()).isEmpty)
    }
}
