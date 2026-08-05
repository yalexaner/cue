import Foundation

/// Turns RSS bytes into a `ParsedFeed` (spec §6).
///
/// Parsing is synchronous, allocation-light and entirely offline: the document
/// arrives as `Data` and leaves as values. Nothing here reaches SwiftData and
/// nothing here performs a request — fetching belongs to the feed service.
///
/// A value type with no stored state, mirroring `EpisodeStore`: constructed at
/// the call site, never shared.
struct FeedParser {
    /// The ways a document can fail to be a usable podcast feed.
    ///
    /// All are structural. A bad `pubDate` or an unrecognised `itunes:duration`
    /// is not a failure — those fields are optional and simply come back `nil`.
    enum Failure: Error, Equatable {
        /// `XMLParser` reported a syntax error. Any items parsed before the
        /// error are discarded: half a document is not a feed.
        case malformedXML
        /// The channel carried no usable `title`, which `Podcast.title` requires.
        case missingChannelTitle
        /// The document parsed but yielded no episodes. Carries the feed URL so
        /// the message can name it (spec §6); only the URL-aware entry throws it.
        case emptyFeed(String)
    }

    /// Parses a feed document.
    ///
    /// Zero episodes is a valid result, not an error — a text-only feed parses
    /// into channel metadata and an empty array. The URL-aware entry point is
    /// what turns that into a failure.
    func parse(data: Data) throws -> ParsedFeed {
        let parser = XMLParser(data: data)
        // qualified names are matched literally (`itunes:duration`), so
        // namespace processing must stay off; false is the default, set
        // explicitly so the parser does not depend on it
        parser.shouldProcessNamespaces = false
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false

        let delegate = FeedDelegate()
        parser.delegate = delegate

        guard parser.parse(), parser.parserError == nil else {
            throw Failure.malformedXML
        }
        guard let title = delegate.channel.title else {
            throw Failure.missingChannelTitle
        }

        return ParsedFeed(
            title: title,
            author: delegate.channel.itunesAuthor ?? delegate.channel.managingEditor,
            summary: delegate.channel.itunesSummary ?? delegate.channel.description,
            artworkURL: delegate.channel.itunesImage ?? delegate.channel.imageURL,
            episodes: delegate.episodes
        )
    }

    /// Parses a feed fetched from `sourceURL`, where zero episodes is a failure.
    ///
    /// A subscribed feed that yields nothing is a problem the user has to see,
    /// and the message has to name which feed — so the URL travels with the
    /// error (spec §6). The data-only entry keeps the permissive contract.
    func parse(data: Data, sourceURL: String) throws -> ParsedFeed {
        let feed = try parse(data: data)
        guard !feed.episodes.isEmpty else {
            throw Failure.emptyFeed(sourceURL)
        }
        return feed
    }
}

// MARK: -

/// The raw strings one `<channel>` contributes, before fallbacks are applied.
private struct ChannelFields {
    var title: String?
    var itunesAuthor: String?
    var managingEditor: String?
    var itunesSummary: String?
    var description: String?
    var itunesImage: String?
    var imageURL: String?
}

/// The raw strings one `<item>` contributes, before fallbacks are applied.
private struct ItemFields {
    var title: String?
    var guid: String?
    var itunesSummary: String?
    var description: String?
    var pubDate: String?
    var enclosureURL: String?
    var duration: String?
}

// MARK: -

/// Accumulates channel and item fields over one `XMLParser` run.
///
/// A reference type, as the delegate protocol requires, but one that never
/// escapes the enclosing `parse(data:)` call — so it carries no `Sendable`
/// obligation under Swift 6.
private final class FeedDelegate: NSObject, XMLParserDelegate {
    private(set) var channel = ChannelFields()
    private(set) var episodes: [ParsedEpisode] = []

    /// The open element names, outermost first.
    ///
    /// A single `currentElement` string would be wrong: `<image><title>` inside
    /// a channel and `<itunes:owner><itunes:name>` both shadow channel fields,
    /// and only the parent tells them apart.
    private var path: [String] = []
    /// Character data seen since the innermost element opened.
    private var text = ""
    /// The enclosing elements' character data, parked while a child is open.
    ///
    /// A single accumulator would be wrong for mixed content: unescaped inline
    /// markup such as `<title>Ep 1 <em>bonus</em></title>` is well-formed XML,
    /// so resetting on every start tag keeps only the run after the last child
    /// — here nothing at all, which silently drops the item.
    private var textStack: [String] = []
    private var item: ItemFields?

