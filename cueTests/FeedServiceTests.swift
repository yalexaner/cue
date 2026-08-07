import Foundation
import SwiftData
import Testing

@testable import cue

@MainActor
private func stub(named fixture: String, statusCode: Int = 200) throws -> FeedTransportStub {
    let stub = FeedTransportStub(data: try fixtureData(named: fixture, withExtension: "rss"))
    stub.serve(statusCode: statusCode)
    return stub
}

@MainActor
struct FeedServiceAddTests {

    // MARK: - The production request

    /// The cache policy is a correctness requirement, not a tuning knob: refresh
    /// is manual only (spec §6), so a feed sending `Cache-Control: max-age`
    /// would otherwise make a pull-to-refresh a silent no-op.
    @Test func theProductionRequestRevalidatesAndKeepsTheURLVerbatim() throws {
        let url = try #require(URL(string: testFeedURL))

        let request = FeedService.feedRequest(for: url)

        #expect(request.cachePolicy == .reloadRevalidatingCacheData)
        #expect(request.url?.absoluteString == testFeedURL)
    }

    // MARK: - Success

    @Test func addPersistsPodcastAndEpisodes() async throws {
        let context = try makeContext()
        let service = FeedService(context: context, transport: try stub(named: "simple").transport)

        let before = Date()
        try await service.add(urlString: testFeedURL)

        let podcasts = try context.fetch(FetchDescriptor<Podcast>())
        #expect(podcasts.count == 1)
        let podcast = try #require(podcasts.first)
        #expect(podcast.feedURL == testFeedURL)
        #expect(podcast.title == "Simple Example Podcast")
        #expect(podcast.author == "editor@example.com (Simple Example Editor)")
        #expect(podcast.episodes.count == 3)
        let refreshedAt = try #require(podcast.lastRefreshedAt)
        #expect(refreshedAt >= before)

        let episodes = try context.fetch(FetchDescriptor<Episode>())
        #expect(episodes.count == 3)
        let first = try #require(episodes.first { $0.guid == "simple-example-0001" })
        #expect(first.title == "Episode 1: Getting Started")
        #expect(first.enclosureURL == "https://example.com/simple/audio/episode-1.mp3")
        #expect(first.summary == "The first episode of the simple example podcast.")
        #expect(first.publishedAt == Date(timeIntervalSince1970: 1_736_154_000))
        #expect(first.podcast === podcast)
        // untouched by ingestion: played and download state are orthogonal
        #expect(first.isPlayed == false)
        #expect(first.localFilename == nil)
    }

    /// The feed URL and the enclosure URLs keep their tokens byte for byte, and
    /// `itunes:duration` lands on `feedDuration`, never on `assetDuration`.
    @Test func addStoresTokenisedURLsVerbatimAndFeedDuration() async throws {
        let context = try makeContext()
        let service = FeedService(context: context, transport: try stub(named: "tokenised").transport)

        try await service.add(urlString: testFeedURL)

        let podcast = try #require(try context.fetch(FetchDescriptor<Podcast>()).first)
        #expect(podcast.feedURL == testFeedURL)
        #expect(podcast.title == "Пример Закрытого Фида")
        #expect(podcast.author == "Пример Приватной Студии")
        #expect(podcast.artworkURL == "https://example.com/private/artwork.jpg")

        let episodes = try context.fetch(FetchDescriptor<Episode>())
        #expect(episodes.count == 2)
        let bonusOne = try #require(episodes.first { $0.title == "Бонус 1: За Стеной Оплаты" })
        let expectedEnclosure = "https://example.com/private/audio/bonus-1.mp3?token=REDACTED_TEST_TOKEN"
        #expect(bonusOne.enclosureURL == expectedEnclosure)
        #expect(bonusOne.feedDuration == 1_880)
        #expect(bonusOne.assetDuration == nil)

        let bonusTwo = try #require(episodes.first { $0.title == "Бонус 2: Всё Ещё За Стеной Оплаты" })
        #expect(bonusTwo.feedDuration == nil)
    }

    /// The URL is *requested* verbatim, not merely stored so: `URL(string:)` is
    /// the only thing between the pasted string and the wire, and a private
    /// feed whose token were re-encoded would answer 401 (spec §6).
    @Test func addRequestsTheURLVerbatim() async throws {
        let context = try makeContext()
        let transport = try stub(named: "tokenised")
        let service = FeedService(context: context, transport: transport.transport)

        try await service.add(urlString: testFeedURL)

        #expect(transport.requestedURLStrings == [testFeedURL])
    }

