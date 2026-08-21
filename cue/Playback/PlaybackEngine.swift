import AVFoundation
import Foundation
import Observation

/// Owns local audio playback and the in-memory state that outlives every view.
///
/// This long-lived `@MainActor @Observable` class is a deliberate deviation
/// from the cheap-struct service convention used by `FeedService` and
/// `EpisodeStore`. The player, its item observers and playback state must
/// survive view replacement and sheet dismissal, while none of that transient
/// state belongs in SwiftData. `CueApp` therefore creates one engine and injects
/// it through the environment, mirroring the lifetime mechanism used by
/// `DownloadManager` for a separate long-lived responsibility.
@MainActor
@Observable
final class PlaybackEngine {
    enum Failure: Error, Equatable {
        case notDownloaded
        case fileMissing
        /// The loaded item reported `.failed`. Only reachable from a resume —
        /// `play(_:store:)` reloads a failed pair instead of resuming it.
        case itemFailed
    }

    private(set) var episodeGUID: String?
    private(set) var loadedFilename: String?
    private(set) var episodeTitle: String?
    private(set) var podcastTitle: String?
    private(set) var isPlaying = false
    private(set) var elapsed: TimeInterval = 0
    private(set) var duration: TimeInterval?
    private(set) var rate: Double = 1.0
    private(set) var playbackError: (any Error)?
    private(set) var itemEnded = false

    @ObservationIgnored var player: AVPlayer?
    var itemStatusObservation: NSKeyValueObservation?
    var playerStatusObservation: NSKeyValueObservation?
    var endObserver: NSObjectProtocol?
    var periodicTimeObserver: Any?
    @ObservationIgnored nonisolated(unsafe) var audioSessionObservers: [NSObjectProtocol] = []
    private var loadedItemFailed = false
    private var loadedPlayerFailed = false
    @ObservationIgnored private var pendingSeekClearedEndedFlag = false
    private(set) var loadGeneration: UInt64 = 0
    @ObservationIgnored private(set) var seekGeneration: UInt64 = 0
    @ObservationIgnored private var pendingSeekGeneration: UInt64?
    @ObservationIgnored var requestedResumePosition: TimeInterval?
    @ObservationIgnored private let nowPlayingController: NowPlayingController?

    init(nowPlayingController: NowPlayingController? = nil) {
        self.nowPlayingController = nowPlayingController
        nowPlayingController?.configure(with: self)
        installAudioSessionObservers()
    }