    // MARK: - XMLParserDelegate

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String]
    ) {
        let parentIsChannel = isChannel
        let parentIsItem = isChannelChild("item")
        path.append(elementName)
        textStack.append(text)
        text = ""

        switch elementName {
        case "item" where parentIsChannel:
            item = ItemFields()
        case "enclosure" where parentIsItem:
            // the URL itself travels verbatim — pre-signed private-feed tokens
            // must survive byte-for-byte, so no re-encoding and no interior
            // rewriting (spec §6). The XML formatting whitespace around the
            // attribute value is not part of the token, and leaving it makes
            // the URL unusable and pollutes the guid that falls back to it.
            // RSS 2.0 allows one enclosure per item; when a feed writes several
            // the first wins, rather than silently the last.
            if item?.enclosureURL == nil, let url = trimmed(attributeDict["url"]) {
                item?.enclosureURL = url
            }
        case "itunes:image" where parentIsChannel:
            // a later bare `<itunes:image/>` must not clear a good href
            if let href = trimmed(attributeDict["href"]) {
                channel.itunesImage = href
            }
        default:
            break
        }
    }

    /// Fires repeatedly for one element — around entities and between CDATA
    /// blocks — so the text is appended, never assigned.
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    /// CDATA arrives here rather than through `foundCharacters`.
    func parser(_ parser: XMLParser, foundCDATA cdataBlock: Data) {
        if let string = String(data: cdataBlock, encoding: .utf8) {
            text += string
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let value = text
        path.removeLast()
        // restore the parent's own text, folding this element's in so that
        // mixed content concatenates instead of truncating
        text = textStack.popLast() ?? ""
        if path.contains(where: readsText(from:)) {
            text += value
        }

        if elementName == "item", isChannel {
            appendItem()
            item = nil
        } else if item != nil {
            if isChannelChild("item") {
                absorbIntoItem(elementName, value)
            }
        } else if isChannel {
            absorbIntoChannel(elementName, value)
        } else if elementName == "url", isChannelChild("image") {
            // an empty repeat must not clear a good URL, as everywhere else here
            channel.imageURL = trimmed(value) ?? channel.imageURL
        }
    }

    // MARK: - Field mapping

    /// An empty element is absent, so it never clears a value already collected
    /// — the same rule the `enclosure` and `itunes:image` guards apply. A feed
    /// that repeats an element and leaves the repeat empty would otherwise lose
    /// the good value, which for `title` rejects the whole feed.
    private func absorbIntoChannel(_ elementName: String, _ value: String) {
        guard let value = trimmed(value) else { return }
        switch elementName {
        case "title": channel.title = value
        case "itunes:author": channel.itunesAuthor = value
        case "managingEditor": channel.managingEditor = value
        case "itunes:summary": channel.itunesSummary = value
        case "description": channel.description = value
        default: break
        }
    }

    /// Empty elements are ignored here too, so a repeated empty `<title>` cannot
    /// drop an otherwise complete item.
    private func absorbIntoItem(_ elementName: String, _ value: String) {
        guard let value = trimmed(value) else { return }
        switch elementName {
        case "title": item?.title = value
        case "guid": item?.guid = value
        case "itunes:summary": item?.itunesSummary = value
        case "description": item?.description = value
        case "pubDate": item?.pubDate = value
        case "itunes:duration": item?.duration = value
        default: break
        }
    }

    /// Promotes the collected item fields into an episode, or drops the item.
    ///
    /// An item without an enclosure URL is not an episode, and an item without
    /// a title cannot become one either — `Episode.title` is non-optional and
    /// the spec offers no default. Neither case is fatal to the feed.
    private func appendItem() {
        guard let fields = item, let enclosureURL = fields.enclosureURL, let title = fields.title else {
            return
        }
        episodes.append(
            ParsedEpisode(
                guid: fields.guid ?? enclosureURL,
                title: title,
                summary: fields.itunesSummary ?? fields.description,
                publishedAt: fields.pubDate.flatMap(RFC822DateParser.date(from:)),
                enclosureURL: enclosureURL,
                duration: fields.duration.flatMap(DurationParser.seconds(from:))
            )
        )
    }

    /// Whether the open path is exactly `/rss/channel`.
    ///
    /// The root is checked, not just the immediate parent: spec §6 sources every
    /// field from `/rss/channel`, so a document that merely happens to nest
    /// `<channel><item>` under some other root is not an RSS feed and must not
    /// parse as one. Nothing is absorbed from it, so it fails on the missing
    /// channel title.
    private var isChannel: Bool {
        path.count == 2 && path[0] == "rss" && path[1] == "channel"
    }

    /// Whether the open path is exactly `/rss/channel/<name>`.
    private func isChannelChild(_ name: String) -> Bool {
        path.count == 3 && path[0] == "rss" && path[1] == "channel" && path[2] == name
    }

    /// Whether this parser reads text out of `elementName`.
    ///
    /// A child's text is folded back into its parent only while one of these is
    /// still open, which keeps the accumulator the size of one field rather than
    /// letting it grow to the text of the whole document. The whole open path is
    /// consulted, not just the immediate parent: HTML nests, so the link text in
    /// `<description><p>see <a href="…">this</a></p></description>` reaches the
    /// field only if a grandchild folds too.
    private func readsText(from elementName: String) -> Bool {
        switch elementName {
        case "title", "guid", "pubDate", "description", "url": true
        case "managingEditor", "itunes:author", "itunes:summary", "itunes:duration": true
        default: false
        }
    }

    /// Trims surrounding whitespace and reports an empty result as absent, so a
    /// `<description/>` never shadows the element it was meant to fall back to.
    private func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