    /// Saved, not merely resident: every other assertion in this suite reads the
    /// same context that did the inserting, which cannot tell a committed store
    /// from pending changes. A dropped `save()` would survive all of them.
    ///
    /// Counts alone would not: the values and the podcast↔episode link have to
    /// be read back through the observer too, since a relationship never written
    /// through is exactly what a row count cannot catch.
    @Test func addCommitsThroughToTheStore() async throws {
        let context = try makeContext()
        let service = FeedService(context: context, transport: try stub(named: "simple").transport)

        try await service.add(urlString: testFeedURL)

        let observer = ModelContext(context.container)
        let podcasts = try observer.fetch(FetchDescriptor<Podcast>())
        #expect(podcasts.count == 1)
        let podcast = try #require(podcasts.first)
        #expect(podcast.feedURL == testFeedURL)
        #expect(podcast.title == "Simple Example Podcast")
        #expect(podcast.author == "editor@example.com (Simple Example Editor)")

        let episodes = try observer.fetch(FetchDescriptor<Episode>())
        #expect(episodes.count == 3)
        let first = try #require(episodes.first { $0.guid == "simple-example-0001" })
        #expect(first.title == "Episode 1: Getting Started")
        #expect(first.enclosureURL == "https://example.com/simple/audio/episode-1.mp3")
        #expect(first.publishedAt == Date(timeIntervalSince1970: 1_736_154_000))
        #expect(first.podcast?.feedURL == testFeedURL)
    }

    /// A document that lists one guid twice yields one episode, not two — two
    /// rows sharing a guid trip the destructive `#Unique` upsert on save.
    @Test func addDeduplicatesRepeatedGUIDWithinOneDocument() async throws {
        let context = try makeContext()
        let service = FeedService(context: context, transport: try stub(named: "duplicate-guid").transport)

        try await service.add(urlString: testFeedURL)

        let observer = ModelContext(context.container)
        let episodes = try observer.fetch(FetchDescriptor<Episode>())
        #expect(episodes.count == 2)
        let repeated = try #require(episodes.first { $0.guid == "duplicate-example-0001" })
        // the later listing wins, exactly as a second document would
        #expect(repeated.title == "Repeated Episode (second listing)")
        #expect(repeated.feedDuration == 1_200)
    }

    /// The repeated guid is still one episode after a second add, and the
    /// played and download state set between the two survives it.
    @Test func repeatedGUIDKeepsPlayedAndDownloadStateAcrossAdds() async throws {
        let context = try makeContext()
        let service = FeedService(context: context, transport: try stub(named: "duplicate-guid").transport)

        try await service.add(urlString: testFeedURL)
        let episodes = try context.fetch(FetchDescriptor<Episode>())
        let repeated = try #require(episodes.first { $0.guid == "duplicate-example-0001" })
        repeated.isPlayed = true
        repeated.localFilename = "7B4C.mp3"
        try context.save()

        try await service.add(urlString: testFeedURL)

        let refetched = try context.fetch(FetchDescriptor<Episode>())
        #expect(refetched.count == 2)
        let same = try #require(refetched.first { $0.guid == "duplicate-example-0001" })
        #expect(same.isPlayed)
        #expect(same.localFilename == "7B4C.mp3")
    }

    // MARK: - Error paths

