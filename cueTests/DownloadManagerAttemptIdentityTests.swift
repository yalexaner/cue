import Foundation
import SwiftData
import Testing

@testable import cue

/// Attempt identity and the stale-event rules built on it.
///
/// A progress callback applies only to the registered live attempt for its
/// guid; everything here pins which attempt owns a report and which reports
/// are refused.
@MainActor
struct DownloadManagerAttemptIdentityTests {
    @Test func anAdoptedTaskCarriesItsIdentifierIntoProgressGating() async throws {
        try await withTemporaryBaseAsync { base in
            let manager = try makeProgressManager(base: base)
            manager.adopt(
                inFlightAttempts: [DownloadAttemptIdentity(taskIdentifier: 17, guid: "guid-1")])

            manager.handleProgress(
                taskIdentifier: 16, guid: "guid-1",
                progress: .indeterminate(bytesWritten: 10))
            #expect(manager.states["guid-1"] == .downloading(.connecting))

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
            let manager = try makeProgressManager(base: base)
            manager.adopt(
                inFlightAttempts: [DownloadAttemptIdentity(taskIdentifier: 5, guid: "guid-1")])

            manager.registerAttempt(taskIdentifier: 6, forGUID: "guid-1")

            manager.handleProgress(
                taskIdentifier: 6, guid: "guid-1", progress: .indeterminate(bytesWritten: 10))
            #expect(manager.states["guid-1"] == .downloading(.connecting))

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
            let manager = try makeProgressManager(base: base)
            await manager.handleCompletion(.failure(StubTransportError.offline), forGUID: "guid-1")
            try #require(manager.resolvedGUIDs.contains("guid-1"))

            _ = try beginProgressAttempt(on: manager, taskIdentifier: 4)

            #expect(!manager.resolvedGUIDs.contains("guid-1"))
        }
    }

    @Test func unregisteredAndRetiredAttemptsDropProgress() async throws {
        try await withTemporaryBaseAsync { base in
            let manager = try makeProgressManager(base: base)
            manager.states["guid-1"] = .downloading(.connecting)
            manager.handleProgress(
                taskIdentifier: 1, guid: "guid-1",
                progress: .indeterminate(bytesWritten: 10))
            #expect(manager.states["guid-1"] == .downloading(.connecting))

            // claimed but not yet registered — the window between claiming
            // ownership and `registerStart`, where the attempt has no task
            // identifier for a callback to match
            let claimed = try #require(manager.claimOwnership(of: "guid-1"))
            manager.handleProgress(
                taskIdentifier: 1, guid: "guid-1",
                progress: .indeterminate(bytesWritten: 10))
            #expect(manager.states["guid-1"] == .downloading(.connecting))
            #expect(manager.releaseOwnership(of: "guid-1", heldBy: claimed))

            let token = try beginProgressAttempt(on: manager)
            #expect(manager.releaseOwnership(of: "guid-1", heldBy: token))
            manager.handleProgress(
                taskIdentifier: 1, guid: "guid-1",
                progress: .indeterminate(bytesWritten: 10))
            #expect(manager.states["guid-1"] == .downloading(.connecting))
        }
    }

    @Test func everyProgressPayloadSuppressesADuplicateDownload() async throws {
        try await withTemporaryBaseAsync { base in
            let context = try makeContext()
            let episode = try makeProgressEpisode(in: context)
            let stub = DownloadTransportStub(stagingDirectory: base)
            let manager = DownloadManager(
                context: context, store: EpisodeStore(baseDirectory: base), transport: stub.transport)

            manager.states[episode.guid] = .downloading(.connecting)
            try await manager.download(episode)
            manager.states[episode.guid] = .downloading(.indeterminate(bytesWritten: 10))
            try await manager.download(episode)
            manager.states[episode.guid] = .downloading(.fraction(bytesWritten: 10, expectedBytes: 20))
            try await manager.download(episode)

            #expect(stub.requestedURLStrings.isEmpty)
        }
    }

    @Test func terminalStatesRejectDelayedProgress() async throws {
        try await withTemporaryBaseAsync { base in
            let manager = try makeProgressManager(base: base)

            var token = try beginProgressAttempt(on: manager, taskIdentifier: 1)
            #expect(manager.releaseOwnership(of: "guid-1", heldBy: token))
            manager.states["guid-1"] = nil
            manager.handleProgress(
                taskIdentifier: 1, guid: "guid-1",
                progress: .indeterminate(bytesWritten: 10))
            #expect(manager.states["guid-1"] == nil)

            token = try beginProgressAttempt(on: manager, taskIdentifier: 2)
            #expect(manager.releaseOwnership(of: "guid-1", heldBy: token))
            manager.states["guid-1"] = .failed(message: "failed")
            manager.handleProgress(
                taskIdentifier: 2, guid: "guid-1",
                progress: .indeterminate(bytesWritten: 10))
            #expect(manager.states["guid-1"] == .failed(message: "failed"))

            token = try beginProgressAttempt(on: manager, taskIdentifier: 3)
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
            let successEpisode = try makeProgressEpisode(in: successContext)
            let successStub = DownloadTransportStub(stagingDirectory: base)
            let successManager = DownloadManager(
                context: successContext, store: EpisodeStore(baseDirectory: base),
                transport: successStub.transport)
            try await successManager.download(successEpisode)
            #expect(successManager.attempts["guid-1"] == nil)

            let failureContext = try makeContext()
            let failureEpisode = try makeProgressEpisode(in: failureContext)
            let failureManager = DownloadManager(
                context: failureContext, store: EpisodeStore(baseDirectory: base),
                transport: failingFileTransport())
            await #expect(throws: StubTransportError.offline) {
                try await failureManager.download(failureEpisode)
            }
            #expect(failureManager.attempts["guid-1"] == nil)

            let cancellationContext = try makeContext()
            let cancellationEpisode = try makeProgressEpisode(in: cancellationContext)
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

    @Test func anOldTaskCannotUpdateARetry() async throws {
        try await withTemporaryBaseAsync { base in
            let manager = try makeProgressManager(base: base)
            let oldToken = try beginProgressAttempt(on: manager, taskIdentifier: 1)
            #expect(manager.releaseOwnership(of: "guid-1", heldBy: oldToken))
            _ = try beginProgressAttempt(on: manager, taskIdentifier: 2)

            manager.handleProgress(
                taskIdentifier: 1, guid: "guid-1",
                progress: .fraction(bytesWritten: 90, expectedBytes: 100))
            #expect(manager.states["guid-1"] == .downloading(.connecting))

            manager.handleProgress(
                taskIdentifier: 2, guid: "guid-1",
                progress: .fraction(bytesWritten: 20, expectedBytes: 100))
            #expect(manager.states["guid-1"] == .downloading(.fraction(bytesWritten: 20, expectedBytes: 100)))
        }
    }
}
