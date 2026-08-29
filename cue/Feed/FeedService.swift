import Foundation
import SwiftData

/// Fetches a feed document, parses it, and merges the result into SwiftData (spec §6).
///
/// A cheap `@MainActor` struct constructed at the call site with the context it
/// writes to, mirroring the `EpisodeStore` / `FeedParser` precedent — there is no
/// shared instance. `@MainActor` because every mutation here lands on a
/// `@Model`, and the model layer stays on the main actor.
///
/// The network is a single injected closure rather than a session or a protocol
/// stack: tests hand it fixture bytes and a crafted response, so no test ever
/// reaches the network and `FeedService` holds no session configuration.
@MainActor
struct FeedService {
    /// One HTTP GET. Mirrors `URLSession.data(from:)` so the default is a wrapper.
    typealias Transport = @Sendable (URL) async throws -> (Data, URLResponse)

    /// The ways an add or refresh fails before the parser is even reached.
    ///
    /// Both cases carry the offending value so the message can name it, matching
    /// `FeedParser.Failure.emptyFeed(_:)` and `EpisodeStore.Failure`. Transport
    /// errors (`URLError`, ATS rejections) and `FeedParser.Failure` propagate
    /// unchanged — wrapping them would only hide what actually went wrong.
    enum Failure: Error, Equatable {
        /// The string is not a URL, or its scheme is not `http`/`https`.
        case invalidURL(String)
        /// The server answered with a non-2xx status. Carries the status and the
        /// feed URL, so a private feed's 401/403 is diagnosable at add time.
        case httpStatus(Int, String)
        /// The feed parsed, but every episode in it is already owned by another
        /// subscription, so subscribing would add an empty show (spec §6).
        case allEpisodesOwnedElsewhere(String)
    }

    /// How long a feed request may go without receiving anything before it
    /// fails.
    ///
    /// Apple defines `timeoutInterval` as an *idle* timeout — the clock restarts
    /// on every byte — so this bounds a silent server, not a slow one, and a
    /// large feed that keeps arriving is never cut off. The inherited default is
    /// 60 s, which is a minute of a spinner saying nothing before the user is
    /// told the host is unreachable; twenty seconds is long enough for a
    /// congested mobile link and short enough to answer while the user is still
    /// looking at the screen.
    static let requestTimeout: TimeInterval = 20

    /// The request the production transport sends.
    ///
    /// Extracted from the closure so the cache policy is assertable: it is a
    /// correctness requirement, not a tuning knob. Refresh is manual only
    /// (spec §6), so a pull-to-refresh has to reach the server; under the
    /// default protocol policy a feed sending `Cache-Control: max-age` would be
    /// answered from `URLCache` and the refresh would report success having
    /// fetched nothing. Revalidating still honours a 304, so a polite feed costs
    /// no more bandwidth than before.
    ///
    /// The idle timeout it also sets is `requestTimeout`.
    static func feedRequest(for url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadRevalidatingCacheData
        request.timeoutInterval = requestTimeout
        return request
    }

    /// The production transport: `URLSession.shared`, no configuration of its own.
    static let sharedTransport: Transport = { url in
        try await URLSession.shared.data(for: feedRequest(for: url))
    }

    private let context: ModelContext
    private let transport: Transport
    /// Readable rather than private so the default is assertable on a
    /// constructed service — asserting on the default *expression* only
    /// restates the declaration, and would stay green if the initialiser were
    /// changed to a writer over the real Application Support directory, which
    /// is the precise accident the no-op exists to prevent.
    let diagnostics: DiagnosticsSink

    /// The sink defaults to the no-op, so no existing test writes to disk. The
    /// three views that construct this service read the real one out of the
    /// environment (`DiagnosticsEnvironment.swift`); the service itself stays a
    /// cheap struct built at the call site.
    init(
        context: ModelContext, transport: @escaping Transport = FeedService.sharedTransport,
        diagnostics: DiagnosticsSink = NoOpDiagnosticsSink()
    ) {
        self.context = context
        self.transport = transport
        self.diagnostics = diagnostics
    }

