import Foundation

/// One transfer shown above the completed downloads list.
struct ActiveDownload: Identifiable {
    let episode: Episode
    let state: DownloadManager.DownloadState

    var id: String { episode.guid }

    /// The shared row policy, asked with no filename on purpose.
    ///
    /// This section is the transfer's own view of itself (AGENTS.md: it derives
    /// directly from the in-memory transfer states), so a failed retry over an
    /// episode that still has its previous file belongs here with Retry — while
    /// the completed list below goes on offering Delete for the file that is
    /// genuinely still there. Routed through the one policy function rather
    /// than restating it, so a new `DownloadState` case cannot be answered two
    /// ways by one screen.
    var rowState: EpisodeDownloadState {
        episodeDownloadState(localFilename: nil, transfer: state)
    }
}

/// The in-flight and failed transfers the Downloads tab shows, in stable order.
///
/// The caller supplies the one guid lookup built from its existing `@Query`.
/// Unknown guids are omitted: the relaunch route owns clearing state for an
/// episode that was deleted while its background transfer was running.
func activeDownloads(
    episodesByGUID: [String: Episode],
    states: [String: DownloadManager.DownloadState]
) -> [ActiveDownload] {
    states.compactMap { guid, state in
        episodesByGUID[guid].map { ActiveDownload(episode: $0, state: state) }
    }
    .sorted(by: activeDownloadComesBefore)
}

private func activeDownloadComesBefore(_ left: ActiveDownload, _ right: ActiveDownload) -> Bool {
    let leftRank = activeDownloadRank(left.state)
    let rightRank = activeDownloadRank(right.state)
    if leftRank != rightRank { return leftRank < rightRank }

    let leftTitle = left.episode.podcast?.title ?? "Unknown Podcast"
    let rightTitle = right.episode.podcast?.title ?? "Unknown Podcast"
    if leftTitle != rightTitle { return leftTitle < rightTitle }

    switch (left.episode.publishedAt, right.episode.publishedAt) {
    case (let leftDate?, let rightDate?) where leftDate != rightDate:
        return leftDate > rightDate
    case (.some, .none):
        return true
    case (.none, .some):
        return false
    default:
        return left.episode.guid < right.episode.guid
    }
}

private func activeDownloadRank(_ state: DownloadManager.DownloadState) -> Int {
    state.isDownloading ? 0 : 1
}
