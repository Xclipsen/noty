import Foundation

/// File coordination for a user-chosen (often iCloud Drive) folder. The app
/// implements it with NSFileCoordinator; Linux tests use `DirectBackupFiles`.
public protocol BackupFileCoordinating: Sendable {
    func reading(_ url: URL, metadataOnly: Bool, _ body: (URL) throws -> Void) throws
    func writing(_ url: URL, _ body: (URL) throws -> Void) throws
    func moving(_ source: URL, to destination: URL, _ body: (URL, URL) throws -> Void) throws
    func deleting(_ url: URL, _ body: (URL) throws -> Void) throws
}
public struct DirectBackupFiles: BackupFileCoordinating {
    public init() {}
    public func reading(_ url: URL, metadataOnly: Bool, _ body: (URL) throws -> Void) throws { try body(url) }
    public func writing(_ url: URL, _ body: (URL) throws -> Void) throws { try body(url) }
    public func moving(_ source: URL, to destination: URL, _ body: (URL, URL) throws -> Void) throws { try body(source, destination) }
    public func deleting(_ url: URL, _ body: (URL) throws -> Void) throws { try body(url) }
}

/// Own files found in the backup folder.
public struct ExternalBackupListing: Equatable, Sendable {
    /// This series' archives, newest first, including not-downloaded iCloud placeholders.
    public var archives: [String] = []
    /// Archive names that are present only as `.<name>.icloud` placeholder.
    public var placeholders: Set<String> = []
    /// This series' unfinished `.partial`/`.failed` files (by real name).
    public var temporaries: [String] = []
    public init() {}
}

/// The caller holds the chosen folder's security scope. Final names are unique;
/// a failed write cannot replace a previous archive, and only files of the own
/// series are ever removed. Archives are compared by exact size and CRC-32.
public enum ExternalBackupFolder {
    /// iCloud Drive keeps not-downloaded files as hidden `.<name>.icloud` placeholders.
    public static func placeholderTarget(_ raw: String) -> String? {
        guard raw.hasPrefix("."), raw.hasSuffix(".icloud"), raw.count > 8 else { return nil }
        return String(raw.dropFirst().dropLast(7))
    }

    public static func list(policy: ExternalBackupPolicy, directory: URL,
                            coordination: BackupFileCoordinating = DirectBackupFiles()) throws -> ExternalBackupListing {
        var raw: [String] = []
        try coordination.reading(directory, metadataOnly: true) { url in raw = try FileManager.default.contentsOfDirectory(atPath: url.path) }
        var listing = ExternalBackupListing(), archives = Set<String>(), temporaries = Set<String>()
        for entry in raw {
            let placeholder = placeholderTarget(entry)
            let name = placeholder ?? entry
            if policy.timestamp(name) != nil {
                archives.insert(name)
                if placeholder != nil, !raw.contains(name) { listing.placeholders.insert(name) }
            } else if policy.temporaryTimestamp(name) != nil { temporaries.insert(name) }
        }
        listing.archives = archives.sorted { policy.timestamp($0)! > policy.timestamp($1)! }
        listing.temporaries = temporaries.sorted()
        return listing
    }

