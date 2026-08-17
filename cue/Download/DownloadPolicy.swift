import AVFoundation
import Foundation

/// The download decisions that hold no state: what may be fetched, what a
/// response means, and how long the file turned out to be.
///
/// Static members of `DownloadManager` rather than free functions — both the
/// transport route and the relaunch route ask them, and the answers are download
/// policy, not view policy. They live in their own file because they need
/// nothing the manager holds, which also keeps `DownloadManager.swift` under the
/// `file_length` warning `--strict` turns into an error.
extension DownloadManager {
    /// The enclosure address as something fetchable, or `nil` when it is not.
    ///
    /// Same rule as `FeedService.fetch(urlString:)`: only `http`/`https`, so a
    /// `file:` enclosure in a feed cannot make the app read a local path.
    static func downloadURL(for enclosureURL: String) -> URL? {
        guard let url = URL(string: enclosureURL), let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https"
        else {
            return nil
        }
        return url
    }

    /// The failure a non-2xx answer deserves, or `nil` when the status is fine.
    ///
    /// A non-HTTP response carries no status to judge, exactly as on the feed
    /// side. Shared so the relaunch route is gated the same way the transport
    /// route is.
    static func statusFailure(for response: URLResponse?, enclosureURL: String) -> Failure? {
        guard let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) else {
            return nil
        }
        return .httpStatus(http.statusCode, enclosureURL)
    }

    /// The audio duration of the file at `url`, or `nil` when it cannot be read.
    ///
    /// `@concurrent nonisolated` rather than bare `nonisolated`, per the
    /// networking convention: opening and parsing an audio container is work
    /// that must not run on the UI thread, and an async `nonisolated` function
    /// only hops to the concurrent executor by a language-mode default that
    /// `NonisolatedNonsendingByDefault` inverts.
    ///
    /// Every failure answers `nil` — a file the reader cannot make sense of, an
    /// indefinite stream, a duration that is not a finite positive number. The
    /// measurement is an improvement on `feedDuration`, never a precondition for
    /// having downloaded the file, so nothing here is allowed to throw.
    @concurrent nonisolated static func assetDuration(at url: URL) async -> TimeInterval? {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration) else { return nil }
        let seconds = duration.seconds
        guard seconds.isFinite, seconds > 0 else { return nil }
        return seconds
    }
}
