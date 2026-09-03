import AVFoundation
import Foundation
import Observation

/// Owns local audio playback and the in-memory state that outlives every view.
///
/// This long-lived `@MainActor @Observable` class is a deliberate deviation
/// from the cheap-struct service convention: the player, its observers and
/// playback state must survive view replacement, while none of that transient
/// state belongs in SwiftData. `CueApp` creates one and injects it, the
/// `DownloadManager` lifetime precedent.
@MainActor
@Observable
final class PlaybackEngine {
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
    var heartbeatTimeObserver: Any?
    @ObservationIgnored nonisolated(unsafe) var audioSessionObservers: [NSObjectProtocol] = []
    private var loadedItemFailed = false
    private var loadedPlayerFailed = false
    @ObservationIgnored private var pendingSeekClearedEndedFlag = false
    private(set) var loadGeneration: UInt64 = 0
    @ObservationIgnored private(set) var seekGeneration: UInt64 = 0
    @ObservationIgnored private(set) var pendingSeekGeneration: UInt64?
    /// Where a user seek left, held until the player confirms the jump landed.
    @ObservationIgnored var pendingSeekBoundaryOrigin: TimeInterval?
    /// The last playhead the player confirmed; `seekPlayer(to:)` never touches
    /// it — see `sessionBoundaryPosition`.
    @ObservationIgnored private(set) var confirmedPosition: TimeInterval = 0
    /// Where a session opened inside a seek's pre-completion window, kept past
    /// that session's close — `reconcileSessionOpenedAtWithdrawnTarget()` rules.
    @ObservationIgnored private(set) var unconfirmedSessionOpenPosition: TimeInterval?
    /// Whether `duration` was measured from the file rather than claimed by
    /// the feed — see `applyObservedPosition(_:)`. Monotonic within a load: an
    /// item reporting no length of its own must not demote the asset's.
    @ObservationIgnored private var durationIsMeasured = false
    @ObservationIgnored var requestedResumePosition: TimeInterval?
    @ObservationIgnored let nowPlayingController: NowPlayingController?
    /// Session boundaries leave the engine through this seam (no SwiftData).
    @ObservationIgnored var sessionEvents: ((SessionEvent) -> Void)?

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

