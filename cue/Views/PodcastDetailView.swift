import OSLog
import SwiftData
import SwiftUI

/// One show's episodes, newest first (spec §12).
///
/// The list reads the podcast's relationship rather than a `@Query`, so it needs
/// no predicate over a relationship and follows the show it was pushed with. The
/// order comes from `episodesNewestFirst(_:)`, which is plain and tested.
///
/// There is no downloaded indicator yet — downloads arrive in the next step, and
/// a file-system read per row is not something to add before there is one.
struct PodcastDetailView: View {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "dev.yachmenev.cue",
        category: "storage"
    )

    @Environment(\.modelContext) private var context

    let podcast: Podcast

    @State private var refreshErrorMessage: String?
    @State private var saveErrorMessage: String?

    private var episodes: [Episode] {
        episodesNewestFirst(podcast.episodes)
    }

    var body: some View {
        List(episodes) { episode in
            EpisodeRow(episode: episode)
                .swipeActions(edge: .leading) {
                    Button {
                        setPlayed(!episode.isPlayed, on: episode)
                    } label: {
                        playedLabel(for: episode)
                    }
                    .tint(episode.isPlayed ? .gray : .accentColor)
                }
                .contextMenu {
                    Button {
                        setPlayed(!episode.isPlayed, on: episode)
                    } label: {
                        playedLabel(for: episode)
                    }
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
            try await FeedService(context: context).refresh(podcast)
            refreshErrorMessage = nil
        } catch {
            // nil when the view went away mid-refresh; an alert on a screen
            // nobody is looking at is not a report
            refreshErrorMessage = reportableFeedErrorMessage(for: error)
        }
    }
}

/// One episode row: title, publication date, duration, played indicator.
private struct EpisodeRow: View {
    let episode: Episode

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
            if episode.isPlayed {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Played")
            }
        }
    }
}
