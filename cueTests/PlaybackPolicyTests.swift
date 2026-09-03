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
}
