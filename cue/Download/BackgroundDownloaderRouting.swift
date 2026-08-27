import Foundation
import OSLog

/// The transfer and routing half of `BackgroundDownloader`.
///
/// Split out of `BackgroundDownloader.swift`, which sat at 396 lines against the
/// 400-line `file_length` warning `--strict` turns into an error: the type half
/// keeps the singleton, the session configuration and the handler registrations,
/// this half owns starting a transfer, awaiting it, delivering its outcome and
/// reporting its progress. Nothing changed but access control — the state and
/// nested types this extension reads (`pending`, `orphanedCompletion`,
/// `attemptRegistration`, `progressHandler`, `unroutedCompletions`,
/// `UnroutedCompletion`, `TransferSlot`, `Delivery` and `logger`) were `private`
/// and are now `internal`, because a `private` member is unreachable from an
/// extension in another file.
extension BackgroundDownloader {
    /// The seam `DownloadManager` is constructed with in production.
    ///
    /// The guid is not a parameter of `FileTransport` — the transport answers a
    /// file, it does not know about episodes — so it is read from the task-local
    /// the manager sets around the call. A transfer started without one still
    /// runs; it just cannot be resolved after a relaunch.
    var transport: DownloadManager.FileTransport {
        { [self] url in
            try await download(from: url, guid: DownloadTaskIdentity.currentGUID)
        }
    }

    /// The guid-addressable cancellation seam injected into the manager.
    var cancellationRequest: DownloadManager.CancellationRequest {
        { [self] guid, taskIdentifier in
            await cancelTransfer(forGUID: guid, taskIdentifier: taskIdentifier)
        }
    }

    /// Wakes the session and reports which episodes it is already transferring.
    ///
    /// Called at launch: a download interrupted by termination is recovered from
    /// the session, never from the store (there is no column for it), so the
    /// manager repopulates its state map from what the system says is in flight.
    func adoptInFlightTasks() async -> [DownloadAttemptIdentity] {
        await session.allTasks.compactMap { task in
            guard let guid = DownloadTaskIdentity.guid(fromTaskDescription: task.taskDescription) else { return nil }
            return DownloadAttemptIdentity(taskIdentifier: task.taskIdentifier, guid: guid)
        }
    }

    /// Requests cancellation of the session task the cancelled attempt owns.
    ///
    /// `allTasks` is a snapshot, so this is deliberately best-effort in the
    /// direction of missing a task: the manager's attempt-scoped checkpoints
    /// close those windows. It must never be best-effort in the other
    /// direction. Enumerating suspends, and the attempt being cancelled can
    /// retire and be replaced by a retry for the same guid before the snapshot
    /// arrives — the retry's task carries the same guid in its description, so
    /// guid matching alone would cancel the transfer the user just started.
    /// `taskIdentifier` narrows the match to the attempt that asked. There is
    /// no guid-wide form: an attempt with no registered task is cancelled when
    /// its registration supplies one, before that task is resumed.
    ///
    /// Task cancellation itself produces no outcome here; the delegate remains
    /// the only route that delivers the terminal failure.
    private func cancelTransfer(forGUID guid: String, taskIdentifier: Int) async {
        let tasks = await session.allTasks
        let identities = tasks.compactMap { task -> DownloadAttemptIdentity? in
            guard let taskGUID = DownloadTaskIdentity.guid(fromTaskDescription: task.taskDescription)
            else { return nil }
            return DownloadAttemptIdentity(taskIdentifier: task.taskIdentifier, guid: taskGUID)
        }
        let identifiers = Set(
            Self.taskIdentifiers(forGUID: guid, taskIdentifier: taskIdentifier, among: identities))
        for task in tasks where identifiers.contains(task.taskIdentifier) {
            task.cancel()
        }
    }

    /// The value-returning core of attempt matching, testable without a session.
    ///
    /// The guid still has to match when an identifier is given: identifiers are
    /// only unique within one session, and the caller's is read from an attempt
    /// record that may have been retired since.
    static func taskIdentifiers(
        forGUID guid: String, taskIdentifier: Int, among identities: [DownloadAttemptIdentity]
    ) -> [Int] {
        identities
            .filter { $0.guid == guid && $0.taskIdentifier == taskIdentifier }
            .map(\.taskIdentifier)
    }

    // MARK: - Transfers

    private func download(from url: URL, guid: String?) async throws -> (URL, URLResponse) {
        let task = session.downloadTask(with: url)
        task.taskDescription = guid.map(DownloadTaskIdentity.taskDescription(forGUID:))
        let taskIdentifier = task.taskIdentifier

        claimTransfer(taskIdentifier: taskIdentifier)
        if let guid { await registerStart(taskIdentifier: taskIdentifier, guid: guid) }
        return try await awaitTransfer(
            taskIdentifier: taskIdentifier, onStart: { task.resume() }, onCancel: { task.cancel() })
    }

    /// Registers a task before the caller is allowed to resume it.
    ///
    /// Internal so the registration-before-progress ordering can be exercised
    /// without constructing a background session.
    func registerStart(taskIdentifier: Int, guid: String) async {
        guard let registration = lock.withLock({ attemptRegistration }) else { return }
        // `download(from:guid:)` awaits this before `awaitTransfer` reaches its
        // `onStart`, so the attempt exists before the first byte callback
        await registration(taskIdentifier, guid)
    }

