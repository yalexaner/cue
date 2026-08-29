import Foundation
import OSLog

/// The one production `DiagnosticsSink`: an append-only text file that
/// survives relaunch, plus one retained previous generation.
///
/// A file rather than `OSLogStore(scope: .currentProcessIdentifier)` because
/// the transfers this exists to explain are precisely the ones that finish in
/// a *different* process than the one that started them.
///
/// Everything that touches the file — append, rotate, read back — runs on one
/// actor, so rotation cannot race a held handle and no write happens on the
/// main actor or the session's delegate queue. What the actor does *not* give
/// on its own is ordering against a later `flush()`: an unstructured task
/// awaiting the actor can be outrun by the flush that follows it. So records
/// land in a lock-protected mailbox synchronously inside `record(_:)`, and the
/// actor drains that mailbox itself — which makes `record(_:)` a fence and
/// makes the drain order actor-serialized rather than task-scheduling order.
final class DiagnosticsFileWriter: DiagnosticsSink, DiagnosticsSnapshotSource {
    static let defaultByteCap = 1_048_576
    static let currentFilename = "diagnostics.log"
    static let previousFilename = "diagnostics-previous.log"

    private let mailbox = Mailbox()
    private let store: Store
    private let now: @Sendable () -> Date

    /// - Parameters:
    ///   - baseDirectory: injected so no test writes to the real Application
    ///     Support directory.
    ///   - byteCap: rotate once the current generation reaches this size.
    ///   - now: injected so a formatter test never has to freeze the clock.
    init(
        baseDirectory: URL,
        byteCap: Int = DiagnosticsFileWriter.defaultByteCap,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = Store(directory: baseDirectory, mailbox: mailbox, byteCap: byteCap)
        self.now = now
    }

    /// `Application Support/Diagnostics/`, composed only — the directory is
    /// created by the writer's own actor on first append.
    ///
    /// Never `Caches/`: iOS evicts that under storage pressure, and a log that
    /// disappears before it can be exported explains nothing. Falls back to the
    /// temporary directory rather than throwing, because a launch must not fail
    /// over a log file.
    static func defaultDirectory() -> URL {
        let base =
            (try? FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil,
                create: false)) ?? FileManager.default.temporaryDirectory
        return base.appending(path: "Diagnostics", directoryHint: .isDirectory)
    }

    func record(_ record: DiagnosticsRecord) {
        mailbox.enqueue(DiagnosticsLine.format(timestamp: now(), record: record))
        let store = store
        Task { await store.drain() }
    }

    func flush() async {
        await store.drain()
    }

    func snapshot() async -> [String] {
        await store.snapshot()
    }
}

/// FIFO handoff between the calling thread and the writer's actor.
///
/// `take()` is called *from* the actor rather than by the caller, so two
/// in-flight drains cannot reorder each other's batches.
private final class Mailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func enqueue(_ line: String) {
        lock.lock()
        lines.append(line)
        lock.unlock()
    }

    func take() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        let taken = lines
        lines = []
        return taken
    }
}

