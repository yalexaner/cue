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
