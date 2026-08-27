import OSLog
import SwiftData
import SwiftUI

/// One show's episodes, newest first (spec §12).
///
/// The list reads the podcast's relationship rather than a `@Query`, so it needs
/// no predicate over a relationship and follows the show it was pushed with. The
/// order comes from `episodesNewestFirst(_:)`, which is plain and tested.
///
/// The download indicator reads `localFilename` and the manager's in-memory
/// transfer state, never the file system: `episodeDownloadState(localFilename:transfer:)`
/// carries that policy, and the Downloads screen is where file presence is
/// actually verified (spec §7).
struct PodcastDetailView: View {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "dev.yachmenev.cue",
        category: "storage"
    )

    @Environment(\.modelContext) private var context
    @Environment(\.diagnostics) private var diagnostics
    @Environment(DownloadManager.self) private var downloads

    let podcast: Podcast

    @State private var refreshErrorMessage: String?
    @State private var saveErrorMessage: String?
    @State private var downloadErrorText: String?
    @State private var pendingDeletion: PendingDownloadDeletion?
    @State private var pendingFailure: PendingDownloadFailure?

    /// Constructed here, not defaulted inside the model: a size is measured on
    /// demand for the confirmation and this list never scans the directory.
    private let store = EpisodeStore()

    private var episodes: [Episode] {
        episodesNewestFirst(podcast.episodes)
    }

    var body: some View {
        List(episodes) { episode in
            EpisodeRow(episode: episode, downloadState: downloadState(for: episode)) { activation in
                activateIndicator(activation, for: episode)
            }
            .swipeActions(edge: .leading) {
                Button {
                    setPlayed(!episode.isPlayed, on: episode)
                } label: {
                    playedLabel(for: episode)
                }
                .tint(episode.isPlayed ? .gray : .accentColor)
            }
            .swipeActions(edge: .trailing) {
                downloadButton(for: episode)
            }
            .contextMenu {
                Button {
                    setPlayed(!episode.isPlayed, on: episode)
                } label: {
                    playedLabel(for: episode)
                }
                downloadButton(for: episode)
            }
        }
        .navigationTitle(podcast.title)
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if episodes.isEmpty {
                ContentUnavailableView(
                    "No Episodes",
                    systemImage: "waveform",
                    description: Text("Refresh this feed to see its episodes.")
                )
            }
        }
        .refreshable { await refresh() }
        .refreshErrorAlert($refreshErrorMessage)
        .errorAlert("Could Not Save", $saveErrorMessage)
        .errorAlert("Download Failed", $downloadErrorText)
        .deleteDownloadConfirmation($pendingDeletion) { guid in
            episode(withGUID: guid).map { deleteDownload($0) }
        }
        .downloadFailureAlert($pendingFailure) { guid in
            episode(withGUID: guid).map { download($0) }
        }
    }

    /// The row a confirmation was raised on, resolved against the list on screen.
    private func episode(withGUID guid: String) -> Episode? {
        podcast.episodes.first { $0.guid == guid }
    }

    /// Routes an indicator tap through the shared policy.
    ///
    /// The confirmation's size is measured here rather than in the row: the read
    /// throws, and a view builder that swallowed it would report an unreadable
    /// file as an episode occupying nothing.
    private func activateIndicator(_ activation: DownloadIndicatorActivation, for episode: Episode) {
        switch activation {
        case .download:
            download(episode)
        case .cancel:
            cancelDownload(episode)
        case .confirmDelete:
            confirmDelete(episode)
        case .showFailure:
            showFailure(for: episode)
        }
    }

    private func confirmDelete(_ episode: Episode) {
        do {
            let byteCount = try episode.fileSize(in: store)
            let message = deleteDownloadConfirmationMessage(
                episodeTitle: episode.title, byteCount: byteCount)
            pendingDeletion = PendingDownloadDeletion(id: episode.guid, message: message)
        } catch {
            downloadErrorText = downloadErrorMessage(for: error)
        }
    }

    private func showFailure(for episode: Episode) {
        guard case .failed(let message) = downloadState(for: episode) else { return }
        pendingFailure = PendingDownloadFailure(id: episode.guid, message: message)
    }

    private func downloadState(for episode: Episode) -> EpisodeDownloadState {
        episodeDownloadState(localFilename: episode.localFilename, transfer: downloads.state(for: episode))
    }

    /// The row's one file action, including Cancel while a transfer is running.
    ///
    /// Which action it is comes from `downloadAction(for:)`, so the swipe and the
    /// context menu cannot offer different things for the same row.
    @ViewBuilder
    private func downloadButton(for episode: Episode) -> some View {
        switch downloadAction(for: downloadState(for: episode)) {
        case .download:
            Button {
                download(episode)
            } label: {
                Label("Download", systemImage: "arrow.down.circle")
            }
            .tint(.accentColor)
        case .delete:
            Button(role: .destructive) {
                deleteDownload(episode)
            } label: {
                Label("Delete Download", systemImage: "trash")
            }
        case .cancel:
            Button(role: .destructive) {
                cancelDownload(episode)
            } label: {
                Label("Cancel Download", systemImage: "xmark.circle")
            }
        }
    }

    /// Starts a transfer and reports what it refused to do.
    ///
    /// Detached from the row's lifetime on purpose: a transfer is the manager's,
    /// not the view's, and `.task`-style ownership would cancel a download the
    /// moment the user scrolled back to the library. Cancellation is explicit
    /// through the row action instead.
    private func download(_ episode: Episode) {
        Task {
            do {
                try await downloads.download(episode)
            } catch {
                downloadErrorText = downloadErrorMessage(for: error)
            }
        }
    }

    private func cancelDownload(_ episode: Episode) {
        Task { await downloads.cancel(episode) }
    }

    private func deleteDownload(_ episode: Episode) {
        do {
            try downloads.deleteDownload(for: episode)
        } catch {
            downloadErrorText = downloadErrorMessage(for: error)
        }
    }

    /// Toggles played and commits it immediately.
    ///
    /// Leaving the flag pending for autosave puts it in reach of
    /// `FeedService`'s rollback: a refresh started before autosave fires and
    /// then failing its save would discard the toggle along with the merge, and
    /// refresh must never touch `isPlayed` (spec §6).
    private func setPlayed(_ isPlayed: Bool, on episode: Episode) {
        let previousIsPlayed = episode.isPlayed
        let previousPlayedAt = episode.playedAt
        episode.setPlayed(isPlayed)
        do {
            try context.save()
        } catch {
            // a pending mutation the store refused is a row showing one value
            // over a store holding another, and a later `FeedService` rollback
            // would flip it back with nothing to explain it. Put the pair back
            // exactly as it was — `rollback()` is context-wide and would drop
            // edits this view never made — and say so, since the row is about
            // to disagree with the tap that made it
            episode.restorePlayed(previousIsPlayed, at: previousPlayedAt)
            saveErrorMessage = "The played state could not be saved. Nothing was changed."
            Self.logger.error("could not save the played flag: \(error, privacy: .public)")
        }
    }

    private func playedLabel(for episode: Episode) -> some View {
        episode.isPlayed
            ? Label("Mark Unplayed", systemImage: "circle")
            : Label("Mark Played", systemImage: "checkmark.circle")
    }

    /// Folds this show's feed in again. The merge is additive, so a refresh
    /// cannot lose the played flags the rows just set.
    ///
    /// Navigating away cancels the refresh; that is not a failure to alert on.
    private func refresh() async {
        do {
            try await FeedService(context: context, diagnostics: diagnostics).refresh(podcast)
            refreshErrorMessage = nil
        } catch {
            // nil when the view went away mid-refresh; an alert on a screen
            // nobody is looking at is not a report
            refreshErrorMessage = reportableFeedErrorMessage(for: error)
        }
    }
}

