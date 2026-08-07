import Foundation
import SwiftData
import Testing

@testable import cue

/// Everything a refresh test needs after the initial subscribe.
@MainActor
private struct Subscription {
    let context: ModelContext
    let transport: FeedTransportStub
    let service: FeedService
    let podcast: Podcast
}

/// Subscribes to `refresh-initial.rss` through a swappable transport.
@MainActor
private func subscribe() async throws -> Subscription {
    let context = try makeContext()
    let initial = try fixtureData(named: "refresh-initial", withExtension: "rss")
    let transport = FeedTransportStub(data: initial)
    let service = FeedService(context: context, transport: transport.transport)
    let podcast = try await service.add(urlString: testFeedURL)
    return Subscription(context: context, transport: transport, service: service, podcast: podcast)
}

@MainActor
private func updatedFeedData() throws -> Data {
    try fixtureData(named: "refresh-updated", withExtension: "rss")
}

@MainActor
struct FeedServiceRefreshTests {

    // MARK: - Additive merge

    /// Step 3's acceptance: refresh twice, no duplicates.
    @Test func refreshTwiceCreatesNoDuplicates() async throws {
        let sub = try await subscribe()

        try await sub.service.refresh(sub.podcast)
        try await sub.service.refresh(sub.podcast)

        #expect(try sub.context.fetch(FetchDescriptor<Podcast>()).count == 1)
        #expect(try sub.context.fetch(FetchDescriptor<Episode>()).count == 2)
        #expect(sub.podcast.episodes.count == 2)
    }

    @Test func refreshInsertsNewEpisodes() async throws {
        let sub = try await subscribe()
        sub.transport.serve(data: try updatedFeedData())

        try await sub.service.refresh(sub.podcast)

        let episodes = try sub.context.fetch(FetchDescriptor<Episode>())
        #expect(episodes.count == 3)
        let new = try #require(episodes.first { $0.guid == "refresh-example-0003" })
        #expect(new.title == "Refresh Episode 3")
        #expect(new.podcast === sub.podcast)
    }

    /// Exactly the mutable fields move: title, summary, publishedAt,
    /// enclosureURL and feedDuration on the episode, plus the four podcast
    /// metadata fields.
    @Test func refreshUpdatesMutableMetadata() async throws {
        let sub = try await subscribe()
        let episodes = try sub.context.fetch(FetchDescriptor<Episode>())
        let first = try #require(episodes.first { $0.guid == "refresh-example-0001" })
        #expect(first.title == "Refresh Episode 1")
        #expect(first.feedDuration == 600)
        sub.transport.serve(data: try updatedFeedData())

        try await sub.service.refresh(sub.podcast)

        #expect(first.title == "Refresh Episode 1 (Corrected)")
        #expect(first.summary == "The corrected summary of episode 1.")
        #expect(first.enclosureURL == "https://example.com/refresh/audio/episode-1-remastered.mp3")
        #expect(first.feedDuration == 1_200)
        #expect(first.publishedAt == Date(timeIntervalSince1970: 1_736_161_200))

        #expect(sub.podcast.title == "Refresh Example Podcast (Renamed)")
        #expect(sub.podcast.author == "Refresh Example Studio Ltd")
        #expect(sub.podcast.artworkURL == "https://example.com/refresh/artwork-new.jpg")
        #expect(sub.podcast.summary?.hasPrefix("The state of the feed after a refresh") == true)
    }

