import Testing

@testable import cue

@Suite("Feed paste offer")
struct FeedPasteOfferTests {
    @Test("a detected web URL on an empty field offers paste")
    func detectedURLOffersPaste() {
        #expect(shouldOfferFeedPaste(detection: .detected(containsProbableWebURL: true), fieldText: ""))
    }

    @Test("a detection that found no URL offers nothing")
    func noURLOffersNothing() {
        #expect(!shouldOfferFeedPaste(detection: .detected(containsProbableWebURL: false), fieldText: ""))
    }

    @Test("a failed detection never falls back to offering a blind read")
    func failedDetectionOffersNothing() {
        #expect(!shouldOfferFeedPaste(detection: .unavailable, fieldText: ""))
    }

    @Test("a field that already has an address is not interrupted")
    func nonEmptyFieldOffersNothing() {
        let detection = FeedPasteDetection.detected(containsProbableWebURL: true)
        #expect(!shouldOfferFeedPaste(detection: detection, fieldText: "https://example.com/feed.xml"))
    }

    @Test("a field holding only paste whitespace still counts as empty")
    func whitespaceFieldStillOffers() {
        #expect(shouldOfferFeedPaste(detection: .detected(containsProbableWebURL: true), fieldText: " \n\t "))
    }

    @Test("a clipboard with no text contributes nothing")
    func missingClipboardTextContributesNothing() {
        #expect(pastedFeedAddress(fromClipboard: nil) == nil)
    }

    @Test("a clipboard that changed to nothing between detection and read contributes nothing")
    func emptyClipboardContributesNothing() {
        #expect(pastedFeedAddress(fromClipboard: "") == nil)
        #expect(pastedFeedAddress(fromClipboard: "  \n ") == nil)
    }

    @Test("a pasted address is normalised exactly as a typed one")
    func pastedAddressIsNormalisedLikeTyped() {
        let pasted = "  https://example.com/feed.xml\n"
        #expect(pastedFeedAddress(fromClipboard: pasted) == normalisedFeedAddress(pasted))
        #expect(pastedFeedAddress(fromClipboard: pasted) == "https://example.com/feed.xml")
    }

    @Test("an inner token survives a paste byte for byte")
    func pastedTokenSurvives() {
        let tokenised = "https://example.com/feed?token=REDACTED_TEST_TOKEN"
        #expect(pastedFeedAddress(fromClipboard: " \(tokenised) ") == tokenised)
        #expect(pastedFeedAddress(fromClipboard: tokenised) == normalisedFeedAddress(tokenised))
    }
}
