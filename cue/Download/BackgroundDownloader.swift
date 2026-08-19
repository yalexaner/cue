import Foundation
import OSLog

/// The one background `URLSession` the app owns, behind a `FileTransport`.
///
/// Spec §7: episode audio is fetched by a background session on a single shared
/// identifier, so a transfer keeps running while the app is suspended and the
/// system relaunches the app to deliver its completion. A background session's
/// identifier is process-global — two sessions with the same identifier is a
/// programmer error the system diagnoses at runtime — so this type is a
/// singleton, and it is the only one in the app.
///
/// It publishes exactly one thing to `DownloadManager`: a
/// `DownloadManager.FileTransport` closure. Everything else — the configuration,
/// the delegate, the continuations, the completion handler UIKit hands over on
/// relaunch — stays behind that closure, which is what lets every manager test
/// run against a stub and never construct a real session.
///
/// Two routes lead out of the delegate:
///
/// - a transfer this process started is awaited by a continuation, keyed by task
///   identifier, and answered directly;
/// - a transfer that finished while the app was gone has no continuation, so its
///   outcome — success *or* failure — goes to the orphan route with the guid read
///   back out of `taskDescription`. A completion that arrives before anyone
///   registered a handler is held rather than discarded: on a relaunch made to
///   deliver a finished transfer the session is woken from the app delegate,
///   which can happen before any view has run.
///
/// In both cases the temporary file is claimed *inside* the delegate callback,
/// before it returns: the system deletes that file the moment the delegate
/// method ends, so anything that hopes to move it later gets nothing.
final class BackgroundDownloader: NSObject, @unchecked Sendable {
    /// The single shared identifier from spec §7. Never construct a second
    /// session with it.
    static let sessionIdentifier = "dev.yachmenev.cue.downloads"

    static let shared = BackgroundDownloader()

    /// The background session's total-transfer deadline.
    static let resourceTimeout: TimeInterval = 2 * 60 * 60

    /// A finished transfer nobody is awaiting: its outcome and the episode guid
    /// that rode along in `taskDescription`.
    typealias OrphanedCompletion = @Sendable (Result<(URL, URLResponse), Error>, String) -> Void

    /// Registers a task with the manager before the task can emit progress.
    typealias AttemptRegistration = @Sendable (Int, String) async -> Void

    /// One progress event mapped back to its episode identity.
    typealias ProgressHandler = @Sendable (Int, String, DownloadProgress) -> Void

    /// An orphaned outcome that arrived before a handler was registered.
    private struct UnroutedCompletion {
        let result: Result<(URL, URLResponse), Error>
        let guid: String
    }

    /// What a task identifier's slot holds while its transfer is in flight.
    ///
    /// Claimed *before* the task is resumed, because claiming and installing the
    /// continuation are not the same moment: an already cancelled caller runs
    /// `onCancel` — and so the delegate — before the operation body installs
    /// anything, and a completion landing in that window would find an empty
    /// map, take the orphan route, and strand the caller forever.
    private enum TransferSlot {
        /// Claimed; the caller has not installed its continuation yet.
        case claimed
        /// A caller is suspended on this continuation.
        case waiting(CheckedContinuation<(URL, URLResponse), Error>)
        /// The outcome arrived first; the caller takes it as it installs.
        case delivered(Result<(URL, URLResponse), Error>)
    }

    /// Where one delivered outcome goes.
    private enum Delivery {
        case resume(CheckedContinuation<(URL, URLResponse), Error>)
        /// Held in the slot for a caller that is still on its way.
        case held
        case orphaned
    }

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "dev.yachmenev.cue",
        category: "downloads"
    )

    /// Internal only because background-event accounting lives in
    /// `BackgroundDownloaderDelegate.swift`; all access remains lock-scoped.
    let lock = NSLock()
    private var pending: [Int: TransferSlot] = [:]
    private var orphanedCompletion: OrphanedCompletion?
    private var attemptRegistration: AttemptRegistration?
    private var progressHandler: ProgressHandler?
    private var unroutedCompletions: [UnroutedCompletion] = []
    /// Delivered outcomes — awaited *and* orphaned — not yet reported finished.
    /// Internal only because its accounting methods live in
    /// `BackgroundDownloaderDelegate.swift`.
    var deliveredWorkInFlight = 0
    /// Internal only because background-event accounting lives in
    /// `BackgroundDownloaderDelegate.swift`.
    var backgroundEventsCompletions: [@Sendable () -> Void] = []
    /// Internal only because background-event accounting lives in
    /// `BackgroundDownloaderDelegate.swift`.
    var backgroundEventsDelivered = false
    private var storedSession: URLSession?

    /// Created once, on first use, and never torn down. Recreating a session
    /// with the same identifier is how a relaunched app re-attaches to transfers
    /// the system kept running, so `session` is also the reconnection.
    ///
    /// Behind the lock rather than `lazy`: `lazy var` initialisation is not
    /// atomic, and the two launch paths reach it from different executors — the
    /// app delegate on the main thread, the transport off it. Two sessions
    /// sharing one background identifier is the runtime error this type exists
    /// to prevent.
    ///
    /// Internal only because background-event registration lives in
    /// `BackgroundDownloaderDelegate.swift`.
    var session: URLSession {
        lock.withLock { () -> URLSession in
            if let storedSession { return storedSession }
            let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
            // spec §7 downloads are user-initiated: the system must not defer
            // them to a moment it considers convenient
            configuration.isDiscretionary = false
            // the reason the relaunch route exists at all
            configuration.sessionSendsLaunchEvents = true
            // This is a total-transfer deadline and keeps running while the
            // daemon waits for connectivity. Two hours bounds the seven-day
            // default without killing a slow transfer that is still moving;
            // the user-facing stall remedy is the waiting state plus Cancel.
            configuration.timeoutIntervalForResource = Self.resourceTimeout
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            storedSession = session
            return session
        }
    }

    /// Where a completion with no waiting continuation goes.
    ///
    /// Anything that arrived before this call is handed over now: those outcomes
    /// were queued, not dropped, because the alternative is deleting a finished
    /// download the app was relaunched specifically to record.
    func setOrphanedCompletionHandler(_ handler: @escaping OrphanedCompletion) {
        let queued = lock.withLock { () -> [UnroutedCompletion] in
            orphanedCompletion = handler
            let queued = unroutedCompletions
            unroutedCompletions = []
            return queued
        }
        for completion in queued {
            handler(completion.result, completion.guid)
        }
    }

    /// Installs the attempt-registration route used before `task.resume()`.
    func setAttemptRegistrationHandler(_ handler: @escaping AttemptRegistration) {
        lock.withLock { attemptRegistration = handler }
    }

    /// Installs the route for delegate byte callbacks.
    func setProgressHandler(_ handler: @escaping ProgressHandler) {
        lock.withLock { progressHandler = handler }
    }

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
