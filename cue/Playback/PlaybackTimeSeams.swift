import AVFoundation
import Foundation

/// The two periodic time observers' seams.
///
/// Split out of `PlaybackEngine.swift` for the 400-line file limit, following
/// the `PlaybackSeeking.swift` precedent. Both publish a position through the
/// engine's `applyObservedPosition(_:)`, which owns the writes to `elapsed` and
/// `duration`; the deciding rule — that only a *measured* length may bound the
/// playhead — is documented there and shared by both, so the UI sample and the
/// session write can never disagree about where the episode is.
extension PlaybackEngine {
    /// The 0.5 s UI sample.
    ///
    /// Both seams are called synchronously from their observer's delivery queue
    /// so `isSeekPending` is read as of delivery: a sample taken before a seek
    /// landed must be dropped, and judged after the completion it would be
    /// applied instead — see `installObservers(for:player:generation:)`.
    func handlePeriodicTime(_ time: CMTime, generation: UInt64) {
        guard generation == loadGeneration, !isSeekPending, time.seconds.isFinite else { return }
        applyObservedPosition(time.seconds)
    }

    /// The 10 s session heartbeat, separate from the 0.5 s UI observer.
    /// A terminated app's session is closed from the last write this makes.
    ///
    /// It records its *own* time sample rather than `elapsed`, which the 0.5 s
    /// observer maintains: the two callbacks are independently scheduled with
    /// no ordering guarantee between them, so reading `elapsed` here can
    /// persist the previous UI sample and put the log more than AC 12's ten
    /// seconds behind. A sample that is not representable
    /// falls back to `elapsed` — skipping the write outright would cost a whole
    /// heartbeat interval instead of half a UI one.
    func handleHeartbeat(_ time: CMTime, generation: UInt64) {
        guard generation == loadGeneration, !isSeekPending, isPlaying else { return }
        if time.seconds.isFinite {
            applyObservedPosition(time.seconds)
        }
        sessionEvents?(.heartbeat(position: elapsed))
    }
}
