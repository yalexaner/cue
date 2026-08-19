import Foundation
import SwiftData
import Testing

@testable import cue

/// Byte progress, attempt identity and the stale-event rules around them.
///
/// The downloader cases use only value-carrying seams. Constructing a
/// `BackgroundDownloader` is safe; no case touches its session.
@MainActor
struct DownloadManagerProgressTests {
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

    private func makeManager(base: URL) throws -> DownloadManager {
        DownloadManager(
            context: try makeContext(), store: EpisodeStore(baseDirectory: base),
            transport: failingFileTransport())
    }

    private func beginAttempt(
        on manager: DownloadManager, taskIdentifier: Int = 1, guid: String = "guid-1"
    ) throws -> UUID {
        let token = try #require(manager.claimOwnership(of: guid))
        manager.states[guid] = .downloading(.waiting)
        manager.registerAttempt(taskIdentifier: taskIdentifier, forGUID: guid)
        return token
    }

    @Test func delegateProgressMapsTaskDescriptionToGUID() {
        let downloader = BackgroundDownloader()
        let events = RecordedProgressEvents()
        downloader.setProgressHandler { taskIdentifier, guid, progress in
            events.record(taskIdentifier: taskIdentifier, guid: guid, progress: progress)
        }

        downloader.reportProgress(
            taskIdentifier: 7,
            taskDescription: DownloadTaskIdentity.taskDescription(forGUID: "guid-1"),
            bytesWritten: 25, expectedBytes: 100)
        downloader.reportProgress(
            taskIdentifier: 8, taskDescription: "not-cue", bytesWritten: 50,
            expectedBytes: 100)

        let expected = RecordedProgress(
            taskIdentifier: 7, guid: "guid-1", progress: .fraction(bytesWritten: 25, value: 0.25))
        #expect(events.values == [expected])
    }

