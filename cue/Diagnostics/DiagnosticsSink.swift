import Foundation

/// Where a diagnostics record goes.
///
/// `record(_:)` does not throw and does not fail its caller: a logging failure
/// must never turn a working download into a broken one, so a writer degrades
/// to `os_log` and swallows the rest.
///
/// `record(_:)` is also a *fence*, not merely serialized — it enqueues
/// synchronously, so a following `await flush()` is guaranteed to wait behind
/// it. The background-delivery barrier depends on that: it answers the system's
/// "may I suspend you" question after flushing, and a record that had not yet
/// been enqueued when the flush ran would be the one terminal record the whole
/// subsystem exists to capture.
protocol DiagnosticsSink: Sendable {
    func record(_ record: DiagnosticsRecord)
    func flush() async
}

/// The default everywhere, so no existing test writes to disk by accident.
struct NoOpDiagnosticsSink: DiagnosticsSink {
    func record(_ record: DiagnosticsRecord) {}
    func flush() async {}
}

/// Reading the log back out, for export.
///
/// Deliberately a second protocol rather than a member of `DiagnosticsSink`:
/// widening the sink would force every conformance — the no-op included — to
/// answer a question it has no business answering, and the export screen must
/// not get at a snapshot by downcasting a sink it was handed for writing.
protocol DiagnosticsSnapshotSource: Sendable {
    /// Every retained generation, oldest first, each as its full text.
    ///
    /// Pending records are flushed first, so a snapshot taken right after an
    /// event contains it.
    func snapshot() async -> [String]
}

/// The default snapshot source, so a preview or a view under test offers an
/// export that succeeds and contains nothing — the same reason the sink
/// defaults to the no-op.
struct EmptyDiagnosticsSnapshotSource: DiagnosticsSnapshotSource {
    func snapshot() async -> [String] { [] }
}