    /// The other direction, and the one a "defensive" `if let` would silently
    /// invert: a field the document stops carrying is *cleared*, because the
    /// feed owns these values and spec §6's "update mutable metadata" means the
    /// feed's current answer wins. (The parser's rule that an *empty* element
    /// never clears a value is about one document, not about two.)
    @Test func refreshClearsMetadataTheDocumentStopsCarrying() async throws {
        let sub = try await subscribe()
        let episodes = try sub.context.fetch(FetchDescriptor<Episode>())
        let first = try #require(episodes.first { $0.guid == "refresh-example-0001" })
        #expect(sub.podcast.author != nil)
        #expect(sub.podcast.artworkURL != nil)
        #expect(first.summary != nil)
        #expect(first.feedDuration != nil)
        #expect(first.publishedAt != nil)
        sub.transport.serve(data: try fixtureData(named: "refresh-stripped", withExtension: "rss"))

        try await sub.service.refresh(sub.podcast)

        #expect(sub.podcast.author == nil)
        #expect(sub.podcast.artworkURL == nil)
        #expect(sub.podcast.summary == nil)
        #expect(first.summary == nil)
        #expect(first.feedDuration == nil)
        #expect(first.publishedAt == nil)
        // and nothing was lost in the clearing
        #expect(sub.podcast.title == "Refresh Example Podcast")
        #expect(first.title == "Refresh Episode 1")
        #expect(try sub.context.fetch(FetchDescriptor<Episode>()).count == 2)
    }

    // MARK: - Invariants

    /// An episode that fell out of the feed window stays in the library —
    /// refresh is additive, it never deletes (spec §6).
    @Test func refreshKeepsEpisodesThatLeftTheFeedWindow() async throws {
        let sub = try await subscribe()
        sub.transport.serve(data: try updatedFeedData())

        try await sub.service.refresh(sub.podcast)

        let episodes = try sub.context.fetch(FetchDescriptor<Episode>())
        let dropped = try #require(episodes.first { $0.guid == "refresh-example-0002" })
        #expect(dropped.title == "Refresh Episode 2")
        #expect(dropped.podcast === sub.podcast)
        #expect(sub.podcast.episodes.count == 3)
    }

    /// Played state, download state, the measured asset duration and the session
    /// log all survive a refresh untouched — none of them is the feed's to write.
    @Test func refreshNeverTouchesPlayedDownloadOrSessionState() async throws {
        let sub = try await subscribe()
        let episodes = try sub.context.fetch(FetchDescriptor<Episode>())
        let first = try #require(episodes.first { $0.guid == "refresh-example-0001" })
        let playedAt = Date(timeIntervalSince1970: 4_000)
        let downloadedAt = Date(timeIntervalSince1970: 3_000)
        first.isPlayed = true
        first.playedAt = playedAt
        first.localFilename = "9C1B.mp3"
        first.downloadedAt = downloadedAt
        first.assetDuration = 987
        let session = PlaybackSession(
            startedAt: Date(timeIntervalSince1970: 2_500),
            startPosition: 0,
            endPosition: 120,
            rate: 1
        )
        session.episode = first
        sub.context.insert(session)
        let addedAt = Date(timeIntervalSince1970: 100)
        sub.podcast.addedAt = addedAt
        try sub.context.save()
        sub.transport.serve(data: try updatedFeedData())

        try await sub.service.refresh(sub.podcast)

        #expect(first.isPlayed)
        #expect(first.playedAt == playedAt)
        #expect(first.localFilename == "9C1B.mp3")
        #expect(first.downloadedAt == downloadedAt)
        #expect(first.assetDuration == 987)
        #expect(first.sessions.count == 1)
        #expect(first.currentPosition == 120)
        #expect(sub.podcast.addedAt == addedAt)
        // the metadata the feed does own still moved
        #expect(first.title == "Refresh Episode 1 (Corrected)")
    }

    // MARK: - lastRefreshedAt

    @Test func refreshStampsLastRefreshedAtOnSuccess() async throws {
        let sub = try await subscribe()
        sub.podcast.lastRefreshedAt = Date(timeIntervalSince1970: 1)

        let before = Date()
        try await sub.service.refresh(sub.podcast)

        let stamped = try #require(sub.podcast.lastRefreshedAt)
        #expect(stamped >= before)
    }