    /// Copies an already verified local archive as `<name>.partial`, re-reads it,
    /// renames it and re-reads the final file; size+CRC must equal `file` each time.
    /// Failures remove the own partial file; an unverifiable final file is removed
    /// (or, if that fails, renamed to `.failed`), so it never counts as a backup.
    public static func write(archive source: URL, file: LibraryArchiveFileInfo, name: String, policy: ExternalBackupPolicy,
                             directory: URL, coordination: BackupFileCoordinating = DirectBackupFiles()) throws {
        guard policy.timestamp(name) != nil else { throw LibraryArchiveError.invalid }
        let fm = FileManager.default
        let final = directory.appendingPathComponent(name), partial = directory.appendingPathComponent(name + ".partial")
        for candidate in [name, name + ".partial", "." + name + ".icloud", "." + name + ".partial.icloud"] {
            guard !fm.fileExists(atPath: directory.appendingPathComponent(candidate).path) else { throw LibraryArchiveError.destinationExists }
        }
        var created = false
        do {
            try coordination.writing(partial) { url in
                let copied = try BoundedFile.copy(from: source, to: url); created = true
                guard copied == file else { throw LibraryArchiveError.verificationFailed }
            }
            try coordination.reading(partial, metadataOnly: false) { url in
                guard try BoundedFile.checksum(url) == file else { throw LibraryArchiveError.verificationFailed }
            }
            try coordination.moving(partial, to: final) { from, to in try fm.moveItem(at: from, to: to) }
        } catch {
            if created { _ = try? remove(partial, coordination: coordination) }
            throw error
        }
        do {
            try coordination.reading(final, metadataOnly: false) { url in
                guard try BoundedFile.checksum(url) == file else { throw LibraryArchiveError.verificationFailed }
            }
        } catch {
            if (try? remove(final, coordination: coordination)) == nil {
                try? coordination.moving(final, to: directory.appendingPathComponent(name + ".failed")) { from, to in try fm.moveItem(at: from, to: to) }
            }
            throw LibraryArchiveError.verificationFailed
        }
    }

    /// After `verified` was written and read back: keeps `policy.keep` newest own
    /// archives (placeholders count and are deleted without downloading) and drops
    /// own temporaries older than a day. Other files are never touched.
    public static func prune(policy: ExternalBackupPolicy, directory: URL, verified: String, file: LibraryArchiveFileInfo,
                             now: Date = Date(), coordination: BackupFileCoordinating = DirectBackupFiles()) throws -> [String] {
        guard policy.timestamp(verified) != nil else { throw LibraryArchiveError.invalid }
        let newest = directory.appendingPathComponent(verified)
        let values = try newest.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, values.fileSize == file.byteCount else {
            throw LibraryArchiveError.verificationFailed
        }
        let listing = try list(policy: policy, directory: directory, coordination: coordination)
        var removed: [String] = []
        for name in policy.obsolete(listing.archives, verified: verified) {
            let url = directory.appendingPathComponent(listing.placeholders.contains(name) ? "." + name + ".icloud" : name)
            guard try remove(url, coordination: coordination, item: directory.appendingPathComponent(name)) else { continue }
            removed.append(name)
        }
        for name in policy.staleTemporaries(listing.temporaries, now: now) {
            _ = try? remove(directory.appendingPathComponent(name), coordination: coordination)
        }
        return removed
    }

    /// Copies one own archive out of the folder (a placeholder is downloaded by
    /// the coordinated read) into a new local file; the caller verifies it.
    public static func copy(name: String, policy: ExternalBackupPolicy, directory: URL, to destination: URL,
                            coordination: BackupFileCoordinating = DirectBackupFiles()) throws -> LibraryArchiveFileInfo {
        guard policy.timestamp(name) != nil else { throw LibraryArchiveError.invalid }
        var info: LibraryArchiveFileInfo?
        try coordination.reading(directory.appendingPathComponent(name), metadataOnly: false) { url in
            info = try BoundedFile.copy(from: url, to: destination)
        }
        guard let info else { throw LibraryArchiveError.invalid }
        return info
    }

    /// Removes one regular file (never a symlink or directory). `item` is the
    /// coordinated item URL when `url` is its iCloud placeholder.
    @discardableResult
    private static func remove(_ url: URL, coordination: BackupFileCoordinating, item: URL? = nil) throws -> Bool {
        var removed = false
        try coordination.deleting(item ?? url) { coordinated in
            let fm = FileManager.default
            var target = item == nil ? coordinated : url
            if item != nil, fm.fileExists(atPath: coordinated.path) { target = coordinated }
            let values = try target.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { return }
            try fm.removeItem(at: target); removed = true
        }
        return removed
    }
}
