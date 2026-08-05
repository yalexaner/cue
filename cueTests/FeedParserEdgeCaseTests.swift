import Foundation
import Testing

@testable import cue

/// Parser behaviour the committed fixtures do not reach: inline markup, repeated
/// elements, and documents that are well-formed XML but not feeds.
struct FeedParserEdgeCaseTests {
    @Test func missingGUIDFallsBackToTheEnclosureURL() throws {
        let xml = """
            <rss version="2.0"><channel><title>No GUID Show</title>
            <item><title>An episode</title>
            <enclosure url="https://example.com/audio/1.mp3?token=REDACTED_TEST_TOKEN" type="audio/mpeg"/>
            </item></channel></rss>
            """
        let feed = try FeedParser().parse(data: Data(xml.utf8))

        let episode = try #require(feed.episodes.first)
        #expect(episode.guid == "https://example.com/audio/1.mp3?token=REDACTED_TEST_TOKEN")
        #expect(episode.enclosureURL == episode.guid)
    }

    @Test func channelImageURLIsTheArtworkFallback() throws {
        let xml = """
            <rss version="2.0"><channel><title>Fallback Artwork Show</title>
            <image><url>https://example.com/fallback.jpg</url></image>
            </channel></rss>
            """
        let feed = try FeedParser().parse(data: Data(xml.utf8))
        #expect(feed.artworkURL == "https://example.com/fallback.jpg")
    }

    @Test func itemWithoutATitleIsSkipped() throws {
        let xml = """
            <rss version="2.0"><channel><title>Partial Items Show</title>
            <item><guid>no-title</guid><enclosure url="https://example.com/1.mp3"/></item>
            <item><title>Complete</title><enclosure url="https://example.com/2.mp3"/></item>
            </channel></rss>
            """
        let feed = try FeedParser().parse(data: Data(xml.utf8))

        #expect(feed.episodes.count == 1)
        #expect(feed.episodes[0].title == "Complete")
    }

    /// Unescaped inline markup is well-formed XML, so `XMLParser` reports it as
    /// child elements rather than text. Every fixture wraps its HTML in CDATA,
    /// so only an inline case pins this: a parser with one flat accumulator
    /// keeps just the run after the last child and drops the item outright.
    @Test func inlineMarkupDoesNotTruncateTitlesOrSummaries() throws {
        let xml = """
            <rss version="2.0"><channel><title>Mixed Content Show</title>
            <item><guid>mixed-1</guid><title>Ep 1 <em>bonus</em> extra</title>
            <description>Hello <b>world</b> and goodbye</description>
            <enclosure url="https://example.com/1.mp3"/></item>
            </channel></rss>
            """
        let feed = try FeedParser().parse(data: Data(xml.utf8))

        let episode = try #require(feed.episodes.first)
        #expect(episode.title == "Ep 1 bonus extra")
        #expect(episode.summary == "Hello world and goodbye")
    }

    /// HTML nests, so an anchor inside a paragraph is a grandchild of the field.
    /// Folding only into the immediate parent loses its text — and when the
    /// nesting wraps the whole title, the item is dropped for having none.
    @Test func nestedInlineMarkupKeepsTextFromEveryDepth() throws {
        let xml = """
            <rss version="2.0"><channel><title>Deep Markup Show</title>
            <item><guid>deep-1</guid><title><b><i>Real Episode Title</i></b></title>
            <description><p>Listen at <a href="https://example.com">our site</a> today.</p></description>
            <enclosure url="https://example.com/1.mp3"/></item>
            </channel></rss>
            """
        let feed = try FeedParser().parse(data: Data(xml.utf8))

        let episode = try #require(feed.episodes.first)
        #expect(episode.title == "Real Episode Title")
        #expect(episode.summary == "Listen at our site today.")
    }

    /// The same loss at channel level rejects the whole document, because an
    /// empty title is a missing title.
    @Test func nestedMarkupInTheChannelTitleDoesNotRejectTheFeed() throws {
        let xml = """
            <rss version="2.0"><channel>
            <title><span><b>Real Channel</b></span></title>
            </channel></rss>
            """
        let feed = try FeedParser().parse(data: Data(xml.utf8))
        #expect(feed.title == "Real Channel")
    }

    /// A repeated element left empty is absent, not a correction: it must not
    /// erase the value the first occurrence carried.
    @Test func laterEmptyElementDoesNotClearChannelOrItemFields() throws {
        let xml = """
            <rss version="2.0"><channel><title>Repeat Show</title>
            <item><title>Episode One</title><guid>repeat-1</guid>
            <enclosure url="https://example.com/1.mp3"/><title/></item>
            <image><url>https://example.com/art.jpg</url><url/></image>
            <title></title></channel></rss>
            """
        let feed = try FeedParser().parse(data: Data(xml.utf8))

        #expect(feed.title == "Repeat Show")
        #expect(feed.artworkURL == "https://example.com/art.jpg")
        #expect(feed.episodes.map(\.title) == ["Episode One"])
    }

