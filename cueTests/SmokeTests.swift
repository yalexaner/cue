import Foundation
import Testing

@testable import cue

struct SmokeTests {
    @Test func testableImportResolves() {
        #expect(Bool(true))
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
