import Foundation
import Testing

@testable import cue

private func step(_ host: String, index: Int = 0, total: Int = 1) -> FeedRefreshStep {
    FeedRefreshStep(host: DiagnosticsHost(host), index: index, total: total)
}

struct FeedRefreshStatusTextTests {

    @Test func nothingRunningSaysNothing() {
        #expect(feedRefreshStatusText(for: nil) == nil)
    }

    /// A single feed carries no position: "(1 of 1)" is noise.
    @Test func aSingleFeedIsNamedWithoutAPosition() {
        let text = feedRefreshStatusText(for: .fetching(host: "https://example.com", index: 0, total: 1))
        #expect(text == "Checking https://example.com…")
    }

    /// The position is one-based on screen while the index is zero-based in the
    /// sweep — the off-by-one is exactly what this pins.
    @Test func aSweepCarriesAOneBasedPosition() {
        let text = feedRefreshStatusText(for: .fetching(host: "https://example.com", index: 1, total: 5))
        #expect(text == "Checking https://example.com (2 of 5)…")
    }

    @Test func stillWaitingReadsDifferentlyFromFetching() {
        let waiting = feedRefreshStatusText(for: .stillWaiting(host: "https://example.com", index: 0, total: 1))
        let fetching = feedRefreshStatusText(for: .fetching(host: "https://example.com", index: 0, total: 1))
        #expect(waiting == "Still waiting for https://example.com…")
        #expect(waiting != fetching)
    }
}

struct FeedRefreshSummaryTextTests {

    /// A clean sweep is silent — a banner saying "refreshed 5 of 5" is chrome
    /// nobody asked for.
    @Test func aCleanSweepSaysNothing() {
        #expect(feedRefreshSummaryText(refreshed: 5, failed: 0) == nil)
    }

    /// An entirely failed sweep is the alert's story; saying it twice is worse
    /// than saying it once.
    @Test func anEntirelyFailedSweepSaysNothingHere() {
        #expect(feedRefreshSummaryText(refreshed: 0, failed: 3) == nil)
        #expect(feedRefreshSummaryText(refreshed: 0, failed: 0) == nil)
    }

    @Test func aPartialSweepCarriesBothCounts() {
        let text = feedRefreshSummaryText(refreshed: 4, failed: 1)
        #expect(text == "Refreshed 4 of 5 feeds; 1 could not be reached.")
    }
}

@MainActor
struct FeedRefreshStatusModelTests {

    @Test func nothingIsSaidBeforeASweepStarts() {
        let model = FeedRefreshStatusModel(clock: ManualDownloadClock())
        #expect(model.phase == nil)
        #expect(model.statusText == nil)
    }

    @Test func aStartedFeedIsFetchingUntilTheThresholdPasses() async {
        let clock = ManualDownloadClock()
        let model = FeedRefreshStatusModel(clock: clock)

        model.began(step("https://example.com"))

        #expect(model.phase == .fetching(host: "https://example.com", index: 0, total: 1))
        await yieldUntil { clock.pendingSleepCount == 1 }
        #expect(clock.requestedSleeps == [FeedRefreshStatus.stillWaitingThreshold])
    }

    /// The transition nothing else can produce: no byte arrives to trigger it,
    /// so the model has to be waiting on the clock.
    @Test func fiveSilentSecondsBecomeStillWaiting() async {
        let clock = ManualDownloadClock()
        let model = FeedRefreshStatusModel(clock: clock)

        model.began(step("https://example.com", index: 2, total: 4))
        await yieldUntil { clock.pendingSleepCount == 1 }
        clock.advance(by: FeedRefreshStatus.stillWaitingThreshold)
        clock.wake()

        await yieldUntil { model.phase == .stillWaiting(host: "https://example.com", index: 2, total: 4) }
        #expect(model.statusText?.hasPrefix("Still waiting") == true)
    }

    /// The next feed replaces the current one, and the wait armed for the
    /// previous feed must not land on it afterwards.
    @Test func aRetiredWaitCannotOverwriteTheFeedThatReplacedIt() async {
        let clock = ManualDownloadClock()
        let model = FeedRefreshStatusModel(clock: clock)

        model.began(step("https://first.example.com", index: 0, total: 2))
        await yieldUntil { clock.pendingSleepCount == 1 }
        model.began(step("https://second.example.com", index: 1, total: 2))
        // waited on the replacement's *phase*, not on a requested duration: the
        // second wait records its duration before it parks, so a single
        // `wake()` fired on that count can release nothing. `wake(_:until:)`
        // retries instead. The first feed's wait is cancelled here but may not
        // have observed it yet, which is the race this test exists for
        await wake(clock) { model.phase != .fetching(host: "https://second.example.com", index: 1, total: 2) }

        #expect(model.phase == .stillWaiting(host: "https://second.example.com", index: 1, total: 2))
    }

    /// The sweep ending takes the banner away, whatever it was showing.
    @Test func finishingClearsTheStatusAndItsPendingWait() async {
        let clock = ManualDownloadClock()
        let model = FeedRefreshStatusModel(clock: clock)

        model.began(step("https://example.com"))
        await yieldUntil { clock.pendingSleepCount == 1 }
        model.finished()

        #expect(model.phase == nil)
        #expect(model.statusText == nil)
        await yieldUntil { clock.pendingSleepCount == 0 }

        // a wake after the fact must not resurrect the banner on a screen that
        // is no longer refreshing
        clock.wake()
        await Task.yield()
        #expect(model.phase == nil)
    }
}
