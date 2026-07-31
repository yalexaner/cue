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
