import SwiftData
import SwiftUI

/// Every episode with a file on disk, grouped by show, with disk usage (spec §12).
///
/// Filtered on file presence *only*, never on played state (spec §7): a played
/// episode keeps its file and keeps its row here until the file is deleted.
///
/// The filter cannot be a `#Predicate`. `Episode.isDownloaded(in:)` reads the
/// file system and throws, so the list is built in memory by
/// `rebuild()` — and a throw becomes an alert, never a shorter list. Reporting
/// "cannot tell" as "not downloaded" here would show the user an empty
/// Downloads screen for a library that is entirely intact.
struct DownloadsView: View {
    @Environment(DownloadManager.self) private var downloads
    @Environment(PlaybackEngine.self) private var playback
    @Query private var episodes: [Episode]

    @State private var groups: [DownloadGroup] = []
    @State private var totalByteCount = 0
    @State private var hasScanned = false
    @State private var storageErrorMessage: String?
    @State private var deleteErrorMessage: String?
    @State private var transferErrorMessage: String?
    @State private var pendingDeletion: PendingDownloadDeletion?
    @State private var pendingFailure: PendingDownloadFailure?
    @State private var playbackErrorText: String?
    @State private var isPresentingPlayer = false

    private let store = EpisodeStore()

    /// Changes whenever the built list would come out different.
    ///
    /// `@Query` re-runs the body when any episode changes, but most of those
    /// changes — a played flag, an episode summary — leave this list identical
    /// and must not cost a directory scan. The download columns change it, and
    /// so do the two things `downloadGroups` *snapshots* rather than reads live:
    /// the section header's podcast title and the `publishedAt` its rows are
    /// ordered on. A refresh that renames a show or corrects a date would
    /// otherwise leave a stale header and a stale order standing until the next
    /// download, delete, or pull-to-refresh.
    ///
    /// Only an episode with a file contributes those two, so the podcast
    /// relationship is faulted for the rows this screen actually shows rather
    /// than for the whole library.
    ///
    /// A missing date is spelled as its own token rather than folded to `0`:
    /// zero is also the reference-time value of a real 2001-01-01 date, and an
    /// undated episode gaining one sorts differently ("undated last" becomes
    /// dated ordering) while the signature would not have changed.
    private var downloadSignature: [String] {
        episodes.map { episode in
            guard let filename = episode.localFilename else { return episode.guid }
            let published = episode.publishedAt.map { "\($0.timeIntervalSinceReferenceDate)" } ?? "none"
            return "\(episode.guid)|\(filename)|\(published)|\(episode.podcast?.title ?? "")"
        }
    }

    /// Derived directly from the observed transfer map, not from the disk-scan
    /// cache: byte progress changes no persisted episode field.
    /// Nothing in flight is the common case, and the body is re-evaluated for
    /// every episode change: the library is walked only when there is at least
    /// one transfer to resolve, and only its guids are kept.
    private var activeTransfers: [ActiveDownload] {
        let states = downloads.states
        guard !states.isEmpty else { return [] }
        var episodesByGUID: [String: Episode] = [:]
        for episode in episodes where states[episode.guid] != nil {
            episodesByGUID[episode.guid] = episode
        }
        return activeDownloads(episodesByGUID: episodesByGUID, states: states)
    }

