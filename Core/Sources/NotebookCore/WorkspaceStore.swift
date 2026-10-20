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
public struct PreparedLibraryRestore: Sendable {
    public let id: UUID
    public let bundle: LibraryBundle
    let crc32: UInt32
}

/// Separate logical instances in the same app/container, not separate signed
/// apps. An interrupted restore stays in Staging, invisible to the workspace
/// picker. Publishing is a same-volume rename, never a merge with current notes.
public actor WorkspaceStore {
    public let root: URL
    private let fm = FileManager.default
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

    public func prepareRestore(file: URL) throws -> PreparedLibraryRestore {
        let bytes = try LibraryArchive.read(file)
        let bundle = try LibraryArchive.decode(bytes)
        let id = UUID()
        let stage = staging.appendingPathComponent(id.uuidString, isDirectory: true)
        try createStage(stage)
        let input = stage.appendingPathComponent("input.notylibrary")
        try bytes.write(to: input, options: .atomic)
        guard try LibraryArchive.read(input) == bytes else { throw LibraryArchiveError.invalid }
        return PreparedLibraryRestore(id: id, bundle: bundle, crc32: SnapshotChecksum.crc32(bytes))
    }

    /// UI validates all PDFKit/PencilKit contents before this call.
    public func commitRestore(_ prepared: PreparedLibraryRestore, title: String) async throws -> TestWorkspace {
        let stage = staging.appendingPathComponent(prepared.id.uuidString, isDirectory: true)
        try regularDirectory(stage)
        let input = stage.appendingPathComponent("input.notylibrary")
        let properties = try input.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard properties.isRegularFile == true, properties.isSymbolicLink != true else { throw BackupError.invalidStaging }
        let bytes = try LibraryArchive.read(input)
        guard SnapshotChecksum.crc32(bytes) == prepared.crc32,
              try LibraryArchive.decode(bytes) == prepared.bundle else { throw BackupError.invalidStaging }
        let data = stage.appendingPathComponent("Data", isDirectory: true)
        try await LibraryStore(root: data).populateEmpty(prepared.bundle)
        // A fresh independent store must reopen every restored document before
        // the result is published. Canonical paths differ from legacy sources.
        let result = try await LibraryStore(root: data).backupBundle()
        guard Dictionary(uniqueKeysWithValues: result.documents.map { ($0.id, $0) }) ==
                Dictionary(uniqueKeysWithValues: prepared.bundle.documents.map { ($0.id, $0) }),
              result.toolbar == prepared.bundle.toolbar else {
            throw LibraryArchiveError.incomplete
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
