import AVFoundation
import Foundation
import Testing

@testable import cue

/// Emission tests for the engine's session seam.
///
/// No SwiftData appears here on purpose: the whole point of `SessionEvent` is
/// that the engine reports boundaries without knowing a session is written
/// down, so these assert the seam alone. The recorder's side lives in
/// `SessionRecorderTests`.
@MainActor
struct PlaybackSessionEventTests {
    @Test func playingOpensASessionAtTheCurrentPositionAndRate() async throws {
        try await withRecordingEngine { engine, events, episode, store in
            try engine.play(episode, store: store)

            #expect(events.drain() == [.started(guid: "episode", position: 0, rate: 1.0)])
        }
    }

    @Test func resumingAfterAPauseClosesAndReopens() async throws {
        try await withRecordingEngine { engine, events, episode, store in
            try engine.play(episode, store: store)
            engine.handlePeriodicTime(playerSeconds(12), generation: engine.loadGeneration)
            _ = events.drain()

            engine.pause()
            try engine.resumeLoaded()

            let close = SessionEvent.stopped(position: 12)
            let reopen = SessionEvent.started(guid: episode.guid, position: 12, rate: 1)
            #expect(events.drain() == [close, reopen])
        }
    }

    @Test func restartingAnEndedItemOpensAtZero() async throws {
        try await withRecordingEngine { engine, events, episode, store in
            try engine.play(episode, store: store)
            _ = events.drain()

            engine.handleItemEnded(generation: engine.loadGeneration)
            #expect(events.drain() == [.stopped(position: 100)])

            try engine.play(episode, store: store)

            #expect(events.drain() == [.started(guid: "episode", position: 0, rate: 1.0)])
        }
    }

    @Test func unloadingClosesTheSessionAtItsLastPosition() async throws {
        try await withRecordingEngine { engine, events, episode, store in
            try engine.play(episode, store: store)
            engine.handlePeriodicTime(playerSeconds(30), generation: engine.loadGeneration)
            _ = events.drain()

            engine.unload(ifGUID: episode.guid)

            #expect(events.drain() == [.stopped(position: 30)])
        }
    }

    @Test func loadingAReplacementClosesTheOutgoingSessionFirst() async throws {
        try await withRecordingEngine { engine, events, episode, store in
            try engine.play(episode, store: store)
            engine.handlePeriodicTime(playerSeconds(20), generation: engine.loadGeneration)
            _ = events.drain()
            let base = try store.episodesDirectory().deletingLastPathComponent()
            try installRejectedAudio(named: "replacement.mp3", in: store, base: base)
            episode.localFilename = "replacement.mp3"

            try engine.play(episode, store: store)

            let close = SessionEvent.stopped(position: 20)
            let reopen = SessionEvent.started(guid: episode.guid, position: 0, rate: 1)
            #expect(events.drain() == [close, reopen])
        }
    }

    @Test func aFailedItemClosesTheSession() async throws {
        try await withRecordingEngine { engine, events, episode, store in
            try engine.play(episode, store: store)
            _ = events.drain()

            engine.handleItemStatus(
                .failed,
                itemDuration: nil,
                error: NSError(domain: AVFoundationErrorDomain, code: AVError.unknown.rawValue),
                generation: engine.loadGeneration
            )

            #expect(events.drain() == [.stopped(position: 0)])
        }
    }

    @Test func aFailedPlayerClosesTheSession() async throws {
        try await withRecordingEngine { engine, events, episode, store in
            try engine.play(episode, store: store)
            _ = events.drain()

            engine.handlePlayerStatus(.failed, error: nil, generation: engine.loadGeneration)

            #expect(events.drain() == [.stopped(position: 0)])
        }
    }

    @Test func aRemotePlaybackFailureClosesTheSession() async throws {
        try await withRecordingEngine { engine, events, episode, store in
            try engine.play(episode, store: store)
            _ = events.drain()

            engine.handleRemotePlaybackFailure(StubTransportError.offline)

            #expect(events.drain() == [.stopped(position: 0)])
        }
    }

    @Test func anInterruptionClosesTheSessionAndItsEndDoesNot() async throws {
        try await withRecordingEngine { engine, events, episode, store in
            try engine.play(episode, store: store)
            _ = events.drain()

            engine.handleAudioSessionInterruption(.began)
            engine.handleAudioSessionInterruption(.ended)

            #expect(events.drain() == [.stopped(position: 0)])
        }
    }

    @Test func onlyALostOutputRouteClosesTheSession() async throws {
        try await withRecordingEngine { engine, events, episode, store in
            try engine.play(episode, store: store)
            _ = events.drain()

            engine.handleAudioRouteChange(.newDeviceAvailable)
            #expect(events.drain().isEmpty)

            engine.handleAudioRouteChange(.oldDeviceUnavailable)
            #expect(events.drain() == [.stopped(position: 0)])
        }
    }

    @Test func repeatedStopsCloseTheSessionExactlyOnce() async throws {
        try await withRecordingEngine { engine, events, episode, store in
            try engine.play(episode, store: store)
            _ = events.drain()

            engine.pause()
            engine.pause()
            engine.handleAudioSessionInterruption(.began)
            engine.unload(ifGUID: episode.guid)

            #expect(events.drain() == [.stopped(position: 0)])
        }
    }

