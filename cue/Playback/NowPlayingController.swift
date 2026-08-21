import MediaPlayer
import Synchronization

/// Whether a remote command has anything to act on.
///
/// A reference type rather than a bare `Mutex` property because `Mutex` is
/// noncopyable and cannot be captured by an escaping `@Sendable` command
/// handler; the handler must answer synchronously, off the main actor.
private final class RemoteCommandState: Sendable {
    private let hasLoadedItem = Mutex(false)

    var isLoaded: Bool {
        hasLoadedItem.withLock { $0 }
    }

    func setLoaded(_ isLoaded: Bool) {
        hasLoadedItem.withLock { $0 = isLoaded }
    }
}

/// Owns the app's single Now Playing publisher and remote-command wiring.
@MainActor
final class NowPlayingController {
    private let infoCenter: MPNowPlayingInfoCenter
    private let commandCenter: MPRemoteCommandCenter
    private let remoteCommandState = RemoteCommandState()
    private var isConfigured = false

    init(
        infoCenter: MPNowPlayingInfoCenter = .default(),
        commandCenter: MPRemoteCommandCenter = .shared()
    ) {
        self.infoCenter = infoCenter
        self.commandCenter = commandCenter
    }

    /// Installs each remote-command handler exactly once for this controller.
    func configure(with engine: PlaybackEngine) {
        guard !isConfigured else { return }
        isConfigured = true

        let remoteCommandState = remoteCommandState
        // The returned handles are discarded: this controller is created once
        // for the process and the shared command center owns its targets, so
        // there is no teardown path for them to serve.
        _ = commandCenter.playCommand.addTarget { [weak engine] _ in
            guard remoteCommandState.isLoaded else {
                return .noActionableNowPlayingItem
            }
            Task { @MainActor [weak engine] in
                guard let engine else { return }
                do {
                    try engine.resumeLoaded()
                } catch {
                    engine.handleRemotePlaybackFailure(error)
                }
            }
            return .success
        }
        _ = commandCenter.pauseCommand.addTarget { [weak engine] _ in
            guard remoteCommandState.isLoaded else {
                return .noActionableNowPlayingItem
            }
            Task { @MainActor [weak engine] in
                engine?.pause()
            }
            return .success
        }
        commandCenter.playCommand.isEnabled = true
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.changePlaybackPositionCommand.isEnabled = false  // deliberate: spec §8
        commandCenter.skipForwardCommand.isEnabled = false  // deliberate: spec §8
        commandCenter.skipBackwardCommand.isEnabled = false  // deliberate: spec §8
    }

    func update(
        title: String, podcastTitle: String, duration: TimeInterval?, elapsed: TimeInterval,
        rate: Double
    ) {
        remoteCommandState.setLoaded(true)
        infoCenter.nowPlayingInfo = nowPlayingInfo(
            title: title,
            podcastTitle: podcastTitle,
            duration: duration,
            elapsed: elapsed,
            rate: rate
        )
    }

    func clear() {
        remoteCommandState.setLoaded(false)
        infoCenter.nowPlayingInfo = nil
    }
}
