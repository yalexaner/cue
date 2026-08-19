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
}
