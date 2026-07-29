import Testing

@testable import cue

struct SmokeTests {
    @Test func testableImportResolves() {
        #expect(Bool(true))
    }
}
