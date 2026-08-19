import Foundation
import SwiftData
import Testing

@testable import cue

/// Cancellation is scoped to the attempt that asked, not to its guid.
///
/// The session enumeration suspends, so a request that named only the guid
/// would resolve against a snapshot taken after that attempt retired — and a
/// retry's task carries the same guid. These tests pin the matching seam and
/// the two windows where an attempt has no task identifier to name yet.
@MainActor
struct DownloadManagerCancellationScopeTests {
    private func makeEpisodes(in context: ModelContext, guids: [String]) throws -> [Episode] {
        let podcast = Podcast(feedURL: testFeedURL, title: "Show")
        context.insert(podcast)
        let episodes = guids.map { guid in
            let episode = Episode(
                guid: guid, title: "Episode \(guid)",
                enclosureURL: "https://example.com/\(guid).mp3")
            episode.podcast = podcast
            context.insert(episode)
            return episode
        }
        try context.save()
        return episodes
    }

    @Test func backgroundPolicyAndGUIDMappingAreExplicit() {
        #expect(BackgroundDownloader.resourceTimeout == 2 * 60 * 60)
        let first = DownloadAttemptIdentity(taskIdentifier: 1, guid: "guid-1")
        let second = DownloadAttemptIdentity(taskIdentifier: 2, guid: "guid-2")
        let third = DownloadAttemptIdentity(taskIdentifier: 3, guid: "guid-1")
        let identities = [first, second, third]

        // A cancel names its attempt's task and reaches that task only: task 3
        // is a retry for the same guid, and cancelling it is the bug.
        #expect(
            BackgroundDownloader.taskIdentifiers(
                forGUID: "guid-1", taskIdentifier: 1, among: identities) == [1])
        #expect(
            BackgroundDownloader.taskIdentifiers(
                forGUID: "guid-1", taskIdentifier: 3, among: identities) == [3])
        // The guid still has to agree — identifiers are unique per session only.
        #expect(
            BackgroundDownloader.taskIdentifiers(
                forGUID: "guid-2", taskIdentifier: 1, among: identities
            ).isEmpty)
        #expect(
            BackgroundDownloader.taskIdentifiers(
                forGUID: "missing", taskIdentifier: 1, among: identities
            ).isEmpty)
    }

    /// The session enumeration is slow, and a retry starts while it runs.
    ///
    /// `cancel` suspends on the request, so the attempt it cancelled can deliver
    /// its outcome, retire and be replaced by a retry for the same guid before
    /// the session ever answers. The request therefore has to carry the
    /// identifier of the task that asked: matching on the guid alone would find
    /// the retry's task in that snapshot and cancel the transfer the user just
    /// started.
    @Test func aDelayedCancellationEnumerationCannotReachTheRetry() async throws {
        try await withTemporaryBaseAsync { base in
            let context = try makeContext()
            let episode = try #require(makeEpisodes(in: context, guids: ["guid-1"]).first)
            let gate = GatedFileTransport(stagingDirectory: base)
            let requests = ParkedCancellationRequest()
            let manager = DownloadManager(
                context: context, store: EpisodeStore(baseDirectory: base), transport: gate.transport,
                cancellationRequest: requests.request)

            let cancelled = Task { try await manager.download(episode) }
            await yieldUntil { gate.callCount == 1 }
            manager.registerAttempt(taskIdentifier: 11, forGUID: episode.guid)

            let cancelling = Task { await manager.cancel(episode) }
            await yieldUntil { requests.identifiers.count == 1 }

            // still enumerating: the cancelled attempt answers, retires, and the
            // user taps Download again
            gate.open()
            await #expect(throws: CancellationError.self) { try await cancelled.value }
            #expect(manager.state(for: episode) == nil)

            let retry = Task { try await manager.download(episode) }
            await yieldUntil { manager.attempts[episode.guid] != nil }
            manager.registerAttempt(taskIdentifier: 12, forGUID: episode.guid)
            try await retry.value

            requests.release()
            await cancelling.value

            #expect(requests.guids == [episode.guid])
            #expect(requests.identifiers == [11])
            #expect(episode.localFilename != nil)
            let persisted = try #require(try persistedEpisode(guid: episode.guid, in: context))
            #expect(persisted.localFilename != nil)
            #expect(manager.state(for: episode) == nil)
            #expect(manager.attempts[episode.guid] == nil)
        }
    }

    /// A cancel that lands before the session task registers is not lost.
    ///
    /// The task is created off the main actor and its registration hops back to
    /// it, so a cancel in that window has no identifier to name. Falling back to
    /// the guid is what the test above forbids, so the request is made from
    /// registration instead — with the identifier known, and still before the
    /// task is resumed.
    @Test func aCancelBeforeRegistrationIsReissuedWhenTheTaskRegisters() async throws {
        try await withTemporaryBaseAsync { base in
            let context = try makeContext()
            let episode = try #require(makeEpisodes(in: context, guids: ["guid-1"]).first)
            let gate = GatedFileTransport(stagingDirectory: base)
            let requests = CancellationRecorder()
            let manager = DownloadManager(
                context: context, store: EpisodeStore(baseDirectory: base), transport: gate.transport,
                cancellationRequest: requests.request)

            let download = Task { try await manager.download(episode) }
            await yieldUntil { gate.callCount == 1 }

            // the session task exists, but its registration has not landed
            await manager.cancel(episode)
            #expect(requests.guids.isEmpty)

            await manager.registerStartedAttempt(taskIdentifier: 21, forGUID: episode.guid)
            #expect(requests.guids == [episode.guid])
            #expect(requests.identifiers == [21])

            gate.open()
            await #expect(throws: CancellationError.self) { try await download.value }
            #expect(episode.localFilename == nil)
            #expect(manager.state(for: episode) == nil)
            #expect(manager.attempts[episode.guid] == nil)
        }
    }

    /// Registering a task for an attempt nobody cancelled asks for nothing.
    @Test func registeringAnUncancelledAttemptRequestsNoCancellation() async throws {
        try await withTemporaryBaseAsync { base in
            let context = try makeContext()
            let episode = try #require(makeEpisodes(in: context, guids: ["guid-1"]).first)
            let gate = GatedFileTransport(stagingDirectory: base)
            let requests = CancellationRecorder()
            let manager = DownloadManager(
                context: context, store: EpisodeStore(baseDirectory: base), transport: gate.transport,
                cancellationRequest: requests.request)

            let download = Task { try await manager.download(episode) }
            await yieldUntil { gate.callCount == 1 }
            await manager.registerStartedAttempt(taskIdentifier: 31, forGUID: episode.guid)

            gate.open()
            try await download.value
            #expect(requests.guids.isEmpty)
            #expect(episode.localFilename != nil)
            let persisted = try #require(try persistedEpisode(guid: episode.guid, in: context))
            #expect(persisted.localFilename != nil)
        }
    }
}
