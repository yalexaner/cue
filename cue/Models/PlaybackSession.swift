import Foundation
import SwiftData

@Model
final class PlaybackSession {
    var startedAt: Date
    var endedAt: Date?  // nil = session is live
    var startPosition: TimeInterval
    var endPosition: TimeInterval
    var rate: Double
    var episode: Episode?

    init(startedAt: Date, startPosition: TimeInterval, endPosition: TimeInterval, rate: Double) {
        self.startedAt = startedAt
        self.startPosition = startPosition
        self.endPosition = endPosition
        self.rate = rate
    }
}
