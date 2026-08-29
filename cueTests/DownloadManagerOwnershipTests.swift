import Foundation
import SwiftData
import Testing

@testable import cue

/// One writer per guid: what happens when a completion the session routes
/// arrives while this process is already transferring the same episode.
///
/// The realistic opening is a terminate-and-relaunch. A transfer that finished
/// while the app was dead is no longer in `session.allTasks`, so `adopt` never
/// marks its guid and the row offers Download; the user taps, and the old task's
/// completion is handed over while the new transfer is in flight. Exercised
/// through `handleCompletion(_:forGUID:)` and `GatedFileTransport`, so no test
/// constructs a background session.
///
/// Split from `DownloadManagerRelaunchTests` only to keep both files under the
/// 400-line `file_length` warning that `--strict` treats as an error.
@MainActor
struct DownloadManagerOwnershipTests {
    private static let enclosureURL = "https://example.com/audio/1.mp3"

    private func makeEpisode(in context: ModelContext) throws -> Episode {
        let podcast = Podcast(feedURL: testFeedURL, title: "Show")
        context.insert(podcast)
        let episode = Episode(guid: "guid-1", title: "Episode", enclosureURL: Self.enclosureURL)
        episode.podcast = podcast
        context.insert(episode)
        try context.save()
        return episode
    }

    private func stagedFile(in base: URL) throws -> URL {
        let staged = base.appending(path: "staged-\(UUID().uuidString).tmp", directoryHint: .notDirectory)
        try Data("stale audio".utf8).write(to: staged)
        return staged
    }

    private func response(_ statusCode: Int) throws -> HTTPURLResponse {
        let url = try #require(URL(string: Self.enclosureURL))
        return try #require(
            HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil))
    }

    /// The mirror image of `aTapWhileARelaunchFinishIsInFlightStartsNoSecondTransfer`.
    ///
    /// A completion for a task an earlier process created routes to the orphan
    /// branch no matter what is running here, and its exit write used to be
    /// unconditional: it cleared the live transfer's marker, so the row read
    /// `.downloaded` with a transfer still running and offered Delete — and the
    /// deleted download came back when that transfer wrote its filename.
    @Test func anOrphanCompletionDoesNotDisplaceALiveTransfer() async throws {
        try await withTemporaryBaseAsync { base in
            let context = try makeContext()
            let store = EpisodeStore(baseDirectory: base)
            let episode = try makeEpisode(in: context)
            let gate = GatedFileTransport(stagingDirectory: base)
            let manager = DownloadManager(context: context, store: store, transport: gate.transport)
            let staged = try stagedFile(in: base)

            let download = Task { try await manager.download(episode) }
            await yieldUntil { gate.callCount == 1 }
            try #require(manager.state(for: episode) == .downloading(.connecting))

            await manager.handleCompletion(.success((staged, try response(200))), forGUID: "guid-1")

            // the live transfer keeps its marker, so no row offers Delete
            #expect(manager.state(for: episode) == .downloading(.connecting))
            #expect(episode.localFilename == nil)
            // and the orphan's file is discarded rather than moved in behind it
            #expect(!FileManager.default.fileExists(atPath: staged.path(percentEncoded: false)))

            gate.open()
            try await download.value

            #expect(manager.state(for: episode) == nil)
            let filename = try #require(episode.localFilename)
            try #expect(store.fileExists(forRelativeFilename: filename) == true)
            try #expect(Data(contentsOf: store.url(forRelativeFilename: filename)) == Data("audio".utf8))
            let persisted = try #require(try persistedEpisode(guid: "guid-1", in: context))
            #expect(persisted.localFilename == filename)
        }
    }

    /// The nastier half: a failing orphan wrote `.failed` over the live marker,
    /// so the row offered Download again and a tap started a *third* concurrent
    /// transfer for one guid.
    @Test func anOrphanFailureDoesNotMarkALiveTransferFailed() async throws {
        try await withTemporaryBaseAsync { base in
            let context = try makeContext()
            let store = EpisodeStore(baseDirectory: base)
            let episode = try makeEpisode(in: context)
            let gate = GatedFileTransport(stagingDirectory: base)
            let manager = DownloadManager(context: context, store: store, transport: gate.transport)

            let download = Task { try await manager.download(episode) }
            await yieldUntil { gate.callCount == 1 }
            try #require(manager.state(for: episode) == .downloading(.connecting))

            await manager.handleCompletion(.failure(StubTransportError.offline), forGUID: "guid-1")

            // the marker is what refuses the next tap, so a row that still reads
            // as transferring is a row that cannot start a third transfer for
            // this guid. Asserted rather than demonstrated with a second
            // `download` call: under the regression that call parks on the
            // single transfer slot behind a gate this test has not opened yet,
            // and a hung suite reports nothing
            #expect(manager.state(for: episode) == .downloading(.connecting))

            gate.open()
            try await download.value

            #expect(manager.state(for: episode) == nil)
            #expect(episode.localFilename != nil)
            #expect(gate.callCount == 1)
        }
    }

    /// The orphan route still owns a guid nothing here is transferring — the
    /// ordinary relaunch case must not be turned into a discard by the guard.
    @Test func anOrphanCompletionForAnIdleGUIDStillFinishes() async throws {
        try await withTemporaryBaseAsync { base in
            let context = try makeContext()
            let store = EpisodeStore(baseDirectory: base)
            let episode = try makeEpisode(in: context)
            let manager = DownloadManager(
                context: context, store: store, transport: failingFileTransport())
            let staged = try stagedFile(in: base)

            // `adopt` marks foreign transfers `.downloading`, and that display
            // state must not read as ownership: the completion it anticipates is
            // exactly this one
            manager.adopt(
                inFlightAttempts: [DownloadAttemptIdentity(taskIdentifier: 1, guid: "guid-1")])
            await manager.handleCompletion(.success((staged, try response(200))), forGUID: "guid-1")

            let filename = try #require(episode.localFilename)
            try #expect(store.fileExists(forRelativeFilename: filename) == true)
            #expect(manager.state(for: episode) == nil)
        }
    }
}
