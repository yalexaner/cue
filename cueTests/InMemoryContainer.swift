import Foundation
import SwiftData

@testable import cue

/// The feed address the suites subscribe to. Redacted on purpose: no real feed
/// URL enters the repository (`docs/SECRETS.md`).
let testFeedURL = "https://example.com/feed?token=REDACTED_TEST_TOKEN"

/// A fresh in-memory context, one per test.
///
/// Shared for the same reason as `fixtureData(named:withExtension:)` and
/// `FeedTransportStub`: the schema list is the part that changes, and a copy per
/// suite means a new `@Model` type has to be added in seven places — a missed
/// one silently runs that suite against a different store.
@MainActor
func makeContext() throws -> ModelContext {
    let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try ModelContainer(
        for: Podcast.self, Episode.self, PlaybackSession.self,
        configurations: configuration
    )
    return ModelContext(container)
}
