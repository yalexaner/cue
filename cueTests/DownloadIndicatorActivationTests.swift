import Foundation
import Testing

@testable import cue

private let indeterminate = DownloadProgress.indeterminate(bytesWritten: 1_024, bytesPerSecond: nil)
private let fraction = DownloadProgress.fraction(
    bytesWritten: 512, expectedBytes: 1_024, bytesPerSecond: 2_048)
private let stalled = DownloadProgress.stalled(bytesWritten: 512, expectedBytes: 1_024)
private let finalizing = DownloadProgress.finalizing(bytesWritten: 1_024)
private let queued = DownloadProgress.queued(position: 4)
private var everyPhase: [DownloadProgress] {
    [.queued(position: 1), queued, .connecting, indeterminate, fraction, stalled, finalizing]
}

/// The indicator's tap policy, its per-phase accessibility text and the
/// confirmation it raises. All three are plain values, so all three are asserted
/// directly rather than through a view (AGENTS.md: views are covered by the
/// build only).
struct DownloadIndicatorActivationTests {

    @Test func anAbsentFileOffersADownload() {
        #expect(downloadIndicatorActivation(for: .notDownloaded) == .download)
    }

    @Test func everyDownloadingPhaseCancels() {
        for progress in everyPhase {
            #expect(downloadIndicatorActivation(for: .downloading(progress)) == .cancel)
        }
    }

    @Test func aStoredFileAsksBeforeItIsRemoved() {
        #expect(downloadIndicatorActivation(for: .downloaded) == .confirmDelete)
    }

    /// The one place the tap policy and the menu policy deliberately differ.
    @Test func failedActivatesDetailRatherThanRetry() {
        let state = EpisodeDownloadState.failed(message: "It did not work")
        #expect(downloadIndicatorActivation(for: state) == .showFailure)
        #expect(downloadAction(for: state) == .download)
    }

    /// And the only place: every other state answers the two questions the same.
    @Test func theTwoPoliciesAgreeOnEveryOtherState() {
        var states: [EpisodeDownloadState] = [.notDownloaded, .downloaded]
        states.append(contentsOf: everyPhase.map { EpisodeDownloadState.downloading($0) })
        for state in states {
            let expected: DownloadIndicatorActivation
            switch downloadAction(for: state) {
            case .download: expected = .download
            case .cancel: expected = .cancel
            case .delete: expected = .confirmDelete
            }
            #expect(downloadIndicatorActivation(for: state) == expected)
        }
    }

    /// The composed answer the Downloads tab's completed list needs.
    ///
    /// That list is built on file presence alone, so an episode being
    /// re-downloaded is a row that has both a filename and a live transfer. Both
    /// of its controls resolve the row through `episodeDownloadState` first, and
    /// the transfer has to outrank the file: an indicator that read only the
    /// filename would offer an immediate delete under the running move, which
    /// clears the columns and the file just before the finish writes the new
    /// filename back over them.
    @Test func aStoredFileBeingReDownloadedCancelsRatherThanDeletes() {
        for progress in everyPhase {
            let state = episodeDownloadState(localFilename: "a.mp3", transfer: .downloading(progress))
            #expect(downloadIndicatorActivation(for: state) == .cancel)
            #expect(downloadAction(for: state) == .cancel)
        }
    }

    @Test func theTapTargetMeetsThePlatformMinimum() {
        #expect(downloadIndicatorMinimumTapTarget >= 44)
    }
}

struct DownloadIndicatorAccessibilityTests {

    @Test func anAbsentFileReadsAsADownloadControl() {
        let text = downloadIndicatorAccessibility(for: .notDownloaded)
        #expect(text.label == "Download")
        #expect(!text.hint.isEmpty)
        #expect(text.value == nil)
    }

    @Test func aStoredFileSaysADeleteIsConfirmedFirst() {
        let text = downloadIndicatorAccessibility(for: .downloaded)
        #expect(text.label == "Downloaded")
        #expect(text.hint.contains("confirming"))
        #expect(text.value == nil)
    }

    @Test func aFailureReadsItsMessageAndOffersRetryFromInside() {
        let text = downloadIndicatorAccessibility(for: .failed(message: "No space left"))
        #expect(text.label == "Download Failed")
        #expect(text.hint.contains("retry"))
        #expect(text.value == "No space left")
    }

    /// The spoken value is the same sentence the row renders, so a phase cannot
    /// read one way on screen and another to VoiceOver.
    @Test func everyDownloadingPhaseSpeaksItsOwnStatusLine() {
        let phases: [DownloadProgress] = everyPhase.filter { $0 != .queued(position: 1) }
        var spoken: Set<String> = []
        for progress in phases {
            let text = downloadIndicatorAccessibility(for: .downloading(progress))
            #expect(text.label == "Cancel Download")
            #expect(text.value == transferStatusText(progress))
            spoken.insert(text.value ?? "")
        }
        // and the six phases are distinguishable from one another
        #expect(spoken.count == phases.count)
    }
}

struct DeleteDownloadConfirmationMessageTests {

    @Test func itNamesTheEpisodeAndWhatTheDeleteFrees() {
        let message = deleteDownloadConfirmationMessage(episodeTitle: "Pilot", byteCount: 5_000_000)
        #expect(message.contains("Pilot"))
        #expect(message.contains(diskUsageText(5_000_000)))
    }

    /// A size the store could not measure is left unsaid rather than claimed as
    /// nothing: the file has not shrunk, the measurement failed.
    @Test func anUnknownSizeIsLeftUnsaid() {
        let message = deleteDownloadConfirmationMessage(episodeTitle: "Pilot", byteCount: nil)
        #expect(message.contains("Pilot"))
        #expect(!message.contains("frees"))
    }

    @Test func aZeroByteFileIsTreatedAsNoSizeAtAll() {
        let message = deleteDownloadConfirmationMessage(episodeTitle: "Pilot", byteCount: 0)
        #expect(!message.contains("frees"))
    }

    @Test func aTitleWithNoCharactersStillProducesASentence() {
        let message = deleteDownloadConfirmationMessage(episodeTitle: "", byteCount: nil)
        #expect(message.hasSuffix("will be removed from this device."))
    }
}
