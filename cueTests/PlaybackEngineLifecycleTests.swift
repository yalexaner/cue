import AVFoundation
import Foundation
import Testing

@testable import cue

@MainActor
struct PlaybackEngineLifecycleTests {
    @Test func loadingAReplacementFilenameReplacesTheCurrentItem() async throws {
        try await withLoadedEngine { engine, episode, store in
            engine.pause()
            engine.seek(to: 25)
            let previousGeneration = engine.loadGeneration
            let base = try store.episodesDirectory().deletingLastPathComponent()
            try installRejectedAudio(named: "replacement.mp3", in: store, base: base)
            episode.localFilename = "replacement.mp3"
            episode.title = "Replacement"

            try engine.play(episode, store: store)

            #expect(engine.loadedFilename == "replacement.mp3")
            #expect(engine.episodeTitle == "Replacement")
            #expect(engine.loadGeneration == previousGeneration &+ 1)
            #expect(engine.elapsed == 0)
            #expect(engine.playbackError == nil)
            #expect(!engine.itemEnded)
        }
    }

    @Test func aFailedItemReloadsOnTheNextPlayRequest() async throws {
        try await withLoadedEngine { engine, episode, store in
            let previousGeneration = engine.loadGeneration
            let failure = NSError(domain: AVFoundationErrorDomain, code: AVError.unknown.rawValue)
            engine.handleItemStatus(
                .failed,
                itemDuration: nil,
                error: failure,
                generation: previousGeneration
            )
            #expect(!engine.isPlaying)
            #expect(engine.playbackError != nil)

            try engine.play(episode, store: store)

            #expect(engine.loadGeneration == previousGeneration &+ 1)
            #expect(engine.playbackError == nil)
            #expect(engine.isPlaying)
        }
    }

    @Test(arguments: [(42.0, 42.0), (125.0, 100.0)])
    func loadStartsAtTheSessionPositionClampedToDuration(
        sessionPosition: TimeInterval, expectedPosition: TimeInterval
    ) async throws {
        try await withTemporaryBaseAsync { base in
            let engine = PlaybackEngine()
            let episode = episode(filename: "audio.mp3")
            let session = PlaybackSession(
                startedAt: .now,
                startPosition: 0,
                endPosition: sessionPosition,
                rate: 1
            )
            episode.sessions.append(session)
            let store = EpisodeStore(baseDirectory: base)
            try store.prepareEpisodesDirectory()
            try installRejectedAudio(named: "audio.mp3", in: store, base: base)

            try engine.play(episode, store: store)

            #expect(engine.elapsed == expectedPosition)
            engine.unload(ifGUID: episode.guid)
        }
    }

    @Test func readyStatusUsesTheLocalItemDuration() async throws {
        try await withLoadedEngine { engine, _, _ in
            engine.handleItemStatus(
                .readyToPlay,
                itemDuration: 80,
                error: nil,
                generation: engine.loadGeneration
            )

            #expect(engine.duration == 80)
            #expect(engine.playbackError == nil)
        }
    }

    @Test(arguments: [(125.0, 100.0, 150.0, 100.0, 125.0), (150.0, 200.0, 100.0, 150.0, 100.0)])
    func readyStatusReclampsTheRawResumePositionAgainstTheLocalDuration(
        sessionPosition: TimeInterval, feedDuration: TimeInterval, itemDuration: TimeInterval,
        initialPosition: TimeInterval, expectedPosition: TimeInterval
    ) async throws {
        try await withTemporaryBaseAsync { base in
            let engine = PlaybackEngine()
            let episode = episode(filename: "audio.mp3")
            episode.feedDuration = feedDuration
            episode.sessions.append(
                PlaybackSession(
                    startedAt: .now,
                    startPosition: 0,
                    endPosition: sessionPosition,
                    rate: 1
                )
            )
            let store = EpisodeStore(baseDirectory: base)
            try store.prepareEpisodesDirectory()
            try installRejectedAudio(named: "audio.mp3", in: store, base: base)

            try engine.play(episode, store: store)
            #expect(engine.elapsed == initialPosition)

            engine.handleItemStatus(
                .readyToPlay,
                itemDuration: itemDuration,
                error: nil,
                generation: engine.loadGeneration
            )

            #expect(engine.duration == itemDuration)
            #expect(engine.elapsed == expectedPosition)
            engine.unload(ifGUID: episode.guid)
        }
    }

