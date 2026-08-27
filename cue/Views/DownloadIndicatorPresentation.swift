import SwiftUI

// The SwiftUI half of the indicator control: the accessibility wiring and the
// two presentations a tap can raise. Written once as modifiers so the podcast
// detail list and the Downloads tab cannot word the same confirmation two ways,
// and so `DownloadIndicatorActivation.swift` stays a plain testable policy with
// no view code in it.

extension View {
    /// Reads the indicator's per-phase label, hint and value onto the control.
    func downloadIndicatorLabels(_ state: EpisodeDownloadState) -> some View {
        let text = downloadIndicatorAccessibility(for: state)
        return accessibilityLabel(text.label)
            .accessibilityHint(text.hint)
            .accessibilityValue(text.value ?? "")
    }

    /// The confirmation a tap-triggered delete raises, naming the episode and
    /// its size. The swipe delete stays immediate — the swipe is its own
    /// confirmation.
    func deleteDownloadConfirmation(
        _ pending: Binding<PendingDownloadDeletion?>,
        onDelete: @escaping (String) -> Void
    ) -> some View {
        confirmationDialog(
            "Delete Download",
            isPresented: presentationBinding(pending),
            presenting: pending.wrappedValue
        ) { deletion in
            Button("Delete", role: .destructive) { onDelete(deletion.id) }
            Button("Cancel", role: .cancel) {}
        } message: { deletion in
            Text(deletion.message)
        }
    }

    /// The failure detail an indicator tap shows, with Retry beside OK.
    ///
    /// Retry lives here rather than on the indicator itself so that starting
    /// another transfer is always a second, labelled tap: the indicator is a
    /// small target in a scrolling list, and a mis-tap must not re-dial a
    /// connection that just failed.
    func downloadFailureAlert(
        _ pending: Binding<PendingDownloadFailure?>,
        onRetry: @escaping (String) -> Void
    ) -> some View {
        alert(
            "Download Failed",
            isPresented: presentationBinding(pending),
            presenting: pending.wrappedValue
        ) { failure in
            Button("Retry") { onRetry(failure.id) }
            Button("OK", role: .cancel) {}
        } message: { failure in
            Text(failure.message)
        }
    }
}

/// Bridges an optional payload to the `isPresented` flag SwiftUI wants, clearing
/// it on dismissal so the same row can raise the same prompt again.
private func presentationBinding<Value: Sendable>(_ pending: Binding<Value?>) -> Binding<Bool> {
    Binding(
        get: { pending.wrappedValue != nil },
        set: { shown in if !shown { pending.wrappedValue = nil } }
    )
}
