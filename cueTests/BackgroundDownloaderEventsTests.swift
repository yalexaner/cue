import Foundation
import Testing

@testable import cue

/// The accounting behind UIKit's background-events completion handler.
///
/// Exercised through the value-returning core — `storeBackgroundEventsCompletion`,
/// `noteBackgroundEventsDelivered`, `finishDeliveredWork` — so no test constructs
/// a background session and what is ready to be called is assertable without
/// hopping to the main actor. Do not add a case that touches `session`.
struct BackgroundDownloaderEventsTests {
    private func staged(in base: URL) throws -> URL {
        let staged = base.appending(path: "staged.tmp", directoryHint: .notDirectory)
        try Data("audio".utf8).write(to: staged)
        return staged
    }

    @Test func aHandlerRegisteredBeforeTheEventsAreDeliveredWaits() {
        let downloader = BackgroundDownloader()

        let ready = downloader.storeBackgroundEventsCompletion({})

        #expect(ready.isEmpty)
    }

    /// The suspended-not-terminated order: the session was already alive, so it
    /// can report its events delivered before UIKit hands the handler over.
    /// Consuming that signal for a handler nobody had yet leaves the arriving
    /// handler waiting for an edge that never comes again — the app then holds
    /// its background assertion until the system kills it.
    @Test func aHandlerRegisteredAfterTheEventsWereDeliveredIsReadyAtOnce() {
        let downloader = BackgroundDownloader()

        #expect(downloader.noteBackgroundEventsDelivered().isEmpty)
        let ready = downloader.storeBackgroundEventsCompletion({})

        #expect(ready.count == 1)
    }

    /// The events are delivered, but the work one of them started is not done:
    /// answering there lets the system suspend the app mid-move.
    @Test func aHandlerIsNotAnsweredWhileDeliveredWorkIsStillInFlight() throws {
        let downloader = BackgroundDownloader()

        downloader.route(.failure(StubTransportError.offline), forGUID: "guid-1")

        #expect(downloader.noteBackgroundEventsDelivered().isEmpty)
        #expect(downloader.storeBackgroundEventsCompletion({}).isEmpty)
        #expect(downloader.finishDeliveredWork().count == 1)
    }

    /// A second wake while an earlier outcome is still being finished must not
    /// answer the first handler inline. Both are held, and both are answered
    /// once the work is done — UIKit requires every handler it hands over to be
    /// called, and neither may be called early.
    @Test func aSecondHandlerNeitherReplacesNorReleasesTheFirst() throws {
        try withTemporaryBase { base in
            let downloader = BackgroundDownloader()
            let url = try #require(URL(string: "https://example.com/audio/1.mp3"))
            let response = try #require(
                HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))

            downloader.route(.success((try staged(in: base), response)), forGUID: "guid-1")

            #expect(downloader.storeBackgroundEventsCompletion({}).isEmpty)
            #expect(downloader.storeBackgroundEventsCompletion({}).isEmpty)
            #expect(downloader.noteBackgroundEventsDelivered().isEmpty)
            #expect(downloader.finishDeliveredWork().count == 2)
        }
    }
}
