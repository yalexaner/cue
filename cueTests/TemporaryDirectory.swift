import Foundation

/// Runs `body` against a fresh temporary base directory, removed when it returns.
///
/// Shared by every test that constructs an `EpisodeStore`, so no test can touch
/// the real Application Support directory.
func withTemporaryBase(_ body: (URL) throws -> Void) throws {
    let base = URL.temporaryDirectory.appending(
        path: "cue-tests-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    try body(base)
}
