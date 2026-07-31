import Foundation
import Testing

@testable import cue

struct EpisodeStoreTests {
    // MARK: - prepareEpisodesDirectory

    @Test func prepareEpisodesDirectoryCreatesTheDirectory() throws {
        try withTemporaryBase { base in
            let store = EpisodeStore(baseDirectory: base)
            let directory = try store.prepareEpisodesDirectory()

            #expect(directory.lastPathComponent == "Episodes")
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(
                atPath: directory.path(percentEncoded: false),
                isDirectory: &isDirectory
            )
            #expect(exists)
            #expect(isDirectory.boolValue)
        }
    }

    @Test func prepareEpisodesDirectoryCreatesIntermediateDirectories() throws {
        try withTemporaryBase { base in
            let missing = base.appending(path: "one/two", directoryHint: .isDirectory)
            let store = EpisodeStore(baseDirectory: missing)

            let directory = try store.prepareEpisodesDirectory()

            #expect(FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)))
        }
    }

    @Test func prepareEpisodesDirectoryExcludesItFromBackup() throws {
        try withTemporaryBase { base in
            let store = EpisodeStore(baseDirectory: base)
            let directory = try store.prepareEpisodesDirectory()

            let values = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
            #expect(values.isExcludedFromBackup == true)
        }
    }

    @Test func prepareEpisodesDirectoryIsIdempotent() throws {
        try withTemporaryBase { base in
            let store = EpisodeStore(baseDirectory: base)
            let first = try store.prepareEpisodesDirectory()

            // a file placed in the directory must survive a second call
            let marker = first.appending(path: "marker", directoryHint: .notDirectory)
            try Data().write(to: marker)

            let second = try store.prepareEpisodesDirectory()

            #expect(first == second)
            #expect(FileManager.default.fileExists(atPath: marker.path(percentEncoded: false)))
            let values = try second.resourceValues(forKeys: [.isExcludedFromBackupKey])
            #expect(values.isExcludedFromBackup == true)
        }
    }

    @Test func prepareEpisodesDirectoryThrowsWhenAFileOccupiesThePath() throws {
        try withTemporaryBase { base in
            let store = EpisodeStore(baseDirectory: base)
            // a plain file where the directory belongs must surface, not be skipped
            try Data().write(to: base.appending(path: "Episodes", directoryHint: .notDirectory))

            #expect(throws: (any Error).self) {
                try store.prepareEpisodesDirectory()
            }
        }
    }

    // MARK: - episodesDirectory

    @Test func episodesDirectoryDoesNotTouchTheFileSystem() throws {
        try withTemporaryBase { base in
            let store = EpisodeStore(baseDirectory: base)

            let directory = try store.episodesDirectory()

            #expect(directory.lastPathComponent == "Episodes")
            #expect(!FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)))
        }
    }

    @Test func episodesDirectoryDefaultsToApplicationSupport() throws {
        // the one test that exercises the shipped path: baseDirectory == nil
        let directory = try EpisodeStore().episodesDirectory()
        let path = directory.path(percentEncoded: false)

        #expect(directory.lastPathComponent == "Episodes")
        #expect(directory.deletingLastPathComponent().lastPathComponent == "Application Support")
        // Caches is evicted under storage pressure — the failure this app designs out
        #expect(!path.contains("/Caches/"))
    }

    // MARK: - url(forRelativeFilename:)

    @Test func urlForRelativeFilenameComposesDirectoryAndName() throws {
        try withTemporaryBase { base in
            let store = EpisodeStore(baseDirectory: base)
            let directory = try store.episodesDirectory()

            let url = try store.url(forRelativeFilename: "3F2A.mp3")

            #expect(url.lastPathComponent == "3F2A.mp3")
            #expect(
                url.deletingLastPathComponent().path(percentEncoded: false)
                    == directory.path(percentEncoded: false))
        }
    }

    @Test func urlForRelativeFilenameIsStableAcrossCalls() throws {
        try withTemporaryBase { base in
            let store = EpisodeStore(baseDirectory: base)

            let first = try store.url(forRelativeFilename: "3F2A.mp3")
            let second = try store.url(forRelativeFilename: "3F2A.mp3")

            #expect(first == second)
        }
    }

    @Test func distinctFilenamesResolveToDistinctURLs() throws {
        try withTemporaryBase { base in
            let store = EpisodeStore(baseDirectory: base)

            let first = try store.url(forRelativeFilename: "one.mp3")
            let second = try store.url(forRelativeFilename: "two.mp3")

            #expect(first != second)
            #expect(first.deletingLastPathComponent() == second.deletingLastPathComponent())
        }
    }

    @Test(arguments: ["", "..", ".", "../escaped.mp3", "nested/3F2A.mp3", "/absolute.mp3"])
    func urlRejectsNamesThatAreNotASinglePathComponent(_ filename: String) throws {
        try withTemporaryBase { base in
            let store = EpisodeStore(baseDirectory: base)

            #expect(throws: EpisodeStore.Failure.invalidFilename(filename)) {
                try store.url(forRelativeFilename: filename)
            }
            #expect(throws: EpisodeStore.Failure.invalidFilename(filename)) {
                try store.fileExists(forRelativeFilename: filename)
            }
        }
    }

    // MARK: - fileExists(forRelativeFilename:)

    @Test func fileExistsIsTrueOnlyForARegularFile() throws {
        try withTemporaryBase { base in
            let store = EpisodeStore(baseDirectory: base)
            let directory = try store.prepareEpisodesDirectory()

            try #expect(store.fileExists(forRelativeFilename: "3F2A.mp3") == false)

            try Data("audio".utf8).write(to: directory.appending(path: "3F2A.mp3"))
            try #expect(store.fileExists(forRelativeFilename: "3F2A.mp3") == true)
        }
    }

    @Test func fileExistsIsFalseForADirectoryOfThatName() throws {
        try withTemporaryBase { base in
            let store = EpisodeStore(baseDirectory: base)
            let directory = try store.prepareEpisodesDirectory()
            try FileManager.default.createDirectory(
                at: directory.appending(path: "3F2A.mp3", directoryHint: .isDirectory),
                withIntermediateDirectories: true
            )

            try #expect(store.fileExists(forRelativeFilename: "3F2A.mp3") == false)
        }
    }

    @Test func fileExistsThrowsWhenTheFileSystemCannotAnswer() throws {
        try withTemporaryBase { base in
            let store = EpisodeStore(baseDirectory: base)
            let directory = try store.prepareEpisodesDirectory()
            try Data("audio".utf8).write(to: directory.appending(path: "3F2A.mp3"))
            let path = directory.path(percentEncoded: false)

            // no search permission makes the lookup fail with EACCES — the
            // indeterminate case FileManager.fileExists reports as a plain false
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: path)
            defer {
                // restore before the temporary base is removed
                try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
            }

            #expect(throws: (any Error).self) {
                try store.fileExists(forRelativeFilename: "3F2A.mp3")
            }
        }
    }
}
