import Foundation
import Testing

@testable import cue

@Suite("Diagnostics file writer")
struct DiagnosticsFileWriterTests {
    private func makeRecord(_ event: String) -> DiagnosticsRecord {
        DiagnosticsRecord(category: .downloads, event: event)
    }

    @Test("a record followed by a flush is always in the snapshot")
    func recordIsFencedBeforeFlush() async throws {
        try await withTemporaryBaseAsync { base in
            let writer = DiagnosticsFileWriter(baseDirectory: base)
            writer.record(makeRecord("download.finished"))
            await writer.flush()
            let text = await writer.snapshot().joined()
            #expect(text.contains("event=download.finished"))
        }
    }

    @Test("the fence holds under contention")
    func recordIsFencedUnderContention() async throws {
        try await withTemporaryBaseAsync { base in
            let writer = DiagnosticsFileWriter(baseDirectory: base)
            await withTaskGroup(of: Void.self) { group in
                for index in 0..<64 {
                    group.addTask { writer.record(DiagnosticsRecord(category: .downloads, event: "e\(index)")) }
                }
                await group.waitForAll()
            }
            await writer.flush()
            let text = await writer.snapshot().joined()
            for index in 0..<64 {
                #expect(text.contains("event=e\(index)"))
            }
        }
    }

    @Test("records are written in the order they were enqueued")
    func recordsKeepTheirOrder() async throws {
        try await withTemporaryBaseAsync { base in
            let writer = DiagnosticsFileWriter(baseDirectory: base)
            for index in 0..<20 {
                writer.record(DiagnosticsRecord(category: .downloads, event: "e\(index)"))
            }
            await writer.flush()
            let lines = await writer.snapshot().joined().split(separator: "\n").map(String.init)
            #expect(lines.count == 20)
            for (index, line) in lines.enumerated() {
                #expect(line.hasSuffix("event=e\(index)"))
            }
        }
    }

    /// One formatted line plus its newline. Every event name below is the same
    /// length, so a cap expressed as a multiple of this is exact.
    private func lineBytes() -> Int {
        DiagnosticsLine.format(timestamp: Date(), record: makeRecord("e0")).utf8.count + 1
    }

    @Test("crossing the cap rotates and the previous generation survives")
    func crossingTheCapRotates() async throws {
        try await withTemporaryBaseAsync { base in
            let writer = DiagnosticsFileWriter(baseDirectory: base, byteCap: lineBytes() * 2)
            for event in ["e1", "e2", "e3"] {
                writer.record(makeRecord(event))
                await writer.flush()
            }
            let generations = await writer.snapshot()
            #expect(generations.count == 2)
            let previous = try #require(generations.first)
            let current = try #require(generations.last)
            #expect(previous.contains("event=e1"))
            #expect(previous.contains("event=e2"))
            #expect(current.contains("event=e3"))
            #expect(!current.contains("event=e1"))
        }
    }

    @Test("a third generation is discarded")
    func thirdGenerationIsDiscarded() async throws {
        try await withTemporaryBaseAsync { base in
            let writer = DiagnosticsFileWriter(baseDirectory: base, byteCap: lineBytes() * 2)
            for event in ["e1", "e2", "e3", "e4"] {
                writer.record(makeRecord(event))
                await writer.flush()
            }
            let text = await writer.snapshot().joined()
            #expect(!text.contains("event=e1"))
            #expect(!text.contains("event=e2"))
            #expect(text.contains("event=e3"))
            #expect(text.contains("event=e4"))
        }
    }

    @Test("a writer whose directory cannot be created still returns normally")
    func unwritableDirectoryIsSurvivable() async throws {
        try await withTemporaryBaseAsync { base in
            let blocking = base.appending(path: "blocking")
            try Data("not a directory".utf8).write(to: blocking)
            let writer = DiagnosticsFileWriter(baseDirectory: blocking.appending(path: "logs"))
            writer.record(makeRecord("download.failed"))
            await writer.flush()
            let generations = await writer.snapshot()
            #expect(generations.isEmpty)
        }
    }

    @Test("a directory that could not be created is retried, not latched away")
    func unwritableDirectoryRecovers() async throws {
        try await withTemporaryBaseAsync { base in
            // a regular file where the parent directory belongs, so the create
            // fails the way a protected-data window or a full volume does
            let blocking = base.appending(path: "blocking")
            try Data("not a directory".utf8).write(to: blocking)
            let writer = DiagnosticsFileWriter(baseDirectory: blocking.appending(path: "logs"))
            writer.record(makeRecord("download.failed"))
            await writer.flush()
            #expect(await writer.snapshot().isEmpty)

            // the obstruction clears — as it does at first unlock — and the
            // very next record must land. Latching the attempt rather than the
            // success leaves the log dead for the rest of the process, in
            // exactly the scenario it exists to capture.
            try FileManager.default.removeItem(at: blocking)
            writer.record(makeRecord("download.finished"))
            await writer.flush()
            let recovered = await writer.snapshot()
            #expect(recovered.count == 1)
            #expect(recovered[0].contains("event=download.finished"))
        }
    }