    @Test func addRejectsUnparseableInput() async throws {
        let context = try makeContext()
        let service = FeedService(context: context, transport: try stub(named: "simple").transport)

        await #expect(throws: FeedService.Failure.invalidURL("")) {
            _ = try await service.add(urlString: "")
        }
        #expect(try context.fetch(FetchDescriptor<Podcast>()).isEmpty)
    }

    @Test func addRejectsNonHTTPSchemes() async throws {
        let context = try makeContext()
        let service = FeedService(context: context, transport: try stub(named: "simple").transport)

        await #expect(throws: FeedService.Failure.invalidURL("ftp://example.com/feed")) {
            _ = try await service.add(urlString: "ftp://example.com/feed")
        }
        await #expect(throws: FeedService.Failure.invalidURL("example.com/feed")) {
            _ = try await service.add(urlString: "example.com/feed")
        }
        #expect(try context.fetch(FetchDescriptor<Podcast>()).isEmpty)
    }

    /// A private feed answering 403 must be diagnosable at add time — the status
    /// and the URL both travel with the error.
    @Test func addSurfacesHTTPStatus() async throws {
        let context = try makeContext()
        let transport = try stub(named: "simple", statusCode: 403).transport
        let service = FeedService(context: context, transport: transport)

        await #expect(throws: FeedService.Failure.httpStatus(403, testFeedURL)) {
            _ = try await service.add(urlString: testFeedURL)
        }
        #expect(try context.fetch(FetchDescriptor<Podcast>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<Episode>()).isEmpty)
    }

    /// The gate is 2xx, not "under 400" and not "200 or more": 299 is accepted,
    /// 300 and 199 are not, so neither a redirect body nor an interim response
    /// is ever mistaken for a feed and reported as a parse failure.
    @Test func addAcceptsOnlyTwoHundredRangeStatuses() async throws {
        let belowRange = try makeContext()
        let belowRangeService = FeedService(
            context: belowRange, transport: try stub(named: "simple", statusCode: 199).transport)
        await #expect(throws: FeedService.Failure.httpStatus(199, testFeedURL)) {
            _ = try await belowRangeService.add(urlString: testFeedURL)
        }
        #expect(try belowRange.fetch(FetchDescriptor<Podcast>()).isEmpty)

        let accepting = try makeContext()
        let acceptingService = FeedService(
            context: accepting, transport: try stub(named: "simple", statusCode: 299).transport)
        try await acceptingService.add(urlString: testFeedURL)
        #expect(try accepting.fetch(FetchDescriptor<Podcast>()).count == 1)

        let rejecting = try makeContext()
        let rejectingService = FeedService(
            context: rejecting, transport: try stub(named: "simple", statusCode: 300).transport)
        await #expect(throws: FeedService.Failure.httpStatus(300, testFeedURL)) {
            _ = try await rejectingService.add(urlString: testFeedURL)
        }
        #expect(try rejecting.fetch(FetchDescriptor<Podcast>()).isEmpty)
    }

    /// A response that is not an `HTTPURLResponse` carries no status to judge,
    /// so the document is parsed rather than rejected.
    @Test func addAcceptsAResponseWithNoHTTPStatus() async throws {
        let context = try makeContext()
        let data = try fixtureData(named: "simple", withExtension: "rss")
        let service = FeedService(context: context, transport: nonHTTPTransport(data: data))

        try await service.add(urlString: testFeedURL)

        #expect(try context.fetch(FetchDescriptor<Podcast>()).count == 1)
    }

    /// A fetched document with zero episodes is a failure naming the URL, and
    /// nothing at all is written — not even the channel metadata.
    @Test func addRejectsFeedWithNoEpisodes() async throws {
        let context = try makeContext()
        let service = FeedService(context: context, transport: try stub(named: "no-enclosures").transport)

        await #expect(throws: FeedParser.Failure.emptyFeed(testFeedURL)) {
            _ = try await service.add(urlString: testFeedURL)
        }
        #expect(try context.fetch(FetchDescriptor<Podcast>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<Episode>()).isEmpty)
    }

    /// Transport errors are not wrapped: the caller sees what actually failed.
    @Test func addPropagatesTransportError() async throws {
        let context = try makeContext()
        let service = FeedService(context: context, transport: failingTransport())

        await #expect(throws: StubTransportError.offline) {
            _ = try await service.add(urlString: testFeedURL)
        }
        #expect(try context.fetch(FetchDescriptor<Podcast>()).isEmpty)
    }

    /// Cancel dismisses the sheet while the request may already be answered.
    /// The response winning that race is not consent, so nothing is committed —
    /// otherwise the subscription the user backed out of appears in the library.
    @Test func addCancelledAfterTheResponseCommitsNothing() async throws {
        let context = try makeContext()
        let service = FeedService(context: context, transport: try stub(named: "simple").transport)

        // the task body is main-actor isolated and nothing here suspends before
        // `cancel()` lands, so the whole add runs already cancelled
        // `Podcast` is deliberately not `Sendable`, so the result stays inside
        let add = Task { @MainActor in
            _ = try await service.add(urlString: testFeedURL)
        }
        add.cancel()

        await #expect(throws: CancellationError.self) { try await add.value }
        #expect(try context.fetch(FetchDescriptor<Podcast>()).isEmpty)
        #expect(try context.fetch(FetchDescriptor<Episode>()).isEmpty)
    }

    @Test func addPropagatesParserError() async throws {
        let context = try makeContext()
        let service = FeedService(context: context, transport: try stub(named: "malformed").transport)

        await #expect(throws: FeedParser.Failure.malformedXML) {
            _ = try await service.add(urlString: testFeedURL)
        }
        #expect(try context.fetch(FetchDescriptor<Podcast>()).isEmpty)
    }
}
