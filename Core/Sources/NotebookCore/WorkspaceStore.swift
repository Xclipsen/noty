import Foundation

public enum WorkspaceKind: String, Codable, Sendable { case test, restored }
public struct TestWorkspace: Codable, Equatable, Identifiable, Sendable {
    public var formatVersion = 1
    public let id: UUID
    public let title: String
    public let kind: WorkspaceKind
    public let createdAt: Date
}
public struct WorkspaceList: Sendable {
    public var workspaces: [TestWorkspace] = []
    public var unreadableCount = 0
}
/// Token for one staged archive; bound to its exact size/CRC and contents.
public struct PreparedLibraryRestore: Sendable {
    public let id: UUID
    public let summary: LibraryArchiveSummary
}

/// Separate logical instances in the same app/container, not separate signed
/// apps. An interrupted restore stays in Staging, invisible to the workspace
/// picker. Publishing is a same-volume rename, never a merge with current notes.
public actor WorkspaceStore {
    public let root: URL
    private let fm = FileManager.default
    /// Stages this store created and still owns (prepared, not yet committed or
    /// discarded). Startup cleanup never touches them.
    private var activeStages = Set<UUID>()
    public init(root: URL) { self.root = root }
    private var areas: URL { root.appendingPathComponent("Areas", isDirectory: true) }
    private var staging: URL { root.appendingPathComponent("Staging", isDirectory: true) }

    public func list() throws -> WorkspaceList {
        guard fm.fileExists(atPath: areas.path) else { return WorkspaceList() }
        try regularDirectory(areas)
        var result = WorkspaceList()
        for folder in try fm.contentsOfDirectory(at: areas, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            guard let id = UUID(uuidString: folder.lastPathComponent), folder.lastPathComponent == id.uuidString else { continue }
            do {
                try regularDirectory(folder)
                let recordURL = folder.appendingPathComponent("workspace.json")
                let properties = try recordURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard properties.isRegularFile == true, properties.isSymbolicLink != true else { throw LibraryError.invalidIndex }
                let record = try JSONDecoder().decode(TestWorkspace.self, from: BackupArchive.readBounded(recordURL, limit: 16_000))
                guard record.formatVersion == 1, record.id == id else { throw LibraryError.invalidIndex }
                _ = try LibraryStore.validTitle(record.title)
                try regularDirectory(folder.appendingPathComponent("Data", isDirectory: true))
                result.workspaces.append(record)
            } catch { result.unreadableCount += 1 }
        }
        result.workspaces.sort { $0.createdAt > $1.createdAt }
        return result
    }

    public func directory(for id: UUID) throws -> URL {
        guard try list().workspaces.contains(where: { $0.id == id }) else { throw LibraryError.unavailable }
        return areas.appendingPathComponent("\(id.uuidString)/Data", isDirectory: true)
    }

    public func createTest(title: String) async throws -> TestWorkspace {
        let id = UUID()
        let stage = staging.appendingPathComponent(id.uuidString, isDirectory: true)
        try createStage(stage)
        activeStages.insert(id); defer { activeStages.remove(id) }
        let data = stage.appendingPathComponent("Data", isDirectory: true)
        var snapshot = LibrarySnapshot()
        let folder = LibraryItem(title: "Steuerrecht")
        let other = LibraryItem(title: "Rechnungswesen")
        var notebook = Notebook(); notebook.title = "Werkzeugtest"
        notebook.pages[0].text = "Testbereich · ÄÖÜ ß\nHier können wir gefahrlos ausprobieren."
        snapshot.items = [folder, other, LibraryItem(id: notebook.id, title: notebook.title, parentID: folder.id, source: .library)]
        try await LibraryStore(root: data).populateEmpty(LibraryBundle(snapshot: snapshot, documents: [notebook]))
        return try publish(stage: stage, id: id, title: title, kind: .test)
    }

    /// Copies the chosen file block-wise into a new stage and verifies the copy
    /// in one streaming pass; `validate` (Apple-framework checks) sees every
    /// notebook once, off the UI actor. A failed preparation removes its stage.
    public func prepareRestore(file: URL, validate: @Sendable (Notebook) throws -> Void = { _ in }) throws -> PreparedLibraryRestore {
        let id = UUID()
        let stage = staging.appendingPathComponent(id.uuidString, isDirectory: true)
        try createStage(stage)
        do {
            let input = stage.appendingPathComponent("input.notylibrary")
            let copied = try BoundedFile.copy(from: file, to: input)
            let summary = try LibraryArchive.verify(input, visit: validate)
            guard summary.file == copied else { throw BackupError.invalidStaging }
            activeStages.insert(id)
            return PreparedLibraryRestore(id: id, summary: summary)
        } catch {
            try? fm.removeItem(at: stage)
            throw error
        }
    }

    /// Drops a prepared, never committed stage (e.g. the user cancelled).
    public func discardRestore(_ prepared: PreparedLibraryRestore) throws {
        activeStages.remove(prepared.id)
        try removeStage(prepared.id)
    }

    /// Startup: unpublished stages older than `age` that this store does not own
    /// (interrupted or failed earlier runs; the user still has the original
    /// archive). Only UUID-named real directories directly inside `Staging/`;
    /// published areas, foreign names and symbolic links are never touched.
    @discardableResult
    public func removeStaleStages(olderThan age: TimeInterval = 24 * 3600, now: Date = Date()) -> Int {
        guard (try? regularDirectory(staging)) != nil,
              let entries = try? fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil, options: []) else { return 0 }
        var removed = 0
        for entry in entries {
            guard let id = UUID(uuidString: entry.lastPathComponent), entry.lastPathComponent == id.uuidString, !activeStages.contains(id),
                  let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey, .creationDateKey]),
                  values.isDirectory == true, values.isSymbolicLink != true else { continue }
            let touched = [values.contentModificationDate, values.creationDate].compactMap { $0 }.max() ?? .distantPast
            guard now.timeIntervalSince(touched) > age, (try? removeStage(id)) != nil else { continue }
            removed += 1
        }
        return removed
    }

    /// Only a real directory `Staging/<id>` below this root; never an area.
    private func removeStage(_ id: UUID) throws {
        let stage = staging.appendingPathComponent(id.uuidString, isDirectory: true)
        guard fm.fileExists(atPath: stage.path) else { return }
        try regularDirectory(stage)
        try fm.removeItem(at: stage)
    }

    /// UI validated all PDFKit/PencilKit contents during preparation. The staged
    /// bytes must still match exactly; a second streaming pass re-checks every
    /// chunk while writing it into its own new package (one notebook at a time).
    /// Any failure removes this stage (up to the archive size of disk space);
    /// the token is then spent and a new restore starts from the original file.
    public func commitRestore(_ prepared: PreparedLibraryRestore, title: String) async throws -> TestWorkspace {
        let stage = staging.appendingPathComponent(prepared.id.uuidString, isDirectory: true)
        try regularDirectory(stage)
        // Still owned while the commit suspends (actor reentrancy vs. cleanup).
        defer { activeStages.remove(prepared.id) }
        do { return try await commitStage(stage, prepared, title: title) }
        catch {
            try? removeStage(prepared.id)
            throw error
        }
    }

    private func commitStage(_ stage: URL, _ prepared: PreparedLibraryRestore, title: String) async throws -> TestWorkspace {
        let input = stage.appendingPathComponent("input.notylibrary")
        let properties = try input.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard properties.isRegularFile == true, properties.isSymbolicLink != true else { throw BackupError.invalidStaging }
        guard (try? BoundedFile.checksum(input)) == prepared.summary.file else { throw BackupError.invalidStaging }
        let data = stage.appendingPathComponent("Data", isDirectory: true)
        guard !fm.fileExists(atPath: data.path) else { throw LibraryArchiveError.destinationExists }
        // Chunk CRCs cover the archived bytes as written (any key order, older
        // builds included); the restored packages are compared by a canonical
        // re-encoding of the decoded value, one notebook at a time.
        var fingerprints: [UUID: LibraryArchiveFileInfo] = [:]
        let summary = try LibraryArchive.verify(input) { document in
            try LibraryStore.populatePackage(document, root: data)
            fingerprints[document.id] = try LibraryArchive.fingerprint(document)
        }
        guard summary == prepared.summary else { throw BackupError.invalidStaging }
        try await LibraryStore(root: data).populateIndex(summary.snapshot, toolbar: summary.toolbar)
        // A fresh independent store must reopen every restored document before
        // the result is published.
        let plan = try await LibraryStore(root: data).backupPlan()
        guard plan.toolbar == summary.toolbar, plan.snapshot.items.map(\.id) == summary.snapshot.items.map(\.id) else {
            throw LibraryArchiveError.incomplete
        }
        for item in plan.documents {
            guard let expected = fingerprints[item.id], try LibraryArchive.fingerprint(plan.committedNotebook(item)) == expected else {
                throw LibraryArchiveError.incomplete
            }
        }
        // The checked source file is kept as part of this workspace's provenance.
        return try publish(stage: stage, id: prepared.id, title: title, kind: .restored)
    }

    private func createStage(_ url: URL) throws {
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        try regularDirectory(staging)
        guard !fm.fileExists(atPath: url.path) else { throw LibraryArchiveError.destinationExists }
        try fm.createDirectory(at: url, withIntermediateDirectories: false)
    }
    private func publish(stage: URL, id: UUID, title: String, kind: WorkspaceKind) throws -> TestWorkspace {
        let record = TestWorkspace(id: id, title: try LibraryStore.validTitle(title), kind: kind, createdAt: Date())
        try JSONEncoder().encode(record).write(to: stage.appendingPathComponent("workspace.json"), options: .atomic)
        try fm.createDirectory(at: areas, withIntermediateDirectories: true)
        try regularDirectory(areas)
        let destination = areas.appendingPathComponent(id.uuidString, isDirectory: true)
        guard !fm.fileExists(atPath: destination.path) else { throw LibraryArchiveError.destinationExists }
        try fm.moveItem(at: stage, to: destination)
        return record
    }
    private func regularDirectory(_ url: URL) throws { try ContainedDirectory.require(url, below: root) }
}
