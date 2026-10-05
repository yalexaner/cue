import MediaPlayer

/// Owns the app's single Now Playing publisher and remote-command wiring.
@MainActor
final class NowPlayingController {
    private let infoCenter: MPNowPlayingInfoCenter
    private let commandCenter: MPRemoteCommandCenter
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

        // The returned handles are discarded: this controller is created once
        // for the process and the shared command center owns its targets, so
        // there is no teardown path for them to serve.
        _ = commandCenter.playCommand.addTarget { [weak engine] _ in
            engine?.handleRemotePlay() == true ? .success : .noActionableNowPlayingItem
        }
        _ = commandCenter.pauseCommand.addTarget { [weak engine] _ in
            engine?.handleRemotePause() == true ? .success : .noActionableNowPlayingItem
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
        infoCenter.nowPlayingInfo = nowPlayingInfo(
            title: title,
            podcastTitle: podcastTitle,
            duration: duration,
            elapsed: elapsed,
            rate: rate
        )
    }

    func clear() {
        infoCenter.nowPlayingInfo = nil
    }
}
