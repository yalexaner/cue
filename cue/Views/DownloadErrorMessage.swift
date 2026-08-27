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
    case let error as URLError:
        return message(for: error)
    case is CocoaError:
        // this mapper also answers the Downloads screen's disk scan and its
        // delete, so the sentence has to fit a file that could not be read or
        // removed as well as one that could not be written
        return "The download file could not be read or written. Check available storage and try again."
    default:
        // An arbitrary error description can contain its failing URL, including
        // a pre-signed enclosure credential. Unknown categories therefore get
        // a fixed sentence instead of a pass-through description.
        return "The download failed. Please try again."
    }
}

/// The four things a `URLError` is actually telling the user.
///
/// Answering every one of them with "could not reach the server" is what made
/// the first device session undiagnosable: a transfer that timed out at 100%, a
/// connection dropped mid-file and a file that could not be written to storage
/// all read as the same sentence, so neither the owner nor an agent could say
/// which had happened. The categories below are the ones that change what a
/// person does next — wait and retry, check the network, or free up space —
/// and anything outside them keeps the original fixed sentence rather than
/// inventing a guess.
///
/// `localizedDescription` is never passed through: `URLError` carries its
/// failing URL, and on a private feed that URL is the credential (spec §6).
private func message(for error: URLError) -> String {
    switch error.code {
    case .timedOut:
        return "The download timed out. The server stopped answering — try again."
    case .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost,
        .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed, .secureConnectionFailed:
        return "The connection to the server was lost. Check your connection and try again."
    case .cannotWriteToFile, .cannotMoveFile, .cannotCreateFile, .cannotRemoveFile, .cannotOpenFile,
        .cannotCloseFile:
        return "The download could not be saved to storage. Check available storage and try again."
    default:
        return "The download could not reach the server. Check your connection and try again."
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
