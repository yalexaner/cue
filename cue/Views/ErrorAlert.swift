import SwiftUI

/// A titled error alert, driven straight off an optional message.
///
/// Several screens carry the same optional `String` and the same alert; bridging
/// that optional to `.alert(isPresented:)` by hand in each of them also meant
/// unwrapping it again with an unreachable `?? ""` fallback. Presenting the
/// message itself hands the body a non-optional value and leaves one copy.
///
/// The title is a parameter because a screen can fail in more than one way, and
/// a save failure reported as "Refresh Failed" names the wrong thing.
extension View {
    func errorAlert(_ title: String, _ message: Binding<String?>) -> some View {
        alert(
            title,
            isPresented: Binding(
                get: { message.wrappedValue != nil },
                set: { shown in if !shown { message.wrappedValue = nil } }
            ),
            presenting: message.wrappedValue
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { text in
            Text(text)
        }
    }

    func refreshErrorAlert(_ message: Binding<String?>) -> some View {
        errorAlert("Refresh Failed", message)
    }
}
