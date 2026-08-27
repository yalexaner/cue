import Foundation
import Testing

@testable import cue

/// The stalled phase: when the deadline writes it, when it must not, and what
/// resuming does.
@MainActor
struct DownloadManagerStallTests {
    @Test func anIdleTransferIsMarkedStalledAndResumingPublishesImmediately() async throws {
        try await withTemporaryBaseAsync { base in
            let clock = ManualDownloadClock()
            let manager = try makeProgressManager(base: base, clock: clock)
            let token = try beginProgressAttempt(on: manager)
            manager.handleProgress(
                taskIdentifier: 1, guid: "guid-1",
                progress: .fraction(bytesWritten: 500, expectedBytes: 1000))
            let generation = try #require(manager.attempts["guid-1"]?.stallGeneration)

            clock.advance(by: DownloadPacing.stallThreshold)
            manager.markStalled(forGUID: "guid-1", heldBy: token, generation: generation)
            #expect(
                manager.states["guid-1"]
                    == .downloading(.stalled(bytesWritten: 500, expectedBytes: 1000)))

            // resuming is a lifecycle transition, so it is published at once
            // rather than waiting out a throttle interval
            manager.handleProgress(
                taskIdentifier: 1, guid: "guid-1",
                progress: .fraction(bytesWritten: 600, expectedBytes: 1000))
            #expect(manager.states["guid-1"]?.isDownloading == true)
            #expect(manager.states["guid-1"]?.progressPhase == .fraction)
            #expect(manager.attempts["guid-1"]?.progress.bytesWritten == 600)
        }
    }

    /// `handleProgress` accepts a report whose byte count merely equals the one
    /// before it, so refreshing the deadline on every accepted report would
    /// postpone stalling for the life of a transfer that has stopped moving.
    @Test func equalByteReportsDoNotDeferTheDeadline() async throws {
        try await withTemporaryBaseAsync { base in
            let clock = ManualDownloadClock()
            let manager = try makeProgressManager(base: base, clock: clock)
            let token = try beginProgressAttempt(on: manager)
            manager.handleProgress(
                taskIdentifier: 1, guid: "guid-1",
                progress: .fraction(bytesWritten: 500, expectedBytes: 1000))
            let generation = try #require(manager.attempts["guid-1"]?.stallGeneration)

            clock.advance(by: DownloadPacing.stallThreshold)
            // a corrected total arrives at the same byte count: accepted, but
            // it is not movement
            manager.handleProgress(
                taskIdentifier: 1, guid: "guid-1",
                progress: .fraction(bytesWritten: 500, expectedBytes: 2000))
            #expect(manager.attempts["guid-1"]?.stallGeneration == generation)

            manager.markStalled(forGUID: "guid-1", heldBy: token, generation: generation)
            #expect(manager.states["guid-1"]?.progressPhase == .stalled)
        }
    }

    /// The armed deadline task itself, not only `markStalled`'s body.
    ///
    /// Every other test in this suite calls `markStalled` directly, so the
    /// wiring between arming and firing — the captured token, the captured
    /// generation, the duration asked of the clock and the call itself — is
    /// covered by nothing: delete the `self?.markStalled(…)` line and no
    /// transfer ever reports stalled while the rest of this file stays green.
    @Test func theArmedDeadlineFiresAndMarksTheTransferStalled() async throws {
        try await withTemporaryBaseAsync { base in
            let clock = ManualDownloadClock()
            let manager = try makeProgressManager(base: base, clock: clock)
            _ = try beginProgressAttempt(on: manager)
            manager.handleProgress(
                taskIdentifier: 1, guid: "guid-1",
                progress: .fraction(bytesWritten: 500, expectedBytes: 1000))

            await yieldUntil { clock.requestedSleeps.contains(DownloadPacing.stallThreshold) }
            #expect(clock.requestedSleeps.contains(DownloadPacing.stallThreshold))

            clock.advance(by: DownloadPacing.stallThreshold)
            await wake(clock) { manager.states["guid-1"]?.progressPhase == .stalled }

            #expect(
                manager.states["guid-1"]
                    == .downloading(.stalled(bytesWritten: 500, expectedBytes: 1000)))
        }
    }

    /// The scenario the phase exists for: the slot was taken, the connection
    /// answered nothing, and no byte ever arrived.
    ///
    /// `publishConnecting` arms the deadline *before* its `guard case .queued`
    /// return, so an uncontended transfer — published `.connecting`, never
    /// `.queued` — is armed only because of that statement ordering. Move the
    /// arming below the guard, which reads like a harmless cleanup, and this is
    /// the transfer that shows "Connecting…" forever.
    @Test func aConnectionThatNeverDeliversAByteReachesStalled() async throws {
        try await withTemporaryBaseAsync { base in
            let clock = ManualDownloadClock()
            let manager = try makeProgressManager(base: base, clock: clock)
            _ = try beginProgressAttempt(on: manager)

            manager.publishConnecting(forGUID: "guid-1")

            clock.advance(by: DownloadPacing.stallThreshold)
            await wake(clock) { manager.states["guid-1"]?.progressPhase == .stalled }

            #expect(
                manager.states["guid-1"]
                    == .downloading(.stalled(bytesWritten: 0, expectedBytes: nil)))
        }
    }

    /// An adopted transfer is the one the diagnostics step cares most about —
    /// it survived a relaunch — and it must be able to reach stalled too.
    /// `adopt` publishes `.connecting` without going through the live route's
    /// `publishConnecting`, so it has to arm the deadline itself.
    @Test func anAdoptedTransferThatNeverMovesReachesStalled() async throws {
        try await withTemporaryBaseAsync { base in
            let clock = ManualDownloadClock()
            let manager = try makeProgressManager(base: base, clock: clock)

            manager.adopt(inFlightAttempts: [
                DownloadAttemptIdentity(taskIdentifier: 7, guid: "guid-1")
            ])
            #expect(manager.states["guid-1"] == .downloading(.connecting))

            clock.advance(by: DownloadPacing.stallThreshold)
            await wake(clock) { manager.states["guid-1"]?.progressPhase == .stalled }

            #expect(manager.states["guid-1"]?.progressPhase == .stalled)
        }
    }

    /// Leaving `.stalled` is a resume, and a resume needs movement.
    ///
    /// `markStalled` has already cleared the deadline and only a strict increase
    /// arms a new one, so un-stalling on a report that carries no new bytes —
    /// a corrected total at the same byte count — would put the row back to
    /// "downloading" with nothing left that could ever mark it stalled again.
    @Test func anEqualByteReportDoesNotUnstallTheTransfer() async throws {
        try await withTemporaryBaseAsync { base in
            let clock = ManualDownloadClock()
            let manager = try makeProgressManager(base: base, clock: clock)
            let token = try beginProgressAttempt(on: manager)
            manager.handleProgress(
                taskIdentifier: 1, guid: "guid-1",
                progress: .fraction(bytesWritten: 500, expectedBytes: 1000))
            let generation = try #require(manager.attempts["guid-1"]?.stallGeneration)

            clock.advance(by: DownloadPacing.stallThreshold)
            manager.markStalled(forGUID: "guid-1", heldBy: token, generation: generation)
            try #require(manager.states["guid-1"]?.progressPhase == .stalled)

            // accepted by `handleProgress`, but it is not movement
            manager.handleProgress(
                taskIdentifier: 1, guid: "guid-1",
                progress: .fraction(bytesWritten: 500, expectedBytes: 2000))

            #expect(manager.states["guid-1"]?.progressPhase == .stalled)

            // a real byte does resume it
            manager.handleProgress(
                taskIdentifier: 1, guid: "guid-1",
                progress: .fraction(bytesWritten: 501, expectedBytes: 2000))
            #expect(manager.states["guid-1"]?.progressPhase == .fraction)
        }
    }

    /// A rescheduled deadline shares its predecessor's token, so the token alone
    /// would let a task armed thirty seconds ago mark fresh progress stalled.
    @Test func aStaleDeadlineGenerationIsIgnored() async throws {
        try await withTemporaryBaseAsync { base in
            let clock = ManualDownloadClock()
            let manager = try makeProgressManager(base: base, clock: clock)
            let token = try beginProgressAttempt(on: manager)
            manager.handleProgress(
                taskIdentifier: 1, guid: "guid-1",
                progress: .fraction(bytesWritten: 100, expectedBytes: 1000))
            let stale = try #require(manager.attempts["guid-1"]?.stallGeneration)

            clock.advance(by: DownloadPacing.stallThreshold)
            manager.handleProgress(
                taskIdentifier: 1, guid: "guid-1",
                progress: .fraction(bytesWritten: 900, expectedBytes: 1000))
            #expect(manager.attempts["guid-1"]?.stallGeneration != stale)

            manager.markStalled(forGUID: "guid-1", heldBy: token, generation: stale)
            #expect(manager.states["guid-1"]?.progressPhase == .fraction)
        }
    }

    @Test func aDeadlineFromARetiredAttemptWritesNothing() async throws {
        try await withTemporaryBaseAsync { base in
            let clock = ManualDownloadClock()
            let manager = try makeProgressManager(base: base, clock: clock)
            let token = try beginProgressAttempt(on: manager)
            manager.handleProgress(
                taskIdentifier: 1, guid: "guid-1",
                progress: .fraction(bytesWritten: 500, expectedBytes: 1000))
            let generation = try #require(manager.attempts["guid-1"]?.stallGeneration)

            #expect(manager.releaseOwnership(of: "guid-1", heldBy: token))
            manager.states["guid-1"] = nil
            clock.advance(by: DownloadPacing.stallThreshold)
            manager.markStalled(forGUID: "guid-1", heldBy: token, generation: generation)

            #expect(manager.states["guid-1"] == nil)
        }
    }

    /// The reading is checked again when the deadline fires: a transfer that
    /// moved inside the window is not stalled, whatever the task believed.
    @Test func aDeadlineThatFiresEarlyMarksNothing() async throws {
        try await withTemporaryBaseAsync { base in
            let clock = ManualDownloadClock()
            let manager = try makeProgressManager(base: base, clock: clock)
            let token = try beginProgressAttempt(on: manager)
            manager.handleProgress(
                taskIdentifier: 1, guid: "guid-1",
                progress: .fraction(bytesWritten: 500, expectedBytes: 1000))
            let generation = try #require(manager.attempts["guid-1"]?.stallGeneration)

            clock.advance(by: DownloadPacing.stallThreshold - 1)
            manager.markStalled(forGUID: "guid-1", heldBy: token, generation: generation)

            #expect(manager.states["guid-1"]?.progressPhase == .fraction)
        }
    }

    /// Once the file is being placed there is nothing left to stall.
    @Test func finalizingIsNeverOverwrittenByADeadline() async throws {
        try await withTemporaryBaseAsync { base in
            let clock = ManualDownloadClock()
            let manager = try makeProgressManager(base: base, clock: clock)
            let token = try beginProgressAttempt(on: manager)
            manager.handleProgress(
                taskIdentifier: 1, guid: "guid-1",
                progress: .fraction(bytesWritten: 1000, expectedBytes: 1000))
            let generation = try #require(manager.attempts["guid-1"]?.stallGeneration)
            manager.publishFinalizing(forGUID: "guid-1", heldBy: token)
            #expect(manager.states["guid-1"] == .downloading(.finalizing(bytesWritten: 1000)))

            clock.advance(by: DownloadPacing.stallThreshold)
            manager.markStalled(forGUID: "guid-1", heldBy: token, generation: generation)

            #expect(manager.states["guid-1"] == .downloading(.finalizing(bytesWritten: 1000)))
        }
    }

    /// A byte report arriving behind the finalizing transition must not reopen
    /// a transfer whose file is already being placed.
    @Test func aLateByteReportDoesNotReopenFinalizing() async throws {
        try await withTemporaryBaseAsync { base in
            let clock = ManualDownloadClock()
            let manager = try makeProgressManager(base: base, clock: clock)
            let token = try beginProgressAttempt(on: manager)
            manager.handleProgress(
                taskIdentifier: 1, guid: "guid-1",
                progress: .fraction(bytesWritten: 1000, expectedBytes: 1000))
            manager.publishFinalizing(forGUID: "guid-1", heldBy: token)

            manager.handleProgress(
                taskIdentifier: 1, guid: "guid-1",
                progress: .fraction(bytesWritten: 1000, expectedBytes: 1000))

            #expect(manager.states["guid-1"] == .downloading(.finalizing(bytesWritten: 1000)))
        }
    }

    /// The phase reaches a real transfer, not only a direct call.
    ///
    /// Every other case here drives `publishFinalizing` by hand, which is
    /// assertable without waiting but covers neither call site: delete the one
    /// inside `consumeDelivered` and each of them still passes while no transfer
    /// ever shows the window between the last byte and the file landing — the
    /// window a device failure was actually reported in.
    @Test func aRealTransferPublishesFinalizingBeforeTheFileLands() async throws {
        try await withTemporaryBaseAsync { base in
            let context = try makeContext()
            let episode = try makeProgressEpisode(in: context)
            let gate = GatedFileTransport(stagingDirectory: base)
            let manager = DownloadManager(
                context: context, store: EpisodeStore(baseDirectory: base),
                transport: gate.transport, cancellationRequest: gate.cancellationRequest)

            let running = Task { try await manager.download(episode) }
            await yieldUntil { gate.callCount == 1 }
            gate.open()

            // observable because `finishDownload` suspends on the asset read
            await yieldUntil { manager.states["guid-1"]?.progressPhase == .finalizing }
            #expect(manager.states["guid-1"]?.progressPhase == .finalizing)

            try await running.value
            #expect(episode.localFilename != nil)
        }
    }

    /// A deadline that wakes before its interval really elapsed must re-arm.
    ///
    /// The entry is cleared on the way into `markStalled` and only a strict byte
    /// increase arms a new one, so returning would leave a transfer that has
    /// genuinely stopped unable to be marked stalled for the rest of its life —
    /// the row would go on showing its last byte count until the resource
    /// timeout or the user. The sleep and the reading are taken across a
    /// suspension and cannot be assumed to agree: the production sleep does not
    /// run while the device is asleep, and the uptime reading does not advance
    /// then either, but nothing guarantees they move together.
    @Test func aDeadlineThatWakesEarlyReArmsForTheRemainder() async throws {
        try await withTemporaryBaseAsync { base in
            let clock = ManualDownloadClock()
            let manager = try makeProgressManager(base: base, clock: clock)
            let token = try beginProgressAttempt(on: manager)
            manager.handleProgress(
                taskIdentifier: 1, guid: "guid-1",
                progress: .fraction(bytesWritten: 500, expectedBytes: 1000))
            let generation = try #require(manager.attempts["guid-1"]?.stallGeneration)
            // that deadline has to be parked before the re-arming below, or the
            // two are simply two tasks racing to reach `sleep(for:)`: the
            // re-arming *cancels* this one, and a cancelled task's remaining run
            // is not ordered against the fresh one, so `requestedSleeps` would
            // record them in either order
            await yieldUntil { clock.pendingSleepCount == 1 }

            // woken having measured only a quarter of the interval
            clock.advance(by: 7)
            manager.markStalled(forGUID: "guid-1", heldBy: token, generation: generation)
            #expect(manager.states["guid-1"]?.progressPhase == .fraction)

            // re-armed for what is left, under a fresh generation
            #expect(manager.attempts["guid-1"]?.stallGeneration == generation + 1)
            await yieldUntil { clock.requestedSleeps.contains(DownloadPacing.stallThreshold - 7) }
            #expect(clock.requestedSleeps == [DownloadPacing.stallThreshold, DownloadPacing.stallThreshold - 7])

            // and the re-armed deadline still stalls the transfer
            clock.advance(by: DownloadPacing.stallThreshold - 7)
            await wake(clock) { manager.states["guid-1"]?.progressPhase == .stalled }
            #expect(
                manager.states["guid-1"]
                    == .downloading(.stalled(bytesWritten: 500, expectedBytes: 1000)))
        }
    }
}
