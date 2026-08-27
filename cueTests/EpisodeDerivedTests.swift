import Foundation
import SwiftData
import Testing

@testable import cue

@MainActor
struct EpisodeDerivedTests {
    private func makeEpisode(in context: ModelContext, guid: String = "guid-1") -> Episode {
        let episode = Episode(
            guid: guid,
            title: "Episode",
            enclosureURL: "https://example.com/audio/1.mp3"
        )
        context.insert(episode)
        return episode
    }

    // MARK: - duration

    @Test func durationPrefersAssetOverFeed() throws {
        let context = try makeContext()
        let episode = makeEpisode(in: context)
        episode.feedDuration = 100
        episode.assetDuration = 137

        #expect(episode.duration == 137)
    }

    @Test func durationFallsBackToFeed() throws {
        let context = try makeContext()
        let episode = makeEpisode(in: context)
        episode.feedDuration = 100

        #expect(episode.duration == 100)
    }

    @Test func durationIsNilWhenBothAreNil() throws {
        let context = try makeContext()
        let episode = makeEpisode(in: context)

        #expect(episode.duration == nil)
    }

    // MARK: - currentPosition

    @Test func currentPositionIsZeroWithoutSessions() throws {
        let context = try makeContext()
        let episode = makeEpisode(in: context)

        #expect(episode.currentPosition == 0)
    }

    @Test func currentPositionUsesTheOnlySession() throws {
        let context = try makeContext()
        let episode = makeEpisode(in: context)
        let session = PlaybackSession(
            startedAt: Date(timeIntervalSince1970: 1_000),
            startPosition: 0,
            endPosition: 42,
            rate: 1
        )
        session.episode = episode
        context.insert(session)
        try context.save()

        #expect(episode.currentPosition == 42)
    }

    @Test func currentPositionPrefersTheLatestStartedSession() throws {
        let context = try makeContext()
        let episode = makeEpisode(in: context)

        // inserted out of chronological order on purpose — insertion order must not decide
        let positions: [(TimeInterval, TimeInterval)] = [(2_000, 55), (1_000, 10), (3_000, 30), (1_500, 99)]
        for (startedAt, endPosition) in positions {
            let session = PlaybackSession(
                startedAt: Date(timeIntervalSince1970: startedAt),
                startPosition: 0,
                endPosition: endPosition,
                rate: 1
            )
            session.episode = episode
            context.insert(session)
        }
        try context.save()

        #expect(episode.sessions.count == 4)
        #expect(episode.currentPosition == 30)
    }

    @Test func currentPositionBreaksAStartedAtTieDeterministically() throws {
        let context = try makeContext()
        let episode = makeEpisode(in: context)

        // sessions can share a startedAt (rapid stop/start, restored clock) and a
        // to-many relationship has no defined order — the answer must still be fixed
        let startedAt = Date(timeIntervalSince1970: 1_000)
        for endPosition in [17.0, 88.0, 51.0] {
            let session = PlaybackSession(
                startedAt: startedAt,
                startPosition: 0,
                endPosition: endPosition,
                rate: 1
            )
            session.episode = episode
            context.insert(session)
        }
        try context.save()

        #expect(episode.sessions.count == 3)
        #expect(episode.currentPosition == 88)
    }

    @Test func currentPositionReturnsToZeroWhenSessionsAreDeleted() throws {
        let context = try makeContext()
        let episode = makeEpisode(in: context)
        let session = PlaybackSession(
            startedAt: Date(timeIntervalSince1970: 1_000),
            startPosition: 0,
            endPosition: 42,
            rate: 1
        )
        session.episode = episode
        context.insert(session)
        try context.save()

        context.delete(session)
        try context.save()

        #expect(episode.currentPosition == 0)
    }

    // MARK: - isDownloaded

    @Test func isDownloadedIsFalseWhenFilenameIsNil() throws {
        let context = try makeContext()
        let episode = makeEpisode(in: context)

        try withTemporaryBase { base in
            let store = EpisodeStore(baseDirectory: base)
            try #expect(episode.isDownloaded(in: store) == false)
        }
    }

    @Test func isDownloadedIsFalseForADanglingRow() throws {
        let context = try makeContext()
        let episode = makeEpisode(in: context)
        episode.localFilename = "3F2A.mp3"
        episode.downloadedAt = Date(timeIntervalSince1970: 1_000)

        try withTemporaryBase { base in
            let store = EpisodeStore(baseDirectory: base)
            try #expect(episode.isDownloaded(in: store) == false)
        }
    }

    @Test func isDownloadedIsTrueWhenTheFileIsPresent() throws {
        let context = try makeContext()
        let episode = makeEpisode(in: context)
        episode.localFilename = "3F2A.mp3"

        try withTemporaryBase { base in
            let store = EpisodeStore(baseDirectory: base)
            try store.prepareEpisodesDirectory()
            let url = try store.url(forRelativeFilename: "3F2A.mp3")
            try Data("audio".utf8).write(to: url)

            try #expect(episode.isDownloaded(in: store) == true)
        }
    }

