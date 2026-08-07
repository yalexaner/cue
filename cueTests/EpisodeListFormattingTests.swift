import Foundation
import SwiftData
import Testing

@testable import cue

private func makeEpisode(guid: String, publishedAt: Date?) -> Episode {
    let episode = Episode(guid: guid, title: "Episode \(guid)", enclosureURL: "https://example.com/\(guid).mp3")
    episode.publishedAt = publishedAt
    return episode
}

private func date(_ day: Int) -> Date {
    Date(timeIntervalSince1970: TimeInterval(day) * 86_400)
}

@MainActor
struct EpisodeOrderingTests {

    @Test func newestDateComesFirst() {
        let old = makeEpisode(guid: "old", publishedAt: date(1))
        let new = makeEpisode(guid: "new", publishedAt: date(3))
        let middle = makeEpisode(guid: "middle", publishedAt: date(2))

        let sorted = episodesNewestFirst([old, new, middle])

        #expect(sorted.map(\.guid) == ["new", "middle", "old"])
    }

    @Test func undatedEpisodesSortLast() {
        let undated = makeEpisode(guid: "undated", publishedAt: nil)
        let dated = makeEpisode(guid: "dated", publishedAt: date(1))

        #expect(episodesNewestFirst([undated, dated]).map(\.guid) == ["dated", "undated"])
        #expect(episodesNewestFirst([dated, undated]).map(\.guid) == ["dated", "undated"])
    }

    @Test func equalDatesTieBreakOnGuid() {
        let first = makeEpisode(guid: "aaa", publishedAt: date(5))
        let second = makeEpisode(guid: "bbb", publishedAt: date(5))

        #expect(episodesNewestFirst([second, first]).map(\.guid) == ["aaa", "bbb"])
    }

    @Test func undatedEpisodesTieBreakOnGuid() {
        let first = makeEpisode(guid: "aaa", publishedAt: nil)
        let second = makeEpisode(guid: "bbb", publishedAt: nil)

        #expect(episodesNewestFirst([second, first]).map(\.guid) == ["aaa", "bbb"])
    }

    @Test func emptyInputStaysEmpty() {
        #expect(episodesNewestFirst([]).isEmpty)
    }
}

struct EpisodeDurationTextTests {

    @Test func underAnHourIsMinutesAndSeconds() {
        #expect(episodeDurationText(125) == "2:05")
    }

    @Test func anHourOrMoreCarriesTheHourField() {
        #expect(episodeDurationText(3_725) == "1:02:05")
    }

    @Test func missingOrZeroDurationHasNoText() {
        #expect(episodeDurationText(nil) == nil)
        #expect(episodeDurationText(0) == nil)
    }

    @Test func nonFiniteDurationHasNoText() {
        #expect(episodeDurationText(.infinity) == nil)
        #expect(episodeDurationText(.nan) == nil)
    }

    @Test func negativeDurationHasNoText() {
        #expect(episodeDurationText(-1) == nil)
        #expect(episodeDurationText(-3_600) == nil)
    }

    /// The one-second threshold, either side of it.
    @Test func subSecondIsNothingAndOneSecondIsShown() {
        #expect(episodeDurationText(0.4) == nil)
        #expect(episodeDurationText(1) == "0:01")
    }

    /// Rounding carries into the next field rather than truncating.
    @Test func roundingCarriesIntoMinutesAndHours() {
        #expect(episodeDurationText(59.6) == "1:00")
        #expect(episodeDurationText(3_599.6) == "1:00:00")
    }

    /// `DurationParser` lets a representable absurdity such as `Int.max` seconds
    /// through rather than trapping on the multiply, so this reaches the
    /// formatter from any feed that writes it. Converting it to `Int` traps —
    /// a crash on every render of the row, on every launch.
    @Test func absurdDurationHasNoTextRatherThanCrashing() {
        #expect(episodeDurationText(TimeInterval(Int.max)) == nil)
        #expect(episodeDurationText(1e30) == nil)
        #expect(episodeDurationText(DurationParser.seconds(from: "9223372036854775807")) == nil)
    }

    /// The ceiling itself: a hundred hours is out, just under it is in.
    @Test func theDisplayableCeilingIsAHundredHours() {
        #expect(episodeDurationText(100 * 3_600) == nil)
        #expect(episodeDurationText(100 * 3_600 - 1) == "99:59:59")
    }
}

@MainActor
struct EpisodePlayedToggleTests {

    @Test func markingPlayedSetsTheFlagAndTimestamp() throws {
        let context = try makeContext()
        let episode = makeEpisode(guid: "a", publishedAt: date(1))
        context.insert(episode)

        let before = Date()
        episode.setPlayed(true)

        #expect(episode.isPlayed)
        // not merely non-nil: the timestamp is *now*, not a placeholder date
        let playedAt = try #require(episode.playedAt)
        #expect(playedAt >= before)
        #expect(playedAt <= Date())
    }

    /// Re-marking an already-played episode moves the timestamp forward rather
    /// than leaving the first one in place.
    @Test func remarkingPlayedMovesTheTimestamp() throws {
        let context = try makeContext()
        let episode = makeEpisode(guid: "a", publishedAt: date(1))
        context.insert(episode)
        episode.playedAt = date(0)
        episode.isPlayed = true

        let before = Date()
        episode.setPlayed(true)

        let playedAt = try #require(episode.playedAt)
        #expect(playedAt >= before)
    }

