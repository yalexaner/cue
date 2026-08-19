import Foundation

/// The single-transfer slot every download waits for (spec §7).
///
/// Its own file for the reason `DownloadFinish.swift` and `DownloadOwnership.swift`
/// are: `DownloadManager.swift` sits against the 400-line `file_length` warning
/// that `--strict` turns into an error, and the queue is a cohesive topic to
/// lift out. That split is why `isTransferring` and `waiting` are internal on
/// the manager rather than private.
///
/// Waiters park on *throwing* continuations and carry both an id and a guid:
/// a queued transfer has no session task yet, so `session.allTasks` cannot
/// reach it, and a cancelled-set consulted only after the slot arrives would
/// leave Cancel apparently ignored until every earlier transfer finishes.
extension DownloadManager {
    /// Spec §7 allows one active transfer; the rest wait their turn in order.
    struct TransferWaiter {
        let id: UUID
        let guid: String
        let continuation: CheckedContinuation<Void, Error>
    }

    /// Waits until this call owns the single transfer slot.
    ///
    /// FIFO: a caller that finds the slot busy parks its continuation at the
    /// back of `waiting`, and `releaseSlot()` hands the slot to the front. All
    /// of it is main-actor state, so there is no lock to get wrong.
    func acquireSlot(forGUID guid: String) async throws {
        guard isTransferring else {
            isTransferring = true
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                waiting.append(TransferWaiter(id: id, guid: guid, continuation: continuation))
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelWaiter { $0.id == id }
            }
        }
    }

    func releaseSlot() {
        if waiting.isEmpty {
            isTransferring = false
        } else {
            waiting.removeFirst().continuation.resume()
        }
    }

    /// Removes the first waiter this matches and fails it, answering whether
    /// there was one. Cancelling a queued transfer takes effect immediately
    /// rather than when the slot it never reached is handed on.
    @discardableResult
    func cancelWaiter(_ matches: (TransferWaiter) -> Bool) -> Bool {
        guard let index = waiting.firstIndex(where: matches) else { return false }
        waiting.remove(at: index).continuation.resume(throwing: CancellationError())
        return true
    }
}
