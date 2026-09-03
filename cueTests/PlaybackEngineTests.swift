import AVFoundation
import Foundation
import Testing

@testable import cue

@MainActor
struct PlaybackEngineTests {
    @Test func playWithoutAFilenameThrowsAndLeavesStateUntouched() async throws {
        try await withTemporaryBaseAsync { base in
            let engine = PlaybackEngine()
            let episode = Episode(guid: "episode", title: "Title", enclosureURL: "https://example.com/audio.mp3")

            #expect(throws: PlaybackEngine.Failure.notDownloaded) {
                try engine.play(episode, store: EpisodeStore(baseDirectory: base))
            }
            expectUnloaded(engine)
        }
    }

    @Test func playWithAnInvalidFilenamePropagatesTheStoreFailure() async throws {
        try await withTemporaryBaseAsync { base in
            let engine = PlaybackEngine()
            let episode = episode(filename: "../audio.mp3")

            #expect(throws: EpisodeStore.Failure.invalidFilename("../audio.mp3")) {
                try engine.play(episode, store: EpisodeStore(baseDirectory: base))
            }
            expectUnloaded(engine)
        }
    }

    @Test func playWithAConfirmedMissingFileThrowsAndLeavesStateUntouched() async throws {
        try await withTemporaryBaseAsync { base in
            let engine = PlaybackEngine()
            let episode = episode(filename: "missing.mp3")

            #expect(throws: PlaybackEngine.Failure.fileMissing) {
                try engine.play(episode, store: EpisodeStore(baseDirectory: base))
            }
            expectUnloaded(engine)
        }
    }

    @Test func playPropagatesAnIndeterminateStorageError() async throws {
        try await withTemporaryBaseAsync { base in
            let engine = PlaybackEngine()
            let episode = episode(filename: "audio.mp3")
            let store = EpisodeStore(baseDirectory: base)
            let directory = try store.prepareEpisodesDirectory()
            try installRejectedAudio(named: "audio.mp3", in: store, base: base)
            let path = directory.path(percentEncoded: false)
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: path)
            defer {
                try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
            }

            let expectedError: NSError
            do {
                _ = try store.fileExists(forRelativeFilename: "audio.mp3")
                Issue.record("the permission-denied lookup unexpectedly succeeded")
                return
            } catch {
                expectedError = error as NSError
            }

            do {
                try engine.play(episode, store: store)
                Issue.record("play unexpectedly accepted an indeterminate disk result")
            } catch {
                let receivedError = error as NSError
                #expect(receivedError.domain == expectedError.domain)
                #expect(receivedError.code == expectedError.code)
            }
            expectUnloaded(engine)
        }
    }

    @Test func replayingTheLoadedPairDoesNotResetElapsedTime() async throws {
        try await withLoadedEngine { engine, episode, store in
            engine.pause()
            engine.seek(to: 12)

            try engine.play(episode, store: store)

            #expect(engine.episodeGUID == episode.guid)
            #expect(engine.loadedFilename == episode.localFilename)
            #expect(engine.elapsed == 12)
            #expect(engine.isPlaying)
        }
    }

    @Test func replayStillChecksThatTheLoadedFileExists() async throws {
        try await withLoadedEngine { engine, episode, store in
            engine.pause()
            engine.seek(to: 12)
            let filename = try #require(episode.localFilename)
            try store.removeFile(forRelativeFilename: filename)

            #expect(throws: PlaybackEngine.Failure.fileMissing) {
                try engine.play(episode, store: store)
            }
            #expect(engine.episodeGUID == episode.guid)
            #expect(engine.elapsed == 12)
            #expect(!engine.isPlaying)
        }
    }

    @Test func playingAnEndedPairRestartsThenBecomesReusable() async throws {
        try await withLoadedEngine { engine, episode, store in
            engine.handleItemEnded(generation: engine.loadGeneration)
            #expect(engine.itemEnded)
            #expect(engine.elapsed == 100)

            try engine.play(episode, store: store)

            #expect(!engine.itemEnded)
            #expect(engine.elapsed == 0)
            #expect(engine.isPlaying)

            // reuse is observable: a second request keeps the same loaded item
            let generation = engine.loadGeneration
            try engine.play(episode, store: store)
            #expect(engine.loadGeneration == generation)
            #expect(engine.elapsed == 0)
        }
    }

    @Test func seekingBackwardAfterTheEndMakesTheItemReusable() async throws {
        try await withLoadedEngine { engine, episode, store in
            engine.handleItemEnded(generation: engine.loadGeneration)

            engine.seek(to: 30)

            #expect(!engine.itemEnded)
            #expect(engine.elapsed == 30)

            // reused rather than restarted: the sought position survives
            let generation = engine.loadGeneration
            try engine.play(episode, store: store)
            #expect(engine.loadGeneration == generation)
            #expect(engine.elapsed == 30)
        }
    }

    @Test func resumingAnEndedItemStartsAtZero() async throws {
        try await withLoadedEngine { engine, _, _ in
            engine.handleItemEnded(generation: engine.loadGeneration)

            try engine.resumeLoaded()

            #expect(!engine.itemEnded)
            #expect(engine.elapsed == 0)
            #expect(engine.isPlaying)
        }
    }

    @Test func togglePausesAndResumesTheLoadedItem() async throws {
        try await withLoadedEngine { engine, _, _ in
            #expect(engine.isPlaying)

            try engine.togglePlayPause()
            #expect(!engine.isPlaying)

            try engine.togglePlayPause()
            #expect(engine.isPlaying)
        }
    }

    @Test func skipsClampAtBothEndsOfTheLoadedDuration() async throws {
        try await withLoadedEngine { engine, _, _ in
            engine.pause()
            engine.seek(to: 90)

            engine.skip(by: 30)
            #expect(engine.elapsed == 100)

            engine.skip(by: -130)
            #expect(engine.elapsed == 0)
        }
    }

    @Test func aRestartWhoseSeekNeverLandsKeepsTheItemEnded() async throws {
        try await withLoadedEngine { engine, episode, store in
            engine.handleItemEnded(generation: engine.loadGeneration)

            try engine.play(episode, store: store)
            #expect(!engine.itemEnded)

            engine.handleSeekCompletion(
                finished: false,
                target: 0,
                seekGeneration: engine.seekGeneration,
                loadGeneration: engine.loadGeneration
            )

            // the playhead may still be at the end, so the next resume restarts
            #expect(engine.itemEnded)
            // and the engine must not report playing over an item at EOF
            #expect(!engine.isPlaying)
        }
    }

    @Test func anEndedItemSoughtBackwardStaysEndedWhenThatSeekFails() async throws {
        try await withLoadedEngine { engine, _, _ in
            engine.handleItemEnded(generation: engine.loadGeneration)

            engine.seek(to: 30)
            #expect(!engine.itemEnded)

            engine.handleSeekCompletion(
                finished: false,
                target: 30,
                seekGeneration: engine.seekGeneration,
                loadGeneration: engine.loadGeneration
            )
            #expect(engine.itemEnded)
            #expect(!engine.isPlaying)
        }
    }

    @Test func reusingALoadedEpisodePublishesItsRefreshedTitle() async throws {
        try await withLoadedEngine { engine, episode, store in
            engine.pause()
            engine.seek(to: 40)
            let generation = engine.loadGeneration
            episode.title = "Renamed by refresh"

            try engine.play(episode, store: store)

            #expect(engine.episodeTitle == "Renamed by refresh")
            #expect(engine.loadGeneration == generation)
            #expect(engine.elapsed == 40)
        }
    }

    @Test func rateAcceptsOnlyLadderValuesAndIsRememberedWhilePaused() {
        let engine = PlaybackEngine()

        engine.setRate(1.5)
        #expect(engine.rate == 1.5)

        engine.setRate(1.1)
        #expect(engine.rate == 1.5)
    }

    @Test func unloadIgnoresAnotherGUIDAndClearsTheMatchingItem() async throws {
        try await withLoadedEngine { engine, episode, _ in
            engine.pause()
            engine.seek(to: 20)
            engine.unload(ifGUID: "another-episode")
            #expect(engine.episodeGUID == episode.guid)
            #expect(engine.elapsed == 20)

            engine.unload(ifGUID: episode.guid)
            expectUnloaded(engine)
        }
    }

    @Test func staleCallbacksCannotChangeTheLoadedState() async throws {
        try await withLoadedEngine { engine, _, _ in
            let currentGeneration = engine.loadGeneration

            engine.handleItemEnded(generation: currentGeneration &- 1)
            engine.handlePeriodicTime(CMTime(seconds: 75, preferredTimescale: 600), generation: currentGeneration &- 1)

            #expect(!engine.itemEnded)
            #expect(engine.elapsed == 0)
        }
    }

    /// Only a *measured* length may bound the playhead, so the item reports one
    /// first: an unmeasured feed length a sample has passed is disproved rather
    /// than enforced (`aFeedLengthThePlaybackCrossesStopsBoundingThePlayhead`).
    @Test func currentPeriodicCallbackPublishesAClampedElapsedTime() async throws {
        try await withLoadedEngine { engine, _, _ in
            engine.handleItemStatus(
                .readyToPlay,
                itemDuration: 100,
                error: nil,
                generation: engine.loadGeneration
            )
            engine.handlePeriodicTime(
                CMTime(seconds: 125, preferredTimescale: 600),
                generation: engine.loadGeneration
            )

            #expect(engine.elapsed == 100)
        }
    }

    @Test func pendingAndSupersededSeeksIgnoreStalePeriodicSamplesAndCompletions() async throws {
        try await withLoadedEngine { engine, _, _ in
            engine.pause()
            engine.seek(to: 20)
            let firstSeek = engine.seekGeneration

            engine.handlePeriodicTime(
                CMTime(seconds: 5, preferredTimescale: 600),
                generation: engine.loadGeneration
            )
            #expect(engine.elapsed == 20)

            engine.seek(to: 40)
            let secondSeek = engine.seekGeneration
            engine.handleSeekCompletion(
                finished: true,
                target: 20,
                seekGeneration: firstSeek,
                loadGeneration: engine.loadGeneration
            )
            #expect(engine.elapsed == 40)

            engine.handleSeekCompletion(
                finished: true,
                target: 40,
                seekGeneration: secondSeek,
                loadGeneration: engine.loadGeneration
            )
            engine.handlePeriodicTime(
                CMTime(seconds: 45, preferredTimescale: 600),
                generation: engine.loadGeneration
            )
            #expect(engine.elapsed == 45)
        }
    }
}

