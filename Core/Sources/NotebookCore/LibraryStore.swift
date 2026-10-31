import Foundation

public enum LibrarySource: String, Codable, Sendable {
    case legacyMain, restored, library
}

public struct LibraryItem: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var title: String
    public var parentID: UUID?
    /// nil identifies a folder. Document paths are derived from this enum + ID.
    public let source: LibrarySource?
    public var favorite = false
    public var lastOpened: Date?
    public var deletedAt: Date?
    /// `.textDocument` for text documents (Textneubau Stufe 3); nil for
    /// notebooks and folders (index entries of notebooks stay byte-identical).
    /// A display hint for icons and menus: the document's own `kind` is
    /// authoritative (older builds drop this key when they rewrite the index;
    /// `setKind` repairs it, a library restore takes it from the documents).
    public var kind: DocumentKind?
    public var isFolder: Bool { source == nil }
    public var isTextDocument: Bool { kind == .textDocument }

    public init(id: UUID = UUID(), title: String, parentID: UUID? = nil, source: LibrarySource? = nil) {
        self.id = id; self.title = title; self.parentID = parentID; self.source = source
    }
}

public struct LibrarySnapshot: Codable, Equatable, Sendable {
    public var formatVersion = 1
    /// Array order is the manual order among siblings, for folders and notebooks.
    public var items: [LibraryItem] = []
    public init() {}

    public func isTrashed(_ id: UUID) -> Bool {
        var current = items.first { $0.id == id }
        var visited = Set<UUID>()
        while let item = current, visited.insert(item.id).inserted {
            if item.deletedAt != nil { return true }
            current = item.parentID.flatMap { parent in items.first { $0.id == parent } }
        }
        return false
    }

    public func children(of parent: UUID?) -> [LibraryItem] {
        items.filter { $0.parentID == parent && !isTrashed($0.id) }
    }

    func validate() throws {
        guard formatVersion == 1 else { throw LibraryError.unsupportedVersion(formatVersion) }
        guard items.count <= 10_000, Set(items.map(\.id)).count == items.count,
              items.filter({ $0.source == .legacyMain }).count <= 1 else { throw LibraryError.invalidIndex }
        let lookup = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        for item in items {
            _ = try LibraryStore.validTitle(item.title)
            if let kind = item.kind { guard kind == .textDocument, !item.isFolder else { throw LibraryError.invalidIndex } }
            for date in [item.deletedAt, item.lastOpened].compactMap({ $0 }) {
                guard date.timeIntervalSince1970.isFinite,
                      (-62_135_596_800...253_402_300_799).contains(date.timeIntervalSince1970) else {
                    throw LibraryError.invalidIndex
                }
            }
            var parent = item.parentID
            var visited: Set<UUID> = [item.id]
            while let id = parent {
                guard visited.insert(id).inserted, let folder = lookup[id], folder.isFolder else {
                    throw LibraryError.invalidIndex
                }
                parent = folder.parentID
            }
        }
    }
}

public struct LibraryLoad: Sendable {
    public let snapshot: LibrarySnapshot
    public let recovered: Bool
    public let unreadableDocuments: Int
}

/// Outcome of a permanent deletion. `purgedIDs` are gone from the index;
/// `leftoverDirectories` packages could not be removed from disk (their files
/// stay intact and may be rediscovered by a later `load()`).
public struct LibraryPurgeResult: Equatable, Sendable {
    public let snapshot: LibrarySnapshot
    public let purgedIDs: [UUID]
    public let leftoverDirectories: Int
    /// Trash roots skipped by `emptyTrash()` because they contain the legacy
    /// main notebook, whose files live directly in the library root.
    public let retainedIDs: [UUID]
}

