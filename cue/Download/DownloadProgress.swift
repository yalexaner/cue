import Foundation

/// Observable byte progress for one background episode transfer.
///
/// `waiting` is distinct from an indeterminate transfer: the latter has
/// received bytes, but the server did not provide a usable total. Raw bytes
/// travel with every moving state so delayed main-actor hops can be ordered.
enum DownloadProgress: Equatable, Sendable {
    case waiting
    case indeterminate(bytesWritten: Int64)
    case fraction(bytesWritten: Int64, value: Double)

    var bytesWritten: Int64 {
        switch self {
        case .waiting:
            return 0
        case .indeterminate(let bytesWritten), .fraction(let bytesWritten, _):
            return bytesWritten
        }
    }

    /// Builds the progress a session byte callback describes.
    ///
    /// A non-positive expected count is URLSession's unknown-total state. A
    /// negative written count is not a meaningful update and is dropped. The
    /// derived fraction is finite and clamped so synthesized `Equatable` never
    /// has to carry a `NaN` and over-delivery never escapes `0...1`.
    static func reported(bytesWritten: Int64, expectedBytes: Int64) -> DownloadProgress? {
        guard bytesWritten >= 0 else { return nil }
        guard expectedBytes > 0 else { return .indeterminate(bytesWritten: bytesWritten) }
        let value = Double(bytesWritten) / Double(expectedBytes)
        guard value.isFinite else { return nil }
        return .fraction(bytesWritten: bytesWritten, value: min(max(value, 0), 1))
    }

    /// Whether publishing this report would change what a transfer row shows.
    ///
    /// A row draws "Waiting…", a spinner, or a bar plus an accessibility value
    /// rounded to whole percent — the byte count itself is never displayed.
    /// `URLSession` reports bytes many times a second and every write to the
    /// observed state map re-evaluates both download screens, so a report that
    /// would redraw the same row is dropped instead of costing a library-wide
    /// body pass per callback. Ordering is unaffected: the exact byte count is
    /// still recorded on the attempt.
    func rendersDifferently(from other: DownloadProgress) -> Bool {
        switch (self, other) {
        case (.waiting, .waiting), (.indeterminate, .indeterminate):
            return false
        case (.fraction(_, let value), .fraction(_, let otherValue)):
            return Self.percent(value) != Self.percent(otherValue)
        default:
            return true
        }
    }

    /// Safe because `reported(bytesWritten:expectedBytes:)` clamps to `0...1`.
    private static func percent(_ value: Double) -> Int {
        Int((min(max(value, 0), 1) * 100).rounded())
    }
}
