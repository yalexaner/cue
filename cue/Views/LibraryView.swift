import SwiftData
import SwiftUI

/// The subscribed shows, oldest subscription first (spec §12).
///
/// The list is the navigation root; a row pushes `PodcastDetailView`. Pull to
/// refresh folds every subscribed feed in again, sequentially — feeds are few,
/// the merge is additive, and one context doing one thing at a time is the
/// cheapest way to keep SwiftData writes ordered.
struct LibraryView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.diagnostics) private var diagnostics
    @Query(sort: \Podcast.addedAt, order: .forward) private var podcasts: [Podcast]

    @State private var isPresentingAddFeed = false
    @State private var refreshErrorMessage: String?

    var body: some View {
        List(podcasts) { podcast in
            NavigationLink(value: podcast) {
                PodcastRow(podcast: podcast)
            }
        }
        .navigationTitle("Library")
        .navigationDestination(for: Podcast.self) { podcast in
            PodcastDetailView(podcast: podcast)
        }
        .overlay {
            if podcasts.isEmpty {
                ContentUnavailableView(
                    "No Podcasts",
                    systemImage: "antenna.radiowaves.left.and.right",
                    description: Text("Add a feed address to see its episodes.")
                )
            }
        }
        .refreshable { await refreshEverySubscription() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isPresentingAddFeed = true
                } label: {
                    Label("Add Feed", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $isPresentingAddFeed) { AddFeedView() }
        .refreshErrorAlert($refreshErrorMessage)
    }

    /// Runs the sweep and turns whatever it reports into the alert's text.
    ///
    /// The sweep itself is `refreshAll(_:using:)`, which is plain and tested.
    private func refreshEverySubscription() async {
        let service = FeedService(context: context, diagnostics: diagnostics)
        let error = await refreshAll(podcasts, using: service)
        refreshErrorMessage = error.map(feedErrorMessage(for:))
    }
}

/// One library row: artwork placeholder, title, and the show's episode count.
///
/// Artwork is a placeholder on purpose — `artworkURL` is stored but nothing
/// downloads or caches images yet, and a per-row network fetch is not something
/// to add by accident.
private struct PodcastRow: View {
    let podcast: Podcast

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 8)
                .fill(.quaternary)
                .frame(width: 56, height: 56)
                .overlay {
                    Image(systemName: "waveform")
                        .foregroundStyle(.secondary)
                }
            VStack(alignment: .leading, spacing: 4) {
                Text(podcast.title)
                    .font(.headline)
                    .lineLimit(2)
                Text("^[\(podcast.episodes.count) episode](inflect: true)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
