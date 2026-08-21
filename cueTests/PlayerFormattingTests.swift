import Foundation
import Testing

@testable import cue

struct PlayerFormattingTests {

    @Test func zeroAndSubHourTimesUseMinutesAndSeconds() {
        #expect(playerTimeText(0) == "0:00")
        #expect(playerTimeText(5) == "0:05")
        #expect(playerTimeText(125) == "2:05")
    }

    @Test func hourRolloverUsesHoursMinutesAndSeconds() {
        #expect(playerTimeText(3_599) == "59:59")
        #expect(playerTimeText(3_600) == "1:00:00")
        #expect(playerTimeText(3_725) == "1:02:05")
    }

    @Test func elapsedTimeRoundsDown() {
        #expect(playerTimeText(59.9) == "0:59")
    }

    @Test func invalidOrAbsurdTimeSafelyRendersAsZero() {
        #expect(playerTimeText(-1) == "0:00")
        #expect(playerTimeText(.nan) == "0:00")
        #expect(playerTimeText(.infinity) == "0:00")
        #expect(playerTimeText(TimeInterval(Int.max)) == "0:00")
        #expect(playerTimeText(100 * 3_600) == "0:00")
    }

    @Test func remainingTimeCountsDownAndClampsAtTheEnd() {
        #expect(playerRemainingTimeText(elapsed: 65, duration: 125) == "-1:00")
        #expect(playerRemainingTimeText(elapsed: 200, duration: 125) == "-0:00")
    }

    @Test func unusableDurationCountsDownToNothingRatherThanToZero() {
        #expect(playerRemainingTimeText(elapsed: 20, duration: nil) == "--:--")
        #expect(playerRemainingTimeText(elapsed: 20, duration: .nan) == "--:--")
        #expect(playerRemainingTimeText(elapsed: 20, duration: .infinity) == "--:--")
        #expect(playerRemainingTimeText(elapsed: 20, duration: 0) == "--:--")
        #expect(playerRemainingTimeText(elapsed: 20, duration: TimeInterval(Int.max)) == "--:--")
        #expect(playerRemainingTimeText(elapsed: 20, duration: 100 * 3_600) == "--:--")
    }

    @Test func onlyAFiniteInBoundsPositiveDurationIsUsable() {
        #expect(isPlaybackDurationUsable(125))
        #expect(isPlaybackDurationUsable(100 * 3_600 - 1))
        #expect(!isPlaybackDurationUsable(nil))
        #expect(!isPlaybackDurationUsable(.nan))
        #expect(!isPlaybackDurationUsable(.infinity))
        #expect(!isPlaybackDurationUsable(0))
        #expect(!isPlaybackDurationUsable(-1))
        #expect(!isPlaybackDurationUsable(100 * 3_600))
        #expect(!isPlaybackDurationUsable(TimeInterval(Int.max)))
    }

    @Test func sliderBoundIsTheDurationOnlyWhileItStaysUsable() {
        #expect(playerSliderUpperBound(duration: 125) == 125)
        #expect(playerSliderUpperBound(duration: nil) == 1)
        #expect(playerSliderUpperBound(duration: .nan) == 1)
        #expect(playerSliderUpperBound(duration: 0) == 1)
        #expect(playerSliderUpperBound(duration: 100 * 3_600) == 1)
    }

    // An item-reported duration bypasses the feed bound in `playerDuration`, so
    // the placeholder bound and the disabled slider must agree on that value —
    // otherwise the slider renders live over `0...1` while elapsed runs past it.
    @Test func anAbsurdItemDurationYieldsAPlaceholderBoundAndADisabledSlider() {
        let itemDuration = playerDuration(itemDuration: 1e30, episodeDuration: 125)
        #expect(itemDuration == 1e30)
        #expect(playerSliderUpperBound(duration: itemDuration) == 1)
        #expect(!isPlaybackDurationUsable(itemDuration))
    }

    @Test func rateLabelsPreserveTheSupportedPrecision() {
        #expect(playbackRates.map(playbackRateText) == ["1.0×", "1.25×", "1.5×", "1.75×", "2.0×"])
    }
}
