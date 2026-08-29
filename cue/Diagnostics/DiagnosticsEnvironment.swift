import SwiftUI

/// How the one production sink reaches `FeedService`.
///
/// `FeedService` is a cheap struct constructed inside three views
/// (`AddFeedView`, `PodcastDetailView`, `LibraryView`) and never by `CueApp`, so
/// there is no initialiser for the app to inject through. The environment is the
/// only seam that reaches all three without turning the service into a shared
/// instance — `CueApp` sets it once and each view reads it beside its
/// `ModelContext`.
///
/// The default is the no-op, so a preview or a view under test writes nothing to
/// disk by accident.
extension EnvironmentValues {
    @Entry var diagnostics: DiagnosticsSink = NoOpDiagnosticsSink()
}

/// How the export screen reaches the log without downcasting the sink it was
/// handed for writing. Set beside `\.diagnostics` by `CueApp`, backed by the
/// same production writer.
extension EnvironmentValues {
    @Entry var diagnosticsSnapshots: DiagnosticsSnapshotSource = EmptyDiagnosticsSnapshotSource()
}
