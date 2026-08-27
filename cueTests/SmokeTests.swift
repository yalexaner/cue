import Foundation
import Testing

@testable import cue

struct SmokeTests {
    @Test func testableImportResolves() {
        #expect(Bool(true))
    }

    @Test func appAllowsArbitraryNetworkLoads() {
        // read as `[String: Any]`: a later per-domain `NSExceptionDomains`
        // entry is a nested dictionary, and a `[String: Bool]` cast would fail
        // the whole assertion over a key this test is not about
        let appTransportSecurity =
            Bundle.main.object(forInfoDictionaryKey: "NSAppTransportSecurity") as? [String: Any]
        #expect(appTransportSecurity?["NSAllowsArbitraryLoads"] as? Bool == true)
    }

    @Test func appSharesItsDocumentsDirectory() {
        // the two settings the diagnostics export depends on: without them the
        // exported file exists but is reachable only through the share sheet,
        // never from Files or a cable. One arrives through `Config/App.xcconfig`
        // and one through the partial `Info.plist`, so both routes are pinned.
        #expect(Bundle.main.object(forInfoDictionaryKey: "UIFileSharingEnabled") as? Bool == true)
        let inPlace = Bundle.main.object(forInfoDictionaryKey: "LSSupportsOpeningDocumentsInPlace")
        #expect(inPlace as? Bool == true)
    }

    @Test func fixturesLoadAsData() throws {
        #expect(!(try fixtureData(named: "durations", withExtension: "rss")).isEmpty)
        #expect(!(try fixtureData(named: "itunes", withExtension: "rss")).isEmpty)
        #expect(!(try fixtureData(named: "malformed", withExtension: "rss")).isEmpty)
        #expect(!(try fixtureData(named: "no-enclosures", withExtension: "rss")).isEmpty)
        #expect(!(try fixtureData(named: "sample", withExtension: "opml")).isEmpty)
        #expect(!(try fixtureData(named: "simple", withExtension: "rss")).isEmpty)
        #expect(!(try fixtureData(named: "tokenised", withExtension: "rss")).isEmpty)
    }
}
