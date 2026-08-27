import Foundation

/// Everything the app is allowed to say about itself in the log.
///
/// The type is the redaction rule. No case takes a `URL`, a host `String`, a
/// guid `String` or an `Error` — only `DiagnosticsHost`, `DiagnosticsGUID`,
/// `DiagnosticsErrorCode`, `DiagnosticsAttemptID` and scalars, each of which can
/// only be built by sanitising (`DiagnosticsSafeFields.swift`). A call site
/// therefore *cannot* pass a pre-signed enclosure address or an error's
/// description into the file, whatever it happens to be holding (decision 2).
///
/// Categories are the two that already exist as `os_log` categories in the tree
/// — `downloads` and `storage` — rather than a parallel vocabulary, so a line in
/// the file and a line in the device log can be lined up by eye. Feed fetching
/// has no category of its own, so it borrows `downloads`: it is the other half
/// of the same network story a transfer belongs to.
/// Why a delivered outcome was thrown away instead of being recorded on an
/// episode.
///
/// A fixed vocabulary rather than free text, for the same reason every other
/// field here is a type: a reason a call site could spell itself is a reason
/// that could carry an address.
enum DiagnosticsDiscardReason: String, Sendable, Equatable {
    /// The guid resolves to no stored episode — unsubscribed or deleted while
    /// the transfer was in flight.
    case episodeMissing = "episode_missing"
    /// Another writer in this process already owns the guid, so there is
    /// nothing here to record the outcome on (`DownloadOwnership.swift`).
    case guidInFlight = "guid_in_flight"
}

enum DiagnosticsEvent: Sendable, Equatable {
    /// Once per process, so a relaunch is visible as a break in the file.
    case launch(build: String)

    case downloadRequested(guid: DiagnosticsGUID, host: DiagnosticsHost)
    case downloadQueued(guid: DiagnosticsGUID, attempt: DiagnosticsAttemptID, position: Int)
    case downloadStarted(guid: DiagnosticsGUID, attempt: DiagnosticsAttemptID, host: DiagnosticsHost)
    case downloadFirstByte(guid: DiagnosticsGUID, attempt: DiagnosticsAttemptID, bytes: Int64)
    case downloadDecile(guid: DiagnosticsGUID, attempt: DiagnosticsAttemptID, decile: Int, bytes: Int64)
    /// The user asked. Distinct from `downloadCancelled`, which is the outcome:
    /// an active transfer stays `.downloading` until the delegate delivers its
    /// sole terminal result, so request and outcome are two different moments
    /// and one event for both makes a single cancel indistinguishable from two
    /// — or from a request the session ignored because the transfer finished.
    case downloadCancelRequested(guid: DiagnosticsGUID, attempt: DiagnosticsAttemptID)
    case downloadCancelled(guid: DiagnosticsGUID, attempt: DiagnosticsAttemptID)
    case downloadFileMoved(guid: DiagnosticsGUID, attempt: DiagnosticsAttemptID)
    case downloadFinished(guid: DiagnosticsGUID, attempt: DiagnosticsAttemptID)
    case downloadFailed(guid: DiagnosticsGUID, attempt: DiagnosticsAttemptID, code: DiagnosticsErrorCode)
    case downloadHTTPStatus(guid: DiagnosticsGUID, host: DiagnosticsHost, status: Int)
    case downloadAdopted(guid: DiagnosticsGUID, attempt: DiagnosticsAttemptID, taskIdentifier: Int)
    case downloadDeleted(guid: DiagnosticsGUID)
    /// A request that ended before an attempt existed to name.
    ///
    /// Its own case rather than a `download.failed` with no attempt: an
    /// enclosure address that is not http is rejected before ownership is
    /// claimed, so there is no attempt to name, and a request followed by
    /// silence is precisely the ambiguity this log exists to remove. The other
    /// pre-transport exits — a cancelled queue wait, a container that could not
    /// be prepared — happen *after* the claim and so are recorded as
    /// `download.cancelled` and `download.failed`, which do carry the attempt.
    case downloadNotStarted(guid: DiagnosticsGUID, code: DiagnosticsErrorCode)

    /// A delivered outcome thrown away rather than recorded on an episode.
    ///
    /// Its own case rather than a `download.failed`: nothing failed — the file
    /// arrived intact and there was nowhere to put it. What matters is that the
    /// last line for the guid says so, because a transfer whose log stops after
    /// its deciles is exactly the "request followed by silence" ambiguity this
    /// file exists to remove. The attempt is optional because an orphan outcome
    /// can be discarded before ownership has been claimed, so there is not
    /// always one to name.
    case downloadDiscarded(
        guid: DiagnosticsGUID, attempt: DiagnosticsAttemptID?, reason: DiagnosticsDiscardReason)

    case feedFetchStarted(host: DiagnosticsHost)
    case feedFetchSucceeded(host: DiagnosticsHost, status: Int, elapsedMilliseconds: Int)
    case feedFetchFailed(host: DiagnosticsHost, code: DiagnosticsErrorCode, elapsedMilliseconds: Int)
    case feedHTTPStatus(host: DiagnosticsHost, status: Int, elapsedMilliseconds: Int)