    // MARK: - Entry points

    /// Subscribes to `urlString`, or refreshes it when it is already subscribed.
    ///
    /// Re-adding a subscribed feed is a refresh, never an error and never a blind
    /// `insert`: the destructive `#Unique` upsert pinned by
    /// `uniqueFeedURLUpsertOverwritesPodcastMetadata` would wipe the podcast's
    /// author, summary, artwork and `addedAt`.
    ///
    /// The string is requested and stored verbatim, tokens included (spec §6).
    @discardableResult
    func add(urlString: String) async throws -> Podcast {
        let feed = try await fetch(urlString: urlString)
        let result = try mergeOrDiscard(feed, feedURL: urlString)

        // spec §6 refuses to add an empty podcast, and a document can parse
        // perfectly and still contribute nothing: `guid` uniqueness is
        // store-wide, so a show re-added under a rotated token URL matches no
        // existing subscription yet has every one of its episodes skipped as
        // owned elsewhere. Left alone that inserts a permanently empty library
        // row and reports success.
        if result.isNewPodcast && result.linkedEpisodes == 0 {
            // the podcast was inserted in this merge and never saved, so
            // deleting it cancels the insert — no rollback, which would also
            // discard pending changes this service never made
            context.delete(result.podcast)
            throw Failure.allEpisodesOwnedElsewhere(urlString)
        }

        try saveOrDiscard()
        return result.podcast
    }

    /// Re-fetches a subscribed podcast's feed and folds it in additively (spec §6).
    ///
    /// Same merge as `add(urlString:)`, so the same guarantees hold: episodes that
    /// fell out of the feed window stay, played and download state are never
    /// written, and nothing is inserted blindly. A failed fetch throws before the
    /// merge runs, leaving `lastRefreshedAt` where it was.
    func refresh(_ podcast: Podcast) async throws {
        let feedURL = podcast.feedURL
        let feed = try await fetch(urlString: feedURL)
        try mergeOrDiscard(feed, feedURL: feedURL)
        try saveOrDiscard()
    }

    /// Merges, discarding the merge when it fails part-way through.
    ///
    /// `merge` writes before it can throw — the podcast is inserted and its
    /// metadata rewritten, then episodes are applied one at a time — and the
    /// lookups inside it throw by design rather than answering "absent". An
    /// aborted merge therefore leaves a half-applied feed pending, and the main
    /// context autosaves, so that partial state is committed moments after the
    /// user was told the add or refresh failed. Same reasoning, and the same
    /// context-wide caveat, as `saveOrDiscard()`.
    @discardableResult
    private func mergeOrDiscard(_ feed: ParsedFeed, feedURL: String) throws -> MergeResult {
        do {
            return try merge(feed, feedURL: feedURL)
        } catch {
            context.rollback()
            throw error
        }
    }

