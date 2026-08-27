import AVFoundation
import Foundation
import OSLog
import Observation
import SwiftData

/// Downloads episode audio into `Episodes/` and owns the state of doing so (spec §7).
///
/// A long-lived `@MainActor @Observable` class, created once by `CueApp` and
/// injected through the environment. That is a deliberate deviation from the
/// cheap-struct service convention `FeedService` and `EpisodeStore` follow: a
/// background `URLSession` has one shared identifier, its delegate outlives any
/// call site, and iOS may relaunch the app to deliver a completion for a
/// transfer no live view started. Per-transfer state therefore needs a lifetime
/// longer than a call, which a struct constructed at the call site cannot give.
///
/// The seam stays the same shape as `FeedService.Transport`, only file-based:
/// `FileTransport` takes a URL and answers a temporary file URL plus a response,
/// so no test constructs a real background session and the session
/// configuration lives entirely behind the closure.
///
/// Progress and failure live in memory only (`states`). No SwiftData column
/// records them: the spec's schema has none, and a new column would be one more
/// field the `#Unique` upsert can clear on refresh. A transfer interrupted by
/// termination is recovered from the session, never from the store.
@MainActor
@Observable
final class DownloadManager {
    /// One download. A URL in, a temporary file URL plus its response out.
    ///
    /// Deliberately not `FeedService.Transport`: buffering an episode into
    /// `Data` would hold a whole audio file in memory and give up background
    /// delivery. What carries over from the feed side is the injection, not the
    /// signature.
    typealias FileTransport = @Sendable (URL) async throws -> (URL, URLResponse)

    /// Reports that the work following one delivered transfer has finished.
    ///
    /// The session may not answer UIKit's completion handler while a delivered
    /// outcome is still being finished — the app can be suspended mid-move.
    /// Injected beside the transport, so a stub is paired with a no-op rather
    /// than with accounting nothing ever incremented.
    typealias DeliveryBarrier = @Sendable () -> Void

    /// Requests cancellation of the background task a live attempt stands for.
    ///
    /// Injected beside `FileTransport` because an adopted transfer has no
    /// in-process `Task` for the manager to cancel. The production seam
    /// enumerates the background session; tests never construct one.
    ///
    /// Names the task, never only the guid. Enumerating the session suspends,
    /// and by the time it answers this attempt may have retired and a retry may
    /// hold the guid — matching on the guid alone would then cancel the
    /// retry's task. The identifier is what makes the request attempt-scoped
    /// rather than guid-scoped, exactly as the cancellation flag on the attempt
    /// record already is. A guid-wide request is therefore not expressible:
    /// an attempt with no task yet is cancelled by `registerStartedAttempt`
    /// when one appears, not by a wildcard the snapshot resolves too late.
    typealias CancellationRequest = @Sendable (String, Int) async -> Void

    /// What a given episode's transfer is doing right now. Absent means idle.
    enum DownloadState: Equatable {
        case downloading(DownloadProgress)
        /// The last attempt failed. Cleared by the next attempt, not by time —
        /// the row has to be able to show that trying again is worth a tap.
        case failed(message: String)

        var isDownloading: Bool {
            if case .downloading = self { return true }
            return false
        }

        var isFailed: Bool {
            if case .failed = self { return true }
            return false
        }
    }

    /// The ways a download fails before the file is ever moved.
    ///
    /// Each case carries the offending value, matching `FeedService.Failure` and
    /// `EpisodeStore.Failure`, so the alert can name what broke. Transport
    /// errors and `EpisodeStore.Failure` propagate unchanged — wrapping them
    /// would hide the cause.
    enum Failure: Error, Equatable {
        /// `enclosureURL` is not a URL, or its scheme is not `http`/`https`.
        case invalidEnclosureURL(String)
        /// The server answered non-2xx. Carries the status and the enclosure
        /// URL, so a token-rotated feed's 403 is diagnosable (spec §6).
        case httpStatus(Int, String)
    }