@MainActor
func episode(filename: String) -> Episode {
    let episode = Episode(guid: "episode", title: "Title", enclosureURL: "https://example.com/audio.mp3")
    episode.feedDuration = 100
    episode.localFilename = filename
    return episode
}

@MainActor
private func expectUnloaded(_ engine: PlaybackEngine) {
    #expect(engine.episodeGUID == nil)
    #expect(engine.loadedFilename == nil)
    #expect(engine.episodeTitle == nil)
    #expect(engine.podcastTitle == nil)
    #expect(!engine.isPlaying)
    #expect(engine.elapsed == 0)
    #expect(engine.duration == nil)
    #expect(engine.playbackError == nil)
    #expect(!engine.itemEnded)
}

@MainActor
func withLoadedEngine(
    _ body: (PlaybackEngine, Episode, EpisodeStore) throws -> Void
) async throws {
    try await withTemporaryBaseAsync { base in
        let engine = PlaybackEngine()
        let episode = episode(filename: "audio.mp3")
        let store = EpisodeStore(baseDirectory: base)
        try store.prepareEpisodesDirectory()
        try installRejectedAudio(named: "audio.mp3", in: store, base: base)
        try engine.play(episode, store: store)
        defer { engine.unload(ifGUID: episode.guid) }
        try body(engine, episode, store)
    }
}

func installRejectedAudio(named filename: String, in store: EpisodeStore, base: URL) throws {
    let source = base.appending(path: "source-\(UUID().uuidString)", directoryHint: .notDirectory)
    try Data("not audio".utf8).write(to: source)
    try store.moveFile(at: source, toRelativeFilename: filename)
}
