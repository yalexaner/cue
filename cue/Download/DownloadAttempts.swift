import Foundation

/// A background task and the episode identity stamped into its description.
struct DownloadAttemptIdentity: Equatable, Sendable {
    let taskIdentifier: Int
    let guid: String
}

/// One live transfer's identity and observable state.
///
/// The ownership token, background task identifier, cancellation intent and
/// progress belong to the same attempt. Keeping them together prevents a late
/// event from an old task from nominating itself as the current transfer.
struct DownloadAttempt: Equatable {
    enum Origin: Equatable {
        case started
        case adopted
    }

    let token: UUID
    let origin: Origin
    var taskIdentifier: Int?
    var isCancellationRequested = false
    var progress = DownloadProgress.waiting
}

extension DownloadManager {
    /// Registers the background task before it is resumed.
    ///
    /// The ownership record is created by `download(_:)` before it can queue.
    /// A registration with no such record is stale and cannot create a live
    /// attempt merely by reporting itself.
    func registerAttempt(taskIdentifier: Int, forGUID guid: String) {
        guard var attempt = attempts[guid], attempt.origin == .started else { return }
        attempt.taskIdentifier = taskIdentifier
        attempts[guid] = attempt
        resolvedGUIDs.remove(guid)
    }

    /// Applies progress only to the registered task that still owns the guid.
    ///
    /// The attempt records every accepted report, because the byte count is what
    /// orders delayed main-actor hops. The observed state map is written only
    /// when the row would actually look different
    /// (`DownloadProgress.rendersDifferently(from:)`): observation invalidates
    /// on assignment rather than on inequality, and both download screens read
    /// this map, so publishing every byte callback re-evaluates a whole-library
    /// body pass tens of times a second for the length of a transfer.
    func handleProgress(taskIdentifier: Int, guid: String, progress: DownloadProgress) {
        guard var attempt = attempts[guid], attempt.taskIdentifier == taskIdentifier else { return }
        guard case .downloading(let published)? = states[guid] else { return }
        guard progress.bytesWritten >= attempt.progress.bytesWritten else { return }
        attempt.progress = progress
        attempts[guid] = attempt
        guard progress.rendersDifferently(from: published) else { return }
        states[guid] = .downloading(progress)
    }
}
