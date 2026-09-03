import Foundation
import SwiftData
import Testing

@testable import cue

@MainActor
struct SessionRecorderTests {
    // MARK: - Helpers

    private func makeEpisode(in context: ModelContext, guid: String = "guid-1") throws -> Episode {
        let episode = Episode(guid: guid, title: "Episode", enclosureURL: "https://example.com/1.mp3")
        context.insert(episode)
        try context.save()
        return episode
    }

    /// `startedAt` alone is not a total order: a close and its reopen are two
    /// `.now` reads apart, so the tie is broken on `endPosition` the way
    /// `Episode.currentPosition` breaks it rather than left to the fetch.
    private var sessionOrder: [SortDescriptor<PlaybackSession>] {
        [SortDescriptor(\.startedAt), SortDescriptor(\.endPosition)]
    }

    /// Sessions as the *store* has them, read through a second context.
    private func persistedSessions(in context: ModelContext) throws -> [PlaybackSession] {
        let fresh = ModelContext(context.container)
        return try fresh.fetch(FetchDescriptor<PlaybackSession>(sortBy: sessionOrder))
    }

    private func sessions(in context: ModelContext) throws -> [PlaybackSession] {
        try context.fetch(FetchDescriptor<PlaybackSession>(sortBy: sessionOrder))
    }

    // MARK: - Open

    @Test
    func startedOpensALiveSessionLinkedToTheEpisode() throws {
        let context = try makeContext()
        _ = try makeEpisode(in: context)
        let recorder = SessionRecorder(context: context)

        recorder.handle(.started(guid: "guid-1", position: 12, rate: 1.5))

        let rows = try persistedSessions(in: context)
        #expect(rows.count == 1)
        #expect(rows.first?.startPosition == 12)
        #expect(rows.first?.endPosition == 12)
        #expect(rows.first?.rate == 1.5)
        #expect(rows.first?.endedAt == nil)
        #expect(rows.first?.episode?.guid == "guid-1")
    }

    @Test
    func startedForAnUnknownGUIDRecordsNothing() throws {
        let context = try makeContext()
        let recorder = SessionRecorder(context: context)

        recorder.handle(.started(guid: "missing", position: 3, rate: 1))

        #expect(try sessions(in: context).isEmpty)
    }

    @Test
    func aFailingEpisodeLookupRecordsNothingAndDoesNotThrow() throws {
        let context = try makeContext()
        _ = try makeEpisode(in: context)
        let recorder = SessionRecorder(context: context) { _ in
            throw StubTransportError.offline
        }

        recorder.handle(.started(guid: "guid-1", position: 3, rate: 1))

        #expect(try sessions(in: context).isEmpty)
    }

    /// A store failure means *cannot tell whether one is live*, and inserting
    /// on that answer is how a second `endedAt == nil` row is minted — which
    /// the unordered live lookup then resolves arbitrarily.
    @Test
    func anUndeterminedLiveSessionOpensNothingRatherThanADuplicate() throws {
        let context = try makeContext()
        _ = try makeEpisode(in: context)
        let recorder = SessionRecorder(context: context, liveSessionLookup: { throw StubTransportError.offline })

        recorder.handle(.started(guid: "guid-1", position: 3, rate: 1))

        #expect(try sessions(in: context).isEmpty)
    }

    @Test
    func anUndeterminedLiveSessionLeavesAnOpenSessionUntouched() throws {
        let context = try makeContext()
        _ = try makeEpisode(in: context)
        SessionRecorder(context: context).handle(.started(guid: "guid-1", position: 3, rate: 1))
        let blocked = SessionRecorder(context: context, liveSessionLookup: { throw StubTransportError.offline })

        blocked.handle(.heartbeat(position: 40))
        blocked.handle(.seeked(from: 40, target: 80))
        blocked.handle(.stopped(position: 90))

        let recorded = try #require(try sessions(in: context).first)
        #expect(try sessions(in: context).count == 1)
        #expect(recorded.endPosition == 3)
        #expect(recorded.endedAt == nil)
    }

    @Test
    func aSecondOpenClosesTheLingeringSessionFirst() throws {
        let context = try makeContext()
        _ = try makeEpisode(in: context)
        let recorder = SessionRecorder(context: context)

        recorder.handle(.started(guid: "guid-1", position: 0, rate: 1))
        recorder.handle(.heartbeat(position: 40))
        recorder.handle(.started(guid: "guid-1", position: 100, rate: 1))

        let rows = try persistedSessions(in: context)
        #expect(rows.count == 2)
        // the lingering row is closed with the heartbeat data it already had
        #expect(rows.first?.endPosition == 40)
        #expect(rows.first?.endedAt != nil)
        #expect(rows.last?.startPosition == 100)
        #expect(rows.last?.endedAt == nil)
        #expect(rows.filter { $0.endedAt == nil }.count == 1)
    }

