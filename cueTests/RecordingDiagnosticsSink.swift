import Foundation

@testable import cue

/// The one test double for `DiagnosticsSink`: keeps every record in memory and
/// counts flushes, so nothing a diagnostics test asserts on ever reaches disk.
///
/// One double rather than one per suite, the same rule as `FeedTransportStub`,
/// `DownloadTransportStub` and the shared fixture loader.
///
/// `flushSilentlyFails` models the only failure a sink can have: `flush()`
/// cannot throw — a logging failure must never fail its caller — so a writer
/// whose file is unavailable simply achieves nothing. The flag exists so a test
/// can say "the flush accomplished nothing" and still assert the UIKit handler
/// was answered.
final class RecordingDiagnosticsSink: DiagnosticsSink, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [DiagnosticsRecord] = []
    private var flushes = 0
    private var attempts = 0
    private let flushSilentlyFails: Bool

    init(flushSilentlyFails: Bool = false) {
        self.flushSilentlyFails = flushSilentlyFails
    }

    var records: [DiagnosticsRecord] { lock.withLock { stored } }
    /// Flushes that actually drained. A silently-failing sink never counts one.
    var flushCount: Int { lock.withLock { flushes } }
    /// Flushes the caller *asked* for, whether or not they achieved anything.
    var flushAttemptCount: Int { lock.withLock { attempts } }
    var eventNames: [String] { records.map(\.event) }

    func record(_ record: DiagnosticsRecord) {
        lock.withLock { stored.append(record) }
    }

    func flush() async {
        lock.withLock {
            attempts += 1
            // the modelled failure: the file is unavailable, so awaiting this
            // returns having drained nothing. It must still be distinguishable
            // from a flush that worked, or a test asserting "the barrier fires
            // even when the flush achieves nothing" exercises the working path
            guard !flushSilentlyFails else { return }
            flushes += 1
        }
    }

    /// Every record for one event name, in the order they were written.
    func records(named event: String) -> [DiagnosticsRecord] {
        records.filter { $0.event == event }
    }
}

/// One record's fields as a dictionary, for assertions that do not care about
/// field order (`DiagnosticsLineTests` is what pins the order).
extension DiagnosticsRecord {
    var fieldsByKey: [String: String] {
        Dictionary(fields.map { ($0.key, $0.value) }, uniquingKeysWith: { first, _ in first })
    }
}
