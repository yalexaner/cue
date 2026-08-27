import Foundation
import SwiftData

/// Removing a downloaded file and the columns that claim it.
///
/// Its own file for the reason `DownloadFinish.swift` and `DownloadOwnership.swift`
/// are: `DownloadManager.swift` sits at the 400-line `file_length` warning that
/// `--strict` turns into an error, and deletion is a cohesive topic to lift out.
/// It needs nothing that was not already internal for those splits — `context`,
/// `store` and `states`.
extension DownloadManager {
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
        let previousState = states[episode.guid]
        if previousState?.isFailed == true {
            states[episode.guid] = nil
        }

        do {
            try store.removeFile(forRelativeFilename: filename)
        } catch {
            // the file is still there — `removeFile` swallows only a confirmed
            // not-found — so the row must go on claiming it. Left cleared, the
            // Downloads filter drops the episode and no screen can offer the
            // delete again, which strands the file for good. The restoring save
            // may itself fail; that error is discarded rather than reported,
            // because the removal failure is the one the user has to see
            episode.localFilename = filename
            episode.downloadedAt = previousDownloadedAt
            states[episode.guid] = previousState
            try? context.save()
            throw error
        }
    }
}
