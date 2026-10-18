import Foundation

/// The caller holds the chosen folder's security scope and file coordination.
/// Final names are unique; a failed write cannot replace a previous archive.
public enum ExternalBackupFolder {
    public static func read(_ url: URL) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw LibraryArchiveError.invalid }
        let bytes = try BackupArchive.readBounded(url, limit: LibraryArchive.maximumBytes)
        _ = try LibraryArchive.decode(bytes); return bytes
    }
    public static func write(_ bytes: Data, name: String, policy: ExternalBackupPolicy, directory: URL) throws {
        guard policy.timestamp(name) != nil else { throw LibraryArchiveError.invalid }
        _ = try LibraryArchive.decode(bytes)
        let fm = FileManager.default
        let final = directory.appendingPathComponent(name), temporary = directory.appendingPathComponent(name + ".partial")
        guard !fm.fileExists(atPath: final.path), !fm.fileExists(atPath: temporary.path) else { throw LibraryArchiveError.destinationExists }
        var created = false
        defer { if created { try? fm.removeItem(at: temporary) } }
        try bytes.write(to: temporary, options: .withoutOverwriting); created = true
        guard try read(temporary) == bytes else { throw LibraryArchiveError.invalid }
        try fm.moveItem(at: temporary, to: final)
        guard try read(final) == bytes else { throw LibraryArchiveError.invalid }
    }
    public static func prune(policy: ExternalBackupPolicy, directory: URL, verified: String) throws -> [String] {
        guard policy.timestamp(verified) != nil else { throw LibraryArchiveError.invalid }
        _ = try read(directory.appendingPathComponent(verified))
        let fm = FileManager.default, names = try fm.contentsOfDirectory(atPath: directory.path)
        var removed: [String] = []
        for name in policy.obsolete(names, verified: verified) {
            let url = directory.appendingPathComponent(name)
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            try fm.removeItem(at: url); removed.append(name)
        }
        return removed
    }
}
