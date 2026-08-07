import SwiftData
import SwiftUI

/// One show's episodes (spec §7).
///
/// Placeholder shell: navigation and the title land here so the library can push
/// to it; the episode list, played toggle and pull-to-refresh arrive next.
struct PodcastDetailView: View {
    let podcast: Podcast

    var body: some View {
        ContentUnavailableView(
            "No Episodes",
            systemImage: "waveform",
            description: Text("Refresh this feed to see its episodes.")
        )
        .navigationTitle(podcast.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
