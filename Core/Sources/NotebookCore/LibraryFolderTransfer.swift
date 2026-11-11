import Foundation

// „Ordner exportieren“ und „Ordner importieren“ (docs/LIBRARY.md): ein Ordner
// mit allem Aktiven darunter als gewöhnliches Bibliotheksbackup (`.notylibrary`,
// Format unverändert), und die Übernahme eines solchen Archivs **in die
// aktuelle Bibliothek** statt als getrennter Bereich: fehlende Ordner entstehen,
// vorhandene gleichnamige werden benutzt, jedes Heft kommt als neues Heft dazu.

extension LibraryBackupPlan {
    /// The plan of only the active folder `id` and everything active below it
    /// (folders and notebooks; nothing from the trash). The folder becomes the
    /// archive's only top-level entry. No calendar: the archive stays format 2.
    public func restricted(toFolder id: UUID) throws -> LibraryBackupPlan {
        guard snapshot.items.contains(where: { $0.id == id && $0.isFolder }), !snapshot.isTrashed(id) else {
            throw LibraryError.unavailable
        }
        var keep: Set<UUID> = [id], grew = true
        // The index order is the manual order among siblings, not parents first.
        while grew {
            grew = false
            for item in snapshot.items where item.deletedAt == nil && !keep.contains(item.id) {
                if let parent = item.parentID, keep.contains(parent) { keep.insert(item.id); grew = true }
            }
        }
        var part = LibrarySnapshot()
        part.formatVersion = snapshot.formatVersion
        part.items = snapshot.items.filter { keep.contains($0.id) }.map { item in
            var copy = item
            if item.id == id { copy.parentID = nil }
            return copy
        }
        try part.validate()
        let kept = packages.filter { keep.contains($0.key) }
        guard part.items.allSatisfy({ $0.isFolder || kept[$0.id] != nil }) else { throw LibraryArchiveError.incomplete }
        return LibraryBackupPlan(snapshot: part, toolbar: toolbar, packages: kept)
    }
}

/// What taking a library archive into today's library does, before anything
/// is written: which folders of the archive already exist, which are created,
/// and where every active notebook of the archive goes.
public struct LibraryMergePlan: Equatable, Sendable {
    public struct Folder: Equatable, Sendable {
        /// The folder's ID in the archive.
        public let backupID: UUID
        public let title: String
        /// Its parent folder in the archive; nil: directly under `base`.
        public let backupParent: UUID?
        /// The active folder of today's library that stands for it; nil: created.
        public let existing: UUID?
    }
    public struct Notebook: Equatable, Sendable {
        public let id: UUID
        public let title: String
        public let isTextDocument: Bool
        /// Its folder in the archive; nil: directly under `base`.
        public let backupParent: UUID?
    }
    /// The folder of today's library everything goes under; nil: the top level.
    public let base: UUID?
    /// Active folders of the archive, parents before their children.
    public let folders: [Folder]
    /// Active notebooks of the archive in its order.
    public let notebooks: [Notebook]
    /// Entries of the archive's own trash; they are not taken over.
    public let skippedTrashed: Int
    public var createdFolders: Int { folders.filter { $0.existing == nil }.count }
    public var reusedFolders: Int { folders.count - createdFolders }
}

public enum LibraryMerge {
    /// Folder names compare without surrounding white space, composed and case-insensitively.
    static func key(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping.lowercased()
    }

    /// Pure: nothing is read or written besides the two indexes. An archive
    /// folder stands for today's active folder at the same place with the same
    /// ID, else for the first one there with the same name that no other
    /// archive folder took; otherwise it is created (and so is everything
    /// below it). `base` must be an active folder of `current`.
    public static func plan(backup: LibrarySnapshot, current: LibrarySnapshot, base: UUID?) throws -> LibraryMergePlan {
        if let base {
            guard current.items.contains(where: { $0.id == base && $0.isFolder }), !current.isTrashed(base) else {
                throw LibraryError.invalidDestination
            }
        }
        let active = backup.items.filter { !backup.isTrashed($0.id) }
        let folderIDs = Set(active.filter(\.isFolder).map(\.id))
        func parent(_ item: LibraryItem) -> UUID? { item.parentID.flatMap { folderIDs.contains($0) ? $0 : nil } }
        let todaysFolders = current.items.filter { $0.isFolder && !current.isTrashed($0.id) }

        var folders: [LibraryMergePlan.Folder] = [], claimed = Set<UUID>()
        /// Today's folder for a planned archive folder; `.some(nil)`: it is created.
        var place: [UUID: UUID?] = [:]
        var level = active.filter { $0.isFolder && parent($0) == nil }
        var visited = Set<UUID>()
        while !level.isEmpty {
            var next: [LibraryItem] = []
            for folder in level where visited.insert(folder.id).inserted {
                let backupParent = parent(folder)
                // Where its siblings live today: under `base`, under an existing folder, or nowhere yet.
                let today: UUID??
                if let backupParent { today = place[backupParent].flatMap { $0 }.map { Optional($0) } } else { today = .some(base) }
                var existing: UUID?
                if let today {
                    let siblings = todaysFolders.filter { $0.parentID == today && !claimed.contains($0.id) }
                    existing = (siblings.first { $0.id == folder.id } ?? siblings.first { key($0.title) == key(folder.title) })?.id
                }
                if let existing { claimed.insert(existing) }
                place[folder.id] = .some(existing)
                folders.append(.init(backupID: folder.id, title: folder.title, backupParent: backupParent, existing: existing))
                next += active.filter { $0.isFolder && parent($0) == folder.id }
            }
            level = next
        }
        let notebooks = active.filter { !$0.isFolder }.map {
            LibraryMergePlan.Notebook(id: $0.id, title: $0.title, isTextDocument: $0.isTextDocument, backupParent: parent($0))
        }
        return LibraryMergePlan(base: base, folders: folders, notebooks: notebooks,
                                skippedTrashed: backup.items.count - active.count)
    }
}
