import Foundation
import SwiftData
import Testing

@testable import cue

/// End-to-end shapes for the acceptance criteria spec §9 exists for: a real
/// `PlaybackEngine` over rejected audio, wired to a real `SessionRecorder` over
/// a real in-memory store — the `DownloadManagerPlaybackTests` precedent. The
/// emission seam and the write mapping have their own suites; what is asserted
/// here is that the two together produce the rows the spec promises.
@MainActor
struct SessionRecordingFlowTests {
    // MARK: - AC 5

    @Test
    func playPausePlayPauseLeavesTwoClosedContiguousSessions() async throws {
        try await withRecordedPlayback { engine, episode, store, context in
            try engine.play(episode, store: store)
            engine.handlePeriodicTime(playerSeconds(30), generation: engine.loadGeneration)
            engine.pause()

            try engine.play(episode, store: store)
            engine.handlePeriodicTime(playerSeconds(45), generation: engine.loadGeneration)
            engine.pause()

            let rows = try persistedSessions(in: context)
            #expect(rows.count == 2)
            #expect(rows.map(\.startPosition) == [0, 30])
            #expect(rows.map(\.endPosition) == [30, 45])
            #expect(rows.allSatisfy { $0.endedAt != nil })
            // contiguous: the reopen reads the position the close just recorded
            #expect(rows.first?.endPosition == rows.last?.startPosition)
            #expect(episode.currentPosition == 45)
        }
    }

    // MARK: - AC 6

    @Test
    func aManualSeekPreservesTheOutgoingEndAndOpensAtTheTarget() async throws {
        try await withRecordedPlayback { engine, episode, store, context in
            try engine.play(episode, store: store)
            engine.handlePeriodicTime(playerSeconds(10), generation: engine.loadGeneration)

            engine.seek(to: 50)
            // the seek's own completion, driven through its seam: until it
            // lands, periodic reports are suppressed as stale by design
            engine.handleSeekCompletion(
                finished: true,
                target: 50,
                seekGeneration: engine.seekGeneration,
                loadGeneration: engine.loadGeneration
            )
            engine.handlePeriodicTime(playerSeconds(60), generation: engine.loadGeneration)
            engine.pause()

            let rows = try persistedSessions(in: context)
            #expect(rows.count == 2)
            // the pre-seek session keeps the position the seek moved away from,
            // which is what makes step 7's revert possible
            #expect(rows.first?.startPosition == 0)
            #expect(rows.first?.endPosition == 10)
            #expect(rows.last?.startPosition == 50)
            #expect(rows.last?.endPosition == 60)
            #expect(rows.allSatisfy { $0.endedAt != nil })
        }
    }

    // MARK: - AC 12

    @Test
    func aTerminatedSessionIsClosedByTheSweepAtItsLastHeartbeat() async throws {
        try await withRecordedPlayback { engine, episode, store, context in
            try engine.play(episode, store: store)
            engine.handlePeriodicTime(playerSeconds(35), generation: engine.loadGeneration)
            engine.handleHeartbeat(playerSeconds(35), generation: engine.loadGeneration)

            // the live row is the resume position while the app is still running
            #expect(episode.currentPosition == 35)
            let live = try persistedSessions(in: context)
            #expect(live.count == 1)
            #expect(live.first?.endedAt == nil)
            #expect(live.first?.endPosition == 35)

            // a termination reaches nothing else; the next launch sweeps
            SessionRecorder(context: context).closeAbandonedSessions()

            let rows = try persistedSessions(in: context)
            #expect(rows.count == 1)
            #expect(rows.first?.endedAt != nil)
            #expect(rows.first?.endPosition == 35)
            #expect(episode.currentPosition == 35)
        }
    }

    // MARK: - Resuming a finished episode

    @Test
    func anEpisodePlayedToTheEndRestartsInsteadOfResumingAtTheEnd() async throws {
        try await withRecordedPlayback { engine, episode, store, context in
            try engine.play(episode, store: store)
            engine.handleItemEnded(generation: engine.loadGeneration)
            // the closing row derives a resume position *at* the end
            #expect(episode.currentPosition == 100)

            engine.unload(ifGUID: episode.guid)
            try engine.play(episode, store: store)

            // starting on the last frame would end the item at once, so the
            // finished episode restarts and its session opens at zero
            #expect(engine.elapsed == 0)
            let rows = try persistedSessions(in: context)
            #expect(rows.count == 2)
            #expect(rows.last?.startPosition == 0)
            #expect(rows.last?.endedAt == nil)
        }
    }