    /// Internal rather than private, like `context` and `store` below: the
    /// shared finish path lives in `DownloadFinish.swift` and needs all three.
    static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "dev.yachmenev.cue",
        category: "downloads"
    )

    /// Per-guid transfer state, keyed by `Episode.guid` rather than by the model.
    ///
    /// A guid because the app that receives a background completion may not be
    /// the app that started the transfer, so the only durable handle on an
    /// episode is the value the store is unique on.
    ///
    /// The setter is internal only because the relaunch route lives in
    /// `DownloadRelaunch.swift`.
    var states: [String: DownloadState] = [:]

    /// Guids this process has already resolved through the relaunch route, so a
    /// late `adopt` cannot mark a finished transfer as still in flight.
    /// Internal only because the relaunch route lives in
    /// `DownloadRelaunch.swift`.
    var resolvedGUIDs: Set<String> = []

    /// The one live attempt per guid. Internal because its lifecycle is split
    /// across `DownloadOwnership.swift`, `DownloadAttempts.swift` and the
    /// relaunch route. In memory only, like `states`.
    var attempts: [String: DownloadAttempt] = [:]

    let context: ModelContext
    let store: EpisodeStore
    /// Test-only stand-in for the store fetch in `episode(forGUID:)`: a
    /// `ModelContext` cannot be made to throw on demand, and the relaunch
    /// route's failed-lookup branch has to be exercised. `nil` in production,
    /// and injected like every other seam rather than left settable, so no
    /// holder of the shared manager can redirect episode resolution mid-transfer.
    let episodeLookup: ((String) throws -> Episode?)?
    private let transport: FileTransport
    private let deliveryBarrier: DeliveryBarrier
    private let cancellationRequest: CancellationRequest

    /// The transfer slot and its queued waiters. Internal only because the
    /// queue itself lives in `DownloadQueue.swift`.
    var isTransferring = false
    var waiting: [TransferWaiter] = []

    init(
        context: ModelContext, store: EpisodeStore = EpisodeStore(),
        transport: @escaping FileTransport, deliveryBarrier: @escaping DeliveryBarrier = {},
        cancellationRequest: @escaping CancellationRequest = { _, _ in },
        episodeLookup: ((String) throws -> Episode?)? = nil
    ) {
        self.context = context
        self.store = store
        self.episodeLookup = episodeLookup
        self.transport = transport
        self.deliveryBarrier = deliveryBarrier
        self.cancellationRequest = cancellationRequest
    }

    /// The state of this episode's transfer, or `nil` when it is not in flight.
    func state(for episode: Episode) -> DownloadState? {
        states[episode.guid]
    }

    // MARK: - Downloading

    /// Downloads `episode`'s enclosure and records it, one transfer at a time.
    ///
    /// Calls made while another transfer is running queue in arrival order
    /// rather than running concurrently (spec §7). Nothing is written to the
    /// store until the file is safely inside `Episodes/`.
    func download(_ episode: Episode) async throws {
        let guid = episode.guid
        // one transfer per episode, decided here rather than only by the row:
        // the state below is set before the slot so the row stops offering
        // Download, but a second tap can land before the row re-renders, and
        // two transfers for one guid race — the first to finish clears the
        // shared state and exposes Delete while the second is still running, so
        // a deletion can land between the second one's move and its write. All
        // of this is main-actor state, so the test and the set below cannot be
        // interleaved. A duplicate request is a no-op, not an error: the
        // transfer the user asked for is already running
        guard states[guid]?.isDownloading != true else { return }
        let enclosureURL = episode.enclosureURL
        guard let url = Self.downloadURL(for: enclosureURL) else {
            let failure = Failure.invalidEnclosureURL(enclosureURL)
            states[guid] = failureState(for: failure)
            throw failure
        }

        // the token is taken before anything is written, so a completion routed
        // from the session while this transfer runs cannot write over it
        guard let token = claimOwnership(of: guid) else { return }

        // before the slot, not after: a queued transfer with no state reads as
        // "not downloaded", so the row keeps offering Download and a second tap
        // fetches the same episode twice
        states[guid] = .downloading(.waiting)

        do {
            try await acquireSlot(forGUID: guid)
            defer { releaseSlot() }

            // The task may have been cancelled before it acquired the slot.
            try Task.checkCancellation()

            // never assume launch succeeded: `CueApp.init()` prepares the
            // directory non-fatally, so the writing path prepares it again and
            // surfaces its own error. Before the transport, so a broken
            // container costs no bandwidth
            try store.prepareEpisodesDirectory()

            // the guid rides with the request so the production transport can
            // stamp it on the task; a stub simply ignores it
            try checkCancellation(of: guid, heldBy: token)
            let delivered: Result<(URL, URLResponse), Error>
            do {
                delivered = .success(
                    try await DownloadTaskIdentity.$currentGUID.withValue(guid) { try await transport(url) })
            } catch {
                delivered = .failure(error)
            }
            // the session has handed this outcome over — success or failure — so
            // everything below is work the background-events handler waits for
            defer { deliveryBarrier() }

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
            // only while this transfer is still the guid's owner: a completion
            // routed from the session may have taken it over
            if releaseOwnership(of: guid, heldBy: token) { states[guid] = nil }
        } catch {
            // a cancelled transfer is not a failed one — the user backed out
            if releaseOwnership(of: guid, heldBy: token) {
                states[guid] = failureState(for: error)
            }
            throw error
        }
    }

    /// Cancels the live attempt for `episode`, whether queued, active or adopted.
    ///
    /// A queued attempt has no session task, so its throwing continuation is
    /// resumed here. An active or adopted attempt stays `.downloading` until the
    /// delegate delivers its sole terminal outcome; requesting cancellation is
    /// not a second outcome producer.
    func cancel(_ episode: Episode) async {
        let guid = episode.guid
        guard var attempt = attempts[guid] else { return }
        attempt.isCancellationRequested = true
        attempts[guid] = attempt

        if cancelWaiter({ $0.guid == guid }) {
            if releaseOwnership(of: guid, heldBy: attempt.token) { states[guid] = nil }
            return
        }
        // only a task this attempt owns may be named. An attempt whose session
        // task has not registered yet has nothing to enumerate — the request
        // is re-issued from `registerStartedAttempt` the moment it does, which
        // is still before that task is resumed
        guard let taskIdentifier = attempt.taskIdentifier else { return }
        await cancellationRequest(guid, taskIdentifier)
    }

    /// Registers a started attempt's session task before it is resumed, and
    /// carries over a cancellation that arrived before the task existed.
    ///
    /// The registration hop is asynchronous — the task is created off the main
    /// actor and this record is written on it — so a `cancel(_:)` landing in
    /// that window sees no identifier to name and requests nothing. This is
    /// where that request is made instead, with the identifier now known, so
    /// the transfer stops at the session rather than running to completion and
    /// being discarded at the next checkpoint.
    func registerStartedAttempt(taskIdentifier: Int, forGUID guid: String) async {
        registerAttempt(taskIdentifier: taskIdentifier, forGUID: guid)
        guard let attempt = attempts[guid], attempt.taskIdentifier == taskIdentifier,
            attempt.isCancellationRequested
        else { return }
        await cancellationRequest(guid, taskIdentifier)
    }

    // MARK: - Background session

    /// Re-attaches to the background session at launch (spec §7).
    ///
    /// Two things a fresh process cannot know on its own: which transfers the
    /// system kept running while the app was gone, and what to do with one that
    /// finished in the meantime. Both come from the session — never from the
    /// store, which has no column for either — so this asks it for both.
    ///
    /// Idempotent: registering the handler again replaces it, and adopting a
    /// transfer already marked `.downloading` writes the same value.
    func connect(to downloader: BackgroundDownloader) async {
        registerCompletionRoute(with: downloader)
        adopt(inFlightAttempts: await downloader.adoptInFlightTasks())
    }

    // MARK: - Helpers

    /// The one conversion every terminal failure route uses.
    ///
    /// `downloadErrorMessage(for:)` owns both cancellation classification and
    /// enclosure-URL redaction, so the live, preflight and relaunch routes
    /// cannot drift into different row messages. Cancellation maps to no state.
    func failureState(for error: Error) -> DownloadState? {
        guard let message = downloadErrorMessage(for: error) else { return nil }
        return .failed(message: message)
    }

}
