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

/// Releases the clock's parked sleepers until `condition` holds, or gives up.
///
/// Arming a deadline or a trailing publication creates a `Task` that has not
/// necessarily reached its `sleep` by the time the test calls `wake()`, and a
/// `wake()` that arrives first releases nothing — the sleeper then parks for
/// good and the test hangs on a scheduler turn that never comes. Retrying is
/// what makes a *firing* test deterministic. Waking an empty set is a no-op, and
/// a sleeper woken before its own guard is satisfied simply returns without
/// writing.
@MainActor
func wake(_ clock: ManualDownloadClock, until condition: () -> Bool) async {
    await yieldUntil {
        clock.wake()
        return condition()
    }
}
