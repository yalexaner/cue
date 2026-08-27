import Foundation

/// One transfer shown above the completed downloads list.
struct ActiveDownload: Identifiable {
    let episode: Episode
    let state: DownloadManager.DownloadState

    var id: String { episode.guid }

    /// The shared row policy, asked with no filename on purpose.
    ///
    /// This section is the transfer's own view of itself (AGENTS.md: it derives
    /// directly from the in-memory transfer states), so a failed retry over an
    /// episode that still has its previous file belongs here with Retry — while
    /// the completed list below goes on offering Delete for the file that is
    /// genuinely still there. Routed through the one policy function rather
    /// than restating it, so a new `DownloadState` case cannot be answered two
    /// ways by one screen.
    var rowState: EpisodeDownloadState {
        episodeDownloadState(localFilename: nil, transfer: state)
    }
}

/// The in-flight and failed transfers the Downloads tab shows, in stable order.
///
/// The caller supplies the one guid lookup built from its existing `@Query`.
/// Unknown guids are omitted: the relaunch route owns clearing state for an
/// episode that was deleted while its background transfer was running.
func activeDownloads(
    episodesByGUID: [String: Episode],
    states: [String: DownloadManager.DownloadState]
) -> [ActiveDownload] {
    states.compactMap { guid, state in
        episodesByGUID[guid].map { ActiveDownload(episode: $0, state: state) }
    }
    .sorted(by: activeDownloadComesBefore)
}

private func activeDownloadComesBefore(_ left: ActiveDownload, _ right: ActiveDownload) -> Bool {
    let leftRank = activeDownloadRank(left.state)
    let rightRank = activeDownloadRank(right.state)
    if leftRank != rightRank { return leftRank < rightRank }

    let leftTitle = left.episode.podcast?.title ?? "Unknown Podcast"
    let rightTitle = right.episode.podcast?.title ?? "Unknown Podcast"
    if leftTitle != rightTitle { return leftTitle < rightTitle }

    switch (left.episode.publishedAt, right.episode.publishedAt) {
    case (let leftDate?, let rightDate?) where leftDate != rightDate:
        return leftDate > rightDate
    case (.some, .none):
        return true
    case (.none, .some):
        return false
    default:
        return left.episode.guid < right.episode.guid
    }
}

private func activeDownloadRank(_ state: DownloadManager.DownloadState) -> Int {
    state.isDownloading ? 0 : 1
}

// MARK: - The status vocabulary both download surfaces render

/// The one sentence a transfer row says about itself, for every phase.
///
/// Free function rather than view code so the vocabulary is assertable and so
/// the Downloads tab and the podcast detail list cannot word the same phase two
/// ways (AGENTS.md: anything worth asserting leaves the view).
///
/// Stalled is worded as a fixed statement rather than a counting duration on
/// purpose: the stalled phase is a single state write, and nothing invalidates
/// the row again while it holds, so a live-looking counter would freeze at
/// whatever it happened to say.
func transferStatusText(_ progress: DownloadProgress) -> String {
    switch progress {
    case .queued(let position):
        return queuedText(position: position)
    case .connecting:
        return "Connecting…"
    case .indeterminate(let bytesWritten, let bytesPerSecond):
        let parts = [transferBytesText(bytesWritten), transferRateText(bytesPerSecond)]
        let measured = parts.compactMap { $0 }.joined(separator: " · ")
        return measured.isEmpty ? "Downloading…" : measured
    case .fraction(let bytesWritten, let expectedBytes, let bytesPerSecond):
        let ratio = DownloadProgress.ratio(bytesWritten: bytesWritten, expectedBytes: expectedBytes)
        let counted = "\(diskUsageText(byteValue(bytesWritten))) of \(diskUsageText(byteValue(expectedBytes)))"
        let parts = [counted, percentText(ratio), transferRateText(bytesPerSecond)]
        return parts.compactMap { $0 }.joined(separator: " · ")
    case .stalled:
        // interpolated from the threshold the deadline actually uses: as a
        // literal the sentence goes on stating a duration the app no longer
        // measures, and the test asserting the literal would keep passing
        return "Stalled · no data for \(Int(DownloadPacing.stallThreshold))s or more"
    case .finalizing:
        return "Finishing…"
    }
}

/// Queue place worded without an ordinal (decision 17: cue is English-only and
/// no ordinal formatting is pulled in for one string).
private func queuedText(position: Int) -> String {
    position > 1 ? "Queued · \(position) in line" : "Queued"
}

/// Bytes received so far, or `nil` before the first one — "Zero KB" reads as a
/// measurement of nothing rather than as a transfer that has not started.
private func transferBytesText(_ bytesWritten: Int64) -> String? {
    guard bytesWritten > 0 else { return nil }
    return diskUsageText(byteValue(bytesWritten))
}

/// A measured rate in the same file-style units as every other size here.
///
/// `nil` for an absent, non-finite or negative rate, and the `Double` is bounded
/// before the conversion: the rate is computed from server-supplied byte counts,
/// and `Int(_: Double)` traps rather than saturating.
func transferRateText(_ bytesPerSecond: Double?) -> String? {
    guard let bytesPerSecond, bytesPerSecond.isFinite, bytesPerSecond >= 1 else { return nil }
    guard bytesPerSecond < Double(Int.max) else { return nil }
    return "\(diskUsageText(Int(bytesPerSecond.rounded())))/s"
}

/// Whole percent. Safe because `DownloadProgress.ratio` clamps to `0...1`.
private func percentText(_ ratio: Double) -> String {
    "\(Int((ratio * 100).rounded()))%"
}

/// `Int64` byte counts meet `diskUsageText`'s `Int` without a trapping cast.
private func byteValue(_ bytes: Int64) -> Int {
    Int(clamping: bytes)
}

/// What the cramped podcast-detail row draws: a small bar or a spinner, and a
/// short label beside it.
///
/// The full sentence does not fit next to an episode title, but the phase still
/// has to be distinguishable there — so the same phases produce a compact form
/// derived in one place instead of a second switch inside the view.
struct CompactTransferStatus: Equatable {
    /// A determinate bar's value, or `nil` when there is no usable total.
    let fractionValue: Double?
    /// Whether an indeterminate spinner stands in for the bar.
    let showsSpinner: Bool
    /// The text beside it, or `nil` when the bar alone says enough.
    let text: String?
}

func compactTransferStatus(_ progress: DownloadProgress) -> CompactTransferStatus {
    switch progress {
    case .queued(let position):
        return CompactTransferStatus(
            fractionValue: nil, showsSpinner: false, text: queuedText(position: position))
    case .connecting:
        return CompactTransferStatus(fractionValue: nil, showsSpinner: true, text: "Connecting…")
    case .indeterminate(let bytesWritten, _):
        return CompactTransferStatus(
            fractionValue: nil, showsSpinner: true, text: transferBytesText(bytesWritten))
    case .fraction(let bytesWritten, let expectedBytes, _):
        let ratio = DownloadProgress.ratio(bytesWritten: bytesWritten, expectedBytes: expectedBytes)
        return CompactTransferStatus(
            fractionValue: ratio, showsSpinner: false, text: percentText(ratio))
    case .stalled:
        return CompactTransferStatus(
            fractionValue: progress.fractionValue, showsSpinner: false, text: "Stalled")
    case .finalizing:
        return CompactTransferStatus(fractionValue: nil, showsSpinner: true, text: "Finishing…")
    }
}
