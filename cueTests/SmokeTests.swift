import Foundation
import Testing

@testable import cue

private final class FixtureBundleMarker {}

private enum FixtureError: Error {
    case missing(String)
}

private func fixtureData(named name: String, withExtension ext: String) throws -> Data {
    let bundle = Bundle(for: FixtureBundleMarker.self)
    guard let url = bundle.url(forResource: name, withExtension: ext) else {
        throw FixtureError.missing("\(name).\(ext)")
    }
    return try Data(contentsOf: url)
}

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