    /// Reopening an existing log appends to it rather than overwriting its head.
    ///
    /// `FileHandle(forWritingTo:)` opens at offset 0, so the seek in
    /// `openHandle()` is the whole of what makes this an appender — and a
    /// swallowed seek failure would cache a handle at the head of the file,
    /// overwriting earlier records and measuring the byte cap from a size the
    /// file does not have. The reopen happens for real on every device: the
    /// handle is closed after a failed append and after every rotation.
    @Test("a reopened log is appended to, not overwritten")
    func reopeningAppends() async throws {
        try await withTemporaryBaseAsync { base in
            let directory = base.appending(path: "logs", directoryHint: .isDirectory)
            let first = DiagnosticsFileWriter(baseDirectory: directory, byteCap: 1024 * 1024)
            first.record(makeRecord("download.requested"))
            await first.flush()

            let second = DiagnosticsFileWriter(baseDirectory: directory, byteCap: 1024 * 1024)
            second.record(makeRecord("download.finished"))
            await second.flush()

            let text = await second.snapshot().joined()
            #expect(text.contains("event=download.requested"))
            #expect(text.contains("event=download.finished"))
            #expect(text.split(separator: "\n").count == 2)
        }
    }

    @Test("the no-op sink accepts records and flushes")
    func noOpSinkDoesNothing() async {
        let sink = NoOpDiagnosticsSink()
        sink.record(DiagnosticsRecord(category: .storage, event: "e"))
        await sink.flush()
    }

    /// The property that actually keeps every other suite off disk is not that
    /// `NoOpDiagnosticsSink` writes nothing — it holds no path — but that a
    /// service constructed without a sink gets one. Asserted on the constructed
    /// instance rather than on the default expression, which would only restate
    /// the declaration and would stay green if the default were swapped for a
    /// writer over the real Application Support directory.
    @Test("a service built without a sink gets the no-op")
    @MainActor
    func theDefaultSinkIsTheNoOp() throws {
        let context = try makeContext()
        let manager = DownloadManager(context: context, transport: failingFileTransport())
        #expect(manager.diagnostics is NoOpDiagnosticsSink)
        let service = FeedService(context: context, transport: failingTransport())
        #expect(service.diagnostics is NoOpDiagnosticsSink)
    }

    /// The log lives in `Application Support/Diagnostics/`, never `Caches/`:
    /// iOS evicts caches under storage pressure, and a log that disappears
    /// before it can be exported explains nothing. The export goes to
    /// `Documents/` instead, which is what makes the `UIFileSharingEnabled` and
    /// `LSSupportsOpeningDocumentsInPlace` pair mean anything.
    @Test("the log directory is Application Support, and the export is Documents")
    func defaultDirectoriesAreTheDurableOnes() {
        let log = DiagnosticsFileWriter.defaultDirectory().path(percentEncoded: false)
        // composed with `directoryHint: .isDirectory`, so it carries a trailing slash
        #expect(log.hasSuffix("/Diagnostics/"))
        #expect(log.contains("Application Support"))
        #expect(!log.contains("Caches"))

        let export = DiagnosticsExport.defaultDirectory().path(percentEncoded: false)
        #expect(export.contains("Documents"))
        #expect(!export.contains("Caches"))
    }

    /// A rotation that cannot move the file loses nothing and is retried, so a
    /// device that was briefly unable to rotate does not stay unrotated.
    ///
    /// This is what the `catch` in `rotate()` is for: the records written while
    /// it kept failing are still in the current generation, and the first append
    /// after the obstacle clears rotates them into the previous one.
    @Test("a rotation that cannot move the file is retried, losing nothing")
    func failedRotationIsRetried() async throws {
        try await withTemporaryBaseAsync { base in
            let directory = base.appending(path: "logs", directoryHint: .isDirectory)
            // comfortably above one line, so the first record does not rotate
            let writer = DiagnosticsFileWriter(baseDirectory: directory, byteCap: 1024)
            writer.record(makeRecord("download.failed"))
            await writer.flush()

            // renaming a file needs write permission on its directory, so this
            // is a rotation that fails while the append itself still works
            let path = directory.path(percentEncoded: false)
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: path)
            for _ in 0..<20 { writer.record(makeRecord("download.first_byte")) }
            await writer.flush()

            // nothing was lost to the failed move: it is all still current
            let blocked = await writer.snapshot()
            #expect(blocked.count == 1)
            #expect(blocked[0].contains("download.failed"))
            #expect(blocked[0].contains("download.first_byte"))

            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
            writer.record(makeRecord("download.finished"))
            await writer.flush()
            writer.record(makeRecord("download.deleted"))
            await writer.flush()

            // the retry took: the blocked records are in the previous
            // generation and the current one carries on
            let recovered = await writer.snapshot()
            #expect(recovered.count == 2)
            #expect(recovered[0].contains("download.first_byte"))
            #expect(recovered[1].contains("download.deleted"))
        }
    }

    /// A rotation whose move fails keeps the generation it was about to replace.
    ///
    /// Discarding the retained generation first and moving second means a move
    /// that throws leaves neither: no previous generation and nothing that
    /// replaced it, against a class that promises one. The current file is
    /// unlinked from under the open handle here, which is the cheapest way to
    /// make the move fail while the delete before it would have succeeded.
    @Test("a rotation whose move fails keeps the previous generation")
    func failedRotationKeepsThePreviousGeneration() async throws {
        try await withTemporaryBaseAsync { base in
            let writer = DiagnosticsFileWriter(baseDirectory: base, byteCap: lineBytes() * 2)
            for event in ["e1", "e2", "e3"] {
                writer.record(makeRecord(event))
                await writer.flush()
            }
            // e1 and e2 rotated into the previous generation; e3 opened a new
            // current one, whose handle survives the file going away
            #expect(await writer.snapshot().count == 2)
            try FileManager.default.removeItem(at: base.appending(path: DiagnosticsFileWriter.currentFilename))

            writer.record(makeRecord("e4"))
            await writer.flush()

            let generations = await writer.snapshot()
            let previous = try #require(generations.first)
            #expect(previous.contains("event=e1"))
            #expect(previous.contains("event=e2"))
        }
    }
}
