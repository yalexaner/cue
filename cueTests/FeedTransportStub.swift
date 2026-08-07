import Foundation

@testable import cue

/// The errors a stub transport raises on its own behalf.
enum StubTransportError: Error, Equatable {
    case offline
    case unreachable(String)
    /// `HTTPURLResponse.init` is failable for reasons none of these calls can
    /// hit, and force unwrapping is banned — so the stub throws rather than
    /// degrading to a plain `URLResponse`, which the service reads as "no
    /// status to judge" and would quietly run a status test down the 2xx path.
    case unbuildableResponse
}

/// The one test double for `FeedService.Transport`.
///
/// Serves fixed bytes at a fixed status, records every URL it was asked for so a
/// test can assert the request was made verbatim (spec §6), and can be told to
/// fail — globally, or only for named URLs so a sweep test can watch one dead
/// feed among healthy ones. All three are swappable between calls, so one test
/// can watch a feed change underneath a refresh.
///
/// The closure is `@Sendable`, so the mutable answer lives behind a lock in a
/// reference type rather than in a captured `var`. A single stub rather than one
/// per suite, following the same rule as the shared fixture loader: a change to
/// the transport signature must not have to be made in three places.
final class FeedTransportStub: @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data
    private var statusCode = 200
    private var error: Error?
    private var failures: [String: any Error]
    private var urls: [URL] = []

    init(data: Data, failures: [String: any Error] = [:]) {
        self.data = data
        self.failures = failures
    }

    /// Every URL requested, in order, exactly as asked for — the assertion that
    /// a tokenised address reached the wire unrewritten (spec §6). Strings
    /// rather than `URL`s because every caller compares against the pasted
    /// address, and a `URL` round trip is the very thing under test.
    var requestedURLStrings: [String] { lock.withLock { urls }.map(\.absoluteString) }

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

    var transport: FeedService.Transport {
        { [self] url in
            let (data, statusCode, error) = lock.withLock {
                self.urls.append(url)
                return (self.data, self.statusCode, self.error ?? self.failures[url.absoluteString])
            }
            if let error { throw error }
            guard
                let response = HTTPURLResponse(
                    url: url, statusCode: statusCode, httpVersion: nil, headerFields: nil)
            else {
                throw StubTransportError.unbuildableResponse
            }
            return (data, response)
        }
    }
}

/// A transport that fails before it answers anything.
func failingTransport(_ error: Error = StubTransportError.offline) -> FeedService.Transport {
    { _ in throw error }
}

/// A response the service treats as carrying no status to judge.
func nonHTTPTransport(data: Data) -> FeedService.Transport {
    { url in
        (data, URLResponse(url: url, mimeType: nil, expectedContentLength: -1, textEncodingName: nil))
    }
}