    /// The name written to the `event=` column. Fixed literals, so a log can be
    /// grepped for one and the set is enumerable from this file alone.
    var name: String {
        switch self {
        case .launch: return "launch"
        case .downloadRequested: return "download.requested"
        case .downloadQueued: return "download.queued"
        case .downloadStarted: return "download.started"
        case .downloadFirstByte: return "download.first_byte"
        case .downloadDecile: return "download.decile"
        case .downloadCancelRequested: return "download.cancel_requested"
        case .downloadCancelled: return "download.cancelled"
        case .downloadFileMoved: return "download.file_moved"
        case .downloadFinished: return "download.finished"
        case .downloadFailed: return "download.failed"
        case .downloadHTTPStatus: return "download.http_status"
        case .downloadAdopted: return "download.adopted"
        case .downloadDeleted: return "download.deleted"
        case .downloadNotStarted: return "download.not_started"
        case .downloadDiscarded: return "download.discarded"
        case .feedFetchStarted: return "feed.fetch_started"
        case .feedFetchSucceeded: return "feed.fetch_succeeded"
        case .feedFetchFailed: return "feed.fetch_failed"
        case .feedHTTPStatus: return "feed.http_status"
        }
    }

    var record: DiagnosticsRecord {
        switch self {
        case .launch(let build):
            return DiagnosticsRecord(
                category: .storage, event: name, fields: [DiagnosticsField("build", safe: build)])
        case .downloadRequested(let guid, let host):
            return downloads(DiagnosticsField("guid", guid), DiagnosticsField("host", host))
        case .downloadQueued(let guid, let attempt, let position):
            return downloads(
                DiagnosticsField("guid", guid), DiagnosticsField("attempt", attempt),
                DiagnosticsField("position", position))
        case .downloadStarted(let guid, let attempt, let host):
            return downloads(
                DiagnosticsField("guid", guid), DiagnosticsField("attempt", attempt),
                DiagnosticsField("host", host))
        case .downloadFirstByte(let guid, let attempt, let bytes):
            return downloads(
                DiagnosticsField("guid", guid), DiagnosticsField("attempt", attempt),
                DiagnosticsField("bytes", bytes))
        case .downloadDecile(let guid, let attempt, let decile, let bytes):
            return downloads(
                DiagnosticsField("guid", guid), DiagnosticsField("attempt", attempt),
                DiagnosticsField("decile", decile), DiagnosticsField("bytes", bytes))
        case .downloadCancelRequested(let guid, let attempt), .downloadCancelled(let guid, let attempt),
            .downloadFileMoved(let guid, let attempt), .downloadFinished(let guid, let attempt):
            return downloads(DiagnosticsField("guid", guid), DiagnosticsField("attempt", attempt))
        case .downloadFailed(let guid, let attempt, let code):
            return downloads(
                level: .error, DiagnosticsField("guid", guid), DiagnosticsField("attempt", attempt),
                DiagnosticsField("domain", safe: code.domain), DiagnosticsField("code", code.code))
        case .downloadHTTPStatus(let guid, let host, let status):
            return downloads(
                level: .error, DiagnosticsField("guid", guid), DiagnosticsField("host", host),
                DiagnosticsField("status", status))
        case .downloadAdopted(let guid, let attempt, let taskIdentifier):
            return downloads(
                DiagnosticsField("guid", guid), DiagnosticsField("attempt", attempt),
                DiagnosticsField("task", taskIdentifier))
        case .downloadDeleted(let guid):
            return downloads(DiagnosticsField("guid", guid))
        case .downloadNotStarted(let guid, let code):
            return downloads(
                level: .error, DiagnosticsField("guid", guid),
                DiagnosticsField("domain", safe: code.domain), DiagnosticsField("code", code.code))
        case .downloadDiscarded(let guid, let attempt, let reason):
            var fields = [DiagnosticsField("guid", guid)]
            if let attempt { fields.append(DiagnosticsField("attempt", attempt)) }
            fields.append(DiagnosticsField("reason", safe: reason.rawValue))
            return DiagnosticsRecord(category: .downloads, event: name, fields: fields)
        case .feedFetchStarted(let host):
            return downloads(DiagnosticsField("host", host))
        case .feedFetchSucceeded(let host, let status, let elapsed):
            return downloads(
                DiagnosticsField("host", host), DiagnosticsField("status", status),
                DiagnosticsField("ms", elapsed))
        case .feedFetchFailed(let host, let code, let elapsed):
            return downloads(
                level: .error, DiagnosticsField("host", host),
                DiagnosticsField("domain", safe: code.domain), DiagnosticsField("code", code.code),
                DiagnosticsField("ms", elapsed))
        case .feedHTTPStatus(let host, let status, let elapsed):
            return downloads(
                level: .error, DiagnosticsField("host", host), DiagnosticsField("status", status),
                DiagnosticsField("ms", elapsed))
        }
    }

    /// Variadic rather than taking an array, so no call site above has to spell
    /// a multiline collection literal: `swift-format` wants a trailing comma on
    /// one and SwiftLint rejects it, so a literal that does not fit on a line
    /// cannot pass both (AGENTS.md).
    private func downloads(level: DiagnosticsLevel = .info, _ fields: DiagnosticsField...) -> DiagnosticsRecord {
        DiagnosticsRecord(level: level, category: .downloads, event: name, fields: fields)
    }
}
