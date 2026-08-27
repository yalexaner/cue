import Foundation
import Testing

@testable import cue

@Suite("Diagnostics line formatting")
struct DiagnosticsLineTests {
    private let timestamp = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("fields are written in the order the record lists them")
    func fieldOrderIsPreserved() {
        let record = DiagnosticsRecord(
            level: .error,
            category: .downloads,
            event: "download.failed",
            fields: [DiagnosticsField("guid", DiagnosticsGUID("a")), DiagnosticsField("status", 403)]
        )
        let line = DiagnosticsLine.format(timestamp: timestamp, record: record)
        let parts = line.components(separatedBy: DiagnosticsLine.fieldDelimiter)
        #expect(parts.count == 6)
        #expect(parts[0].hasPrefix("ts="))
        #expect(parts[1] == "level=error")
        #expect(parts[2] == "category=downloads")
        #expect(parts[3] == "event=download.failed")
        #expect(parts[4] == "guid=\(DiagnosticsGUID("a").digest)")
        #expect(parts[5] == "status=403")
    }

    @Test("an adversarial value cannot forge a line break or a field boundary")
    func adversarialValuesAreEscaped() {
        let hostile = "a\nb\tc=d\re\u{0}f\\g"
        let record = DiagnosticsRecord(
            category: .storage,
            event: "e",
            fields: [DiagnosticsField("k", safe: hostile)]
        )
        let line = DiagnosticsLine.format(timestamp: timestamp, record: record)
        #expect(!line.contains("\n"))
        #expect(!line.contains("\r"))
        #expect(line.components(separatedBy: DiagnosticsLine.fieldDelimiter).count == 5)
        #expect(line.hasSuffix("k=a\\nb\\tc\\=d\\re\\u{00}f\\\\g"))
    }

    @Test("escaping round-trips every control character, the delimiter and the separator")
    func escapingIsReversible() {
        let samples = ["", "plain", "a=b", "a\tb", "a\nb\r", "\\", "\\n", "\u{1}\u{7f}", "héllo\u{1f600}"]
        for sample in samples {
            #expect(DiagnosticsLine.unescape(DiagnosticsLine.escape(sample)) == sample)
        }
    }

    @Test("an event name is escaped like any other field")
    func eventIsEscaped() {
        let record = DiagnosticsRecord(category: .downloads, event: "bad\nevent")
        let line = DiagnosticsLine.format(timestamp: timestamp, record: record)
        #expect(line.hasSuffix("event=bad\\nevent"))
    }
}

@Suite("Diagnostics safe field types")
struct DiagnosticsSafeFieldsTests {
    @Test("a host drops path, query and userinfo")
    func hostKeepsOnlySchemeAndHost() {
        let redacted = DiagnosticsHost("https://user:pass@example.com/a/b?token=REDACTED_TEST_TOKEN#f").redacted
        #expect(redacted == "https://example.com")
        #expect(!redacted.contains("token"))
        #expect(!redacted.contains("user"))
        #expect(!redacted.contains("pass"))
    }

    @Test("an address that does not parse is not echoed back")
    func unparseableAddressIsNotEchoed() {
        #expect(DiagnosticsHost("not an address").redacted == "an unreadable address")
    }

    /// The host is feed-supplied, so it is bounded like every other field here:
    /// without a cap one hostile enclosure puts kilobytes on a single line.
    @Test("a hostile host is capped, and the unparseable fallback is untouched")
    func hostIsBounded() {
        let host = String(repeating: "a", count: 2_000) + ".example.com"
        let redacted = DiagnosticsHost("https://\(host)/x").redacted
        #expect(redacted.count == DiagnosticsHost.maximumLength)
        #expect(DiagnosticsHost.maximumLength == DiagnosticsErrorCode.maximumDomainLength)
        #expect(redacted.hasPrefix("https://aaa"))
        // short values are still whole, and the fallback still reads as prose
        #expect(DiagnosticsHost("https://example.com/x").redacted == "https://example.com")
        #expect(DiagnosticsHost("not an address").redacted == "an unreadable address")
    }

    @Test("a guid digest is the same across constructions and across values")
    func guidDigestIsDeterministic() {
        #expect(DiagnosticsGUID("episode-guid").digest == DiagnosticsGUID("episode-guid").digest)
        #expect(DiagnosticsGUID("episode-guid").digest != DiagnosticsGUID("episode-guie").digest)
        #expect(DiagnosticsGUID("episode-guid").digest.count == DiagnosticsGUID.digestLength)
    }

    @Test("a guid whose secret starts at byte zero cannot be read back out of its digest")
    func guidDigestIsNotAPrefixOfTheGUID() {
        let guid = "https://example.com/e?token=REDACTED_TEST_TOKEN"
        let digest = DiagnosticsGUID(guid).digest
        #expect(!guid.hasPrefix(digest))
        #expect(!guid.contains(digest))
        #expect(!digest.contains("http"))
        #expect(digest.allSatisfy { $0.isHexDigit })
        // two guids sharing a long prefix must not share a digest prefix
        let sibling = DiagnosticsGUID(guid + "2").digest
        #expect(sibling != digest)
    }

    @Test("a field renders a host and a guid through their sanitised forms")
    func fieldsUseSanitisedValues() {
        #expect(DiagnosticsField("host", DiagnosticsHost("https://example.com/x")).value == "https://example.com")
        #expect(DiagnosticsField("guid", DiagnosticsGUID("g")).value == DiagnosticsGUID("g").digest)
        #expect(DiagnosticsField("bytes", Int64(9)).value == "9")
    }
}
