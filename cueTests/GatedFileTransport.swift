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
    private struct Waiter {
        let id: UUID
        let guid: String
        let continuation: CheckedContinuation<Void, Error>
    }

    private let lock = NSLock()
    private let stagingDirectory: URL
    private var waiting: [Waiter] = []
    private var isOpen = false
    private var calls = 0
    private var cancelledGUIDs: [String] = []

    init(stagingDirectory: URL) {
        self.stagingDirectory = stagingDirectory
    }

    var callCount: Int { lock.withLock { calls } }
    var cancellationRequests: [String] { lock.withLock { cancelledGUIDs } }

    /// Lets every parked call through, and every later one straight past.
    func open() {
        resume(
            parked: lock.withLock { () -> [Waiter] in
                isOpen = true
                let parked = waiting
                waiting = []
                return parked
            })
    }

    /// Lets the calls parked *now* through and leaves the gate shut behind them.
    ///
    /// `open()` is permanent, so a transfer that reaches the transport after it
    /// is never held: its `connecting` phase lasts only as long as the transport
    /// takes to answer, and `yieldUntil` samples between scheduler turns, so a
    /// test asserting that phase can miss it and read the cleared state of a
    /// finished transfer instead. Releasing only the current waiters hands the
    /// slot on while keeping the next transfer parked, which makes `connecting`
    /// a state that persists until the test says otherwise.
    func openParked() {
        resume(
            parked: lock.withLock { () -> [Waiter] in
                let parked = waiting
                waiting = []
                return parked
            })
    }

    private func resume(parked: [Waiter]) {
        for waiter in parked {
            waiter.continuation.resume()
        }
    }

    /// Cancels only calls already parked for `guid`; a later retry is clean.
    func cancel(guid: String) {
        let cancelled = lock.withLock { () -> [Waiter] in
            cancelledGUIDs.append(guid)
            let cancelled = waiting.filter { $0.guid == guid }
            waiting.removeAll { $0.guid == guid }
            return cancelled
        }
        for waiter in cancelled {
            waiter.continuation.resume(throwing: CancellationError())
        }
    }

    var cancellationRequest: DownloadManager.CancellationRequest {
        { [self] guid, _ in cancel(guid: guid) }
    }

    var transport: DownloadManager.FileTransport {
        { [self] url in
            lock.withLock { calls += 1 }
            try await waitUntilOpen(guid: DownloadTaskIdentity.currentGUID ?? "")
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

    private func waitUntilOpen(guid: String) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                enum Verdict { case proceed, cancelled, park }
                let verdict = lock.withLock { () -> Verdict in
                    if isOpen { return .proceed }
                    if Task.isCancelled { return .cancelled }
                    waiting.append(Waiter(id: id, guid: guid, continuation: continuation))
                    return .park
                }
                switch verdict {
                case .proceed: continuation.resume()
                // A cancellation delivered before the waiter is registered has to
                // resolve inside the same critical section as the append: `cancel(id:)`
                // finds no waiter to cancel, so the park would never be released.
                case .cancelled: continuation.resume(throwing: CancellationError())
                case .park: break
                }
            }
        } onCancel: {
            cancel(id: id)
        }
    }

    private func cancel(id: UUID) {
        let cancelled = lock.withLock { () -> Waiter? in
            guard let index = waiting.firstIndex(where: { $0.id == id }) else { return nil }
            return waiting.remove(at: index)
        }
        cancelled?.continuation.resume(throwing: CancellationError())
    }
}