    /// Reserves the slot a completion for this task identifier is routed to.
    ///
    /// Internal, and separate from `awaitTransfer`, so the ordering the two of
    /// them keep is testable without constructing a background session.
    func claimTransfer(taskIdentifier: Int) {
        lock.withLock { pending[taskIdentifier] = .claimed }
    }

    /// Suspends until the claimed transfer answers, starting it on the way in.
    ///
    /// `onStart` runs only when the outcome is not already here — a task that
    /// has answered must not be resumed. `withTaskCancellationHandler` stays: it
    /// is what turns the caller's cancellation into the session's.
    func awaitTransfer(
        taskIdentifier: Int, onStart: @escaping @Sendable () -> Void, onCancel: @escaping @Sendable () -> Void
    ) async throws -> (URL, URLResponse) {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let delivered = lock.withLock { () -> Result<(URL, URLResponse), Error>? in
                    if case .delivered(let result) = pending[taskIdentifier] {
                        pending[taskIdentifier] = nil
                        return result
                    }
                    pending[taskIdentifier] = .waiting(continuation)
                    return nil
                }
                guard let delivered else {
                    onStart()
                    return
                }
                continuation.resume(with: delivered)
            }
        } onCancel: {
            onCancel()
        }
    }

    /// Hands a finished transfer to whoever is waiting, or to the orphan route.
    ///
    /// Internal only because the session delegate lives in
    /// `BackgroundDownloaderDelegate.swift`.
    func deliver(_ result: Result<(URL, URLResponse), Error>, for task: URLSessionTask) {
        deliver(result, forTaskIdentifier: task.taskIdentifier, taskDescription: task.taskDescription)
    }

    /// The core of `deliver(_:for:)`, minus the session task, so both routes can
    /// be exercised without a background session.
    func deliver(
        _ result: Result<(URL, URLResponse), Error>, forTaskIdentifier taskIdentifier: Int,
        taskDescription: String?
    ) {
        let delivery = lock.withLock { () -> Delivery in
            switch pending[taskIdentifier] {
            case .waiting(let continuation):
                pending[taskIdentifier] = nil
                // a live continuation means the app was suspended rather than
                // terminated, not that the work is done: the awaiting side still
                // has to move the file and record it, and the UIKit handler must
                // not be answered before it has
                deliveredWorkInFlight += 1
                return .resume(continuation)
            case .claimed:
                // the caller is on its way to installing its continuation and
                // will take this the moment it gets there; the same accounting
                // applies, because the same work follows
                pending[taskIdentifier] = .delivered(result)
                deliveredWorkInFlight += 1
                return .held
            case .delivered, .none:
                return .orphaned
            }
        }
        if case .resume(let continuation) = delivery {
            continuation.resume(with: result)
            return
        }
        // a held outcome has a caller coming for it; only a true orphan goes on
        guard case .orphaned = delivery else { return }
        // no one is awaiting: either the app was relaunched to receive this, or
        // the awaiting task was already answered. Both outcomes still have to be
        // routed — a failure nobody hears about leaves its row transferring
        // forever — and both need to say which episode they are for
        guard let guid = DownloadTaskIdentity.guid(fromTaskDescription: taskDescription) else {
            Self.logger.notice("background transfer finished with nothing to route it to; discarding")
            if case .success(let (fileURL, _)) = result {
                try? FileManager.default.removeItem(at: fileURL)
            }
            return
        }
        route(result, forGUID: guid)
    }

    /// Sends an orphaned outcome to the registered handler, or holds it for the
    /// handler that has not been registered yet.
    ///
    /// Internal so the queueing can be tested without a background session; the
    /// delegate is its only production caller.
    func route(_ result: Result<(URL, URLResponse), Error>, forGUID guid: String) {
        let handler = lock.withLock { () -> OrphanedCompletion? in
            deliveredWorkInFlight += 1
            guard let orphanedCompletion else {
                unroutedCompletions.append(UnroutedCompletion(result: result, guid: guid))
                return nil
            }
            return orphanedCompletion
        }
        handler?(result, guid)
    }

    /// Maps and reports a delegate byte callback without exposing a session
    /// task, so progress delivery is testable without constructing a session.
    func reportProgress(
        taskIdentifier: Int, taskDescription: String?, bytesWritten: Int64,
        expectedBytes: Int64
    ) {
        guard let guid = DownloadTaskIdentity.guid(fromTaskDescription: taskDescription) else { return }
        guard let progress = DownloadProgress.reported(bytesWritten: bytesWritten, expectedBytes: expectedBytes)
        else { return }
        lock.withLock { progressHandler }?(taskIdentifier, guid, progress)
    }

    /// Moves the system's temporary file somewhere it will still exist after
    /// this delegate callback returns.
    ///
    /// Internal only because the session delegate lives in
    /// `BackgroundDownloaderDelegate.swift`.
    static func claim(_ location: URL) throws -> URL {
        let claimed = FileManager.default.temporaryDirectory.appending(
            path: "download-\(UUID().uuidString).tmp", directoryHint: .notDirectory)
        try FileManager.default.moveItem(at: location, to: claimed)
        return claimed
    }
}