    deinit {
        for observer in audioSessionObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

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
        isPlaying = false
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

    /// Remembers and, when playing, immediately applies a supported rate.
    func setRate(_ newRate: Double) {
        guard isValidPlaybackRate(newRate) else { return }
        rate = newRate
        if isPlaying {
            player?.rate = Float(newRate)
        }
        updateNowPlayingInfo()
    }

    /// Unloads the item only when it belongs to `guid`.
    ///
    /// File-mutating actions call this before deleting or replacing episode
    /// audio so an active player never retains an item for an unlinked file.
    func unload(ifGUID guid: String) {
        guard episodeGUID == guid else { return }
        player?.pause()
        loadGeneration &+= 1
        tearDownObservers()
        player = nil
        episodeGUID = nil
        loadedFilename = nil
        episodeTitle = nil
        podcastTitle = nil
        isPlaying = false
        elapsed = 0
        duration = nil
        playbackError = nil
        itemEnded = false
        loadedItemFailed = false
        loadedPlayerFailed = false
        pendingSeekGeneration = nil
        pendingSeekClearedEndedFlag = false
        requestedResumePosition = nil
        nowPlayingController?.clear()
    }

    private var itemFailed: Bool {
        loadedItemFailed || loadedPlayerFailed || player?.currentItem?.status == .failed
            || player?.status == .failed
    }

    /// Republishes feed metadata onto an item the engine is about to reuse.
    /// Only `load(_:filename:url:)` reads the titles, so a refresh that renamed
    /// the episode or its show would otherwise leave the player sheet and the
    /// lock screen stale. Position and player state are deliberately untouched.
    private func refreshLoadedMetadata(from episode: Episode) {
        episodeTitle = episode.title
        podcastTitle = episode.podcast?.title
        updateNowPlayingInfo()
    }

    private func load(_ episode: Episode, filename: String, url: URL) {
        player?.pause()
        loadGeneration &+= 1
        tearDownObservers()

        let item = AVPlayerItem(url: url)
        item.audioTimePitchAlgorithm = .timeDomain
        let newPlayer = AVPlayer(playerItem: item)
        player = newPlayer
        episodeGUID = episode.guid
        loadedFilename = filename
        episodeTitle = episode.title
        podcastTitle = episode.podcast?.title
        isPlaying = false
        duration = playerDuration(itemDuration: nil, episodeDuration: episode.duration)
        requestedResumePosition = episode.currentPosition
        elapsed = clampedPlaybackPosition(requestedResumePosition ?? 0, duration: duration)
        playbackError = nil
        itemEnded = false
        loadedItemFailed = false
        loadedPlayerFailed = false
        pendingSeekGeneration = nil
        pendingSeekClearedEndedFlag = false

        if elapsed > 0 {
            seekPlayer(to: elapsed)
        }
        installObservers(for: item, player: newPlayer, generation: loadGeneration)
        updateNowPlayingInfo()
    }

    /// The only transition that sets `isPlaying` to true.
    ///
    /// A failed item is an error rather than a silent no-op: `play(_:store:)`
    /// never arrives here with one (its decision reloads instead), so the only
    /// callers that can are the resume paths, and returning quietly there left
    /// the player sheet and the lock-screen Play button dead with no feedback.
    private func startLoadedPlayback() throws {
        guard !isPlaying, let player else { return }
        if itemFailed {
            throw playbackError ?? Failure.itemFailed
        }
        let audioSession = AVAudioSession.sharedInstance()
        try audioSession.setCategory(.playback, mode: .spokenAudio)
        try audioSession.setActive(true)
        playbackError = nil
        player.playImmediately(atRate: Float(rate))
        isPlaying = true
        updateNowPlayingInfo()
    }

    private func restartLoadedItem() {
        guard player != nil else { return }
        requestedResumePosition = nil
        seekPlayer(to: 0)
    }

    /// Starts an asynchronous player seek while keeping stale time samples and
    /// superseded completions from undoing the requested position. A seek that
    /// never lands gives back the `itemEnded` clear it applied optimistically.
    func seekPlayer(to target: TimeInterval) {
        guard let player else { return }
        seekGeneration &+= 1
        let generation = seekGeneration
        let currentLoadGeneration = loadGeneration
        pendingSeekGeneration = generation
        elapsed = target
        pendingSeekClearedEndedFlag = clearEndedFlagWhenAwayFromEnd(target) || pendingSeekClearedEndedFlag
        updateNowPlayingInfo()
        player.seek(to: Self.playerTime(target)) { [weak self] finished in
            Task { @MainActor [weak self] in
                self?.handleSeekCompletion(
                    finished: finished,
                    target: target,
                    seekGeneration: generation,
                    loadGeneration: currentLoadGeneration
                )
            }
        }
    }

    @discardableResult
    private func clearEndedFlagWhenAwayFromEnd(_ position: TimeInterval) -> Bool {
        guard itemEnded else { return false }
        guard duration.map({ position < $0 }) ?? true else { return false }
        itemEnded = false
        return true
    }

    // Internal callback seams keep the AVPlayer wiring build-only while tests
    // can assert generation guards and state transitions without audio media.
    func handleItemStatus(
        _ status: AVPlayerItem.Status, itemDuration: TimeInterval?, error: (any Error)?,
        generation: UInt64
    ) {
        guard generation == loadGeneration else { return }
        switch status {
        case .readyToPlay:
            loadedItemFailed = false
            duration = playerDuration(itemDuration: itemDuration, episodeDuration: duration)
            if let requestedResumePosition {
                self.requestedResumePosition = nil
                let target = clampedPlaybackPosition(requestedResumePosition, duration: duration)
                seekPlayer(to: target)
            } else {
                let reconciledElapsed = clampedPlaybackPosition(elapsed, duration: duration)
                if reconciledElapsed != elapsed {
                    seekPlayer(to: reconciledElapsed)
                } else {
                    updateNowPlayingInfo()
                }
            }
        case .failed:
            loadedItemFailed = true
            publishLoadFailure(error)
        case .unknown:
            break
        @unknown default:
            break
        }
    }

    /// Handles a failure reported by the player rather than by its item.
    /// `AVPlayer` is a documented error surface of its own, and a player-level
    /// failure — which is terminal — stops audio without touching
    /// `AVPlayerItem.status`, so without this seam the engine keeps reporting
    /// `isPlaying`, publishes a nonzero Now Playing rate and shows Pause over
    /// silence. The flag makes the next `play(_:store:)` reload, not resume.
    func handlePlayerStatus(_ status: AVPlayer.Status, error: (any Error)?, generation: UInt64) {
        guard generation == loadGeneration, status == .failed else { return }
        loadedPlayerFailed = true
        publishLoadFailure(error)
    }

    private func publishLoadFailure(_ error: (any Error)?) {
        requestedResumePosition = nil
        pendingSeekGeneration = nil
        pendingSeekClearedEndedFlag = false
        playbackError = error ?? NSError(domain: AVFoundationErrorDomain, code: AVError.unknown.rawValue)
        player?.pause()
        isPlaying = false
        updateNowPlayingInfo()
    }

    func handleItemEnded(generation: UInt64) {
        guard generation == loadGeneration else { return }
        player?.pause()
        requestedResumePosition = nil
        pendingSeekGeneration = nil
        pendingSeekClearedEndedFlag = false
        isPlaying = false
        if let duration {
            elapsed = duration
        }
        itemEnded = true
        updateNowPlayingInfo()
    }

    func handlePeriodicTime(_ time: CMTime, generation: UInt64) {
        guard generation == loadGeneration, pendingSeekGeneration == nil, time.seconds.isFinite else { return }
        elapsed = clampedPlaybackPosition(time.seconds, duration: duration)
        updateNowPlayingInfo()
    }

    func handleSeekCompletion(
        finished: Bool, target: TimeInterval, seekGeneration: UInt64,
        loadGeneration: UInt64
    ) {
        guard loadGeneration == self.loadGeneration, seekGeneration == pendingSeekGeneration else { return }
        pendingSeekGeneration = nil
        if finished {
            elapsed = clampedPlaybackPosition(target, duration: duration)
            clearEndedFlagWhenAwayFromEnd(elapsed)
        } else if pendingSeekClearedEndedFlag {
            // The playhead may still be at the end, so the optimistic clear is
            // taken back and the player stopped with it: a restart that never
            // landed must restart again, not keep showing Pause over silence.
            itemEnded = true
            pause()
        }
        pendingSeekClearedEndedFlag = false
        updateNowPlayingInfo()
    }

    func handleAudioSessionInterruption(_ type: AVAudioSession.InterruptionType) {
        guard type == .began else { return }
        player?.pause()
        isPlaying = false
        updateNowPlayingInfo()
    }

    /// Reconciles state with a player the system paused when its output left.
    ///
    /// Only `.oldDeviceUnavailable` pauses — a route gained, or an override,
    /// leaves playback running and must not stop it.
    func handleAudioRouteChange(_ reason: AVAudioSession.RouteChangeReason) {
        guard reason == .oldDeviceUnavailable else { return }
        player?.pause()
        isPlaying = false
        updateNowPlayingInfo()
    }

    func handleRemotePlaybackFailure(_ error: any Error) {
        playbackError = error
        player?.pause()
        isPlaying = false
        updateNowPlayingInfo()
    }

    private func updateNowPlayingInfo() {
        guard let episodeTitle else { return }
        nowPlayingController?.update(
            title: episodeTitle,
            podcastTitle: podcastTitle ?? "",
            duration: duration,
            elapsed: elapsed,
            rate: isPlaying ? rate : 0
        )
    }
}