public enum LibraryError: Error, LocalizedError {
    case invalidIndex, unavailable, invalidDestination, invalidTitle, unsupportedVersion(Int), notPurgeable, olderStateOnly
    public var errorDescription: String? {
        switch self {
        case .invalidIndex: "Der Bibliotheksindex ist nicht lesbar. Vorhandene Hefte bleiben erhalten."
        case .unavailable: "Dieser Eintrag ist nicht mehr verfügbar. Bitte die Bibliothek neu laden."
        case .invalidDestination: "Dieses Ziel ist nicht möglich. Ein Ordner kann nicht in sich selbst oder einen Unterordner verschoben werden."
        case .invalidTitle: "Bitte einen Namen mit 1 bis 120 Zeichen ohne Zeilenumbrüche eingeben."
        case .unsupportedVersion(let version): "Bibliotheksformat \(version) benötigt eine neuere noty-Version."
        case .notPurgeable: "Das ursprüngliche Heft liegt direkt im App-Ordner und kann nicht endgültig gelöscht werden. Es bleibt im Papierkorb wiederherstellbar."
        case .olderStateOnly: "Der neueste Stand dieses Hefts ist nicht lesbar. Bitte das Heft öffnen und prüfen; es wurde nichts geteilt."
        }
    }
}

private struct LibraryEnvelope: Codable {
    var formatVersion = 1
    var crc32: UInt32
    var payload: Data
}

