import Foundation
import OSLog

extension DownloadManager {
    /// Installs the route a completion with no continuation takes.
    ///
    /// Synchronous, and called from `CueApp.init()` rather than only from a
    /// view's `.task`: a relaunch made purely to deliver a finished transfer may
    /// never present a scene, and a completion with nowhere to go is a finished
    /// download thrown away.
    func registerCompletionRoute(with downloader: BackgroundDownloader) {
        downloader.setAttemptRegistrationHandler { [weak self] taskIdentifier, guid in
            await self?.registerAttempt(taskIdentifier: taskIdentifier, forGUID: guid)
        }
        downloader.setProgressHandler { [weak self] taskIdentifier, guid, progress in
            Task { @MainActor [weak self] in
                self?.handleProgress(taskIdentifier: taskIdentifier, guid: guid, progress: progress)
            }
        }
        downloader.setOrphanedCompletionHandler { [weak self] result, guid in
            Task { @MainActor [weak self] in
                // the system may suspend the app once the downloader answers
                // UIKit, and it waits for this
                defer { downloader.completeDeliveredWork() }
                guard let self else {
                    if case .success(let (tempURL, _)) = result {
                        try? FileManager.default.removeItem(at: tempURL)
                    }
                    return
                }
                await handleCompletion(result, forGUID: guid)
            }
        }
    }

    /// What the relaunch route does with a transfer that finished without us.
    ///
    /// A failure is recorded as one: the transfer belongs to a process that may
    /// be gone, so there is no continuation to throw to, and a row left
    /// `.downloading` offers neither a retry nor a delete.
    ///
    /// Separate from the closure that installs it so the policy is testable
    /// without constructing a background session.
    func handleCompletion(_ result: Result<(URL, URLResponse), Error>, forGUID guid: String) async {
        // both before the awaits below: an `adopt` landing mid-finish must not
        // mark this transfer as still in flight, and the claim is what the
        // duplicate guard in `download(_:)` tests. Without it the row reads as
        // idle for the length of the finish — which suspends, on the asset read
        // — so a tap starts a second transfer for the same guid, and the finish
        // below then clears the state that second transfer is holding
        resolvedGUIDs.insert(guid)
        // a live transfer of this process already holds the guid, so there is
        // nothing here to write: one writer per guid (`DownloadOwnership.swift`).
        // Discard the delivered file exactly as the unknown-guid path does. The
        // tradeoff is deliberate — if that transfer later fails a finished
        // download is thrown away and the user retries, which beats a deleted
        // download reappearing
        let token: UUID
        if let attempt = attempts[guid], attempt.origin == .adopted {
            token = attempt.token
        } else if let attempt = attempts[guid], attempt.origin == .started {
            if case .success(let (tempURL, _)) = result {
                Self.logger.notice("completion for a guid already in flight here; discarding the file")
                try? FileManager.default.removeItem(at: tempURL)
            }
            return
        } else {
            guard let claimed = claimOwnership(of: guid, origin: .adopted) else { return }
            token = claimed
        }
        states[guid] = .downloading(attempts[guid]?.progress ?? .waiting)
        do {
            switch result {
            case .success(let (tempURL, response)):
                try await finishDownload(tempURL: tempURL, response: response, forGUID: guid)
                if releaseOwnership(of: guid, heldBy: token) { states[guid] = nil }
            case .failure(let error):
                throw error
            }
        } catch {
            // nothing is on screen to alert on the relaunch route; the row shows
            // the failure the next time it is looked at
            if releaseOwnership(of: guid, heldBy: token) {
                states[guid] = isCancellation(error) ? nil : .failed
            }
            // never `.public`: a `httpStatus` failure carries the enclosure URL,
            // and a private feed's URL is a token (spec §6)
            Self.logger.error("background download failed: \(error, privacy: .private)")
        }
    }

    /// Marks the transfers the system kept running while the app was gone.
    ///
    /// A guid already resolved is skipped: the session's answer is a snapshot
    /// taken before an `await`, so a completion routed in the meantime would
    /// otherwise be overwritten with a `.downloading` nothing clears.
    func adopt(inFlightAttempts identities: [DownloadAttemptIdentity]) {
        for identity in identities where !resolvedGUIDs.contains(identity.guid) {
            guard attempts[identity.guid] == nil else { continue }
            guard
                claimOwnership(
                    of: identity.guid, origin: .adopted,
                    taskIdentifier: identity.taskIdentifier) != nil
            else { continue }
            states[identity.guid] = .downloading(.waiting)
        }
    }
}
