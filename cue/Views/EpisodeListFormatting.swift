import Foundation

/// Episodes newest first, undated ones last (spec §12).
///
/// A SwiftData to-many relationship has no defined order, so the detail list
/// sorts in memory rather than through a `SortDescriptor` — which would also have
/// to answer where an optional `publishedAt` belongs. The order is total: equal
/// (or absent) dates tie-break on `guid`, so two fetches never disagree.
func episodesNewestFirst(_ episodes: [Episode]) -> [Episode] {
    episodes.sorted { left, right in
        switch (left.publishedAt, right.publishedAt) {
        case (let leftDate?, let rightDate?):
            if leftDate != rightDate { return leftDate > rightDate }
        case (nil, .some):
            return false
        case (.some, nil):
            return true
        case (nil, nil):
            break
        }
        return left.guid < right.guid
    }
}

/// Past this, the value is a feed bug rather than an episode — a hundred hours.
///
/// The ceiling is a correctness guard, not cosmetics. `DurationParser` prefers a
/// representable absurdity over trapping on the multiply, so `<itunes:duration>`
/// can legitimately deliver `Int.max` seconds; `Int(_: Double)` traps on exactly
/// that, which would crash every render of a row the feed itself authored, on
/// every launch, with no way out but wiping the store. The bound also keeps
/// `hours` inside the 32 bits `%d` consumes.
private let maximumDisplayableDuration: TimeInterval = 100 * 3_600

/// A duration as `h:mm:ss`, or `m:ss` under an hour. `nil` when there is nothing
/// worth showing.
///
/// The source is `Episode.duration`, which is often the feed's own unreliable
/// claim — a missing, zero or absurd value is rendered as no duration at all
/// rather than as a confident `0:00`.
func episodeDurationText(_ duration: TimeInterval?) -> String? {
    // NaN and infinity both fail this comparison, so no separate finiteness check
    guard let duration, duration >= 1, duration < maximumDisplayableDuration else { return nil }

    let total = Int(duration.rounded())
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let seconds = total % 60

    if hours > 0 {
        return String(format: "%d:%02d:%02d", hours, minutes, seconds)
    }
    return String(format: "%d:%02d", minutes, seconds)
}

/// An episode row's second line: date and duration, separated by a middle dot.
///
/// Either half may be absent — an undated episode and a feed with no usable
/// `itunes:duration` are both ordinary — so the separator appears only between
/// two present values, and a row with neither shows an empty line rather than a
/// stray dot or an invented placeholder.
func episodeSubtitle(publishedAt: Date?, duration: TimeInterval?) -> String {
    let date = publishedAt?.formatted(date: .abbreviated, time: .omitted)
    return [date, episodeDurationText(duration)].compactMap { $0 }.joined(separator: " · ")
}
