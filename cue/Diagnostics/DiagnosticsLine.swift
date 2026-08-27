import Foundation

/// The on-disk representation of one record: a single line of tab-separated
/// `key=value` pairs.
///
/// A pure formatter — it takes its timestamp as an input rather than reading
/// the clock, so every property below is assertable without freezing time.
///
/// Escaping is reversible, which matters more than it looks: a feed controls
/// the text that reaches several of these fields, and an unescaped newline
/// would let a publisher forge log lines. `unescape(_:)` exists so that
/// round-tripping is a property a test can state rather than a claim.
enum DiagnosticsLine {
    /// Tab, so an escaped value can never contain one unescaped.
    static let fieldDelimiter = "\t"

    static func format(timestamp: Date, record: DiagnosticsRecord) -> String {
        var parts: [String] = []
        parts.append("ts=" + escape(timestampText(timestamp)))
        parts.append("level=" + escape(record.level.rawValue))
        parts.append("category=" + escape(record.category.rawValue))
        parts.append("event=" + escape(record.event))
        for field in record.fields {
            parts.append(escape(field.key) + "=" + escape(field.value))
        }
        return parts.joined(separator: fieldDelimiter)
    }

    static func timestampText(_ date: Date) -> String {
        date.ISO8601Format(.init(includingFractionalSeconds: true))
    }

    /// Backslash escapes for the delimiter, the separator, the escape
    /// character itself and every control scalar.
    static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.unicodeScalars.count)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\\":
                out += "\\\\"
            case "=":
                out += "\\="
            case "\n":
                out += "\\n"
            case "\r":
                out += "\\r"
            case "\t":
                out += "\\t"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7f {
                    out += String(format: "\\u{%02x}", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out
    }

    /// The inverse of `escape(_:)`. An unrecognised escape is left as written,
    /// which cannot happen for text this file produced.
    static func unescape(_ text: String) -> String {
        var out = ""
        let scalars = Array(text.unicodeScalars)
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            guard scalar == "\\", index + 1 < scalars.count else {
                out.unicodeScalars.append(scalar)
                index += 1
                continue
            }
            let next = scalars[index + 1]
            index += 2
            switch next {
            case "\\":
                out += "\\"
            case "=":
                out += "="
            case "n":
                out += "\n"
            case "r":
                out += "\r"
            case "t":
                out += "\t"
            case "u":
                guard index < scalars.count, scalars[index] == "{",
                    let closing = scalars[index...].firstIndex(of: "}"),
                    let value = UInt32(String(String.UnicodeScalarView(scalars[(index + 1)..<closing])), radix: 16),
                    let decoded = Unicode.Scalar(value)
                else {
                    out += "\\u"
                    continue
                }
                out.unicodeScalars.append(decoded)
                index = closing + 1
            default:
                out += "\\"
                out.unicodeScalars.append(next)
            }
        }
        return out
    }
}