/// One index owner. Index operations never move, overwrite or remove notebook
/// packages. A new notebook is committed before its index entry; an interrupted
/// index write leaves a discoverable orphan, never a dangling successful create.
public actor LibraryStore {
    public let root: URL
    private var snapshot: LibrarySnapshot?
    private var lastGoodBytes: Data?
    private var recovered = false
    private let fm = FileManager.default
    private var directory: URL { root.appendingPathComponent("Library", isDirectory: true) }
    private var primary: URL { directory.appendingPathComponent("index.json") }
    private var previous: URL { directory.appendingPathComponent("index-previous.json") }

    public init(root: URL) { self.root = root }

    public static func validTitle(_ title: String) throws -> String {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...120).contains(name.count), !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw LibraryError.invalidTitle
        }
        return name
    }

    public func load() throws -> LibraryLoad {
        if snapshot == nil { try readIndex() }
        var candidate = snapshot!
        var unreadable = 0
        // Existing storage is adopted by reference; no document format migration.
        if hasDocument(at: root) {
            do { try discover(at: root, source: .legacyMain, into: &candidate) }
            catch { unreadable += 1 }
        }
        for (name, source) in [("Restores", LibrarySource.restored), ("Library/Documents", .library)] {
            let parent = root.appendingPathComponent(name, isDirectory: true)
            guard fm.fileExists(atPath: parent.path) else { continue }
            try requireDirectory(parent)
            for folder in try fm.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                guard let id = UUID(uuidString: folder.lastPathComponent), id.uuidString == folder.lastPathComponent else { continue }
                do {
                    // Known documents are owned by their editor; reopening the
                    // library does not decode every large notebook again.
                    if let existing = candidate.items.first(where: { $0.id == id }) {
                        guard existing.source == source else { throw LibraryError.invalidIndex }
                        try requireDirectory(folder)
                    } else { try discover(at: folder, source: source, into: &candidate) }
                } catch { unreadable += 1 }
            }
        }
        if candidate != snapshot! { try commit(candidate) }
        return LibraryLoad(snapshot: snapshot!, recovered: recovered, unreadableDocuments: unreadable)
    }

    private func discover(at url: URL, source: LibrarySource, into candidate: inout LibrarySnapshot) throws {
        try requireDirectory(url)
        guard hasDocument(at: url) else { throw LibraryError.invalidIndex }
        if source == .legacyMain, candidate.items.contains(where: { $0.source == source }) { return }
        let notebook = try RevisionStore(directory: url, readOnly: true).load()
        if source != .legacyMain {
            guard notebook.id.uuidString == url.lastPathComponent else { throw LibraryError.invalidIndex }
        }
        guard !candidate.items.contains(where: { $0.id == notebook.id }) else { throw LibraryError.invalidIndex }
        let title = (try? Self.validTitle(notebook.title)) ?? (notebook.isTextDocument ? "Unbenanntes Dokument" : "Unbenanntes Heft")
        var item = LibraryItem(id: notebook.id, title: title, source: source)
        item.kind = notebook.isTextDocument ? .textDocument : nil
        candidate.items.append(item)
    }

    /// Read-only view of the committed index (falls back to `index-previous.json`
    /// like `load()`), without inventory of packages and without any commit.
    /// For summaries of an area that is not open, e.g. before removing it.
    public func committedSnapshot() throws -> LibrarySnapshot {
        if snapshot == nil { try readIndex() }
        return try current()
    }

    /// Read-only, serialized with other library work; metadata remains in the
    /// versioned notebook so the index does not duplicate cover/paper settings.
    public func previewDocument(id: UUID) throws -> Notebook {
        try previewPackage(id: id).document
    }

    /// Like `previewDocument`, with the package's image originals (read-only;
    /// embedded originals of a not yet migrated schema 5–11 state in memory).
    public func previewPackage(id: UUID) throws -> (document: Notebook, assets: NotebookAssets) {
        let store = RevisionStore(directory: try documentURL(id: id), readOnly: true)
        return (try store.load(), store.assets)
    }

    /// The last committed revision for sharing as `.noty`: refuses a package
    /// whose newest revision is unreadable instead of silently sharing an
    /// older state (like `duplicateDocument`).
    public func sharePackage(id: UUID) throws -> (document: Notebook, assets: NotebookAssets) {
        let store = RevisionStore(directory: try documentURL(id: id), readOnly: true)
        let document = try store.load()
        guard !store.recovered else { throw LibraryError.olderStateOnly }
        return (document, store.assets)
    }

    /// Read-only, without an actor: the committed index of the library at
    /// `root` (primary, else the previous copy), nil if there is none or it
    /// is unreadable. For title collisions of copies created outside the
    /// library's own actor (local history in the editor).
    public static func committedIndex(root: URL) -> LibrarySnapshot? {
        let directory = root.appendingPathComponent("Library", isDirectory: true)
        for name in ["index.json", "index-previous.json"] {
            if let value = try? readIndexPayload(at: directory.appendingPathComponent(name)) { return value }
        }
        return nil
    }

    /// Adopts a package that an import committed and read back at
    /// `Library/Documents/<id>` (`NotebookRepository.commitRestore(into:)`)
    /// as a normal library notebook (`source == .library`, never a restored
    /// copy). `title` is the unique title the package was written with.
    ///
    /// `replacing`: an active notebook with the file's document ID. In one
    /// index commit the import takes its place (same folder, same position,
    /// pin) and the existing notebook moves to the library trash with its
    /// last committed state; its package is not touched and stays
    /// restorable. The import keeps its own new identity: the old entry
    /// needs its ID in the trash, and overwriting a package in place would
    /// be a second writer of an existing notebook.
    ///
    /// The package is written before this index commit; an interruption in
    /// between leaves a discoverable orphan (like `createDocument`). If a
    /// `load()` already adopted the orphan, that entry is placed instead.
    public func adoptImported(_ id: UUID, title: String, parentID: UUID?, replacing: UUID?,
                              kind: DocumentKind = .notebook) throws -> LibrarySnapshot {
        var next = try current()
        let name = try Self.validTitle(title)
        let url = packageURL(id: id, source: .library)
        try requireDirectory(url)
        guard hasDocument(at: url) else { throw LibraryError.unavailable }
        if let existing = next.items.firstIndex(where: { $0.id == id }) {
            guard next.items[existing].source == .library else { throw LibraryError.invalidIndex }
            next.items.remove(at: existing)
        }
        var item = LibraryItem(id: id, title: name, parentID: parentID, source: .library)
        item.kind = kind == .textDocument ? .textDocument : nil
        if let replacing {
            guard replacing != id else { throw LibraryError.invalidIndex }
            let index = try activeIndex(replacing, in: next)
            guard !next.items[index].isFolder else { throw LibraryError.unavailable }
            item.parentID = next.items[index].parentID
            item.favorite = next.items[index].favorite
            next.items[index].deletedAt = Date()
            next.items.insert(item, at: index)
        } else {
            try checkParent(parentID, in: next)
            next.items.append(item)
        }
        try commit(next)
        return next
    }

    public func documentURL(id: UUID) throws -> URL {
        let item = try current().items.first { $0.id == id }
        guard let item, let source = item.source, !currentSnapshot.isTrashed(id) else { throw LibraryError.unavailable }
        let url = packageURL(id: id, source: source)
        try requireDirectory(url)
        guard hasDocument(at: url) else { throw LibraryError.unavailable }
        return url
    }

    /// Quick, on the library actor: the complete index (including trash and
    /// folders), preferences and every package location. Notebook contents are
    /// read afterwards from committed revisions, off this actor (`LibraryArchive.write`).
    public func backupPlan() throws -> LibraryBackupPlan {
        let result = try load()
        guard result.unreadableDocuments == 0 else { throw LibraryArchiveError.incomplete }
        var packages: [UUID: URL] = [:]
        for item in result.snapshot.items where !item.isFolder {
            let url: URL
            switch item.source! {
            case .legacyMain: url = root
            case .restored: url = root.appendingPathComponent("Restores/\(item.id.uuidString)", isDirectory: true)
            case .library: url = root.appendingPathComponent("Library/Documents/\(item.id.uuidString)", isDirectory: true)
            }
            try requireDirectory(url)
            guard hasDocument(at: url) else { throw LibraryArchiveError.incomplete }
            packages[item.id] = url
        }
        let preferences = try ToolbarPreferenceStore.read(root: root)
        return LibraryBackupPlan(snapshot: result.snapshot, toolbar: preferences.0, packages: packages)
    }

    /// Complete library in memory (tests, small libraries). Includes independently
    /// trashed children and folders; an older recovered revision aborts.
    public func backupBundle() throws -> LibraryBundle {
        let plan = try backupPlan()
        let bundle = LibraryBundle(snapshot: plan.snapshot, documents: try plan.documents.map(plan.committedNotebook), toolbar: plan.toolbar)
        try bundle.validate(); return bundle
    }

    /// Only for an unpublished empty restore stage, never an existing library.
    /// WorkspaceStore atomically publishes the whole validated directory later.
    public func populateEmpty(_ bundle: LibraryBundle) throws {
        try bundle.validate()
        guard !fm.fileExists(atPath: root.path) else { throw LibraryArchiveError.destinationExists }
        for document in bundle.documents { try Self.populatePackage(document, root: root) }
        try populateIndex(bundle.snapshot, toolbar: bundle.toolbar,
                          kinds: Dictionary(bundle.documents.map { ($0.id, $0.documentKind) }, uniquingKeysWith: { a, _ in a }))
    }

    /// Restore stage only: writes one complete package and reads it back. A
    /// streaming restore calls this per notebook before any index exists.
    /// `RevisionStore.save` writes the image assets first (verified copies
    /// from `assets`), then revision and manifest; every asset must be
    /// present afterwards.
    static func populatePackage(_ document: Notebook, root: URL, assetsFrom assets: ImageAssetProviding? = nil) throws {
        let fm = FileManager.default
        let documentsRoot = root.appendingPathComponent("Library/Documents", isDirectory: true)
        try fm.createDirectory(at: documentsRoot, withIntermediateDirectories: true)
        try ContainedDirectory.require(documentsRoot, below: root)
        let destination = documentsRoot.appendingPathComponent(document.id.uuidString, isDirectory: true)
        guard !fm.fileExists(atPath: destination.path) else { throw LibraryArchiveError.destinationExists }
        try RevisionStore(directory: destination).save(document, importingAssetsFrom: assets)
        let reopened = RevisionStore(directory: destination, readOnly: true)
        guard try reopened.load() == document, reopened.assets.presentOnDisk(document.externalImageAssets) else {
            throw LibraryArchiveError.incomplete
        }
    }

    /// Restore stage only, after every package: preferences, then the portable
    /// index (all documents as `library` packages) as the last commit.
    /// `kinds`: the restored documents' own kinds, authoritative over the
    /// archived index (an index rewritten by an older build lost them).
    func populateIndex(_ value: LibrarySnapshot, toolbar: ToolbarPreferences, kinds: [UUID: DocumentKind] = [:]) throws {
        try value.validate(); try toolbar.validate()
        guard snapshot == nil, !fm.fileExists(atPath: primary.path), !fm.fileExists(atPath: previous.path) else {
            throw LibraryArchiveError.destinationExists
        }
        var portable = value
        portable.items = value.items.map { item in
            var copy = LibraryItem(id: item.id, title: item.title, parentID: item.parentID,
                                   source: item.isFolder ? nil : .library)
            copy.favorite = item.favorite; copy.lastOpened = item.lastOpened; copy.deletedAt = item.deletedAt
            if !item.isFolder { copy.kind = (kinds[item.id].map { $0 == .textDocument } ?? item.isTextDocument) ? .textDocument : nil }
            return copy
        }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(toolbar).write(to: root.appendingPathComponent("toolbar.json"), options: .atomic)
        snapshot = LibrarySnapshot()
        try commit(portable)
        guard try LibraryStore.readIndexPayload(at: primary) == portable else { throw LibraryArchiveError.incomplete }
    }

    private static func readIndexPayload(at url: URL) throws -> LibrarySnapshot {
        let data = try BackupArchive.readBounded(url, limit: 4_000_000)
        let envelope = try JSONDecoder().decode(LibraryEnvelope.self, from: data)
        guard envelope.formatVersion == 1, SnapshotChecksum.crc32(envelope.payload) == envelope.crc32 else { throw LibraryError.invalidIndex }
        let value = try JSONDecoder().decode(LibrarySnapshot.self, from: envelope.payload)
        try value.validate(); return value
    }

    public func createFolder(title: String, parentID: UUID?) throws -> LibrarySnapshot {
        var next = try current()
        try checkParent(parentID, in: next)
        next.items.append(LibraryItem(title: try Self.validTitle(title), parentID: parentID))
        try commit(next)
        return next
    }

    public func createDocument(_ notebook: Notebook, parentID: UUID?) throws -> LibrarySnapshot {
        var next = try current()
        try checkParent(parentID, in: next)
        let title = try writePackage(notebook, in: next)
        var item = LibraryItem(id: notebook.id, title: title, parentID: parentID, source: .library)
        item.kind = notebook.isTextDocument ? .textDocument : nil
        next.items.append(item)
        try commit(next)
        return next
    }

    /// Independent copy of an active notebook directly behind the original in
    /// the same folder. The copy gets a new document identity and its own
    /// package with the latest committed revision (pages, page trash, PDF/image
    /// originals unchanged; no local history). Page/object IDs stay scoped to
    /// the copy, like restore copies. A recovered (older) source revision is
    /// refused instead of being duplicated silently. Image originals are
    /// copied (an APFS clone) and verified into the new package; the original
    /// is only read. A not yet migrated schema 5–11 source becomes a schema-12
    /// copy whose assets are its embedded originals; the source keeps its bytes.
    public func duplicateDocument(_ id: UUID, title: String) throws -> (snapshot: LibrarySnapshot, id: UUID) {
        // Reads another package's originals: no asset GC meanwhile.
        let activity = BackupActivity.shared.begin(); defer { activity.end() }
        var next = try current()
        let index = try activeIndex(id, in: next)
        let original = next.items[index]
        guard !original.isFolder else { throw LibraryError.unavailable }
        let source = RevisionStore(directory: try documentURL(id: id), readOnly: true)
        var copy = try source.load()
        guard !source.recovered, copy.id == id else { throw LibraryError.unavailable }
        copy.id = UUID()
        copy.title = try Self.validTitle(title)
        let name = try writePackage(copy, in: next, assetsFrom: source.assets)
        var item = LibraryItem(id: copy.id, title: name, parentID: original.parentID, source: .library)
        item.kind = copy.isTextDocument ? .textDocument : nil
        next.items.insert(item, at: index + 1)
        try commit(next)
        return (next, copy.id)
    }

    /// Writes and reads back a complete new package before any index entry
    /// exists; image assets (from `assets`) first, every one present afterwards.
    private func writePackage(_ notebook: Notebook, in value: LibrarySnapshot,
                              assetsFrom assets: ImageAssetProviding? = nil) throws -> String {
        guard !value.items.contains(where: { $0.id == notebook.id }) else { throw LibraryError.invalidIndex }
        let title = try Self.validTitle(notebook.title)
        let destination = root.appendingPathComponent("Library/Documents/\(notebook.id.uuidString)", isDirectory: true)
        guard !fm.fileExists(atPath: destination.path) else { throw LibraryError.invalidIndex }
        let parent = destination.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        try requireDirectory(parent)
        try RevisionStore(directory: destination).save(notebook, importingAssetsFrom: assets)
        let reopened = RevisionStore(directory: destination, readOnly: true)
        guard try reopened.load() == notebook, reopened.assets.presentOnDisk(notebook.externalImageAssets) else {
            throw LibraryError.invalidIndex
        }
        return title
    }

    public func rename(_ id: UUID, title: String) throws -> LibrarySnapshot {
        var next = try current()
        let index = try activeIndex(id, in: next)
        next.items[index].title = try Self.validTitle(title)
        try commit(next); return next
    }

    public func move(_ id: UUID, to parentID: UUID?) throws -> LibrarySnapshot {
        var next = try current()
        let index = try activeIndex(id, in: next)
        try checkDestination(parentID, moving: id, in: next)
        var item = next.items.remove(at: index)
        item.parentID = parentID
        next.items.append(item)
        try commit(next); return next
    }

    /// Drag & drop placement in one commit: moves `id` into `parentID` (same
    /// cycle/target rules as `move`) and puts it directly before the active
    /// sibling `beforeID`, or behind all siblings when `beforeID` is nil.
    public func place(_ id: UUID, in parentID: UUID?, before beforeID: UUID?) throws -> LibrarySnapshot {
        var next = try current()
        let index = try activeIndex(id, in: next)
        try checkDestination(parentID, moving: id, in: next)
        if let beforeID {
            guard beforeID != id, next.children(of: parentID).contains(where: { $0.id == beforeID }) else {
                throw LibraryError.unavailable
            }
        }
        var item = next.items.remove(at: index)
        item.parentID = parentID
        if let beforeID, let target = next.items.firstIndex(where: { $0.id == beforeID }) {
            next.items.insert(item, at: target)
        } else {
            next.items.append(item)
        }
        try commit(next); return next
    }

    public func reorder(_ ids: [UUID], parentID: UUID?) throws -> LibrarySnapshot {
        var next = try current()
        try checkParent(parentID, in: next)
        let siblings = next.children(of: parentID)
        guard ids.count == siblings.count, Set(ids).count == ids.count, Set(ids) == Set(siblings.map(\.id)) else {
            throw LibraryError.unavailable
        }
        let lookup = Dictionary(uniqueKeysWithValues: siblings.map { ($0.id, $0) })
        var iterator = ids.makeIterator()
        next.items = next.items.map { item in
            guard lookup[item.id] != nil, let id = iterator.next() else { return item }
            return lookup[id]!
        }
        try commit(next); return next
    }

    /// Repairs the index hint when a document's own kind differs (index
    /// rewritten by an older build). No commit if nothing changes.
    public func setKind(_ id: UUID, kind: DocumentKind) throws -> LibrarySnapshot {
        var next = try current()
        guard let index = next.items.firstIndex(where: { $0.id == id }), !next.items[index].isFolder else { throw LibraryError.unavailable }
        let value: DocumentKind? = kind == .textDocument ? .textDocument : nil
        guard next.items[index].kind != value else { return next }
        next.items[index].kind = value
        try commit(next); return next
    }

    public func setFavorite(_ id: UUID, value: Bool) throws -> LibrarySnapshot {
        var next = try current()
        let index = try activeIndex(id, in: next)
        next.items[index].favorite = value
        try commit(next); return next
    }

    public func markOpened(_ id: UUID) throws -> LibrarySnapshot {
        var next = try current()
        let index = try activeIndex(id, in: next)
        guard !next.items[index].isFolder else { throw LibraryError.unavailable }
        next.items[index].lastOpened = Date()
        try commit(next); return next
    }

    public func trash(_ id: UUID) throws -> LibrarySnapshot {
        var next = try current()
        let index = try activeIndex(id, in: next)
        next.items[index].deletedAt = Date()
        try commit(next); return next
    }

    public func restore(_ id: UUID) throws -> LibrarySnapshot {
        var next = try current()
        guard let index = next.items.firstIndex(where: { $0.id == id }), next.items[index].deletedAt != nil else {
            throw LibraryError.unavailable
        }
        if let parent = next.items[index].parentID, next.isTrashed(parent) { next.items[index].parentID = nil }
        next.items[index].deletedAt = nil
        try commit(next); return next
    }

    /// Permanently removes trashed items. Only items already in the trash
    /// (directly or through a trashed ancestor) are accepted; a trashed folder
    /// takes all its descendants with it. Any other ID refuses the whole call.
    /// Order: the new index is committed first (atomic, like every other
    /// mutation) and then also written as the fallback copy, so neither index
    /// can reference a removed package. Only afterwards are the package
    /// directories renamed into `Library/Purging` and removed. A failure after
    /// the index write leaves orphaned files, never a corrupt index.
    public func purge(ids: [UUID]) throws -> LibraryPurgeResult {
        let value = try current()
        guard !ids.isEmpty else { return LibraryPurgeResult(snapshot: value, purgedIDs: [], leftoverDirectories: 0, retainedIDs: []) }
        for id in ids {
            guard value.items.contains(where: { $0.id == id }), value.isTrashed(id) else { throw LibraryError.unavailable }
        }
        let removing = Self.subtree(of: Set(ids), in: value)
        guard !value.items.contains(where: { removing.contains($0.id) && $0.source == .legacyMain }) else {
            throw LibraryError.notPurgeable
        }
        // Validate every package path before touching the index: no symbolic
        // links, nothing outside the root. Missing packages need no removal.
        var directories: [URL] = []
        for item in value.items where removing.contains(item.id) && !item.isFolder {
            let url = try packageURL(item)
            guard fm.fileExists(atPath: url.path) || (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true else { continue }
            try requireDirectory(url)
            directories.append(url)
        }
        var next = value
        next.items.removeAll { removing.contains($0.id) }
        try commit(next)
        let purged = value.items.filter { removing.contains($0.id) }.map(\.id)
        // Second commit replaces index-previous.json, too. If it fails, keep the
        // packages: the fallback index may still reference them.
        do { try commit(next) } catch {
            return LibraryPurgeResult(snapshot: next, purgedIDs: purged, leftoverDirectories: directories.count, retainedIDs: [])
        }
        var leftovers = 0
        let staging = directory.appendingPathComponent("Purging", isDirectory: true)
        cleanPurgingLeftovers(staging)
        for url in directories {
            do {
                try fm.createDirectory(at: staging, withIntermediateDirectories: true)
                try requireDirectory(staging)
                try requireDirectory(url)
                let target = staging.appendingPathComponent("\(url.lastPathComponent)-\(UUID().uuidString)", isDirectory: true)
                // Rename first: a half-removed package is never rediscovered.
                try fm.moveItem(at: url, to: target)
                try fm.removeItem(at: target)
            } catch { leftovers += 1 }
        }
        cleanPurgingLeftovers(staging)
        return LibraryPurgeResult(snapshot: next, purgedIDs: purged, leftoverDirectories: leftovers, retainedIDs: [])
    }

    /// Purges every trash root except subtrees that contain the legacy main
    /// notebook; those stay in the trash and are reported as retained.
    public func emptyTrash() throws -> LibraryPurgeResult {
        let value = try current()
        let roots = value.items.filter { $0.deletedAt != nil }.map(\.id)
        var retained: [UUID] = []
        var purgeable: [UUID] = []
        for id in roots {
            let tree = Self.subtree(of: [id], in: value)
            if value.items.contains(where: { tree.contains($0.id) && $0.source == .legacyMain }) { retained.append(id) }
            else { purgeable.append(id) }
        }
        // Roots nested below another purgeable root are covered by its subtree.
        let result = try purge(ids: purgeable)
        return LibraryPurgeResult(snapshot: result.snapshot, purgedIDs: result.purgedIDs,
                                  leftoverDirectories: result.leftoverDirectories, retainedIDs: retained)
    }

    private static func subtree(of ids: Set<UUID>, in value: LibrarySnapshot) -> Set<UUID> {
        let lookup = Dictionary(uniqueKeysWithValues: value.items.map { ($0.id, $0) })
        var result = Set<UUID>()
        for item in value.items {
            var current: LibraryItem? = item
            var visited = Set<UUID>()
            while let candidate = current, visited.insert(candidate.id).inserted {
                if ids.contains(candidate.id) { result.insert(item.id); break }
                current = candidate.parentID.flatMap { lookup[$0] }
            }
        }
        return result
    }

    /// Package paths are derived from source + ID only; never stored.
    private func packageURL(id: UUID, source: LibrarySource) -> URL {
        switch source {
        case .legacyMain: root
        case .restored: root.appendingPathComponent("Restores/\(id.uuidString)", isDirectory: true)
        case .library: root.appendingPathComponent("Library/Documents/\(id.uuidString)", isDirectory: true)
        }
    }

    /// Purgeable packages only; the legacy main notebook lives in the root.
    private func packageURL(_ item: LibraryItem) throws -> URL {
        guard let source = item.source, source != .legacyMain else { throw LibraryError.notPurgeable }
        return packageURL(id: item.id, source: source)
    }

    /// Removes only direct entries of our own staging directory; symbolic links
    /// are unlinked, never followed.
    private func cleanPurgingLeftovers(_ staging: URL) {
        guard (try? requireDirectory(staging)) != nil,
              let entries = try? fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil, options: []) else { return }
        for entry in entries { try? fm.removeItem(at: entry) }
    }

    private var currentSnapshot: LibrarySnapshot { snapshot ?? LibrarySnapshot() }
    private func current() throws -> LibrarySnapshot {
        guard let snapshot else { throw LibraryError.unavailable }
        return snapshot
    }
    private func checkParent(_ id: UUID?, in value: LibrarySnapshot) throws {
        guard let id else { return }
        guard value.items.contains(where: { $0.id == id && $0.isFolder }), !value.isTrashed(id) else {
            throw LibraryError.invalidDestination
        }
    }
    /// Valid folder target that is neither the moved item nor one of its descendants.
    private func checkDestination(_ parentID: UUID?, moving id: UUID, in value: LibrarySnapshot) throws {
        try checkParent(parentID, in: value)
        var ancestor = parentID
        while let parent = ancestor {
            guard parent != id else { throw LibraryError.invalidDestination }
            ancestor = value.items.first(where: { $0.id == parent })?.parentID
        }
    }
    private func activeIndex(_ id: UUID, in value: LibrarySnapshot) throws -> Int {
        guard let index = value.items.firstIndex(where: { $0.id == id }), !value.isTrashed(id) else {
            throw LibraryError.unavailable
        }
        return index
    }
    private func hasDocument(at url: URL) -> Bool {
        ["manifest.json", "manifest-previous.json", "notebook.json", "recovery.json"].contains {
            fm.fileExists(atPath: url.appendingPathComponent($0).path)
        }
    }
    private func requireDirectory(_ url: URL) throws { try ContainedDirectory.require(url, below: root) }

    private func readIndex() throws {
        var found = false
        for url in [primary, previous] where fm.fileExists(atPath: url.path) {
            found = true
            do {
                try requireDirectory(directory)
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= 4_000_000 else {
                    throw LibraryError.invalidIndex
                }
                let bytes = try BackupArchive.readBounded(url, limit: 4_000_000)
                let value = try decode(bytes)
                snapshot = value; lastGoodBytes = bytes; recovered = url != primary
                return
            } catch LibraryError.unsupportedVersion(let version) { throw LibraryError.unsupportedVersion(version) }
            catch { continue }
        }
        guard !found else { throw LibraryError.invalidIndex }
        snapshot = LibrarySnapshot()
    }

    private func decode(_ bytes: Data) throws -> LibrarySnapshot {
        struct Header: Decodable { var formatVersion: Int }
        let version = try JSONDecoder().decode(Header.self, from: bytes).formatVersion
        guard version == 1 else { throw LibraryError.unsupportedVersion(version) }
        let envelope = try JSONDecoder().decode(LibraryEnvelope.self, from: bytes)
        guard SnapshotChecksum.crc32(envelope.payload) == envelope.crc32 else { throw LibraryError.invalidIndex }
        let value = try JSONDecoder().decode(LibrarySnapshot.self, from: envelope.payload)
        try value.validate()
        return value
    }

    private func commit(_ value: LibrarySnapshot) throws {
        try value.validate()
        let payload = try JSONEncoder().encode(value)
        let bytes = try JSONEncoder().encode(LibraryEnvelope(crc32: SnapshotChecksum.crc32(payload), payload: payload))
        guard bytes.count <= 4_000_000, try decode(bytes) == value else { throw LibraryError.invalidIndex }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try requireDirectory(directory)
        if let lastGoodBytes { try lastGoodBytes.write(to: previous, options: .atomic) }
        try bytes.write(to: primary, options: .atomic)
        snapshot = value; lastGoodBytes = bytes
    }
}

/// Shared by LibraryStore and WorkspaceStore.
enum ContainedDirectory {
    /// A real directory at or below `root`: rejects paths outside the root and
    /// symbolic links in every path component down to the root itself.
    static func require(_ url: URL, below root: URL) throws {
        var checked = url.standardizedFileURL
        let base = root.standardizedFileURL
        guard checked.path == base.path || checked.path.hasPrefix(base.path + "/") else { throw LibraryError.invalidIndex }
        while true {
            let values = try checked.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { throw LibraryError.invalidIndex }
            if checked.path == base.path { break }
            checked.deleteLastPathComponent()
        }
    }
}
