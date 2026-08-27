import Foundation

/// Turns a failed diagnostics export into one line a person can act on.
///
/// A third mapper rather than a reuse of `downloadErrorMessage(for:)`, for the
/// reason that one is a second mapper rather than a case on
/// `feedErrorMessage(for:)`: a screen must not answer with another screen's
/// vocabulary. Handed a `CocoaError` the download mapper says "The download
/// file could not be read or written", which under an alert titled *Could Not
/// Export Diagnostics* tells the user a download failed.
///
/// Non-optional, unlike the other two. Cancellation is a real answer there — a
/// transfer the user backed out of, a refresh on a disappearing view — but the
/// export is one tap that either produces a file or does not, so `nil` here
/// would only be a way for the button to fail silently.
///
/// The same redaction discipline applies: an arbitrary error's description can
/// carry a container path, so anything unrecognised gets a fixed sentence.
func diagnosticsExportErrorMessage(for error: Error) -> String {
    switch error {
    case is CocoaError:
        return "The diagnostics file could not be written. Check available storage and try again."
    default:
        return "The diagnostics log could not be exported. Please try again."
    }
}
