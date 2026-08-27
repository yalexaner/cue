import Foundation

/// One feed that failed a sweep, kept whole.
///
/// The `Error` is carried unchanged — wrapping it would hide the cause, and the
/// screen still has to hand it to `isCancellation(_:)` and to the message
/// mapper — beside the only part of its address that may be shown or logged.
/// The pair travels together because by the time the alert is composed the
/// podcast that produced the error is long out of scope.
struct FeedRefreshFailure {
    let error: any Error
    let host: DiagnosticsHost
}

/// What a whole sweep did.
///
/// Counts rather than a bare first error: a refresh over five subscriptions
/// where one is dead is a *partial* success, and reporting only the failure
/// tells the user nothing about the four shows that did update.
struct FeedRefreshSummary {
    let refreshed: Int
    let failed: Int
    let firstFailure: FeedRefreshFailure?

    static let empty = FeedRefreshSummary(refreshed: 0, failed: 0, firstFailure: nil)
}

/// The feed a sweep is about to fetch, and where it sits in the run.
struct FeedRefreshStep {
    let host: DiagnosticsHost
    let index: Int
    let total: Int
}

/// Refreshes every subscribed feed in order and reports what happened
/// (spec §6).
///
/// Sequential on purpose: feeds are few, and one context doing one thing at a
/// time is the cheapest way to keep SwiftData writes ordered. A failing feed
/// does not stop the others, so one dead subscription cannot leave the rest of
/// the library stale — and it is the *first* failure that is reported, so the
/// alert names the feed that broke rather than whichever broke last.
///
/// `onStep` is called before each fetch so a screen can say which feed it is
/// waiting on. It is a plain closure rather than a returned stream because the
/// caller is a `.refreshable` body that has to stay a single `await`.
///
/// A free function rather than a method on the view, per the project rule that
/// anything worth asserting leaves the view: the continue-past-failure,
/// first-error-wins and cancellation-is-not-a-failure behaviours are decisions,
/// not chrome.
@MainActor
func refreshAll(
    _ podcasts: [Podcast],
    using service: FeedService,
    onStep: (FeedRefreshStep) -> Void = { _ in }
) async -> FeedRefreshSummary {
    var refreshed = 0
    var failed = 0
    var firstFailure: FeedRefreshFailure?

    for (index, podcast) in podcasts.enumerated() {
        if Task.isCancelled { break }
        let host = DiagnosticsHost(podcast.feedURL)
        onStep(FeedRefreshStep(host: host, index: index, total: podcasts.count))
        do {
            try await service.refresh(podcast)
            refreshed += 1
        } catch let error where isCancellation(error) {
            break
        } catch {
            failed += 1
            if firstFailure == nil {
                firstFailure = FeedRefreshFailure(error: error, host: host)
            }
        }
    }

    return FeedRefreshSummary(refreshed: refreshed, failed: failed, firstFailure: firstFailure)
}

/// Whether an error is cooperative cancellation rather than a failure to report.
///
/// `.refreshable`'s task is cancelled when its view goes away, and `URLSession`
/// surfaces that as `URLError.cancelled`. Treating it as a failure pops a
/// "Refresh Failed" alert on a disappearing view, and inside the sweep it would
/// become the first failure and mask the real one.
func isCancellation(_ error: Error) -> Bool {
    if error is CancellationError { return true }
    if let urlError = error as? URLError, urlError.code == .cancelled { return true }
    return false
}