    var body: some View {
        let activeTransfers = activeTransfers
        List {
            if !activeTransfers.isEmpty {
                Section("Active Transfers") {
                    ForEach(activeTransfers) { transfer in
                        ActiveDownloadRow(transfer: transfer) {
                            downloadIndicator(
                                for: transfer.episode, state: transfer.rowState, byteCount: nil)
                        }
                        .swipeActions(edge: .trailing) { transferButton(for: transfer) }
                        .contextMenu { transferButton(for: transfer) }
                    }
                }
            }

            ForEach(groups) { group in
                Section {
                    ForEach(group.episodes) { item in
                        DownloadedEpisodeRow(episode: item.episode, byteCount: item.byteCount) {
                            downloadIndicator(
                                for: item.episode,
                                state: fileRowState(for: item.episode),
                                byteCount: item.byteCount)
                        }
                        .swipeActions(edge: .leading) { playButton(for: item.episode) }
                        .swipeActions(edge: .trailing) { fileButton(for: item.episode) }
                        .contextMenu {
                            playButton(for: item.episode)
                            fileButton(for: item.episode)
                        }
                    }
                } header: {
                    Text(group.title)
                } footer: {
                    Text(diskUsageText(group.byteCount))
                }
            }

            if !groups.isEmpty {
                Section {
                    LabeledContent("Total", value: diskUsageText(totalByteCount))
                }
            }
        }
        .navigationTitle("Downloads")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { DiagnosticsExportButton() }
        }
        .overlay {
            // only when the scan actually succeeded and found nothing: an empty
            // screen must never be how a storage failure looks
            if hasScanned && groups.isEmpty && activeTransfers.isEmpty && storageErrorMessage == nil {
                ContentUnavailableView(
                    "No Downloads",
                    systemImage: "arrow.down.circle",
                    description: Text("Download an episode to keep it on this device.")
                )
            }
        }
        .refreshable { rebuild() }
        .onChange(of: downloadSignature, initial: true) { rebuild() }
        .errorAlert("Could Not Read Downloads", $storageErrorMessage)
        .errorAlert("Could Not Delete", $deleteErrorMessage)
        .errorAlert("Download Failed", $transferErrorMessage)
        .errorAlert("Playback Failed", $playbackErrorText)
        .sheet(isPresented: $isPresentingPlayer) { PlayerView() }
        .deleteDownloadConfirmation($pendingDeletion) { guid in
            episode(withGUID: guid).map { delete($0) }
        }
        .downloadFailureAlert($pendingFailure) { guid in
            episode(withGUID: guid).map { retry($0) }
        }
    }

    /// The row a confirmation was raised on, resolved against the query already
    /// backing this screen.
    private func episode(withGUID guid: String) -> Episode? {
        episodes.first { $0.guid == guid }
    }

    /// Both sections' visible indicator, routed through the *tap* policy.
    ///
    /// Written once for the Active Transfers row and the completed row rather
    /// than twice: the two sections can show the same episode at the same
    /// moment — a re-download is listed above on its transfer and below on the
    /// file it still has — and an indicator that answered that row on its own
    /// would offer an immediate delete under the running move.
    ///
    /// Not `downloadAction(for:)`: that maps a failed transfer to Retry, which
    /// is right for the labelled swipe action beside it and wrong for a tap
    /// target — the indicator shows the failure, and Retry is one explicit
    /// button further in.
    @ViewBuilder
    private func downloadIndicator(
        for episode: Episode, state: EpisodeDownloadState, byteCount: Int?
    ) -> some View {
        Button {
            switch downloadIndicatorActivation(for: state) {
            case .cancel:
                Task { await downloads.cancel(episode) }
            case .showFailure:
                if case .failed(let message) = state {
                    pendingFailure = PendingDownloadFailure(id: episode.guid, message: message)
                }
            case .download:
                retry(episode)
            case .confirmDelete:
                confirmDelete(episode, byteCount: byteCount)
            }
        } label: {
            transferIndicatorImage(for: state)
                .frame(minWidth: downloadIndicatorMinimumTapTarget, minHeight: downloadIndicatorMinimumTapTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .downloadIndicatorLabels(state)
    }

    /// The completed row's state: its file, and any transfer running over it.
    ///
    /// The same expression `fileButton(for:)` uses, so the row's tap target and
    /// its swipe action cannot disagree about what the row is.
    private func fileRowState(for episode: Episode) -> EpisodeDownloadState {
        episodeDownloadState(localFilename: episode.localFilename, transfer: downloads.state(for: episode))
    }

    @ViewBuilder
    private func transferIndicatorImage(for state: EpisodeDownloadState) -> some View {
        switch state {
        case .downloading:
            Image(systemName: "xmark.circle")
                .foregroundStyle(.secondary)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .downloaded:
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(.secondary)
        case .notDownloaded:
            Image(systemName: "arrow.down.circle")
                .foregroundStyle(.secondary)
        }
    }

    /// Raises the confirmation for a tap-triggered delete.
    ///
    /// The size the scan already measured is reused when there is one; a row it
    /// could not measure asks the store on demand rather than claiming a size,
    /// and a storage failure there is reported instead of swallowed.
    private func confirmDelete(_ episode: Episode, byteCount: Int?) {
        do {
            let size = try byteCount ?? episode.fileSize(in: store)
            let message = deleteDownloadConfirmationMessage(episodeTitle: episode.title, byteCount: size)
            pendingDeletion = PendingDownloadDeletion(id: episode.guid, message: message)
        } catch {
            deleteErrorMessage = downloadErrorMessage(for: error)
        }
    }

    /// The active row's one transfer action, shared by its visible button,
    /// swipe action and context menu.
    @ViewBuilder
    private func transferButton(for transfer: ActiveDownload) -> some View {
        switch downloadAction(for: transfer.rowState) {
        case .download:
            Button {
                retry(transfer.episode)
            } label: {
                Label("Retry Download", systemImage: "arrow.clockwise")
            }
        case .cancel:
            Button(role: .destructive) {
                Task { await downloads.cancel(transfer.episode) }
            } label: {
                Label("Cancel Download", systemImage: "xmark.circle")
            }
        case .delete:
            EmptyView()
        }
    }

    /// The row's one file action, written once so the swipe action and the
    /// context menu cannot drift apart — the same rule `PodcastDetailView`
    /// follows for its download button.
    ///
    /// Routed through `downloadAction(for:)` rather than shown unconditionally,
    /// because the two download screens must not answer the same row
    /// differently: a transfer in flight outranks a stored file, and a row
    /// mid-transfer offers Cancel rather than Delete. A re-download of an episode that
    /// already has a file is exactly that row — it is listed here on file
    /// presence, and deleting under the running move is the race the policy
    /// exists to forbid (the delete clears the columns and the file, then the
    /// finish writes the new filename over them, so the episode comes back
    /// downloaded moments after the user removed it).
    @ViewBuilder
    private func fileButton(for episode: Episode) -> some View {
        switch downloadAction(for: fileRowState(for: episode)) {
        case .delete:
            Button(role: .destructive) {
                delete(episode)
            } label: {
                Label("Delete Download", systemImage: "trash")
            }
        case .cancel:
            Button(role: .destructive) {
                Task { await downloads.cancel(episode) }
            } label: {
                Label("Cancel Download", systemImage: "xmark.circle")
            }
        case .download:
            EmptyView()
        }
    }

    @ViewBuilder
    private func playButton(for episode: Episode) -> some View {
        let state = episodeDownloadState(
            localFilename: episode.localFilename, transfer: downloads.state(for: episode))
        if playAction(for: state) {
            Button {
                play(episode)
            } label: {
                Label("Play", systemImage: "play.fill")
            }
            .tint(.accentColor)
        }
    }

    /// Re-reads which episodes have a file and what those files occupy.
    ///
    /// The previous list is left standing when the scan fails, for the same
    /// reason the alert exists: a storage error is a thing that went wrong, not
    /// a library that shrank.
    private func rebuild() {
        do {
            var downloaded: [Episode] = []
            var sizes: [String: Int] = [:]
            for episode in episodes {
                guard try episode.isDownloaded(in: store), let filename = episode.localFilename else {
                    continue
                }
                downloaded.append(episode)
                if let size = try store.fileSize(forRelativeFilename: filename) {
                    sizes[episode.guid] = size
                }
            }
            groups = downloadGroups(downloaded, sizes: sizes)
            totalByteCount = sizes.values.reduce(0, +)
            storageErrorMessage = nil
            hasScanned = true
        } catch {
            storageErrorMessage = downloadErrorMessage(for: error)
        }
    }

    private func delete(_ episode: Episode) {
        do {
            try downloads.deleteDownload(for: episode)
        } catch {
            deleteErrorMessage = downloadErrorMessage(for: error)
        }
        // either way the row may have changed: a failed removal still cleared
        // the columns, and the scan is what decides whether the row is still here
        rebuild()
    }

    private func retry(_ episode: Episode) {
        Task {
            do {
                try await downloads.download(episode)
                transferErrorMessage = nil
            } catch {
                transferErrorMessage = downloadErrorMessage(for: error)
            }
        }
    }

    private func play(_ episode: Episode) {
        do {
            try playback.play(episode, store: store)
            playbackErrorText = nil
            isPresentingPlayer = true
        } catch {
            playbackErrorText = playbackErrorMessage(for: error)
        }
    }
}
