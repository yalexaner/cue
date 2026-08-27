import Foundation

/// The time constants and the clock the transfer phases are measured against.
///
/// Its own file for the reason `DownloadPolicy.swift` is: `DownloadManager.swift`
/// sits against the 400-line `file_length` warning `--strict` turns into an
/// error, and the pacing is a cohesive topic to lift out.
enum DownloadPacing {
    /// No byte for this long makes a transfer stalled (decision 16).
    static let stallThreshold: TimeInterval = 30
    /// Repeated byte/rate publications are limited to one per this interval.
    ///
    /// Lifecycle transitions — queued to connecting, a queue reindex, stalled,
    /// finalizing, and every terminal state — bypass it entirely: a change the
    /// user caused must not wait for the next byte callback.
    static let publishInterval: TimeInterval = 1
}

/// The two things the phase machinery needs from time, behind one seam.
///
/// Injected rather than reached for, like every other service seam here: stall
/// deadlines, the throttle and the rate window are all time-dependent, and no
/// test may sleep to exercise them.
///
/// `now()` is monotonic. Wall-clock time is not usable: the deadline compares
/// two readings taken across a suspension, and a clock adjustment between them
/// would either mark a moving transfer stalled or postpone stalling forever.
protocol DownloadClock: Sendable {
    func now() -> TimeInterval
    func sleep(for seconds: TimeInterval) async throws
}

/// The production clock: uptime for readings, and a sleep measured on the same
/// time base.
///
/// `SuspendingClock` rather than `Task.sleep`'s default `ContinuousClock`:
/// `systemUptime` does not advance while the device is asleep and a continuous
/// deadline does, so pairing them means a screen locked mid-transfer wakes the
/// deadline early, having measured a different quantity than the reading it is
/// compared against. `markStalled` re-arms rather than trusting either, but the
/// two halves of one clock should not disagree in the first place.
struct SystemDownloadClock: DownloadClock {
    func now() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    func sleep(for seconds: TimeInterval) async throws {
        guard seconds > 0 else { return }
        try await Task.sleep(for: .seconds(seconds), clock: SuspendingClock())
    }
}

/// A bounded trailing window of byte readings, and the rate they imply.
///
/// A value type with no clock of its own — every reading carries the time it was
/// taken — so the whole thing is testable without waiting for anything.
///
/// The rate is measured from the oldest surviving sample to the newest rather
/// than between the last two: consecutive `URLSession` callbacks can be
/// milliseconds apart, and dividing by that interval produces a number that
/// swings by an order of magnitude between renders.
struct TransferRateWindow: Equatable, Sendable {
    /// One byte reading and when it was taken (decision 16: a 5-second window).
    struct Sample: Equatable, Sendable {
        let time: TimeInterval
        let bytes: Int64
    }

    static let window: TimeInterval = 5
    /// A ceiling on retained readings, so a very fast transfer cannot grow the
    /// array without bound between prunes.
    static let maximumSamples = 64
    /// Below this the division is noise rather than a measurement, and at zero
    /// it is a division by zero.
    static let minimumInterval: TimeInterval = 0.05

    private(set) var samples: [Sample] = []

    /// Records a reading and answers the rate it implies, if any.
    ///
    /// A reading at or before the newest one already held is dropped: byte
    /// reports are ordered by the caller, and a non-advancing time would make
    /// the interval below meaningless.
    @discardableResult
    mutating func record(bytes: Int64, at time: TimeInterval) -> Double? {
        if let last = samples.last, time <= last.time {
            return rate(at: last.time)
        }
        samples.append(Sample(time: time, bytes: bytes))
        prune(at: time)
        return rate(at: time)
    }

    /// The rate over the readings still inside the window ending at `now`.
    ///
    /// A stall therefore answers `nil` rather than a stale number: nothing new
    /// is recorded, so every sample eventually falls out of the window.
    func rate(at now: TimeInterval) -> Double? {
        let live = samples.filter { now - $0.time <= Self.window }
        guard let first = live.first, let last = live.last else { return nil }
        let elapsed = last.time - first.time
        guard elapsed >= Self.minimumInterval else { return nil }
        let delta = Double(last.bytes - first.bytes)
        guard delta >= 0 else { return nil }
        let value = delta / elapsed
        guard value.isFinite else { return nil }
        return value
    }

    private mutating func prune(at now: TimeInterval) {
        samples.removeAll { now - $0.time > Self.window }
        if samples.count > Self.maximumSamples {
            samples.removeFirst(samples.count - Self.maximumSamples)
        }
    }
}
