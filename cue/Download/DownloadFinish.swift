import Foundation
import SwiftData

/// The one finish path both download routes share: temporary file in, a file
/// inside `Episodes/` and a recorded episode out.
///
/// Its own file for the reason `DownloadPolicy.swift` is: `DownloadManager.swift`
/// sits at the 400-line `file_length` warning that `--strict` turns into an
/// error, and the finish path is the cohesive topic to lift out — the transport
/// route and the relaunch route both end here, and `DownloadManagerRelaunchTests`
/// already exercises it as a seam of its own. That split is why `context`,
/// `store` and `logger` are internal on the manager rather than private.
extension DownloadManager {
    /// Moves a finished transfer into `Episodes/` and records it on the episode.
    ///
    /// The transport route calls it with the continuation's answer; the relaunch
    /// route calls it from the session delegate, where no continuation exists
    /// and the episode is known only by the guid carried in `taskDescription`.
    ///
    /// Ordering is the whole point: the file is moved *first*, and
    /// `localFilename`/`downloadedAt` are written only after the move succeeded,
    /// so the store can never claim a file that is not there. A rejected save
    /// puts the pair back for the same reason.
    ///
    /// An unknown guid is ignored rather than fatal: the episode may have been
    /// deleted while the transfer was in flight, and a background completion
    /// must not crash the app it relaunched.
    func finishDownload(
        tempURL: URL, response: URLResponse?, forGUID guid: String,
        heldBy token: UUID
    ) async throws {
        guard let episode = try episodeToRecord(forGUID: guid, heldBy: token, tempURL: tempURL) else {
            return
        }
        if let response, let failure = Self.statusFailure(for: response, enclosureURL: episode.enclosureURL) {
            try? FileManager.default.removeItem(at: tempURL)
            throw failure
        }

        let previousFilename = episode.localFilename
        let previousDownloadedAt = episode.downloadedAt
        let previousAssetDuration = episode.assetDuration
        let filename = store.downloadFilename(forEnclosureURL: episode.enclosureURL)

        do {
            // inside the `do`, before the move: a cancel landing while the
            // transport was answering must leave the disk and the store alone,
            // and throwing from above would skip the restore below
            try Task.checkCancellation()
            try checkCancellation(of: guid, heldBy: token)
            try store.prepareEpisodesDirectory()
            let destination = try store.moveFile(at: tempURL, toRelativeFilename: filename)
            let attempt = DiagnosticsAttemptID(token: token)
            record(.downloadFileMoved(guid: DiagnosticsGUID(guid), attempt: attempt))

            // the measured duration is authoritative but optional: a file the
            // asset reader cannot make sense of leaves `assetDuration` alone,
            // so `duration` falls back to the feed's value and the download
            // still counts as done. Read after the move, from the final URL,
            // and *before* the model is touched — this suspends, and the main
            // context autosaves, so a save from anywhere else landing between
            // the writes below and ours would commit a download this `catch`
            // still has to be able to take back
            let measured = await Self.assetDuration(at: destination)
            // and again, because that read suspends: the check before the move
            // cannot speak for a cancel landing during it, and `assetDuration`
            // answers `nil` for cancellation exactly as it does for an
            // unreadable file, so nothing else here would notice. Inside the
            // `do`, so the restore below takes the moved file back with the
            // fields
            try Task.checkCancellation()
            try checkCancellation(of: guid, heldBy: token)

            episode.localFilename = filename
            episode.downloadedAt = .now
            if let measured {
                episode.assetDuration = measured
            }
            try context.save()
            record(.downloadFinished(guid: DiagnosticsGUID(guid), attempt: attempt))
        } catch {
            // the model must not disagree with the disk: put the fields back,
            // and take the file we just placed with them — its name is a fresh
            // UUID, so nothing else can be pointing at it. The claimed
            // temporary file goes too when the throw came before the move
            // consumed it; a full episode left in `tmp` is referenced by nothing
            episode.localFilename = previousFilename
            episode.downloadedAt = previousDownloadedAt
            episode.assetDuration = previousAssetDuration
            try? FileManager.default.removeItem(at: tempURL)
            try? store.removeFile(forRelativeFilename: filename)
            throw error
        }

        // a re-download supersedes the previous file; removing it here rather
        // than before the save means a failed save cannot orphan the old one
        if let previousFilename, previousFilename != filename {
            try? store.removeFile(forRelativeFilename: previousFilename)
        }
    }

    /// The episode this outcome belongs to, or `nil` when there is none.
    ///
    /// Owns the two exits that happen before anything is written, because both
    /// have to let go of the delivered file: the claimed temporary file is ours
    /// from the moment the transport answers, and neither the caller's `catch`
    /// nor its epilogue would deal with it — a whole episode referenced by
    /// nothing would sit in `tmp` until the system purged it.
    ///
    /// The `nil` exit additionally records the discard. It returns *normally*,
    /// so the caller's epilogue takes the same path a success does and writes no
    /// terminal record on its behalf: the log would show the request, its first
    /// byte and its deciles, and then stop, which is exactly the silence the
    /// file exists to remove.
    private func episodeToRecord(
        forGUID guid: String, heldBy token: UUID, tempURL: URL
    ) throws -> Episode? {
        let found: Episode?
        do {
            found = try episode(forGUID: guid)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }
        guard let found else {
            Self.logger.notice("finished download for an unknown guid; discarding the file")
            try? FileManager.default.removeItem(at: tempURL)
            record(
                .downloadDiscarded(
                    guid: DiagnosticsGUID(guid), attempt: DiagnosticsAttemptID(token: token),
                    reason: .episodeMissing))
            return nil
        }
        return found
    }

    /// The episode with this guid — the store's uniqueness scope.
    ///
    /// Propagates rather than answering `nil` on a store-level failure: "cannot
    /// tell" read as "no such episode" would discard a finished download.
    func episode(forGUID guid: String) throws -> Episode? {
        if let episodeLookup { return try episodeLookup(guid) }
        var descriptor = FetchDescriptor<Episode>(predicate: #Predicate { $0.guid == guid })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }
}
