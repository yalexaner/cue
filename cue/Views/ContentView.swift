import SwiftUI

/// The app's root: a tab bar over the two screens that exist (spec §12).
///
/// Each tab owns its own `NavigationStack`, so a push into a show's episodes and
/// a push out of Downloads keep separate histories — one shared stack would make
/// switching tabs a navigation event.
struct ContentView: View {
    var body: some View {
        TabView {
            Tab("Library", systemImage: "books.vertical") {
                NavigationStack {
                    LibraryView()
                }
            }
            Tab("Downloads", systemImage: "arrow.down.circle") {
                NavigationStack {
                    DownloadsView()
                }
            }
        }
    }
}
