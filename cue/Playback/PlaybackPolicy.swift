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

/// Spec §9 names the session heartbeat interval; the observer reads it from
/// here so the number the acceptance criterion depends on is assertable.
let sessionHeartbeatInterval: TimeInterval = 10

/// How near the end a resume position counts as "already finished".
///
/// An exact comparison is not enough: the duration an item reports can move by
/// a fraction of a second between loads, and a resume a few milliseconds short
/// of the end plays nothing either.
let playbackCompletionTolerance: TimeInterval = 1

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

/// The position a freshly loaded item should start from.
///
/// An episode played to its end closes its session at `duration`, so spec §4's
/// derived position *is* the end — and starting there plays nothing, because
/// the item ends the instant it starts. That reads as a dead Play button: the
/// first tap flips to Pause and straight back, and it also mints a zero-length
/// session row in a log that is append-only. A finished episode therefore
/// restarts from the beginning, which is the same answer `playLoadDecision`
/// already gives for an ended item the engine still holds.
///
/// The duration must be a *measured* one — the asset's or the loaded item's,
/// never `<itunes:duration>`. A feed that understates the file leaves ordinary
/// mid-episode positions sitting past its claimed end, and restarting those
/// would throw away exactly the position this app exists to keep. `nil` is the
/// honest answer when nothing has measured the file yet: no end is known, so
/// the raw position survives to be judged again once the item reports one.
func playbackResumePosition(_ position: TimeInterval, duration: TimeInterval?) -> TimeInterval {
    let target = clampedPlaybackPosition(position, duration: duration)
    guard let duration, duration.isFinite, duration > 0,
        target >= duration - playbackCompletionTolerance
    else {
        return target
    }
    return 0
}

/// The playhead and published duration a freshly loaded item starts with.
///
/// Only a *measured* length may judge or bound this position — the same rule
/// the ready seam applies once the item reports one. A feed that understates
/// its file would otherwise drag a mid-episode position back onto its claimed
/// end before anything has measured the file: `startLoadedPlayback()` opens the
/// session at that regressed value, the ready seam then has to correct it, and
/// a termination in between records the regression as the resume position.
///
/// `playbackResumePosition` already clamps against `measured`, so its answer is
/// the playhead — a second clamp against the same length could only be a no-op,
/// and against the feed's length it would be the bug above. The feed's value
/// survives as the published `duration` only while the playhead is inside it,
/// exactly as `reconciledPlaybackDuration` allows at the ready seam.
func loadedPlayhead(
    _ position: TimeInterval, measured: TimeInterval?, feed: TimeInterval?
) -> (position: TimeInterval, duration: TimeInterval?) {
    let resume = playbackResumePosition(position, duration: measured)
    return (resume, reconciledPlaybackDuration(measured: measured, fallback: feed, position: resume))
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

/// The duration allowed to bound the playhead once the item is ready.
///
/// A measured duration is authoritative. A feed-authored fallback survives only
/// while the playhead stays inside it: a length the position has already passed
/// is provably wrong, and keeping it would let the clamps in the seek-completion
/// and periodic-time seams drag the resume the ready seam just restored back
/// onto that number — freezing `elapsed` there, publishing the frozen value to
/// Now Playing, and heartbeating it into the session log as real progress.
func reconciledPlaybackDuration(
    measured: TimeInterval?, fallback: TimeInterval?, position: TimeInterval
) -> TimeInterval? {
    if let measured { return measured }
    guard let fallback, position <= fallback else { return nil }
    return fallback
}

/// Whether `rate` is one of the discrete values exposed by the player.
func isValidPlaybackRate(_ rate: Double) -> Bool {
    playbackRates.contains(rate)
}
