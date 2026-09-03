import AVFoundation
import Foundation
import Testing

@testable import cue

/// The seek half of the engine's session seam.
///
/// Split out of `PlaybackSessionEventTests.swift` for the 400-line file limit;
/// `withRecordingEngine`, `SessionEventLog` and `playerSeconds` still live
/// there, and `withLoadedEngine` in `PlaybackEngineTests.swift`, and all are
/// shared rather than re-declared.
@MainActor
struct PlaybackSeekBoundaryTests {
    @Test func aManualSeekWhilePlayingClosesAndReopensAtTheClampedTarget() async throws {
        try await withRecordingEngine { engine, events, episode, store in
            try engine.play(episode, store: store)
            engine.handlePeriodicTime(playerSeconds(10), generation: engine.loadGeneration)
            _ = events.drain()

            engine.seek(to: 150)
            // the pair is committed only once the player confirms the jump
            #expect(events.drain().isEmpty)
            engine.handleSeekCompletion(
                finished: true, target: 100,
                seekGeneration: engine.seekGeneration, loadGeneration: engine.loadGeneration
            )

            #expect(events.drain() == [.seeked(from: 10, target: 100)])
        }
    }

    @Test func skippingInheritsTheSeekBoundary() async throws {
        try await withRecordingEngine { engine, events, episode, store in
            try engine.play(episode, store: store)
            engine.handlePeriodicTime(playerSeconds(10), generation: engine.loadGeneration)
            _ = events.drain()

            engine.skip(by: 30)
            engine.handleSeekCompletion(
                finished: true, target: 40,
                seekGeneration: engine.seekGeneration, loadGeneration: engine.loadGeneration
            )

            #expect(events.drain() == [.seeked(from: 10, target: 40)])
        }
    }

    @Test func aSeekThatLandsWhereThePlayheadIsReportsNoBoundary() async throws {
        try await withRecordingEngine { engine, events, episode, store in
            try engine.play(episode, store: store)
            engine.handlePeriodicTime(playerSeconds(100), generation: engine.loadGeneration)
            _ = events.drain()

            // clamped back to the position it started from, so nothing moved
            engine.skip(by: 30)
            #expect(events.drain().isEmpty)
            engine.handleSeekCompletion(
                finished: true, target: 100,
                seekGeneration: engine.seekGeneration, loadGeneration: engine.loadGeneration
            )

            engine.handlePeriodicTime(playerSeconds(0), generation: engine.loadGeneration)
            engine.skip(by: -30)
            #expect(events.drain().isEmpty)
        }
    }

    @Test func aSeekWhilePausedReportsNoBoundary() async throws {
        try await withRecordingEngine { engine, events, episode, store in
            try engine.play(episode, store: store)
            engine.pause()
            _ = events.drain()

            engine.seek(to: 40)
            engine.handleSeekCompletion(
                finished: true, target: 40,
                seekGeneration: engine.seekGeneration, loadGeneration: engine.loadGeneration
            )

            #expect(events.drain().isEmpty)
        }
    }

    /// A seek the player never performed must leave no trace in a log nothing
    /// can rewrite: reported at the request, its `startPosition` sits ahead of
    /// every `endPosition` the heartbeat then writes from the original
    /// playhead, and the row ends before it begins.
    @Test func aSeekThatNeverLandsReportsNoBoundary() async throws {
        try await withRecordingEngine { engine, events, episode, store in
            try engine.play(episode, store: store)
            engine.handlePeriodicTime(playerSeconds(10), generation: engine.loadGeneration)
            _ = events.drain()

            engine.seek(to: 70)
            engine.handleSeekCompletion(
                finished: false, target: 70,
                seekGeneration: engine.seekGeneration, loadGeneration: engine.loadGeneration
            )
            #expect(events.drain().isEmpty)

            engine.handlePeriodicTime(playerSeconds(10), generation: engine.loadGeneration)
            engine.handleHeartbeat(playerSeconds(10), generation: engine.loadGeneration)
            #expect(events.drain() == [.heartbeat(position: 10)])
        }
    }

    /// A second seek before the first lands must still close the session where
    /// it really began, not at the position the first seek only guessed.
    @Test func aSupersededSeekKeepsTheOriginalOrigin() async throws {
        try await withRecordingEngine { engine, events, episode, store in
            try engine.play(episode, store: store)
            engine.handlePeriodicTime(playerSeconds(10), generation: engine.loadGeneration)
            _ = events.drain()

            engine.seek(to: 40)
            engine.seek(to: 70)
            engine.handleSeekCompletion(
                finished: true, target: 70,
                seekGeneration: engine.seekGeneration, loadGeneration: engine.loadGeneration
            )

            #expect(events.drain() == [.seeked(from: 10, target: 70)])
        }
    }

    @Test func anInternalSeekReportsNoBoundary() async throws {
        try await withRecordingEngine { engine, events, episode, store in
            try engine.play(episode, store: store)
            _ = events.drain()

            engine.seekPlayer(to: 55)

            #expect(events.drain().isEmpty)
        }
    }

