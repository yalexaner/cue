import Foundation
import Testing

@testable import cue

/// The handover between a caller waiting on a transfer and the delegate that
/// answers it.
///
/// Exercised through `claimTransfer`, `awaitTransfer` and the task-identifier
/// form of `deliver` — the value-carrying core — so no test constructs a
/// background session. Do not add a case that touches `session`.
@MainActor
struct BackgroundDownloaderTransferTests {
    private static let taskDescription = DownloadTaskIdentity.taskDescription(forGUID: "guid-1")

    private func response() throws -> HTTPURLResponse {
        let url = try #require(URL(string: "https://example.com/audio/1.mp3"))
        return try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
    }

    /// `withTaskCancellationHandler` runs `onCancel` *before* the operation body
    /// when the caller is already cancelled, so the delegate can answer before
    /// the continuation exists. Answering that as an orphan leaves the caller
    /// suspended for the life of the process.
    @Test func anAlreadyCancelledCallerIsAnsweredRatherThanStranded() async throws {
        let downloader = BackgroundDownloader()
        downloader.claimTransfer(taskIdentifier: 1)
        let answers = HookCount()

        // the task inherits this suite's actor, so it cannot start before the
        // cancellation below — the ordering the bug needs, made deterministic
        let waiter = Task {
            defer { answers.record() }
            _ = try await downloader.awaitTransfer(
                taskIdentifier: 1, onStart: {},
                // what the session does with a cancelled task: the delegate
                // reports the failure
                onCancel: {
                    downloader.deliver(
                        .failure(CancellationError()), forTaskIdentifier: 1, taskDescription: nil)
                })
        }
        waiter.cancel()

        // bounded rather than `await waiter.value`: a stranded caller never
        // returns, and this has to fail the expectation instead of the suite
        var spins = 0
        while answers.count == 0, spins < 1_000 {
            await Task.yield()
            spins += 1
        }

        #expect(answers.count == 1)
    }

    /// The same window, without cancellation: the outcome is held in the slot
    /// and handed to the caller as it installs, rather than being routed away.
    @Test func aCompletionDeliveredBeforeTheContinuationStillAnswersItsCaller() async throws {
        try await withTemporaryBaseAsync { base in
            let downloader = BackgroundDownloader()
            let staged = base.appending(path: "staged.tmp", directoryHint: .notDirectory)
            try Data("audio".utf8).write(to: staged)
            let received = ReceivedCompletions()
            downloader.setOrphanedCompletionHandler { result, guid in received.record(result, guid: guid) }
            let starts = HookCount()

            downloader.claimTransfer(taskIdentifier: 2)
            downloader.deliver(
                .success((staged, try response())), forTaskIdentifier: 2,
                taskDescription: Self.taskDescription)

            // through a task and a bounded wait, for the reason the cancellation
            // case is: the regression this pins suspends the caller for good
            let answered = AnsweredFile()
            _ = Task {
                let (file, _) = try await downloader.awaitTransfer(
                    taskIdentifier: 2, onStart: { starts.record() }, onCancel: {})
                answered.record(file)
            }
            var spins = 0
            while answered.file == nil, spins < 1_000 {
                await Task.yield()
                spins += 1
            }

            #expect(answered.file == staged)
            // the transfer already finished; resuming the task would run it twice
            #expect(starts.count == 0)
            // and it is not an orphan — its caller was on the way
            #expect(received.guids.isEmpty)
        }
    }

    /// The route the relaunch case depends on is untouched: a completion for a
    /// task this process never claimed still reaches the orphan handler.
    @Test func aCompletionWithNoWaitingCallerStillReachesTheOrphanRoute() {
        let downloader = BackgroundDownloader()
        let received = ReceivedCompletions()
        downloader.setOrphanedCompletionHandler { result, guid in received.record(result, guid: guid) }

        downloader.deliver(
            .failure(StubTransportError.offline), forTaskIdentifier: 3,
            taskDescription: Self.taskDescription)

        #expect(received.guids == ["guid-1"])
        #expect(received.succeeded == [false])
    }
}

/// The file a waiting caller was answered with, if it was answered at all.
private final class AnsweredFile: @unchecked Sendable {
    private let lock = NSLock()
    private var answered: URL?

    var file: URL? { lock.withLock { answered } }

    func record(_ url: URL) {
        lock.withLock { answered = url }
    }
}

/// How many times a hook ran — a transfer asked to start, or a caller answered.
private final class HookCount: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    var count: Int { lock.withLock { calls } }

    func record() {
        lock.withLock { calls += 1 }
    }
}
