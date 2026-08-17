import Foundation

/// Turns a download failure into one line a person can act on, or `nil` when
/// there is nothing to report.
///
/// The download-side counterpart of `reportableFeedErrorMessage(for:)`, and
/// deliberately a second function rather than a case added to
/// `feedErrorMessage(for:)`: the feed mapper stays feed-only, so neither screen
/// can answer with the other's vocabulary.
///
/// Optional for the same reason the feed one is: a transfer cancelled because
/// the view went away is not a failure, and `isCancellation(_:)` is the single
/// classifier for that.
///
/// What spec §6 asks for is the HTTP status: a token-rotated enclosure
/// answering 403 has to be diagnosable from the alert alone. It does not ask
/// for the address, and an enclosure URL must not be shown — spec §7's private
/// feeds pre-sign them, so the URL *is* the credential, which is why the
/// download log writes it `.private`. Anything URL-shaped therefore goes
/// through `redactedAddress(_:)` first; every other case still names the value
/// it is about.
func downloadErrorMessage(for error: Error) -> String? {
    if isCancellation(error) { return nil }

    switch error {
    case let failure as DownloadManager.Failure:
        return message(for: failure)
    case let failure as EpisodeStore.Failure:
        return message(for: failure)
    default:
        // transport errors (`URLError`, ATS rejections) and storage errors
        // propagate unwrapped, and their own descriptions beat anything
        // invented here
        return error.localizedDescription
    }
}

private func message(for failure: DownloadManager.Failure) -> String {
    switch failure {
    case .invalidEnclosureURL(let urlString):
        return "This episode's audio address is not a valid http or https address (\(redactedAddress(urlString)))."
    case .httpStatus(let status, let urlString):
        return "The server answered \(status) for \(redactedAddress(urlString))."
    }
}

/// The most of an enclosure URL an alert may show: its scheme and its host.
///
/// A pre-signed URL carries its credential wherever the publisher put it — the
/// query, the userinfo, or a path segment — so nothing below the host is safe
/// to render, and saying which server answered is enough to act on a 403. An
/// address that does not parse is not echoed back either: it reached here
/// precisely because it is not the shape this can trim, so it gets a fixed
/// phrase instead.
///
/// A free function next to the mapper, because it is view policy and therefore
/// testable on its own (AGENTS.md).
func redactedAddress(_ urlString: String) -> String {
    guard let components = URLComponents(string: urlString), let host = components.host, !host.isEmpty
    else {
        return "an unreadable address"
    }
    guard let scheme = components.scheme, !scheme.isEmpty else { return host }
    return "\(scheme)://\(host)"
}

private func message(for failure: EpisodeStore.Failure) -> String {
    switch failure {
    case .invalidFilename(let filename):
        return "\(filename) is not a usable file name for a download."
    }
}