    @Test func unknownAndInvalidTotalsAreHandledWithoutInvalidFractions() {
        #expect(
            DownloadProgress.reported(bytesWritten: 12, expectedBytes: -1)
                == .indeterminate(bytesWritten: 12))
        #expect(
            DownloadProgress.reported(bytesWritten: 12, expectedBytes: 0)
                == .indeterminate(bytesWritten: 12))
        #expect(DownloadProgress.reported(bytesWritten: -1, expectedBytes: 100) == nil)
        #expect(
            DownloadProgress.reported(bytesWritten: 150, expectedBytes: 100)
                == .fraction(bytesWritten: 150, value: 1))
    }

    @Test func lowerByteUpdatesAreDroppedEvenWhenTheyArriveLater() async throws {
        try await withTemporaryBaseAsync { base in
            let manager = try makeManager(base: base)
            _ = try beginAttempt(on: manager)

            manager.handleProgress(
                taskIdentifier: 1, guid: "guid-1",
                progress: .fraction(bytesWritten: 80, value: 0.8))
            manager.handleProgress(
                taskIdentifier: 1, guid: "guid-1",
                progress: .fraction(bytesWritten: 40, value: 0.4))

            #expect(manager.states["guid-1"] == .downloading(.fraction(bytesWritten: 80, value: 0.8)))
        }
    }

    @Test func equalBytesCanBecomeKnownAndAcceptACorrectedTotal() async throws {
        try await withTemporaryBaseAsync { base in
            let manager = try makeManager(base: base)
            _ = try beginAttempt(on: manager)

            manager.handleProgress(
                taskIdentifier: 1, guid: "guid-1",
                progress: .indeterminate(bytesWritten: 50))
            #expect(manager.states["guid-1"] == .downloading(.indeterminate(bytesWritten: 50)))

            manager.handleProgress(
                taskIdentifier: 1, guid: "guid-1",
                progress: .fraction(bytesWritten: 50, value: 0.5))
            #expect(manager.states["guid-1"] == .downloading(.fraction(bytesWritten: 50, value: 0.5)))

            manager.handleProgress(
                taskIdentifier: 1, guid: "guid-1",
                progress: .fraction(bytesWritten: 50, value: 0.25))
            #expect(manager.states["guid-1"] == .downloading(.fraction(bytesWritten: 50, value: 0.25)))
        }
    }

    @Test func registrationCompletesBeforeTheFirstProgressEvent() async throws {
        try await withTemporaryBaseAsync { base in
            let manager = try makeManager(base: base)
            let downloader = BackgroundDownloader()
            manager.registerCompletionRoute(with: downloader)
            _ = try #require(manager.claimOwnership(of: "guid-1"))
            manager.states["guid-1"] = .downloading(.waiting)

            await downloader.registerStart(taskIdentifier: 9, guid: "guid-1")
            downloader.reportProgress(
                taskIdentifier: 9,
                taskDescription: DownloadTaskIdentity.taskDescription(forGUID: "guid-1"),
                bytesWritten: 30, expectedBytes: 60)
            await yieldUntil {
                manager.states["guid-1"] == .downloading(.fraction(bytesWritten: 30, value: 0.5))
            }

            #expect(manager.states["guid-1"] == .downloading(.fraction(bytesWritten: 30, value: 0.5)))
        }
    }

    @Test func transportStubRegistersBeforeItsProgressHook() async throws {
        try await withTemporaryBaseAsync { base in
            let stub = DownloadTransportStub(stagingDirectory: base)
            let events = OrderedHooks()
            stub.setAttemptRegistrationHandler { _, _ in events.record("registered") }
            stub.setProgressHandler { _, _, _ in events.record("progress") }
            stub.reportOnNextAnswer(.indeterminate(bytesWritten: 10))
            let url = try #require(URL(string: Self.enclosureURL))

            _ = try await DownloadTaskIdentity.$currentGUID.withValue("guid-1") {
                try await stub.transport(url)
            }

            #expect(events.values == ["registered", "progress"])
        }
    }

    @Test func anAdoptedTaskCarriesItsIdentifierIntoProgressGating() async throws {
        try await withTemporaryBaseAsync { base in
            let manager = try makeManager(base: base)
            manager.adopt(
                inFlightAttempts: [DownloadAttemptIdentity(taskIdentifier: 17, guid: "guid-1")])

            manager.handleProgress(
                taskIdentifier: 16, guid: "guid-1",
                progress: .indeterminate(bytesWritten: 10))
            #expect(manager.states["guid-1"] == .downloading(.waiting))

            manager.handleProgress(
                taskIdentifier: 17, guid: "guid-1",
                progress: .indeterminate(bytesWritten: 10))
            #expect(manager.states["guid-1"] == .downloading(.indeterminate(bytesWritten: 10)))
        }
    }

    /// A registration can only ever describe a transfer this process started.
    ///
    /// An adopted attempt already carries the identifier the session gave it;
    /// letting a later registration re-point it would hand its progress to
    /// another task and leave the real one unreachable.
    @Test func aRegistrationCannotRepointAnAdoptedAttempt() async throws {
        try await withTemporaryBaseAsync { base in
            let manager = try makeManager(base: base)
            manager.adopt(
                inFlightAttempts: [DownloadAttemptIdentity(taskIdentifier: 5, guid: "guid-1")])

            manager.registerAttempt(taskIdentifier: 6, forGUID: "guid-1")

            manager.handleProgress(
                taskIdentifier: 6, guid: "guid-1", progress: .indeterminate(bytesWritten: 10))
            #expect(manager.states["guid-1"] == .downloading(.waiting))

            manager.handleProgress(
                taskIdentifier: 5, guid: "guid-1", progress: .indeterminate(bytesWritten: 10))
            #expect(manager.states["guid-1"] == .downloading(.indeterminate(bytesWritten: 10)))
        }
    }

    /// A guid resolved by an earlier completion is adoptable again once a new
    /// attempt registers — otherwise a retry started after a relaunch delivery
    /// would be refused by `adopt` and its row would sit idle mid-transfer.
    @Test func registeringAFreshAttemptClearsTheResolvedGUIDMarker() async throws {
        try await withTemporaryBaseAsync { base in
            let manager = try makeManager(base: base)
            await manager.handleCompletion(.failure(StubTransportError.offline), forGUID: "guid-1")
            try #require(manager.resolvedGUIDs.contains("guid-1"))

            _ = try beginAttempt(on: manager, taskIdentifier: 4)

            #expect(!manager.resolvedGUIDs.contains("guid-1"))
        }
    }

    @Test func unregisteredAndRetiredAttemptsDropProgress() async throws {
        try await withTemporaryBaseAsync { base in
            let manager = try makeManager(base: base)
            manager.states["guid-1"] = .downloading(.waiting)
            manager.handleProgress(
                taskIdentifier: 1, guid: "guid-1",
                progress: .indeterminate(bytesWritten: 10))
            #expect(manager.states["guid-1"] == .downloading(.waiting))

            // claimed but not yet registered — the window between claiming
            // ownership and `registerStart`, where the attempt has no task
            // identifier for a callback to match
            let claimed = try #require(manager.claimOwnership(of: "guid-1"))
            manager.handleProgress(
                taskIdentifier: 1, guid: "guid-1",
                progress: .indeterminate(bytesWritten: 10))
            #expect(manager.states["guid-1"] == .downloading(.waiting))
            #expect(manager.releaseOwnership(of: "guid-1", heldBy: claimed))

            let token = try beginAttempt(on: manager)
            #expect(manager.releaseOwnership(of: "guid-1", heldBy: token))
            manager.handleProgress(
                taskIdentifier: 1, guid: "guid-1",
                progress: .indeterminate(bytesWritten: 10))
            #expect(manager.states["guid-1"] == .downloading(.waiting))
        }
    }

    @Test func everyProgressPayloadSuppressesADuplicateDownload() async throws {
        try await withTemporaryBaseAsync { base in
            let context = try makeContext()
            let episode = try makeEpisode(in: context)
            let stub = DownloadTransportStub(stagingDirectory: base)
            let manager = DownloadManager(
                context: context, store: EpisodeStore(baseDirectory: base), transport: stub.transport)

            manager.states[episode.guid] = .downloading(.waiting)
            try await manager.download(episode)
            manager.states[episode.guid] = .downloading(.indeterminate(bytesWritten: 10))
            try await manager.download(episode)
            manager.states[episode.guid] = .downloading(.fraction(bytesWritten: 10, value: 0.5))
            try await manager.download(episode)

            #expect(stub.requestedURLStrings.isEmpty)
        }
    }

    @Test func terminalStatesRejectDelayedProgress() async throws {
        try await withTemporaryBaseAsync { base in
            let manager = try makeManager(base: base)

            var token = try beginAttempt(on: manager, taskIdentifier: 1)
            #expect(manager.releaseOwnership(of: "guid-1", heldBy: token))
            manager.states["guid-1"] = nil
            manager.handleProgress(
                taskIdentifier: 1, guid: "guid-1",
                progress: .indeterminate(bytesWritten: 10))
            #expect(manager.states["guid-1"] == nil)

            token = try beginAttempt(on: manager, taskIdentifier: 2)
            #expect(manager.releaseOwnership(of: "guid-1", heldBy: token))
            manager.states["guid-1"] = .failed(message: "failed")
            manager.handleProgress(
                taskIdentifier: 2, guid: "guid-1",
                progress: .indeterminate(bytesWritten: 10))
            #expect(manager.states["guid-1"] == .failed(message: "failed"))

            token = try beginAttempt(on: manager, taskIdentifier: 3)
            #expect(manager.releaseOwnership(of: "guid-1", heldBy: token))
            manager.states["guid-1"] = nil
            manager.handleProgress(
                taskIdentifier: 3, guid: "guid-1",
                progress: .indeterminate(bytesWritten: 10))
            #expect(manager.states["guid-1"] == nil)
        }
    }

    @Test func eachTerminalOutcomeRetiresItsExactAttempt() async throws {
        try await withTemporaryBaseAsync { base in
            let successContext = try makeContext()
            let successEpisode = try makeEpisode(in: successContext)
            let successStub = DownloadTransportStub(stagingDirectory: base)
            let successManager = DownloadManager(
                context: successContext, store: EpisodeStore(baseDirectory: base),
                transport: successStub.transport)
            try await successManager.download(successEpisode)
            #expect(successManager.attempts["guid-1"] == nil)

            let failureContext = try makeContext()
            let failureEpisode = try makeEpisode(in: failureContext)
            let failureManager = DownloadManager(
                context: failureContext, store: EpisodeStore(baseDirectory: base),
                transport: failingFileTransport())
            await #expect(throws: StubTransportError.offline) {
                try await failureManager.download(failureEpisode)
            }
            #expect(failureManager.attempts["guid-1"] == nil)

            let cancellationContext = try makeContext()
            let cancellationEpisode = try makeEpisode(in: cancellationContext)
            let cancellationStub = DownloadTransportStub(stagingDirectory: base)
            let cancellationManager = DownloadManager(
                context: cancellationContext, store: EpisodeStore(baseDirectory: base),
                transport: cancellationStub.transport)
            let cancellation = Task { try await cancellationManager.download(cancellationEpisode) }
            cancellationStub.whenAnswering { cancellation.cancel() }
            await #expect(throws: CancellationError.self) { try await cancellation.value }
            #expect(cancellationManager.attempts["guid-1"] == nil)
        }
    }

    /// Byte callbacks arrive many times a second, and every published state
    /// re-evaluates both download screens, so a report that would draw the same
    /// row is recorded on the attempt without being published.
    @Test func progressThatWouldRedrawTheSameRowIsNotPublished() throws {
        try withTemporaryBase { base in
            let manager = try makeManager(base: base)
            _ = try beginAttempt(on: manager, taskIdentifier: 1)
            let half = DownloadProgress.fraction(bytesWritten: 500, value: 0.5)
            let nudged = DownloadProgress.fraction(bytesWritten: 502, value: 0.502)

            manager.handleProgress(taskIdentifier: 1, guid: "guid-1", progress: half)
            #expect(manager.states["guid-1"] == .downloading(half))

            // the same whole percent: the attempt advances, the row does not
            manager.handleProgress(taskIdentifier: 1, guid: "guid-1", progress: nudged)
            #expect(manager.states["guid-1"] == .downloading(half))
            #expect(manager.attempts["guid-1"]?.progress == nudged)

            // and a later report behind the unpublished one is still refused
            manager.handleProgress(
                taskIdentifier: 1, guid: "guid-1",
                progress: .fraction(bytesWritten: 501, value: 0.501))
            #expect(manager.attempts["guid-1"]?.progress == nudged)

            let stepped = DownloadProgress.fraction(bytesWritten: 510, value: 0.51)
            manager.handleProgress(taskIdentifier: 1, guid: "guid-1", progress: stepped)
            #expect(manager.states["guid-1"] == .downloading(stepped))
        }
    }

    @Test func anOldTaskCannotUpdateARetry() async throws {
        try await withTemporaryBaseAsync { base in
            let manager = try makeManager(base: base)
            let oldToken = try beginAttempt(on: manager, taskIdentifier: 1)
            #expect(manager.releaseOwnership(of: "guid-1", heldBy: oldToken))
            _ = try beginAttempt(on: manager, taskIdentifier: 2)

            manager.handleProgress(
                taskIdentifier: 1, guid: "guid-1",
                progress: .fraction(bytesWritten: 90, value: 0.9))
            #expect(manager.states["guid-1"] == .downloading(.waiting))

            manager.handleProgress(
                taskIdentifier: 2, guid: "guid-1",
                progress: .fraction(bytesWritten: 20, value: 0.2))
            #expect(manager.states["guid-1"] == .downloading(.fraction(bytesWritten: 20, value: 0.2)))
        }
    }
}

private struct RecordedProgress: Equatable {
    let taskIdentifier: Int
    let guid: String
    let progress: DownloadProgress
}

private final class RecordedProgressEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [RecordedProgress] = []

    var values: [RecordedProgress] { lock.withLock { events } }

    func record(taskIdentifier: Int, guid: String, progress: DownloadProgress) {
        lock.withLock {
            events.append(RecordedProgress(taskIdentifier: taskIdentifier, guid: guid, progress: progress))
        }
    }
}

private final class OrderedHooks: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []

    var values: [String] { lock.withLock { events } }

    func record(_ event: String) {
        lock.withLock { events.append(event) }
    }
}
