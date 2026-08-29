import Foundation
import Testing

@testable import cue

/// The status vocabulary both download surfaces render (step 4.6, Task 9).
///
/// Its own file rather than an addition to `ActiveDownloadFormattingTests`: that
/// suite is about ordering and needs a `ModelContext` per test, while none of
/// this touches SwiftData at all.
struct TransferStatusTextTests {
    @Test func queuedSaysSoWithoutAPositionAtTheHeadOfTheLine() {
        #expect(transferStatusText(.queued(position: 1)) == "Queued")
    }

    @Test func queuedBehindOthersNamesItsPlaceWithoutAnOrdinal() {
        #expect(transferStatusText(.queued(position: 4)) == "Queued · 4 in line")
    }

    @Test func connectingIsDistinctFromQueued() {
        #expect(transferStatusText(.connecting) == "Connecting…")
    }

    @Test func anUnknownTotalShowsBytesAndRateWithNoPercent() {
        let text = transferStatusText(.indeterminate(bytesWritten: 2_000_000, bytesPerSecond: 512_000))

        #expect(text == "\(diskUsageText(2_000_000)) · \(diskUsageText(512_000))/s")
        #expect(!text.contains("%"))
    }

    @Test func anUnknownTotalWithNoRateShowsBytesAlone() {
        #expect(transferStatusText(.indeterminate(bytesWritten: 2_000_000)) == diskUsageText(2_000_000))
    }

    /// Zero bytes must not read as "Zero KB" — nothing has arrived yet.
    @Test func zeroBytesWithNoRateReadsAsDownloadingRatherThanAsAMeasurement() {
        #expect(transferStatusText(.indeterminate(bytesWritten: 0)) == "Downloading…")
    }

    @Test func zeroBytesWithAKnownTotalStillCountsFromZero() {
        let text = transferStatusText(.fraction(bytesWritten: 0, expectedBytes: 4_000_000))

        #expect(text == "\(diskUsageText(0)) of \(diskUsageText(4_000_000)) · 0%")
    }

    @Test func aKnownTotalShowsBytesOfTotalThenPercentThenRate() {
        let progress = DownloadProgress.fraction(
            bytesWritten: 1_000_000, expectedBytes: 4_000_000, bytesPerSecond: 250_000)

        #expect(
            transferStatusText(progress)
                == "\(diskUsageText(1_000_000)) of \(diskUsageText(4_000_000)) · 25% · \(diskUsageText(250_000))/s"
        )
    }

    /// Over-delivery is clamped by `DownloadProgress.ratio`, so the percent can
    /// never exceed 100 even though the byte counts disagree.
    @Test func overDeliveryReportsOneHundredPercentRatherThanMore() {
        let progress = DownloadProgress.fraction(bytesWritten: 9_000_000, expectedBytes: 4_000_000)

        #expect(transferStatusText(progress).contains("100%"))
    }

    /// Decision 16's threshold, worded as a fixed statement: the stalled phase is
    /// one state write and nothing invalidates the row again while it holds, so a
    /// counting duration would freeze on screen.
    @Test func stalledUsesFixedWordingRatherThanACountingDuration() {
        let text = transferStatusText(.stalled(bytesWritten: 1_000, expectedBytes: 4_000))

        #expect(text == "Stalled · no data for 30s or more")
        #expect(text.contains("30s"))
    }

    @Test func stalledWithNoKnownTotalSaysTheSameThing() {
        #expect(
            transferStatusText(.stalled(bytesWritten: 1_000, expectedBytes: nil))
                == "Stalled · no data for 30s or more")
    }

    /// The window the 100%-then-fail bug lives in must not read as plain 100%.
    @Test func finalizingIsNotWordedAsACompletePercentage() {
        let text = transferStatusText(.finalizing(bytesWritten: 4_000_000))

        #expect(text == "Finishing…")
        #expect(!text.contains("100%"))
    }

    @Test func everyPhaseProducesANonEmptyLine() {
        for progress in allTransferPhases {
            #expect(!transferStatusText(progress).isEmpty)
        }
    }
}

/// Byte and rate formatting, which must match `diskUsageText`'s file-style units.
struct TransferRateFormattingTests {
    @Test func aRateUsesTheSameFileStyleUnitsAsDiskUsage() {
        #expect(transferRateText(1_500_000) == "\(diskUsageText(1_500_000))/s")
    }

    @Test func aRateIsRoundedToWholeBytesPerSecond() {
        #expect(transferRateText(1_048_576.4) == "\(diskUsageText(1_048_576))/s")
    }

    @Test func anAbsentRateShowsNothing() {
        #expect(transferRateText(nil) == nil)
    }