    /// The channel title is read after a mixed-content element has closed, so a
    /// leaked accumulator would show up here rather than in the item.
    @Test func inlineMarkupDoesNotLeakBetweenSiblingElements() throws {
        let xml = """
            <rss version="2.0"><channel>
            <description>Intro <b>bold</b> outro</description>
            <title>Real Title</title>
            </channel></rss>
            """
        let feed = try FeedParser().parse(data: Data(xml.utf8))

        #expect(feed.title == "Real Title")
        #expect(feed.summary == "Intro bold outro")
    }

    /// RSS 2.0 allows one enclosure per item. When a feed writes several, the
    /// first is the one the episode is built from — and the one the guid falls
    /// back to, which makes the choice store-wide-visible.
    @Test func firstEnclosureWinsOverLaterOnes() throws {
        let xml = """
            <rss version="2.0"><channel><title>Multi Enclosure Show</title>
            <item><title>An episode</title>
            <enclosure url="https://example.com/first.mp3"/>
            <enclosure url="https://example.com/second.mp3"/>
            </item></channel></rss>
            """
        let feed = try FeedParser().parse(data: Data(xml.utf8))

        let episode = try #require(feed.episodes.first)
        #expect(episode.enclosureURL == "https://example.com/first.mp3")
        #expect(episode.guid == "https://example.com/first.mp3")
    }

    /// XML attribute-value normalisation turns an embedded newline into a space
    /// but does not strip it, so a wrapped attribute arrives padded. The padding
    /// is not part of a pre-signed token, and leaving it makes `URL(string:)`
    /// return nil for an episode that otherwise looks fine.
    ///
    /// The interior `&#x20;` is what makes this the *only* in the name testable:
    /// boundary padding must go, an escaped space inside the value must not.
    @Test func enclosureURLIsStrippedOfSurroundingWhitespaceOnly() throws {
        let xml = """
            <rss version="2.0"><channel><title>Padded Show</title>
            <item><title>An episode</title>
            <enclosure
                url="
                    https://example.com/1.mp3?label=two&#x20;words
                "/>
            </item></channel></rss>
            """
        let feed = try FeedParser().parse(data: Data(xml.utf8))

        let episode = try #require(feed.episodes.first)
        #expect(episode.enclosureURL == "https://example.com/1.mp3?label=two words")
    }

    @Test func itemWithAnEmptyEnclosureURLIsSkipped() throws {
        let xml = """
            <rss version="2.0"><channel><title>Empty URL Show</title>
            <item><title>Broken</title><enclosure url=""/></item>
            <item><title>Complete</title><enclosure url="https://example.com/2.mp3"/></item>
            </channel></rss>
            """
        let feed = try FeedParser().parse(data: Data(xml.utf8))

        #expect(feed.episodes.count == 1)
        #expect(feed.episodes[0].title == "Complete")
    }

    /// A second `itunes:image` without an `href` must not erase the first one.
    @Test func laterHrefLessItunesImageDoesNotClearTheArtwork() throws {
        let xml = """
            <rss version="2.0"><channel><title>Artwork Show</title>
            <itunes:image href="https://example.com/good.jpg"/>
            <itunes:image/>
            </channel></rss>
            """
        let feed = try FeedParser().parse(data: Data(xml.utf8))
        #expect(feed.artworkURL == "https://example.com/good.jpg")
    }

    /// A feed host answering with an HTML error page is well-formed XML often
    /// enough to reach the title check rather than the syntax check.
    @Test func wellFormedNonFeedDocumentFailsOnTheMissingChannelTitle() {
        let xml = "<html><body><p>Not a feed</p></body></html>"
        #expect(throws: FeedParser.Failure.missingChannelTitle) {
            try FeedParser().parse(data: Data(xml.utf8))
        }
    }

    @Test func emptyDocumentIsMalformed() {
        #expect(throws: FeedParser.Failure.malformedXML) {
            try FeedParser().parse(data: Data())
        }
    }

    @Test func whitespaceOnlyChannelTitleIsTreatedAsMissing() {
        let xml = "<rss version=\"2.0\"><channel><title>   </title></channel></rss>"
        #expect(throws: FeedParser.Failure.missingChannelTitle) {
            try FeedParser().parse(data: Data(xml.utf8))
        }
    }

    /// `itunes:owner/itunes:name` sits inside the channel and must not be read
    /// as an author or a title.
    @Test func nestedItunesOwnerDoesNotLeakIntoChannelFields() throws {
        let xml = """
            <rss version="2.0"><channel><title>Owner Show</title>
            <itunes:owner><itunes:name>Owner Person</itunes:name></itunes:owner>
            <managingEditor>editor@example.com (Editor)</managingEditor>
            </channel></rss>
            """
        let feed = try FeedParser().parse(data: Data(xml.utf8))

        #expect(feed.title == "Owner Show")
        #expect(feed.author == "editor@example.com (Editor)")
    }
}
