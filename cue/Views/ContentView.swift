import SwiftUI

/// The app's root. A single `NavigationStack` over the library.
///
/// No `TabView` yet — the tab bar arrives with the second tab (Downloads), and
/// a one-tab bar is just chrome.
struct ContentView: View {
    var body: some View {
        NavigationStack {
            LibraryView()
        }
    }
}
