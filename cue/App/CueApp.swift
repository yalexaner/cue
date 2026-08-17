import OSLog
import SwiftData
import SwiftUI

@main
struct CueApp: App {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "dev.yachmenev.cue",
        category: "storage"
    )

    // the one UIKit callback SwiftUI has no equivalent for: a background
    // transfer finishing while the app is not running (spec §7)
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    private let container: ModelContainer

    /// Owned here rather than constructed at the call site, unlike every other
    /// service: it holds the state of transfers that outlive any view, and the
    /// background session's delegate has to have somewhere to deliver to. See
    /// the type's own doc comment for the full reasoning.
    @State private var downloads: DownloadManager

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

        // built here rather than by `.modelContainer(for:)` because the download
        // manager needs the main context before the scene body runs. A container
        // that cannot open is unrecoverable either way — the modifier traps too
        do {
            container = try ModelContainer(for: Podcast.self, Episode.self, PlaybackSession.self)
        } catch {
            fatalError("could not open the store: \(error)")
        }
        let manager = DownloadManager(
            context: container.mainContext,
            transport: BackgroundDownloader.shared.transport,
            // the transport's other half: the session counts an outcome as
            // handed over until the finish that follows it reports back
            deliveryBarrier: { BackgroundDownloader.shared.completeDeliveredWork() }
        )
        // here rather than only in the scene's `.task`: a launch made purely to
        // deliver a finished background transfer may never present a scene, and
        // a completion with nowhere to go loses the download
        manager.registerCompletionRoute(with: .shared)
        _downloads = State(initialValue: manager)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(downloads)
                // re-attach to transfers the system kept running while the app
                // was gone, and claim any that finished in the meantime
                .task { await downloads.connect(to: .shared) }
        }
        .modelContainer(container)
    }
}
