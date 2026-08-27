import SwiftUI

// The two row types `DownloadsView` renders, in their own file: `DownloadsView.swift`
// sits near the 400-line `file_length` warning that `--strict` turns into an
// error, and the rows are the cohesive topic to lift out — Tasks 7 to 11 of the
// diagnostics step all change row rendering rather than the screen around it.
// They are `internal` rather than file-private for the same reason: a
// file-private type cannot be referenced from the view it belongs to once the
// two live in different files.

/// One in-flight or failed transfer, including its always-visible escape hatch.
struct ActiveDownloadRow<Action: View>: View {
    let transfer: ActiveDownload
    let action: Action

    init(transfer: ActiveDownload, @ViewBuilder action: () -> Action) {
        self.transfer = transfer
        self.action = action()
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(transfer.episode.title)
                    .font(.headline)
                    .lineLimit(3)
                Text(transfer.episode.podcast?.title ?? "Unknown Podcast")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                transferStatus
            }
            Spacer(minLength: 0)
            action
                .labelStyle(.iconOnly)
        }
    }

    @ViewBuilder
    private var transferStatus: some View {
        switch transfer.state {
        case .downloading(let progress):
            VStack(alignment: .leading, spacing: 4) {
                if let value = progress.fractionValue {
                    ProgressView(value: value)
                        .accessibilityHidden(true)
                }
                Text(transferStatusText(progress))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(transferStatusText(progress))
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .lineLimit(3)
        }
    }
}

/// One Downloads row: the episode, its show's ordering, and its own size line.
///
/// The size arrives measured, from the scan that already walked the files, and
/// is absent when that scan could not measure it — this row never reads the
/// file system itself.
///
/// Its indicator is supplied by the screen rather than built here, for the same
/// reason the swipe action beside it is: this row is listed on file presence
/// alone, so an episode being re-downloaded appears here *and* in Active
/// Transfers, and a hard-wired delete would answer that row differently from the
/// swipe action on it — the delete-under-a-running-move race
/// `downloadAction(for:)` exists to forbid. The screen asks the shared policy
/// once and hands the answer down.
struct DownloadedEpisodeRow<Indicator: View>: View {
    let episode: Episode
    let byteCount: Int?
    let indicator: Indicator

    init(episode: Episode, byteCount: Int?, @ViewBuilder indicator: () -> Indicator) {
        self.episode = episode
        self.byteCount = byteCount
        self.indicator = indicator()
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(episode.title)
                    .font(.headline)
                    .lineLimit(3)
                Text(
                    episodeSubtitle(
                        publishedAt: episode.publishedAt, duration: episode.duration, byteCount: byteCount)
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            indicator
        }
    }
}