    @Test
    func anEpisodeStoppedShortOfTheEndStillResumesWhereItStopped() async throws {
        try await withRecordedPlayback { engine, episode, store, _ in
            try engine.play(episode, store: store)
            engine.handlePeriodicTime(playerSeconds(60), generation: engine.loadGeneration)
            engine.pause()

            engine.unload(ifGUID: episode.guid)
            try engine.play(episode, store: store)

            #expect(engine.elapsed == 60)
        }
    }

    /// A pause inside a seek's pre-completion window bounds its session at the
    /// target, the only value that is not an inverted row. A refusal landing
    /// after that pause therefore leaves the newest row naming a position the
    /// player never reached, with nothing live to reconcile — so the log gains
    /// a later zero-length row at the real playhead. Without it the next launch
    /// resumes at 70 rather than 10.
    @Test
    func aSeekRefusedAfterThePauseCorrectsTheResumePosition() async throws {
        try await withRecordedPlayback { engine, episode, store, context in
            try engine.play(episode, store: store)
            engine.handlePeriodicTime(playerSeconds(10), generation: engine.loadGeneration)
            engine.seek(to: 70)
            engine.pause()
            try engine.resumeLoaded()
            engine.pause()
            #expect(episode.currentPosition == 70)

            engine.handleSeekCompletion(
                finished: false,
                target: 70,
                seekGeneration: engine.seekGeneration,
                loadGeneration: engine.loadGeneration
            )

            let rows = try persistedSessions(in: context)
            #expect(rows.count == 3)
            // in open order: the pre-seek session, the one the resume opened
            // at the target, then the correction at the confirmed playhead
            #expect(rows.map(\.startPosition) == [0, 70, 10])
            #expect(rows.map(\.endPosition) == [10, 70, 10])
            #expect(rows.allSatisfy { $0.endedAt != nil })
            #expect(episode.currentPosition == 10)
        }
    }

    @Test
    func aSweepWithNothingLiveLeavesTheLogAlone() async throws {
        try await withRecordedPlayback { engine, episode, store, context in
            try engine.play(episode, store: store)
            engine.handlePeriodicTime(playerSeconds(20), generation: engine.loadGeneration)
            engine.pause()
            let closedAt = try #require(try persistedSessions(in: context).first?.endedAt)

            SessionRecorder(context: context).closeAbandonedSessions()

            let rows = try persistedSessions(in: context)
            #expect(rows.count == 1)
            #expect(rows.first?.endedAt == closedAt)
            #expect(rows.first?.endPosition == 20)
        }
    }
}

// MARK: - Helpers

/// Sessions as the *store* has them, read through a second context.
@MainActor
private func persistedSessions(in context: ModelContext) throws -> [PlaybackSession] {
    let fresh = ModelContext(context.container)
    // `startedAt` alone is not a total order: a close and its reopen are two
    // `.now` reads apart, so the tie is broken the way `Episode.currentPosition`
    // breaks it rather than left to the fetch.
    let descriptor = FetchDescriptor<PlaybackSession>(
        sortBy: [SortDescriptor(\.startedAt), SortDescriptor(\.endPosition)]
    )
    return try fresh.fetch(descriptor)
}

/// A real engine wired to a real recorder over a persisted episode — the
/// production wiring `CueApp.init()` performs, minus the app.
@MainActor
private func withRecordedPlayback(
    _ body: (PlaybackEngine, Episode, EpisodeStore, ModelContext) throws -> Void
) async throws {
    try await withTemporaryBaseAsync { base in
        let context = try makeContext()
        let episode = episode(filename: "audio.mp3")
        // a downloaded episode has had its asset measured, which is the only
        // duration allowed to decide that a stored position is the end
        episode.assetDuration = 100
        context.insert(episode)
        try context.save()

        let store = EpisodeStore(baseDirectory: base)
        try store.prepareEpisodesDirectory()
        try installRejectedAudio(named: "audio.mp3", in: store, base: base)

        let engine = PlaybackEngine()
        let recorder = SessionRecorder(context: context)
        engine.sessionEvents = { recorder.handle($0) }
        defer { engine.unload(ifGUID: episode.guid) }
        try body(engine, episode, store, context)
    }
}
