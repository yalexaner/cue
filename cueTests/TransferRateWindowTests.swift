import Foundation
import Testing

@testable import cue

/// The trailing rate window, driven entirely by the times its caller supplies.
struct TransferRateWindowTests {
    @Test func aSingleReadingHasNoRateYet() {
        var window = TransferRateWindow()
        #expect(window.record(bytes: 100, at: 0) == nil)
        #expect(window.rate(at: 0) == nil)
    }

    @Test func theRateSpansTheOldestSurvivingReading() {
        var window = TransferRateWindow()
        window.record(bytes: 0, at: 0)
        window.record(bytes: 1000, at: 1)
        #expect(window.record(bytes: 2000, at: 2) == 1000)
    }

    /// Readings closer together than the minimum interval are noise, not a
    /// measurement — and at the same instant they are a division by zero.
    @Test func readingsTooCloseTogetherProduceNoRate() {
        var window = TransferRateWindow()
        window.record(bytes: 0, at: 10)
        #expect(window.record(bytes: 5000, at: 10 + TransferRateWindow.minimumInterval / 2) == nil)
        // a reading that does not advance the clock is dropped rather than
        // dividing by zero
        var same = TransferRateWindow()
        same.record(bytes: 0, at: 4)
        #expect(same.record(bytes: 900, at: 4) == nil)
        #expect(same.samples.count == 1)
    }

    @Test func readingsOlderThanTheWindowArePruned() {
        var window = TransferRateWindow()
        window.record(bytes: 0, at: 0)
        window.record(bytes: 1000, at: 1)
        window.record(bytes: 9000, at: 1 + TransferRateWindow.window)
        // the reading at zero has fallen out, so the rate is measured from one
        #expect(window.samples.map(\.time) == [1, 1 + TransferRateWindow.window])
        #expect(window.rate(at: 1 + TransferRateWindow.window) == 8000 / TransferRateWindow.window)
    }

    @Test func theSampleCountIsBounded() {
        var window = TransferRateWindow()
        for index in 0...(TransferRateWindow.maximumSamples + 40) {
            window.record(bytes: Int64(index), at: Double(index) / 1000)
        }
        #expect(window.samples.count <= TransferRateWindow.maximumSamples)
    }

    /// A stall records nothing, so every reading eventually leaves the window
    /// and the rate goes quiet rather than reporting a stale number.
    @Test func aStallEmptiesTheWindowRatherThanHoldingAStaleRate() {
        var window = TransferRateWindow()
        window.record(bytes: 0, at: 0)
        window.record(bytes: 4000, at: 2)
        #expect(window.rate(at: 2) == 2000)
        #expect(window.rate(at: 2 + TransferRateWindow.window + 1) == nil)
    }

    @Test func aResumedTransferMeasuresFromTheReadingsItStillHas() {
        var window = TransferRateWindow()
        window.record(bytes: 0, at: 0)
        window.record(bytes: 100, at: 1)
        // nothing for longer than the window, then bytes again
        let resumedAt = 1 + TransferRateWindow.window + 5
        #expect(window.record(bytes: 200, at: resumedAt) == nil)
        #expect(window.samples.map(\.bytes) == [200])
        #expect(window.record(bytes: 400, at: resumedAt + 1) == 200)
    }

    @Test func aReadingThatGoesBackwardsProducesNoRate() {
        var window = TransferRateWindow()
        window.record(bytes: 900, at: 0)
        #expect(window.record(bytes: 100, at: 1) == nil)
    }
}
