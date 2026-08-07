import Foundation

/// Turns an add/refresh error into one line a person can act on (spec §6).
///
/// A free function over `Error` rather than a `LocalizedError` conformance: the
/// errors it maps are owned by the feed layer, which has no business carrying
/// presentation strings, and a plain function is testable without a view.
///
/// Every case names the offending value — the whole point of `httpStatus` and
/// `emptyFeed` carrying the URL is that a private feed's 401/403 is diagnosable
/// from the message alone.
func feedErrorMessage(for error: Error) -> String {
    switch error {
    case let failure as FeedService.Failure:
        return message(for: failure)
    case let failure as FeedParser.Failure:
        return message(for: failure)
    default:
        // transport errors (`URLError`, ATS rejections) propagate unwrapped, and
        // their own descriptions are better than anything invented here
        return error.localizedDescription
    }
}

/// The message a failed add or refresh should show, or `nil` when there is
/// nothing to report.
///
/// The whole policy behind a single-feed view action: cancellation is silence,
/// everything else is a line naming what failed. A free function because the
/// two screens that run one feed at a time would otherwise each hand-write the
/// `catch let error where isCancellation(error)` clause, and a screen that
/// forgets it pops "Refresh Failed" on a view the user just left — the same
/// mistake `refreshAll(_:using:)` exists to keep out of the sweep.
func reportableFeedErrorMessage(for error: Error) -> String? {
    isCancellation(error) ? nil : feedErrorMessage(for: error)
}

private func message(for failure: FeedService.Failure) -> String {
    switch failure {
    case .invalidURL(let urlString):
        return "\(urlString) is not a valid http or https feed address."
    case .httpStatus(let status, let urlString):
        return "The server answered \(status) for \(urlString)."
    case .allEpisodesOwnedElsewhere(let urlString):
        return "Every episode in the feed at \(urlString) already belongs to another subscription."
    }
}

private func message(for failure: FeedParser.Failure) -> String {
    switch failure {
    case .malformedXML:
        return "That address did not return a readable RSS document."
    case .missingChannelTitle:
        return "That feed has no title, so it cannot be added."
    case .emptyFeed(let urlString):
        return "No episodes were found in the feed at \(urlString)."
    }
}
