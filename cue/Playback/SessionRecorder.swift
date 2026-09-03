import Foundation
import OSLog
import SwiftData

/// Turns the engine's `SessionEvent` stream into `PlaybackSession` rows (spec §9).
///
/// A cheap `@MainActor` struct constructed at the call site, the `EpisodeStore`
/// and `FeedService` precedent — deliberately *not* a third long-lived service.
/// It holds a `ModelContext` and no other state: the live session is re-found by
/// fetching `endedAt == nil` at every write, which is what makes "never more
/// than one live session" enforceable rather than assumed from call ordering.
///
/// No operation throws into playback. A session-log write that fails is logged
/// and swallowed — audio keeps playing — because a history row is worth less
/// than the listening it describes.
@MainActor
struct SessionRecorder {
    static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "dev.yachmenev.cue",
        category: "playback"
    )

    let context: ModelContext
    /// Test-only stand-in for the store fetch in `episode(forGUID:)`, the
    /// `DownloadManager.episodeLookup` precedent: a `ModelContext` cannot be
    /// made to throw on demand, and the failed-lookup branch has to be
    /// exercised. `nil` in production. Declared first so an unlabelled trailing
    /// closure keeps binding to it rather than to `liveSessionLookup`.
    let episodeLookup: ((String) throws -> Episode?)?
    /// Test-only stand-in for the store fetch in `liveSession()`, the same
    /// reason `episodeLookup` exists. `nil` in production.
    let liveSessionLookup: (() throws -> PlaybackSession?)?

    init(
        context: ModelContext,
        episodeLookup: ((String) throws -> Episode?)? = nil,
        liveSessionLookup: (() throws -> PlaybackSession?)? = nil
    ) {
        self.context = context
        self.episodeLookup = episodeLookup
        self.liveSessionLookup = liveSessionLookup
    }

    /// The single entry point the engine's `sessionEvents` seam is wired to.
    func handle(_ event: SessionEvent) {
        switch event {
        case .started(let guid, let position, let rate):
            open(guid: guid, at: position, rate: rate)
        case .stopped(let position):
            close(at: position)
        case .seeked(let from, let target):
            guard let live = liveSessionForWrite("session seek boundary") else { return }
            let guid = live.episode?.guid
            let rate = live.rate
            closeSession(live, at: from)
            if let guid {
                open(guid: guid, at: target, rate: rate)
            } else {
                Self.reportUnlinkedBoundary()
            }
        case .rateChanged(let position, let newRate):
            guard let live = liveSessionForWrite("session rate boundary") else { return }
            let guid = live.episode?.guid
            closeSession(live, at: position)
            if let guid {
                open(guid: guid, at: position, rate: newRate)
            } else {
                Self.reportUnlinkedBoundary()
            }
        case .heartbeat(let position):
            heartbeat(at: position)
        case .correctedPosition(let guid, let position, let rate):
            appendCorrection(guid: guid, at: position, rate: rate)
        }
    }

    /// A boundary closed a live session that carried no episode, so nothing
    /// reopens and every later heartbeat and stop is a silent no-op. That is
    /// the one give-up path with no row to show for it, so it says so — the
    /// same reason the failed-lookup and unknown-guid paths log.
    private static func reportUnlinkedBoundary() {
        logger.error("live session has no episode; session recording stops here")
    }

    // MARK: - Writes

    /// Opens a session for `guid` at `position`.
    ///
    /// A lingering live session is closed first (decision 13): finding one here
    /// is a bug, not a plan, and the invariant is enforced at the write rather
    /// than trusted to the caller. A failed save deletes the row this call
    /// inserted — `add`'s `allEpisodesOwnedElsewhere` precedent, not a
    /// context-wide `rollback()`, which would drop edits the recorder never made.
    ///
    /// The lingering probe is the one place a failed fetch may not be read as
    /// "nothing is live": inserting on an answer that only means *cannot tell*
    /// is how a second `endedAt == nil` row is minted, and with two of them the
    /// unordered `fetchLimit = 1` lookup sends later heartbeats to an arbitrary
    /// one while `Episode.currentPosition` reads the other. A missed open costs
    /// one session; a duplicate live row costs the resume position.
    private func open(guid: String, at position: TimeInterval, rate: Double) {
        let lingering: PlaybackSession?
        do {
            lingering = try liveSession()
        } catch {
            Self.logger.error("session open could not check for a live session; recording nothing")
            return
        }
        if let lingering {
            closeSession(lingering, at: lingering.endPosition)
        }

        let found: Episode?
        do {
            found = try episode(forGUID: guid)
        } catch {
            Self.logger.error("session open could not resolve its episode")
            return
        }
        guard let episode = found else {
            Self.logger.notice("session open for an unknown guid; recording nothing")
            return
        }

        let session = PlaybackSession(
            startedAt: .now, startPosition: position, endPosition: position, rate: rate
        )
        session.episode = episode
        context.insert(session)
        do {
            try context.save()
        } catch {
            Self.logger.error("session open failed to save")
            context.delete(session)
            // The discard is committed at the moment it is decided: left
            // pending on `mainContext` it sits in reach of `FeedService`'s
            // context-wide `rollback()` and of whichever unrelated writer saves
            // next, which is the same reason every other write here saves.
            save("session open discard")
        }
    }

    /// Appends an already-closed, zero-length session at `position`.
    ///
    /// A refused seek can invalidate the `endPosition` of a session that is
    /// already closed, and the log is append-only, so the correction is a later
    /// row rather than an edit: `Episode.currentPosition` reads the latest one,
    /// and this one names where the player really is. It opens and closes at
    /// the same position because nothing was played. Unlike `open(guid:at:rate:)`
    /// it needs no lingering-session probe — the row it writes is closed, so it
    /// cannot mint a second `endedAt == nil` row whatever else is live.
    private func appendCorrection(guid: String, at position: TimeInterval, rate: Double) {
        let found: Episode?
        do {
            found = try episode(forGUID: guid)
        } catch {
            Self.logger.error("session correction could not resolve its episode")
            return
        }
        guard let episode = found else {
            Self.logger.notice("session correction for an unknown guid; recording nothing")
            return
        }

        let now = Date.now
        let session = PlaybackSession(
            startedAt: now, startPosition: position, endPosition: position, rate: rate
        )
        session.endedAt = now
        session.episode = episode
        context.insert(session)
        do {
            try context.save()
        } catch {
            Self.logger.error("session correction failed to save")
            context.delete(session)
            save("session correction discard")
        }
    }

    /// Closes the live session at `position`. No live session is a no-op — a
    /// stop while nothing is open is the ordinary paused case, not an error.
    private func close(at position: TimeInterval) {
        guard let live = liveSessionForWrite("session close") else { return }
        closeSession(live, at: position)
    }

    private func closeSession(_ session: PlaybackSession, at position: TimeInterval) {
        advance(session, to: position)
        session.endedAt = .now
        save("session close")
    }

    /// A row may never end before it begins, so both writes funnel through here.
    ///
    /// The engine reports a landed seek at the position it *requested*, and
    /// `AVPlayer` is free to land at a nearby sample instead. A session opened
    /// by that boundary therefore starts a fraction ahead of where the player
    /// really is, and the next observed sample would write an `endPosition`
    /// behind its own `startPosition` — the inverted row the whole
    /// pre-completion window exists to keep out of an append-only log.
    private func advance(_ session: PlaybackSession, to position: TimeInterval) {
        session.endPosition = max(session.startPosition, position)
    }

    /// Advances the live session's `endPosition` without closing it — this is
    /// what bounds a force-quit's lost progress to one heartbeat interval, and
    /// what `Episode.currentPosition` reads while playback is still running.
    private func heartbeat(at position: TimeInterval) {
        guard let live = liveSessionForWrite("session heartbeat") else { return }
        advance(live, to: position)
        save("session heartbeat")
    }

    /// Every write saves explicitly: AC 12's 10-second bound cannot lean on
    /// autosave timing, and pending writes on `mainContext` sit in reach of
    /// `FeedService`'s context-wide `rollback()`.
    private func save(_ what: String) {
        do {
            try context.save()
        } catch {
            Self.logger.error("\(what, privacy: .public) failed to save")
        }
    }

    // MARK: - Lookups

    /// The one session with `endedAt == nil`, if any. Throws rather than
    /// answering `nil` on a store failure — `Episode.isDownloaded(in:)`'s rule:
    /// "cannot tell" is not "there is none", and the two answers lead the open
    /// path to opposite decisions.
    private func liveSession() throws -> PlaybackSession? {
        if let liveSessionLookup { return try liveSessionLookup() }
        var descriptor = FetchDescriptor<PlaybackSession>(predicate: #Predicate { $0.endedAt == nil })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    /// The live session for a write that can safely do nothing. A close, a
    /// heartbeat and a boundary all need a row to write to, so a failed fetch
    /// and an absent session end the same way — but it is logged, because one
    /// of them means progress was lost rather than never made.
    private func liveSessionForWrite(_ what: String) -> PlaybackSession? {
        do {
            return try liveSession()
        } catch {
            Self.logger.error("\(what, privacy: .public) could not fetch the live session")
            return nil
        }
    }

    /// The episode with this guid — the store's uniqueness scope.
    private func episode(forGUID guid: String) throws -> Episode? {
        if let episodeLookup { return try episodeLookup(guid) }
        var descriptor = FetchDescriptor<Episode>(predicate: #Predicate { $0.guid == guid })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    // MARK: - Launch sweep

    /// Closes every session left live by a termination (spec §9, AC 12).
    ///
    /// `endedAt` is derived rather than stored: the schema has no modification
    /// timestamp, so `startedAt + (endPosition - startPosition) / rate` is the
    /// best wall-clock estimate the recorded fields support. Plural and
    /// unconditional on purpose — more than one live row should be impossible,
    /// and a sweep that closed only the first would leave the rest forever.
    func closeAbandonedSessions() {
        let descriptor = FetchDescriptor<PlaybackSession>(predicate: #Predicate { $0.endedAt == nil })
        let live: [PlaybackSession]
        do {
            live = try context.fetch(descriptor)
        } catch {
            Self.logger.error("launch sweep could not fetch live sessions")
            return
        }
        guard !live.isEmpty else { return }
        for session in live {
            session.endedAt = session.startedAt.addingTimeInterval(Self.playedDuration(of: session))
        }
        save("launch sweep")
    }

    /// Wall-clock seconds a session accounts for, from its recorded fields.
    /// A non-positive rate would divide into infinity or flip the sign, so it
    /// contributes nothing rather than an `endedAt` before `startedAt`.
    static func playedDuration(of session: PlaybackSession) -> TimeInterval {
        guard session.rate > 0 else { return 0 }
        return max(0, (session.endPosition - session.startPosition) / session.rate)
    }
}
