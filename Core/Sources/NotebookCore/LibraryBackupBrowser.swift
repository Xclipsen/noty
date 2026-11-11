import Foundation

/// One notebook of a library backup compared with today's library
/// (BACKUP-RESTORE-PLAN Phase 1).
public struct BackupNotebookEntry: Identifiable, Equatable, Sendable {
    public enum Change: Equatable, Sendable {
        /// Same content as today.
        case unchanged
        /// Exists today, but its content or title differs.
        case changed
        /// Today in the library trash (or inside a trashed folder).
        case trashed
        /// No longer in the library at all (finally deleted).
        case deleted
    }
    public let id: UUID
    public let title: String
    public let isTextDocument: Bool
    /// Folder titles from the top level down; empty at the top level.
    public let folderPath: [String]
    /// The folder in the backup.
    public let parentID: UUID?
    public let pageCount: Int
    public let change: Change
    /// Title of the notebook with this ID today (active or trashed).
    public let currentTitle: String?
}

/// Table of contents of a verified library backup. Only notebooks that were
/// active in the backup; its own trash is counted, not listed.
public struct BackupCatalog: Equatable, Sendable {
    public let createdAt: Date
    public let entries: [BackupNotebookEntry]
    /// Active today, but not active in the backup (created or restored since).
    public let newSince: [String]
    /// Their identities, in the same order (Phase 4: „Ganze Bibliothek auf
    /// diesen Stand bringen“ moves them to the trash).
    public var newSinceIDs: [UUID] = []
    public let trashedInBackup: Int
    /// Folder paths (titles from the top) of the backup's active notebooks, by notebook.
    public var folderPaths: [UUID: [String]] { Dictionary(entries.map { ($0.id, $0.folderPath) }, uniquingKeysWith: { a, _ in a }) }
    public var differences: [BackupNotebookEntry] { entries.filter { $0.change != .unchanged } }
}

public enum LibraryBackupBrowser {
    /// One streaming pass (every record and asset verified again): each active
    /// notebook of the backup with its folder, page count and change against
    /// `current`. `fingerprints`: canonical size/CRC of today's committed
    /// notebooks (`LibraryBackupPlan.currentFingerprints`); a notebook without
    /// one (unreadable today) counts as changed.
    public static func catalog(archive: URL, current: LibrarySnapshot,
                               fingerprints: [UUID: LibraryArchiveFileInfo]) throws -> BackupCatalog {
        var found: [UUID: (pages: Int, text: Bool, print: LibraryArchiveFileInfo)] = [:]
        let summary = try LibraryArchive.verify(archive) { document in
            found[document.id] = (document.pages.count, document.isTextDocument, try LibraryArchive.fingerprint(document))
        }
        let backup = summary.snapshot
        var entries: [BackupNotebookEntry] = []
        for item in backup.items where !item.isFolder && !backup.isTrashed(item.id) {
            guard let notebook = found[item.id] else { throw LibraryArchiveError.invalid }
            let today = current.items.first { $0.id == item.id && !$0.isFolder }
            let change: BackupNotebookEntry.Change
            if let today {
                if current.isTrashed(today.id) { change = .trashed }
                else { change = fingerprints[today.id] == notebook.print ? .unchanged : .changed }
            } else { change = .deleted }
            entries.append(BackupNotebookEntry(id: item.id, title: item.title, isTextDocument: notebook.text,
                                               folderPath: folderPath(of: item, in: backup), parentID: item.parentID,
                                               pageCount: notebook.pages, change: change, currentTitle: today?.title))
        }
        let inBackup = Set(entries.map(\.id))
        let added = current.items.filter { !$0.isFolder && !current.isTrashed($0.id) && !inBackup.contains($0.id) }
        let trashed = backup.items.filter { !$0.isFolder && backup.isTrashed($0.id) }.count
        var catalog = BackupCatalog(createdAt: summary.createdAt, entries: entries, newSince: added.map(\.title), trashedInBackup: trashed)
        catalog.newSinceIDs = added.map(\.id)
        return catalog
    }