    @Test func changingTheRateWhilePlayingClosesAndReopens() async throws {
        try await withRecordingEngine { engine, events, episode, store in
            try engine.play(episode, store: store)
            engine.handlePeriodicTime(playerSeconds(8), generation: engine.loadGeneration)
            _ = events.drain()

            engine.setRate(1.5)

            #expect(events.drain() == [.rateChanged(position: 8, newRate: 1.5)])
        }
    }

    @Test func reselectingTheLiveRateReportsNoBoundary() async throws {
        try await withRecordingEngine { engine, events, episode, store in
            try engine.play(episode, store: store)
            _ = events.drain()

            engine.setRate(1.0)

            #expect(events.drain().isEmpty)
        }
    }

    @Test func anUnsupportedRateReportsNoBoundary() async throws {
        try await withRecordingEngine { engine, events, episode, store in
            try engine.play(episode, store: store)
            _ = events.drain()

            engine.setRate(4.0)

            #expect(events.drain().isEmpty)
            #expect(engine.rate == 1.0)
        }
    }

    @Test func changingTheRateWhilePausedReportsNoBoundary() async throws {
        try await withRecordingEngine { engine, events, episode, store in
            try engine.play(episode, store: store)
            engine.pause()
            _ = events.drain()

            engine.setRate(1.5)

            #expect(events.drain().isEmpty)
        }
    }

    @Test func theHeartbeatReportsThePositionOnlyWhilePlaying() async throws {
        try await withRecordingEngine { engine, events, episode, store in
            try engine.play(episode, store: store)
            engine.handlePeriodicTime(playerSeconds(25), generation: engine.loadGeneration)
            _ = events.drain()

            engine.handleHeartbeat(playerSeconds(25), generation: engine.loadGeneration)
            #expect(events.drain() == [.heartbeat(position: 25)])

            engine.pause()
            _ = events.drain()
            engine.handleHeartbeat(playerSeconds(25), generation: engine.loadGeneration)
            #expect(events.drain().isEmpty)
        }
    }

    @Test func aStaleHeartbeatIsIgnored() async throws {
        try await withRecordingEngine { engine, events, episode, store in
            try engine.play(episode, store: store)
            _ = events.drain()

            engine.handleHeartbeat(playerSeconds(5), generation: engine.loadGeneration &- 1)

            #expect(events.drain().isEmpty)
        }
    }

    @Test func aHeartbeatDuringAnUnlandedSeekIsSuppressed() async throws {
        try await withRecordingEngine { engine, events, episode, store in
            try engine.play(episode, store: store)
            engine.handlePeriodicTime(playerSeconds(10), generation: engine.loadGeneration)
            engine.seek(to: 70)
            _ = events.drain()

            // the seek has not reported completion, so the position is a guess
            engine.handleHeartbeat(playerSeconds(10), generation: engine.loadGeneration)
            #expect(events.drain().isEmpty)

            engine.handleSeekCompletion(
                finished: true, target: 70,
                seekGeneration: engine.seekGeneration, loadGeneration: engine.loadGeneration
            )
            _ = events.drain()
            engine.handleHeartbeat(playerSeconds(70), generation: engine.loadGeneration)
            #expect(events.drain() == [.heartbeat(position: 70)])
        }
    }

    /// The heartbeat observer is the whole of AC 12's mechanism (there is no
    /// termination observer), so its registration, its interval and its
    /// teardown are asserted rather than left to the build.
    @Test func theHeartbeatObserverIsInstalledAtTheSpecIntervalAndTornDown() async throws {
        #expect(sessionHeartbeatInterval == 10)
        try await withRecordingEngine { engine, _, episode, store in
            try engine.play(episode, store: store)
            #expect(engine.heartbeatTimeObserver != nil)
            #expect(engine.periodicTimeObserver != nil)

            engine.unload(ifGUID: episode.guid)

            #expect(engine.heartbeatTimeObserver == nil)
            #expect(engine.periodicTimeObserver == nil)
        }
    }
}

/// Collects the engine's emissions so a test can assert a whole boundary
/// sequence rather than a single flag.
@MainActor
final class SessionEventLog {
    private var events: [SessionEvent] = []

    func record(_ event: SessionEvent) {
        events.append(event)
    }

    /// Returns everything seen since the last call and starts a fresh window.
    func drain() -> [SessionEvent] {
        defer { events = [] }
        return events
    }
}

func playerSeconds(_ seconds: TimeInterval) -> CMTime {
    CMTime(seconds: seconds, preferredTimescale: 600)
}

/// Wires a recording closure before the first start, which `withLoadedEngine`
/// cannot do — it plays for you, so the opening `.started` would be lost.
@MainActor
func withRecordingEngine(
    _ body: (PlaybackEngine, SessionEventLog, Episode, EpisodeStore) throws -> Void
) async throws {
    try await withTemporaryBaseAsync { base in
        let engine = PlaybackEngine()
        let events = SessionEventLog()
        engine.sessionEvents = { events.record($0) }
        let episode = episode(filename: "audio.mp3")
        let store = EpisodeStore(baseDirectory: base)
        try store.prepareEpisodesDirectory()
        try installRejectedAudio(named: "audio.mp3", in: store, base: base)
        defer { engine.unload(ifGUID: episode.guid) }
        try body(engine, events, episode, store)
    }
}
