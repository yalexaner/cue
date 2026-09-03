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

    /// A stored position short of the end resumes there. One at or past a
    /// *measured* end is a finished episode and restarts, because starting on
    /// the last frame plays nothing at all.
    @Test(arguments: [(42.0, 42.0), (99.5, 0.0), (125.0, 0.0)])
    func loadResumesTheSessionPositionUnlessTheEpisodeFinished(
        sessionPosition: TimeInterval, expectedPosition: TimeInterval
    ) async throws {
        try await withTemporaryBaseAsync { base in
            let engine = PlaybackEngine()
            let episode = episode(filename: "audio.mp3")
            episode.assetDuration = 100
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

    /// An unmeasured episode carries its raw session position through the load
    /// — a feed duration is not allowed to judge it — and the item's own
    /// duration settles it: within reach of the end, resume there; at or past
    /// the end, the episode is finished and restarts.
    @Test(arguments: [(125.0, 100.0, 150.0, 125.0, 125.0), (150.0, 200.0, 100.0, 150.0, 0.0)])
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

    /// The load itself may not let the feed judge the playhead either. A feed
    /// that understates its file would otherwise drag a mid-episode position
    /// back onto its claimed end before the item is ready — which is the
    /// `startPosition` the session opens at, and the position a termination in
    /// that window records as the resume point.
    @Test func loadKeepsTheFeedDurationFromClampingAnUnmeasuredPosition() async throws {
        try await withTemporaryBaseAsync { base in
            let engine = PlaybackEngine()
            let episode = episode(filename: "audio.mp3")
            episode.feedDuration = 100
            episode.sessions.append(
                PlaybackSession(startedAt: .now, startPosition: 0, endPosition: 150, rate: 1)
            )
            let store = EpisodeStore(baseDirectory: base)
            try store.prepareEpisodesDirectory()
            try installRejectedAudio(named: "audio.mp3", in: store, base: base)

            try engine.play(episode, store: store)

            #expect(engine.elapsed == 150)
            // A length the playhead is already past is provably wrong, so it
            // may not bound the seek and periodic-time clamps either.
            #expect(engine.duration == nil)
            engine.unload(ifGUID: episode.guid)
        }
    }

    /// A ready item that reports no usable duration of its own leaves the
    /// resume position unjudged rather than handing it to the feed's value: a
    /// feed understating its file would otherwise clamp a mid-episode position
    /// onto its claimed end, read that as finished, and restart from zero.
    @Test func readyStatusWithNoItemDurationKeepsTheFeedFromRestartingTheEpisode() async throws {
        try await withTemporaryBaseAsync { base in
            let engine = PlaybackEngine()
            let episode = episode(filename: "audio.mp3")
            episode.feedDuration = 100
            episode.sessions.append(
                PlaybackSession(startedAt: .now, startPosition: 0, endPosition: 150, rate: 1)
            )
            let store = EpisodeStore(baseDirectory: base)
            try store.prepareEpisodesDirectory()
            try installRejectedAudio(named: "audio.mp3", in: store, base: base)

            try engine.play(episode, store: store)

            engine.handleItemStatus(
                .readyToPlay,
                itemDuration: nil,
                error: nil,
                generation: engine.loadGeneration
            )

            // a feed length the playhead has passed is provably wrong, so it
            // is dropped rather than left to clamp the position back onto it
            #expect(engine.duration == nil)
            #expect(engine.elapsed == 150)

            // the seams that write `elapsed` must not undo the restored
            // position: clamping them against the feed value froze the
            // playhead at 100 and heartbeated that into the session log
            engine.handleSeekCompletion(
                finished: true,
                target: 150,
                seekGeneration: engine.seekGeneration,
                loadGeneration: engine.loadGeneration
            )
            #expect(engine.elapsed == 150)

            engine.handlePeriodicTime(playerSeconds(160), generation: engine.loadGeneration)
            #expect(engine.elapsed == 160)
            engine.unload(ifGUID: episode.guid)
        }
    }

    /// The complementary case: at the ready seam the playhead is still *inside*
    /// the feed's claimed length, so nothing has disproved it yet — and an item
    /// that reports no length of its own never returns to the seam. Left to
    /// bound the time samples, that claim freezes `elapsed` on it for the rest
    /// of the episode and the heartbeat writes the frozen value to the log.
    @Test func aFeedLengthThePlaybackCrossesStopsBoundingThePlayhead() async throws {
        try await withTemporaryBaseAsync { base in
            let engine = PlaybackEngine()
            let episode = episode(filename: "audio.mp3")
            episode.feedDuration = 100
            let store = EpisodeStore(baseDirectory: base)
            try store.prepareEpisodesDirectory()
            try installRejectedAudio(named: "audio.mp3", in: store, base: base)

            try engine.play(episode, store: store)
            engine.handleItemStatus(
                .readyToPlay,
                itemDuration: nil,
                error: nil,
                generation: engine.loadGeneration
            )
            #expect(engine.duration == 100)

            engine.handlePeriodicTime(playerSeconds(90), generation: engine.loadGeneration)
            #expect(engine.elapsed == 90)

            // the file is longer than the feed said, and the sample proves it
            engine.handlePeriodicTime(playerSeconds(120), generation: engine.loadGeneration)
            #expect(engine.duration == nil)
            #expect(engine.elapsed == 120)

            engine.handleHeartbeat(playerSeconds(130), generation: engine.loadGeneration)
            #expect(engine.elapsed == 130)
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
