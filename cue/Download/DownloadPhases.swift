import Foundation

/// When a transfer's phase is published, and when it is held back.
///
/// Its own file for the reason `DownloadQueue.swift` and `DownloadOwnership.swift`
/// are: `DownloadManager.swift` sits against the 400-line `file_length` warning
/// `--strict` turns into an error. That split is why the deadline and
/// publication task maps are internal on the manager rather than private.
///
/// Two rules run through everything here.
///
/// *Lifecycle transitions are never throttled.* Queued to connecting, a queue
/// reindex, stalled, finalizing and every terminal state are published the
/// moment they happen, and each of them invalidates any pending byte
/// publication — a change the user caused must not wait for the next callback,
/// and a callback must not undo it.
///
/// *A deferred publication proves who it is before it writes.* It carries its
/// own publication generation as well as the guid and the attempt token,
/// because "still downloading" is not enough: `stalled` and `finalizing` are
/// both downloading states, so a publication that had already passed its sleep
/// would overwrite either one.
extension DownloadManager {
    // MARK: - Publishing byte progress

    /// Publishes a byte report now, or defers it to the end of the interval.
    ///
    /// A transfer that had been marked stalled publishes immediately, but only
    /// when it actually *moved*: resuming is a lifecycle transition, and a
    /// report whose byte count merely equals the one before it — a corrected
    /// total arrives that way — is not movement. Un-stalling on one would be
    /// unrecoverable: `markStalled` has already cleared the deadline, and only a
    /// strict byte increase arms a new one, so the row would go on claiming to
    /// be downloading for the rest of a transfer that had stopped.
    func publishProgress(
        _ progress: DownloadProgress, forGUID guid: String, replacing published: DownloadProgress,
        at now: TimeInterval, movedForward: Bool
    ) {
        if published.phase == .stalled {
            guard movedForward else { return }
            publishImmediately(progress, forGUID: guid, at: now)
            return
        }
        guard progress.rendersDifferently(from: published) else { return }
        guard let attempt = attempts[guid] else { return }
        guard let last = attempt.lastPublishedAt, now - last < DownloadPacing.publishInterval else {
            publishImmediately(progress, forGUID: guid, at: now)
            return
        }
        schedulePendingPublication(forGUID: guid, after: DownloadPacing.publishInterval - (now - last))
    }

    /// Writes a byte report through, cancelling anything queued behind it.
    private func publishImmediately(
        _ progress: DownloadProgress, forGUID guid: String, at now: TimeInterval
    ) {
        guard var attempt = attempts[guid] else { return }
        attempt.lastPublishedAt = now
        attempts[guid] = attempt
        invalidatePendingPublication(forGUID: guid)
        states[guid] = .downloading(progress)
    }

