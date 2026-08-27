import Foundation
import SwiftData
import Testing

@testable import cue

/// Byte reporting and what reaches the published state.
///
/// The downloader cases use only value-carrying seams. Constructing a
/// `BackgroundDownloader` is safe; no case touches its session.
@MainActor
struct DownloadManagerProgressTests {
    @Test func delegateProgressMapsTaskDescriptionToGUID() {
        let downloader = BackgroundDownloader()
        let events = RecordedProgressEvents()
        downloader.setProgressHandler { taskIdentifier, guid, progress in
            events.record(taskIdentifier: taskIdentifier, guid: guid, progress: progress)
        }

        downloader.reportProgress(
            taskIdentifier: 7,
            taskDescription: DownloadTaskIdentity.taskDescription(forGUID: "guid-1"),
            bytesWritten: 25, expectedBytes: 100)
        downloader.reportProgress(
            taskIdentifier: 8, taskDescription: "not-cue", bytesWritten: 50,
            expectedBytes: 100)

        let expected = RecordedProgress(
            taskIdentifier: 7, guid: "guid-1", progress: .fraction(bytesWritten: 25, expectedBytes: 100))
        #expect(events.values == [expected])
    }

    @Test func unknownAndInvalidTotalsAreHandledWithoutInvalidFractions() {
        #expect(
            DownloadProgress.reported(bytesWritten: 12, expectedBytes: -1)
                == .indeterminate(bytesWritten: 12))
        #expect(
            DownloadProgress.reported(bytesWritten: 12, expectedBytes: 0)
                == .indeterminate(bytesWritten: 12))
        #expect(DownloadProgress.reported(bytesWritten: -1, expectedBytes: 100) == nil)
        // over-delivery keeps the real total, so "X of Y" survives, while the
        // ratio a bar draws is still clamped
        #expect(
            DownloadProgress.reported(bytesWritten: 150, expectedBytes: 100)
                == .fraction(bytesWritten: 150, expectedBytes: 100))
        #expect(DownloadProgress.fraction(bytesWritten: 150, expectedBytes: 100).fractionValue == 1)
        #expect(DownloadProgress.fraction(bytesWritten: 0, expectedBytes: 100).fractionValue == 0)
        // a total that never came through `reported` cannot divide
        #expect(DownloadProgress.fraction(bytesWritten: 10, expectedBytes: 0).fractionValue == nil)
        #expect(DownloadProgress.connecting.fractionValue == nil)
        #expect(DownloadProgress.queued(position: 2).bytesWritten == 0)
        #expect(DownloadProgress.connecting.bytesWritten == 0)
    }

    /// A queue position is displayed, so a reindex must always redraw; the
    /// phases before it are stable, and only whole percent moves a bar.
    @Test func onlyVisibleChangesAreWorthPublishing() {
        let queued = DownloadProgress.queued(position: 2)
        #expect(!queued.rendersDifferently(from: .queued(position: 2)))
        #expect(queued.rendersDifferently(from: .queued(position: 1)))
        #expect(queued.rendersDifferently(from: .connecting))
        #expect(!DownloadProgress.connecting.rendersDifferently(from: .connecting))
        #expect(DownloadProgress.connecting.rendersDifferently(from: .indeterminate(bytesWritten: 1)))
        // an indeterminate transfer now shows its byte count, so a byte change
        // is a redraw; the flood is held off by the throttle, not by pretending
        // nothing moved
        #expect(
            DownloadProgress.indeterminate(bytesWritten: 9)
                .rendersDifferently(from: .indeterminate(bytesWritten: 4)))
        #expect(
            !DownloadProgress.indeterminate(bytesWritten: 9)
                .rendersDifferently(from: .indeterminate(bytesWritten: 9)))
        // the rate is displayed too, bucketed to whole kilobytes per second
        #expect(
            DownloadProgress.indeterminate(bytesWritten: 9, bytesPerSecond: 4096)
                .rendersDifferently(from: .indeterminate(bytesWritten: 9, bytesPerSecond: 8192)))
        #expect(
            !DownloadProgress.indeterminate(bytesWritten: 9, bytesPerSecond: 4096)
                .rendersDifferently(from: .indeterminate(bytesWritten: 9, bytesPerSecond: 4100)))
        // the two phases after the bytes stop are their own rows
        #expect(
            DownloadProgress.stalled(bytesWritten: 500, expectedBytes: 1000)
                .rendersDifferently(from: .fraction(bytesWritten: 500, expectedBytes: 1000)))
        #expect(
            DownloadProgress.finalizing(bytesWritten: 1000)
                .rendersDifferently(from: .fraction(bytesWritten: 1000, expectedBytes: 1000)))
        let half = DownloadProgress.fraction(bytesWritten: 500, expectedBytes: 1000)
        // the byte count is displayed beside the bar, so two bytes apart is a
        // different row even at the same whole percent
        #expect(half.rendersDifferently(from: .fraction(bytesWritten: 502, expectedBytes: 1000)))
        #expect(!half.rendersDifferently(from: .fraction(bytesWritten: 500, expectedBytes: 1000)))
        #expect(half.rendersDifferently(from: .fraction(bytesWritten: 510, expectedBytes: 1000)))
        // the same bytes against a corrected total is a different bar
        #expect(half.rendersDifferently(from: .fraction(bytesWritten: 500, expectedBytes: 2000)))
    }

    @Test func lowerByteUpdatesAreDroppedEvenWhenTheyArriveLater() async throws {
        try await withTemporaryBaseAsync { base in
            let manager = try makeProgressManager(base: base)
            _ = try beginProgressAttempt(on: manager)

            manager.handleProgress(
                taskIdentifier: 1, guid: "guid-1",
                progress: .fraction(bytesWritten: 80, expectedBytes: 100))
            manager.handleProgress(
                taskIdentifier: 1, guid: "guid-1",
                progress: .fraction(bytesWritten: 40, expectedBytes: 100))

            #expect(manager.states["guid-1"] == .downloading(.fraction(bytesWritten: 80, expectedBytes: 100)))
        }
    }

    @Test func equalBytesCanBecomeKnownAndAcceptACorrectedTotal() async throws {
        try await withTemporaryBaseAsync { base in
            let clock = ManualDownloadClock()
            let manager = try makeProgressManager(base: base, clock: clock)
            _ = try beginProgressAttempt(on: manager)

            manager.handleProgress(
                taskIdentifier: 1, guid: "guid-1",
                progress: .indeterminate(bytesWritten: 50))
            #expect(manager.states["guid-1"] == .downloading(.indeterminate(bytesWritten: 50)))

            // past the throttle interval, so each corrected total publishes on
            // its own rather than through the trailing publication
            clock.advance(by: DownloadPacing.publishInterval)
            manager.handleProgress(
                taskIdentifier: 1, guid: "guid-1",
                progress: .fraction(bytesWritten: 50, expectedBytes: 100))
            // no byte moved across the window, so the measured rate is zero
            #expect(
                manager.states["guid-1"]
                    == .downloading(.fraction(bytesWritten: 50, expectedBytes: 100, bytesPerSecond: 0)))

            clock.advance(by: DownloadPacing.publishInterval)
            manager.handleProgress(
                taskIdentifier: 1, guid: "guid-1",
                progress: .fraction(bytesWritten: 50, expectedBytes: 200))
            #expect(
                manager.states["guid-1"]
                    == .downloading(.fraction(bytesWritten: 50, expectedBytes: 200, bytesPerSecond: 0)))
        }
    }

    @Test func registrationCompletesBeforeTheFirstProgressEvent() async throws {
        try await withTemporaryBaseAsync { base in
            let manager = try makeProgressManager(base: base)
            let downloader = BackgroundDownloader()
            manager.registerCompletionRoute(with: downloader)
            _ = try #require(manager.claimOwnership(of: "guid-1"))
            manager.states["guid-1"] = .downloading(.connecting)

            await downloader.registerStart(taskIdentifier: 9, guid: "guid-1")
            downloader.reportProgress(
                taskIdentifier: 9,
                taskDescription: DownloadTaskIdentity.taskDescription(forGUID: "guid-1"),
                bytesWritten: 30, expectedBytes: 60)
            await yieldUntil {
                manager.states["guid-1"] == .downloading(.fraction(bytesWritten: 30, expectedBytes: 60))
            }

            #expect(manager.states["guid-1"] == .downloading(.fraction(bytesWritten: 30, expectedBytes: 60)))
        }
    }

    @Test func transportStubRegistersBeforeItsProgressHook() async throws {
        try await withTemporaryBaseAsync { base in
            let stub = DownloadTransportStub(stagingDirectory: base)
            let events = OrderedHooks()
            stub.setAttemptRegistrationHandler { _, _ in events.record("registered") }
            stub.setProgressHandler { _, _, _ in events.record("progress") }
            stub.reportOnNextAnswer(.indeterminate(bytesWritten: 10))
            let url = try #require(URL(string: DownloadProgressFixtures.enclosureURL))

            _ = try await DownloadTaskIdentity.$currentGUID.withValue("guid-1") {
                try await stub.transport(url)
            }

            #expect(events.values == ["registered", "progress"])
        }
    }

    /// Byte callbacks arrive many times a second, and every published state
    /// re-evaluates both download screens, so a report that would draw the same
    /// row is recorded on the attempt without being published.
    @Test func progressThatWouldRedrawTheSameRowIsNotPublished() throws {
        try withTemporaryBase { base in
            let clock = ManualDownloadClock()
            let manager = try makeProgressManager(base: base, clock: clock)
            _ = try beginProgressAttempt(on: manager, taskIdentifier: 1)
            let half = DownloadProgress.fraction(bytesWritten: 500, expectedBytes: 1000)
            let nudged = DownloadProgress.fraction(bytesWritten: 502, expectedBytes: 1000)

            manager.handleProgress(taskIdentifier: 1, guid: "guid-1", progress: half)
            #expect(manager.states["guid-1"] == .downloading(half))

            // inside the throttle interval: the attempt advances, the row does
            // not, and the report is deferred rather than dropped
            manager.handleProgress(taskIdentifier: 1, guid: "guid-1", progress: nudged)
            #expect(manager.states["guid-1"] == .downloading(half))
            #expect(manager.attempts["guid-1"]?.progress == nudged)

            // and a later report behind the unpublished one is still refused
            manager.handleProgress(
                taskIdentifier: 1, guid: "guid-1",
                progress: .fraction(bytesWritten: 501, expectedBytes: 1000))
            #expect(manager.attempts["guid-1"]?.progress == nudged)

            clock.advance(by: DownloadPacing.publishInterval)
            let stepped = DownloadProgress.fraction(bytesWritten: 510, expectedBytes: 1000)
            manager.handleProgress(taskIdentifier: 1, guid: "guid-1", progress: stepped)
            // ten bytes over the one second the clock was advanced by
            #expect(
                manager.states["guid-1"]
                    == .downloading(
                        .fraction(bytesWritten: 510, expectedBytes: 1000, bytesPerSecond: 10)))
        }
    }
}

private struct RecordedProgress: Equatable {
    let taskIdentifier: Int
    let guid: String
    let progress: DownloadProgress
}

private final class RecordedProgressEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [RecordedProgress] = []

    var values: [RecordedProgress] { lock.withLock { events } }

    func record(taskIdentifier: Int, guid: String, progress: DownloadProgress) {
        lock.withLock {
            events.append(RecordedProgress(taskIdentifier: taskIdentifier, guid: guid, progress: progress))
        }
    }
}

private final class OrderedHooks: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []

    var values: [String] { lock.withLock { events } }

    func record(_ event: String) {
        lock.withLock { events.append(event) }
    }
}
