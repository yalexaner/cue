import Foundation

/// Who is allowed to write a given guid's transfer state: one writer per guid.
///
/// Its own file for the reason `DownloadFinish.swift` is — `DownloadManager.swift`
/// sits at the 400-line `file_length` warning that `--strict` turns into an
/// error, and ownership is a cohesive topic to lift out. That split is why
/// `owners` is internal on the manager rather than private.
///
/// `states` cannot answer the question. `adopt(inFlightGUIDs:)` writes
/// `.downloading` for transfers this process never started, so a bare
/// "already downloading, back off" test would make the relaunch route discard
/// exactly the completion `adopt` was anticipating. Ownership has to be an
/// identity, not a display state.
///
/// What it is for: `BackgroundDownloader.pending` is keyed by task identifier,
/// so a completion for a task some *earlier* process created routes to
/// `handleCompletion` no matter what is running here. Its exit writes used to be
/// unconditional, so the orphan cleared the marker a live manual transfer was
/// holding; the row then read `.downloaded` with a transfer still in flight and
/// offered Delete, and the deleted download came back the moment that transfer
/// wrote its filename. A failing orphan was worse still — it wrote `.failed`
/// over the live marker, so the row offered Download and a tap started a third
/// concurrent transfer for the same guid.
///
/// `finishDownload` depends on the same invariant for a second reason: two
/// concurrent finishes both capture the previous filename before the asset read
/// suspends, so the loser's restore puts a stale `nil` over the winner's
/// committed filename and orphans the winner's file.
extension DownloadManager {
    /// Takes the transfer token for `guid`, or answers `nil` when another
    /// in-process transfer already holds it.
    ///
    /// All main-actor state, so the test and the write cannot interleave.
    func claimOwnership(of guid: String) -> UUID? {
        guard owners[guid] == nil else { return nil }
        let token = UUID()
        owners[guid] = token
        return token
    }

    /// Releases `guid`'s token and answers whether the caller still held it —
    /// which is exactly the question "may I write this guid's state".
    ///
    /// Answering a boolean rather than writing `states` here keeps that map's
    /// setter private to the manager, and keeps every state write on one screen
    /// with the outcome it reports.
    ///
    /// Note what the caller must *not* do with a `false`: restore a state saved
    /// before the transfer began. If the other writer resolved first, putting
    /// `.downloading` back leaves a marker no transfer is left to clear and the
    /// row spins for the rest of the process — the bug
    /// `adoptingATransferAlreadyResolvedDoesNotResurrectIt` exists to prevent,
    /// reintroduced from the other side. A `false` means write nothing.
    func releaseOwnership(of guid: String, heldBy token: UUID) -> Bool {
        guard owners[guid] == token else { return false }
        owners[guid] = nil
        return true
    }
}
