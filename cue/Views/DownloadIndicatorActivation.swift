import CoreGraphics
import Foundation

/// What a tap on an episode row's download indicator does.
///
/// Deliberately a second question, asked separately from `downloadAction(for:)`:
/// the swipe action and the context menu are *chosen* — the user read a label
/// before committing — while the indicator is a small target sitting inside a
/// scrolling list, so the two must not answer `.failed` the same way.
/// `downloadAction` maps a failed transfer to `.download`, which is right for a
/// menu item spelled "Retry Download" and wrong for an unlabelled triangle: a
/// mis-tap would silently start a transfer the user did not ask for, over a
/// connection that just failed. The indicator shows the failure instead, and
/// retry is one explicit button further in.
///
/// Delete is the mirror image. A swipe delete is immediate because the swipe
/// itself is the confirmation; a tap has no such gesture behind it, so the
/// indicator asks first and names what it is about to remove.
enum DownloadIndicatorActivation: Equatable {
    case download
    case cancel
    /// Ask first, naming the episode and what its file occupies.
    case confirmDelete
    /// Show the failure, with retry reachable from inside it.
    case showFailure
}

/// The one answer for what an indicator tap does in a given row state.
func downloadIndicatorActivation(for state: EpisodeDownloadState) -> DownloadIndicatorActivation {
    switch state {
    case .notDownloaded:
        return .download
    case .downloading:
        return .cancel
    case .downloaded:
        return .confirmDelete
    case .failed:
        return .showFailure
    }
}

/// The smallest the indicator may draw, in points — Apple's 44-point minimum.
///
/// A named constant rather than a literal in two view files, so the two download
/// screens cannot give the same control two different tap targets.
let downloadIndicatorMinimumTapTarget: CGFloat = 44

/// What VoiceOver reads for the indicator: what it is, what a tap does, and
/// where the transfer has got to.
///
/// A value type rather than three parallel functions so a phase cannot gain a
/// label and be left without a hint.
struct DownloadIndicatorAccessibility: Equatable {
    /// What the control is.
    let label: String
    /// What activating it does.
    let hint: String
    /// The live state behind it, or `nil` when the label already says everything.
    let value: String?
}

/// Per-phase accessibility text for the indicator.
///
/// The downloading value is the same sentence the row renders, from
/// `transferStatusText(_:)`, rather than a second vocabulary: a phase that reads
/// as "Connecting…" on screen must not read as "Downloading" to VoiceOver.
func downloadIndicatorAccessibility(for state: EpisodeDownloadState) -> DownloadIndicatorAccessibility {
    switch state {
    case .notDownloaded:
        return DownloadIndicatorAccessibility(
            label: "Download", hint: "Downloads this episode to this device", value: nil)
    case .downloading(let progress):
        return DownloadIndicatorAccessibility(
            label: "Cancel Download", hint: "Cancels this transfer", value: transferStatusText(progress))
    case .downloaded:
        return DownloadIndicatorAccessibility(
            label: "Downloaded", hint: "Deletes this download, after confirming", value: nil)
    case .failed(let message):
        return DownloadIndicatorAccessibility(
            label: "Download Failed", hint: "Shows the failure, with an option to retry", value: message)
    }
}

/// What the delete confirmation says before a tap-triggered removal.
///
/// Names the episode, because the indicator is small and a mis-tap on the wrong
/// row is exactly what the confirmation exists to catch, and names the size when
/// one is known. An unknown size is left unsaid rather than shown as "Zero KB":
/// the size is measured on demand and a file the store could not measure has not
/// shrunk to nothing.
func deleteDownloadConfirmationMessage(episodeTitle: String, byteCount: Int?) -> String {
    let freed = byteCount.flatMap { $0 > 0 ? " This frees \(diskUsageText($0))." : nil } ?? ""
    return "“\(episodeTitle)” will be removed from this device.\(freed)"
}

/// A delete the user has been asked to confirm.
///
/// Carries the episode's `guid` rather than the model, so the payload is
/// `Sendable` and can be captured by the presentation binding SwiftUI wants;
/// the screen resolves it against the list it is already showing. The message
/// is assembled up front because measuring the size can throw — that failure
/// belongs on the path that reads the file, not inside a view builder.
struct PendingDownloadDeletion: Identifiable, Equatable, Sendable {
    let id: String
    let message: String
}

/// A failure the user asked to see, on the episode a retry would restart.
struct PendingDownloadFailure: Identifiable, Equatable, Sendable {
    let id: String
    let message: String
}
