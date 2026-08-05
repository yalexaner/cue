import Foundation
import Testing

@testable import cue

/// `itunes:duration` shapes accepted and rejected (spec §6).
struct DurationParserTests {
    // MARK: - Accepted formats

    @Test(arguments: [("45", 45.0), ("10584", 10584.0), ("12:34", 754.0), ("1:03:33", 3813.0), ("01:02:03", 3723.0)])
    func secondsParsesEveryDurationShapeFoundInFeeds(_ input: String, _ expected: TimeInterval) {
        #expect(DurationParser.seconds(from: input) == expected)
    }

    @Test func secondsTrimsSurroundingWhitespace() {
        #expect(DurationParser.seconds(from: "  12:34 \n") == 754)
    }

    /// Only the seconds component of `MM:SS` is bounded — a feed writing a
    /// 90-minute episode as `90:00` means it, whereas the minutes of `HH:MM:SS`
    /// are bounded and `1:99:00` is rejected. Pinned separately from the
    /// shapes-found-in-feeds cases because this one is not from the fixtures.
    @Test func secondsAllowsMinutesAbove59WhenHoursAreOmitted() {
        #expect(DurationParser.seconds(from: "90:00") == 5400)
    }

    // MARK: - Rejected input

    @Test(arguments: ["abc", "1:2:3:4", "-5", "12:99", "1:00:00.5", "", "  ", "1:99:00", "12:", ":34", "1 2"])
    func secondsReturnsNilForAnythingElse(_ input: String) {
        #expect(DurationParser.seconds(from: input) == nil)
    }
}