    @Test func isDownloadedThrowsForAnUnresolvableFilename() throws {
        let context = try makeContext()
        let episode = makeEpisode(in: context)
        // a corrupt name must never be answered as "not downloaded" — the
        // reconciliation sweep would clear the row and orphan the audio
        episode.localFilename = "../escaped.mp3"

        try withTemporaryBase { base in
            let store = EpisodeStore(baseDirectory: base)
            #expect(throws: EpisodeStore.Failure.invalidFilename("../escaped.mp3")) {
                try episode.isDownloaded(in: store)
            }
        }
    }

    @Test func isDownloadedTurnsFalseWhenTheFileIsRemoved() throws {
        let context = try makeContext()
        let episode = makeEpisode(in: context)
        episode.localFilename = "3F2A.mp3"

        try withTemporaryBase { base in
            let store = EpisodeStore(baseDirectory: base)
            try store.prepareEpisodesDirectory()
            let url = try store.url(forRelativeFilename: "3F2A.mp3")
            try Data("audio".utf8).write(to: url)
            try #expect(episode.isDownloaded(in: store) == true)

            try FileManager.default.removeItem(at: url)

            try #expect(episode.isDownloaded(in: store) == false)
            // the column is untouched — clearing it is the reconciliation sweep's job
            #expect(episode.localFilename == "3F2A.mp3")
        }
    }

    // MARK: - fileSize

    @Test func fileSizeIsNilWhenFilenameIsNil() throws {
        let context = try makeContext()
        let episode = makeEpisode(in: context)

        try withTemporaryBase { base in
            let store = EpisodeStore(baseDirectory: base)
            try #expect(episode.fileSize(in: store) == nil)
        }
    }

    @Test func fileSizeIsNilForADanglingRow() throws {
        let context = try makeContext()
        let episode = makeEpisode(in: context)
        episode.localFilename = "3F2A.mp3"

        try withTemporaryBase { base in
            let store = EpisodeStore(baseDirectory: base)
            try #expect(episode.fileSize(in: store) == nil)
        }
    }

    @Test func fileSizeReportsTheBytesOnDisk() throws {
        let context = try makeContext()
        let episode = makeEpisode(in: context)
        episode.localFilename = "3F2A.mp3"

        try withTemporaryBase { base in
            let store = EpisodeStore(baseDirectory: base)
            try store.prepareEpisodesDirectory()
            let url = try store.url(forRelativeFilename: "3F2A.mp3")
            try Data(repeating: 7, count: 2_048).write(to: url)

            try #expect(episode.fileSize(in: store) == 2_048)
        }
    }

    /// A size that cannot be read is never answered as zero: a confirmation
    /// naming "Zero KB" would tell the user a real download costs nothing.
    @Test func fileSizeThrowsForAnUnresolvableFilename() throws {
        let context = try makeContext()
        let episode = makeEpisode(in: context)
        episode.localFilename = "../escaped.mp3"

        try withTemporaryBase { base in
            let store = EpisodeStore(baseDirectory: base)
            #expect(throws: EpisodeStore.Failure.invalidFilename("../escaped.mp3")) {
                try episode.fileSize(in: store)
            }
        }
    }

    // MARK: - orthogonality of played state and download state

    @Test func markingPlayedLeavesDownloadStateUntouched() throws {
        let context = try makeContext()
        let episode = makeEpisode(in: context)
        episode.localFilename = "3F2A.mp3"
        episode.downloadedAt = Date(timeIntervalSince1970: 1_000)

        try withTemporaryBase { base in
            let store = EpisodeStore(baseDirectory: base)
            try store.prepareEpisodesDirectory()
            let url = try store.url(forRelativeFilename: "3F2A.mp3")
            try Data("audio".utf8).write(to: url)

            episode.isPlayed = true
            episode.playedAt = Date(timeIntervalSince1970: 2_000)
            try context.save()

            #expect(episode.localFilename == "3F2A.mp3")
            #expect(episode.downloadedAt == Date(timeIntervalSince1970: 1_000))
            try #expect(episode.isDownloaded(in: store) == true)
            #expect(FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
        }
    }

    @Test func clearingDownloadStateLeavesPlayedStateUntouched() throws {
        let context = try makeContext()
        let episode = makeEpisode(in: context)
        episode.localFilename = "3F2A.mp3"
        episode.downloadedAt = Date(timeIntervalSince1970: 1_000)
        episode.isPlayed = true
        episode.playedAt = Date(timeIntervalSince1970: 2_000)
        try context.save()

        episode.localFilename = nil
        episode.downloadedAt = nil
        try context.save()

        #expect(episode.isPlayed == true)
        #expect(episode.playedAt == Date(timeIntervalSince1970: 2_000))
    }

    @Test func deletingTheFileDoesNotMarkTheEpisodePlayed() throws {
        let context = try makeContext()
        let episode = makeEpisode(in: context)
        episode.localFilename = "3F2A.mp3"

        try withTemporaryBase { base in
            let store = EpisodeStore(baseDirectory: base)
            try store.prepareEpisodesDirectory()
            let url = try store.url(forRelativeFilename: "3F2A.mp3")
            try Data("audio".utf8).write(to: url)
            try FileManager.default.removeItem(at: url)

            try #expect(episode.isDownloaded(in: store) == false)
            #expect(episode.isPlayed == false)
            #expect(episode.playedAt == nil)
        }
    }
}
