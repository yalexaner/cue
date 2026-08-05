import Foundation

/// A podcast feed after parsing, before any of it reaches SwiftData (spec §6).
///
/// Deliberately a plain value type rather than a model: step 2 turns bytes into
/// values, and the merge into `Podcast` / `Episode` is a separate concern. Note
/// that `feedURL` is absent — it belongs to the request that fetched the
/// document, never to the document itself.
struct ParsedFeed: Sendable, Equatable {
    /// Channel `title`. Non-optional because `Podcast.title` is.
    var title: String
    /// `itunes:author`, falling back to `managingEditor`.
    var author: String?
    /// `itunes:summary`, falling back to `description`.
    var summary: String?
    /// `itunes:image[@href]`, falling back to `channel/image/url`.
    var artworkURL: String?
    var episodes: [ParsedEpisode]
}

/// One `<item>` that carried everything `Episode.init` requires.
///
/// `guid`, `title` and `enclosureURL` are non-optional here precisely because
/// they are non-optional on the model: an item missing any of them is skipped
/// during parsing rather than represented as a half-episode.
struct ParsedEpisode: Sendable, Equatable {
    /// `guid`, falling back to the enclosure URL.
    var guid: String
    var title: String
    /// `itunes:summary`, falling back to `description`.
    var summary: String?
    /// `pubDate`, `nil` when absent or unparseable.
    var publishedAt: Date?
    /// `enclosure[@url]`, stored verbatim — pre-signed private-feed tokens must
    /// survive byte-for-byte (spec §6).
    var enclosureURL: String
    /// `itunes:duration` in seconds, via `DurationParser`.
    var duration: TimeInterval?
}

// MARK: -

/// Parses the RFC 822 date shapes that `pubDate` actually appears in.
///
/// Four patterns cover every observed feed: the canonical one, the widespread
/// no-seconds variant, and both without the day-of-week, which RFC 822 makes
/// optional. `zzz` handles named zones (`GMT`, `EST`, `EDT`), numeric offsets
/// (`+0000`, `-0400`) and the literal `UTC` token alike — verified empirically,
/// since the last of those is not RFC 822 and is not guaranteed by the pattern.
/// `d` accepts both `3` and `03`.
///
/// The year field is `yy`, not `yyyy`, on purpose. RSS 2.0 permits a two-digit
/// year, and `yyyy` does not reject one — it reads `25` as the year 25 AD and
/// hands back a date sixteen centuries off with no signal. `yy` parses both
/// widths correctly (verified empirically), so it is the only safe spelling.
///
/// An unparseable date is `nil`, never an error: a bad timestamp is no reason
/// to drop an otherwise usable episode.
enum RFC822DateParser {
    private static let weekdayPatterns = ["EEE, d MMM yy HH:mm:ss zzz", "EEE, d MMM yy HH:mm zzz"]
    private static let weekdaylessPatterns = ["d MMM yy HH:mm:ss zzz", "d MMM yy HH:mm zzz"]

    /// 1950-01-01Z, so a two-digit year follows RFC 2822's obsolete-year rule:
    /// `50`–`99` are 19xx, `00`–`49` are 20xx. Pinned rather than left to
    /// `DateFormatter`'s default, which slides with the system clock and would
    /// make the same feed parse differently in a later decade.
    private static let twoDigitYearStart = Date(timeIntervalSince1970: -631_152_000)

    /// The date for a `pubDate` string, or `nil` if no known pattern matches.
    static func date(from string: String) -> Date? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // built per call rather than cached in a static, because a shared
        // DateFormatter is not Sendable — but reused across the patterns, since
        // a date matching none of them would otherwise allocate four times.
        // twoDigitStartDate is reapplied after every dateFormat assignment, so
        // the pinned century holds whatever the setters do to each other.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for pattern in weekdayPatterns + weekdaylessPatterns {
            formatter.dateFormat = pattern
            formatter.twoDigitStartDate = twoDigitYearStart
            if let date = formatter.date(from: trimmed) {
                return date
            }
        }
        return nil
    }
}
