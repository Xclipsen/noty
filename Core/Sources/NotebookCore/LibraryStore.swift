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
    public var isFolder: Bool { source == nil }

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

public enum LibraryError: Error, LocalizedError {
    case invalidIndex, unavailable, invalidDestination, invalidTitle, unsupportedVersion(Int)
    public var errorDescription: String? {
        switch self {
        case .invalidIndex: "Der Bibliotheksindex ist nicht lesbar. Vorhandene Hefte bleiben erhalten."
        case .unavailable: "Dieser Eintrag ist nicht mehr verfügbar. Bitte die Bibliothek neu laden."
        case .invalidDestination: "Dieses Ziel ist nicht möglich. Ein Ordner kann nicht in sich selbst oder einen Unterordner verschoben werden."
        case .invalidTitle: "Bitte einen Namen mit 1 bis 120 Zeichen ohne Zeilenumbrüche eingeben."
        case .unsupportedVersion(let version): "Bibliotheksformat \(version) benötigt eine neuere noty-Version."
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
        let notebook = try RevisionStore(directory: url).load()
        if source != .legacyMain {
            guard notebook.id.uuidString == url.lastPathComponent else { throw LibraryError.invalidIndex }
        }
        guard !candidate.items.contains(where: { $0.id == notebook.id }) else { throw LibraryError.invalidIndex }
        let title = (try? Self.validTitle(notebook.title)) ?? "Unbenanntes Heft"
        candidate.items.append(LibraryItem(id: notebook.id, title: title, source: source))
    }

    /// Read-only, serialized with other library work; metadata remains in the
    /// versioned notebook so the index does not duplicate cover/paper settings.
    public func previewDocument(id: UUID) throws -> Notebook {
        try RevisionStore(directory: documentURL(id: id)).load()
    }

    public func documentURL(id: UUID) throws -> URL {
        let item = try current().items.first { $0.id == id }
        guard let item, let source = item.source, !currentSnapshot.isTrashed(id) else { throw LibraryError.unavailable }
        let url: URL
        switch source {
        case .legacyMain: url = root
        case .restored: url = root.appendingPathComponent("Restores/\(id.uuidString)", isDirectory: true)
        case .library: url = root.appendingPathComponent("Library/Documents/\(id.uuidString)", isDirectory: true)
        }
        try requireDirectory(url)
        guard hasDocument(at: url) else { throw LibraryError.unavailable }
        return url
    }

    /// UI calls only with all editors closed and library mutations disabled.
    /// This synchronous actor operation captures the complete index + documents
    /// without suspension. Includes independently trashed children and folders.
    public func backupBundle() throws -> LibraryBundle {
        let result = try load()
        guard result.unreadableDocuments == 0 else { throw LibraryArchiveError.incomplete }
        var documents: [Notebook] = []
        for item in result.snapshot.items where !item.isFolder {
            let url: URL
            switch item.source! {
            case .legacyMain: url = root
            case .restored: url = root.appendingPathComponent("Restores/\(item.id.uuidString)", isDirectory: true)
            case .library: url = root.appendingPathComponent("Library/Documents/\(item.id.uuidString)", isDirectory: true)
            }
            try requireDirectory(url)
            guard hasDocument(at: url) else { throw LibraryArchiveError.incomplete }
            let store = RevisionStore(directory: url)
            var document = try store.load()
            guard document.id == item.id, !store.recovered else { throw LibraryArchiveError.incomplete }
            document.title = item.title
            documents.append(document)
        }
        let preferences = try ToolbarPreferenceStore.read(root: root)
        let bundle = LibraryBundle(snapshot: result.snapshot, documents: documents, toolbar: preferences.0)
        try bundle.validate(); return bundle
    }

    /// Only for an unpublished empty restore stage, never an existing library.
    /// WorkspaceStore atomically publishes the whole validated directory later.
    public func populateEmpty(_ bundle: LibraryBundle) throws {
        try bundle.validate()
        guard !fm.fileExists(atPath: root.path) else { throw LibraryArchiveError.destinationExists }
        var portable = bundle.snapshot
        portable.items = bundle.snapshot.items.map { item in
            var copy = LibraryItem(id: item.id, title: item.title, parentID: item.parentID,
                                   source: item.isFolder ? nil : .library)
            copy.favorite = item.favorite; copy.lastOpened = item.lastOpened; copy.deletedAt = item.deletedAt
            return copy
        }
        let documentsRoot = directory.appendingPathComponent("Documents", isDirectory: true)
        try fm.createDirectory(at: documentsRoot, withIntermediateDirectories: true)
        try requireDirectory(documentsRoot)
        for document in bundle.documents {
            let destination = documentsRoot.appendingPathComponent(document.id.uuidString, isDirectory: true)
            try RevisionStore(directory: destination).save(document)
            guard try RevisionStore(directory: destination).load() == document else { throw LibraryArchiveError.incomplete }
        }
        try bundle.toolbar.validate()
        try JSONEncoder().encode(bundle.toolbar).write(to: root.appendingPathComponent("toolbar.json"), options: .atomic)
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
        guard !next.items.contains(where: { $0.id == notebook.id }) else { throw LibraryError.invalidIndex }
        let title = try Self.validTitle(notebook.title)
        let destination = root.appendingPathComponent("Library/Documents/\(notebook.id.uuidString)", isDirectory: true)
        guard !fm.fileExists(atPath: destination.path) else { throw LibraryError.invalidIndex }
        let parent = destination.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        try requireDirectory(parent)
        try RevisionStore(directory: destination).save(notebook)
        guard try RevisionStore(directory: destination).load() == notebook else { throw LibraryError.invalidIndex }
        next.items.append(LibraryItem(id: notebook.id, title: title, parentID: parentID, source: .library))
        try commit(next)
        return next
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
        try checkParent(parentID, in: next)
        var ancestor = parentID
        while let parent = ancestor {
            guard parent != id else { throw LibraryError.invalidDestination }
            ancestor = next.items.first(where: { $0.id == parent })?.parentID
        }
        var item = next.items.remove(at: index)
        item.parentID = parentID
        next.items.append(item)
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
    private func requireDirectory(_ url: URL) throws {
        // Reject symbolic links in every path component below our container root.
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
