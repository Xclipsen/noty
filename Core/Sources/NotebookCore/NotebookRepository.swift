import Foundation

/// Serial disk work runs on this actor, never on the UI actor.
/// Revisions prevent an older queued autosave from overwriting a newer snapshot.
public actor NotebookRepository {
    private let store: RevisionStore
    private let restoreDirectory: URL
    private var revision = 0
    /// The package's image originals: committed files plus the pending area
    /// (imports staged from any thread, embedded originals of an old schema).
    /// The single writer is this repository's store; rendering only reads.
    public nonisolated let assets: NotebookAssets

    public init(directory: URL, restoreDirectory: URL? = nil) {
        store = RevisionStore(directory: directory)
        assets = store.assets
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

    /// Writes a verified `.notybackup` (format 2) of `snapshot` into a new
    /// file at `url` (a scratch file the caller owns; never replaced). The
    /// originals come from the writable store's assets: committed files and
    /// pending ones, so not yet committed images are included.
    @discardableResult
    public func backup(_ snapshot: Notebook, to url: URL) throws -> DecodedBackup {
        try BackupArchive.write(snapshot, assets: store.assets, to: url)
    }

    /// Copies the chosen file block-wise into a new stage, then verifies the
    /// copy in one streaming pass (format 2: every asset verified into the
    /// stage's `Assets/`; format 1 and prototype JSON in memory, ≤ 200 MB).
    /// Originals embedded by schema 5–11 land in the stage's `Assets/` too, so
    /// every restore copy is a schema-12 package with assets.
    /// A failed preparation removes its stage.
    public func prepareRestore(from url: URL) throws -> PreparedRestore {
        try prepareStaged { input in
            do { return try BoundedFile.copy(from: url, to: input, limit: BackupArchive.maximumFileBytes) }
            catch LibraryArchiveError.archiveTooLarge { throw BackupError.fileTooLarge }
        }
    }

    public func localHistory() throws -> LocalHistory {
        try store.localHistory()
    }

    /// A kept local revision through the same staged path: written as a
    /// verified archive into the stage (assets from this package, where every
    /// revision's originals stay as GC roots), then checked like an import.
    public func prepareLocalRecovery(id: UUID) throws -> PreparedRestore {
        let decoded = try store.localRevision(id: id)
        // Originals an older revision embedded (schema ≤ 11) first, then this package.
        let assets = ChainedImageAssets([decoded.inlineAssets, store.assets])
        return try prepareStaged { input in try BackupArchive.write(decoded.notebook, assets: assets, to: input).file }
    }

    private var stagingRoot: URL { store.directory.appendingPathComponent("BackupStaging", isDirectory: true) }

    private func prepareStaged(_ fill: (URL) throws -> LibraryArchiveFileInfo) throws -> PreparedRestore {
        let fm = FileManager.default
        let id = UUID()
        let stage = stagingRoot.appendingPathComponent(id.uuidString, isDirectory: true)
        try fm.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: false)
        do {
            let input = stage.appendingPathComponent("input.notybackup")
            let copied = try fill(input)
            let assetDirectory = stage.appendingPathComponent(NotebookAssets.directoryName, isDirectory: true)
            try fm.createDirectory(at: assetDirectory, withIntermediateDirectories: false)
            let decoded = try BackupArchive.verify(input, extractingAssetsTo: assetDirectory)
            guard decoded.file == copied else { throw BackupError.invalidStaging }
            return PreparedRestore(id: id, document: Self.restoredCopy(of: decoded.document, id: id), isLegacyJSON: decoded.isLegacyJSON,
                                   assets: NotebookAssets(directory: assetDirectory, readOnly: true),
                                   archive: copied, assetReferences: decoded.assets)
        } catch {
            try? fm.removeItem(at: stage)
            // No empty staging root is left behind by a rejected file.
            if (try? fm.contentsOfDirectory(atPath: stagingRoot.path))?.isEmpty == true { try? fm.removeItem(at: stagingRoot) }
            throw error
        }
    }

    /// Separate document identity; the original stays untouched. Image asset
    /// references stay (content addresses).
    private static func restoredCopy(of document: Notebook, id: UUID) -> Notebook {
        var copy = document
        copy.id = id
        copy.schemaVersion = max(2, copy.schemaVersion)
        copy.title += " (Wiederhergestellt)"
        return copy
    }

    /// Call only after the UI actor validates PDFKit/PencilKit contents of the
    /// prepared document. The current store and its revision counter never change.
    /// The stage is checked again first: the archive's exact size and CRC (one
    /// pass, which also re-reads the notebook) and the SHA-256 of every staged
    /// original the copy references. Then `RevisionStore.save` writes the
    /// assets first, revision and manifest last, into a new empty package;
    /// read back before the stage is removed. A failure keeps the stage.
    public func commitRestore(_ prepared: PreparedRestore) throws -> RestoredNotebook {
        let fm = FileManager.default
        let stage = stagingRoot.appendingPathComponent(prepared.id.uuidString, isDirectory: true)
        let input = stage.appendingPathComponent("input.notybackup")
        let decoded: DecodedBackup
        do { decoded = try BackupArchive.verify(input, handling: .skip, limits: .standard) }
        catch { throw BackupError.invalidStaging }
        guard decoded.file == prepared.archive, decoded.assets == prepared.assetReferences else { throw BackupError.invalidStaging }
        let copy = Self.restoredCopy(of: decoded.document, id: prepared.id)
        guard copy == prepared.document else { throw BackupError.invalidStaging }
        let staged = NotebookAssets(directory: stage.appendingPathComponent(NotebookAssets.directoryName, isDirectory: true), readOnly: true)
        for reference in copy.externalImageAssets {
            guard case .file = try staged.verifiedPayload(for: reference) else { throw BackupError.invalidStaging }
        }
        let destination = restoreDirectory.appendingPathComponent(prepared.id.uuidString, isDirectory: true)
        guard !fm.fileExists(atPath: destination.path) else { throw BackupError.invalidStaging }
        try RevisionStore(directory: destination).save(copy, importingAssetsFrom: staged)
        let reopened = RevisionStore(directory: destination, readOnly: true)
        guard try reopened.load() == copy, reopened.assets.presentOnDisk(copy.externalImageAssets) else {
            throw BackupError.invalidStaging
        }
        try? fm.removeItem(at: stage)
        return restoredEntry(copy, directory: destination)
    }

    /// Listing for the library. A copy is decoded again only after its
    /// manifest.json changed (every commit replaces it: new date/size); a
    /// long-lived repository therefore lists unchanged copies without reading
    /// their revisions. Opening a copy still validates it completely.
    public func restoredCopies() throws -> RestoreCatalog {
        let root = restoreDirectory
        guard FileManager.default.fileExists(atPath: root.path) else { catalogCache = [:]; return RestoreCatalog() }
        let directories = try FileManager.default.contentsOfDirectory(at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])
        var catalog = RestoreCatalog()
        var cache: [String: CatalogEntry] = [:]
        for directory in directories.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let id = UUID(uuidString: directory.lastPathComponent), id.uuidString == directory.lastPathComponent else { continue }
            do {
                let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isDirectory == true, values.isSymbolicLink != true else { throw BackupError.invalidStaging }
                let stamp = Self.manifestStamp(directory)
                if let stamp, let cached = catalogCache[directory.path], cached.stamp == stamp {
                    catalog.notebooks.append(cached.entry); cache[directory.path] = cached; continue
                }
                let document = try RevisionStore(directory: directory, readOnly: true).load()
                guard document.id == id else { throw BackupError.invalidStaging }
                let entry = restoredEntry(document, directory: directory)
                catalog.notebooks.append(entry)
                if let stamp { cache[directory.path] = CatalogEntry(stamp: stamp, entry: entry) }
            } catch { catalog.unreadableCount += 1 }
        }
        catalogCache = cache
        return catalog
    }

    private struct ManifestStamp: Equatable, Sendable { let modified: Date; let size: Int }
    private struct CatalogEntry: Sendable { let stamp: ManifestStamp; let entry: RestoredNotebook }
    private var catalogCache: [String: CatalogEntry] = [:]

    private static func manifestStamp(_ directory: URL) -> ManifestStamp? {
        let values = try? directory.appendingPathComponent("manifest.json")
            .resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard let values, values.isRegularFile == true, values.isSymbolicLink != true,
              let modified = values.contentModificationDate, let size = values.fileSize else { return nil }
        return ManifestStamp(modified: modified, size: size)
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
}