    @Test func refreshLeavesLastRefreshedAtOnTransportFailure() async throws {
        let sub = try await subscribe()
        let stale = Date(timeIntervalSince1970: 1)
        sub.podcast.lastRefreshedAt = stale
        try sub.context.save()
        sub.transport.fail(with: StubTransportError.offline)

        await #expect(throws: StubTransportError.offline) {
            try await sub.service.refresh(sub.podcast)
        }
        #expect(sub.podcast.lastRefreshedAt == stale)
        #expect(try sub.context.fetch(FetchDescriptor<Episode>()).count == 2)
    }

    @Test func refreshLeavesLastRefreshedAtOnHTTPFailure() async throws {
        let sub = try await subscribe()
        let stale = Date(timeIntervalSince1970: 1)
        sub.podcast.lastRefreshedAt = stale
        try sub.context.save()
        sub.transport.serve(statusCode: 401)

        await #expect(throws: FeedService.Failure.httpStatus(401, testFeedURL)) {
            try await sub.service.refresh(sub.podcast)
        }
        #expect(sub.podcast.lastRefreshedAt == stale)
        #expect(try sub.context.fetch(FetchDescriptor<Episode>()).count == 2)
    }

    // MARK: - A good feed briefly serving junk

    /// The most destructive plausible refresh: a healthy feed answers 200 with a
    /// truncated document. Nothing is written and nothing is lost — the library
    /// is not what a parse failure gets to edit.
    @Test func refreshOnMalformedDocumentChangesNothing() async throws {
        let sub = try await subscribe()
        let stale = Date(timeIntervalSince1970: 1)
        sub.podcast.lastRefreshedAt = stale
        try sub.context.save()
        sub.transport.serve(data: try fixtureData(named: "malformed", withExtension: "rss"))

        await #expect(throws: FeedParser.Failure.malformedXML) {
            try await sub.service.refresh(sub.podcast)
        }

        #expect(sub.podcast.title == "Refresh Example Podcast")
        #expect(sub.podcast.lastRefreshedAt == stale)
        let titles = try sub.context.fetch(FetchDescriptor<Episode>()).map(\.title).sorted()
        #expect(titles == ["Refresh Episode 1", "Refresh Episode 2"])
    }

    /// A 200 whose body parses to zero episodes is an error, never "the show
    /// ended" — refresh is additive and deletes nothing (spec §6).
    @Test func refreshOnEmptyDocumentKeepsEveryEpisode() async throws {
        let sub = try await subscribe()
        let stale = Date(timeIntervalSince1970: 1)
        sub.podcast.lastRefreshedAt = stale
        try sub.context.save()
        sub.transport.serve(data: try fixtureData(named: "no-enclosures", withExtension: "rss"))

        await #expect(throws: FeedParser.Failure.emptyFeed(testFeedURL)) {
            try await sub.service.refresh(sub.podcast)
        }

        #expect(sub.podcast.title == "Refresh Example Podcast")
        #expect(sub.podcast.lastRefreshedAt == stale)
        #expect(try sub.context.fetch(FetchDescriptor<Episode>()).count == 2)
    }

    // MARK: - The request itself

    /// A refresh asks for the podcast's own stored address, byte for byte —
    /// a re-encoded token would answer 401 on a private feed (spec §6).
    @Test func refreshRequestsThePodcastsFeedURLVerbatim() async throws {
        let sub = try await subscribe()

        try await sub.service.refresh(sub.podcast)

        #expect(sub.transport.requestedURLStrings == [testFeedURL, testFeedURL])
    }

    // MARK: - Persistence

    /// Observed through a second context, so a dropped `save()` cannot pass.
    @Test func refreshCommitsThroughToTheStore() async throws {
        let sub = try await subscribe()
        sub.transport.serve(data: try updatedFeedData())

        try await sub.service.refresh(sub.podcast)

        let observer = ModelContext(sub.context.container)
        let episodes = try observer.fetch(FetchDescriptor<Episode>())
        #expect(episodes.count == 3)
        let corrected = try #require(episodes.first { $0.guid == "refresh-example-0001" })
        #expect(corrected.title == "Refresh Episode 1 (Corrected)")
    }
}
