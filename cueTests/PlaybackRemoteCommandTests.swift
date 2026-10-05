import AVFoundation
import Foundation
import Testing

@testable import cue

@MainActor
struct PlaybackRemoteCommandTests {
    @Test func aPauseOnAPlayingItemPauses() async throws {
        try await withLoadedEngine { engine, _, _ in
            #expect(engine.isPlaying)

            #expect(engine.handleRemotePause())

            #expect(!engine.isPlaying)
        }
    }

    @Test func aPlayAfterAPauseResumes() async throws {
        try await withLoadedEngine { engine, _, _ in
            engine.pause()

            #expect(engine.handleRemotePlay())

            #expect(engine.isPlaying)
        }
    }

    @Test func aPlayThatCannotStartReportsTheFailure() async throws {
        try await withLoadedEngine { engine, _, _ in
            let failure = NSError(domain: AVFoundationErrorDomain, code: AVError.unknown.rawValue)
            engine.handleItemStatus(.failed, itemDuration: nil, error: failure, generation: engine.loadGeneration)

            #expect(engine.handleRemotePlay())

            #expect(!engine.isPlaying)
            #expect((engine.playbackError as NSError?)?.code == failure.code)
        }
    }

    @Test func commandsAfterAnUnloadAreNotActionable() async throws {
        try await withLoadedEngine { engine, episode, _ in
            engine.unload(ifGUID: episode.guid)

            #expect(!engine.handleRemotePause())
            #expect(!engine.handleRemotePlay())

            #expect(!engine.isPlaying)
            #expect(engine.episodeGUID == nil)
            #expect(engine.player == nil)
            #expect(engine.playbackError == nil)
        }
    }

    @Test func commandsBeforeAnyLoadAreNotActionable() {
        let engine = PlaybackEngine()

        #expect(!engine.handleRemotePlay())
        #expect(!engine.handleRemotePause())

        #expect(!engine.isPlaying)
        #expect(engine.episodeGUID == nil)
    }
}
