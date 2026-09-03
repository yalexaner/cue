import AVFoundation
import Foundation

/// The user-initiated seek surface and the pre-completion window it opens.
///
/// Split out of `PlaybackEngine.swift` for the 400-line file limit, following
/// the same precedent as `PlaybackTransport.swift`. `isSeekPending` and
/// `sessionBoundaryPosition` live here rather than with the engine because
/// they describe that window; the engine keeps the writes to the state they
/// read, whose setters stay private to it.
extension PlaybackEngine {
    /// Whether a seek has been requested and not yet reported completion.
    /// Until it lands the published position is a guess, so the time seams and
    /// the heartbeat both stand down.
    var isSeekPending: Bool { pendingSeekGeneration != nil }

    /// The position a session boundary may be written at.
    ///
    /// While a seek is in flight `elapsed` is the target the engine optimistically
    /// published, not a place the player has ever been, and a boundary is a
    /// permanent row in an append-only log. A pause, a rate change or an unload
    /// landing in that window therefore records the last confirmed playhead —
    /// otherwise a seek that then reports `finished == false` leaves a session
    /// bounded by a position no later write can reach, which is the inverted row
    /// `reportLandedSeekBoundary()` already refuses to create.
    ///
    /// The exception is a session that *opened* inside the window, at the
    /// target itself: the confirmed playhead sits behind its `startPosition`,
    /// so closing there would write the very inversion this property exists to
    /// avoid. Its own opening position is the only defensible bound until the
    /// seek resolves, and a close there is an honest zero-length row.
    var sessionBoundaryPosition: TimeInterval {
        guard isSeekPending else { return elapsed }
        return unconfirmedSessionOpenPosition ?? confirmedPosition
    }

    /// Seeks to a safe position in the loaded item.
    ///
    /// This and `skip(by:)` are the only user-initiated seeks, so this is the
    /// only seam that reports a session boundary: `seekPlayer(to:)` also serves
    /// load resume, restart and duration reclamping and must emit nothing. A
    /// seek while paused touches no session — none is live, and the next open
    /// reads the moved `elapsed` as its `startPosition`.
    ///
    /// A seek that lands where the playhead already is is not a discontinuity,
    /// so it reports nothing — `setRate(_:)`'s same-value guard, for the same
    /// reason. Clamping makes that case ordinary rather than exotic: skipping
    /// back at zero, skipping forward at the end, and releasing the slider
    /// where it was picked up all resolve to the current position, and each
    /// would otherwise close the live session and open a zero-length one.
    ///
    /// The boundary is armed here and emitted by `handleSeekCompletion` once
    /// the player confirms the jump, which is the same stance the heartbeat
    /// already takes on the pre-completion window. A superseded seek keeps the
    /// origin armed by the first: the live session still starts where that one
    /// left, so it is that position the eventual pair must close at.
    func seek(to position: TimeInterval) {
        guard player != nil else { return }
        requestedResumePosition = nil
        let target = clampedPlaybackPosition(position, duration: duration)
        if isPlaying, target != elapsed, pendingSeekBoundaryOrigin == nil {
            pendingSeekBoundaryOrigin = elapsed
        }
        seekPlayer(to: target)
    }

    /// Moves relative to the last observed player position.
    func skip(by interval: TimeInterval) {
        seek(to: elapsed + interval)
    }

    /// Arms the ready seam's playhead correction as a session boundary.
    ///
    /// `seekPlayer(to:)` stays silent for every internal seek, and the ready
    /// seam is the one internal caller that knows a session may already be
    /// live: `startLoadedPlayback()` opened it from the load-time `elapsed`,
    /// before the item reported a length of its own, so this is the first
    /// moment the recorded `startPosition` can be known to be wrong. Left
    /// silent, a finished episode restarting from zero leaves that
    /// `startPosition` ahead of every `endPosition` the heartbeat writes — an
    /// inverted row in a log that is append-only and cannot be corrected.
    ///
    /// It is armed rather than reported for the same reason a manual seek is:
    /// the correcting seek can report `finished == false`, and a pair committed
    /// at the request then names a `startPosition` the player never reached.
    /// Nothing can write to the session in the meantime — the heartbeat stands
    /// down for the whole pre-completion window.
    func armReadySeamCorrection(to target: TimeInterval) {
        guard isPlaying, target != elapsed, pendingSeekBoundaryOrigin == nil else { return }
        pendingSeekBoundaryOrigin = elapsed
    }

    /// Emits the session boundary for a seek the player has confirmed.
    ///
    /// The pair is reported here rather than at the request because the
    /// heartbeat already stands down until a seek lands — the engine treats the
    /// pre-completion position as a guess, and a boundary committed from a
    /// guess survives a failed seek as a `startPosition` no later write can
    /// reach: the next time sample restores the original playhead, the
    /// heartbeat records it, and the append-only log keeps a row that ends
    /// before it begins.
    func reportLandedSeekBoundary() {
        guard let origin = pendingSeekBoundaryOrigin else { return }
        pendingSeekBoundaryOrigin = nil
        guard isPlaying, elapsed != origin else { return }
        sessionEvents?(.seeked(from: origin, target: elapsed))
    }

    /// Repairs a session whose `startPosition` a refused seek took back.
    ///
    /// A resume inside the pre-completion window opens the next session at the
    /// target — which is why `stopPlaying()` retires the armed boundary — and
    /// the withdrawal in `handleSeekCompletion` then puts the playhead behind
    /// that `startPosition`. Left alone the next heartbeat writes an
    /// `endPosition` before it: `startPosition = 70, endPosition = 10` in a log
    /// nothing can rewrite. While that session is live, closing at the position
    /// it opened at leaves a zero-length row, which is honest — it played
    /// nothing — and reopens where the player really is. That is the shape the
    /// failed-restart path already produces by closing before the playhead is
    /// given back.
    ///
    /// A pause, an interruption or a route loss inside the same window closes
    /// that session first, and `stopPlaying()` bounds it at the target too —
    /// the only value that is not an inverted row. The refusal then finds
    /// nothing live to reopen, and an append-only log cannot take the bound
    /// back, so the correction is a *later* row: a zero-length closed session
    /// at the real playhead, which is what `Episode.currentPosition` reads.
    /// Without it a relaunch resumes at a position the player never reached.
    func reconcileSessionOpenedAtWithdrawnTarget() {
        guard let openPosition = unconfirmedSessionOpenPosition, elapsed != openPosition
        else { return }
        if isPlaying {
            sessionEvents?(.seeked(from: openPosition, target: elapsed))
        } else if let episodeGUID {
            sessionEvents?(.correctedPosition(guid: episodeGUID, position: elapsed, rate: rate))
        }
    }

    /// Rewinds an ended item so the next start plays it from the beginning.
    /// Internal rather than user-initiated, so it reports no session boundary:
    /// the `.started` emission that follows carries position zero.
    func restartLoadedItem() {
        guard player != nil else { return }
        requestedResumePosition = nil
        seekPlayer(to: 0)
    }

    static func playerTime(_ seconds: TimeInterval) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }
}
