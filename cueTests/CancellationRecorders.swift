import Foundation

@testable import cue

/// Records what the manager asked the session to cancel, and answers at once.
///
/// Shared for the reason `GatedFileTransport` is: two suites cover the
/// cancellation seam, and a second copy of a double is the duplication the
/// shared doubles exist to avoid.
final class CancellationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var requestedGUIDs: [String] = []
    private var requestedIdentifiers: [Int] = []

    var guids: [String] { lock.withLock { requestedGUIDs } }
    var identifiers: [Int] { lock.withLock { requestedIdentifiers } }
    var request: DownloadManager.CancellationRequest {
        { [self] guid, taskIdentifier in
            lock.withLock {
                requestedGUIDs.append(guid)
                requestedIdentifiers.append(taskIdentifier)
            }
        }
    }
}

/// The same recorder, parked until released: a slow `session.allTasks`.
///
/// The enumeration a real request suspends on is what lets the attempt it names
/// retire before the answer arrives, so a test that needs that window holds the
/// request open across it.
final class ParkedCancellationRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var requestedGUIDs: [String] = []
    private var requestedIdentifiers: [Int] = []
    private var parked: [CheckedContinuation<Void, Never>] = []
    private var isReleased = false

    var guids: [String] { lock.withLock { requestedGUIDs } }
    var identifiers: [Int] { lock.withLock { requestedIdentifiers } }

    func release() {
        let waiting = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            isReleased = true
            let waiting = parked
            parked = []
            return waiting
        }
        for continuation in waiting { continuation.resume() }
    }

    var request: DownloadManager.CancellationRequest {
        { [self] guid, taskIdentifier in
            lock.withLock {
                requestedGUIDs.append(guid)
                requestedIdentifiers.append(taskIdentifier)
            }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let released = lock.withLock { () -> Bool in
                    guard !isReleased else { return true }
                    parked.append(continuation)
                    return false
                }
                if released { continuation.resume() }
            }
        }
    }
}