    /// Arms the one trailing publication this attempt may have outstanding.
    ///
    /// One per attempt: a second would publish the same latest report twice.
    /// The armed task reads the attempt's progress when it fires, so it always
    /// delivers the newest report rather than the one that armed it.
    private func schedulePendingPublication(forGUID guid: String, after delay: TimeInterval) {
        guard pendingPublications[guid] == nil else { return }
        guard let attempt = attempts[guid] else { return }
        let token = attempt.token
        let generation = attempt.publicationGeneration
        let clock = self.clock
        pendingPublications[guid] = Task { @MainActor [weak self] in
            do {
                try await clock.sleep(for: delay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.flushPendingProgress(forGUID: guid, heldBy: token, generation: generation)
        }
    }

    /// The trailing publication's body, separated so it is testable without
    /// waiting for a sleep to elapse.
    ///
    /// Every guard here is load-bearing: the attempt must still be the one that
    /// armed this, no lifecycle transition may have happened since, the transfer
    /// must still be actively moving, and the report must still draw a different
    /// row.
    func flushPendingProgress(forGUID guid: String, heldBy token: UUID, generation: Int) {
        pendingPublications[guid] = nil
        guard var attempt = attempts[guid], attempt.token == token else { return }
        guard attempt.publicationGeneration == generation else { return }
        guard case .downloading(let published)? = states[guid] else { return }
        guard published.isActivelyMoving || published.phase == .connecting else { return }
        guard attempt.progress.isActivelyMoving else { return }
        guard attempt.progress.rendersDifferently(from: published) else { return }
        attempt.lastPublishedAt = clock.now()
        attempts[guid] = attempt
        states[guid] = .downloading(attempt.progress)
    }

    // MARK: - Stalling

    /// Arms the stall deadline for this attempt, replacing any earlier one.
    ///
    /// Called where the transfer demonstrably moved — it took the slot, or a
    /// byte count strictly increased — so the deadline always measures from the
    /// last thing that actually happened.
    ///
    /// `after` is the full threshold except when `markStalled` re-arms for the
    /// remainder of an interval that had not really elapsed.
    func scheduleStallDeadline(
        forGUID guid: String, after delay: TimeInterval = DownloadPacing.stallThreshold
    ) {
        guard var attempt = attempts[guid] else { return }
        attempt.stallGeneration &+= 1
        let generation = attempt.stallGeneration
        let token = attempt.token
        attempts[guid] = attempt
        stallDeadlines[guid]?.cancel()
        let clock = self.clock
        stallDeadlines[guid] = Task { @MainActor [weak self] in
            do {
                try await clock.sleep(for: delay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.markStalled(forGUID: guid, heldBy: token, generation: generation)
        }
    }

    /// The deadline's body, separated so it is testable without waiting.
    ///
    /// The generation is what makes it safe: a rescheduled deadline shares its
    /// predecessor's token, so token alone would let a task armed thirty seconds
    /// ago mark a transfer that has moved since as stalled.
    ///
    /// A deadline that wakes early *re-arms* rather than returning. The entry is
    /// cleared on the way in and only a strict byte increase arms a new one, so
    /// a bare return would leave a transfer that has genuinely stopped unable to
    /// ever be marked stalled again — the row would go on showing its last byte
    /// count until the resource timeout or the user. The sleep and the reading
    /// are taken across a suspension, so they cannot be assumed to agree.
    func markStalled(forGUID guid: String, heldBy token: UUID, generation: Int) {
        stallDeadlines[guid] = nil
        guard let attempt = attempts[guid], attempt.token == token else { return }
        guard attempt.stallGeneration == generation else { return }
        guard case .downloading(let published)? = states[guid] else { return }
        guard published.phase != .stalled, published.phase != .finalizing else { return }
        let idle = clock.now() - attempt.lastIncreaseAt
        guard idle >= DownloadPacing.stallThreshold else {
            scheduleStallDeadline(forGUID: guid, after: DownloadPacing.stallThreshold - idle)
            return
        }
        // the generation bump lives in `invalidatePendingPublication` and
        // nowhere else, so a lifecycle transition advances it exactly once
        invalidatePendingPublication(forGUID: guid)
        states[guid] = .downloading(
            .stalled(
                bytesWritten: attempt.progress.bytesWritten,
                expectedBytes: attempt.progress.expectedBytes))
    }

    func cancelStallDeadline(forGUID guid: String) {
        stallDeadlines.removeValue(forKey: guid)?.cancel()
    }

    // MARK: - Finalizing

    /// Publishes the window between the last byte and the file landing.
    ///
    /// Called on both routes immediately before `finishDownload` runs. As
    /// ordinary 100 % this window was indistinguishable from success, which is
    /// precisely why a download that failed there could not be described
    /// (decision 10).
    func publishFinalizing(forGUID guid: String, heldBy token: UUID) {
        guard let attempt = attempts[guid], attempt.token == token else { return }
        guard case .downloading? = states[guid] else { return }
        invalidatePendingPublication(forGUID: guid)
        cancelStallDeadline(forGUID: guid)
        states[guid] = .downloading(.finalizing(bytesWritten: attempt.progress.bytesWritten))
    }

    // MARK: - Invalidation

    /// Retires any deferred byte publication and makes a late one unusable.
    ///
    /// The generation bump is what an already-sleeping task cannot escape;
    /// cancelling covers the one that has not woken yet.
    func invalidatePendingPublication(forGUID guid: String) {
        pendingPublications.removeValue(forKey: guid)?.cancel()
        guard var attempt = attempts[guid] else { return }
        attempt.publicationGeneration &+= 1
        attempts[guid] = attempt
    }

    /// Everything time-based this guid owns, dropped at retirement.
    func cancelPacing(forGUID guid: String) {
        pendingPublications.removeValue(forKey: guid)?.cancel()
        cancelStallDeadline(forGUID: guid)
    }
}
