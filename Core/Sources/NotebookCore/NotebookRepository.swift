import Foundation

/// Serial disk work runs on this actor, never on the UI actor.
/// Revisions prevent an older queued autosave from overwriting a replacement.
public actor NotebookRepository {
    private let store: RevisionStore
    private let restoreDirectory: URL
    private var revision = 0

    public init(directory: URL, restoreDirectory: URL? = nil) {
        store = RevisionStore(directory: directory)
        self.restoreDirectory = restoreDirectory ?? directory.appendingPathComponent("Restores", isDirectory: true)
    }

    public func load() throws -> (Notebook, Bool) {
        let document = try store.load()
        return (document, store.recovered)
    }

    public func save(_ document: Notebook, revision: Int) throws {
        guard revision >= self.revision else { return }
        try store.save(document)
        self.revision = revision
    }

    public func backup(_ snapshot: Notebook) throws -> Data {
        try BackupArchive.encode(snapshot)
    }

    public func prepareRestore(from url: URL) throws -> PreparedRestore {
        let data = try BackupArchive.read(url)
        return try prepareRestore(data: data)
    }

    public func localHistory() throws -> LocalHistory {
        try store.localHistory()
    }

    public func prepareLocalRecovery(id: UUID) throws -> PreparedRestore {
        let document = try store.localRevision(id: id)
        return try prepareRestore(data: BackupArchive.encode(document))
    }

    private func prepareRestore(data: Data) throws -> PreparedRestore {
        let decoded = try BackupArchive.decode(data)
        let id = UUID()
        let stage = store.directory.appendingPathComponent("BackupStaging/\(id.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        let stagedFile = stage.appendingPathComponent("input.notybackup")
        try data.write(to: stagedFile, options: .atomic)
        let staged = try BackupArchive.read(stagedFile)
        guard staged == data else { throw BackupError.invalidStaging }
        var copy = try BackupArchive.decode(staged).document
        copy.id = id
        copy.schemaVersion = max(2, copy.schemaVersion)
        copy.title += " (Wiederhergestellt)"
        return PreparedRestore(id: id, document: copy, isLegacyJSON: decoded.isLegacyJSON,
                               archiveCRC32: SnapshotChecksum.crc32(staged))
    }

    /// Call only after the UI actor validates PDFKit/PencilKit contents of the
    /// prepared document. The current store and its revision counter never change.
    public func commitRestore(_ prepared: PreparedRestore) throws -> RestoredNotebook {
        let stage = store.directory.appendingPathComponent("BackupStaging/\(prepared.id.uuidString)", isDirectory: true)
        let data = try BackupArchive.read(stage.appendingPathComponent("input.notybackup"))
        guard SnapshotChecksum.crc32(data) == prepared.archiveCRC32 else { throw BackupError.invalidStaging }
        var copy = try BackupArchive.decode(data).document
        copy.id = prepared.id
        copy.schemaVersion = max(2, copy.schemaVersion)
        copy.title += " (Wiederhergestellt)"
        guard copy == prepared.document else { throw BackupError.invalidStaging }
        let destination = restoreDirectory.appendingPathComponent(prepared.id.uuidString, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw BackupError.invalidStaging }
        let restored = RevisionStore(directory: destination)
        try restored.save(copy)
        guard try RevisionStore(directory: destination).load() == copy else { throw BackupError.invalidStaging }
        try? FileManager.default.removeItem(at: stage)
        return restoredEntry(copy, directory: destination)
    }

    public func restoredCopies() throws -> RestoreCatalog {
        let root = restoreDirectory
        guard FileManager.default.fileExists(atPath: root.path) else { return RestoreCatalog() }
        let directories = try FileManager.default.contentsOfDirectory(at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
        var catalog = RestoreCatalog()
        for directory in directories.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let id = UUID(uuidString: directory.lastPathComponent), id.uuidString == directory.lastPathComponent else { continue }
            do {
                let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isDirectory == true, values.isSymbolicLink != true else { throw BackupError.invalidStaging }
                let document = try RevisionStore(directory: directory).load()
                guard document.id == id else { throw BackupError.invalidStaging }
                catalog.notebooks.append(restoredEntry(document, directory: directory))
            } catch { catalog.unreadableCount += 1 }
        }
        return catalog
    }

    private func restoredEntry(_ document: Notebook, directory: URL) -> RestoredNotebook {
        let date = (try? directory.appendingPathComponent("manifest.json")
            .resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        var previews: [RestoredPagePreview] = []
        for (index, page) in document.pages.enumerated() {
            guard !page.searchableText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            previews.append(RestoredPagePreview(id: page.id, pageNumber: index + 1,
                text: String(page.searchableText.replacingOccurrences(of: "\n", with: " ").prefix(160))))
            if previews.count == 4 { break }
        }
        return RestoredNotebook(id: document.id, title: document.title, directory: directory,
                                collectionDirectory: restoreDirectory, modifiedAt: date, textPages: previews)
    }

    public func replace(_ document: Notebook, preserving current: Notebook?, revision: Int) throws {
        guard revision >= self.revision else { return }
        let archive = store.directory.appendingPathComponent("Archives/\(UUID().uuidString)", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: archive, withIntermediateDirectories: true)
        if let current {
            try JSONEncoder().encode(current).write(to: archive.appendingPathComponent("before-import.noty"), options: .atomic)
        }
        // Keep exact bytes too, even when the originals were unreadable.
        for name in ["notebook.json", "recovery.json", "manifest.json", "manifest-previous.json", "Revisions"] {
            let original = store.directory.appendingPathComponent(name)
            if fm.fileExists(atPath: original.path) {
                try fm.copyItem(at: original, to: archive.appendingPathComponent(name))
            }
        }
        try store.replaceArchivedOriginal(with: document)
        self.revision = revision
    }
}
