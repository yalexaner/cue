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

    /// What a given episode's transfer is doing right now. Absent means idle.
    enum DownloadState: Equatable {
        case downloading
        /// The last attempt failed. Cleared by the next attempt, not by time —
        /// the row has to be able to show that trying again is worth a tap.
        case failed
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
    private(set) var states: [String: DownloadState] = [:]

    let context: ModelContext
    let store: EpisodeStore
    private let transport: FileTransport

    /// Spec §7 allows one active transfer; the rest wait their turn in order.
    private var isTransferring = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(
        context: ModelContext, store: EpisodeStore = EpisodeStore(),
        transport: @escaping FileTransport
    ) {
        self.context = context
        self.store = store
        self.transport = transport
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
        guard states[guid] != .downloading else { return }
        let enclosureURL = episode.enclosureURL
        guard let url = Self.downloadURL(for: enclosureURL) else {
            states[guid] = .failed
            throw Failure.invalidEnclosureURL(enclosureURL)
        }

        // before the slot, not after: a queued transfer with no state reads as
        // "not downloaded", so the row keeps offering Download and a second tap
        // fetches the same episode twice
        states[guid] = .downloading
        await acquireSlot()
        defer { releaseSlot() }

        do {
            // never assume launch succeeded: `CueApp.init()` prepares the
            // directory non-fatally, so the writing path prepares it again and
            // surfaces its own error. Before the transport, so a broken
            // container costs no bandwidth
            try store.prepareEpisodesDirectory()

            let (tempURL, response) = try await transport(url)
            if let failure = Self.statusFailure(for: response, enclosureURL: enclosureURL) {
                // the temporary file is ours once the transport answers, and an
                // error page is not an episode
                try? FileManager.default.removeItem(at: tempURL)
                throw failure
            }

            try await finishDownload(tempURL: tempURL, response: response, forGUID: guid)
            states[guid] = nil
        } catch {
            // a cancelled transfer is not a failed one — the user backed out
            states[guid] = isCancellation(error) ? nil : .failed
            throw error
        }
    }

    // MARK: - Deleting

    /// Removes the downloaded file and clears the download columns (spec §7).
    ///
    /// Touches download state only: `isPlayed`, `playedAt` and the session log
    /// are never written here, which is what makes deleting a download safe for
    /// a played episode (AC 9).
    ///
    /// Clear, save, *then* remove. The reverse order can leave a row pointing at
    /// a file that is gone, which is the direction the design forbids; this
    /// order can at worst leave a file no row claims, which the reconciliation
    /// sweep collects.
    func deleteDownload(for episode: Episode) throws {
        guard let filename = episode.localFilename else {
            // nothing recorded — clearing again is not an error. A stray
            // `downloadedAt` is still a write, and one left pending for autosave
            // is a write a context-wide `rollback()` elsewhere can discard
            guard let orphanedDownloadedAt = episode.downloadedAt else { return }
            episode.downloadedAt = nil
            do {
                try context.save()
            } catch {
                episode.downloadedAt = orphanedDownloadedAt
                throw error
            }
            return
        }
        let previousDownloadedAt = episode.downloadedAt

        episode.localFilename = nil
        episode.downloadedAt = nil
        do {
            try context.save()
        } catch {
            episode.localFilename = filename
            episode.downloadedAt = previousDownloadedAt
            throw error
        }

        // only a `.failed` state is this delete's to resolve. A transfer in
        // flight is not: clearing it would drop the duplicate guard in
        // `download(_:)`, so the row reads as idle and a tap starts a second
        // transfer for the same guid. The screens no longer offer a delete
        // mid-transfer, and this is the line that keeps that from mattering
        if states[episode.guid] == .failed {
            states[episode.guid] = nil
        }
        try store.removeFile(forRelativeFilename: filename)
    }

    // MARK: - Helpers

    /// Waits until this call owns the single transfer slot.
    ///
    /// FIFO: a caller that finds the slot busy parks its continuation at the
    /// back of `waiting`, and `releaseSlot()` hands the slot to the front. All
    /// of it is main-actor state, so there is no lock to get wrong.
    private func acquireSlot() async {
        guard isTransferring else {
            isTransferring = true
            return
        }
        await withCheckedContinuation { continuation in
            waiting.append(continuation)
        }
    }

    private func releaseSlot() {
        if waiting.isEmpty {
            isTransferring = false
        } else {
            waiting.removeFirst().resume()
        }
    }
}
