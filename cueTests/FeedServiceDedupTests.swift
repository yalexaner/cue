import Foundation
import SwiftData
import Testing

@testable import cue

private let otherFeedURL = "https://example.com/other"

@MainActor
private func service(in context: ModelContext, serving fixture: String) throws -> FeedService {
    let stub = FeedTransportStub(data: try fixtureData(named: fixture, withExtension: "rss"))
    return FeedService(context: context, transport: stub.transport)
}

@MainActor
struct FeedServiceDedupTests {

    /// Re-adding a subscribed feed is a refresh: no second podcast, no duplicate
    /// episodes, and none of the metadata the destructive `#Unique` upsert would
    /// have cleared (`uniqueFeedURLUpsertOverwritesPodcastMetadata`).
    @Test func addingSubscribedFeedMergesInsteadOfOverwriting() async throws {
        let context = try makeContext()
        let service = try service(in: context, serving: "tokenised")

        _ = try await service.add(urlString: testFeedURL)
        let addedAt = Date(timeIntervalSince1970: 500)
        let podcast = try #require(try context.fetch(FetchDescriptor<Podcast>()).first)
        podcast.addedAt = addedAt
        try context.save()

        _ = try await service.add(urlString: testFeedURL)

        let podcasts = try context.fetch(FetchDescriptor<Podcast>())
        #expect(podcasts.count == 1)
        let merged = try #require(podcasts.first)
        #expect(merged.addedAt == addedAt)
        #expect(merged.author == "Пример Приватной Студии")
        #expect(merged.artworkURL == "https://example.com/private/artwork.jpg")
        #expect(
            merged.summary
                == "Еженедельные бонусные выпуски. Каждый адрес в этой фикстуре — заглушка.")
        #expect(merged.episodes.count == 2)
        #expect(try context.fetch(FetchDescriptor<Episode>()).count == 2)
    }

    /// Download and played state set between two adds survive the second one.
    @Test func addingSubscribedFeedKeepsPlayedAndDownloadState() async throws {
        let context = try makeContext()
        let service = try service(in: context, serving: "simple")

        _ = try await service.add(urlString: testFeedURL)
        let episodes = try context.fetch(FetchDescriptor<Episode>())
        let episode = try #require(episodes.first { $0.guid == "simple-example-0001" })
        let playedAt = Date(timeIntervalSince1970: 2_000)
        episode.isPlayed = true
        episode.playedAt = playedAt
        episode.localFilename = "3F2A.mp3"
        episode.downloadedAt = Date(timeIntervalSince1970: 1_000)
        try context.save()

        _ = try await service.add(urlString: testFeedURL)

        let refetched = try context.fetch(FetchDescriptor<Episode>())
        #expect(refetched.count == 3)
        let same = try #require(refetched.first { $0.guid == "simple-example-0001" })
        #expect(same.isPlayed)
        #expect(same.playedAt == playedAt)
        #expect(same.localFilename == "3F2A.mp3")
        #expect(same.downloadedAt == Date(timeIntervalSince1970: 1_000))
    }

    /// A guid already owned by a different show is skipped — never stolen, never
    /// overwritten (`guidUniquenessIsGlobalNotPerPodcast`).
    @Test func addSkipsGUIDOwnedByAnotherPodcast() async throws {
        let context = try makeContext()
        let other = Podcast(feedURL: otherFeedURL, title: "Other Show")
        context.insert(other)
        let taken = Episode(
            guid: "simple-example-0001",
            title: "Owned elsewhere",
            enclosureURL: "https://example.com/other/1.mp3"
        )
        taken.podcast = other
        context.insert(taken)
        try context.save()

        _ = try await service(in: context, serving: "simple").add(urlString: testFeedURL)

        let episodes = try context.fetch(FetchDescriptor<Episode>())
        #expect(episodes.count == 3)
        let contested = try #require(episodes.first { $0.guid == "simple-example-0001" })
        #expect(contested.title == "Owned elsewhere")
        #expect(contested.podcast?.feedURL == otherFeedURL)

        let added = try #require(episodes.first { $0.podcast?.feedURL == testFeedURL }?.podcast)
        #expect(added.episodes.count == 2)
    }

    /// A guid held by an episode belonging to no podcast at all is skipped by the
    /// same identity check, and skipping is the safe answer: adopting an orphan
    /// would hand this show a row whose history it never had. The add still
    /// succeeds on the episodes that are free.
    @Test func addSkipsGUIDHeldByAnEpisodeWithNoPodcast() async throws {
        let context = try makeContext()
        let orphan = Episode(
            guid: "simple-example-0001",
            title: "Orphaned",
            enclosureURL: "https://example.com/orphan/1.mp3"
        )
        context.insert(orphan)
        try context.save()

        _ = try await service(in: context, serving: "simple").add(urlString: testFeedURL)

        let podcast = try #require(try context.fetch(FetchDescriptor<Podcast>()).first)
        #expect(podcast.episodes.count == 2)
        #expect(orphan.title == "Orphaned")
        #expect(orphan.podcast == nil)
        #expect(try context.fetch(FetchDescriptor<Episode>()).count == 3)
    }

    /// The token-rotation trap: the same show re-added under a new URL matches no
    /// subscription, yet every guid it carries is owned by the old one. Spec §6
    /// forbids adding an empty podcast, so this is an error — not a success that
    /// leaves an empty, undeletable library row behind.
    ///
    /// Asserted through the *primary* context on purpose. Nothing is ever saved
    /// on this path, so an observer context cannot see the difference between a
    /// cancelled insert and one still pending — and a pending insert is exactly
    /// what the app's autosaving context would commit moments later.
    @Test func addRejectsFeedWhoseEpisodesAllBelongToAnotherPodcast() async throws {
        let context = try makeContext()
        let service = try service(in: context, serving: "simple")
        try await service.add(urlString: otherFeedURL)

        await #expect(throws: FeedService.Failure.allEpisodesOwnedElsewhere(testFeedURL)) {
            _ = try await service.add(urlString: testFeedURL)
        }

        let podcasts = try context.fetch(FetchDescriptor<Podcast>())
        #expect(podcasts.count == 1)
        #expect(podcasts.first?.feedURL == otherFeedURL)
        #expect(try context.fetch(FetchDescriptor<Episode>()).count == 3)

        // and the cancelled insert stays cancelled once autosave catches up
        try context.save()
        let observer = ModelContext(context.container)
        #expect(try observer.fetch(FetchDescriptor<Podcast>()).count == 1)
    }

    /// The guard is about a *new* subscription only: an already-subscribed feed
    /// that contributes nothing new this time is an ordinary no-op refresh.
    @Test func addingSubscribedFeedWithNoNewEpisodesIsNotAnError() async throws {
        let context = try makeContext()
        let service = try service(in: context, serving: "simple")

        try await service.add(urlString: testFeedURL)
        try await service.add(urlString: testFeedURL)

        #expect(try context.fetch(FetchDescriptor<Podcast>()).count == 1)
        #expect(try context.fetch(FetchDescriptor<Episode>()).count == 3)
    }

    /// The other half of the same guard, and the destructive one if it were ever
    /// dropped: a subscribed feed whose document now carries only another show's
    /// guids contributes nothing, yet must not be deleted. `Podcast.episodes`
    /// cascades, so refusing this add would destroy the show and every episode.
    @Test func subscribedFeedContributingNothingIsKeptNotDeleted() async throws {
        let context = try makeContext()
        try await service(in: context, serving: "tokenised").add(urlString: testFeedURL)
        try await service(in: context, serving: "simple").add(urlString: otherFeedURL)

        // the subscribed feed now serves a document made entirely of the other
        // show's guids — every episode is skipped as owned elsewhere
        try await service(in: context, serving: "simple").add(urlString: testFeedURL)

        let podcasts = try context.fetch(FetchDescriptor<Podcast>())
        #expect(podcasts.count == 2)
        let subscribed = try #require(podcasts.first { $0.feedURL == testFeedURL })
        #expect(subscribed.episodes.count == 2)
        #expect(subscribed.episodes.contains { $0.title == "Бонус 1: За Стеной Оплаты" })
        #expect(try context.fetch(FetchDescriptor<Episode>()).count == 5)
    }
}
