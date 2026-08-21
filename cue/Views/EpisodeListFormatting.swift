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

/// A whole number of seconds as `h:mm:ss`, or `m:ss` under an hour.
///
/// The shared tail of every duration and position label. Each caller applies its
/// own bounds check and rounding first — this one only formats, and traps for
/// nothing an `Int` can already hold.
func hoursMinutesSecondsText(_ total: Int) -> String {
    let hours = total / 3600
    let minutes = (total % 3600) / 60
    let seconds = total % 60

    if hours > 0 {
        return String(format: "%d:%02d:%02d", hours, minutes, seconds)
    }
    return String(format: "%d:%02d", minutes, seconds)
}

/// A duration as `h:mm:ss`, or `m:ss` under an hour. `nil` when there is nothing
/// worth showing.
///
/// The source is `Episode.duration`, which is often the feed's own unreliable
/// claim — a missing, zero or absurd value is rendered as no duration at all
/// rather than as a confident `0:00`.
func episodeDurationText(_ duration: TimeInterval?) -> String? {
    // NaN and infinity both fail this comparison, so no separate finiteness check
    guard let duration, duration >= 1, duration < maximumReasonableEpisodeDuration else { return nil }

    return hoursMinutesSecondsText(Int(duration.rounded()))
}

/// An episode row's second line: date, duration and file size, separated by
/// middle dots.
///
/// Any part may be absent — an undated episode, a feed with no usable
/// `itunes:duration`, and a row whose size was never measured are all
/// ordinary — so a separator appears only between two present values, and a row
/// with none shows an empty line rather than a stray dot or an invented
/// placeholder.
///
/// `byteCount` is optional and defaults to absent because only the Downloads
/// screen measures sizes: it is the one screen that already walks the files
/// (spec §7), and a size it could not measure must read as no size at all
/// rather than as a confident "Zero KB". A non-positive count is treated the
/// same way — a zero-byte episode file is a broken file, not information.
func episodeSubtitle(publishedAt: Date?, duration: TimeInterval?, byteCount: Int? = nil) -> String {
    let date = publishedAt?.formatted(date: .abbreviated, time: .omitted)
    let size = byteCount.flatMap { $0 > 0 ? diskUsageText($0) : nil }
    return [date, episodeDurationText(duration), size].compactMap { $0 }.joined(separator: " · ")
}
