import Foundation
import SwiftData
import Testing

@testable import cue

/// Fixtures shared by the download progress suites.
///
/// `DownloadManagerProgressTests` and `DownloadManagerAttemptIdentityTests` are
/// one suite split by topic, so their setup lives here once rather than being
/// re-declared per file.
enum DownloadProgressFixtures {
    static let enclosureURL = "https://example.com/audio/1.mp3"
}

@MainActor
func makeProgressEpisode(in context: ModelContext) throws -> Episode {
    let podcast = Podcast(feedURL: testFeedURL, title: "Show")
    context.insert(podcast)
    let episode = Episode(
        guid: "guid-1", title: "Episode", enclosureURL: DownloadProgressFixtures.enclosureURL)
    episode.podcast = podcast
    context.insert(episode)
    try context.save()
    return episode
}

@MainActor
func makeProgressManager(
    base: URL, clock: DownloadClock = ManualDownloadClock()
) throws -> DownloadManager {
    DownloadManager(
        context: try makeContext(), store: EpisodeStore(baseDirectory: base),
        transport: failingFileTransport(), clock: clock)
}

@MainActor
func beginProgressAttempt(
    on manager: DownloadManager, taskIdentifier: Int = 1, guid: String = "guid-1"
) throws -> UUID {
    let token = try #require(manager.claimOwnership(of: guid))
    manager.states[guid] = .downloading(.connecting)
    manager.registerAttempt(taskIdentifier: taskIdentifier, forGUID: guid)
    return token
}

extension DownloadManager.DownloadState {
    /// The phase of a downloading state, for tests that care which one it is
    /// without restating the numbers riding on it.
    var progressPhase: DownloadProgress.Phase? {
        guard case .downloading(let progress) = self else { return nil }
        return progress.phase
    }
}

extension DownloadManager {
    /// The progress a guid's row is currently drawing, if it is drawing one.
    @MainActor
    func publishedProgress(forGUID guid: String) -> DownloadProgress? {
        guard case .downloading(let progress)? = states[guid] else { return nil }
        return progress
    }
}
