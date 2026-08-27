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
    @Query private var episodes: [Episode]

    @State private var groups: [DownloadGroup] = []
    @State private var totalByteCount = 0
    @State private var hasScanned = false
    @State private var storageErrorMessage: String?
    @State private var deleteErrorMessage: String?
    @State private var transferErrorMessage: String?

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
                            transferButton(for: transfer)
                        }
                        .swipeActions(edge: .trailing) { transferButton(for: transfer) }
                        .contextMenu { transferButton(for: transfer) }
                    }
                }
            }

            ForEach(groups) { group in
                Section {
                    ForEach(group.episodes) { episode in
                        DownloadedEpisodeRow(episode: episode)
                            .swipeActions(edge: .trailing) { fileButton(for: episode) }
                            .contextMenu { fileButton(for: episode) }
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
        let state = episodeDownloadState(
            localFilename: episode.localFilename, transfer: downloads.state(for: episode))
        switch downloadAction(for: state) {
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
}