    /// Saves, discarding the merge when the save is rejected.
    ///
    /// The main context autosaves, so pending inserts left behind by a failed
    /// save are committed moments after the user has been told the add or
    /// refresh failed. Discarding is the only answer that keeps the store and
    /// the message agreeing.
    ///
    /// `rollback()` is context-wide, so it also drops edits this service never
    /// made. That is why a view mutating a model outside a service saves at the
    /// point of mutation rather than leaning on autosave — see
    /// `PodcastDetailView.setPlayed(_:on:)`.
    ///
    /// The cancellation check belongs *inside* the `do`, not above it. The merge
    /// runs synchronously between `fetch`'s check and this one, so a cancel that
    /// lands while it runs is only observed here; throwing from above the `do`
    /// would skip the discard and leave the whole merge pending for autosave to
    /// commit — the cancelled subscription appears anyway, which is the outcome
    /// the check exists to prevent.
    private func saveOrDiscard() throws {
        do {
            try Task.checkCancellation()
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }

    // MARK: - Fetching

    /// Fetches and parses the document at `urlString`. Writes nothing.
    private func fetch(urlString: String) async throws -> ParsedFeed {
        guard let url = URL(string: urlString), let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https"
        else {
            throw Failure.invalidURL(urlString)
        }

        // scheme and host only: a private feed's URL *is* its credential
        // (spec §6), and the type is what enforces that rather than this call
        // site remembering to trim
        let host = DiagnosticsHost(urlString)
        let startedAt = ContinuousClock.now
        diagnostics.record(DiagnosticsEvent.feedFetchStarted(host: host).record)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport(url)
        } catch {
            recordFetchFailure(error, host: host, startedAt: startedAt)
            throw error
        }

        // a non-HTTP response carries no status to judge; only HTTP is gated,
        // and a status of zero in the log says exactly that
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let elapsed = Self.elapsedMilliseconds(since: startedAt)
        if status != 0, !(200..<300).contains(status) {
            diagnostics.record(
                DiagnosticsEvent.feedHTTPStatus(host: host, status: status, elapsedMilliseconds: elapsed).record)
            throw Failure.httpStatus(status, urlString)
        }
        diagnostics.record(
            DiagnosticsEvent.feedFetchSucceeded(host: host, status: status, elapsedMilliseconds: elapsed).record)

        // a document that arrived and could not be read is a failure like any
        // other: without this the log shows `feed.fetch_succeeded` and then
        // nothing, which reads as an app that stopped rather than a feed that
        // is broken
        let feed: ParsedFeed
        do {
            feed = try await Self.parse(data: data, sourceURL: urlString)
        } catch {
            recordFetchFailure(error, host: host, startedAt: startedAt)
            throw error
        }
        // Cancel dismisses the add sheet while the request may already be
        // answered, and a view can go away mid-refresh the same way. Without
        // this the merge still commits, so the subscription the user backed out
        // of appears in the library — the response winning the race is not
        // consent. Callers treat cancellation as nothing to report.
        try Task.checkCancellation()
        return feed
    }

    /// Parses a fetched document off the main actor.
    ///
    /// `@MainActor` on the service is about SwiftData: every mutation lands on a
    /// `@Model`, so the merge has to stay here. Parsing has no such obligation —
    /// it touches no model and no context, takes `Data` and returns a `Sendable`
    /// value — and it is the one genuinely expensive step, walking the whole
    /// document and building a `DateFormatter` per dated item. Left inline it
    /// runs on the UI thread, so a large feed stalls navigation, the refresh
    /// indicator and the Cancel button for the length of the parse.
    ///
    /// `@concurrent` rather than a bare `nonisolated`: under this language mode
    /// a `nonisolated async` function already hops to the concurrent executor,
    /// but that default is the thing `NonisolatedNonsendingByDefault` inverts —
    /// spelling it out means the hop cannot be lost to a language-mode change.
    ///
    /// The URL-aware entry is mandatory for a document that was really fetched:
    /// zero episodes in a subscribed feed is an error the user has to see, and
    /// the message has to name the feed (spec §6).
    @concurrent
    private nonisolated static func parse(data: Data, sourceURL: String) async throws -> ParsedFeed {
        try FeedParser().parse(data: data, sourceURL: sourceURL)
    }

    // MARK: - Merging