    @Test func aStaleFailedStatusCannotPoisonTheCurrentItem() async throws {
        try await withLoadedEngine { engine, _, _ in
            let currentGeneration = engine.loadGeneration
            engine.handleItemStatus(
                .failed,
                itemDuration: nil,
                error: NSError(domain: AVFoundationErrorDomain, code: AVError.unknown.rawValue),
                generation: currentGeneration &- 1
            )

            #expect(engine.playbackError == nil)
            #expect(engine.isPlaying)
        }
    }

    @Test func anAudioSessionInterruptionLeavesTheLoadedItemResumable() async throws {
        try await withLoadedEngine { engine, _, _ in
            engine.handleAudioSessionInterruption(.began)

            #expect(!engine.isPlaying)

            try engine.resumeLoaded()
            #expect(engine.isPlaying)
        }
    }

    @Test func resumingAFailedItemReportsTheFailureRatherThanDoingNothing() async throws {
        try await withLoadedEngine { engine, _, _ in
            let failure = NSError(domain: AVFoundationErrorDomain, code: AVError.unknown.rawValue)
            engine.handleItemStatus(
                .failed,
                itemDuration: nil,
                error: failure,
                generation: engine.loadGeneration
            )
            #expect(!engine.isPlaying)

            #expect(throws: (any Error).self) { try engine.resumeLoaded() }
            #expect(throws: (any Error).self) { try engine.togglePlayPause() }
            #expect(!engine.isPlaying)
        }
    }

    @Test func aLostOutputRouteStopsPlaybackWhileOtherRouteChangesDoNot() async throws {
        try await withLoadedEngine { engine, _, _ in
            engine.handleAudioRouteChange(.newDeviceAvailable)
            #expect(engine.isPlaying)

            engine.handleAudioRouteChange(.oldDeviceUnavailable)
            #expect(!engine.isPlaying)

            try engine.resumeLoaded()
            #expect(engine.isPlaying)
        }
    }

    @Test func readyStatusReconcilesAlreadySoughtPositionAgainstAShorterItem() async throws {
        try await withLoadedEngine { engine, _, _ in
            // a seek clears the pending resume position, so readiness takes the
            // reconciliation branch rather than the resume branch
            engine.seek(to: 90)
            #expect(engine.elapsed == 90)

            engine.handleItemStatus(
                .readyToPlay,
                itemDuration: 40,
                error: nil,
                generation: engine.loadGeneration
            )

            #expect(engine.duration == 40)
            #expect(engine.elapsed == 40)
        }
    }

    @Test func aPlayerLevelFailureStopsPlaybackAndReloadsOnTheNextRequest() async throws {
        try await withLoadedEngine { engine, episode, store in
            let previousGeneration = engine.loadGeneration
            let failure = NSError(domain: AVFoundationErrorDomain, code: AVError.unknown.rawValue)

            // a stale player-status callback cannot touch the loaded item
            engine.handlePlayerStatus(.failed, error: failure, generation: previousGeneration &- 1)
            #expect(engine.isPlaying)
            #expect(engine.playbackError == nil)

            engine.handlePlayerStatus(.failed, error: failure, generation: previousGeneration)
            #expect(!engine.isPlaying)
            #expect((engine.playbackError as NSError?)?.code == failure.code)
            #expect(throws: (any Error).self) { try engine.resumeLoaded() }

            try engine.play(episode, store: store)

            #expect(engine.loadGeneration == previousGeneration &+ 1)
            #expect(engine.playbackError == nil)
            #expect(engine.isPlaying)
        }
    }

    @Test func aRemoteStartFailureDoesNotPoisonTheLoadedItem() async throws {
        try await withLoadedEngine { engine, _, _ in
            let failure = NSError(domain: AVFoundationErrorDomain, code: AVError.deviceNotConnected.rawValue)
            engine.handleRemotePlaybackFailure(failure)

            #expect(!engine.isPlaying)
            let recordedFailure = engine.playbackError as NSError?
            #expect(recordedFailure?.domain == failure.domain)
            #expect(recordedFailure?.code == failure.code)

            try engine.resumeLoaded()
            #expect(engine.isPlaying)
            #expect(engine.playbackError == nil)
        }
    }
}
