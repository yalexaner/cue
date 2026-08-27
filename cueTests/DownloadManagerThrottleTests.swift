import Foundation
import Testing

@testable import cue

/// The publication throttle: what is deferred, what bypasses it, and what a
/// deferred publication must prove before it writes.
@MainActor
struct DownloadManagerThrottleTests {
    /// The row shows the byte count now, so an indeterminate transfer is no
    /// longer a bare spinner that never redraws.
    @Test func indeterminateByteUpdatesReachTheRow() async throws {
        try await withTemporaryBaseAsync { base in
            let clock = ManualDownloadClock()
            let manager = try makeProgressManager(base: base, clock: clock)
            _ = try beginProgressAttempt(on: manager)

            manager.handleProgress(
                taskIdentifier: 1, guid: "guid-1", progress: .indeterminate(bytesWritten: 10))
            #expect(manager.states["guid-1"] == .downloading(.indeterminate(bytesWritten: 10)))

            clock.advance(by: DownloadPacing.publishInterval)
            manager.handleProgress(
                taskIdentifier: 1, guid: "guid-1", progress: .indeterminate(bytesWritten: 4096))
            #expect(manager.states["guid-1"]?.progressPhase == .indeterminate)
            #expect(manager.publishedProgress(forGUID: "guid-1")?.bytesWritten == 4096)
        }
    }

    /// The armed publication task itself, not only `flushPendingProgress`.
    ///
    /// Every other test here calls that body directly, so nothing covers the
    /// wiring in between — the captured token and generation, the computed
    /// delay, and the call. Delete the `self?.flushPendingProgress(…)` line and
    /// a transfer's row freezes on its first published report for the whole
    /// download while the rest of this file stays green.
    @Test func theArmedTrailingPublicationFiresAndWritesTheNewestReport() async throws {
        try await withTemporaryBaseAsync { base in
            let clock = ManualDownloadClock()
            let manager = try makeProgressManager(base: base, clock: clock)
            _ = try beginProgressAttempt(on: manager)

            manager.handleProgress(
                taskIdentifier: 1, guid: "guid-1",
                progress: .fraction(bytesWritten: 100, expectedBytes: 1000))
            // inside the interval, so this one is deferred rather than published
            manager.handleProgress(
                taskIdentifier: 1, guid: "guid-1",
                progress: .fraction(bytesWritten: 900, expectedBytes: 1000))
            #expect(manager.publishedProgress(forGUID: "guid-1")?.bytesWritten == 100)

            #expect(manager.pendingPublications["guid-1"] != nil)
            clock.advance(by: DownloadPacing.publishInterval)
            await wake(clock) { manager.publishedProgress(forGUID: "guid-1")?.bytesWritten == 900 }

            #expect(manager.publishedProgress(forGUID: "guid-1")?.bytesWritten == 900)
            #expect(manager.pendingPublications["guid-1"] == nil)
        }
    }

    @Test func aDeferredPublicationDeliversTheNewestReport() async throws {
        try await withTemporaryBaseAsync { base in
            let clock = ManualDownloadClock()
            let manager = try makeProgressManager(base: base, clock: clock)
            let token = try beginProgressAttempt(on: manager)

            manager.handleProgress(
                taskIdentifier: 1, guid: "guid-1",
                progress: .fraction(bytesWritten: 100, expectedBytes: 1000))
            let generation = try #require(manager.attempts["guid-1"]?.publicationGeneration)
            // both inside the interval, so neither publishes on its own
            manager.handleProgress(
                taskIdentifier: 1, guid: "guid-1",
                progress: .fraction(bytesWritten: 200, expectedBytes: 1000))
            manager.handleProgress(
                taskIdentifier: 1, guid: "guid-1",
                progress: .fraction(bytesWritten: 300, expectedBytes: 1000))
            #expect(manager.publishedProgress(forGUID: "guid-1")?.bytesWritten == 100)

            clock.advance(by: DownloadPacing.publishInterval)
            manager.flushPendingProgress(forGUID: "guid-1", heldBy: token, generation: generation)

            #expect(manager.publishedProgress(forGUID: "guid-1")?.bytesWritten == 300)
        }
    }

    /// "Still downloading" is not enough: stalled is a downloading state, so a
    /// publication that had already passed its sleep would undo it.
    @Test func aDelayedPublicationAfterAStallIsDiscarded() async throws {
        try await withTemporaryBaseAsync { base in
            let clock = ManualDownloadClock()
            let manager = try makeProgressManager(base: base, clock: clock)
            let token = try beginProgressAttempt(on: manager)
            manager.handleProgress(
                taskIdentifier: 1, guid: "guid-1",
                progress: .fraction(bytesWritten: 100, expectedBytes: 1000))
            manager.handleProgress(
                taskIdentifier: 1, guid: "guid-1",
                progress: .fraction(bytesWritten: 200, expectedBytes: 1000))
            let generation = try #require(manager.attempts["guid-1"]?.publicationGeneration)

            clock.advance(by: DownloadPacing.stallThreshold)
            let stallGeneration = try #require(manager.attempts["guid-1"]?.stallGeneration)
            manager.markStalled(forGUID: "guid-1", heldBy: token, generation: stallGeneration)
            #expect(manager.states["guid-1"]?.progressPhase == .stalled)

            manager.flushPendingProgress(forGUID: "guid-1", heldBy: token, generation: generation)

            #expect(manager.states["guid-1"]?.progressPhase == .stalled)
        }
    }

