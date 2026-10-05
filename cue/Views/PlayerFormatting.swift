import Foundation

/// An elapsed time as `h:mm:ss`, or `m:ss` under an hour.
///
/// Invalid and implausibly large values render as the safe zero state. The
/// bounds check must precede `Int` conversion because that conversion traps for
/// finite values outside `Int`'s range as well as for NaN and infinity.
func playerTimeText(_ time: TimeInterval) -> String {
    guard time.isFinite, time >= 0, time < maximumReasonableEpisodeDuration else { return "0:00" }

    return hoursMinutesSecondsText(Int(time.rounded(.down)))
}

/// Whether a duration can express a real position in the player.
///
/// Absent, non-finite, non-positive and absurd durations are all equally
/// unusable, and the player's three duration consumers have to agree on that:
/// a bound, a countdown and an enabled slider derived from different predicates
/// produce a control that looks live over a range that means nothing.
func isPlaybackDurationUsable(_ duration: TimeInterval?) -> Bool {
    guard let duration else { return false }
    return duration.isFinite && duration > 0 && duration < maximumReasonableEpisodeDuration
}

/// The time left in an episode, prefixed as a countdown.
///
/// An unusable duration has no remainder to count down. It renders as a
/// placeholder rather than as `-0:00`, which reads as an episode that finished.
func playerRemainingTimeText(elapsed: TimeInterval, duration: TimeInterval?) -> String {
    guard isPlaybackDurationUsable(duration), let duration else { return "--:--" }
    let safeElapsed = clampedPlaybackPosition(elapsed, duration: duration)
    return "-\(playerTimeText(duration - safeElapsed))"
}

/// The upper bound of the player's progress slider.
///
/// Never zero, because `0...0` is not a usable `Slider` range, and never derived
/// from the elapsed time: a bound that tracks elapsed pins the thumb at the far
/// end and leaves a control that can only seek backwards. An unusable duration
/// therefore yields a placeholder bound, and the view disables the slider on the
/// same predicate rather than pretending the position means something.
func playerSliderUpperBound(duration: TimeInterval?) -> TimeInterval {
    guard isPlaybackDurationUsable(duration), let duration else { return 1 }
    return duration
}

/// A picker label for a playback rate.
func playbackRateText(_ rate: Double) -> String {
    switch rate {
    case 1.0:
        return "1.0×"
    case 1.25:
        return "1.25×"
    case 1.5:
        return "1.5×"
    case 1.75:
        return "1.75×"
    case 2.0:
        return "2.0×"
    default:
        return "\(rate)×"
    }
}