    @Test func markingUnplayedClearsTheFlagAndTimestamp() throws {
        let context = try makeContext()
        let episode = makeEpisode(guid: "a", publishedAt: date(1))
        context.insert(episode)
        episode.setPlayed(true)

        episode.setPlayed(false)

        #expect(!episode.isPlayed)
        #expect(episode.playedAt == nil)
    }

    @Test func togglingPlayedTouchesNoDownloadStateOrSessions() throws {
        let context = try makeContext()
        let episode = makeEpisode(guid: "a", publishedAt: date(1))
        episode.localFilename = "kept.mp3"
        episode.downloadedAt = date(2)
        episode.assetDuration = 120
        context.insert(episode)
        let session = PlaybackSession(startedAt: date(2), startPosition: 0, endPosition: 30, rate: 1)
        session.episode = episode
        context.insert(session)

        episode.setPlayed(true)
        episode.setPlayed(false)

        #expect(episode.localFilename == "kept.mp3")
        #expect(episode.downloadedAt == date(2))
        #expect(episode.assetDuration == 120)
        #expect(episode.sessions.count == 1)
    }

    /// What a caller whose save failed needs: the pair back exactly as it was,
    /// in both directions. `setPlayed(_:)` cannot do it — it derives `playedAt`
    /// from `.now` — and download state stays untouched either way (spec §4).
    @Test func restoringPlayedPutsBackTheCapturedPair() throws {
        let context = try makeContext()
        let episode = makeEpisode(guid: "a", publishedAt: date(1))
        episode.localFilename = "kept.mp3"
        episode.downloadedAt = date(2)
        context.insert(episode)
        episode.isPlayed = true
        episode.playedAt = date(3)

        let previousIsPlayed = episode.isPlayed
        let previousPlayedAt = episode.playedAt
        episode.setPlayed(false)
        episode.restorePlayed(previousIsPlayed, at: previousPlayedAt)

        #expect(episode.isPlayed)
        #expect(episode.playedAt == date(3))
        #expect(episode.localFilename == "kept.mp3")
        #expect(episode.downloadedAt == date(2))
    }

    /// The other direction: a previously unplayed episode restores to a `nil`
    /// timestamp, not to a placeholder date.
    @Test func restoringUnplayedClearsTheTimestamp() throws {
        let context = try makeContext()
        let episode = makeEpisode(guid: "a", publishedAt: date(1))
        episode.localFilename = "kept.mp3"
        episode.downloadedAt = date(2)
        context.insert(episode)

        let previousIsPlayed = episode.isPlayed
        let previousPlayedAt = episode.playedAt
        episode.setPlayed(true)
        episode.restorePlayed(previousIsPlayed, at: previousPlayedAt)

        #expect(!episode.isPlayed)
        #expect(episode.playedAt == nil)
        #expect(episode.localFilename == "kept.mp3")
        #expect(episode.downloadedAt == date(2))
    }
}

struct EpisodeSubtitleTests {

    @Test func bothPartsAreJoinedByAMiddleDot() {
        let subtitle = episodeSubtitle(publishedAt: date(1), duration: 3_725)

        #expect(subtitle.contains(" · "))
        #expect(subtitle.hasSuffix("1:02:05"))
    }

    /// One part missing means no separator — never a leading or trailing dot.
    @Test func aMissingPartLeavesNoSeparator() {
        let dateOnly = episodeSubtitle(publishedAt: date(1), duration: nil)
        let durationOnly = episodeSubtitle(publishedAt: nil, duration: 90)

        #expect(!dateOnly.contains("·"))
        #expect(!dateOnly.isEmpty)
        #expect(durationOnly == "1:30")
    }

    /// A duration the formatter rejects counts as missing, not as "0:00".
    @Test func anUnusableDurationCountsAsMissing() {
        #expect(episodeSubtitle(publishedAt: nil, duration: 0).isEmpty)
        #expect(episodeSubtitle(publishedAt: nil, duration: .infinity).isEmpty)
        #expect(episodeSubtitle(publishedAt: nil, duration: TimeInterval(Int.max)).isEmpty)
    }

    /// A feed supplying neither leaves the line empty rather than inventing a
    /// placeholder.
    @Test func neitherPartPresentIsAnEmptyLine() {
        #expect(episodeSubtitle(publishedAt: nil, duration: nil).isEmpty)
    }
}

struct FeedAddressTests {

    /// Whitespace and newlines are clipboard artifacts, so they go.
    @Test func surroundingWhitespaceAndNewlinesAreRemoved() {
        #expect(normalisedFeedAddress("  https://example.com/feed\n") == "https://example.com/feed")
        #expect(normalisedFeedAddress("\t\nhttps://example.com/feed  ") == "https://example.com/feed")
    }

    /// Everything inside survives byte for byte: a private feed whose token were
    /// rewritten answers 401 (spec §6).
    @Test func theAddressItselfIsNeverRewritten() {
        let tokenised = "https://example.com/feed?token=REDACTED_TEST_TOKEN&a=b%20c"

        #expect(normalisedFeedAddress(tokenised) == tokenised)
        #expect(normalisedFeedAddress(" \(tokenised) ") == tokenised)
    }

    @Test func anAddressOfOnlyWhitespaceNormalisesToEmpty() {
        #expect(normalisedFeedAddress("   \n\t ").isEmpty)
        #expect(normalisedFeedAddress("").isEmpty)
    }
}
