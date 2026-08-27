import Foundation
import SwiftData
import Testing

@testable import cue

@MainActor
private func makeEpisode(
    _ context: ModelContext,
    guid: String,
    podcast: Podcast?,
    publishedAt: Date? = nil,
    localFilename: String? = "\(UUID().uuidString).mp3"
) -> Episode {
    let episode = Episode(guid: guid, title: "Episode \(guid)", enclosureURL: "https://example.com/\(guid).mp3")
    episode.publishedAt = publishedAt
    episode.localFilename = localFilename
    episode.podcast = podcast
    context.insert(episode)
    return episode
}

@MainActor
private func makePodcast(_ context: ModelContext, feedURL: String, title: String) -> Podcast {
    let podcast = Podcast(feedURL: feedURL, title: title)
    context.insert(podcast)
    return podcast
}

private func date(_ day: Int) -> Date {
    Date(timeIntervalSince1970: TimeInterval(day) * 86_400)
}

@MainActor
struct DownloadGroupingTests {

    @Test func noDownloadsGroupIntoNothing() {
        #expect(downloadGroups([], sizes: [:]).isEmpty)
    }

    @Test func oneShowIsOneGroupWithItsOwnTitle() throws {
        let context = try makeContext()
        let podcast = makePodcast(context, feedURL: testFeedURL, title: "Show")
        let first = makeEpisode(context, guid: "a", podcast: podcast, publishedAt: date(1))
        let second = makeEpisode(context, guid: "b", podcast: podcast, publishedAt: date(2))

        let groups = downloadGroups([first, second], sizes: [:])

        #expect(groups.count == 1)
        #expect(groups[0].title == "Show")
        #expect(groups[0].id == testFeedURL)
    }

    /// Newest first inside a group, same order the detail list uses.
    @Test func episodesInsideAGroupAreNewestFirst() throws {
        let context = try makeContext()
        let podcast = makePodcast(context, feedURL: testFeedURL, title: "Show")
        let old = makeEpisode(context, guid: "old", podcast: podcast, publishedAt: date(1))
        let new = makeEpisode(context, guid: "new", podcast: podcast, publishedAt: date(3))

        let groups = downloadGroups([old, new], sizes: [:])

        #expect(groups[0].episodes.map(\.guid) == ["new", "old"])
    }

    /// Groups are ordered by title so two rebuilds of the same library agree.
    @Test func severalShowsAreOrderedByTitle() throws {
        let context = try makeContext()
        let zed = makePodcast(context, feedURL: "https://example.com/z", title: "Zed")
        let ann = makePodcast(context, feedURL: "https://example.com/a", title: "Ann")
        let fromZed = makeEpisode(context, guid: "z1", podcast: zed)
        let fromAnn = makeEpisode(context, guid: "a1", podcast: ann)

        let groups = downloadGroups([fromZed, fromAnn], sizes: [:])

        #expect(groups.map(\.title) == ["Ann", "Zed"])
        #expect(groups.map { $0.episodes.count } == [1, 1])
    }

    /// Two shows can share a title — a re-published feed is the ordinary case —
    /// and `Dictionary(grouping:)` iteration order is not stable, so the tie has
    /// to break on something. Without it the list reorders under the user.
    @Test func showsSharingATitleAreOrderedByFeedURL() throws {
        let context = try makeContext()
        let second = makePodcast(context, feedURL: "https://example.com/b", title: "Show")
        let first = makePodcast(context, feedURL: "https://example.com/a", title: "Show")
        let fromSecond = makeEpisode(context, guid: "b1", podcast: second)
        let fromFirst = makeEpisode(context, guid: "a1", podcast: first)

        let groups = downloadGroups([fromSecond, fromFirst], sizes: [:])

        #expect(groups.map(\.id) == ["https://example.com/a", "https://example.com/b"])
    }

    /// A downloaded file whose show is gone still needs a row — otherwise it is
    /// a file the user cannot see and therefore cannot delete.
    @Test func anEpisodeWithNoPodcastStillGetsAGroup() throws {
        let context = try makeContext()
        let orphan = makeEpisode(context, guid: "orphan", podcast: nil)

        let groups = downloadGroups([orphan], sizes: [:])

        #expect(groups.count == 1)
        #expect(groups[0].episodes.map(\.guid) == ["orphan"])
        #expect(groups[0].id.isEmpty)
        #expect(groups[0].title == "Unknown Podcast")
    }

    @Test func groupBytesSumOnlyThatGroupsEpisodes() throws {
        let context = try makeContext()
        let first = makePodcast(context, feedURL: "https://example.com/a", title: "Ann")
        let second = makePodcast(context, feedURL: "https://example.com/z", title: "Zed")
        let one = makeEpisode(context, guid: "a1", podcast: first)
        let two = makeEpisode(context, guid: "a2", podcast: first)
        let three = makeEpisode(context, guid: "z1", podcast: second)
        let sizes = ["a1": 1_000, "a2": 2_000, "z1": 500]

        let groups = downloadGroups([one, two, three], sizes: sizes)

        #expect(groups.map(\.byteCount) == [3_000, 500])
    }

