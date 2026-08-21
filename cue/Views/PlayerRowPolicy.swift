/// Whether an episode row offers local playback for its download state.
///
/// Active transfers deliberately pass their transfer-only state through this
/// same total policy, so a failed retry over an older file cannot accidentally
/// gain a play action in the Active Transfers section.
func playAction(for state: EpisodeDownloadState) -> Bool {
    switch state {
    case .downloaded:
        return true
    case .notDownloaded, .downloading, .failed:
        return false
    }
}
