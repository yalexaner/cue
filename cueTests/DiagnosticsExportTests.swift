import Foundation
import Testing

@testable import cue

/// A snapshot source that answers a fixed set of generations, so the assembly
/// is tested without a writer and without touching disk.
private struct StubSnapshotSource: DiagnosticsSnapshotSource {
    let generations: [String]
    func snapshot() async -> [String] { generations }
}

private let testEnvironment = DiagnosticsExport.Environment(
    build: "1.0 (7)", deviceModel: "iPhone17,1", systemVersion: "26.0")

private let testTimestamp = Date(timeIntervalSince1970: 1_700_000_000)

struct DiagnosticsExportTests {
    @Test func headerNamesTheBinaryTheDeviceAndTheMoment() {
        let text = DiagnosticsExport.assemble(
            environment: testEnvironment, timestamp: testTimestamp, generations: [])
        #expect(text.contains("cue diagnostics export"))
        #expect(text.contains("build=1.0 (7)"))
        #expect(text.contains("device=iPhone17,1"))
        #expect(text.contains("ios=26.0"))
        #expect(text.contains("exported=2023-11-14T22:13:20Z"))
    }

    @Test func generationsAppearInTheOrderGiven() throws {
        let text = DiagnosticsExport.assemble(
            environment: testEnvironment,
            timestamp: testTimestamp,
            generations: ["older line\n", "newer line\n"]
        )
        let older = try #require(text.range(of: "older line"))
        let newer = try #require(text.range(of: "newer line"))
        #expect(older.lowerBound < newer.lowerBound)
        let header = try #require(text.range(of: "cue diagnostics export"))
        #expect(header.lowerBound < older.lowerBound)
    }

    @Test func aMissingRotatedGenerationIsNotAnError() {
        let text = DiagnosticsExport.assemble(
            environment: testEnvironment, timestamp: testTimestamp, generations: ["only line\n"])
        #expect(text.contains("only line"))
        #expect(text.contains("build=1.0 (7)"))
    }

    @Test func anEmptyLogYieldsTheHeaderAlone() {
        let header = DiagnosticsExport.header(environment: testEnvironment, timestamp: testTimestamp)
        let empty = DiagnosticsExport.assemble(
            environment: testEnvironment, timestamp: testTimestamp, generations: [])
        let blank = DiagnosticsExport.assemble(
            environment: testEnvironment, timestamp: testTimestamp, generations: ["", ""])
        #expect(empty == header)
        #expect(blank == header)
    }

    @Test func aGenerationWithoutATrailingNewlineStillSeparatesFromTheNext() {
        let text = DiagnosticsExport.assemble(
            environment: testEnvironment,
            timestamp: testTimestamp,
            generations: ["older line", "newer line"]
        )
        #expect(text.contains("older line\nnewer line"))
    }

    @Test func exportFlushesSnapshotsAndWritesToTheInjectedDirectory() async throws {
        try await withTemporaryBaseAsync { base in
            let sink = RecordingDiagnosticsSink()
            let source = StubSnapshotSource(generations: ["previous\n", "current\n"])
            let url = try await DiagnosticsExport.export(
                from: source,
                flushing: sink,
                environment: testEnvironment,
                timestamp: testTimestamp,
                toDirectory: base
            )
            #expect(sink.flushCount == 1)
            #expect(url.lastPathComponent == DiagnosticsExport.filename)
            let written = try String(contentsOf: url, encoding: .utf8)
            #expect(written.contains("previous"))
            #expect(written.contains("current"))
            #expect(written.hasPrefix("cue diagnostics export"))
        }
    }

    @Test func aSecondExportReplacesTheFirst() async throws {
        try await withTemporaryBaseAsync { base in
            let sink = RecordingDiagnosticsSink()
            let first = try await DiagnosticsExport.export(
                from: StubSnapshotSource(generations: ["first run\n"]),
                flushing: sink,
                environment: testEnvironment,
                timestamp: testTimestamp,
                toDirectory: base
            )
            let second = try await DiagnosticsExport.export(
                from: StubSnapshotSource(generations: ["second run\n"]),
                flushing: sink,
                environment: testEnvironment,
                timestamp: testTimestamp,
                toDirectory: base
            )
            #expect(first == second)
            let contents = try FileManager.default.contentsOfDirectory(atPath: base.path(percentEncoded: false))
            #expect(contents == [DiagnosticsExport.filename])
            let written = try String(contentsOf: second, encoding: .utf8)
            #expect(written.contains("second run"))
            #expect(!written.contains("first run"))
        }
    }

    @Test func exportCreatesTheDestinationDirectoryWhenItIsAbsent() async throws {
        try await withTemporaryBaseAsync { base in
            let nested = base.appending(path: "Exports", directoryHint: .isDirectory)
            let url = try await DiagnosticsExport.export(
                from: StubSnapshotSource(generations: []),
                flushing: NoOpDiagnosticsSink(),
                environment: testEnvironment,
                timestamp: testTimestamp,
                toDirectory: nested
            )
            #expect(FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
        }
    }

    @Test func theProductionWriterIsReadableAsASnapshotSource() async throws {
        try await withTemporaryBaseAsync { base in
            let writer = DiagnosticsFileWriter(baseDirectory: base)
            writer.record(DiagnosticsEvent.launch(build: "1.0 (7)").record)
            let url = try await DiagnosticsExport.export(
                from: writer,
                flushing: writer,
                environment: testEnvironment,
                timestamp: testTimestamp,
                toDirectory: base.appending(path: "Exports", directoryHint: .isDirectory)
            )
            let written = try String(contentsOf: url, encoding: .utf8)
            #expect(written.contains(DiagnosticsEvent.launch(build: "1.0 (7)").name))
        }
    }
}
