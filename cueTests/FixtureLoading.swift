import Foundation

private final class FixtureBundleMarker {}

enum FixtureError: Error {
    case missing(String)
}

/// Loads a committed fixture from the test bundle by name and extension.
///
/// Shared by every test that reads `cueTests/Fixtures/`, so no test resolves a
/// fixture from a path on disk. The bundle is located through a private marker
/// class rather than `Bundle.main`, which is the test runner, not the test target.
func fixtureData(named name: String, withExtension ext: String) throws -> Data {
    let bundle = Bundle(for: FixtureBundleMarker.self)
    guard let url = bundle.url(forResource: name, withExtension: ext) else {
        throw FixtureError.missing("\(name).\(ext)")
    }
    return try Data(contentsOf: url)
}
