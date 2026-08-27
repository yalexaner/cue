import Foundation

/// Observable byte progress for one background episode transfer.
///
/// The phases before the first byte are two, not one. `queued` is a transfer
/// parked behind the single transfer slot (spec §7) and carries its place in
/// line; `connecting` holds the slot and is waiting for the server to answer.
/// One literal "Waiting…" covering both was exactly why a test session could
/// not tell a queue from a connection that never opened.
///
/// `indeterminate` is distinct from both: bytes have arrived, but the server
/// gave no usable total. `fraction` carries the *expected total* rather than a
/// pre-computed ratio — the ratio is clamped to `0...1`, so at zero bytes or
/// after over-delivery it cannot be divided back into a total and "X of Y"
/// would be unrecoverable. Raw bytes travel with every moving state so delayed
/// main-actor hops can be ordered.
///
/// Two phases exist after the bytes stop. `stalled` is written by an
/// attempt-scoped deadline when no byte has arrived for
/// `DownloadPacing.stallThreshold`; it cannot be derived on read, because
/// elapsed time invalidates no observation and `DownloadsView` reads the
/// published map directly. `finalizing` covers the window between the last byte
/// and the file landing in `Episodes/` — the window the reported
/// 100 %-then-fail bug lives in, which as ordinary 100 % was indistinguishable
/// from success.
///
/// The measured rate rides on the moving phases rather than being recomputed in
/// a view: the samples that produce it live on the attempt, and two screens
/// render the same transfer.
enum DownloadProgress: Equatable, Sendable {
    /// Waiting for the transfer slot; `position` is its place in the FIFO queue.
    case queued(position: Int)
    /// Holds the slot, no byte reported yet.
    case connecting
    case indeterminate(bytesWritten: Int64, bytesPerSecond: Double?)
    case fraction(bytesWritten: Int64, expectedBytes: Int64, bytesPerSecond: Double?)
    /// Still open, but no byte for at least `DownloadPacing.stallThreshold`.
    case stalled(bytesWritten: Int64, expectedBytes: Int64?)
    /// Every byte has arrived; the file is being moved into `Episodes/`.
    case finalizing(bytesWritten: Int64)

    /// The phase alone, without the numbers that ride on it.
    ///
    /// Named so the render comparison and the throttle can ask "is this the same
    /// kind of thing" without a six-by-six pattern match.
    enum Phase: Equatable, Sendable {
        case queued
        case connecting
        case indeterminate
        case fraction
        case stalled
        case finalizing
    }

    /// Shorthand for a report with no rate yet — the shape every call site used
    /// before a rate existed, kept so a byte report reads as a byte report.
    static func indeterminate(bytesWritten: Int64) -> DownloadProgress {
        .indeterminate(bytesWritten: bytesWritten, bytesPerSecond: nil)
    }

    /// Shorthand for a report with no rate yet.
    static func fraction(bytesWritten: Int64, expectedBytes: Int64) -> DownloadProgress {
        .fraction(bytesWritten: bytesWritten, expectedBytes: expectedBytes, bytesPerSecond: nil)
    }

    var phase: Phase {
        switch self {
        case .queued: return .queued
        case .connecting: return .connecting
        case .indeterminate: return .indeterminate
        case .fraction: return .fraction
        case .stalled: return .stalled
        case .finalizing: return .finalizing
        }
    }

    var bytesWritten: Int64 {
        switch self {
        case .queued, .connecting:
            return 0
        case .indeterminate(let bytesWritten, _), .fraction(let bytesWritten, _, _):
            return bytesWritten
        case .stalled(let bytesWritten, _), .finalizing(let bytesWritten):
            return bytesWritten
        }
    }

    /// The total the server promised, or `nil` when it never gave a usable one.
    var expectedBytes: Int64? {
        switch self {
        case .fraction(_, let expectedBytes, _):
            return expectedBytes
        case .stalled(_, let expectedBytes):
            return expectedBytes
        case .queued, .connecting, .indeterminate, .finalizing:
            return nil
        }
    }

    var bytesPerSecond: Double? {
        switch self {
        case .indeterminate(_, let rate), .fraction(_, _, let rate):
            return rate
        case .queued, .connecting, .stalled, .finalizing:
            return nil
        }
    }

