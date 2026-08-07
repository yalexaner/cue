import Testing

@testable import cue

struct FeedAddressTests {

    /// Whitespace and newlines are clipboard artifacts, so they go.
    @Test func surroundingWhitespaceAndNewlinesAreRemoved() {
        #expect(normalisedFeedAddress("  https://example.com/feed\n") == "https://example.com/feed")
        #expect(normalisedFeedAddress("\t\nhttps://example.com/feed  ") == "https://example.com/feed")
    }

    /// Everything inside survives byte for byte: a private feed whose token were
    /// rewritten answers 401 (spec §6).
    @Test func theAddressItselfIsNeverRewritten() {
        let tokenised = "https://example.com/feed?token=REDACTED_TEST_TOKEN&a=b%20c"

        #expect(normalisedFeedAddress(tokenised) == tokenised)
        #expect(normalisedFeedAddress(" \(tokenised) ") == tokenised)
    }

    @Test func anAddressOfOnlyWhitespaceNormalisesToEmpty() {
        #expect(normalisedFeedAddress("   \n\t ").isEmpty)
        #expect(normalisedFeedAddress("").isEmpty)
    }
}
