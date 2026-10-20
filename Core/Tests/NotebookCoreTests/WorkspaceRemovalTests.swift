import Foundation
import XCTest
@testable import NotebookCore

/// Removing a Bereich: never „Meine Bibliothek“, never the last or the open
/// area, only a real `Areas/<UUID>` directory, symbolic links never followed.
final class WorkspaceRemovalTests: XCTestCase {
    private let fm = FileManager.default

    /// `Documents/Noty` (main library with one notebook) and `Documents/NotyWorkspaces`.
    private func container() async throws -> (documents: URL, main: URL, store: WorkspaceStore) {
        let documents = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("Documents")
        let main = documents.appendingPathComponent("Noty", isDirectory: true)
        let library = LibraryStore(root: main); _ = try await library.load()
        var notebook = Notebook(); notebook.title = "Echte Notizen"; notebook.pages[0].text = "Bleibt erhalten · ÄÖÜ"
        _ = try await library.createDocument(notebook, parentID: nil)
        return (documents, main, WorkspaceStore(root: documents.appendingPathComponent("NotyWorkspaces", isDirectory: true)))
    }

    /// Every regular file below `url` with its bytes (relative paths).
    private func tree(_ url: URL) throws -> [String: Data] {
        var result: [String: Data] = [:]
        let base = url.standardizedFileURL.path
        guard let files = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey]) else { return result }
        for case let file as URL in files where (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
            result[String(file.standardizedFileURL.path.dropFirst(base.count))] = try Data(contentsOf: file)
        }
        return result
    }

    private func areaFolder(_ documents: URL, _ id: UUID) -> URL {
        documents.appendingPathComponent("NotyWorkspaces/Areas/\(id.uuidString)", isDirectory: true)
    }

    func testRulesNeverMainLibraryNeverLastAreaNeverOpenArea() {
        let a = UUID(), b = UUID()
        XCTAssertEqual(WorkspaceRemoval.blocker(target: nil, active: a, areaCount: 3), .mainLibrary)
        XCTAssertEqual(WorkspaceRemoval.blocker(target: nil, active: nil, areaCount: 1), .mainLibrary)
        XCTAssertEqual(WorkspaceRemoval.blocker(target: a, active: nil, areaCount: 1), .lastArea)
        XCTAssertEqual(WorkspaceRemoval.blocker(target: a, active: nil, areaCount: 0), .lastArea)
        XCTAssertEqual(WorkspaceRemoval.blocker(target: a, active: a, areaCount: 3), .activeArea)
        XCTAssertNil(WorkspaceRemoval.blocker(target: a, active: b, areaCount: 2))
        XCTAssertNil(WorkspaceRemoval.blocker(target: a, active: nil, areaCount: 2))
        for error in [WorkspaceRemovalError.mainLibrary, .lastArea, .activeArea, .unavailable, .unsafeLocation, .notRemoved, .leftoverFiles] {
            XCTAssertFalse((error.errorDescription ?? "").isEmpty)
        }
    }

    func testRemovesOnlyTheChosenAreaAndKeepsMainLibraryAndOtherAreas() async throws {
        let (documents, main, store) = try await container()
        defer { try? fm.removeItem(at: documents.deletingLastPathComponent()) }
        let a = try await store.createTest(title: "Test A")
        let b = try await store.createTest(title: "Test B")
        let mainBefore = try tree(main), otherBefore = try tree(areaFolder(documents, b.id))
        let removedBefore = try tree(areaFolder(documents, a.id))
        XCTAssertFalse(mainBefore.isEmpty)

        let summary = try await store.removalSummary(a.id)
        XCTAssertEqual(summary.workspace, a)
        XCTAssertEqual(summary.notebooks, 1)
        XCTAssertEqual(summary.trashedNotebooks, 0)
        XCTAssertTrue(summary.indexReadable)
        // The summary only reads.
        XCTAssertEqual(try tree(areaFolder(documents, a.id)), removedBefore)

        try await store.remove(a.id, protecting: [main])
        XCTAssertFalse(fm.fileExists(atPath: areaFolder(documents, a.id).path))
        let listed = try await store.list()
        XCTAssertEqual(listed.workspaces.map(\.id), [b.id])
        XCTAssertEqual(listed.unreadableCount, 0)
        XCTAssertEqual(try tree(main), mainBefore)
        XCTAssertEqual(try tree(areaFolder(documents, b.id)), otherBefore)
        let bin = documents.appendingPathComponent("NotyWorkspaces/Removing")
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: bin.path), [])
        // Gone means gone: a second request is rejected, the remaining area still opens.
        do { try await store.remove(a.id, protecting: [main]); XCTFail("removed twice") } catch WorkspaceRemovalError.unavailable { }
        _ = try await LibraryStore(root: store.directory(for: b.id)).backupBundle()
    }

    func testOpenAreaIsRemovableOnlyAfterSwitchingToMainLibrary() async throws {
        let (documents, main, store) = try await container()
        defer { try? fm.removeItem(at: documents.deletingLastPathComponent()) }
        let a = try await store.createTest(title: "Geöffnet")
        let opened = try await store.activate(a.id)
        let expected = try await store.directory(for: a.id)
        XCTAssertEqual(opened, expected)
        let before = try tree(areaFolder(documents, a.id))
        do { try await store.remove(a.id, protecting: [main]); XCTFail("open area removed") } catch WorkspaceRemovalError.activeArea { }
        XCTAssertEqual(try tree(areaFolder(documents, a.id)), before)
        // A failed switch keeps the previous (open) area.
        do { _ = try await store.activate(UUID()); XCTFail("unknown area opened") } catch { }
        do { try await store.remove(a.id, protecting: [main]); XCTFail("open area removed") } catch WorkspaceRemovalError.activeArea { }
        let back = try await store.activate(nil)
        XCTAssertNil(back)
        try await store.remove(a.id, protecting: [main])
        let listed = try await store.list(); XCTAssertTrue(listed.workspaces.isEmpty)
    }

    func testUnknownAreaAndProtectedRootsAreRejectedWithoutDeleting() async throws {
        let (documents, main, store) = try await container()
        defer { try? fm.removeItem(at: documents.deletingLastPathComponent()) }
        let a = try await store.createTest(title: "Geschützt")
        let folder = areaFolder(documents, a.id), workspaces = documents.appendingPathComponent("NotyWorkspaces")
        do { try await store.remove(UUID(), protecting: [main]); XCTFail("unknown area") } catch WorkspaceRemovalError.unavailable { }
        let before = try tree(folder)
        // Never a protected root, nothing inside one, nothing containing one.
        for protected in [folder, folder.appendingPathComponent("Data"), workspaces, documents,
                          folder.appendingPathComponent("../\(a.id.uuidString)")] {
            XCTAssertThrowsError(try WorkspaceRemoval.directory(for: a.id, workspaceRoot: workspaces, protecting: [protected])) {
                XCTAssertEqual($0 as? WorkspaceRemovalError, .unsafeLocation)
            }
            do { try await store.remove(a.id, protecting: [main, protected]); XCTFail("protected root removed") }
            catch WorkspaceRemovalError.unsafeLocation { }
        }
        XCTAssertEqual(try tree(folder), before)
        // A path given with `..` components is standardized before any check.
        let roundabout = workspaces.appendingPathComponent("Areas/../")
        XCTAssertEqual(try WorkspaceRemoval.directory(for: a.id, workspaceRoot: roundabout, protecting: [main]).path,
                       folder.standardizedFileURL.path)
        XCTAssertEqual(try WorkspaceRemoval.directory(for: a.id, workspaceRoot: workspaces, protecting: [main]).path,
                       folder.standardizedFileURL.path)
        do { _ = try WorkspaceRemoval.directory(for: UUID(), workspaceRoot: workspaces, protecting: [main]); XCTFail("missing area") }
        catch WorkspaceRemovalError.unavailable { }
    }

    func testSymbolicLinksAreNeverFollowedOrDeletedThrough() async throws {
        let (documents, main, store) = try await container()
        defer { try? fm.removeItem(at: documents.deletingLastPathComponent()) }
        let keep = try await store.createTest(title: "Bleibt")
        let workspaces = documents.appendingPathComponent("NotyWorkspaces")
        // A complete area outside the container, linked in as `Areas/<UUID>`.
        let outside = documents.deletingLastPathComponent().appendingPathComponent("Fremd", isDirectory: true)
        let foreign = try await WorkspaceStore(root: outside).createTest(title: "Fremd")
        let foreignFolder = outside.appendingPathComponent("Areas/\(foreign.id.uuidString)")
        let foreignBefore = try tree(foreignFolder)
        let link = areaFolder(documents, foreign.id)
        try fm.createSymbolicLink(at: link, withDestinationURL: foreignFolder)
        let listed = try await store.list()
        XCTAssertEqual(listed.workspaces.map(\.id), [keep.id]); XCTAssertEqual(listed.unreadableCount, 1)
        do { try await store.remove(foreign.id, protecting: [main]); XCTFail("linked area removed") } catch WorkspaceRemovalError.unavailable { }
        XCTAssertThrowsError(try WorkspaceRemoval.directory(for: foreign.id, workspaceRoot: workspaces, protecting: [main])) {
            XCTAssertEqual($0 as? WorkspaceRemovalError, .unsafeLocation)
        }
        XCTAssertEqual(try tree(foreignFolder), foreignBefore)
        XCTAssertNotNil(try? fm.destinationOfSymbolicLink(atPath: link.path))
        try fm.removeItem(at: link)

        // A link inside a removed area is unlinked; its target stays intact.
        let target = outside.appendingPathComponent("Ziel", isDirectory: true)
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        try Data([7, 7]).write(to: target.appendingPathComponent("wichtig"))
        try fm.createSymbolicLink(at: areaFolder(documents, keep.id).appendingPathComponent("Data/Verweis"), withDestinationURL: target)
        try fm.createSymbolicLink(at: areaFolder(documents, keep.id).appendingPathComponent("Data/Hauptbibliothek"), withDestinationURL: main)
        let mainBefore = try tree(main)
        try await store.remove(keep.id, protecting: [main])
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("wichtig")), Data([7, 7]))
        XCTAssertEqual(try tree(main), mainBefore)

        // The `Areas` directory itself replaced by a link: nothing is removed.
        let areas = workspaces.appendingPathComponent("Areas")
        try fm.removeItem(at: areas)
        try fm.createSymbolicLink(at: areas, withDestinationURL: outside.appendingPathComponent("Areas"))
        do { try await store.remove(foreign.id, protecting: [main]); XCTFail("removed through linked Areas") } catch WorkspaceRemovalError.notRemoved { }
        XCTAssertThrowsError(try WorkspaceRemoval.directory(for: foreign.id, workspaceRoot: workspaces, protecting: [main])) {
            XCTAssertEqual($0 as? WorkspaceRemovalError, .unsafeLocation)
        }
        XCTAssertEqual(try tree(foreignFolder), foreignBefore)
    }

    func testFailureBeforeTheMoveLeavesTheAreaIntact() async throws {
        let (documents, main, store) = try await container()
        defer { try? fm.removeItem(at: documents.deletingLastPathComponent()) }
        let a = try await store.createTest(title: "Unverändert")
        let before = try tree(areaFolder(documents, a.id))
        // `Removing` blocked by a file: the move cannot happen.
        try Data([1]).write(to: documents.appendingPathComponent("NotyWorkspaces/Removing"))
        do { try await store.remove(a.id, protecting: [main]); XCTFail("removed") } catch WorkspaceRemovalError.notRemoved { }
        XCTAssertEqual(try tree(areaFolder(documents, a.id)), before)
        let listed = try await store.list(); XCTAssertEqual(listed.workspaces.map(\.id), [a.id])
        // A linked `Removing` directory is rejected as well.
        try fm.removeItem(at: documents.appendingPathComponent("NotyWorkspaces/Removing"))
        let elsewhere = documents.deletingLastPathComponent().appendingPathComponent("Woanders")
        try fm.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: documents.appendingPathComponent("NotyWorkspaces/Removing"), withDestinationURL: elsewhere)
        do { try await store.remove(a.id, protecting: [main]); XCTFail("moved through a link") } catch WorkspaceRemovalError.notRemoved { }
        XCTAssertEqual(try tree(areaFolder(documents, a.id)), before)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: elsewhere.path), [])
    }

    func testStartupFinishesOnlyOwnLeftovers() async throws {
        let (documents, _, store) = try await container()
        defer { try? fm.removeItem(at: documents.deletingLastPathComponent()) }
        let area = try await store.createTest(title: "Bleibt")
        let bin = documents.appendingPathComponent("NotyWorkspaces/Removing", isDirectory: true)
        let leftover = bin.appendingPathComponent("\(UUID().uuidString)-\(UUID().uuidString)/Data/Library", isDirectory: true)
        try fm.createDirectory(at: leftover, withIntermediateDirectories: true)
        try Data([1, 2]).write(to: leftover.appendingPathComponent("index.json"))
        try fm.createDirectory(at: bin.appendingPathComponent("Fremd"), withIntermediateDirectories: true)
        try fm.createDirectory(at: bin.appendingPathComponent(UUID().uuidString), withIntermediateDirectories: true)
        let outside = documents.deletingLastPathComponent().appendingPathComponent("Draußen", isDirectory: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data([3]).write(to: outside.appendingPathComponent("keep"))
        let link = "\(UUID().uuidString)-\(UUID().uuidString)"
        try fm.createSymbolicLink(at: bin.appendingPathComponent(link), withDestinationURL: outside)
        let removed = await store.removeRemovalLeftovers()
        XCTAssertEqual(removed, 2)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: bin.path).count, 2)
        XCTAssertEqual(try Data(contentsOf: outside.appendingPathComponent("keep")), Data([3]))
        let listed = try await store.list(); XCTAssertEqual(listed.workspaces.map(\.id), [area.id])
    }

    func testSummaryCountsTrashUnindexedPackagesAndUnreadableIndex() async throws {
        let (documents, _, store) = try await container()
        defer { try? fm.removeItem(at: documents.deletingLastPathComponent()) }
        let area = try await store.createTest(title: "Zählung")
        let data = try await store.directory(for: area.id)
        let library = LibraryStore(root: data)
        let notebook = try await library.load().snapshot.items.first { !$0.isFolder }!
        _ = try await library.trash(notebook.id)
        try fm.createDirectory(at: data.appendingPathComponent("Library/Documents/\(UUID().uuidString)"), withIntermediateDirectories: true)
        let summary = try await store.removalSummary(area.id)
        XCTAssertEqual(summary.notebooks, 2); XCTAssertEqual(summary.trashedNotebooks, 1); XCTAssertTrue(summary.indexReadable)
        for name in ["index.json", "index-previous.json"] {
            try Data("kaputt".utf8).write(to: data.appendingPathComponent("Library/\(name)"))
        }
        let unreadable = try await store.removalSummary(area.id)
        XCTAssertEqual(unreadable.notebooks, 2); XCTAssertFalse(unreadable.indexReadable)
        do { _ = try await store.removalSummary(UUID()); XCTFail("unknown area") } catch WorkspaceRemovalError.unavailable { }
    }
}
