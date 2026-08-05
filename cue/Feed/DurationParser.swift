import Foundation

/// Parses the `itunes:duration` element into seconds (spec §6).
///
/// Feeds in the wild write the value three ways — bare seconds (`45`, `10584`),
/// `MM:SS` and `HH:MM:SS` — so all three are accepted. Anything else is a
/// duration this app refuses to guess at: the value is optional in the model,
/// and a wrong number is worse than no number.
///
/// A caseless enum rather than a struct: there is no state to carry.
enum DurationParser {
    /// Seconds for a valid `SS`, `MM:SS` or `HH:MM:SS` string, otherwise `nil`.
    ///
    /// Surrounding whitespace is trimmed first. Every component must be
    /// non-empty ASCII digits, which rejects signs (`-5`) and fractions
    /// (`1:00:00.5`) without a separate check. The seconds component of a clock
    /// string must be under 60, as must the minutes of an `HH:MM:SS` string —
    /// `12:99` is not 12 minutes 99 seconds, it is a feed bug.
    static func seconds(from string: String) -> TimeInterval? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let components = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(components.count) else { return nil }

        var values: [Int] = []
        for component in components {
            guard !component.isEmpty, component.allSatisfy(\.isASCIIDigit), let value = Int(component) else {
                return nil
            }
            values.append(value)
        }

        // arithmetic in TimeInterval, not Int. A digit run wider than Int is
        // already gone — Int(component) returned nil above. What survives is a
        // representable absurdity such as Int.max, and scaling that by 3600 in
        // Int would trap. Converting first yields a useless number instead,
        // which is the failure this parser prefers.
        switch values.count {
        case 1:
            return TimeInterval(values[0])
        case 2:
            guard values[1] < 60 else { return nil }
            return TimeInterval(values[0]) * 60 + TimeInterval(values[1])
        default:
            guard values[1] < 60, values[2] < 60 else { return nil }
            return TimeInterval(values[0]) * 3600 + TimeInterval(values[1]) * 60 + TimeInterval(values[2])
        }
    }
}

extension Character {
    /// `isNumber` accepts Arabic-Indic digits and the like; a duration is ASCII only.
    fileprivate var isASCIIDigit: Bool {
        ("0"..."9").contains(self)
    }
}
