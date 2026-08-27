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
struct DownloadedEpisodeRow: View {
    let episode: Episode

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(episode.title)
                .font(.headline)
                .lineLimit(3)
            Text(episodeSubtitle(publishedAt: episode.publishedAt, duration: episode.duration))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}
