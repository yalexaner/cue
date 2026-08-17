import Foundation

/// How a background transfer remembers which episode it belongs to.
///
/// A background `URLSession` outlives the process that started it: iOS can
/// relaunch the app to deliver a completion, and the relaunched app holds no
/// continuation, no view and no memory of what it asked for. The only thing that
/// survives with the task is `URLSessionTask.taskDescription`, so the episode's
/// `guid` — the value the store is unique on — rides there.
///
/// Prefixed rather than stored bare so a description written by anything else
/// (or an empty one from a task the app never stamped) is recognisably not ours
/// instead of being resolved as a guid that happens to be blank.
enum DownloadTaskIdentity {
    /// Marks a description as an episode reference rather than free text.
    static let prefix = "episode:"

    /// The episode a transport call is being made for.
    ///
    /// `DownloadManager.FileTransport` answers a file for a URL and knows
    /// nothing about episodes, but the production transport has to stamp the
    /// guid onto the task so a relaunched app can still say what the transfer
    /// was for. A task-local carries it without widening the seam every test
    /// injects against, and it cannot be read stale: it is set around the one
    /// call and scoped to that task.
    ///
    /// It lives here rather than on `DownloadManager` because that type is
    /// `@MainActor` and a transport runs off the main actor — this is a value
    /// both sides have to reach.
    @TaskLocal static var currentGUID: String?

    /// The `taskDescription` to stamp on a transfer for this episode.
    static func taskDescription(forGUID guid: String) -> String {
        prefix + guid
    }

    /// The episode guid a task description refers to, or `nil` when it refers to
    /// nothing this app wrote.
    ///
    /// A guid may itself contain colons — feeds write URLs and tags there — so
    /// only the leading marker is removed and the rest is taken whole.
    static func guid(fromTaskDescription description: String?) -> String? {
        guard let description, description.hasPrefix(prefix) else { return nil }
        let guid = String(description.dropFirst(prefix.count))
        return guid.isEmpty ? nil : guid
    }
}
