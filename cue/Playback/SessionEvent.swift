import Foundation

/// A session boundary the engine reports, carrying positions and rates only.
///
/// The type deliberately names no model and imports no SwiftData: it is the
/// seam that lets `PlaybackEngine` describe what happened to a listening
/// session without knowing that a session is ever written down. `CueApp` wires
/// the engine's emissions to a `SessionRecorder`; tests wire a closure.
enum SessionEvent: Equatable {
    /// A session opens. Emitted by the one transition that starts audio.
    case started(guid: String, position: TimeInterval, rate: Double)
    /// A session closes at `position`. Emitted once per true→false transition.
    case stopped(position: TimeInterval)
    /// A user-initiated seek: close at `from`, reopen at `target`. The label
    /// is `target` rather than `to` only because SwiftLint's `identifier_name`
    /// rejects a two-character name.
    case seeked(from: TimeInterval, target: TimeInterval)
    /// A rate change while playing: close and reopen at `position`.
    case rateChanged(position: TimeInterval, newRate: Double)
    /// A periodic position write so a terminated session keeps its progress.
    case heartbeat(position: TimeInterval)
    /// A refused seek took back the position a session was already *closed* at
    /// and nothing is playing, so no live row can be reconciled. Appends a
    /// zero-length closed session at the real playhead: the log is append-only,
    /// so the superseded row stays and the later one carries the resume
    /// position — see `reconcileSessionOpenedAtWithdrawnTarget()`.
    case correctedPosition(guid: String, position: TimeInterval, rate: Double)
}
