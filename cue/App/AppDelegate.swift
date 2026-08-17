import UIKit

/// The app's one UIKit entry point, for the one thing SwiftUI has no scene
/// phase for: a background `URLSession` finishing while the app is not running.
///
/// When a transfer completes with the app suspended or terminated, iOS relaunches
/// it and calls this method with a completion handler that must be invoked once
/// every queued delegate callback has been delivered — the system uses it to
/// decide when the app may be suspended again. Storing the handler and touching
/// the session is all that is needed; `BackgroundDownloader` calls it back from
/// `urlSessionDidFinishEvents`.
///
/// This exists for that single callback. Nothing else about the app's lifecycle
/// belongs here — SwiftUI owns the rest.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == BackgroundDownloader.sessionIdentifier else {
            // not a session this app owns; answering immediately is the only
            // safe thing to do with a handler we will never otherwise call
            completionHandler()
            return
        }
        // UIKit predates strict concurrency and hands this over as a plain
        // non-`Sendable` closure. It is safe to store because the downloader
        // calls it back on the main actor, which is where UIKit requires it and
        // where it arrived from
        nonisolated(unsafe) let handler = completionHandler
        BackgroundDownloader.shared.registerBackgroundEventsCompletion { handler() }
    }
}
