import Foundation

/// The feed route's diagnostics: how long a fetch took, and the one place a
/// fetch failure becomes a record.
///
/// Its own file for the reason `DownloadDiagnostics.swift` is:
/// `FeedService.swift` sits against the 400-line `file_length` warning
/// `--strict` turns into an error.
extension FeedService {
    /// Whole milliseconds since `start`, on a clock that cannot step backwards.
    ///
    /// `ContinuousClock` rather than `Date`: a wall-clock adjustment mid-fetch
    /// would otherwise be logged as a negative or absurd duration.
    static func elapsedMilliseconds(since start: ContinuousClock.Instant) -> Int {
        let elapsed = ContinuousClock.now - start
        let components = elapsed.components
        return Int(components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000)
    }

    /// Records a failed fetch, unless the user backed out.
    ///
    /// Cancellation is the user backing out — Cancel on the add sheet, a view
    /// going away mid-refresh — not a failure, and the download route already
    /// draws that line in `recordTerminalFailure`. Recorded as one it fills the
    /// export with error-level noise for deliberate actions, and classifies the
    /// same event two ways across the app.
    ///
    /// Every way a fetch can end badly comes through here, the parse included: a
    /// malformed document that logged `feed.fetch_succeeded` and then nothing is
    /// the "a request followed by silence" ambiguity the download route closed
    /// with `download.not_started`, and it reads as an app that stopped rather
    /// than a feed that is broken.
    func recordFetchFailure(_ error: Error, host: DiagnosticsHost, startedAt: ContinuousClock.Instant) {
        guard !isCancellation(error) else { return }
        diagnostics.record(
            DiagnosticsEvent.feedFetchFailed(
                host: host, code: DiagnosticsErrorCode(error),
                elapsedMilliseconds: Self.elapsedMilliseconds(since: startedAt)
            ).record)
    }
}