    /// A size the scan could not measure contributes nothing rather than
    /// dropping the episode out of the list.
    @Test func anUnmeasuredEpisodeCountsAsZeroBytesAndKeepsItsRow() throws {
        let context = try makeContext()
        let podcast = makePodcast(context, feedURL: testFeedURL, title: "Show")
        let measured = makeEpisode(context, guid: "measured", podcast: podcast)
        let unmeasured = makeEpisode(context, guid: "unmeasured", podcast: podcast)

        let groups = downloadGroups([measured, unmeasured], sizes: ["measured": 42])

        #expect(groups[0].byteCount == 42)
        #expect(groups[0].episodes.count == 2)
    }
}

struct DiskUsageTextTests {

    @Test func aByteCountIsFormattedAsAFileSize() {
        #expect(!diskUsageText(0).isEmpty)
        // against the formatted value, not a literal unit: the rendered unit is
        // localised ("5 МБ", "5 Mo"), so an ASCII "MB" only passes on some hosts
        #expect(diskUsageText(5_000_000) == (5_000_000).formatted(.byteCount(style: .file)))
    }

    /// `.file` style, not `.memory`: 1,000,000 bytes is 1 MB on disk, and the
    /// same count under `.memory` is 977 kB — the disagreement with Settings the
    /// doc comment warns about.
    ///
    /// Asserted against the two styles rather than against a literal, because
    /// Foundation never spells a binary unit "MiB" (checking for that string
    /// passes whichever style is used) and the rendered unit is localised.
    @Test func fileStyleIsUsedRatherThanBinaryUnits() {
        #expect(diskUsageText(1_000_000) == (1_000_000).formatted(.byteCount(style: .file)))
        #expect(diskUsageText(1_000_000) != (1_000_000).formatted(.byteCount(style: .memory)))
    }
}

struct EpisodeDownloadStateTests {

    @Test func noFileAndNoTransferIsNotDownloaded() {
        #expect(episodeDownloadState(localFilename: nil, transfer: nil) == .notDownloaded)
    }

    @Test func aStoredFilenameReadsAsDownloaded() {
        #expect(episodeDownloadState(localFilename: "a.mp3", transfer: nil) == .downloaded)
    }

    /// A transfer in flight outranks the file it is about to replace.
    @Test func aTransferInFlightOutranksAStoredFilename() {
        #expect(
            episodeDownloadState(localFilename: "a.mp3", transfer: .downloading(.connecting))
                == .downloading(.connecting))
        #expect(
            episodeDownloadState(localFilename: nil, transfer: .downloading(.connecting))
                == .downloading(.connecting))
        #expect(
            episodeDownloadState(
                localFilename: nil, transfer: .downloading(.indeterminate(bytesWritten: 12)))
                == .downloading(.indeterminate(bytesWritten: 12)))
        #expect(
            episodeDownloadState(
                localFilename: nil,
                transfer: .downloading(.fraction(bytesWritten: 50, expectedBytes: 100)))
                == .downloading(.fraction(bytesWritten: 50, expectedBytes: 100)))
    }

    /// A failed retry over a file that is still there is not a failed episode.
    @Test func failureShowsOnlyWhenThereIsNoFile() {
        let message = "The download failed."
        #expect(
            episodeDownloadState(localFilename: nil, transfer: .failed(message: message))
                == .failed(message: message))
        #expect(
            episodeDownloadState(localFilename: "a.mp3", transfer: .failed(message: message))
                == .downloaded)
    }
}

struct DownloadRowActionTests {

    @Test func anAbsentOrFailedDownloadOffersDownloading() {
        #expect(downloadAction(for: .notDownloaded) == .download)
        #expect(downloadAction(for: .failed(message: "The download failed.")) == .download)
    }

    @Test func aPresentDownloadOffersDeleting() {
        #expect(downloadAction(for: .downloaded) == .delete)
    }

    /// A running transfer offers Cancel rather than Delete, because deleting
    /// under a running move is a race.
    @Test func aRunningTransferOffersCancellation() {
        // every phase, queued included: a queued transfer is cancellable before
        // it has a session task, and a connecting one has no file to delete
        #expect(downloadAction(for: .downloading(.queued(position: 3))) == .cancel)
        #expect(downloadAction(for: .downloading(.connecting)) == .cancel)
        #expect(downloadAction(for: .downloading(.indeterminate(bytesWritten: 8))) == .cancel)
        #expect(downloadAction(for: .downloading(.fraction(bytesWritten: 1, expectedBytes: 2))) == .cancel)
    }
}
