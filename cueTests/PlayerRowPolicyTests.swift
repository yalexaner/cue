import Testing

@testable import cue

struct PlayerRowPolicyTests {
    @Test func onlyADownloadedRowOffersPlayback() {
        #expect(playAction(for: .downloaded))
        #expect(!playAction(for: .notDownloaded))
        #expect(!playAction(for: .downloading(.connecting)))
        #expect(!playAction(for: .downloading(.indeterminate(bytesWritten: 12))))
        #expect(!playAction(for: .downloading(.fraction(bytesWritten: 50, expectedBytes: 100))))
        #expect(!playAction(for: .failed(message: "The download failed.")))
    }

    /// A failed retry is listed twice when its previous file survives: the
    /// transfer row describes the failed attempt, while the completed row
    /// describes the file that is still actually present.
    @Test func aFailedRetryIsPlayableOnlyFromItsCompletedRow() {
        let failure = DownloadManager.DownloadState.failed(message: "The download failed.")
        let activeState = episodeDownloadState(localFilename: nil, transfer: failure)
        let completedState = episodeDownloadState(localFilename: "previous.mp3", transfer: failure)

        #expect(!playAction(for: activeState))
        #expect(playAction(for: completedState))
    }
}
