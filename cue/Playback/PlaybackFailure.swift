import Foundation

/// The engine's own error domain, split out of `PlaybackEngine.swift` for the
/// 400-line file limit — the `PlaybackSeeking.swift` precedent.
extension PlaybackEngine {
    enum Failure: Error, Equatable {
        case notDownloaded
        case fileMissing
        /// The loaded item reported `.failed`. Only reachable from a resume —
        /// `play(_:store:)` reloads a failed pair instead of resuming it.
        case itemFailed
    }
}