    /// A pause that lands inside the pre-completion window must close the
    /// session where the player really is. `elapsed` is the target the engine
    /// published optimistically, and a seek that then fails leaves that target
    /// as an `endPosition` no later write can reach — the same inverted row the
    /// boundary itself is deferred to avoid.
    @Test func pausingDuringAPendingSeekClosesAtTheConfirmedPosition() async throws {
        try await withRecordingEngine { engine, events, episode, store in
            try engine.play(episode, store: store)
            engine.handlePeriodicTime(playerSeconds(10), generation: engine.loadGeneration)
            _ = events.drain()

            engine.seek(to: 70)
            engine.pause()
            #expect(events.drain() == [.stopped(position: 10)])

            engine.handleSeekCompletion(
                finished: false, target: 70,
                seekGeneration: engine.seekGeneration, loadGeneration: engine.loadGeneration
            )
            #expect(events.drain().isEmpty)
        }
    }

    /// The rate change is the same window seen from the other side: reopening
    /// at the unconfirmed target gives the new session a `startPosition` the
    /// first real time sample then contradicts.
    @Test func changingTheRateDuringAPendingSeekReopensAtTheConfirmedPosition() async throws {
        try await withRecordingEngine { engine, events, episode, store in
            try engine.play(episode, store: store)
            engine.handlePeriodicTime(playerSeconds(10), generation: engine.loadGeneration)
            _ = events.drain()

            engine.seek(to: 70)
            engine.setRate(1.5)

            #expect(events.drain() == [.rateChanged(position: 10, newRate: 1.5)])
        }
    }

    /// A seek the player refused moved nothing, so the position it guessed is
    /// withdrawn rather than left standing as the published playhead — which is
    /// what a resume would open the next session at.
    @Test func aSeekThatNeverLandsGivesThePlayheadBack() async throws {
        try await withRecordingEngine { engine, events, episode, store in
            try engine.play(episode, store: store)
            engine.handlePeriodicTime(playerSeconds(10), generation: engine.loadGeneration)
            _ = events.drain()

            engine.seek(to: 70)
            #expect(engine.elapsed == 70)

            engine.handleSeekCompletion(
                finished: false, target: 70,
                seekGeneration: engine.seekGeneration, loadGeneration: engine.loadGeneration
            )
            #expect(engine.elapsed == 10)
        }
    }

    /// A seek the player refused left the playhead where it was, so the target
    /// it only guessed is withdrawn rather than published: paused, no time
    /// sample arrives to correct it, and the next start would open a session at
    /// a position the first heartbeat then contradicts from the real playhead.
    /// A superseded seek does not come through here — the generation guard
    /// drops it — so a completion that reaches this point is a genuine refusal.
    @Test func anInterruptedSeekGivesBackItsTargetAndStopsSuppressingSamples() async throws {
        try await withLoadedEngine { engine, _, _ in
            engine.pause()
            engine.handlePeriodicTime(
                CMTime(seconds: 12, preferredTimescale: 600),
                generation: engine.loadGeneration
            )
            engine.seek(to: 30)
            let interruptedSeek = engine.seekGeneration

            engine.handleSeekCompletion(
                finished: false,
                target: 30,
                seekGeneration: interruptedSeek,
                loadGeneration: engine.loadGeneration
            )
            #expect(engine.elapsed == 12)

            engine.handlePeriodicTime(
                CMTime(seconds: 31, preferredTimescale: 600),
                generation: engine.loadGeneration
            )
            #expect(engine.elapsed == 31)
        }
    }

    /// A resume that lands inside the pre-completion window opens the next
    /// session at the target the seek was already heading for, so the boundary
    /// armed by the *closed* session has nothing left to correct. Emitted
    /// anyway, it closes the new session at the position it began ahead of —
    /// `startPosition = 70, endPosition = 10` in a log nothing can rewrite.
    @Test func resumingDuringAPendingSeekRetiresTheArmedBoundary() async throws {
        try await withRecordingEngine { engine, events, episode, store in
            try engine.play(episode, store: store)
            engine.handlePeriodicTime(playerSeconds(10), generation: engine.loadGeneration)
            _ = events.drain()

            engine.seek(to: 70)
            engine.pause()
            try engine.resumeLoaded()
            #expect(events.drain() == [.stopped(position: 10), .started(guid: episode.guid, position: 70, rate: 1.0)])

            engine.handleSeekCompletion(
                finished: true, target: 70,
                seekGeneration: engine.seekGeneration, loadGeneration: engine.loadGeneration
            )
            #expect(events.drain().isEmpty)
        }
    }

