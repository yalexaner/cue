import Foundation
import Testing

@testable import cue

/// What the download alert says. The feed mapper's own cases are
/// `FeedErrorMessageTests`; these are the download-only half.
struct DownloadErrorMessageTests {
    private struct TokenBearingError: LocalizedError {
        var errorDescription: String? {
            "Request failed for https://example.com/feed?token=REDACTED_TEST_TOKEN"
        }
    }

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

    /// The failure the first device session hit: a transfer that reached 100%
    /// and then timed out has to be distinguishable from one that never
    /// connected, or the alert says nothing an agent can work from.
    @Test func aTimeoutSaysItTimedOutRatherThanNamingTheServer() throws {
        let message = try #require(downloadErrorMessage(for: URLError(.timedOut)))

        #expect(message == "The download timed out. The server stopped answering — try again.")
    }

    @Test func reachabilityFailuresSayTheConnectionWasLost() throws {
        for code in Self.unreachableCodes {
            let message = try #require(downloadErrorMessage(for: URLError(code)))

            #expect(message == "The connection to the server was lost. Check your connection and try again.")
        }
    }

    @Test func fileFailuresSaidToBeNetworkErrorsNowNameStorage() throws {
        for code in Self.fileCodes {
            let message = try #require(downloadErrorMessage(for: URLError(code)))

            #expect(message == "The download could not be saved to storage. Check available storage and try again.")
        }
    }

    /// Everything outside the three categories keeps the sentence the mapper
    /// always answered with, rather than a guess at what the code meant.
    @Test func anUncategorisedURLErrorKeepsTheOriginalSentence() throws {
        let message = try #require(downloadErrorMessage(for: URLError(.badServerResponse)))

        #expect(message == "The download could not reach the server. Check your connection and try again.")
    }

    /// The rule the whole mapper exists to enforce: no branch may answer with an
    /// error's own text, because a `URLError` carries its failing URL and a
    /// private feed's URL is the credential (spec §6).
    @Test func noBranchReturnsARawLocalizedDescription() throws {
        for error in Self.everyMappedError {
            guard let message = downloadErrorMessage(for: error) else { continue }
            let description = error.localizedDescription

            #expect(message != description)
            #expect(!message.contains(description))
            #expect(!message.contains("REDACTED_TEST_TOKEN"))
        }
    }

    // split in two, and every literal on one line: a multiline literal cannot
    // satisfy `swift-format` and SwiftLint at once (AGENTS.md)
    private static let lostCodes: [URLError.Code] = [.networkConnectionLost, .notConnectedToInternet]
    private static let unroutableCodes: [URLError.Code] = [.cannotConnectToHost, .cannotFindHost, .dnsLookupFailed]
    private static let roamingCodes: [URLError.Code] = [.internationalRoamingOff, .dataNotAllowed]
    private static let refusedCodes: [URLError.Code] = [.secureConnectionFailed]
    private static let writeCodes: [URLError.Code] = [.cannotWriteToFile, .cannotMoveFile, .cannotCreateFile]
    private static let handleCodes: [URLError.Code] = [.cannotRemoveFile, .cannotOpenFile, .cannotCloseFile]

    private static var unreachableCodes: [URLError.Code] { lostCodes + unroutableCodes + roamingCodes + refusedCodes }
    private static var fileCodes: [URLError.Code] { writeCodes + handleCodes }

    private static var everyMappedError: [Error] {
        let codes = unreachableCodes + fileCodes + [.timedOut, .badServerResponse]
        let address = "https://example.com/ep.mp3?token=REDACTED_TEST_TOKEN"
        let status: Error = DownloadManager.Failure.httpStatus(403, address)
        let invalid: Error = DownloadManager.Failure.invalidEnclosureURL(address)
        let others: [Error] = [EpisodeStore.Failure.invalidFilename("../escape"), TokenBearingError()]
        return codes.map { URLError($0) } + [status, invalid] + others + [CocoaError(.fileWriteOutOfSpace)]
    }

    /// A transport can put the token-bearing enclosure URL in its arbitrary
    /// description. Unknown categories must not pass that text through.
    @Test func arbitraryErrorDescriptionsCannotExposeAnEnclosureURL() throws {
        let message = try #require(downloadErrorMessage(for: TokenBearingError()))

        #expect(message == "The download failed. Please try again.")
        #expect(!message.contains("/feed"))
        #expect(!message.contains("REDACTED_TEST_TOKEN"))
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

/// The export screen's own mapper.
///
/// Its own function so a failed log export cannot be reported in the download
/// vocabulary — the same rule that keeps `downloadErrorMessage(for:)` separate
/// from `feedErrorMessage(for:)`.
@Suite struct DiagnosticsExportErrorMessageTests {
    @Test func aStorageFailureNamesTheDiagnosticsFileRatherThanADownload() {
        let message = diagnosticsExportErrorMessage(for: CocoaError(.fileWriteOutOfSpace))
        #expect(message.contains("diagnostics"))
        #expect(!message.lowercased().contains("download"))
    }

    /// Non-optional on purpose: the export is one tap that either produces a
    /// file or does not, so a `nil` would only let the button fail in silence.
    @Test func everyOtherErrorGetsAFixedSentenceIncludingCancellation() {
        #expect(diagnosticsExportErrorMessage(for: CancellationError()).isEmpty == false)
        let secret = "https://example.com/x?token=REDACTED_TEST_TOKEN"
        let message = diagnosticsExportErrorMessage(for: URLError(.badURL, userInfo: [:]))
        #expect(!message.contains(secret))
        #expect(message == "The diagnostics log could not be exported. Please try again.")
    }
}