    /// Below a byte a second there is no measurement worth printing, and the
    /// negative and non-finite cases come from arithmetic over server-supplied
    /// counts rather than from anything a user did.
    @Test func nonMeasurementsShowNothing() {
        #expect(transferRateText(0) == nil)
        #expect(transferRateText(0.4) == nil)
        #expect(transferRateText(-10) == nil)
        #expect(transferRateText(.nan) == nil)
        #expect(transferRateText(.infinity) == nil)
    }

    /// `Int(_: Double)` traps rather than saturating, and the rate is derived
    /// from feed-supplied byte counts.
    @Test func anUnrepresentableRateShowsNothingRatherThanTrapping() {
        #expect(transferRateText(Double(Int.max) * 4) == nil)
    }

    @Test func aByteCountInTheLineMatchesDiskUsageText() {
        let text = transferStatusText(.indeterminate(bytesWritten: 1_500_000))

        #expect(text == diskUsageText(1_500_000))
    }
}

/// The compact form the podcast-detail row draws beside an episode title.
struct CompactTransferStatusTests {
    @Test func aKnownTotalDrawsADeterminateBarWithItsPercent() {
        let status = compactTransferStatus(.fraction(bytesWritten: 1_000, expectedBytes: 4_000))

        #expect(status.fractionValue == 0.25)
        #expect(status.showsSpinner == false)
        #expect(status.text == "25%")
    }

    @Test func anUnknownTotalDrawsASpinnerWithItsBytes() {
        let status = compactTransferStatus(.indeterminate(bytesWritten: 2_000_000))

        #expect(status.fractionValue == nil)
        #expect(status.showsSpinner)
        #expect(status.text == diskUsageText(2_000_000))
    }

    @Test func anUnknownTotalWithNoBytesYetDrawsTheSpinnerAlone() {
        let status = compactTransferStatus(.indeterminate(bytesWritten: 0))

        #expect(status.showsSpinner)
        #expect(status.text == nil)
    }

    @Test func queuedNamesItsPlaceWithNoBarAndNoSpinner() {
        let status = compactTransferStatus(.queued(position: 3))

        #expect(status.fractionValue == nil)
        #expect(status.showsSpinner == false)
        #expect(status.text == "Queued · 3 in line")
    }

    @Test func connectingSpinsWithoutABar() {
        let status = compactTransferStatus(.connecting)

        #expect(status.fractionValue == nil)
        #expect(status.showsSpinner)
        #expect(status.text == "Connecting…")
    }

    /// A stalled transfer keeps whatever bar it had — the bytes are still there —
    /// but stops spinning, because nothing is moving.
    @Test func stalledKeepsItsBarAndStopsSpinning() {
        let status = compactTransferStatus(.stalled(bytesWritten: 1_000, expectedBytes: 4_000))

        #expect(status.fractionValue == 0.25)
        #expect(status.showsSpinner == false)
        #expect(status.text == "Stalled")
    }

    @Test func stalledWithNoKnownTotalHasNoBar() {
        let status = compactTransferStatus(.stalled(bytesWritten: 1_000, expectedBytes: nil))

        #expect(status.fractionValue == nil)
        #expect(status.text == "Stalled")
    }

    @Test func finalizingSpinsRatherThanShowingAFullBar() {
        let status = compactTransferStatus(.finalizing(bytesWritten: 4_000_000))

        #expect(status.fractionValue == nil)
        #expect(status.showsSpinner)
        #expect(status.text == "Finishing…")
    }

    @Test func everyPhaseDrawsSomething() {
        for progress in allTransferPhases {
            let status = compactTransferStatus(progress)
            #expect(status.fractionValue != nil || status.showsSpinner || status.text != nil)
        }
    }
}

/// One instance of every phase, so a new case cannot be added without a status.
///
/// Assembled by appending rather than written as one literal: a multiline
/// collection literal cannot pass `just lint` and `just format-check` at the
/// same time, and this list does not fit on a line (AGENTS.md).
private func everyTransferPhase() -> [DownloadProgress] {
    var phases: [DownloadProgress] = [.queued(position: 1), .queued(position: 5), .connecting]
    phases.append(.indeterminate(bytesWritten: 0))
    phases.append(.indeterminate(bytesWritten: 10, bytesPerSecond: 5))
    phases.append(.fraction(bytesWritten: 0, expectedBytes: 10))
    phases.append(.fraction(bytesWritten: 10, expectedBytes: 10, bytesPerSecond: 5))
    phases.append(.stalled(bytesWritten: 1, expectedBytes: nil))
    phases.append(.stalled(bytesWritten: 1, expectedBytes: 10))
    phases.append(.finalizing(bytesWritten: 10))
    return phases
}

private let allTransferPhases = everyTransferPhase()
