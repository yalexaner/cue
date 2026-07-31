import OSLog
import SwiftData
import SwiftUI

@main
struct CueApp: App {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "dev.yachmenev.cue",
        category: "storage"
    )

    init() {
        // spec §5: Episodes/ is created on first launch and excluded from backup.
        // Resolution never provisions, so this is the only thing that creates it
        // before a download lands. Non-fatal: the library, playback and the
        // session log all work without it, and the download path prepares the
        // directory again and surfaces its own error there.
        do {
            try EpisodeStore().prepareEpisodesDirectory()
        } catch {
            Self.logger.error("could not prepare the episodes directory: \(error, privacy: .public)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(for: [Podcast.self, Episode.self, PlaybackSession.self])
    }
}
