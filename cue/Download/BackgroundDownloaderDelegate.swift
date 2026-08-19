import Foundation

extension BackgroundDownloader {
    /// Stores the handler UIKit hands over when it relaunches us for a finished
    /// background transfer. Called back once the session says it has delivered
    /// every event it had.
    func registerBackgroundEventsCompletion(_ handler: @escaping @Sendable () -> Void) {
        callOnMain(storeBackgroundEventsCompletion(handler))
        // touching the session is what recreates it, and recreating it is what
        // makes the queued delegate callbacks arrive
        _ = session
    }

    /// Stores a handler and answers the ones that may be called right now.
    ///
    /// Handlers queue rather than replace each other: answering a replaced one
    /// inline reports "safe to suspend" while a delivered outcome is still being
    /// finished, which is the suspension the accounting exists to prevent. A
    /// handler registered *after* its events were already delivered is ready
    /// immediately — the suspended-not-terminated order, where the session was
    /// alive and finished its work before UIKit handed the handler over.
    ///
    /// Internal, and value-returning, so the accounting is testable without
    /// constructing a background session.
    func storeBackgroundEventsCompletion(_ handler: @escaping @Sendable () -> Void) -> [@Sendable () -> Void] {
        lock.withLock {
            backgroundEventsCompletions.append(handler)
            return takeBackgroundEventsCompletionsIfReady()
        }
    }

    /// Reports that the work for one delivered outcome has finished.
    ///
    /// The system may suspend the app as soon as the stored UIKit handler is
    /// called, so it is called only once every delivered outcome has been dealt
    /// with. Calling it while a finish is still moving a file is how a claimed
    /// download ends up abandoned in `tmp` with nothing recorded — and that is
    /// as true of an outcome answered through a live continuation (the app was
    /// merely suspended, not terminated) as of an orphaned one, so both routes
    /// are counted and both call this.
    func completeDeliveredWork() {
        callOnMain(finishDeliveredWork())
    }

    /// The value-returning core of `completeDeliveredWork()`.
    func finishDeliveredWork() -> [@Sendable () -> Void] {
        lock.withLock {
            deliveredWorkInFlight = max(0, deliveredWorkInFlight - 1)
            return takeBackgroundEventsCompletionsIfReady()
        }
    }

    /// Records that the session has delivered every event it had, and answers
    /// the handlers that may be called now.
    func noteBackgroundEventsDelivered() -> [@Sendable () -> Void] {
        lock.withLock {
            backgroundEventsDelivered = true
            return takeBackgroundEventsCompletionsIfReady()
        }
    }

    /// The stored UIKit handlers, once the session has delivered every event and
    /// nothing is still being finished. The lock must be held.
    ///
    /// The delivered signal is consumed only when handlers actually leave:
    /// clearing it for an empty queue throws away the one edge a handler
    /// registered a moment later is waiting for, and that handler is then never
    /// called — the app keeps its background assertion until the watchdog takes
    /// it away.
    private func takeBackgroundEventsCompletionsIfReady() -> [@Sendable () -> Void] {
        guard backgroundEventsDelivered, deliveredWorkInFlight == 0, !backgroundEventsCompletions.isEmpty
        else { return [] }
        let handlers = backgroundEventsCompletions
        backgroundEventsCompletions = []
        backgroundEventsDelivered = false
        return handlers
    }

    /// UIKit requires its handlers on the main thread.
    private func callOnMain(_ handlers: [@Sendable () -> Void]) {
        guard !handlers.isEmpty else { return }
        Task { @MainActor in
            for handler in handlers {
                handler()
            }
        }
    }
}

// MARK: - URLSessionDownloadDelegate

extension BackgroundDownloader: URLSessionDownloadDelegate {
    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        reportProgress(
            taskIdentifier: downloadTask.taskIdentifier,
            taskDescription: downloadTask.taskDescription,
            bytesWritten: totalBytesWritten,
            expectedBytes: totalBytesExpectedToWrite)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // claimed here, synchronously, because `location` is deleted as soon as
        // this method returns
        do {
            let claimed = try Self.claim(location)
            deliver(.success((claimed, downloadTask.response ?? URLResponse())), for: downloadTask)
        } catch {
            deliver(.failure(error), for: downloadTask)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // a successful download already answered from `didFinishDownloadingTo`
        // and took its continuation with it, so this only has work to do when
        // the transfer failed
        guard let error else { return }
        deliver(.failure(error), for: task)
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        // every event is delivered, but the work they started may still be
        // running, and the handler may not have been handed over yet;
        // `completeDeliveredWork()` and the registration answer those cases
        callOnMain(noteBackgroundEventsDelivered())
    }
}
