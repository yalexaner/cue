import Foundation

/// A background task and the episode identity stamped into its description.
struct DownloadAttemptIdentity: Equatable, Sendable {
    let taskIdentifier: Int
    let guid: String
}

/// One live transfer's identity and observable state.
///
/// The ownership token, background task identifier, cancellation intent and
/// progress belong to the same attempt. Keeping them together prevents a late
/// event from an old task from nominating itself as the current transfer.
struct DownloadAttempt: Equatable {
    enum Origin: Equatable {
        case started
        case adopted
    }

    let token: UUID
    let origin: Origin
    var taskIdentifier: Int?
    var isCancellationRequested = false
    /// Set while the relaunch route is finishing this attempt.
    ///
    /// An adopted attempt yields its token to that route, so the transfer it
    /// stands for can be recorded — and the token is what authorises a write
    /// (`checkCancellation(of:heldBy:)`). Without this flag a second outcome for
    /// the same guid, arriving while the first suspends on the asset read, is
    /// handed the *same* token and both finishes move a file and write
    /// `localFilename`: the one-writer-per-guid hazard `DownloadOwnership.swift`
    /// describes. The yield is single-use.
    var isFinishing = false
    var progress = DownloadProgress.connecting
    /// Monotonic time of the last *strict* byte increase.
    ///
    /// Strict on purpose: `handleProgress` accepts a report whose byte count
    /// merely equals the one before it — a corrected total arrives that way —
    /// and refreshing this on every accepted report would let a transfer that
    /// has stopped moving postpone stalling forever.
    var lastIncreaseAt: TimeInterval = 0
    /// Bumped every time a stall deadline is armed.
    ///
    /// The token alone cannot guard the deadline: a rescheduled deadline shares
    /// its predecessor's token, so a stale task would mark fresh progress
    /// stalled.
    var stallGeneration = 0
    /// Bumped by *every* lifecycle transition, so a trailing publication that
    /// has already passed its sleep cannot overwrite the phase that replaced it.
    var publicationGeneration = 0
    /// Monotonic time of the last throttled publication, `nil` before the first.
    var lastPublishedAt: TimeInterval?
    /// The readings behind the published rate.
    var rateWindow = TransferRateWindow()
    /// Diagnostics bookkeeping, per attempt so retirement drops it.
    var hasLoggedFirstByte = false
    var loggedDecile: Int?
}

extension DownloadManager {
    /// Throws when this exact attempt has been cancelled or displaced.
    ///
    /// The token matters as much as the guid: a delayed checkpoint from an old
    /// attempt must not inspect or alter the retry that replaced it.
    func checkCancellation(of guid: String, heldBy token: UUID) throws {
        guard let attempt = attempts[guid], attempt.token == token else { throw CancellationError() }
        if attempt.isCancellationRequested { throw CancellationError() }
    }

    /// Registers the background task before it is resumed.
    ///
    /// The ownership record is created by `download(_:)` before it can queue.
    /// A registration with no such record is stale and cannot create a live
    /// attempt merely by reporting itself, and an adopted attempt keeps the
    /// identifier it was adopted with.
    ///
    /// The production route in is `registerStartedAttempt`, which also carries
    /// over a cancellation that arrived before this task existed; this is the
    /// bare record write.
    func registerAttempt(taskIdentifier: Int, forGUID guid: String) {
        guard var attempt = attempts[guid], attempt.origin == .started else { return }
        attempt.taskIdentifier = taskIdentifier
        attempts[guid] = attempt
        resolvedGUIDs.remove(guid)
    }

    /// Applies progress only to the registered task that still owns the guid.
    ///
    /// The attempt records every accepted report, because the byte count is what
    /// orders delayed main-actor hops. Publication is separate and throttled —
    /// see `publishProgress(_:forGUID:replacing:at:)`.
    func handleProgress(taskIdentifier: Int, guid: String, progress: DownloadProgress) {
        guard var attempt = attempts[guid], attempt.taskIdentifier == taskIdentifier else { return }
        guard case .downloading(let published)? = states[guid] else { return }
        // the move is over: a byte report arriving behind the finalizing
        // transition must not reopen a transfer whose file is already being
        // placed
        guard published.phase != .finalizing else { return }
        guard progress.bytesWritten >= attempt.progress.bytesWritten else { return }

        let now = clock.now()
        let isStrictIncrease = progress.bytesWritten > attempt.progress.bytesWritten
        if isStrictIncrease { attempt.lastIncreaseAt = now }
        let rate = attempt.rateWindow.record(bytes: progress.bytesWritten, at: now)
        let measured = progress.withRate(rate)
        attempt.progress = measured
        // Deliberately scoped to exactly the reports accepted above, for
        // exactly this registered live attempt — not to "every byte". Progress
        // arrives on separate unstructured main-actor tasks, so a report can
        // land after the attempt retires and be rejected here; one arriving
        // before the handler is installed is discarded by the downloader, and
        // one arriving before `adopt` creates the attempt is rejected by the
        // guard above. On the relaunch path an adopted transfer's early
        // progress is therefore not logged at all. These are accepted gaps:
        // buffering around them would add a second delivery queue. Terminal
        // records are not best-effort; these are.
        //
        // Both identities are built inside the branches that log rather than
        // once above them: a guid is hashed with SHA-256 and an attempt id
        // rewrites a UUID, and this runs on the main actor for every accepted
        // callback while the records fire at most eleven times per attempt.
        if !attempt.hasLoggedFirstByte, measured.bytesWritten > 0 {
            attempt.hasLoggedFirstByte = true
            record(
                .downloadFirstByte(
                    guid: DiagnosticsGUID(guid), attempt: DiagnosticsAttemptID(token: attempt.token),
                    bytes: measured.bytesWritten))
        }
        if let decile = crossedDecile(for: measured, lastLogged: attempt.loggedDecile) {
            attempt.loggedDecile = decile
            record(
                .downloadDecile(
                    guid: DiagnosticsGUID(guid), attempt: DiagnosticsAttemptID(token: attempt.token),
                    decile: decile, bytes: measured.bytesWritten))
        }
        attempts[guid] = attempt
        // only a strict increase re-arms the deadline, for the same reason only
        // a strict increase moves `lastIncreaseAt`
        if isStrictIncrease { scheduleStallDeadline(forGUID: guid) }
        publishProgress(
            measured, forGUID: guid, replacing: published, at: now, movedForward: isStrictIncrease)
    }
}