    @Test func aDelayedPublicationAfterFinalizingIsDiscarded() async throws {
        try await withTemporaryBaseAsync { base in
            let clock = ManualDownloadClock()
            let manager = try makeProgressManager(base: base, clock: clock)
            let token = try beginProgressAttempt(on: manager)
            manager.handleProgress(
                taskIdentifier: 1, guid: "guid-1",
                progress: .fraction(bytesWritten: 900, expectedBytes: 1000))
            manager.handleProgress(
                taskIdentifier: 1, guid: "guid-1",
                progress: .fraction(bytesWritten: 1000, expectedBytes: 1000))
            let generation = try #require(manager.attempts["guid-1"]?.publicationGeneration)

            manager.publishFinalizing(forGUID: "guid-1", heldBy: token)
            manager.flushPendingProgress(forGUID: "guid-1", heldBy: token, generation: generation)

            #expect(manager.states["guid-1"] == .downloading(.finalizing(bytesWritten: 1000)))
        }
    }

    /// The queue reindex is a lifecycle transition too, so a publication armed
    /// before it cannot put a byte report over a corrected queue position.
    @Test func aLifecycleTransitionInvalidatesAPendingPublication() async throws {
        try await withTemporaryBaseAsync { base in
            let clock = ManualDownloadClock()
            let manager = try makeProgressManager(base: base, clock: clock)
            let token = try beginProgressAttempt(on: manager)
            manager.handleProgress(
                taskIdentifier: 1, guid: "guid-1",
                progress: .fraction(bytesWritten: 100, expectedBytes: 1000))
            manager.handleProgress(
                taskIdentifier: 1, guid: "guid-1",
                progress: .fraction(bytesWritten: 200, expectedBytes: 1000))
            let generation = try #require(manager.attempts["guid-1"]?.publicationGeneration)

            manager.invalidatePendingPublication(forGUID: "guid-1")
            #expect(manager.attempts["guid-1"]?.publicationGeneration != generation)
            manager.flushPendingProgress(forGUID: "guid-1", heldBy: token, generation: generation)

            #expect(manager.publishedProgress(forGUID: "guid-1")?.bytesWritten == 100)
        }
    }

    @Test func aDelayedPublicationForARetiredAttemptWritesNothing() async throws {
        try await withTemporaryBaseAsync { base in
            let clock = ManualDownloadClock()
            let manager = try makeProgressManager(base: base, clock: clock)
            let token = try beginProgressAttempt(on: manager)
            manager.handleProgress(
                taskIdentifier: 1, guid: "guid-1",
                progress: .fraction(bytesWritten: 100, expectedBytes: 1000))
            manager.handleProgress(
                taskIdentifier: 1, guid: "guid-1",
                progress: .fraction(bytesWritten: 200, expectedBytes: 1000))
            let generation = try #require(manager.attempts["guid-1"]?.publicationGeneration)

            #expect(manager.releaseOwnership(of: "guid-1", heldBy: token))
            manager.states["guid-1"] = nil
            manager.flushPendingProgress(forGUID: "guid-1", heldBy: token, generation: generation)

            #expect(manager.states["guid-1"] == nil)
        }
    }

    /// Retirement cancels the armed task itself, not only its generation.
    @Test func retirementCancelsTheTrailingPublication() async throws {
        try await withTemporaryBaseAsync { base in
            let clock = ManualDownloadClock()
            let manager = try makeProgressManager(base: base, clock: clock)
            let token = try beginProgressAttempt(on: manager)
            manager.handleProgress(
                taskIdentifier: 1, guid: "guid-1",
                progress: .fraction(bytesWritten: 100, expectedBytes: 1000))
            manager.handleProgress(
                taskIdentifier: 1, guid: "guid-1",
                progress: .fraction(bytesWritten: 200, expectedBytes: 1000))
            await yieldUntil { manager.pendingPublications["guid-1"] != nil }
            #expect(manager.pendingPublications["guid-1"] != nil)

            #expect(manager.releaseOwnership(of: "guid-1", heldBy: token))
            #expect(manager.pendingPublications["guid-1"] == nil)
            #expect(manager.stallDeadlines["guid-1"] == nil)

            // and releasing the parked sleeper delivers nothing, because the
            // task it belonged to was cancelled
            clock.wake()
            manager.states["guid-1"] = nil
            await Task.yield()
            #expect(manager.states["guid-1"] == nil)
        }
    }

    /// One pending publication per attempt: a second report inside the interval
    /// rides the task already armed rather than arming another.
    @Test func onlyOneTrailingPublicationIsArmedPerAttempt() async throws {
        try await withTemporaryBaseAsync { base in
            let clock = ManualDownloadClock()
            let manager = try makeProgressManager(base: base, clock: clock)
            _ = try beginProgressAttempt(on: manager)

            manager.handleProgress(
                taskIdentifier: 1, guid: "guid-1",
                progress: .fraction(bytesWritten: 100, expectedBytes: 1000))
            for bytes in stride(from: Int64(200), through: 600, by: 100) {
                manager.handleProgress(
                    taskIdentifier: 1, guid: "guid-1",
                    progress: .fraction(bytesWritten: bytes, expectedBytes: 1000))
            }
            // waited on the publication path's own sleep, not on any sleep:
            // each report also arms a stall deadline, and stopping at the first
            // entry can stop at one of those while the publication task has not
            // reached its sleep yet
            await yieldUntil {
                clock.requestedSleeps.contains { $0 <= DownloadPacing.publishInterval }
            }

            // exactly one sleep was asked for by the publication path; the
            // stall deadline's own sleeps are the threshold, not the interval
            let deferred = clock.requestedSleeps.filter { $0 <= DownloadPacing.publishInterval }
            #expect(deferred.count == 1)
        }
    }
}
