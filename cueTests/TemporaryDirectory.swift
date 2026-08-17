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

/// Async counterpart, for tests whose body awaits (the download manager's).
///
/// Deliberately *not* an overload of `withTemporaryBase`: two functions of that
/// name taking only a closure are ambiguous at a trailing-closure call site,
/// which `swift-format --strict` rejects (`AmbiguousTrailingClosureOverload`).
/// The directory is still removed when `body` returns or throws, so no async
/// test can leak into the real Application Support.
///
/// The `isolation` parameter keeps `body` running in the caller's actor, so a
/// `@MainActor` suite can hand it a closure over `@Model` values without the
/// compiler treating them as sent across an isolation boundary.
func withTemporaryBaseAsync(
    isolation: isolated (any Actor)? = #isolation,
    _ body: (URL) async throws -> Void
) async throws {
    let base = URL.temporaryDirectory.appending(
        path: "cue-tests-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    try await body(base)
}
