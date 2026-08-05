import Foundation
import Testing

@testable import cue

/// `pubDate` shapes accepted and rejected (spec §6).
///
/// Every accepted input below is a literal `pubDate` value taken from the
/// committed fixtures, so a regression here is a regression against real feeds.
struct RFC822DateParserTests {
    // MARK: - Accepted shapes

    @Test func dateParsesNamedZones() throws {
        try expectDate("Fri, 04 Apr 2025 06:00:00 GMT", matches: "2025-04-04T06:00:00Z")
        try expectDate("Mon, 02 Jun 2025 10:00:00 EDT", matches: "2025-06-02T14:00:00Z")
        try expectDate("Fri, 3 Jan 2025 19:14:19 EST", matches: "2025-01-04T00:14:19Z")
    }

    /// The literal `UTC` token is not RFC 822, but feeds write it — and whether
    /// `zzz` accepts it is not something the pattern guarantees.
    @Test func dateParsesTheLiteralUTCToken() throws {
        try expectDate("Thu, 08 May 2025 07:00:00 UTC", matches: "2025-05-08T07:00:00Z")
        try expectDate("Thu, 03 Apr 2025 18:15:30 UTC", matches: "2025-04-03T18:15:30Z")
    }

    @Test func dateParsesNumericOffsets() throws {
        try expectDate("Wed, 09 Jul 2025 14:05:30 +0000", matches: "2025-07-09T14:05:30Z")
        try expectDate("Tue, 01 Apr 2025 18:30:00 -0400", matches: "2025-04-01T22:30:00Z")
        try expectDate("Wed, 02 Apr 2025 22:45:00 -0500", matches: "2025-04-03T03:45:00Z")
    }

    /// Single-digit days appear alongside zero-padded ones in the same feed set.
    @Test func dateParsesSingleDigitDays() throws {
        try expectDate("Tue, 8 Jul 2025 11:40:00 EDT", matches: "2025-07-08T15:40:00Z")
    }

    @Test func dateParsesTheNoSecondsVariant() throws {
        try expectDate("Fri, 09 May 2025 19:05 +0000", matches: "2025-05-09T19:05:00Z")
        try expectDate("Thu, 13 Feb 2025 08:00 +0000", matches: "2025-02-13T08:00:00Z")
        try expectDate("Tue, 03 Jun 2025 10:00 +0000", matches: "2025-06-03T10:00:00Z")
    }

    /// RFC 822 makes the day-of-week optional and feeds do omit it.
    @Test func dateParsesTheWeekdaylessVariant() throws {
        try expectDate("04 Apr 2025 06:00:00 GMT", matches: "2025-04-04T06:00:00Z")
        try expectDate("4 Apr 2025 06:00:00 +0000", matches: "2025-04-04T06:00:00Z")
        try expectDate("09 May 2025 19:05 +0000", matches: "2025-05-09T19:05:00Z")
    }

    /// RSS 2.0 permits a two-digit year, and a `yyyy` pattern reads `25` as the
    /// year 25 AD rather than rejecting it — a silently wrong `publishedAt` that
    /// would sort every such episode to the far past. The window is pinned to
    /// RFC 2822's rule, so these assertions do not drift with the system clock.
    @Test func dateParsesTwoDigitYearsAgainstAFixedWindow() throws {
        try expectDate("Fri, 04 Apr 25 06:00:00 GMT", matches: "2025-04-04T06:00:00Z")
        try expectDate("Sun, 04 Apr 49 06:00:00 GMT", matches: "2049-04-04T06:00:00Z")
        try expectDate("Mon, 04 Apr 50 06:00:00 GMT", matches: "1950-04-04T06:00:00Z")
        try expectDate("Tue, 04 Apr 95 06:00:00 GMT", matches: "1995-04-04T06:00:00Z")
    }

    @Test func dateTrimsSurroundingWhitespace() throws {
        try expectDate("\n  Fri, 04 Apr 2025 06:00:00 GMT  ", matches: "2025-04-04T06:00:00Z")
    }

    // MARK: - Rejected input

    @Test(arguments: ["not a date", "", "   ", "Fri, 04 Apr 2025 06:00:00"])
    func dateReturnsNilForJunkAndMissingZones(_ input: String) {
        #expect(RFC822DateParser.date(from: input) == nil)
    }

    /// ISO 8601 is the other thing feeds sometimes do — deliberately unsupported
    /// rather than silently mis-parsed.
    @Test(arguments: ["2025-04-04T06:00:00Z", "Fri, 04 Apx 2025 06:00:00 GMT", "Fri, 04 Apr 2025"])
    func dateReturnsNilForNearMisses(_ input: String) {
        #expect(RFC822DateParser.date(from: input) == nil)
    }

    // MARK: - Helpers

    private func expectDate(_ input: String, matches iso8601: String) throws {
        let expected = try #require(ISO8601DateFormatter().date(from: iso8601))
        #expect(RFC822DateParser.date(from: input) == expected, "\(input)")
    }
}

/// The value types carry what the models require, and compare by value.
struct ParsedFeedTests {
    @Test func parsedFeedIsEquatableByValue() {
        let episode = ParsedEpisode(
            guid: "guid-1",
            title: "Episode one",
            summary: nil,
            publishedAt: nil,
            enclosureURL: "https://example.com/1.mp3",
            duration: 754
        )
        let feed = ParsedFeed(title: "Show", author: nil, summary: nil, artworkURL: nil, episodes: [episode])

        var other = feed
        #expect(other == feed)

        other.episodes[0].duration = 755
        #expect(other != feed)
    }
}
