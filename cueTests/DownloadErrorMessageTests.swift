import Foundation
import Testing

@testable import cue

/// What the download alert says. The feed mapper's own cases are
/// `FeedErrorMessageTests`; these are the download-only half.
struct DownloadErrorMessageTests {

    /// The Boosty case: a rotated token answers 403, and the alert has to say so
    /// or the user has nothing to act on (spec §6). What it must not say is the
    /// enclosure URL — on a private feed that URL is the credential.
    @Test func httpStatusNamesTheStatusAndTheServerButNotThePath() throws {
        let failure = DownloadManager.Failure.httpStatus(403, "https://example.com/ep.mp3?token=REDACTED_TEST_TOKEN")
        let message = try #require(downloadErrorMessage(for: failure))

        #expect(message.contains("403"))
        #expect(message.contains("https://example.com"))
        #expect(!message.contains("REDACTED_TEST_TOKEN"))
        #expect(!message.contains("ep.mp3"))
    }

    @Test func invalidEnclosureURLNamesTheServerItCouldNotUse() throws {
        let message = try #require(downloadErrorMessage(for: DownloadManager.Failure.invalidEnclosureURL("ftp://x")))

        #expect(message.contains("ftp://x"))
    }

    @Test func storageFailureNamesTheFilename() throws {
        let message = try #require(downloadErrorMessage(for: EpisodeStore.Failure.invalidFilename("../escape")))

        #expect(message.contains("../escape"))
    }

    /// Cancellation is not a failure to report — the same rule the feed side
    /// follows, through the same classifier.
    @Test func cancellationIsNotReported() {
        #expect(downloadErrorMessage(for: CancellationError()) == nil)
        #expect(downloadErrorMessage(for: URLError(.cancelled)) == nil)
    }

    /// Anything the download layer does not own keeps its own description rather
    /// than being flattened into an invented sentence.
    @Test func unknownErrorsFallBackToTheirDescription() throws {
        let error = URLError(.timedOut)
        let message = try #require(downloadErrorMessage(for: error))

        #expect(message == error.localizedDescription)
        #expect(!message.isEmpty)
    }
}

/// The most of a pre-signed enclosure URL an alert may show.
///
/// A publisher can put the signature in the query, in the userinfo or in a path
/// segment, so all three have to go; scheme and host are what is left, and they
/// are enough to say which server answered.
struct RedactedAddressTests {

    @Test func aQueryTokenIsNotRendered() {
        let rendered = redactedAddress("https://example.com/ep.mp3?token=REDACTED_TEST_TOKEN&sig=REDACTED_TEST_TOKEN")

        #expect(rendered == "https://example.com")
        #expect(!rendered.contains("REDACTED_TEST_TOKEN"))
    }

    @Test func userinfoIsNotRendered() {
        let rendered = redactedAddress("https://user:REDACTED_TEST_TOKEN@example.com/ep.mp3")

        #expect(rendered == "https://example.com")
        #expect(!rendered.contains("REDACTED_TEST_TOKEN"))
        #expect(!rendered.contains("user"))
    }

    /// A signature can ride in the path rather than the query, so the path goes
    /// too — the host alone still says which server answered.
    @Test func aSignedPathSegmentIsNotRendered() {
        let rendered = redactedAddress("https://example.com/REDACTED_TEST_TOKEN/ep.mp3#REDACTED_TEST_TOKEN")

        #expect(rendered == "https://example.com")
        #expect(!rendered.contains("REDACTED_TEST_TOKEN"))
    }

    /// The `.invalidEnclosureURL` case carries a string that failed to parse, and
    /// echoing it back would defeat the whole point of trimming the parseable ones.
    @Test func anUnparseableAddressIsNotEchoed() {
        let rendered = redactedAddress("h t t p://%%%REDACTED_TEST_TOKEN")

        #expect(rendered == "an unreadable address")
        #expect(!rendered.contains("REDACTED_TEST_TOKEN"))
    }

    @Test func theStatusSurvivesRedaction() throws {
        let address = "https://example.com/private/ep.mp3?token=REDACTED_TEST_TOKEN"
        let failure = DownloadManager.Failure.httpStatus(401, address)
        let message = try #require(downloadErrorMessage(for: failure))

        #expect(message.contains("401"))
        #expect(!message.contains("REDACTED_TEST_TOKEN"))
        #expect(!message.contains("private"))
    }
}
