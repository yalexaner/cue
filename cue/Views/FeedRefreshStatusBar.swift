import SwiftUI

/// The one-line banner a running refresh puts above the list.
///
/// A safe-area inset rather than an overlay: it must push the content down
/// rather than sit on top of the first row, and it disappears entirely when
/// there is nothing to say, so a screen that is not refreshing looks exactly as
/// it did before.
///
/// The text itself comes from `feedRefreshStatusText(for:)` or from
/// `feedRefreshSummaryText(refreshed:failed:)`, both plain and tested; this file
/// is chrome only. `isActive` distinguishes the two: a finished sweep's summary
/// still has something to say, but a spinner beside it would claim work is
/// running when none is.
///
/// `onDismiss` is what keeps a *finished* sweep's summary from becoming
/// permanent chrome. A running status clears itself when the sweep ends, but a
/// summary is only replaced by the next sweep — and the library list is the
/// navigation root, so its state lives for the whole session. Without a way out
/// one partial refresh pins a report of a past event above the list until the
/// user happens to pull to refresh again.
extension View {
    func feedRefreshStatusBar(
        _ text: String?, isActive: Bool, onDismiss: (() -> Void)? = nil
    ) -> some View {
        safeAreaInset(edge: .top) {
            if let text {
                HStack(spacing: 8) {
                    if isActive { ProgressView().controlSize(.small) }
                    Text(text)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(text)
                    Spacer(minLength: 0)
                    if let onDismiss {
                        Button(action: onDismiss) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Dismiss")
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .background(.bar)
            }
        }
    }
}
