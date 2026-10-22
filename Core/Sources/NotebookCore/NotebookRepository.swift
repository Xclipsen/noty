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

    /// The package's asset GC on this actor, so it runs strictly between
    /// commits (`RevisionStore.collectAssetGarbage`): the editor calls it once
    /// after opening and once after its last commit when closing. `keeping`:
    /// originals the process still needs from outside the notebook (the in-app
    /// object clipboard). Nil: skipped (a backup or restore runs, the store
    /// already committed, or the state is not committed).
    @discardableResult
    public func collectAssetGarbage(_ moment: RevisionStore.AssetGarbageMoment, current: Notebook? = nil,
                                    keeping: Set<String> = []) throws -> ImageAssetGarbageReport? {
        try store.collectAssetGarbage(moment, current: current, keeping: keeping)
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
        let activity = BackupActivity.shared.begin(); defer { activity.end() }
        return try prepareStaged { input in
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
        let activity = BackupActivity.shared.begin(); defer { activity.end() }
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
            return PreparedRestore(id: id, sourceDocumentID: decoded.document.id,
                                   document: Self.restoredCopy(of: decoded.document, id: id), isLegacyJSON: decoded.isLegacyJSON,
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
    /// references stay (content addresses). The title stays exactly as in the
    /// file; a colliding name is resolved on commit (`NotebookTitles.unique`).
    private static func restoredCopy(of document: Notebook, id: UUID) -> Notebook {
        var copy = document
        copy.id = id
        copy.schemaVersion = max(2, copy.schemaVersion)
        return copy
    }

    /// Removes the unpublished stage of a preparation the user declined
    /// (cancelled import). Only a UUID-named directory directly in our
    /// staging root; nothing else is touched.
    public func discardRestore(_ prepared: PreparedRestore) {
        let stage = stagingRoot.appendingPathComponent(prepared.id.uuidString, isDirectory: true)
        let fm = FileManager.default
        guard let values = try? stage.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory == true, values.isSymbolicLink != true else { return }
        try? fm.removeItem(at: stage)
        if (try? fm.contentsOfDirectory(atPath: stagingRoot.path))?.isEmpty == true { try? fm.removeItem(at: stagingRoot) }
    }

    /// A copy (local history) into this repository's restore collection with
    /// a title that is unique in the library area at `libraryRoot`: the
    /// active notebooks of its committed index plus copies in the collection
    /// that the index does not list yet (created earlier in the same editor
    /// session; the library adopts them on its next load).
    public func commitRestoreCopy(_ prepared: PreparedRestore, libraryRoot: URL) throws -> RestoredNotebook {
        let index = LibraryStore.committedIndex(root: libraryRoot)
        let indexed = Set(index?.items.map(\.id) ?? [])
        var taken = index?.activeNotebookTitles() ?? []
        taken += ((try? restoredCopies().notebooks) ?? []).filter { !indexed.contains($0.id) }.map(\.title)
        return try commitRestore(prepared, title: NotebookTitles.unique(prepared.document.title, taken: taken))
    }

    /// Call only after the UI actor validates PDFKit/PencilKit contents of the
    /// prepared document. The current store and its revision counter never change.
    /// The stage is checked again first: the archive's exact size and CRC (one
    /// pass, which also re-reads the notebook) and the SHA-256 of every staged
    /// original the copy references. Then `RevisionStore.save` writes the
    /// assets first, revision and manifest last, into a new empty package;
    /// read back before the stage is removed. A failure keeps the stage.
    /// `title`: the final (unique) title of the copy, nil keeps the file's
    /// title. `collection`: parent of the new package (an import into the
    /// library uses `Library/Documents`, then `LibraryStore.adoptImported`);
    /// nil is this repository's restore collection.
    public func commitRestore(_ prepared: PreparedRestore, title: String? = nil, into collection: URL? = nil) throws -> RestoredNotebook {
        let activity = BackupActivity.shared.begin(); defer { activity.end() }
        let fm = FileManager.default
        let stage = stagingRoot.appendingPathComponent(prepared.id.uuidString, isDirectory: true)
        let input = stage.appendingPathComponent("input.notybackup")
        let decoded: DecodedBackup
        do { decoded = try BackupArchive.verify(input, handling: .skip, limits: .standard) }
        catch { throw BackupError.invalidStaging }
        guard decoded.file == prepared.archive, decoded.assets == prepared.assetReferences else { throw BackupError.invalidStaging }
        var copy = Self.restoredCopy(of: decoded.document, id: prepared.id)
        guard copy == prepared.document else { throw BackupError.invalidStaging }
        if let title { copy.title = try LibraryStore.validTitle(title) }
        let staged = NotebookAssets(directory: stage.appendingPathComponent(NotebookAssets.directoryName, isDirectory: true), readOnly: true)
        for reference in copy.externalImageAssets {
            guard case .file = try staged.verifiedPayload(for: reference) else { throw BackupError.invalidStaging }
        }
        let parent = collection ?? restoreDirectory
        let destination = parent.appendingPathComponent(prepared.id.uuidString, isDirectory: true)
        guard !fm.fileExists(atPath: destination.path) else { throw BackupError.invalidStaging }
        if collection != nil { try fm.createDirectory(at: parent, withIntermediateDirectories: true) }
        try RevisionStore(directory: destination).save(copy, importingAssetsFrom: staged)
        let reopened = RevisionStore(directory: destination, readOnly: true)
        guard try reopened.load() == copy, reopened.assets.presentOnDisk(copy.externalImageAssets) else {
            throw BackupError.invalidStaging
        }
        try? fm.removeItem(at: stage)
        return restoredEntry(copy, directory: destination, collection: parent)
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

    private func restoredEntry(_ document: Notebook, directory: URL, collection: URL? = nil) -> RestoredNotebook {
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
                                collectionDirectory: collection ?? restoreDirectory, modifiedAt: date, textPages: previews)
    }
}
