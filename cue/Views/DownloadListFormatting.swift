import Foundation

/// One podcast's downloaded episodes, with what they occupy on disk (spec §12).
///
/// `id` is the show's `feedURL` — unique in the store, and stable across the
/// fetches that rebuild the list — rather than the model's object identity,
/// which a re-fetch does not preserve. An episode whose podcast relationship is
/// missing lands in one nameless group instead of vanishing: a downloaded file
/// nobody can see is a file nobody can delete.
struct DownloadGroup: Identifiable {
    let id: String
    let title: String
    let episodes: [DownloadedEpisode]
    /// Bytes on disk for this group, summed from the sizes the caller measured.
    let byteCount: Int
}

/// One downloaded episode with what its own file occupies on disk.
///
/// The size the Downloads scan measures reaches the row through this pair
/// rather than only the group and total sums: the row is where the user reads
/// what an individual episode costs, and re-measuring it per row would mean a
/// throwing file-system read on every render. `byteCount` is optional because
/// a file whose size could not be measured must render as no size at all — the
/// scan contributes an entry only for a size it actually got.
///
/// `id` is the episode's `guid` — the store's uniqueness scope, stable across
/// the fetches that rebuild the list — rather than the model's object identity.
struct DownloadedEpisode: Identifiable {
    let episode: Episode
    let byteCount: Int?

    var id: String { episode.guid }
}

/// The title a downloaded episode with no podcast is filed under.
private let ungroupedTitle = "Unknown Podcast"

/// Groups downloaded episodes by show, newest episode first inside each group.
///
/// A free function over values the caller already measured, rather than a method
/// that reads the file system: sizes come from `EpisodeStore.fileSize`, which
/// throws, and a view that swallowed that throw would report a storage failure
/// as a smaller library. `sizes` is keyed by `Episode.guid` — the store's
/// uniqueness scope — and a guid it has no entry for contributes nothing rather
/// than being dropped from the list.
///
/// Groups are ordered by title, ties broken on `id`, so the order is total and
/// two rebuilds of the same library never disagree.
func downloadGroups(_ episodes: [Episode], sizes: [String: Int]) -> [DownloadGroup] {
    let grouped = Dictionary(grouping: episodes) { $0.podcast?.feedURL ?? "" }

    return grouped.map { feedURL, episodes in
        DownloadGroup(
            id: feedURL,
            title: episodes.first?.podcast?.title ?? ungroupedTitle,
            episodes: episodesNewestFirst(episodes).map {
                DownloadedEpisode(episode: $0, byteCount: sizes[$0.guid])
            },
            byteCount: episodes.reduce(0) { $0 + (sizes[$1.guid] ?? 0) }
        )
    }
    .sorted { left, right in
        if left.title != right.title { return left.title < right.title }
        return left.id < right.id
    }
}

/// A byte count as the file sizes iOS shows elsewhere — "1.2 MB", "Zero KB".
///
/// `.file` style rather than `.memory`: this is disk usage, and a download that
/// reads as 1,048,576 bytes in Settings must not read as 1 MiB here.
func diskUsageText(_ byteCount: Int) -> String {
    byteCount.formatted(.byteCount(style: .file))
}

/// What an episode row should say about its file (spec §12's state indicators).
enum EpisodeDownloadState: Equatable {
    case notDownloaded
    case downloading(DownloadProgress)
    case downloaded
    /// The last attempt failed; the row offers another try.
    case failed(message: String)
}

/// The row's download state, from the stored filename and the in-flight transfer.
///
/// Deliberately reads `localFilename` and not `Episode.isDownloaded(in:)`: that
/// one touches the file system and throws, and doing it per row on every render
/// of a long episode list is both slow and a swallowed-error hazard. The
/// Downloads screen — the one place file presence is the whole point (spec §7) —
/// pays for the real check.
///
/// A transfer in flight outranks a stored filename, so a re-download of an
/// episode that already has a file reads as `downloading` rather than as done.
func episodeDownloadState(
    localFilename: String?,
    transfer: DownloadManager.DownloadState?
) -> EpisodeDownloadState {
    switch transfer {
    case .downloading(let progress):
        return .downloading(progress)
    case .failed(let message):
        // a failed retry over an existing file is still a downloaded episode
        return localFilename == nil ? .failed(message: message) : .downloaded
    case nil:
        return localFilename == nil ? .notDownloaded : .downloaded
    }
}

/// Whether the row's action starts, cancels or removes a download.
///
/// One question with one answer, so the swipe action and the context menu cannot
/// drift apart: an episode mid-transfer offers Cancel rather than Delete,
/// because deleting under a running move is a race. Every download phase answers
/// the same way — a queued transfer is cancellable before it has a session task
/// (`DownloadQueue.swift`), and a connecting one has nothing on disk to delete.
func downloadAction(for state: EpisodeDownloadState) -> DownloadRowAction {
    switch state {
    case .notDownloaded, .failed:
        return .download
    case .downloaded:
        return .delete
    case .downloading:
        return .cancel
    }
}

/// The one action an episode row offers for its file.
enum DownloadRowAction: Equatable {
    case download
    case cancel
    case delete
}
