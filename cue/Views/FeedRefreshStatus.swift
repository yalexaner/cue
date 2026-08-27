import Foundation

/// The constants the refresh status is measured against.
enum FeedRefreshStatus {
    /// How long one feed may be outstanding before the status admits it is
    /// waiting rather than merely working.
    ///
    /// Five seconds, against a twenty-second request timeout: long enough that
    /// a healthy feed never shows it, short enough that the fifteen seconds
    /// before a timeout are not silent.
    static let stillWaitingThreshold: TimeInterval = 5
}

/// What a running refresh is doing, as a value a test can construct.
///
/// The host is already reduced to scheme-and-host by `DiagnosticsHost` before
/// it gets here — a private feed's URL is its credential (spec §6), and this
/// text goes on screen.
enum FeedRefreshPhase: Equatable, Sendable {
    case fetching(host: String, index: Int, total: Int)
    case stillWaiting(host: String, index: Int, total: Int)
}

/// The line shown while a refresh runs, or `nil` when there is nothing to say.
func feedRefreshStatusText(for phase: FeedRefreshPhase?) -> String? {
    switch phase {
    case nil:
        return nil
    case .fetching(let host, let index, let total):
        return "Checking \(host)\(positionSuffix(index: index, total: total))…"
    case .stillWaiting(let host, let index, let total):
        return "Still waiting for \(host)\(positionSuffix(index: index, total: total))…"
    }
}

/// What a finished sweep reports outside the alert, or `nil` when the counts
/// say nothing the alert does not.
///
/// A clean sweep is silent, and an entirely failed one is the alert's story —
/// only a *partial* sweep needs this, because the alert names one broken feed
/// and would otherwise leave the user believing nothing updated.
func feedRefreshSummaryText(refreshed: Int, failed: Int) -> String? {
    guard failed > 0, refreshed > 0 else { return nil }
    return "Refreshed \(refreshed) of \(refreshed + failed) feeds; \(failed) could not be reached."
}

/// " (2 of 5)" for a multi-feed sweep, nothing for a single feed.
private func positionSuffix(index: Int, total: Int) -> String {
    guard total > 1 else { return "" }
    return " (\(index + 1) of \(total))"
}

/// The small piece of state behind the status line.
///
/// A model rather than one more formatting function because the "still waiting"
/// transition is time-driven: nothing arrives to trigger it, so something has
/// to be waiting on a clock. That clock is injected like every other time seam
/// here, so the five-second transition is tested without sleeping for five
/// seconds.
///
/// Every armed wait carries a generation, and every transition bumps it: the
/// pending task is cancelled too, but a cancellation observed after the sleep
/// has already returned would otherwise let a retired wait overwrite the phase
/// of the feed that replaced it.
@MainActor
@Observable
final class FeedRefreshStatusModel {
    private(set) var phase: FeedRefreshPhase?

    private let clock: DownloadClock
    private var pending: Task<Void, Never>?
    private var generation = 0

    init(clock: DownloadClock = SystemDownloadClock()) {
        self.clock = clock
    }

    var statusText: String? { feedRefreshStatusText(for: phase) }

    /// A feed is about to be fetched.
    func began(_ step: FeedRefreshStep) {
        let armed = beginGeneration()
        phase = .fetching(host: step.host.redacted, index: step.index, total: step.total)
        pending = Task { [weak self] in
            guard let clock = self?.clock else { return }
            do {
                try await clock.sleep(for: FeedRefreshStatus.stillWaitingThreshold)
            } catch {
                return
            }
            guard let self, self.generation == armed else { return }
            guard case .fetching(let host, let index, let total) = self.phase else { return }
            self.phase = .stillWaiting(host: host, index: index, total: total)
        }
    }

    /// The sweep is over, whatever it did. The status line goes away; the counts
    /// and the failure are the caller's to report.
    func finished() {
        _ = beginGeneration()
        phase = nil
    }

    private func beginGeneration() -> Int {
        pending?.cancel()
        pending = nil
        generation += 1
        return generation
    }
}
