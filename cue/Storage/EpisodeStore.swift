import Foundation

/// Resolves on-disk locations for downloaded episode audio.
///
/// The database stores a relative filename only (spec §5); the absolute URL is
/// rebuilt from `episodesDirectory()` at every access, because the app
/// container path contains a UUID that changes on reinstall and restore.
///
/// Resolution and provisioning are deliberately separate. `episodesDirectory()`
/// and everything built on it only compose paths — they never touch the file
/// system, so a read such as `Episode.isDownloaded(in:)` cannot create
/// directories or write extended attributes as a side effect.
/// `prepareEpisodesDirectory()` is the one mutating entry point.
struct EpisodeStore: Sendable {
    /// Rejected relative filenames — anything that could resolve outside `Episodes/`.
    enum Failure: Error, Equatable {
        case invalidFilename(String)
    }

    private let baseDirectory: URL?

    /// - Parameter baseDirectory: overrides Application Support; tests pass a
    ///   temporary directory here. `nil` uses the real container location.
    init(baseDirectory: URL? = nil) {
        self.baseDirectory = baseDirectory
    }

    /// `Application Support/Episodes/` — composed only, never created here.
    ///
    /// Never `Caches/` — iOS evicts that under storage pressure.
    func episodesDirectory() throws -> URL {
        let base =
            try baseDirectory
            ?? FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: false
            )
        return base.appending(path: "Episodes", directoryHint: .isDirectory)
    }

    /// Creates `Episodes/` and excludes it from backup. Call before writing a download.
    ///
    /// Throws rather than skipping if a non-directory already occupies the path,
    /// so the condition surfaces instead of turning every later lookup into a
    /// silent "not downloaded".
    @discardableResult
    func prepareEpisodesDirectory() throws -> URL {
        let base =
            try baseDirectory
            ?? FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        var directory = base.appending(path: "Episodes", directoryHint: .isDirectory)

        // createDirectory is idempotent for an existing directory and throws for
        // an existing file, which is exactly the wanted behaviour
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // podcast audio is re-downloadable and must not bloat device backups
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)

        return directory
    }

    /// Absolute URL for a stored relative filename. Resolved on demand, never persisted.
    ///
    /// `localFilename` must be a single path component. `URL.appending(path:)`
    /// does not normalise `..`, so an unvalidated name could resolve outside
    /// `Episodes/` — where the reconciliation sweep would never find it and the
    /// backup exclusion would not apply.
    func url(forRelativeFilename filename: String) throws -> URL {
        guard !filename.isEmpty, !filename.contains("/"), filename != ".", filename != ".." else {
            throw Failure.invalidFilename(filename)
        }
        return try episodesDirectory().appending(path: filename, directoryHint: .notDirectory)
    }

    /// Whether the audio file for a stored relative filename is actually on disk.
    ///
    /// A restore can leave the database row behind while the file is gone, since
    /// `Episodes/` is excluded from backup and the store is not (spec §5).
    ///
    /// Throws rather than answering `false` when the name cannot be resolved or
    /// the file system cannot answer: the reconciliation sweep (spec §5) clears
    /// download state for every episode whose file is absent, so "cannot tell"
    /// must never be reported as "absent".
    ///
    /// `FileManager.fileExists(atPath:)` is unusable here for exactly that
    /// reason — it collapses "no such file" and "could not determine" (denied
    /// permission, I/O failure, unmounted volume) into the same `false`. Reading
    /// a resource value throws instead, and only a confirmed not-found is
    /// translated back into `false`.
    func fileExists(forRelativeFilename filename: String) throws -> Bool {
        let url = try url(forRelativeFilename: filename)
        do {
            // a directory of that name is not a download, but it is a confident answer
            return try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
        } catch let error where error.isConfirmedFileNotFound {
            return false
        }
    }

    /// The relative filename a fresh download of `enclosureURL` is stored under.
    ///
    /// A UUID rather than anything derived from the feed (spec §5): enclosure
    /// paths collide across shows, carry rotating tokens, and are attacker-chosen
    /// text that would have to be sanitised into a path component anyway.
    ///
    /// The extension is inferred only so the file is recognisable to a human and
    /// to `AVURLAsset`; anything the feed offers that is not a plain short
    /// alphanumeric extension falls back to `mp3`. Composes only — the file
    /// system is never consulted, and no uniqueness check against `Episodes/` is
    /// needed because a v4 UUID does not repeat.
    func downloadFilename(forEnclosureURL enclosureURL: String) -> String {
        "\(UUID().uuidString).\(Self.fileExtension(forEnclosureURL: enclosureURL))"
    }

    private static func fileExtension(forEnclosureURL enclosureURL: String) -> String {
        let fallback = "mp3"
        // URL parsing drops the query and fragment, so ?token=… never becomes an extension
        guard let candidate = URL(string: enclosureURL)?.pathExtension.lowercased(), !candidate.isEmpty
        else {
            return fallback
        }
        let isPlausible =
            candidate.count <= 5 && candidate.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
        return isPlausible ? candidate : fallback
    }

    /// Moves a finished download into `Episodes/` under `filename`, returning its URL.
    ///
    /// Overwrite-safe: a leftover file of that name is replaced rather than
    /// treated as an error, because a crash between the move and the model write
    /// can leave one behind and a retry must be able to succeed.
    ///
    /// The caller is responsible for having called `prepareEpisodesDirectory()`.
    @discardableResult
    func moveFile(at source: URL, toRelativeFilename filename: String) throws -> URL {
        let destination = try url(forRelativeFilename: filename)
        do {
            try FileManager.default.removeItem(at: destination)
        } catch let error where error.isConfirmedFileNotFound {
            // nothing to replace, which is the ordinary case
        }
        try FileManager.default.moveItem(at: source, to: destination)
        return destination
    }

    /// Removes the audio file for a stored relative filename.
    ///
    /// A confirmed not-found is success — the goal state is "no file", and a
    /// dangling row whose file is already gone must not block clearing it.
    /// Every other error propagates, so a removal that could not be performed is
    /// never reported as one that was.
    func removeFile(forRelativeFilename filename: String) throws {
        let url = try url(forRelativeFilename: filename)
        do {
            try FileManager.default.removeItem(at: url)
        } catch let error where error.isConfirmedFileNotFound {
            // already absent
        }
    }

    /// Size in bytes of the audio file for a stored relative filename, or `nil` when absent.
    ///
    /// Same rule as `fileExists(forRelativeFilename:)`: only a confirmed
    /// not-found answers `nil`; an indeterminate file system throws rather than
    /// contributing a silent zero to a disk-usage total.
    func fileSize(forRelativeFilename filename: String) throws -> Int? {
        let url = try url(forRelativeFilename: filename)
        do {
            return try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        } catch let error where error.isConfirmedFileNotFound {
            return nil
        }
    }
}

extension Error {
    /// `true` only when the file system positively reported the item as absent.
    ///
    /// Everything else — denied permission, I/O failure, a dead volume — is an
    /// indeterminate answer that must propagate rather than be mistaken for a
    /// missing download.
    fileprivate var isConfirmedFileNotFound: Bool {
        let error = self as NSError
        switch error.domain {
        case NSCocoaErrorDomain:
            return error.code == NSFileReadNoSuchFileError || error.code == NSFileNoSuchFileError
        case NSPOSIXErrorDomain:
            // ENOTDIR: a parent component is not a directory, so nothing can exist here
            return error.code == Int(ENOENT) || error.code == Int(ENOTDIR)
        default:
            return false
        }
    }
}
