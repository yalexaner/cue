import Foundation
import Testing

@testable import cue

/// What a refused seek must leave behind when the session it invalidated has
/// already been *closed*.
///
/// Split out of `PlaybackSeekBoundaryTests.swift` for the 400-line file limit;
/// that suite covers the same pre-completion window while a session is still
/// live. `withRecordingEngine`, `SessionEventLog` and `playerSeconds` live in
/// `PlaybackSessionEventTests.swift` and are shared rather than re-declared.
@MainActor
struct PlaybackSeekWithdrawalTests {
    /// The same window, with the session already closed when the refusal
    /// arrives. `stopPlaying()` bounded it at the target — the one value that
    /// is not an inverted row — so nothing is live to reopen and the log
    /// cannot take that bound back: the correction is a later zero-length row
    /// at the real playhead, which is what the next launch resumes from.
    @Test func aSeekRefusedAfterTheSessionClosedCorrectsThePosition() async throws {
        try await withRecordingEngine { engine, events, episode, store in
            try engine.play(episode, store: store)
            engine.handlePeriodicTime(playerSeconds(10), generation: engine.loadGeneration)
            _ = events.drain()

            engine.seek(to: 70)
            engine.pause()
            try engine.resumeLoaded()
            #expect(events.drain() == [.stopped(position: 10), .started(guid: episode.guid, position: 70, rate: 1)])

            // the close bounds the session at the target, the one value that is
            // not an inverted row — and the one the refusal invalidates
            engine.pause()
            #expect(events.drain() == [.stopped(position: 70)])

            engine.handleSeekCompletion(
                finished: false, target: 70,
                seekGeneration: engine.seekGeneration, loadGeneration: engine.loadGeneration
            )

            #expect(engine.elapsed == 10)
            #expect(events.drain() == [.correctedPosition(guid: episode.guid, position: 10, rate: 1.0)])
        }
    }

    /// The same shape reached through a failure rather than a pause. The item
    /// fails while the seek is still pending, so its completion is dropped by
    /// the generation guard and can never withdraw the target the session was
    /// closed at. Retiring the window has to make that correction instead —
    /// without it `Episode.currentPosition` answers 70 for content the player
    /// never reached and the next play resumes a minute ahead of what was heard.
    @Test func anItemFailureAfterTheSessionOpenedAtItsTargetCorrectsThePosition() async throws {
        try await withRecordingEngine { engine, events, episode, store in
            try engine.play(episode, store: store)
            engine.handlePeriodicTime(playerSeconds(10), generation: engine.loadGeneration)
            engine.seek(to: 70)
            engine.pause()
            try engine.resumeLoaded()
            _ = events.drain()

            engine.handleItemStatus(
                .failed, itemDuration: nil, error: nil, generation: engine.loadGeneration
            )

            #expect(engine.elapsed == 10)
            let corrected = SessionEvent.correctedPosition(guid: episode.guid, position: 10, rate: 1)
            #expect(events.drain() == [.stopped(position: 70), corrected])
        }
    }

    /// The file-mutation path, which `DownloadManager` invokes on a delete or a
    /// re-download finish: it too retires the window with the completion still
    /// outstanding, and its correction must name the *outgoing* episode.
    @Test func unloadingAfterTheSessionOpenedAtItsTargetCorrectsThePosition() async throws {
        try await withRecordingEngine { engine, events, episode, store in
            try engine.play(episode, store: store)
            engine.handlePeriodicTime(playerSeconds(10), generation: engine.loadGeneration)
            engine.seek(to: 70)
            engine.pause()
            try engine.resumeLoaded()
            _ = events.drain()

            engine.unload(ifGUID: episode.guid)

            let corrected = SessionEvent.correctedPosition(guid: episode.guid, position: 10, rate: 1)
            #expect(events.drain() == [.stopped(position: 70), corrected])
        }
    }

    /// The same shape reached through a *second seek*. Starting one supersedes
    /// the outstanding completion by generation, so that completion — the only
    /// thing that would withdraw its target — never arrives, exactly as it
    /// never arrives after a failure, an unload or a replacing load. Without
    /// the refusal the new seek performs on its behalf, the closed row keeps a
    /// bound the player never reached and the next launch resumes 60s ahead.
    @Test func aSecondSeekAfterTheSessionClosedAtItsTargetCorrectsThePosition() async throws {
        try await withRecordingEngine { engine, events, episode, store in
            try engine.play(episode, store: store)
            engine.handlePeriodicTime(playerSeconds(10), generation: engine.loadGeneration)
            engine.seek(to: 70)
            engine.pause()
            try engine.resumeLoaded()
            engine.pause()
            _ = events.drain()

            // paused, so nothing is live to reopen — the correction is a later row
            engine.seek(to: 50)

            let corrected = SessionEvent.correctedPosition(guid: episode.guid, position: 10, rate: 1)
            #expect(events.drain() == [corrected])
        }
    }

    /// The live case needs no correction of its own: the second seek's landed
    /// boundary closes the session opened at the first target and reopens where
    /// the player really went, so correcting here too would close the reopened
    /// session at the position it starts behind.
    @Test func aSecondSeekWhilePlayingLeavesTheCorrectionToItsLandedBoundary() async throws {
        try await withRecordingEngine { engine, events, episode, store in
            try engine.play(episode, store: store)
            engine.handlePeriodicTime(playerSeconds(10), generation: engine.loadGeneration)
            engine.seek(to: 70)
            engine.pause()
            try engine.resumeLoaded()
            _ = events.drain()

            engine.seek(to: 50)
            #expect(events.drain().isEmpty)

            engine.handleSeekCompletion(
                finished: true, target: 50,
                seekGeneration: engine.seekGeneration, loadGeneration: engine.loadGeneration
            )
            #expect(events.drain() == [.seeked(from: 70, target: 50)])
        }
    }

    /// A seek the player confirmed needs no correction: the session closed at
    /// the target really was closed where the player then was.
    @Test func aSeekThatLandsAfterTheSessionClosedCorrectsNothing() async throws {
        try await withRecordingEngine { engine, events, episode, store in
            try engine.play(episode, store: store)
            engine.handlePeriodicTime(playerSeconds(10), generation: engine.loadGeneration)
            engine.seek(to: 70)
            engine.pause()
            try engine.resumeLoaded()
            engine.pause()
            _ = events.drain()

            engine.handleSeekCompletion(
                finished: true, target: 70,
                seekGeneration: engine.seekGeneration, loadGeneration: engine.loadGeneration
            )

            #expect(events.drain().isEmpty)
        }
    }
}
