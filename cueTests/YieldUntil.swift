import Foundation

/// Yields until `condition` holds, bounded so a regression fails the assertion
/// that follows instead of hanging the suite.
///
/// A bare `await Task.yield()` is not a synchronisation primitive. It lets an
/// already-enqueued child task run on a quiet machine and does not reliably do
/// so on a loaded runner, which is precisely the difference between a suite that
/// is green locally and one that is red in CI. Wait for the state the test is
/// actually about instead of for a scheduler turn.
@MainActor
func yieldUntil(_ condition: () -> Bool) async {
    var spins = 0
    while !condition(), spins < 1_000 {
        await Task.yield()
        spins += 1
    }
}