/// The serial owner of the file handle.
private actor Store {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "dev.yachmenev.cue",
        category: "storage"
    )

    let currentURL: URL
    let previousURL: URL

    private let directory: URL
    private let mailbox: Mailbox
    private let byteCap: Int
    private var handle: FileHandle?
    private var currentSize = 0
    /// Latched only once the directory actually exists. Setting it before the
    /// attempt means one transient failure — a container that is briefly
    /// unwritable, a full volume — permanently disables the log: the create is
    /// never retried, every later `createFile` and `FileHandle` fails, and the
    /// subsystem whose whole purpose is capturing a rare failure goes quiet for
    /// the rest of the run. `withIntermediateDirectories` is a no-op once the
    /// directory is there, so retrying costs nothing on the happy path.
    private var prepared = false
    /// Latches a failed rotation so the retry on every append does not emit an
    /// `os_log` line of its own each time.
    private var rotationFailed = false
    /// The same latch for a handle that cannot be opened. `handle` stays `nil`
    /// on failure, so the open is retried on *every* record; unlatched, an
    /// unwritable container turns each one into an `os_log` line and fills the
    /// device log with the noise this file exists to keep out of it.
    private var openFailed = false
    /// The `os_log` latch for a directory that cannot be created, held
    /// separately from `prepared` so the create is retried on every record
    /// while the failure is still logged only once per streak.
    private var directoryFailed = false

    init(directory: URL, mailbox: Mailbox, byteCap: Int) {
        self.directory = directory
        self.mailbox = mailbox
        self.byteCap = byteCap
        self.currentURL = directory.appending(path: DiagnosticsFileWriter.currentFilename)
        self.previousURL = directory.appending(path: DiagnosticsFileWriter.previousFilename)
    }

    func drain() {
        let lines = mailbox.take()
        guard !lines.isEmpty else { return }
        let text = lines.map { $0 + "\n" }.joined()
        append(Data(text.utf8))
    }

    /// Decoded lossily on purpose. A write that failed part-way — the volume
    /// filled, which is exactly the condition worth exporting — can leave a torn
    /// multi-byte sequence at the end of a generation, and a strict UTF-8 read
    /// answers that by throwing, which `try?` turns into "this generation does
    /// not exist". A damaged tail must cost one character, not every record of
    /// the run that failed.
    func snapshot() -> [String] {
        drain()
        try? handle?.synchronize()
        var generations: [String] = []
        // the failable initialiser `optional_data_string_conversion` prefers is
        // the exact thing being avoided: it answers `nil` for the whole
        // generation over one torn byte
        if let previous = try? Data(contentsOf: previousURL) {
            // swiftlint:disable:next optional_data_string_conversion
            generations.append(String(decoding: previous, as: UTF8.self))
        }
        if let current = try? Data(contentsOf: currentURL) {
            // swiftlint:disable:next optional_data_string_conversion
            generations.append(String(decoding: current, as: UTF8.self))
        }
        return generations
    }

    /// A write failure degrades to `os_log` and is otherwise swallowed:
    /// logging must never fail the caller that was only trying to download an
    /// episode.
    private func append(_ data: Data) {
        guard let handle = openHandle() else { return }
        do {
            try handle.write(contentsOf: data)
            currentSize += data.count
        } catch {
            Self.logger.error("diagnostics append failed: \(error.localizedDescription, privacy: .public)")
            closeHandle()
            return
        }
        if currentSize >= byteCap { rotate() }
    }

    private func openHandle() -> FileHandle? {
        if let handle { return handle }
        if !prepared {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                prepared = true
                directoryFailed = false
            } catch {
                if !directoryFailed {
                    directoryFailed = true
                    Self.logger.error(
                        "diagnostics directory unavailable: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        if !FileManager.default.fileExists(atPath: currentURL.path(percentEncoded: false)) {
            FileManager.default.createFile(atPath: currentURL.path(percentEncoded: false), contents: nil)
        }
        guard let opened = try? FileHandle(forWritingTo: currentURL) else {
            if !openFailed {
                openFailed = true
                Self.logger.error("diagnostics file unavailable")
            }
            return nil
        }
        // `FileHandle(forWritingTo:)` opens at offset 0, so this seek is what
        // makes the writer an appender rather than an overwriter. A swallowed
        // failure would cache a handle sitting at the head of an existing log:
        // every later record would overwrite what is already there, and the
        // byte cap would be measured from a size the file does not have, so it
        // could reach roughly twice `byteCap` before rotating. Treat it as a
        // failed open instead, so the next record retries.
        guard let end = try? opened.seekToEnd() else {
            try? opened.close()
            if !openFailed {
                openFailed = true
                Self.logger.error("diagnostics file unavailable")
            }
            return nil
        }
        openFailed = false
        currentSize = Int(end)
        handle = opened
        return opened
    }

    private func closeHandle() {
        try? handle?.close()
        handle = nil
    }

    /// One previous generation is kept; an older one is discarded.
    ///
    /// `currentSize` is reset only when the move actually happened. Zeroing it
    /// after a failure tells the writer an oversized file is empty, which grants
    /// another whole `byteCap` of growth before the next attempt — repeat that
    /// and the bound the file is supposed to have is gone entirely. Keeping the
    /// size means the rotation is retried on the next append instead, so the
    /// failure is logged once per streak rather than once per record.
    private func rotate() {
        closeHandle()
        let manager = FileManager.default
        // the retained generation is moved aside rather than deleted outright:
        // a remove that succeeds followed by a move that throws — the current
        // file unlinked from under the writer, a volume that went read-only
        // between the two calls — would leave no previous generation at all,
        // and one is promised. Staging makes the failure path restorable.
        let stagedURL = previousURL.appendingPathExtension("staged")
        var staged = false
        do {
            try? manager.removeItem(at: stagedURL)
            if manager.fileExists(atPath: previousURL.path(percentEncoded: false)) {
                try manager.moveItem(at: previousURL, to: stagedURL)
                staged = true
            }
            try manager.moveItem(at: currentURL, to: previousURL)
            if staged { try? manager.removeItem(at: stagedURL) }
            currentSize = 0
            rotationFailed = false
        } catch {
            // restored only if the slot is genuinely empty, so a move that
            // partly landed is never overwritten by the generation it replaced
            if staged, !manager.fileExists(atPath: previousURL.path(percentEncoded: false)) {
                try? manager.moveItem(at: stagedURL, to: previousURL)
            }
            if !rotationFailed {
                rotationFailed = true
                Self.logger.error("diagnostics rotation failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
