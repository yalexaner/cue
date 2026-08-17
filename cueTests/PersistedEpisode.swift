import Foundation
import SwiftData

@testable import cue

/// The episode with this guid as the *store* has it, read through a second
/// `ModelContext` over the same container.
///
/// The context that did the writing cannot tell a committed store from pending
/// changes, so any assertion about a column having been saved has to come from
/// here. Shared rather than re-declared per suite, the same rule as the fixture
/// loader and the transport stubs: three download suites assert persistence and
/// a private copy in each is three places for the fetch to drift.
///
/// The inverse case still belongs on the primary context — a test about an
/// insert being *cancelled* is asserting on state only the writing context can
/// see.
@MainActor
func persistedEpisode(guid: String, in context: ModelContext) throws -> Episode? {
    let fresh = ModelContext(context.container)
    var descriptor = FetchDescriptor<Episode>(predicate: #Predicate { $0.guid == guid })
    descriptor.fetchLimit = 1
    return try fresh.fetch(descriptor).first
}
