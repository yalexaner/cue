import Foundation

@testable import cue

/// The one test double for `DownloadManager.FileTransport`.
///
/// Writes its bytes to a fresh file in `stagingDirectory` per call, because the
/// manager *moves* what it is handed — a shared file would exist for the first
/// download only. The staging directory is the test's temporary base, so no
/// stub ever writes outside it.
///
/// Records every URL it was asked for, can be told to fail or to answer a
/// status, and tracks how many calls were ever in flight at once so the
/// one-transfer-at-a-time rule (spec §7) is assertable. Answers can be swapped
/// between calls. A single stub rather than one per suite, following the same
/// rule as `FeedTransportStub` and the shared fixture loader.
final class DownloadTransportStub: @unchecked Sendable {
    private let lock = NSLock()
    private let stagingDirectory: URL
    private var data: Data
    private var statusCode = 200
    private var error: Error?
    private var urls: [URL] = []
    private var inFlight = 0
    private var observedPeakInFlight = 0
    private var onAnswer: (@Sendable () -> Void)?

    init(data: Data = Data("audio".utf8), stagingDirectory: URL) {
        self.data = data
        self.stagingDirectory = stagingDirectory
    }

    /// Every URL requested, in order, exactly as asked for.
    var requestedURLStrings: [String] { lock.withLock { urls }.map(\.absoluteString) }

    /// The most calls that were ever inside the transport simultaneously.
    var peakInFlight: Int { lock.withLock { observedPeakInFlight } }

    func serve(data: Data) {
        lock.withLock { self.data = data }
    }

    func serve(statusCode: Int) {
        lock.withLock { self.statusCode = statusCode }
    }

    /// Fail every request from now on.
    func fail(with error: Error) {
        lock.withLock { self.error = error }
    }

    /// Runs just before an answer is handed back — the hook a cancellation test
    /// uses to cancel while the response is already in hand.
    func whenAnswering(_ body: @escaping @Sendable () -> Void) {
        lock.withLock { self.onAnswer = body }
    }

    var transport: DownloadManager.FileTransport {
        { [self] url in
            let (data, statusCode, error) = lock.withLock {
                self.urls.append(url)
                self.inFlight += 1
                self.observedPeakInFlight = max(self.observedPeakInFlight, self.inFlight)
                return (self.data, self.statusCode, self.error)
            }
            // registered before the suspension, not after: nothing between the
            // increment and here throws today, but a `try` added above would
            // skip the decrement and quietly corrupt the peak this stub exists
            // to measure
            defer { lock.withLock { self.inFlight -= 1 } }
            // a real transfer suspends; without this every call would run to
            // completion before the next one started and overlap could not show
            await Task.yield()

            if let error { throw error }
            guard
                let response = HTTPURLResponse(
                    url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil)
            else {
                throw StubTransportError.unbuildableResponse
            }
            let temporaryURL = stagingDirectory.appending(
                path: "staged-\(UUID().uuidString).tmp", directoryHint: .notDirectory)
            try data.write(to: temporaryURL)
            lock.withLock { self.onAnswer }?()
            return (temporaryURL, response)
        }
    }
}

/// A file transport that fails before it answers anything.
func failingFileTransport(_ error: Error = StubTransportError.offline) -> DownloadManager.FileTransport {
    { _ in throw error }
}

/// A transport whose temporary file is not there — the move must fail.
///
/// Not something `DownloadTransportStub` can produce by accident, which is why
/// it lives here rather than as a flag on the stub.
func missingFileTransport(in directory: URL) -> DownloadManager.FileTransport {
    { url in
        guard
            let response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: nil, headerFields: nil)
        else {
            throw StubTransportError.unbuildableResponse
        }
        let missing = directory.appending(
            path: "never-written-\(UUID().uuidString).tmp", directoryHint: .notDirectory)
        return (missing, response)
    }
}
