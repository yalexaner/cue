import Foundation

/// A pasted feed address, cleaned of the artifacts of pasting and nothing else.
///
/// Only leading and trailing whitespace and newlines go: those come from the
/// clipboard, not from the feed. Everything inside survives byte for byte —
/// a private feed's token is part of the URL, and re-encoding or stripping any
/// of it answers 401 (spec §6). Extracted from `AddFeedView` so the rule is
/// asserted rather than assumed.
func normalisedFeedAddress(_ pasted: String) -> String {
    pasted.trimmingCharacters(in: .whitespacesAndNewlines)
}
