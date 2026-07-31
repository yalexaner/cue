import Foundation
import SwiftData
import Testing

@testable import cue

private let testFeedURL = "https://example.com/feed?token=REDACTED_TEST_TOKEN"

@MainActor
private func makeContext() throws -> ModelContext {
    let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try ModelContainer(
        for: Podcast.self, Episode.self, PlaybackSession.self,
        configurations: configuration
    )
    return ModelContext(container)
}

@MainActor
struct ModelTests {
    @Test func podcastRoundTrips() throws {
        let context = try makeContext()
        let before = Date()
        let podcast = Podcast(feedURL: testFeedURL, title: "Example Show")
        podcast.author = "Example Author"
        context.insert(podcast)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<Podcast>())
        #expect(fetched.count == 1)
        // addedAt is the one field the initialiser sets implicitly
        let addedAt = try #require(fetched.first?.addedAt)
        #expect(addedAt >= before)
        #expect(addedAt <= Date())
        #expect(fetched.first?.feedURL == testFeedURL)
        #expect(fetched.first?.title == "Example Show")
        #expect(fetched.first?.author == "Example Author")
        #expect(fetched.first?.summary == nil)
        #expect(fetched.first?.lastRefreshedAt == nil)
        #expect(fetched.first?.episodes.isEmpty == true)
    }

    @Test func episodeRoundTrips() throws {
        let context = try makeContext()
        let episode = Episode(
            guid: "guid-1",
            title: "Episode One",
            enclosureURL: "https://example.com/audio/1.mp3"
        )
        episode.feedDuration = 120
        episode.localFilename = "3F2A.mp3"
        context.insert(episode)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<Episode>())
        #expect(fetched.count == 1)
        #expect(fetched.first?.guid == "guid-1")
        #expect(fetched.first?.enclosureURL == "https://example.com/audio/1.mp3")
        #expect(fetched.first?.feedDuration == 120)
        #expect(fetched.first?.assetDuration == nil)
        #expect(fetched.first?.localFilename == "3F2A.mp3")
        #expect(fetched.first?.isPlayed == false)
        #expect(fetched.first?.playedAt == nil)
        #expect(fetched.first?.podcast == nil)
    }

    @Test func playbackSessionRoundTrips() throws {
        let context = try makeContext()
        let startedAt = Date(timeIntervalSince1970: 1_000)
        let session = PlaybackSession(
            startedAt: startedAt,
            startPosition: 10,
            endPosition: 42,
            rate: 1.5
        )
        context.insert(session)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<PlaybackSession>())
        #expect(fetched.count == 1)
        #expect(fetched.first?.startedAt == startedAt)
        #expect(fetched.first?.endedAt == nil)
        #expect(fetched.first?.startPosition == 10)
        #expect(fetched.first?.endPosition == 42)
        #expect(fetched.first?.rate == 1.5)
        #expect(fetched.first?.episode == nil)
    }

    @Test func finishedPlaybackSessionRoundTripsItsEndedAt() throws {
        let context = try makeContext()
        let endedAt = Date(timeIntervalSince1970: 2_000)
        let session = PlaybackSession(
            startedAt: Date(timeIntervalSince1970: 1_000),
            startPosition: 0,
            endPosition: 42,
            rate: 1
        )
        // nil means the session is live; a finished one must persist its end
        session.endedAt = endedAt
        context.insert(session)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<PlaybackSession>())
        #expect(fetched.first?.endedAt == endedAt)
    }

    @Test func podcastRelationshipLinksBothWays() throws {
        let context = try makeContext()
        let podcast = Podcast(feedURL: testFeedURL, title: "Example Show")
        let episode = Episode(guid: "guid-1", title: "One", enclosureURL: "https://example.com/1.mp3")
        episode.podcast = podcast
        context.insert(podcast)
        context.insert(episode)
        try context.save()

        #expect(podcast.episodes.count == 1)
        #expect(episode.podcast?.feedURL == testFeedURL)
    }

    @Test func deletingPodcastCascadesEpisodes() throws {
        let context = try makeContext()
        let podcast = Podcast(feedURL: testFeedURL, title: "Example Show")
        context.insert(podcast)
        for index in 0..<3 {
            let episode = Episode(
                guid: "guid-\(index)",
                title: "Episode \(index)",
                enclosureURL: "https://example.com/\(index).mp3"
            )
            episode.podcast = podcast
            context.insert(episode)
        }
        try context.save()
        #expect(try context.fetch(FetchDescriptor<Episode>()).count == 3)

        context.delete(podcast)
        try context.save()

        #expect(try context.fetch(FetchDescriptor<Podcast>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<Episode>()).isEmpty)
    }

    @Test func deletingEpisodeCascadesSessions() throws {
        let context = try makeContext()
        let episode = Episode(guid: "guid-1", title: "One", enclosureURL: "https://example.com/1.mp3")
        context.insert(episode)
        for index in 0..<2 {
            let session = PlaybackSession(
                startedAt: Date(timeIntervalSince1970: TimeInterval(index)),
                startPosition: 0,
                endPosition: 10,
                rate: 1
            )
            session.episode = episode
            context.insert(session)
        }
        try context.save()
        #expect(try context.fetch(FetchDescriptor<PlaybackSession>()).count == 2)

        context.delete(episode)
        try context.save()

        #expect(try context.fetch(FetchDescriptor<Episode>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<PlaybackSession>()).isEmpty)
    }

    @Test func deletingEpisodeLeavesPodcastIntact() throws {
        let context = try makeContext()
        let podcast = Podcast(feedURL: testFeedURL, title: "Example Show")
        let episode = Episode(guid: "guid-1", title: "One", enclosureURL: "https://example.com/1.mp3")
        episode.podcast = podcast
        context.insert(podcast)
        context.insert(episode)
        try context.save()

        context.delete(episode)
        try context.save()

        #expect(try context.fetch(FetchDescriptor<Podcast>()).count == 1)
        #expect(podcast.episodes.isEmpty)
    }

    @Test func uniqueFeedURLUpsertsPodcast() throws {
        let context = try makeContext()
        context.insert(Podcast(feedURL: testFeedURL, title: "First"))
        try context.save()

        context.insert(Podcast(feedURL: testFeedURL, title: "Second"))
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<Podcast>())
        #expect(fetched.count == 1)
        #expect(fetched.first?.title == "Second")
    }

    /// The `Podcast` half of the destructive `#Unique` upsert.
    ///
    /// Re-adding an already-subscribed feed — the natural shape of "add feed"
    /// and OPML import (spec §6) — resets every scalar the new instance does not
    /// set, so artwork, author and summary vanish and `addedAt` moves. Only the
    /// `episodes` cascade survives. Add-feed must fetch-then-mutate too.
    @Test func uniqueFeedURLUpsertOverwritesPodcastMetadata() throws {
        let context = try makeContext()
        let first = Podcast(feedURL: testFeedURL, title: "First")
        first.author = "Author"
        first.summary = "Summary"
        first.artworkURL = "https://example.com/art.png"
        first.lastRefreshedAt = Date(timeIntervalSince1970: 1_000)
        first.addedAt = Date(timeIntervalSince1970: 500)
        context.insert(first)
        try context.save()

        context.insert(Podcast(feedURL: testFeedURL, title: "Second"))
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<Podcast>())
        #expect(fetched.count == 1)
        #expect(fetched.first?.author == nil)
        #expect(fetched.first?.summary == nil)
        #expect(fetched.first?.artworkURL == nil)
        #expect(fetched.first?.lastRefreshedAt == nil)
        #expect(fetched.first?.addedAt != Date(timeIntervalSince1970: 500))
    }

    @Test func distinctFeedURLsCoexist() throws {
        let context = try makeContext()
        context.insert(Podcast(feedURL: testFeedURL, title: "First"))
        context.insert(Podcast(feedURL: "https://example.com/other", title: "Second"))
        try context.save()

        #expect(try context.fetch(FetchDescriptor<Podcast>()).count == 2)
    }

    @Test func uniqueGUIDUpsertsEpisode() throws {
        let context = try makeContext()
        context.insert(Episode(guid: "guid-1", title: "First", enclosureURL: "https://example.com/1.mp3"))
        try context.save()

        context.insert(Episode(guid: "guid-1", title: "Second", enclosureURL: "https://example.com/2.mp3"))
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<Episode>())
        #expect(fetched.count == 1)
        #expect(fetched.first?.title == "Second")
    }

    /// Pins the destructive half of the `#Unique` upsert.
    ///
    /// A conflicting `insert` overwrites *every* scalar with the new instance's
    /// value, including the defaults for fields the new instance never set. So
    /// refresh (ROADMAP §3) must fetch-then-mutate, never blind-insert — spec §6
    /// forbids touching `isPlayed`, `localFilename` or sessions on refresh, and
    /// a blind insert violates all three.
    @Test func uniqueGUIDUpsertOverwritesDownloadAndPlayedState() throws {
        let context = try makeContext()
        let first = Episode(guid: "guid-1", title: "First", enclosureURL: "https://example.com/1.mp3")
        first.localFilename = "3F2A.mp3"
        first.downloadedAt = Date(timeIntervalSince1970: 1_000)
        first.isPlayed = true
        first.playedAt = Date(timeIntervalSince1970: 2_000)
        context.insert(first)
        try context.save()

        context.insert(Episode(guid: "guid-1", title: "Second", enclosureURL: "https://example.com/2.mp3"))
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<Episode>())
        #expect(fetched.count == 1)
        #expect(fetched.first?.localFilename == nil)
        #expect(fetched.first?.downloadedAt == nil)
        #expect(fetched.first?.isPlayed == false)
        #expect(fetched.first?.playedAt == nil)
    }

    /// Pins that `guid` uniqueness is store-wide, not scoped to a podcast.
    ///
    /// Bare-integer guids (`1`, `2`, …) are common in real feeds, so two
    /// subscriptions can collide and one loses its episode. Recorded here so the
    /// trade-off is visible before feed ingestion lands.
    @Test func guidUniquenessIsGlobalNotPerPodcast() throws {
        let context = try makeContext()
        let showA = Podcast(feedURL: testFeedURL, title: "Show A")
        let showB = Podcast(feedURL: "https://example.com/other", title: "Show B")
        context.insert(showA)
        context.insert(showB)

        let inA = Episode(guid: "1", title: "A one", enclosureURL: "https://example.com/a/1.mp3")
        inA.podcast = showA
        context.insert(inA)
        try context.save()

        let inB = Episode(guid: "1", title: "B one", enclosureURL: "https://example.com/b/1.mp3")
        inB.podcast = showB
        context.insert(inB)
        try context.save()

        #expect(try context.fetch(FetchDescriptor<Episode>()).count == 1)
    }

    @Test func distinctGUIDsCoexist() throws {
        let context = try makeContext()
        context.insert(Episode(guid: "guid-1", title: "First", enclosureURL: "https://example.com/1.mp3"))
        context.insert(Episode(guid: "guid-2", title: "Second", enclosureURL: "https://example.com/2.mp3"))
        try context.save()

        #expect(try context.fetch(FetchDescriptor<Episode>()).count == 2)
    }
}