    @Test
    func switchingEpisodesClosesTheFirstRowAndLinksTheSecondToItsOwnEpisode() throws {
        let context = try makeContext()
        let first = try makeEpisode(in: context, guid: "guid-1")
        let second = try makeEpisode(in: context, guid: "guid-2")
        let recorder = SessionRecorder(context: context)

        recorder.handle(.started(guid: "guid-1", position: 0, rate: 1))
        recorder.handle(.heartbeat(position: 40))
        recorder.handle(.stopped(position: 55))
        recorder.handle(.started(guid: "guid-2", position: 5, rate: 2))

        let rows = try persistedSessions(in: context)
        #expect(rows.count == 2)
        // each row belongs to the episode it was opened for — `liveSession()`
        // is store-wide, so a recorder that reused the first lookup would
        // report one show's position for the other
        #expect(rows.first?.episode?.guid == "guid-1")
        #expect(rows.first?.endPosition == 55)
        #expect(rows.last?.episode?.guid == "guid-2")
        #expect(rows.last?.startPosition == 5)
        #expect(rows.filter { $0.endedAt == nil }.count == 1)
        #expect(first.currentPosition == 55)
        #expect(second.currentPosition == 5)
    }

    // MARK: - Close

    @Test
    func stoppedClosesTheLiveSessionAtThePosition() throws {
        let context = try makeContext()
        _ = try makeEpisode(in: context)
        let recorder = SessionRecorder(context: context)

        recorder.handle(.started(guid: "guid-1", position: 5, rate: 1))
        recorder.handle(.stopped(position: 65))

        let rows = try persistedSessions(in: context)
        #expect(rows.count == 1)
        #expect(rows.first?.startPosition == 5)
        #expect(rows.first?.endPosition == 65)
        #expect(rows.first?.endedAt != nil)
    }

    @Test
    func stoppedWithNoLiveSessionIsANoOp() throws {
        let context = try makeContext()
        _ = try makeEpisode(in: context)
        let recorder = SessionRecorder(context: context)

        recorder.handle(.stopped(position: 20))
        #expect(try sessions(in: context).isEmpty)

        recorder.handle(.started(guid: "guid-1", position: 0, rate: 1))
        recorder.handle(.stopped(position: 30))
        recorder.handle(.stopped(position: 999))

        let rows = try persistedSessions(in: context)
        #expect(rows.count == 1)
        #expect(rows.first?.endPosition == 30)
    }

    // MARK: - Heartbeat

    @Test
    func heartbeatAdvancesEndPositionWithoutClosing() throws {
        let context = try makeContext()
        _ = try makeEpisode(in: context)
        let recorder = SessionRecorder(context: context)

        recorder.handle(.started(guid: "guid-1", position: 0, rate: 1))
        recorder.handle(.heartbeat(position: 10))
        recorder.handle(.heartbeat(position: 20))

        let rows = try persistedSessions(in: context)
        #expect(rows.count == 1)
        #expect(rows.first?.endPosition == 20)
        #expect(rows.first?.endedAt == nil)
    }

    @Test
    func heartbeatWithNoLiveSessionIsANoOp() throws {
        let context = try makeContext()
        _ = try makeEpisode(in: context)
        let recorder = SessionRecorder(context: context)

        recorder.handle(.heartbeat(position: 10))

        #expect(try sessions(in: context).isEmpty)
    }

    // MARK: - Seek

    @Test
    func seekedClosesAtTheOriginAndReopensAtTheTarget() throws {
        let context = try makeContext()
        _ = try makeEpisode(in: context)
        let recorder = SessionRecorder(context: context)

        recorder.handle(.started(guid: "guid-1", position: 0, rate: 1.25))
        recorder.handle(.seeked(from: 30, target: 300))

        let rows = try persistedSessions(in: context)
        #expect(rows.count == 2)
        #expect(rows.first?.endPosition == 30)
        #expect(rows.first?.endedAt != nil)
        #expect(rows.last?.startPosition == 300)
        #expect(rows.last?.endPosition == 300)
        // the new session inherits the rate the closed one was playing at
        #expect(rows.last?.rate == 1.25)
        #expect(rows.last?.endedAt == nil)
    }

    @Test
    func seekedWithNoLiveSessionIsANoOp() throws {
        let context = try makeContext()
        _ = try makeEpisode(in: context)
        let recorder = SessionRecorder(context: context)

        recorder.handle(.seeked(from: 10, target: 200))

        #expect(try sessions(in: context).isEmpty)
    }

    // MARK: - Rate change

