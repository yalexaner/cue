import Foundation
import Testing

@testable import cue

/// Field mapping, fallbacks and skip rules against the committed fixtures (spec §6).
struct FeedParserTests {
    // MARK: - simple.rss

    @Test func simpleFeedParsesChannelMetadata() throws {
        let feed = try parseFixture("simple")

        #expect(feed.title == "Simple Example Podcast")
        #expect(feed.author == "editor@example.com (Simple Example Editor)")
        #expect(feed.summary?.hasPrefix("A minimal RSS 2.0 podcast feed") == true)
        #expect(feed.artworkURL == nil)
    }

    @Test func simpleFeedParsesEveryEpisode() throws {
        let feed = try parseFixture("simple")
        #expect(feed.episodes.count == 3)

        let first = try #require(feed.episodes.first)
        #expect(first.guid == "simple-example-0001")
        #expect(first.title == "Episode 1: Getting Started")
        #expect(first.summary == "The first episode of the simple example podcast.")
        #expect(first.enclosureURL == "https://example.com/simple/audio/episode-1.mp3")
        #expect(first.duration == nil)
        try expect(first.publishedAt, matches: "2025-01-06T09:00:00Z")

        #expect(feed.episodes.map(\.guid) == expectedSimpleGUIDs)
        #expect(feed.episodes.allSatisfy { $0.publishedAt != nil })
        #expect(feed.episodes.allSatisfy { $0.duration == nil })
    }

    /// An empty `<description/>` is absent, not an empty string.
    @Test func emptyDescriptionBecomesNilSummary() throws {
        let feed = try parseFixture("simple")
        #expect(feed.episodes[1].summary == nil)
    }

    // MARK: - itunes.rss

    @Test func itunesFieldsWinOverTheirFallbacks() throws {
        let feed = try parseFixture("itunes")

        #expect(feed.title == "iTunes Example Podcast")
        // managingEditor is present and must lose to itunes:author
        #expect(feed.author == "Example Media Collective")
        #expect(feed.summary?.hasPrefix("Long-form conversations recorded at Example Media.") == true)
        // channel/image/url is present and must lose to itunes:image[@href]
        #expect(feed.artworkURL == "https://example.com/itunes/artwork/show-3000.jpg")
    }

    /// The channel title must not be overwritten by `<image><title>`, which
    /// carries the same text here — a flat "current element" parser gets this
    /// wrong silently.
    @Test func nestedImageTitleDoesNotShadowTheChannelTitle() throws {
        let xml = """
            <rss version="2.0"><channel>
            <title>Real Channel Title</title>
            <image><url>https://example.com/art.jpg</url><title>Image Title</title></image>
            </channel></rss>
            """
        let feed = try FeedParser().parse(data: Data(xml.utf8))

        #expect(feed.title == "Real Channel Title")
        #expect(feed.artworkURL == "https://example.com/art.jpg")
    }

    @Test func cdataTitlesAndSummariesSurviveIntact() throws {
        let feed = try parseFixture("itunes")

        let first = try #require(feed.episodes.first)
        #expect(first.title == "Episode 1: Namespaces All the Way Down")
        #expect(first.summary?.hasPrefix("An itunes:summary for episode one") == true)

        // indented CDATA: the payload is trimmed, its markup untouched
        let second = feed.episodes[1]
        #expect(second.summary?.hasPrefix("<p>An itunes:summary delivered as CDATA") == true)
        #expect(second.summary?.hasSuffix("</p>") == true)
    }

    @Test func escapedEntitiesAreResolvedInTitles() throws {
        let feed = try parseFixture("itunes")
        #expect(feed.episodes[1].title == "Episode 2: Fallbacks, Defaults & Entities")
    }

    @Test func itunesDurationsAndEnclosuresParse() throws {
        let feed = try parseFixture("itunes")

        #expect(feed.episodes.count == 3)
        #expect(feed.episodes.map(\.duration) == [2537, 3188, 3900])
        #expect(feed.episodes[1].enclosureURL == "https://example.com/itunes/audio/episode-2.m4a")
        // content:encoded is not a summary source: episode 3 has only an empty description
        #expect(feed.episodes[2].summary == nil)
    }

    // MARK: - durations.rss

    @Test func durationFixtureCoversEveryAcceptedShape() throws {
        let feed = try parseFixture("durations")

        #expect(feed.episodes.count == 6)
        #expect(feed.episodes.map(\.duration) == expectedDurations)
        #expect(feed.author == "Example Duration Lab")
        #expect(feed.artworkURL == "https://example.org/durations/artwork.jpg")
        #expect(feed.summary?.hasPrefix("Every itunes:duration shape") == true)
    }

    // MARK: - tokenised.rss

