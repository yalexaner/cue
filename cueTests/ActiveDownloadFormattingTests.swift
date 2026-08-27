import Foundation
import SwiftData
import Testing

@testable import cue

@MainActor
private func activeEpisode(
    in context: ModelContext, guid: String, podcast: Podcast,
    publishedAt: Date? = nil
) -> Episode {
    let episode = Episode(
        guid: guid, title: "Episode \(guid)",
        enclosureURL: "https://example.com/\(guid).mp3")
    episode.podcast = podcast
    episode.publishedAt = publishedAt
    context.insert(episode)
    return episode
}

@MainActor
private func activePodcast(in context: ModelContext, title: String) -> Podcast {
    let podcast = Podcast(feedURL: "https://example.com/\(UUID().uuidString)", title: title)
    context.insert(podcast)
    return podcast
}

private func activeDate(_ day: Int) -> Date {
    Date(timeIntervalSince1970: TimeInterval(day) * 86_400)
}

@MainActor
struct ActiveDownloadFormattingTests {
    @Test func noTransferStatesProduceNoActiveRows() throws {
        let context = try makeContext()
        let podcast = activePodcast(in: context, title: "Show")
        let episode = activeEpisode(in: context, guid: "guid-1", podcast: podcast)

        #expect(activeDownloads(episodesByGUID: [episode.guid: episode], states: [:]).isEmpty)
    }

    @Test func mixedStatesListDownloadingBeforeFailed() throws {
        let context = try makeContext()
        let zed = activePodcast(in: context, title: "Zed")
        let ann = activePodcast(in: context, title: "Ann")
        let downloading = activeEpisode(in: context, guid: "downloading", podcast: zed)
        let failed = activeEpisode(in: context, guid: "failed", podcast: ann)
        let episodes = [downloading.guid: downloading, failed.guid: failed]
        var states: [String: DownloadManager.DownloadState] = [:]
        states[downloading.guid] = .downloading(.connecting)
        states[failed.guid] = .failed(message: "Failed")

        let rows = activeDownloads(episodesByGUID: episodes, states: states)

        #expect(rows.map(\.episode.guid) == ["downloading", "failed"])
    }

    @Test func rowsSortByTitleThenNewestDateThenGUIDWithUndatedLast() throws {
        let context = try makeContext()
        let ann = activePodcast(in: context, title: "Ann")
        let zed = activePodcast(in: context, title: "Zed")
        let annNew = activeEpisode(
            in: context, guid: "ann-new", podcast: ann, publishedAt: activeDate(3))
        let annTieB = activeEpisode(
            in: context, guid: "ann-b", podcast: ann, publishedAt: activeDate(1))
        let annTieA = activeEpisode(
            in: context, guid: "ann-a", podcast: ann, publishedAt: activeDate(1))
        let annUndated = activeEpisode(in: context, guid: "ann-undated", podcast: ann)
        let zedEpisode = activeEpisode(
            in: context, guid: "zed", podcast: zed, publishedAt: activeDate(4))
        let all = [annUndated, zedEpisode, annTieB, annNew, annTieA]
        let episodes = Dictionary(uniqueKeysWithValues: all.map { ($0.guid, $0) })
        let states = Dictionary(
            uniqueKeysWithValues: all.map { ($0.guid, DownloadManager.DownloadState.downloading(.connecting)) })

        let rows = activeDownloads(episodesByGUID: episodes, states: states)

        #expect(rows.map(\.episode.guid) == ["ann-new", "ann-a", "ann-b", "ann-undated", "zed"])
    }

    @Test func aStateWhoseEpisodeIsUnknownIsNotListed() throws {
        let context = try makeContext()
        let podcast = activePodcast(in: context, title: "Show")
        let known = activeEpisode(in: context, guid: "known", podcast: podcast)
        var states: [String: DownloadManager.DownloadState] = [:]
        states["known"] = .downloading(.connecting)
        states["unknown"] = .failed(message: "Failed")

        let rows = activeDownloads(episodesByGUID: [known.guid: known], states: states)

        #expect(rows.map(\.episode.guid) == ["known"])
    }

    /// An episode whose podcast relationship is missing files under the same
    /// fallback title the row shows, rather than sorting to an arbitrary end.
    @Test func anEpisodeWithNoPodcastSortsUnderTheFallbackTitle() throws {
        let context = try makeContext()
        let show = activePodcast(in: context, title: "Show")
        let zed = activePodcast(in: context, title: "Zed")
        let shown = activeEpisode(in: context, guid: "shown", podcast: show)
        let zedEpisode = activeEpisode(in: context, guid: "zed", podcast: zed)
        let orphan = Episode(
            guid: "orphan", title: "Orphan", enclosureURL: "https://example.com/orphan.mp3")
        context.insert(orphan)
        let all = [zedEpisode, orphan, shown]
        let episodes = Dictionary(uniqueKeysWithValues: all.map { ($0.guid, $0) })
        let states = Dictionary(
            uniqueKeysWithValues: all.map { ($0.guid, DownloadManager.DownloadState.downloading(.connecting)) })

        let rows = activeDownloads(episodesByGUID: episodes, states: states)

        #expect(rows.map(\.episode.guid) == ["shown", "orphan", "zed"])
    }

    /// The section answers from the transfer alone: a retry that failed over an
    /// episode that still has its previous file is listed here with Retry, while
    /// the completed list below keeps offering Delete for the file on disk.
    @Test func aFailedRetryOverAnExistingFileStillOffersRetryHere() throws {
        let context = try makeContext()
        let podcast = activePodcast(in: context, title: "Show")
        let episode = activeEpisode(in: context, guid: "guid-1", podcast: podcast)
        episode.localFilename = "kept.mp3"
        var states: [String: DownloadManager.DownloadState] = [:]
        states[episode.guid] = .failed(message: "The download failed.")

        let rows = activeDownloads(episodesByGUID: [episode.guid: episode], states: states)
        let row = try #require(rows.first)

        #expect(row.rowState == .failed(message: "The download failed."))
        #expect(downloadAction(for: row.rowState) == .download)
        #expect(
            downloadAction(
                for: episodeDownloadState(
                    localFilename: episode.localFilename, transfer: states[episode.guid])) == .delete)
    }

    @Test func activeRowsOfferTheTransferSpecificAction() throws {
        let context = try makeContext()
        let podcast = activePodcast(in: context, title: "Show")
        let downloading = activeEpisode(in: context, guid: "downloading", podcast: podcast)
        let failed = activeEpisode(in: context, guid: "failed", podcast: podcast)
        let episodes = [downloading.guid: downloading, failed.guid: failed]
        var states: [String: DownloadManager.DownloadState] = [:]
        states[downloading.guid] = .downloading(.indeterminate(bytesWritten: 12))
        states[failed.guid] = .failed(message: "The download failed.")

        let rows = activeDownloads(episodesByGUID: episodes, states: states)
        let pairs = rows.map { ($0.episode.guid, downloadAction(for: $0.rowState)) }
        let actions = Dictionary(uniqueKeysWithValues: pairs)

        #expect(actions[downloading.guid] == .cancel)
        #expect(actions[failed.guid] == .download)
    }
}
