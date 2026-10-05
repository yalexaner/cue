import Foundation

/// Maps local playback failures to fixed, credential-safe alert text.
///
/// An arbitrary error description can contain a URL, including a private feed
/// credential. Unknown errors therefore never pass their descriptions through.
func playbackErrorMessage(for error: (any Error)?) -> String? {
    guard let error else { return nil }

    switch error {
    case PlaybackEngine.Failure.notDownloaded:
        return "Download this episode before playing it."
    case PlaybackEngine.Failure.fileMissing:
        return "The downloaded audio file could not be found. Download the episode again."
    case PlaybackEngine.Failure.itemFailed:
        return "This episode could not be played. Delete it and download the episode again."
    case is EpisodeStore.Failure:
        return "The downloaded audio file has an invalid file name. Delete it and download the episode again."
    case is CocoaError:
        return "The downloaded audio file could not be read. Check available storage and try again."
    default:
        return "Playback failed. Please try again."
    }
}
