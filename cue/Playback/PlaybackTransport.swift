import AVFoundation
import Foundation

/// The transport commands a view or a remote control invokes.
///
/// Split out of `PlaybackEngine.swift` for the 400-line file limit, following
/// the `PlaybackSeeking.swift` precedent. `setRate(_:)` stays with the engine:
/// it is the only transport command that writes published state directly, and
/// `rate`'s setter is deliberately private. The load, reuse and start helpers
/// these call are module-visible for the same reason `seekPlayer(to:)` is —
/// the split, not a widening of what a view may do.
extension PlaybackEngine {
    /// Plays a downloaded episode from its resolved local file URL.
    ///
    /// The disk gate deliberately precedes the reuse decision. A file removed
    /// underneath a still-loaded item must report `.fileMissing`, not appear to
    /// resume successfully. This path performs no network or reachability work.
    func play(_ episode: Episode, store: EpisodeStore) throws {
        guard let requestedFilename = episode.localFilename else {
            throw Failure.notDownloaded
        }
        guard try episode.isDownloaded(in: store) else {
            throw Failure.fileMissing
        }

        let action = playLoadDecision(
            loadedGUID: episodeGUID,
            loadedFilename: loadedFilename,
            requestedGUID: episode.guid,
            requestedFilename: requestedFilename,
            itemFailed: itemFailed,
            itemEnded: itemEnded
        )
        switch action {
        case .reuse:
            refreshLoadedMetadata(from: episode)
            try startLoadedPlayback()
        case .restart:
            refreshLoadedMetadata(from: episode)
            restartLoadedItem()
            try startLoadedPlayback()
        case .reload:
            let url = try store.url(forRelativeFilename: requestedFilename)
            load(episode, filename: requestedFilename, url: url)
            try startLoadedPlayback()
        }
    }

    /// Pauses playback without unloading the local item.
    func pause() {
        player?.pause()
        stopPlaying()
        updateNowPlayingInfo()
    }

    /// Pauses a playing item or resumes the loaded item.
    func togglePlayPause() throws {
        if isPlaying {
            pause()
        } else {
            try resumeLoaded()
        }
    }

    /// Starts the loaded item, restarting from zero when it previously ended.
    ///
    /// A remote Play command targets this method so duplicate commands never
    /// turn a playing item into a paused one.
    func resumeLoaded() throws {
        guard player != nil else { return }
        if itemEnded {
            restartLoadedItem()
        }
        try startLoadedPlayback()
    }
}
