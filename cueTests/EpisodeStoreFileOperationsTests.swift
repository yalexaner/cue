import Foundation
import Testing

@testable import cue

/// Filename policy and the move/remove/size operations downloads are built on.
///
/// Split from `EpisodeStoreTests` to stay under the 400-line `file_length`
/// warning that `just lint --strict` treats as an error.
struct EpisodeStoreFileOperationsTests {
    // MARK: - downloadFilename(forEnclosureURL:)

    /// One test rather than a parameterized one: the case table would be a
    /// multiline collection literal, which cannot satisfy `swift-format` and
    /// SwiftLint at the same time (AGENTS.md, trailing-comma deadlock).
    @Test func downloadFilenameInfersTheExtension() throws {
        try withTemporaryBase { base in
            let store = EpisodeStore(baseDirectory: base)
            func inferred(_ enclosureURL: String) -> String {
                (store.downloadFilename(forEnclosureURL: enclosureURL) as NSString).pathExtension
            }

            #expect(inferred("https://example.com/audio/ep1.mp3") == "mp3")
            #expect(inferred("https://example.com/audio/ep1.m4a") == "m4a")
            #expect(inferred("https://example.com/audio/ep1.M4A") == "m4a")
            #expect(inferred("https://example.com/audio/ep1.opus") == "opus")

            // the query and fragment must never become the extension
            #expect(inferred("https://example.com/audio/ep1.m4a?token=REDACTED_TEST_TOKEN") == "m4a")
            #expect(inferred("https://example.com/audio/ep1.mp3#t=30") == "mp3")

            // nothing usable to infer from
            #expect(inferred("https://example.com/audio/ep1") == "mp3")
            #expect(inferred("https://example.com/audio/") == "mp3")
            #expect(inferred("") == "mp3")

            // implausible extensions fall back rather than being trusted
            #expect(inferred("https://example.com/ep1.veryverylong") == "mp3")
            #expect(inferred("https://example.com/ep1.m p3") == "mp3")
        }
    }

    @Test func downloadFilenameIsUniqueAndResolvable() throws {
        try withTemporaryBase { base in
            let store = EpisodeStore(baseDirectory: base)

            let first = store.downloadFilename(forEnclosureURL: "https://example.com/ep1.mp3")
            let second = store.downloadFilename(forEnclosureURL: "https://example.com/ep1.mp3")

            #expect(first != second)
            // the generated name must survive the traversal guard
            #expect(throws: Never.self) { try store.url(forRelativeFilename: first) }
        }
    }

    @Test func downloadFilenameDoesNotTouchTheFileSystem() throws {
        try withTemporaryBase { base in
            let store = EpisodeStore(baseDirectory: base)

            _ = store.downloadFilename(forEnclosureURL: "https://example.com/ep1.mp3")

            let directory = try store.episodesDirectory()
            #expect(!FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)))
        }
    }

    // MARK: - moveFile(at:toRelativeFilename:)

    @Test func moveFilePlacesTheFileInEpisodes() throws {
        try withTemporaryBase { base in
            let store = EpisodeStore(baseDirectory: base)
            try store.prepareEpisodesDirectory()
            let source = base.appending(path: "download.tmp", directoryHint: .notDirectory)
            try Data("audio".utf8).write(to: source)

            let destination = try store.moveFile(at: source, toRelativeFilename: "3F2A.mp3")

            try #expect(destination == store.url(forRelativeFilename: "3F2A.mp3"))
            try #expect(store.fileExists(forRelativeFilename: "3F2A.mp3") == true)
            #expect(!FileManager.default.fileExists(atPath: source.path(percentEncoded: false)))
            try #expect(Data(contentsOf: destination) == Data("audio".utf8))
        }
    }

    @Test func moveFileReplacesALeftoverOfTheSameName() throws {
        try withTemporaryBase { base in
            let store = EpisodeStore(baseDirectory: base)
            let directory = try store.prepareEpisodesDirectory()
            try Data("stale".utf8).write(to: directory.appending(path: "3F2A.mp3"))
            let source = base.appending(path: "download.tmp", directoryHint: .notDirectory)
            try Data("fresh".utf8).write(to: source)

            let destination = try store.moveFile(at: source, toRelativeFilename: "3F2A.mp3")

            try #expect(Data(contentsOf: destination) == Data("fresh".utf8))
        }
    }

