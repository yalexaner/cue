import AVFoundation
import Foundation
import Testing

@testable import cue

/// Emission tests for the one internal seek that reports a boundary.
///
/// The rest of the seam lives in `PlaybackSessionEventTests`, whose helpers
/// these reuse; they are a separate suite only because that file is at its
/// length limit.
@MainActor
struct PlaybackReadySeamEventTests {
    /// A session opens from the load-time position, which a feed duration may
    /// have clamped and which the item's own duration may overrule. The ready
    /// seam's correction is therefore a real boundary — without it a restart
    /// records a `startPosition` ahead of every `endPosition` that follows it,
    /// in a log nothing can go back and rewrite.
    @Test func theReadySeamsResumeCorrectionClosesAndReopensTheSession() async throws {
        try await withRecordingEngine { engine, events, episode, store in
            episode.sessions.append(
                PlaybackSession(startedAt: .now, startPosition: 0, endPosition: 99, rate: 1)
            )

            try engine.play(episode, store: store)
            #expect(events.drain() == [.started(guid: episode.guid, position: 99, rate: 1)])

            // the file really is 100 s long, so 99 s in is a finished episode
            engine.handleItemStatus(
                .readyToPlay, itemDuration: 100, error: nil, generation: engine.loadGeneration
            )

            // armed, not committed: the correcting seek can still fail
            #expect(engine.elapsed == 0)
            #expect(events.drain().isEmpty)

            engine.handleSeekCompletion(
                finished: true, target: 0,
                seekGeneration: engine.seekGeneration, loadGeneration: engine.loadGeneration
            )
            #expect(events.drain() == [.seeked(from: 99, target: 0)])
        }
    }

    /// The correction is a seek like any other, so a player that never performs
    /// it must leave the session it would have reopened exactly as it was — and
    /// give back the playhead, which the seam only guessed.
    @Test func aReadySeamCorrectionThatNeverLandsReportsNothing() async throws {
        try await withRecordingEngine { engine, events, episode, store in
            episode.sessions.append(
                PlaybackSession(startedAt: .now, startPosition: 0, endPosition: 99, rate: 1)
            )

            try engine.play(episode, store: store)
            _ = events.drain()
            engine.handleItemStatus(
                .readyToPlay, itemDuration: 100, error: nil, generation: engine.loadGeneration
            )

            engine.handleSeekCompletion(
                finished: false, target: 0,
                seekGeneration: engine.seekGeneration, loadGeneration: engine.loadGeneration
            )

            #expect(events.drain().isEmpty)
            #expect(engine.elapsed == 99)
        }
    }

    @Test func aReadySeamThatLeavesThePlayheadAloneReportsNothing() async throws {
        try await withRecordingEngine { engine, events, episode, store in
            try engine.play(episode, store: store)
            _ = events.drain()

            engine.handleItemStatus(
                .readyToPlay, itemDuration: 100, error: nil, generation: engine.loadGeneration
            )

            #expect(events.drain().isEmpty)
        }
    }

    /// Nothing is live before the first start, so the same correction on a
    /// merely loaded item must stay silent: the next open reads the corrected
    /// `elapsed` as its own `startPosition`.
    @Test func aReadySeamCorrectionWhilePausedReportsNothing() async throws {
        try await withRecordingEngine { engine, events, episode, store in
            episode.sessions.append(
                PlaybackSession(startedAt: .now, startPosition: 0, endPosition: 99, rate: 1)
            )
            try engine.play(episode, store: store)
            engine.pause()
            _ = events.drain()

            engine.handleItemStatus(
                .readyToPlay, itemDuration: 100, error: nil, generation: engine.loadGeneration
            )

            #expect(engine.elapsed == 0)
            #expect(events.drain().isEmpty)
        }
    }
}
