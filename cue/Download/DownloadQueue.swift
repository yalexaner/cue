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
            reindexQueuedTransfers()
        }
    }

    /// Removes the first waiter this matches and fails it, answering whether
    /// there was one. Cancelling a queued transfer takes effect immediately
    /// rather than when the slot it never reached is handed on.
    @discardableResult
    func cancelWaiter(_ matches: (TransferWaiter) -> Bool) -> Bool {
        guard let index = waiting.firstIndex(where: matches) else { return false }
        waiting.remove(at: index).continuation.resume(throwing: CancellationError())
        reindexQueuedTransfers()
        return true
    }

    /// Republishes every queued transfer's place in line.
    ///
    /// The position a row shows is derived from the FIFO array rather than
    /// stored on the attempt, so there is one source of truth and no way for a
    /// removal to leave a stale number on screen. Called whenever the array
    /// shrinks — a slot handed on, a queued transfer cancelled — and the write
    /// is immediate rather than throttled, because a lifecycle change the user
    /// caused must not wait for the next byte callback.
    ///
    /// A waiter whose state is not a queued transfer is skipped: it may have
    /// failed, been retired, or not yet published anything.
    func reindexQueuedTransfers() {
        for (index, waiter) in waiting.enumerated() {
            guard case .downloading(let published)? = states[waiter.guid] else { continue }
            guard case .queued = published else { continue }
            let reindexed = DownloadProgress.queued(position: index + 1)
            guard reindexed.rendersDifferently(from: published) else { continue }
            invalidatePendingPublication(forGUID: waiter.guid)
            states[waiter.guid] = .downloading(reindexed)
        }
    }

    /// Moves a queued transfer to `connecting` once it owns the slot, and
    /// starts the clock the stall deadline measures against.
    ///
    /// The state write happens only from `queued`: an attempt that already
    /// reported bytes, failed or retired must not be dragged back to a
    /// pre-transfer phase. The deadline is armed either way — taking the slot is
    /// the last thing that demonstrably happened, and a connection that never
    /// answers is exactly what the stalled phase exists to name.
    func publishConnecting(forGUID guid: String) {
        if var attempt = attempts[guid] {
            attempt.lastIncreaseAt = clock.now()
            attempts[guid] = attempt
            scheduleStallDeadline(forGUID: guid)
        }
        guard case .downloading(let published)? = states[guid] else { return }
        guard case .queued = published else { return }
        invalidatePendingPublication(forGUID: guid)
        states[guid] = .downloading(.connecting)
    }
}
