import Foundation
import UIKit

/// Turning the retained diagnostics generations into one file the owner can
/// hand to an agent.
///
/// The assembly is a pure function over *supplied* text: the header, then the
/// rotated generation, then the current one. Nothing here reads the clock, the
/// file system or the bundle — those arrive as parameters — so every rule the
/// export has can be asserted directly.
///
/// The log is read through `DiagnosticsSnapshotSource` and never by downcasting
/// a `DiagnosticsSink`: writing and reading back are separate capabilities on
/// purpose (see `DiagnosticsSink.swift`).
enum DiagnosticsExport {
    /// One file, replaced on every export, rather than one per tap: the share
    /// sheet hands over a URL, and an accumulating Documents directory would be
    /// visible to the user in Files as a growing pile of near-identical logs.
    static let filename = "cue-diagnostics.txt"

    /// What the header says about the binary and the device that wrote the log.
    struct Environment: Sendable, Equatable {
        var build: String
        var deviceModel: String
        var systemVersion: String
    }

    /// Header, then every generation in the order the snapshot source gave
    /// them — oldest first.
    ///
    /// An empty log is a header-only success, not an error: "the app logged
    /// nothing" is itself an answer, and failing the export would leave the
    /// owner with nothing to show for the tap.
    static func assemble(environment: Environment, timestamp: Date, generations: [String]) -> String {
        var text = header(environment: environment, timestamp: timestamp)
        for generation in generations where !generation.isEmpty {
            text += generation
            if !generation.hasSuffix("\n") { text += "\n" }
        }
        return text
    }

    /// The provenance block. Its field syntax matches `DiagnosticsLine` closely
    /// enough to read, but it is deliberately not a record: it describes the
    /// export, not an event.
    static func header(environment: Environment, timestamp: Date) -> String {
        let stamp = timestampText(timestamp)
        var text = "cue diagnostics export\n"
        text += "build=\(environment.build)\n"
        text += "device=\(environment.deviceModel)\n"
        text += "ios=\(environment.systemVersion)\n"
        text += "exported=\(stamp)\n\n"
        return text
    }

    /// Writes atomically over any previous export and answers where it landed.
    @discardableResult
    static func write(_ text: String, toDirectory directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: filename)
        try Data(text.utf8).write(to: url, options: .atomic)
        return url
    }

    /// Flush first, then snapshot, then write.
    ///
    /// The flush is what makes the export worth taking right after a failure:
    /// `record(_:)` is a fence, so awaiting `flush()` guarantees the terminal
    /// record the owner is exporting *because of* is already in the file.
    ///
    /// - Parameter directory: injected, so no test writes to the real Documents
    ///   directory.
    static func export(
        from source: DiagnosticsSnapshotSource,
        flushing sink: DiagnosticsSink,
        environment: Environment,
        timestamp: Date,
        toDirectory directory: URL
    ) async throws -> URL {
        await sink.flush()
        let generations = await source.snapshot()
        let text = assemble(environment: environment, timestamp: timestamp, generations: generations)
        return try write(text, toDirectory: directory)
    }

    /// `Documents/`, so the exported file is also reachable over Files and
    /// iTunes file sharing — the two settings this step adds to the bundle.
    static func defaultDirectory() -> URL {
        (try? FileManager.default.url(
            for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false))
            ?? FileManager.default.temporaryDirectory
    }

    /// Marketing version and build number, the pair that says which binary
    /// wrote a log the owner exports.
    static var buildIdentifier: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = info?["CFBundleVersion"] as? String ?? "unknown"
        return "\(version) (\(build))"
    }

    /// The hardware identifier rather than `UIDevice.model`, which answers
    /// "iPhone" for every iPhone ever made and so cannot distinguish the device
    /// a bug was seen on.
    static var deviceModel: String {
        var system = utsname()
        uname(&system)
        let machine = withUnsafeBytes(of: &system.machine) { raw in
            Array(raw.prefix { $0 != 0 })
        }
        guard let identifier = String(bytes: machine, encoding: .utf8), !identifier.isEmpty else {
            return "unknown"
        }
        return identifier
    }

    @MainActor
    static var current: Environment {
        Environment(
            build: buildIdentifier,
            deviceModel: deviceModel,
            systemVersion: UIDevice.current.systemVersion
        )
    }

    /// Built per call rather than held as a static: `ISO8601DateFormatter` is
    /// not `Sendable`, and an export happens once per tap, so there is nothing
    /// to save by sharing one.
    private static func timestampText(_ timestamp: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: timestamp)
    }
}