    /// Remembers and, when playing, immediately applies a supported rate.
    func setRate(_ newRate: Double) {
        guard isValidPlaybackRate(newRate) else { return }
        // Re-selecting the live rate is not a boundary; paused, the new rate
        // is simply what the next open records.
        let isBoundary = isPlaying && newRate != rate
        rate = newRate
        if isPlaying {
            player?.rate = Float(newRate)
        }
        if isBoundary {
            sessionEvents?(.rateChanged(position: sessionBoundaryPosition, newRate: newRate))
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
        // Both speak for the outgoing episode, so both precede the clear below.
        stopPlaying()
        retirePendingSeekWindow()
        episodeGUID = nil
        loadedFilename = nil
        episodeTitle = nil
        podcastTitle = nil
        elapsed = 0
        duration = nil
        playbackError = nil
        itemEnded = false
        loadedItemFailed = false
        loadedPlayerFailed = false
        confirmedPosition = 0
        durationIsMeasured = false
        requestedResumePosition = nil
        nowPlayingController?.clear()
    }

    var itemFailed: Bool {
        loadedItemFailed || loadedPlayerFailed || player?.currentItem?.status == .failed
            || player?.status == .failed
    }

    /// Republishes feed metadata onto an item the engine is about to reuse.
    /// Only `load(_:filename:url:)` reads the titles, so a refresh that renamed
    /// the episode or its show would leave the player sheet and the lock screen
    /// stale. Position and player state are deliberately untouched.
    func refreshLoadedMetadata(from episode: Episode) {
        episodeTitle = episode.title
        podcastTitle = episode.podcast?.title
        updateNowPlayingInfo()
    }

    func load(_ episode: Episode, filename: String, url: URL) {
        player?.pause()
        // Both speak for the outgoing episode, as in `unload`; the writes below replace it.
        stopPlaying()
        retirePendingSeekWindow()
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
        let feed = playerDuration(itemDuration: nil, episodeDuration: episode.duration)
        let measured = episode.assetDuration
        let playhead = loadedPlayhead(episode.currentPosition, measured: measured, feed: feed)
        requestedResumePosition = playhead.position
        elapsed = playhead.position
        confirmedPosition = playhead.position
        duration = playhead.duration
        durationIsMeasured = measured != nil
        playbackError = nil
        itemEnded = false
        loadedItemFailed = false
        loadedPlayerFailed = false

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
    func startLoadedPlayback() throws {
        guard !isPlaying, let player else { return }
        if itemFailed {
            throw playbackError ?? Failure.itemFailed
        }
        try activateAudioSession()
        playbackError = nil
        player.playImmediately(atRate: Float(rate))
        isPlaying = true
        // The open keeps using `elapsed` — a restart begins at the zero it just
        // asked for — so inside a seek window it records an unconfirmed target.
        unconfirmedSessionOpenPosition = isSeekPending ? elapsed : nil
        if let episodeGUID {
            sessionEvents?(.started(guid: episodeGUID, position: elapsed, rate: rate))
        }
        updateNowPlayingInfo()
    }

    /// Starts an asynchronous player seek, keeping stale time samples and
    /// superseded completions from undoing the requested position. A seek that
    /// never lands gives back the `itemEnded` clear it applied optimistically.
    func seekPlayer(to target: TimeInterval) {
        guard let player else { return }
        // Superseding drops the pending completion, the only thing that would
        // withdraw its target — so this seek performs that refusal itself.
        // Playing needs none: its own landed boundary reopens the live session.
        if !isPlaying { retirePendingSeekWindow(supersededBySeek: true) }
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
                    finished: finished, target: target,
                    seekGeneration: generation, loadGeneration: currentLoadGeneration
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

    // Internal callback seams keep the AVPlayer wiring build-only.
    func handleItemStatus(
        _ status: AVPlayerItem.Status, itemDuration: TimeInterval?, error: (any Error)?,
        generation: UInt64
    ) {
        guard generation == loadGeneration else { return }
        switch status {
        case .readyToPlay:
            loadedItemFailed = false
            // Only a measured duration may judge a resume or bound the playhead:
            // a feed understating its file reads a mid-episode position as
            // finished, and a feed length the playhead is already past lets the
            // seek and time clamps drag the restored position back onto it.
            let measured = playerDuration(itemDuration: itemDuration, episodeDuration: nil)
            let resume = requestedResumePosition
            requestedResumePosition = nil
            let target =
                resume.map { playbackResumePosition($0, duration: measured) }
                ?? clampedPlaybackPosition(elapsed, duration: measured)
            duration = reconciledPlaybackDuration(measured: measured, fallback: duration, position: target)
            durationIsMeasured = durationIsMeasured || measured != nil  // never demote the asset's
            if target == elapsed {
                // A seek in flight owns `elapsed`, and only its completion may
                // confirm it: promoted here, a refusal "restores" an unvisited spot.
                if !isSeekPending { confirmedPosition = elapsed }
                updateNowPlayingInfo()
            } else {
                armReadySeamCorrection(to: target)
                seekPlayer(to: target)
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

    /// The one place `isPlaying` goes false, so no stop site can be missed.
    /// Already-stopped paths are no-ops, which is what makes `.stopped` fire
    /// exactly once per session and only on a true→false transition.
    func stopPlaying() {
        guard isPlaying else { return }
        isPlaying = false
        // A boundary belongs to the session that armed it, so this close
        // retires it: a resume before the seek lands opens the next session at
        // the target, and a later emission would close that new session at the
        // position it started ahead of — an inverted row. The session's
        // *opening* position outlives this close instead, as the bound written
        // below, for a refusal to correct.
        pendingSeekBoundaryOrigin = nil
        sessionEvents?(.stopped(position: sessionBoundaryPosition))
    }

    /// Publishes an observed player sample as the playhead.
    ///
    /// A measured length is authoritative and bounds it. An unmeasured feed
    /// length is only a claim, and a sample past it disproves that claim:
    /// dropped here, the clamp stops dragging the playhead back onto a number
    /// the file has gone beyond, where it would freeze for the rest of the
    /// episode and be heartbeaten in as real progress. The ready seam applies
    /// the rule once against the resume target; an item reporting no length of
    /// its own never gives it a second chance, so every sample applies it too.
    func applyObservedPosition(_ seconds: TimeInterval) {
        if !durationIsMeasured {
            duration = reconciledPlaybackDuration(measured: nil, fallback: duration, position: seconds)
        }
        elapsed = clampedPlaybackPosition(seconds, duration: duration)
        confirmedPosition = elapsed
        updateNowPlayingInfo()
    }

    private func publishLoadFailure(_ error: (any Error)?) {
        requestedResumePosition = nil
        playbackError = error ?? NSError(domain: AVFoundationErrorDomain, code: AVError.unknown.rawValue)
        player?.pause()
        // The close runs first, while the seek is still pending: it records the
        // confirmed playhead, or a target the retire below withdraws and corrects.
        stopPlaying()
        retirePendingSeekWindow()
        updateNowPlayingInfo()
    }

    func handleItemEnded(generation: UInt64) {
        guard generation == loadGeneration else { return }
        player?.pause()
        requestedResumePosition = nil
        if let duration {
            elapsed = duration
        }
        confirmedPosition = elapsed
        // Retires before the close, unlike `publishLoadFailure`: the end bounds better than an unreachable target.
        retirePendingSeekWindow(withdrawing: false)
        stopPlaying()
        itemEnded = true
        updateNowPlayingInfo()
    }

    /// Ends a seek window whose completion the caller just made unreachable.
    ///
    /// That completion is the only thing that withdraws an unreached target and
    /// reconciles the session opened at it, so a silent retire leaves that session
    /// bounded by a position the player never reached and `Episode.currentPosition`
    /// resuming there. Retiring is therefore itself a refusal; `handleItemEnded`
    /// opts out, retiring before its own close with the end of the file in hand.
    /// `supersededBySeek` keeps what the incoming seek inherits: the first
    /// seek's armed origin and its outstanding optimistic ended-flag clear.
    private func retirePendingSeekWindow(withdrawing: Bool = true, supersededBySeek: Bool = false) {
        if withdrawing, isSeekPending, unconfirmedSessionOpenPosition != nil {
            elapsed = clampedPlaybackPosition(confirmedPosition, duration: duration)
            reconcileSessionOpenedAtWithdrawnTarget()
        }
        unconfirmedSessionOpenPosition = nil
        guard !supersededBySeek else { return }
        pendingSeekGeneration = nil
        pendingSeekBoundaryOrigin = nil
        pendingSeekClearedEndedFlag = false
    }

    func handleSeekCompletion(
        finished: Bool, target: TimeInterval, seekGeneration: UInt64,
        loadGeneration: UInt64
    ) {
        guard loadGeneration == self.loadGeneration, seekGeneration == pendingSeekGeneration else { return }
        pendingSeekGeneration = nil
        if finished {
            elapsed = clampedPlaybackPosition(target, duration: duration)
            confirmedPosition = elapsed
            clearEndedFlagWhenAwayFromEnd(elapsed)
            reportLandedSeekBoundary()
        } else {
            if pendingSeekClearedEndedFlag {
                // The playhead may still be at the end, so the optimistic
                // clear is taken back and the player stopped with it: a restart
                // that never landed must restart again, not keep showing Pause
                // over silence. The close runs before the playhead is given
                // back, so the session opened at the unreached target is not
                // credited with everything between there and the real playhead.
                itemEnded = true
                pause()
            }
            // The player never left where it was, so the optimistic target is
            // withdrawn: left published it is the position the UI shows, the
            // one a resume opens the next session at, and the one a heartbeat
            // would then contradict from the first real time sample.
            elapsed = clampedPlaybackPosition(confirmedPosition, duration: duration)
            reconcileSessionOpenedAtWithdrawnTarget()
        }
        // The window is over either way: the session's opening position is now
        // either confirmed or already closed by the reconciliation above.
        unconfirmedSessionOpenPosition = nil
        // A seek that never landed moved nothing, so the boundary armed for it
        // is dropped rather than reported against a playhead that stayed put.
        pendingSeekBoundaryOrigin = nil
        pendingSeekClearedEndedFlag = false
        updateNowPlayingInfo()
    }

    func handleRemotePlaybackFailure(_ error: any Error) {
        playbackError = error
        player?.pause()
        stopPlaying()
        updateNowPlayingInfo()
    }
}
