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
    struct UnroutedCompletion {
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
    enum TransferSlot {
        /// Claimed; the caller has not installed its continuation yet.
        case claimed
        /// A caller is suspended on this continuation.
        case waiting(CheckedContinuation<(URL, URLResponse), Error>)
        /// The outcome arrived first; the caller takes it as it installs.
        case delivered(Result<(URL, URLResponse), Error>)
    }

    /// Where one delivered outcome goes.
    enum Delivery {
        case resume(CheckedContinuation<(URL, URLResponse), Error>)
        /// Held in the slot for a caller that is still on its way.
        case held
        case orphaned
    }

    static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "dev.yachmenev.cue",
        category: "downloads"
    )

    /// Internal only because background-event accounting lives in
    /// `BackgroundDownloaderDelegate.swift`; all access remains lock-scoped.
    let lock = NSLock()
    var pending: [Int: TransferSlot] = [:]
    var orphanedCompletion: OrphanedCompletion?
    var attemptRegistration: AttemptRegistration?
    var progressHandler: ProgressHandler?
    var unroutedCompletions: [UnroutedCompletion] = []
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
}
