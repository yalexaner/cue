import Foundation

extension PlaybackEngine {
    // MediaPlayer delivers remote commands on the main thread, and each handler
    // is main-actor isolated — inferred from `configure(with:)` and enforced at
    // runtime by Swift 6 — so a command acts synchronously on the item it
    // answers for. A hop to the main actor would open a window in which a
    // replacing load lands before the command acts, which is why there is none.
    //
    // "Loaded" is `episodeTitle != nil`: the condition under which
    // `updateNowPlayingInfo()` publishes, cleared only by `unload(ifGUID:)`
    // alongside its `NowPlayingController.clear()`.

    /// Resumes the loaded item for a remote Play command; `false` when nothing is loaded.
    func handleRemotePlay() -> Bool {
        guard episodeTitle != nil else { return false }
        do {
            try resumeLoaded()
        } catch {
            handleRemotePlaybackFailure(error)
        }
        return true
    }

    /// Pauses the loaded item for a remote Pause command; `false` when nothing is loaded.
    func handleRemotePause() -> Bool {
        guard episodeTitle != nil else { return false }
        pause()
        return true
    }
}
