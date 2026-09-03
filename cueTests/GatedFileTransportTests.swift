import Foundation
import Testing

@testable import cue

/// The gate itself must not lose a cancellation that lands before registration.
struct GatedFileTransportTests {
    /// A task cancelled before it reaches the gate throws instead of parking.
    ///
    /// The never-yielding stream ends its iteration only through cancellation, so the
    /// transport is always entered with the task already cancelled — deterministically
    /// exercising the cancel-before-registration order that `cancel(id:)` cannot see.
    @Test func aTaskCancelledBeforeEnteringTheGateThrowsWithoutOpen() async throws {
        try await withTemporaryBaseAsync { base in
            let gate = GatedFileTransport(stagingDirectory: base)
            let url = try #require(URL(string: "https://example.com/enclosure.mp3"))
            let idle = AsyncStream<Void> { _ in }
            let task = Task {
                for await _ in idle {}
                return try await gate.transport(url)
            }
            task.cancel()
            await #expect(throws: CancellationError.self) { _ = try await task.value }
            #expect(gate.callCount == 1)
        }
    }

    /// `openParked()` releases the current waiters and shuts again behind them.
    ///
    /// This is what a test asserting a transient phase leans on: the transfer
    /// that takes the slot next must park rather than run to completion.
    @Test func openParkedReleasesOnlyTheCallsAlreadyWaiting() async throws {
        try await withTemporaryBaseAsync { base in
            let gate = GatedFileTransport(stagingDirectory: base)
            let url = try #require(URL(string: "https://example.com/enclosure.mp3"))
            let first = Task { try await gate.transport(url) }
            await yieldUntil { gate.callCount == 1 }

            gate.openParked()
            _ = try await first.value

            let second = Task { try await gate.transport(url) }
            await yieldUntil { gate.callCount == 2 }
            // the gate shut again, so this one is still parked: had it run
            // through, the task would already hold a value and the cancel
            // below would be a no-op
            second.cancel()
            await #expect(throws: CancellationError.self) { _ = try await second.value }
        }
    }
}
