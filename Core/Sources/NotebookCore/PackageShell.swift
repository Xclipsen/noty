import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// A notebook package directory that provably holds no user data: what the
/// first commit of a new package leaves when it fails or the app is killed
/// before any byte of a revision or original reached the disk.
///
/// Exactly: a real directory (no symbolic link) whose entries are only
/// - the directories `Revisions` and `Assets`, each containing nothing but
///   zero-length regular files, and
/// - zero-length regular files that are none of the package's document files.
///
/// Anything else is no shell: a manifest, previous manifest, checkpoint list
/// or legacy document (even an empty one), `Migrations/`, `Quarantine/`, any
/// other directory, a symbolic link, and every file with at least one byte
/// (a revision, an original, a partial original, a temporary file). Such a
/// directory stays untouched and is reported as an unreadable notebook.
enum PackageShell {
    private static let documentFiles: Set<String> = ["manifest.json", "manifest-previous.json", "checkpoints.json",
                                                     "notebook.json", "recovery.json"]
    private static let ownDirectories: Set<String> = ["Revisions", NotebookAssets.directoryName]
    /// More entries than any aborted first commit leaves: not judged, no shell.
    private static let maximumEntries = 256

    static func isShell(_ directory: URL) -> Bool { inventory(directory) != nil }

    /// A regular file without a single byte (a final symbolic link is not followed).
    static func isEmptyFile(_ url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return false }
        return attributes[.type] as? FileAttributeType == .typeRegular && (attributes[.size] as? NSNumber)?.intValue == 0
    }

    /// Removes a shell: its zero-length files, then its directories with
    /// `rmdir`, which refuses a directory that is not empty. Never recursive,
    /// so an entry that appeared meanwhile keeps its directory. With
    /// `keepingRoot` the directory itself stays (empty). False if `directory`
    /// is no shell or something could not be removed.
    @discardableResult
    static func remove(_ directory: URL, keepingRoot: Bool = false) -> Bool {
        guard let found = inventory(directory) else { return false }
        for file in found.files {
            guard isEmptyFile(file), unlink(file.path) == 0 else { return false }
        }
        for folder in found.directories where rmdir(folder.path) != 0 { return false }
        return keepingRoot || rmdir(directory.path) == 0
    }

    /// Nil: no shell. Otherwise its zero-length files and its subdirectories.
    private static func inventory(_ directory: URL) -> (files: [URL], directories: [URL])? {
        let fm = FileManager.default
        // attributesOfItem does not follow a final symbolic link.
        guard let root = try? fm.attributesOfItem(atPath: directory.path), root[.type] as? FileAttributeType == .typeDirectory,
              let names = try? fm.contentsOfDirectory(atPath: directory.path), names.count <= maximumEntries else { return nil }
        var files: [URL] = [], directories: [URL] = []
        for name in names {
            let child = directory.appendingPathComponent(name)
            guard let attributes = try? fm.attributesOfItem(atPath: child.path) else { return nil }
            switch attributes[.type] as? FileAttributeType {
            case .typeRegular?:
                guard !documentFiles.contains(name), isEmptyFile(child) else { return nil }
                files.append(child)
            case .typeDirectory?:
                guard ownDirectories.contains(name), let inner = try? fm.contentsOfDirectory(atPath: child.path),
                      inner.count <= maximumEntries else { return nil }
                for innerName in inner {
                    let file = child.appendingPathComponent(innerName)
                    guard isEmptyFile(file) else { return nil }
                    files.append(file)
                }
                directories.append(child)
            default:
                return nil
            }
        }
        return (files, directories)
    }
}