    @Test(arguments: ["", "..", "nested/3F2A.mp3", "/absolute.mp3"])
    func moveFileRejectsNamesThatEscapeEpisodes(_ filename: String) throws {
        try withTemporaryBase { base in
            let store = EpisodeStore(baseDirectory: base)
            try store.prepareEpisodesDirectory()
            let source = base.appending(path: "download.tmp", directoryHint: .notDirectory)
            try Data("audio".utf8).write(to: source)

            #expect(throws: EpisodeStore.Failure.invalidFilename(filename)) {
                try store.moveFile(at: source, toRelativeFilename: filename)
            }
            // the guard runs before anything is moved, so the temp file is intact
            #expect(FileManager.default.fileExists(atPath: source.path(percentEncoded: false)))
        }
    }

    @Test func moveFileThrowsWhenTheSourceIsMissing() throws {
        try withTemporaryBase { base in
            let store = EpisodeStore(baseDirectory: base)
            try store.prepareEpisodesDirectory()
            let source = base.appending(path: "gone.tmp", directoryHint: .notDirectory)

            #expect(throws: (any Error).self) {
                try store.moveFile(at: source, toRelativeFilename: "3F2A.mp3")
            }
            try #expect(store.fileExists(forRelativeFilename: "3F2A.mp3") == false)
        }
    }

    // MARK: - removeFile(forRelativeFilename:)

    @Test func removeFileDeletesTheFile() throws {
        try withTemporaryBase { base in
            let store = EpisodeStore(baseDirectory: base)
            let directory = try store.prepareEpisodesDirectory()
            try Data("audio".utf8).write(to: directory.appending(path: "3F2A.mp3"))

            try store.removeFile(forRelativeFilename: "3F2A.mp3")

            try #expect(store.fileExists(forRelativeFilename: "3F2A.mp3") == false)
        }
    }

    @Test func removeFileSucceedsWhenTheFileIsAlreadyGone() throws {
        try withTemporaryBase { base in
            let store = EpisodeStore(baseDirectory: base)
            try store.prepareEpisodesDirectory()

            // the goal state is "no file", so a dangling row must still clear
            #expect(throws: Never.self) {
                try store.removeFile(forRelativeFilename: "3F2A.mp3")
            }
        }
    }

    @Test func removeFileSucceedsWhenEpisodesWasNeverCreated() throws {
        try withTemporaryBase { base in
            let store = EpisodeStore(baseDirectory: base)

            #expect(throws: Never.self) {
                try store.removeFile(forRelativeFilename: "3F2A.mp3")
            }
        }
    }

    @Test(arguments: ["", "..", "nested/3F2A.mp3"])
    func removeFileRejectsNamesThatEscapeEpisodes(_ filename: String) throws {
        try withTemporaryBase { base in
            let store = EpisodeStore(baseDirectory: base)

            #expect(throws: EpisodeStore.Failure.invalidFilename(filename)) {
                try store.removeFile(forRelativeFilename: filename)
            }
        }
    }

    // MARK: - fileSize(forRelativeFilename:)

    @Test func fileSizeReportsTheByteCount() throws {
        try withTemporaryBase { base in
            let store = EpisodeStore(baseDirectory: base)
            let directory = try store.prepareEpisodesDirectory()
            let bytes = Data(repeating: 0x41, count: 2048)
            try bytes.write(to: directory.appending(path: "3F2A.mp3"))

            try #expect(store.fileSize(forRelativeFilename: "3F2A.mp3") == 2048)
        }
    }

    @Test func fileSizeIsNilForAMissingFile() throws {
        try withTemporaryBase { base in
            let store = EpisodeStore(baseDirectory: base)
            try store.prepareEpisodesDirectory()

            try #expect(store.fileSize(forRelativeFilename: "3F2A.mp3") == nil)
        }
    }

    @Test(arguments: ["", "..", "nested/3F2A.mp3"])
    func fileSizeRejectsNamesThatEscapeEpisodes(_ filename: String) throws {
        try withTemporaryBase { base in
            let store = EpisodeStore(baseDirectory: base)

            #expect(throws: EpisodeStore.Failure.invalidFilename(filename)) {
                try store.fileSize(forRelativeFilename: filename)
            }
        }
    }

    @Test func fileSizeThrowsWhenTheFileSystemCannotAnswer() throws {
        try withTemporaryBase { base in
            let store = EpisodeStore(baseDirectory: base)
            let directory = try store.prepareEpisodesDirectory()
            try Data("audio".utf8).write(to: directory.appending(path: "3F2A.mp3"))
            let path = directory.path(percentEncoded: false)

            // an indeterminate answer must never be summed into a disk total as zero
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: path)
            defer {
                try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
            }

            #expect(throws: (any Error).self) {
                try store.fileSize(forRelativeFilename: "3F2A.mp3")
            }
        }
    }

    // MARK: - withTemporaryBaseAsync

    @Test func asyncTemporaryBaseIsUsableAndRemoved() async throws {
        var captured: URL?
        try await withTemporaryBaseAsync { base in
            captured = base
            let store = EpisodeStore(baseDirectory: base)
            let directory = try store.prepareEpisodesDirectory()
            await Task.yield()
            #expect(FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)))
        }

        let path = try #require(captured).path(percentEncoded: false)
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    /// The removal is a `defer`, and the doc comment promises it covers a body
    /// that throws — which is the path most of these tests take when they fail.
    /// Left uncovered, a `try` moved above the `defer` would leak a directory
    /// per failing run and nothing would say so.
    @Test func asyncTemporaryBaseIsRemovedWhenTheBodyThrows() async throws {
        var captured: URL?
        var thrown: (any Error)?
        do {
            try await withTemporaryBaseAsync { base in
                captured = base
                throw StubTransportError.offline
            }
        } catch {
            thrown = error
        }

        #expect(thrown as? StubTransportError == .offline)
        let path = try #require(captured).path(percentEncoded: false)
        #expect(!FileManager.default.fileExists(atPath: path))
    }
}
