import Foundation

@testable import cue

/// A file transport that parks every call until it is opened.
///
/// `DownloadTransportStub` answers as fast as it is asked, which is what makes
/// it useless for observing an episode *while* its transfer is in flight; this
/// one holds the transfer open until the test says otherwise.
///
/// Not private to any suite: `DownloadManagerOwnershipTests` needs the same
/// held-open transfer to observe a completion arriving *during* one, and a
/// second copy of a double is the duplication the shared doubles exist to
/// avoid — the same rule that put `yieldUntil` in a file of its own.
final class GatedFileTransport: @unchecked Sendable {
    private let lock = NSLock()
    private let stagingDirectory: URL
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false
    private var calls = 0

    init(stagingDirectory: URL) {
        self.stagingDirectory = stagingDirectory
    }

    var callCount: Int { lock.withLock { calls } }

    /// Lets every parked call through, and every later one straight past.
    func open() {
        let parked = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            isOpen = true
            let parked = waiting
            waiting = []
            return parked
        }
        for continuation in parked {
            continuation.resume()
        }
    }

    var transport: DownloadManager.FileTransport {
        { [self] url in
            lock.withLock { calls += 1 }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let alreadyOpen = lock.withLock { () -> Bool in
                    guard isOpen else {
                        waiting.append(continuation)
                        return false
                    }
                    return true
                }
                if alreadyOpen { continuation.resume() }
            }
            guard
                let response = HTTPURLResponse(
                    url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
            else {
                throw StubTransportError.unbuildableResponse
            }
            let temporaryURL = stagingDirectory.appending(
                path: "gated-\(UUID().uuidString).tmp", directoryHint: .notDirectory)
            try Data("audio".utf8).write(to: temporaryURL)
            return (temporaryURL, response)
        }
    }
}
