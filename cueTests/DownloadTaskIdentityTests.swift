import Foundation
import SwiftData
import Testing

@testable import cue

/// The guid a background transfer carries in `taskDescription`.
///
/// The session and its delegate are device-verified only; what is assertable
/// here is the round-trip that the relaunch route depends on — a completion
/// arriving in a process that started nothing has this string and nothing else.
struct DownloadTaskIdentityTests {
    @Test func aGUIDRoundTripsThroughATaskDescription() {
        let description = DownloadTaskIdentity.taskDescription(forGUID: "guid-1")

        #expect(DownloadTaskIdentity.guid(fromTaskDescription: description) == "guid-1")
    }

    /// Feeds write URLs and tags as guids, and both contain the marker's
    /// separator; only the leading marker may be stripped.
    @Test func aGUIDContainingColonsRoundTripsWhole() {
        let guid = "tag:example.com,2026:episode:7"
        let description = DownloadTaskIdentity.taskDescription(forGUID: guid)

        #expect(DownloadTaskIdentity.guid(fromTaskDescription: description) == guid)
    }

    @Test func anUnstampedTaskResolvesToNoEpisode() {
        #expect(DownloadTaskIdentity.guid(fromTaskDescription: nil) == nil)
    }

    @Test func aDescriptionWrittenBySomethingElseResolvesToNoEpisode() {
        #expect(DownloadTaskIdentity.guid(fromTaskDescription: "guid-1") == nil)
        #expect(DownloadTaskIdentity.guid(fromTaskDescription: "") == nil)
    }

    /// The marker alone is not a guid: resolving it as the empty string would
    /// send the relaunch route looking for an episode that cannot exist.
    @Test func theMarkerWithNoGUIDResolvesToNoEpisode() {
        #expect(DownloadTaskIdentity.guid(fromTaskDescription: DownloadTaskIdentity.prefix) == nil)
    }
}

/// The other half of the round-trip: how the guid reaches the task in the first
/// place. A guid the transport never saw is a transfer nothing can resolve after
/// a relaunch, so the hand-off is worth pinning even though the session that
/// consumes it is device-verified only.
///
/// (What the manager does with a guid that resolves to nothing is
/// `finishingAnUnknownGUIDIsIgnored` in `DownloadManagerTests`.)
@MainActor
struct DownloadTaskGUIDHandoffTests {
    /// The task-local the production transport reads the guid from is set for
    /// the duration of the transport call and is nothing outside it.
    @Test func theTransportSeesTheGUIDOfTheEpisodeBeingDownloaded() async throws {
        try await withTemporaryBaseAsync { base in
            let context = try makeContext()
            let store = EpisodeStore(baseDirectory: base)
            let podcast = Podcast(feedURL: testFeedURL, title: "Show")
            context.insert(podcast)
            let episode = Episode(guid: "guid-7", title: "Episode", enclosureURL: "https://example.com/a.mp3")
            episode.podcast = podcast
            context.insert(episode)
            try context.save()

            let observed = GUIDRecorder()
            let stub = DownloadTransportStub(stagingDirectory: base)
            let inner = stub.transport
            let manager = DownloadManager(context: context, store: store) { url in
                observed.record(DownloadTaskIdentity.currentGUID)
                return try await inner(url)
            }

            #expect(DownloadTaskIdentity.currentGUID == nil)
            try await manager.download(episode)

            #expect(observed.recorded == "guid-7")
            #expect(DownloadTaskIdentity.currentGUID == nil)
        }
    }
}

/// Captures a value seen inside a `@Sendable` transport closure.
private final class GUIDRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?

    func record(_ guid: String?) {
        lock.withLock { value = guid }
    }

    var recorded: String? { lock.withLock { value } }
}
