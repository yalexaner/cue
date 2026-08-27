import Foundation

/// The download route's diagnostics: how a record is written, which progress
/// reports are worth one, and the one-shot epilogue that answers the background
/// session once a delivered outcome has been dealt with.
///
/// Its own file for the reason `DownloadFinish.swift` and `DownloadOwnership.swift`
/// are: `DownloadManager.swift` sits against the 400-line `file_length` warning
/// `--strict` turns into an error.
extension DownloadManager {
    /// The one way a download record reaches the sink.
    func record(_ event: DiagnosticsEvent) {
        diagnostics.record(event.record)
    }

    /// Everything that happens once the session has handed an outcome over.
    ///
    /// The barrier is called from here and nowhere else on this route, exactly
    /// once, and *after* the failure state and the log have been written —
    /// `defer` fired it before the outer `catch` could record anything, so the
    /// records left unprotected were precisely the terminal ones this log exists
    /// to explain (decision 8). `flush()` precedes it because the system may
    /// suspend the app the moment the accounting reaches zero; a flush that
    /// achieves nothing must still complete delivery, since a lost log is
    /// survivable and a never-answered UIKit handler is not.
    func completeDelivery(
        _ delivered: Result<(URL, URLResponse), Error>, guid: String, token: UUID,
        enclosureURL: String, attempt: DiagnosticsAttemptID
    ) async throws {
        var epilogueError: Error?
        do {
            try await consumeDelivered(
                delivered, guid: guid, token: token, enclosureURL: enclosureURL)
            // only while this transfer is still the guid's owner: a completion
            // routed from the session may have taken it over
            if releaseOwnership(of: guid, heldBy: token) { states[guid] = nil }
        } catch {
            if releaseOwnership(of: guid, heldBy: token) {
                states[guid] = failureState(for: error)
            }
            recordTerminalFailure(error, guid: guid, attempt: attempt, enclosureURL: enclosureURL)
            epilogueError = error
        }
        await diagnostics.flush()
        deliveryBarrier()
        if let epilogueError { throw epilogueError }
    }

    /// Turns a delivered outcome into a recorded episode, or throws.
    private func consumeDelivered(
        _ delivered: Result<(URL, URLResponse), Error>, guid: String, token: UUID,
        enclosureURL: String
    ) async throws {
        do {
            try checkCancellation(of: guid, heldBy: token)
        } catch {
            if case .success(let (tempURL, _)) = delivered {
                try? FileManager.default.removeItem(at: tempURL)
            }
            throw error
        }
        let (tempURL, response) = try delivered.get()
        if let failure = Self.statusFailure(for: response, enclosureURL: enclosureURL) {
            // the temporary file is ours once the transport answers, and an
            // error page is not an episode
            try? FileManager.default.removeItem(at: tempURL)
            throw failure
        }
        try await finishDownload(tempURL: tempURL, response: response, forGUID: guid, heldBy: token)
    }

    /// The one place a terminal download failure becomes records.
    ///
    /// Cancellation is not a failure — it is the user backing out — so it gets
    /// its own event and no error level. A non-2xx answer additionally records
    /// the status and the host, which is the pair that makes a rotated-token
    /// 403 readable without any part of the pre-signed address (spec §6).
    func recordTerminalFailure(
        _ error: Error, guid: String, attempt: DiagnosticsAttemptID, enclosureURL: String
    ) {
        let loggedGUID = DiagnosticsGUID(guid)
        guard !isCancellation(error) else {
            record(.downloadCancelled(guid: loggedGUID, attempt: attempt))
            return
        }
        if case DownloadManager.Failure.httpStatus(let status, let urlString) = error {
            record(.downloadHTTPStatus(guid: loggedGUID, host: DiagnosticsHost(urlString), status: status))
        }
        record(.downloadFailed(guid: loggedGUID, attempt: attempt, code: DiagnosticsErrorCode(error)))
    }
}

/// The decile a progress report newly reaches, or `nil` when there is nothing to
/// log.
///
/// A per-attempt record of the highest decile already logged is what makes this
/// answer once per bucket: repeated callbacks inside one decile log nothing, a
/// jump across several logs only the bucket actually reached, and an
/// indeterminate report — the server gave no usable total — has no decile at
/// all. The record lives on the attempt, so it is dropped when the attempt
/// retires and a retry starts again from nothing.
func crossedDecile(for progress: DownloadProgress, lastLogged: Int?) -> Int? {
    guard case .fraction(_, let value) = progress else { return nil }
    let bucket = min(max(Int((value * 10).rounded(.down)), 0), 10)
    guard bucket >= 1, bucket > (lastLogged ?? 0) else { return nil }
    return bucket
}