    /// Whether bytes are still expected to arrive against this phase.
    ///
    /// The throttle's trailing publication requires it: `stalled` and
    /// `finalizing` are both *downloading* states, so "still downloading" would
    /// let a publication that had already passed its sleep overwrite either one.
    var isActivelyMoving: Bool {
        switch self {
        case .indeterminate, .fraction:
            return true
        case .queued, .connecting, .stalled, .finalizing:
            return false
        }
    }

    /// The same report carrying a freshly measured rate, where one can ride.
    func withRate(_ bytesPerSecond: Double?) -> DownloadProgress {
        switch self {
        case .indeterminate(let bytesWritten, _):
            return .indeterminate(bytesWritten: bytesWritten, bytesPerSecond: bytesPerSecond)
        case .fraction(let bytesWritten, let expectedBytes, _):
            return .fraction(
                bytesWritten: bytesWritten, expectedBytes: expectedBytes, bytesPerSecond: bytesPerSecond)
        case .queued, .connecting, .stalled, .finalizing:
            return self
        }
    }

    /// The ratio a progress bar draws, or `nil` when there is no usable total.
    ///
    /// Derived rather than stored: a stored ratio can disagree with the byte
    /// counts beside it, and `reported(bytesWritten:expectedBytes:)` only ever
    /// builds `.fraction` with a positive total, so the division is finite.
    var fractionValue: Double? {
        guard let expectedBytes, expectedBytes > 0 else { return nil }
        guard phase == .fraction || phase == .stalled else { return nil }
        return Self.ratio(bytesWritten: bytesWritten, expectedBytes: expectedBytes)
    }

    /// Clamped so synthesized `Equatable` never carries a `NaN` and
    /// over-delivery never escapes `0...1`.
    static func ratio(bytesWritten: Int64, expectedBytes: Int64) -> Double {
        guard expectedBytes > 0 else { return 0 }
        let value = Double(bytesWritten) / Double(expectedBytes)
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }

    /// Builds the progress a session byte callback describes.
    ///
    /// A non-positive expected count is URLSession's unknown-total state. A
    /// negative written count is not a meaningful update and is dropped.
    static func reported(bytesWritten: Int64, expectedBytes: Int64) -> DownloadProgress? {
        guard bytesWritten >= 0 else { return nil }
        guard expectedBytes > 0 else { return .indeterminate(bytesWritten: bytesWritten) }
        return .fraction(bytesWritten: bytesWritten, expectedBytes: expectedBytes)
    }

    /// Whether publishing this report would change what a transfer row shows.
    ///
    /// Compared over *every* displayed field — phase, queue position, whole
    /// percent, byte count, expected total and rate bucket. It used to answer
    /// `false` for two `.indeterminate` values whose byte counts differed, from
    /// the days when an indeterminate transfer rendered as a bare spinner; the
    /// row now shows the bytes, and the flood that comparison was guarding
    /// against is held off by the once-a-second throttle instead
    /// (`DownloadPacing.publishInterval`).
    ///
    /// Observation invalidates on assignment rather than on inequality, and both
    /// download screens read the published map, so a write that would draw the
    /// same row costs a library-wide body pass for nothing.
    func rendersDifferently(from other: DownloadProgress) -> Bool {
        displayFields != other.displayFields
    }

    private var displayFields: DisplayFields {
        DisplayFields(
            phase: phase, position: queuePosition, bytesWritten: bytesWritten,
            expectedBytes: expectedBytes, percent: percent, rateBucket: rateBucket
        )
    }

    private var queuePosition: Int? {
        guard case .queued(let position) = self else { return nil }
        return position
    }

    /// Safe because `ratio(bytesWritten:expectedBytes:)` clamps to `0...1`.
    private var percent: Int? {
        guard let value = fractionValue else { return nil }
        return Int((value * 100).rounded())
    }

    /// Whole kilobytes per second — the granularity the rendered speed moves at.
    ///
    /// Bucketed rather than compared raw so a rate that differs in the eighth
    /// decimal is not a redraw. `Double` is bounded before the conversion
    /// because a rate is computed from feed-supplied byte counts.
    private var rateBucket: Int? {
        guard let bytesPerSecond, bytesPerSecond.isFinite, bytesPerSecond >= 0 else { return nil }
        let kilobytes = (bytesPerSecond / 1024).rounded()
        guard kilobytes < Double(Int.max) else { return Int.max }
        return Int(kilobytes)
    }

    private struct DisplayFields: Equatable {
        let phase: Phase
        let position: Int?
        let bytesWritten: Int64
        let expectedBytes: Int64?
        let percent: Int?
        let rateBucket: Int?
    }
}
