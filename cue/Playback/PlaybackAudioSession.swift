import AVFoundation
import Foundation

/// Reconciling engine state with the system's own audio decisions.
///
/// Split out of `PlaybackEngine.swift` for the 400-line file limit, following
/// the `PlaybackSeeking.swift` precedent. Both handlers end audible playback,
/// so both close the live session through the engine's one stop funnel.
/// `handleRemotePlaybackFailure` stays with the engine: it is a remote-command
/// failure rather than an audio-session notification, and it is the only one of
/// the three that writes `playbackError`, whose setter is deliberately private.
extension PlaybackEngine {
    /// Activates the session the one start transition needs.
    ///
    /// The engine owns the audio session and deliberately never deactivates it
    /// in this step — that belongs to the sleep timer — so the activation lives
    /// here with the rest of the session handling while `startLoadedPlayback()`
    /// keeps being the only place playback begins. `.spokenAudio` is a
    /// requirement rather than a default worth tidying away (spec §8).
    func activateAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio)
        try session.setActive(true)
    }

    /// Pauses on `.began` and deliberately does not resume on `.ended`: a call
    /// must never silently restart audio in a pocket.
    func handleAudioSessionInterruption(_ type: AVAudioSession.InterruptionType) {
        guard type == .began else { return }
        player?.pause()
        stopPlaying()
        updateNowPlayingInfo()
    }

    /// Reconciles state with a player the system paused when its output left.
    ///
    /// Only `.oldDeviceUnavailable` pauses — a route gained, or an override,
    /// leaves playback running and must not stop it.
    func handleAudioRouteChange(_ reason: AVAudioSession.RouteChangeReason) {
        guard reason == .oldDeviceUnavailable else { return }
        player?.pause()
        stopPlaying()
        updateNowPlayingInfo()
    }
}