    /// One streaming pass that writes each notebook of `titles` (ID → title of
    /// the restored notebook) as a verified `.notybackup` into the existing
    /// empty `directory` (format 2 with its originals, read back by
    /// `BackupArchive.write`). The import then takes the same staged, checked
    /// path as a `.noty` file (`NotebookRepository.prepareRestore`). Asset
    /// originals are extracted into `directory/Assets` meanwhile; the caller
    /// removes the whole directory afterwards. Missing IDs fail the pass.
    public static func extract(archive: URL, titles: [UUID: String], into directory: URL) throws -> [UUID: URL] {
        let fm = FileManager.default
        let assets = directory.appendingPathComponent("Assets", isDirectory: true)
        try fm.createDirectory(at: assets, withIntermediateDirectories: false)
        var files: [UUID: URL] = [:]
        _ = try LibraryArchive.verify(archive, extractingAssetsTo: assets) { document, originals in
            guard let title = titles[document.id] else { return }
            var copy = document
            copy.title = try LibraryStore.validTitle(title)
            let url = directory.appendingPathComponent(document.id.uuidString + ".notybackup")
            _ = try BackupArchive.write(copy, assets: originals, to: url)
            files[document.id] = url
        }
        guard Set(files.keys) == Set(titles.keys) else { throw LibraryArchiveError.invalid }
        return files
    }

    /// „Bio (Stand 07.11.2026)“: title of a copy next to a notebook that still
    /// exists. The title is shortened, never the date, to stay ≤ 120 characters.
    /// `withTime`: „Bio (Stand 07.11.2026, 15:40)“ for states of the same day.
    public static func copyTitle(_ title: String, savedAt date: Date, withTime: Bool = false, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.day, .month, .year, .hour, .minute], from: date)
        var suffix = String(format: " (Stand %02d.%02d.%04d", parts.day ?? 1, parts.month ?? 1, parts.year ?? 1970)
        if withTime { suffix += String(format: ", %02d:%02d", parts.hour ?? 0, parts.minute ?? 0) }
        suffix += ")"
        let head = String(NotebookTitles.sanitized(title).prefix(NotebookTitles.maximumLength - suffix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (head.isEmpty ? "Heft" : head) + suffix
    }

    /// What „Ganze Bibliothek auf diesen Stand bringen“ does (Phase 4):
    /// notebooks missing or different today come back (a changed one in place
    /// of today's state, which goes to the trash), notebooks active today but
    /// not in the backup go to the trash. Nothing is deleted for good.
    public struct WholeRestorePlan: Equatable, Sendable {
        public var replace: [BackupNotebookEntry] = []
        public var bringBack: [BackupNotebookEntry] = []
        public var toTrash: [UUID] = []
        public var isEmpty: Bool { replace.isEmpty && bringBack.isEmpty && toTrash.isEmpty }
    }

    public static func wholeRestorePlan(_ catalog: BackupCatalog) -> WholeRestorePlan {
        var plan = WholeRestorePlan()
        for entry in catalog.entries {
            switch entry.change {
            case .changed: plan.replace.append(entry)
            case .deleted, .trashed: plan.bringBack.append(entry)
            case .unchanged: break
            }
        }
        plan.toTrash = catalog.newSinceIDs
        return plan
    }

    /// The folder of the backup if it still exists today (and is not in the
    /// trash); otherwise the top level.
    public static func destination(for entry: BackupNotebookEntry, in current: LibrarySnapshot) -> UUID? {
        guard let parent = entry.parentID,
              current.items.contains(where: { $0.id == parent && $0.isFolder }), !current.isTrashed(parent) else { return nil }
        return parent
    }

    static func folderPath(of item: LibraryItem, in snapshot: LibrarySnapshot) -> [String] {
        var path: [String] = [], visited = Set<UUID>([item.id]), parent = item.parentID
        while let id = parent, visited.insert(id).inserted, let folder = snapshot.items.first(where: { $0.id == id && $0.isFolder }) {
            path.insert(folder.title, at: 0)
            parent = folder.parentID
        }
        return path
    }
}

extension LibraryBackupPlan {
    /// Canonical size/CRC (`LibraryArchive.fingerprint`) of every active
    /// notebook's committed state, read one at a time off any actor, exactly
    /// as the backup would archive it. Unreadable notebooks are left out.
    public func currentFingerprints() -> [UUID: LibraryArchiveFileInfo] {
        var result: [UUID: LibraryArchiveFileInfo] = [:]
        for item in documents where !snapshot.isTrashed(item.id) {
            if Task.isCancelled { break }
            guard let state = try? readableNotebook(item), !state.olderState,
                  let print = try? LibraryArchive.fingerprint(state.document) else { continue }
            result[item.id] = print
        }
        return result
    }
}