    @Test func tokenisedFeedKeepsCyrillicTextAndTokenURLsVerbatim() throws {
        let feed = try parseFixture("tokenised")

        #expect(feed.title == "Пример Закрытого Фида")
        #expect(feed.author == "Пример Приватной Студии")
        #expect(feed.episodes.count == 2)

        let first = try #require(feed.episodes.first)
        #expect(first.title == "Бонус 1: За Стеной Оплаты")
        #expect(first.enclosureURL == tokenisedFirstEnclosure)
        #expect(first.duration == 1880)
        try expect(first.publishedAt, matches: "2025-05-08T07:00:00Z")

        #expect(feed.episodes[1].duration == nil)
    }

    // MARK: - malformed.rss

    /// The truncated document contains one complete item before the cut; it must
    /// not survive, because a partial feed is indistinguishable from a shrunken one.
    @Test func malformedDocumentThrowsAndReturnsNothing() throws {
        let data = try fixtureData(named: "malformed", withExtension: "rss")
        #expect(throws: FeedParser.Failure.malformedXML) {
            try FeedParser().parse(data: data)
        }
    }

    /// A channel and item nested under something other than `<rss>` is not an
    /// RSS feed, however complete its fields look — spec §6 sources everything
    /// from `/rss/channel`, so nothing is absorbed and the title is missing.
    @Test func documentWithANonRSSRootThrows() {
        let xml = """
            <not-rss><channel>
            <title>Looks Like A Feed</title>
            <description>But its root is not rss.</description>
            <item><title>Episode 1</title><enclosure url="https://example.com/ep1.mp3" type="audio/mpeg"/></item>
            </channel></not-rss>
            """
        #expect(throws: FeedParser.Failure.missingChannelTitle) {
            try FeedParser().parse(data: Data(xml.utf8))
        }
    }

    @Test func documentWithoutAChannelTitleThrows() {
        let xml = "<rss version=\"2.0\"><channel><description>No title here</description></channel></rss>"
        #expect(throws: FeedParser.Failure.missingChannelTitle) {
            try FeedParser().parse(data: Data(xml.utf8))
        }
    }

    // MARK: - no-enclosures.rss

    @Test func feedWithoutEnclosuresParsesToZeroEpisodesWithoutError() throws {
        let feed = try parseFixture("no-enclosures")

        #expect(feed.episodes.isEmpty)
        #expect(feed.title == "Example Newsroom Headlines")
        #expect(feed.author == "newsdesk@example.org (Example Newsroom)")
        #expect(feed.summary?.hasPrefix("A text-only news feed.") == true)
    }

    // MARK: - URL-aware entry point

    /// The same document that is merely empty through the data-only entry is a
    /// failure through the URL-aware one, and the error names the feed.
    @Test func urlAwareEntryThrowsNamingTheFeedWhenNoEpisodesParse() throws {
        let data = try fixtureData(named: "no-enclosures", withExtension: "rss")
        #expect(throws: FeedParser.Failure.emptyFeed(emptyFeedURL)) {
            try FeedParser().parse(data: data, sourceURL: emptyFeedURL)
        }
    }

    @Test func urlAwareEntryReturnsTheFeedUnchangedWhenEpisodesParse() throws {
        let data = try fixtureData(named: "simple", withExtension: "rss")
        let feed = try FeedParser().parse(data: data, sourceURL: "https://example.com/simple.rss")

        #expect(feed == (try FeedParser().parse(data: data)))
    }

    @Test func urlAwareEntryStillSurfacesStructuralFailures() throws {
        let data = try fixtureData(named: "malformed", withExtension: "rss")
        #expect(throws: FeedParser.Failure.malformedXML) {
            try FeedParser().parse(data: data, sourceURL: "https://example.com/malformed.rss")
        }
    }

    // MARK: - Helpers

    private var expectedSimpleGUIDs: [String] {
        ["simple-example-0001", "http://example.com/simple/2", "https://example.com/simple/3"]
    }

    private var expectedDurations: [TimeInterval?] {
        [45, 10584, 754, 3813, 3723, nil]
    }

    private var emptyFeedURL: String {
        "https://example.org/no-enclosures.rss"
    }

    private var tokenisedFirstEnclosure: String {
        "https://example.com/private/audio/bonus-1.mp3?token=REDACTED_TEST_TOKEN"
    }

    private func parseFixture(_ name: String) throws -> ParsedFeed {
        let data = try fixtureData(named: name, withExtension: "rss")
        return try FeedParser().parse(data: data)
    }

    private func expect(_ date: Date?, matches iso8601: String) throws {
        let expected = try #require(ISO8601DateFormatter().date(from: iso8601))
        #expect(date == expected)
    }
}