/// One episode row: title, publication date, duration, download and played
/// indicators.
///
/// The two indicators are independent, and both can show at once: a downloaded
/// episode that has been played keeps its file (spec §4, AC 8).
///
/// The download indicator is a button in *every* phase, not only the failed
/// one — starting a download used to need a swipe or a long-press, which is a
/// gesture nobody discovers. What the tap does comes from
/// `downloadIndicatorActivation(for:)` and is handed back to the screen, which
/// owns the confirmation and the failure alert: measuring a size to name in the
/// confirmation throws, and that belongs on the screen's error path.
///
/// The row's own tap gesture stays unbound; playback claims it in a later step.
private struct EpisodeRow: View {
    let episode: Episode
    let downloadState: EpisodeDownloadState
    let activate: (DownloadIndicatorActivation) -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(episode.title)
                    .font(.headline)
                    .lineLimit(3)
                Text(episodeSubtitle(publishedAt: episode.publishedAt, duration: episode.duration))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            downloadIndicator
            if episode.isPlayed {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Played")
            }
        }
    }

    private var downloadIndicator: some View {
        Button {
            activate(downloadIndicatorActivation(for: downloadState))
        } label: {
            indicatorContent
                .frame(minWidth: downloadIndicatorMinimumTapTarget, minHeight: downloadIndicatorMinimumTapTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .downloadIndicatorLabels(downloadState)
    }

    @ViewBuilder
    private var indicatorContent: some View {
        switch downloadState {
        case .downloading(let progress):
            downloadProgress(progress)
        case .downloaded:
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(.secondary)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .notDownloaded:
            Image(systemName: "arrow.down.circle")
                .foregroundStyle(.secondary)
        }
    }

    private func downloadProgress(_ progress: DownloadProgress) -> some View {
        let status = compactTransferStatus(progress)
        return HStack(spacing: 6) {
            if let value = status.fractionValue {
                ProgressView(value: value)
                    .frame(width: 48)
            } else if status.showsSpinner {
                ProgressView()
                    .controlSize(.small)
            }
            if let text = status.text {
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}
