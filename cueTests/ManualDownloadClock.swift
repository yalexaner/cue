import Foundation

@testable import cue

/// The clock every pacing test drives by hand.
///
/// Two jobs, matching `DownloadClock`: a reading the test moves with
/// `advance(by:)`, and a sleep that parks until the test releases it with
/// `wake()`. Nothing here waits for real time — a stall deadline is thirty
/// seconds and a throttle interval is one, and a suite that slept for either
/// would be both slow and flaky.
///
/// One double for the whole seam, like `FeedTransportStub` and
/// `DownloadTransportStub`: never re-declared per suite.
final class ManualDownloadClock: DownloadClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: TimeInterval
    private var sleepers: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var cancelled: Set<UUID> = []
    private var slept: [TimeInterval] = []

    init(now: TimeInterval = 0) {
        current = now
    }

    /// Every duration a sleeper has asked for, in call order.
    ///
    /// Recorded on entry to `sleep(for:)`, *before* the sleeper parks: a
    /// duration here does not mean `wake()` can release it. Wait on
    /// `pendingSleepCount`, or use `wake(_:until:)`, before waking.
    var requestedSleeps: [TimeInterval] { lock.withLock { slept } }

    var pendingSleepCount: Int { lock.withLock { sleepers.count } }

    func now() -> TimeInterval {
        lock.withLock { current }
    }

    func advance(by seconds: TimeInterval) {
        lock.withLock { current += seconds }
    }

    /// Releases every parked sleeper, as if their durations had elapsed.
    func wake() {
        let waiting: [CheckedContinuation<Void, Error>] = lock.withLock {
            let values = Array(sleepers.values)
            sleepers.removeAll()
            return values
        }
        for continuation in waiting { continuation.resume() }
    }

    func sleep(for seconds: TimeInterval) async throws {
        let id = UUID()
        lock.withLock { slept.append(seconds) }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let alreadyCancelled: Bool = lock.withLock {
                    // the handler below may fire before this closure runs, so
                    // the cancellation is recorded rather than delivered to a
                    // continuation that does not exist yet
                    if cancelled.remove(id) != nil { return true }
                    sleepers[id] = continuation
                    return false
                }
                if alreadyCancelled { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let continuation: CheckedContinuation<Void, Error>? = lock.withLock {
                guard let waiting = sleepers.removeValue(forKey: id) else {
                    cancelled.insert(id)
                    return nil
                }
                return waiting
            }
            continuation?.resume(throwing: CancellationError())
        }
    }
}
