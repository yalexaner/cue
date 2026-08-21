import AVFoundation
import Foundation

extension PlaybackEngine {
    /// Seeks to a safe position in the loaded item.
    func seek(to position: TimeInterval) {
        guard player != nil else { return }
        requestedResumePosition = nil
        let target = clampedPlaybackPosition(position, duration: duration)
        seekPlayer(to: target)
    }

    /// Moves relative to the last observed player position.
    func skip(by interval: TimeInterval) {
        seek(to: elapsed + interval)
    }

    static func playerTime(_ seconds: TimeInterval) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }
}