    /// Folds a parsed feed into the store additively, and stamps `lastRefreshedAt`.
    ///
    /// Additive means: podcasts and episodes are fetched then mutated, new items
    /// are inserted, and nothing is ever deleted. Only the mutable metadata
    /// fields are written — `isPlayed`, `playedAt`, `localFilename`,
    /// `downloadedAt`, `assetDuration`, `sessions` and `addedAt` are never
    /// touched here, which is what makes a refresh safe (spec §6).
    ///
    /// Called only after a successful fetch and parse, so `lastRefreshedAt`
    /// cannot advance on a failure.
    ///
    /// Optional metadata is assigned unconditionally, so a field the document
    /// stops carrying is cleared: the feed owns these values, and spec §6's
    /// "update mutable metadata" means the feed's current answer wins. (The
    /// parser's rule that an *empty* element never clears a value is about one
    /// document, not about two.)
    ///
    /// Throws whatever the store's own lookups throw. A failed fetch must never
    /// degrade to "absent": `nil` is exactly the input that takes the insert
    /// branch, and on save that becomes the destructive `#Unique` upsert which
    /// clears `localFilename`, `downloadedAt`, `isPlayed` and `playedAt` — the
    /// same rule `EpisodeStore.fileExists(forRelativeFilename:)` follows for the
    /// file system.
    @discardableResult
    private func merge(_ feed: ParsedFeed, feedURL: String) throws -> MergeResult {
        let existing = try existingPodcast(feedURL: feedURL)
        let podcast = existing ?? insertedPodcast(feedURL: feedURL, title: feed.title)
        podcast.title = feed.title
        podcast.author = feed.author
        podcast.summary = feed.summary
        podcast.artworkURL = feed.artworkURL

        // episodes inserted during this merge are not necessarily visible to a
        // fetch until the context is saved, so a feed that repeats a guid would
        // otherwise insert it twice and hit the destructive upsert on save
        var insertedThisMerge: [String: Episode] = [:]
        var linkedEpisodes = 0

        for parsed in feed.episodes {
            if let existing = try insertedThisMerge[parsed.guid] ?? existingEpisode(guid: parsed.guid) {
                // `guid` uniqueness is store-wide, not per podcast
                // (`guidUniquenessIsGlobalNotPerPodcast`), so an episode already
                // owned by another show is skipped — never stolen, never
                // overwritten. Resolving that collision is out of scope here.
                guard existing.podcast === podcast else { continue }
                apply(parsed, to: existing)
                linkedEpisodes += 1
            } else {
                let episode = Episode(guid: parsed.guid, title: parsed.title, enclosureURL: parsed.enclosureURL)
                apply(parsed, to: episode)
                episode.podcast = podcast
                context.insert(episode)
                insertedThisMerge[parsed.guid] = episode
                linkedEpisodes += 1
            }
        }

        podcast.lastRefreshedAt = .now
        return MergeResult(podcast: podcast, isNewPodcast: existing == nil, linkedEpisodes: linkedEpisodes)
    }

    /// What a merge did, beyond the podcast it wrote to.
    ///
    /// `linkedEpisodes` counts the parsed episodes that ended up belonging to
    /// this podcast, inserted or updated — the ones skipped as owned by another
    /// show are not among them, which is what lets `add` refuse an empty
    /// subscription.
    private struct MergeResult {
        let podcast: Podcast
        let isNewPodcast: Bool
        let linkedEpisodes: Int
    }

    /// Writes exactly the episode fields a feed owns. `ParsedEpisode.duration`
    /// is the feed's claim, so it lands on `feedDuration` — never on
    /// `assetDuration`, which only a downloaded asset may set.
    private func apply(_ parsed: ParsedEpisode, to episode: Episode) {
        episode.title = parsed.title
        episode.summary = parsed.summary
        episode.publishedAt = parsed.publishedAt
        episode.enclosureURL = parsed.enclosureURL
        episode.feedDuration = parsed.duration
    }

    private func insertedPodcast(feedURL: String, title: String) -> Podcast {
        let podcast = Podcast(feedURL: feedURL, title: title)
        context.insert(podcast)
        return podcast
    }

    // MARK: - Lookups

    /// The subscribed podcast for a feed URL, if any.
    ///
    /// Both lookups propagate rather than answering `nil`: a store-level failure
    /// (I/O, a corrupted or mid-migration store) is not a predicate concern, and
    /// "cannot tell" answered as "absent" is what routes a merge into the
    /// destructive upsert.
    private func existingPodcast(feedURL: String) throws -> Podcast? {
        var descriptor = FetchDescriptor<Podcast>(predicate: #Predicate { $0.feedURL == feedURL })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    /// The episode with this guid anywhere in the store — the uniqueness scope.
    private func existingEpisode(guid: String) throws -> Episode? {
        var descriptor = FetchDescriptor<Episode>(predicate: #Predicate { $0.guid == guid })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }
}
