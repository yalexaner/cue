import Foundation

/// What `UIPasteboard.detectPatterns(for:)` found on the clipboard, reduced to
/// the one pattern the add-feed sheet cares about.
///
/// Detection is a separate step from reading on purpose (decision 15): asking
/// what *shape* the clipboard holds does not prompt, while reading its contents
/// may. A detection that fails answers `nil` — the sheet then offers nothing
/// rather than falling back to a blind read the user never asked for.
enum FeedPasteDetection: Sendable, Equatable {
    /// Detection completed; `containsProbableWebURL` is what it found.
    case detected(containsProbableWebURL: Bool)
    /// Detection failed or has not run yet.
    case unavailable
}

/// Whether the add-feed sheet shows its Paste button.
///
/// Offered only when detection completed *and* saw a probable web URL *and* the
/// field is still empty: once there is text on screen, a Paste button competes
/// with what the user typed instead of helping them start.
func shouldOfferFeedPaste(detection: FeedPasteDetection, fieldText: String) -> Bool {
    guard normalisedFeedAddress(fieldText).isEmpty else { return false }
    guard case .detected(let containsProbableWebURL) = detection else { return false }
    return containsProbableWebURL
}

/// The address a clipboard read contributes, or `nil` if it contributes nothing.
///
/// The clipboard can change between detection and read, so the value is
/// revalidated here rather than trusted from the offer: an empty clipboard, a
/// clipboard holding only whitespace, or one that no longer holds text at all
/// leaves the field untouched. Whatever survives goes through
/// `normalisedFeedAddress(_:)`, exactly as a typed address does — the inner
/// token of a private feed is never rewritten (spec §6).
func pastedFeedAddress(fromClipboard clipboard: String?) -> String? {
    guard let clipboard else { return nil }
    let normalised = normalisedFeedAddress(clipboard)
    return normalised.isEmpty ? nil : normalised
}
