import AVFoundation
import Foundation

/// Installing and tearing down the engine's asynchronous observers.
///
/// Split out of `PlaybackEngine.swift` for the 400-line file limit. Only the
/// registration lives here; every callback it installs hops to a main-actor
/// seam on the engine itself, which is what keeps the generation guards and the
/// state transitions in one readable place.
extension PlaybackEngine {
    func installObservers(for item: AVPlayerItem, player: AVPlayer, generation: UInt64) {
        itemStatusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self, weak item] _, _ in
            Task { @MainActor [weak self, weak item] in
                guard let self, let item else { return }
                self.handleItemStatus(
                    item.status,
                    itemDuration: item.duration.seconds,
                    error: item.error,
                    generation: generation
                )
            }
        }
        // `AVPlayer` reports failures its item never sees, so both statuses are
        // observed; a player-level failure is terminal for that player.
        playerStatusObservation = player.observe(\.status, options: [.initial, .new]) { [weak self, weak player] _, _ in
            Task { @MainActor [weak self, weak player] in
                guard let self, let player else { return }
                self.handlePlayerStatus(player.status, error: player.error, generation: generation)
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleItemEnded(generation: generation)
            }
        }
        periodicTimeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor [weak self] in
                self?.handlePeriodicTime(time, generation: generation)
            }
        }
    }

    func installAudioSessionObservers() {
        let session = AVAudioSession.sharedInstance()
        let interruption = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: session,
            queue: .main
        ) { [weak self] notification in
            guard
                let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                let type = AVAudioSession.InterruptionType(rawValue: rawType)
            else { return }
            Task { @MainActor [weak self] in
                self?.handleAudioSessionInterruption(type)
            }
        }
        // The system pauses the player itself when the current output goes
        // away, and posts no interruption for it. Without this the engine keeps
        // reporting `isPlaying`, so the button shows Pause for silence and the
        // lock screen advertises a rate of 1.0 for a stopped player.
        let routeChange = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: session,
            queue: .main
        ) { [weak self] notification in
            guard
                let rawReason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
                let reason = AVAudioSession.RouteChangeReason(rawValue: rawReason)
            else { return }
            Task { @MainActor [weak self] in
                self?.handleAudioRouteChange(reason)
            }
        }
        audioSessionObservers = [interruption, routeChange]
    }

    func tearDownObservers() {
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
        playerStatusObservation?.invalidate()
        playerStatusObservation = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        if let periodicTimeObserver, let player {
            player.removeTimeObserver(periodicTimeObserver)
            self.periodicTimeObserver = nil
        }
    }
}