    @Test
    func rateChangedClosesAndReopensAtTheSamePosition() throws {
        let context = try makeContext()
        _ = try makeEpisode(in: context)
        let recorder = SessionRecorder(context: context)

        recorder.handle(.started(guid: "guid-1", position: 0, rate: 1))
        recorder.handle(.rateChanged(position: 90, newRate: 2))

        let rows = try persistedSessions(in: context)
        #expect(rows.count == 2)
        #expect(rows.first?.endPosition == 90)
        #expect(rows.first?.rate == 1)
        #expect(rows.first?.endedAt != nil)
        #expect(rows.last?.startPosition == 90)
        #expect(rows.last?.rate == 2)
        #expect(rows.last?.endedAt == nil)
    }

    @Test
    func rateChangedWithNoLiveSessionIsANoOp() throws {
        let context = try makeContext()
        _ = try makeEpisode(in: context)
        let recorder = SessionRecorder(context: context)

        recorder.handle(.rateChanged(position: 10, newRate: 2))

        #expect(try sessions(in: context).isEmpty)
    }

    // MARK: - Launch sweep

    @Test
    func theSweepClosesEveryLiveSessionWithTheDerivedEnd() throws {
        let context = try makeContext()
        let episode = try makeEpisode(in: context)
        let start = Date(timeIntervalSince1970: 1_000_000)

        let first = PlaybackSession(startedAt: start, startPosition: 0, endPosition: 120, rate: 1)
        first.episode = episode
        context.insert(first)
        let second = PlaybackSession(startedAt: start, startPosition: 100, endPosition: 400, rate: 2)
        second.episode = episode
        context.insert(second)
        try context.save()

        SessionRecorder(context: context).closeAbandonedSessions()

        let rows = try persistedSessions(in: context)
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.endedAt != nil })
        let ends = rows.map { $0.endedAt?.timeIntervalSince(start) }
        #expect(ends.contains(120))
        #expect(ends.contains(150))
    }

    @Test
    func theSweepLeavesClosedSessionsAlone() throws {
        let context = try makeContext()
        let episode = try makeEpisode(in: context)
        let start = Date(timeIntervalSince1970: 1_000_000)
        let closedAt = start.addingTimeInterval(42)

        let session = PlaybackSession(startedAt: start, startPosition: 0, endPosition: 500, rate: 1)
        session.episode = episode
        session.endedAt = closedAt
        context.insert(session)
        try context.save()

        SessionRecorder(context: context).closeAbandonedSessions()

        let rows = try persistedSessions(in: context)
        #expect(rows.count == 1)
        #expect(rows.first?.endedAt == closedAt)
        #expect(rows.first?.endPosition == 500)
    }

    // MARK: - Correction

    @Test
    func aCorrectionAppendsAClosedZeroLengthSessionAtThePlayhead() throws {
        let context = try makeContext()
        _ = try makeEpisode(in: context)
        let recorder = SessionRecorder(context: context)
        recorder.handle(.started(guid: "guid-1", position: 70, rate: 1))
        recorder.handle(.stopped(position: 70))

        recorder.handle(.correctedPosition(guid: "guid-1", position: 10, rate: 1))

        let rows = try persistedSessions(in: context)
        #expect(rows.count == 2)
        #expect(rows.last?.startPosition == 10)
        #expect(rows.last?.endPosition == 10)
        #expect(rows.last?.endedAt != nil)
        #expect(rows.last?.episode?.guid == "guid-1")
        // the superseded row stays: the log is append-only
        #expect(rows.first?.endPosition == 70)
    }

    @Test
    func aCorrectionLeavesALiveSessionOpen() throws {
        let context = try makeContext()
        _ = try makeEpisode(in: context)
        let recorder = SessionRecorder(context: context)
        recorder.handle(.started(guid: "guid-1", position: 70, rate: 1))

        recorder.handle(.correctedPosition(guid: "guid-1", position: 10, rate: 1))

        let rows = try persistedSessions(in: context)
        #expect(rows.count == 2)
        #expect(rows.filter { $0.endedAt == nil }.count == 1)
    }

    @Test
    func aCorrectionForAnUnknownGUIDRecordsNothing() throws {
        let context = try makeContext()
        let recorder = SessionRecorder(context: context)

        recorder.handle(.correctedPosition(guid: "missing", position: 10, rate: 1))

        #expect(try sessions(in: context).isEmpty)
    }

    @Test
    func theSweepIsSafeOnAnEmptyStore() throws {
        let context = try makeContext()

        SessionRecorder(context: context).closeAbandonedSessions()

        #expect(try sessions(in: context).isEmpty)
    }

    @Test
    func aSessionThatRewoundOrHasNoRateContributesNoNegativeDuration() throws {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let rewound = PlaybackSession(startedAt: start, startPosition: 300, endPosition: 100, rate: 1)
        #expect(SessionRecorder.playedDuration(of: rewound) == 0)

        let zeroRate = PlaybackSession(startedAt: start, startPosition: 0, endPosition: 100, rate: 0)
        #expect(SessionRecorder.playedDuration(of: zeroRate) == 0)
    }
}
