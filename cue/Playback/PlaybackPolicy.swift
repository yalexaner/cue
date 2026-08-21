import Foundation
import MediaPlayer

/// A hundred hours is the boundary between a useful episode duration and a
/// feed-authored absurdity.
///
/// `DurationParser` deliberately keeps representable values wider than `Int`,
/// so every consumer must guard the conversion independently of the parser.
let maximumReasonableEpisodeDuration: TimeInterval = 100 * 3_600

/// Playback rates offered by the player, in picker order.
let playbackRates: [Double] = [1.0, 1.25, 1.5, 1.75, 2.0]

/// Builds the complete metadata payload published for the loaded episode.
///
/// Artwork is deliberately absent: playback is local-only and the app does not
/// yet have an artwork download or cache pipeline. An unknown duration is
/// omitted so the system does not advertise a false zero-length timeline.
func nowPlayingInfo(
    title: String, podcastTitle: String, duration: TimeInterval?, elapsed: TimeInterval, rate: Double
) -> [String: Any] {
    var info: [String: Any] = [:]
    info[MPMediaItemPropertyTitle] = title
    info[MPMediaItemPropertyAlbumTitle] = podcastTitle
    info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
    info[MPNowPlayingInfoPropertyPlaybackRate] = rate
    if let duration {
        info[MPMediaItemPropertyPlaybackDuration] = duration
    }
    return info
}

/// Whether a play request can keep the current item or must replace it.
enum PlayLoadAction: Equatable {
    case reuse
    case restart
    case reload
}

// Six explicit inputs keep this total decision independent of engine state.
// swiftlint:disable function_parameter_count
/// Chooses how a play request relates to the item already held by the engine.
///
/// Identity includes the relative filename because a re-download keeps the
/// episode guid but replaces its file. Failed items are never reused, while an
/// item that naturally ended restarts without paying the cost of a full reload.
func playLoadDecision(
    loadedGUID: String?, loadedFilename: String?, requestedGUID: String,
    requestedFilename: String, itemFailed: Bool, itemEnded: Bool
) -> PlayLoadAction {
    guard loadedGUID == requestedGUID, loadedFilename == requestedFilename else {
        return .reload
    }
    if itemFailed { return .reload }
    if itemEnded { return .restart }
    return .reuse
}
// swiftlint:enable function_parameter_count

/// Clamps a playback target without trusting either input to be representable.
///
/// The duration is optional rather than sentinel-encoded: an engine that does
/// not yet know the item's length passes `nil`, so no caller has to spell a
/// magic float, and a wrong spelling cannot silently clamp everything to zero.
/// An unknown or absurd duration has no useful upper bound, but the target is
/// still kept nonnegative. A non-finite target always resolves to the start.
func clampedPlaybackPosition(_ position: TimeInterval, duration: TimeInterval?) -> TimeInterval {
    guard position.isFinite else { return 0 }

    let lowerBoundedPosition = max(0, position)
    guard let duration, duration.isFinite, duration >= 0, duration < maximumReasonableEpisodeDuration
    else {
        return lowerBoundedPosition
    }
    return min(lowerBoundedPosition, duration)
}

/// Chooses the duration that should drive playback UI.
///
/// A finite positive duration read from the local player item is authoritative
/// and deliberately unbounded — the file on disk is the ground truth, however
/// long it is. Only the feed-authored fallback must remain within the same
/// bound used by episode-row formatting.
func playerDuration(itemDuration: TimeInterval?, episodeDuration: TimeInterval?) -> TimeInterval? {
    if let itemDuration, itemDuration.isFinite, itemDuration > 0 {
        return itemDuration
    }
    guard let episodeDuration, episodeDuration.isFinite, episodeDuration > 0,
        episodeDuration < maximumReasonableEpisodeDuration
    else {
        return nil
    }
    return episodeDuration
}

/// Whether `rate` is one of the discrete values exposed by the player.
func isValidPlaybackRate(_ rate: Double) -> Bool {
    playbackRates.contains(rate)
}
