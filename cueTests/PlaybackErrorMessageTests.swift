import Foundation
import Testing

@testable import cue

struct PlaybackErrorMessageTests {
    private struct TokenBearingError: LocalizedError {
        var errorDescription: String? {
            "Playback failed for https://example.com/feed?token=REDACTED_TEST_TOKEN"
        }
    }

    @Test func noErrorHasNoAlertMessage() {
        #expect(playbackErrorMessage(for: nil) == nil)
    }

    @Test func anEpisodeWithoutADownloadExplainsTheRequirement() {
        let message = playbackErrorMessage(for: PlaybackEngine.Failure.notDownloaded)

        #expect(message == "Download this episode before playing it.")
    }

    @Test func aMissingFileSuggestsDownloadingAgain() {
        let message = playbackErrorMessage(for: PlaybackEngine.Failure.fileMissing)

        #expect(message == "The downloaded audio file could not be found. Download the episode again.")
    }

    @Test func aFailedItemSuggestsDeletingAndDownloadingAgain() {
        let message = playbackErrorMessage(for: PlaybackEngine.Failure.itemFailed)

        #expect(message == "This episode could not be played. Delete it and download the episode again.")
    }

    @Test func anInvalidStoredFilenameUsesAFixedSentence() throws {
        let message = try #require(playbackErrorMessage(for: EpisodeStore.Failure.invalidFilename("../private.mp3")))
        let expected = "The downloaded audio file has an invalid file name. Delete it and download the episode again."

        #expect(message == expected)
        #expect(!message.contains("../private.mp3"))
    }

    @Test func localFileErrorsUseAFixedSentence() {
        let error = CocoaError(.fileReadNoPermission)

        #expect(
            playbackErrorMessage(for: error)
                == "The downloaded audio file could not be read. Check available storage and try again.")
    }

    @Test func arbitraryErrorDescriptionsCannotExposeAURL() throws {
        let message = try #require(playbackErrorMessage(for: TokenBearingError()))

        #expect(message == "Playback failed. Please try again.")
        #expect(!message.contains("example.com"))
        #expect(!message.contains("REDACTED_TEST_TOKEN"))
    }
}