    /// The refusal half of the same window. The resume opened the session at
    /// the target, so withdrawing the playhead behind it would leave the next
    /// heartbeat writing `endPosition = 10` onto a row starting at 70. The
    /// refusal closes that session where it began — a zero-length row that
    /// played nothing, which is true — and reopens where the player really is.
    @Test func aRefusedSeekReopensASessionOpenedAtItsTarget() async throws {
        try await withRecordingEngine { engine, events, episode, store in
            try engine.play(episode, store: store)
            engine.handlePeriodicTime(playerSeconds(10), generation: engine.loadGeneration)
            _ = events.drain()

            engine.seek(to: 70)
            engine.pause()
            try engine.resumeLoaded()
            _ = events.drain()

            engine.handleSeekCompletion(
                finished: false, target: 70,
                seekGeneration: engine.seekGeneration, loadGeneration: engine.loadGeneration
            )

            #expect(engine.elapsed == 10)
            #expect(events.drain() == [.seeked(from: 70, target: 10)])
            engine.handleHeartbeat(playerSeconds(11), generation: engine.loadGeneration)
            #expect(events.drain() == [.heartbeat(position: 11)])
        }
    }

    /// A second boundary landing before the refusal must bound the session by
    /// its own opening position too: the confirmed playhead is behind it, so
    /// closing there is the inversion `sessionBoundaryPosition` exists to stop.
    @Test func aRateChangeInsideTheWindowClosesAtTheSessionsOpeningPosition() async throws {
        try await withRecordingEngine { engine, events, episode, store in
            try engine.play(episode, store: store)
            engine.handlePeriodicTime(playerSeconds(10), generation: engine.loadGeneration)
            _ = events.drain()

            engine.seek(to: 70)
            engine.pause()
            try engine.resumeLoaded()
            _ = events.drain()

            engine.setRate(1.5)

            #expect(events.drain() == [.rateChanged(position: 70, newRate: 1.5)])
        }
    }

    /// The ordinary case the rule above must not disturb: the session opened at
    /// a confirmed playhead before the seek, so a boundary inside the window
    /// still records that playhead rather than the target.
    @Test func aRateChangeInsideTheWindowStillUsesTheConfirmedPlayhead() async throws {
        try await withRecordingEngine { engine, events, episode, store in
            try engine.play(episode, store: store)
            engine.handlePeriodicTime(playerSeconds(10), generation: engine.loadGeneration)
            _ = events.drain()

            engine.seek(to: 70)
            engine.setRate(1.5)

            #expect(events.drain() == [.rateChanged(position: 10, newRate: 1.5)])
        }
    }

    /// The same window seen through a failure: cleared before the close, the
    /// pending state stops `sessionBoundaryPosition` answering the confirmed
    /// playhead and the session is closed at a target the player never reached.
    @Test func anItemFailureDuringAPendingSeekClosesAtTheConfirmedPosition() async throws {
        try await withRecordingEngine { engine, events, episode, store in
            try engine.play(episode, store: store)
            engine.handlePeriodicTime(playerSeconds(10), generation: engine.loadGeneration)
            _ = events.drain()

            engine.seek(to: 70)
            engine.handleItemStatus(
                .failed, itemDuration: nil, error: nil, generation: engine.loadGeneration
            )

            #expect(events.drain() == [.stopped(position: 10)])
        }
    }

    /// Readiness arriving while a user seek is in flight must not promote that
    /// seek's target to confirmed: a refusal then "restores" the guess as the
    /// published playhead instead of the position the player is really at.
    @Test func readinessDuringAPendingSeekDoesNotConfirmItsTarget() async throws {
        try await withRecordingEngine { engine, events, episode, store in
            try engine.play(episode, store: store)
            engine.handlePeriodicTime(playerSeconds(10), generation: engine.loadGeneration)
            _ = events.drain()

            engine.seek(to: 70)
            // the target is already inside the measured length, so the seam
            // finds nothing to correct and only publishes
            engine.handleItemStatus(
                .readyToPlay, itemDuration: 600, error: nil, generation: engine.loadGeneration
            )
            engine.handleSeekCompletion(
                finished: false, target: 70,
                seekGeneration: engine.seekGeneration, loadGeneration: engine.loadGeneration
            )

            #expect(engine.elapsed == 10)
            #expect(events.drain().isEmpty)
        }
    }

    /// The end of the item ends the window too, and it is the one way out of
    /// it that carries a *better* position than the session's opening one:
    /// the file played to its end, and no refusal can ever reconcile the seek
    /// now. Closed at the unreached target instead, `Episode.currentPosition`
    /// answers 70 for a finished episode and the next launch resumes in its
    /// middle rather than restarting it.
    @Test func theEndOfTheItemClosesASessionOpenedAtAnUnreachedTarget() async throws {
        try await withRecordingEngine { engine, events, episode, store in
            try engine.play(episode, store: store)
            engine.handlePeriodicTime(playerSeconds(10), generation: engine.loadGeneration)
            _ = events.drain()

            engine.seek(to: 70)
            engine.pause()
            try engine.resumeLoaded()
            #expect(events.drain() == [.stopped(position: 10), .started(guid: episode.guid, position: 70, rate: 1.0)])

            engine.handleItemEnded(generation: engine.loadGeneration)

            #expect(engine.elapsed == 100)
            #expect(events.drain() == [.stopped(position: 100)])
        }
    }
}
