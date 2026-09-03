import Foundation
import Testing

@testable import cue

struct PlaybackPolicyTests {

    @Test func ratesAreTheFiveSupportedValuesInOrder() {
        #expect(playbackRates == [1.0, 1.25, 1.5, 1.75, 2.0])
    }

    @Test func positionClampsToTheAvailableRange() {
        #expect(clampedPlaybackPosition(-20, duration: 100) == 0)
        #expect(clampedPlaybackPosition(40, duration: 100) == 40)
        #expect(clampedPlaybackPosition(120, duration: 100) == 100)
    }

    @Test func nonFiniteTargetAnswersZero() {
        #expect(clampedPlaybackPosition(.nan, duration: 100) == 0)
        #expect(clampedPlaybackPosition(.infinity, duration: 100) == 0)
        #expect(clampedPlaybackPosition(-.infinity, duration: 100) == 0)
    }

    @Test func durationWithoutAUsefulUpperBoundOnlyClampsTheLowerBound() {
        #expect(clampedPlaybackPosition(120, duration: .infinity) == 120)
        #expect(clampedPlaybackPosition(-20, duration: .nan) == 0)
        #expect(clampedPlaybackPosition(400_000, duration: 100 * 3_600) == 400_000)
    }

    @Test func itemDurationWinsWhenItIsFiniteAndPositive() {
        #expect(playerDuration(itemDuration: 180, episodeDuration: 120) == 180)
        #expect(playerDuration(itemDuration: 1e30, episodeDuration: 120) == 1e30)
    }

    @Test func usableEpisodeDurationIsTheFallback() {
        #expect(playerDuration(itemDuration: nil, episodeDuration: 120) == 120)
        #expect(playerDuration(itemDuration: .infinity, episodeDuration: 120) == 120)
        #expect(playerDuration(itemDuration: 0, episodeDuration: 120) == 120)
    }

    @Test func unusableEpisodeDurationHasNoFallback() {
        #expect(playerDuration(itemDuration: nil, episodeDuration: nil) == nil)
        #expect(playerDuration(itemDuration: nil, episodeDuration: 0) == nil)
        #expect(playerDuration(itemDuration: nil, episodeDuration: .nan) == nil)
        #expect(playerDuration(itemDuration: nil, episodeDuration: 100 * 3_600) == nil)
        #expect(playerDuration(itemDuration: nil, episodeDuration: TimeInterval(Int.max)) == nil)
    }

    @Test func onlyLadderRatesAreValid() {
        for rate in playbackRates {
            #expect(isValidPlaybackRate(rate))
        }
        #expect(!isValidPlaybackRate(1.1))
    }

    @Test func loadDecisionReusesOnlyTheSameLivePair() {
        #expect(
            playLoadDecision(
                loadedGUID: "episode", loadedFilename: "audio.mp3",
                requestedGUID: "episode", requestedFilename: "audio.mp3",
                itemFailed: false, itemEnded: false
            ) == .reuse
        )
    }

    @Test func loadDecisionRestartsTheSameEndedPair() {
        #expect(
            playLoadDecision(
                loadedGUID: "episode", loadedFilename: "audio.mp3",
                requestedGUID: "episode", requestedFilename: "audio.mp3",
                itemFailed: false, itemEnded: true
            ) == .restart
        )
    }

    @Test func loadDecisionReloadsFailedChangedAndMissingItems() {
        #expect(
            playLoadDecision(
                loadedGUID: "episode", loadedFilename: "audio.mp3",
                requestedGUID: "episode", requestedFilename: "audio.mp3",
                itemFailed: true, itemEnded: false
            ) == .reload
        )
        #expect(
            playLoadDecision(
                loadedGUID: "episode", loadedFilename: "old.mp3",
                requestedGUID: "episode", requestedFilename: "new.mp3",
                itemFailed: false, itemEnded: false
            ) == .reload
        )
        #expect(
            playLoadDecision(
                loadedGUID: nil, loadedFilename: nil,
                requestedGUID: "episode", requestedFilename: "audio.mp3",
                itemFailed: false, itemEnded: false
            ) == .reload
        )
    }

    @Test func aResumePositionAtTheEndRestartsFromTheBeginning() {
        #expect(playbackResumePosition(100, duration: 100) == 0)
        #expect(playbackResumePosition(99.5, duration: 100) == 0)
        // a stored position past a shortened duration is still the end
        #expect(playbackResumePosition(150, duration: 100) == 0)
    }

    @Test func aResumePositionShortOfTheEndIsKept() {
        #expect(playbackResumePosition(40, duration: 100) == 40)
        #expect(playbackResumePosition(98, duration: 100) == 98)
        #expect(playbackResumePosition(-5, duration: 100) == 0)
        // nothing has measured the file, so no end is known to compare against
        // and the raw position survives for the ready seam to judge
        #expect(playbackResumePosition(4000, duration: nil) == 4000)
    }

    @Test func aMeasuredDurationAlwaysOutranksTheFeedFallback() {
        #expect(reconciledPlaybackDuration(measured: 200, fallback: 100, position: 150) == 200)
        #expect(reconciledPlaybackDuration(measured: 80, fallback: nil, position: 0) == 80)
    }

    /// Nothing measured the file, so the feed's claim is all there is — it is
    /// kept while the playhead is inside it and dropped once the playhead has
    /// passed it, because a length playback is already beyond is provably
    /// wrong and would otherwise clamp the position back onto itself.
    @Test func anUnmeasuredFeedLengthSurvivesOnlyWhileThePlayheadIsInsideIt() {
        #expect(reconciledPlaybackDuration(measured: nil, fallback: 100, position: 40) == 100)
        #expect(reconciledPlaybackDuration(measured: nil, fallback: 100, position: 100) == 100)
        #expect(reconciledPlaybackDuration(measured: nil, fallback: 100, position: 150) == nil)
        #expect(reconciledPlaybackDuration(measured: nil, fallback: nil, position: 0) == nil)
    }
    /// An unmeasured episode carries its raw position through the load: a feed
    /// that understates its file may neither clamp the playhead onto its
    /// claimed end nor survive as a bound the playhead has already passed.
    @Test func loadedPlayheadRefusesToLetTheFeedJudgeAnUnmeasuredPosition() {
        let playhead = loadedPlayhead(150, measured: nil, feed: 100)

        #expect(playhead.position == 150)
        #expect(playhead.duration == nil)
    }

    /// Inside the feed's claimed length the fallback still drives the UI.
    @Test func loadedPlayheadKeepsAFeedLengthThePlayheadIsInside() {
        let playhead = loadedPlayhead(40, measured: nil, feed: 100)

        #expect(playhead.position == 40)
        #expect(playhead.duration == 100)
    }

    /// A measured length is authoritative for both answers, and one reached at
    /// its end is a finished episode that restarts from the beginning.
    @Test(arguments: [(40.0, 40.0), (99.5, 0.0), (150.0, 0.0)])
    func loadedPlayheadJudgesAgainstTheMeasuredLength(
        position: TimeInterval, expected: TimeInterval
    ) {
        let playhead = loadedPlayhead(position, measured: 100, feed: 250)

        #expect(playhead.position == expected)
        #expect(playhead.duration == 100)
    }

}
