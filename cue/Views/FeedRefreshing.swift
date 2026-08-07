import Foundation

/// Refreshes every subscribed feed in order and reports the first real failure,
/// or `nil` when there was none (spec §6).
///
/// Sequential on purpose: feeds are few, and one context doing one thing at a
/// time is the cheapest way to keep SwiftData writes ordered. A failing feed
/// does not stop the others, so one dead subscription cannot leave the rest of
/// the library stale — and it is the *first* failure that is reported, so the
/// alert names the feed that broke rather than whichever broke last.
///
/// A free function rather than a method on the view, per the project rule that
/// anything worth asserting leaves the view: the continue-past-failure and
/// first-error-wins behaviours are decisions, not chrome.
@MainActor
func refreshAll(_ podcasts: [Podcast], using service: FeedService) async -> Error? {
    var firstError: Error?

    for podcast in podcasts {
        if Task.isCancelled { break }
        do {
            try await service.refresh(podcast)
        } catch let error where isCancellation(error) {
            break
        } catch {
            if firstError == nil { firstError = error }
        }
    }

    return firstError
}

/// Whether an error is cooperative cancellation rather than a failure to report.
///
/// `.refreshable`'s task is cancelled when its view goes away, and `URLSession`
/// surfaces that as `URLError.cancelled`. Treating it as a failure pops a
/// "Refresh Failed" alert on a disappearing view, and inside the sweep it would
/// become `firstError` and mask the real one.
func isCancellation(_ error: Error) -> Bool {
    if error is CancellationError { return true }
    if let urlError = error as? URLError, urlError.code == .cancelled { return true }
    return false
}
