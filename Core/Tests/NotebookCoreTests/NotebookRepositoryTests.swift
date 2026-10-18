import Foundation
import XCTest
@testable import NotebookCore

final class NotebookRepositoryTests: XCTestCase {
    func testConcurrentSavesCommitHighestRevisionRegardlessOfArrivalOrder() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = NotebookRepository(directory: directory)
        let base = Notebook()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for revision in 1...40 {
                var document = base
                document.pages[0].text = "Revision \(revision)"
                let snapshot = document
                group.addTask { try await repository.save(snapshot, revision: revision) }
            }
            try await group.waitForAll()
        }
        let (loaded, _) = try await repository.load()
        XCTAssertEqual(loaded.id, base.id)
        XCTAssertEqual(loaded.pages[0].text, "Revision 40")
        // Verify a fresh reader too, rather than only the actor's cached state.
        XCTAssertEqual(try RevisionStore(directory: directory).load(), loaded)
    }

    func testOlderAutosaveCannotOverwriteNewerSnapshot() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = NotebookRepository(directory: directory)
        var old = Notebook()
        old.pages[0].text = "alt"
        var new = old
        new.pages[0].text = "neu"
        try await repository.save(new, revision: 2)
        try await repository.save(old, revision: 1)
        let (loaded, _) = try await repository.load()
        XCTAssertEqual(loaded, new)
    }

    func testRestoreArchivesCorruptOriginalBytesBeforeReplacing() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let original = Data("broken original".utf8)
        try original.write(to: directory.appendingPathComponent("notebook.json"))
        let repository = NotebookRepository(directory: directory)
        let replacement = Notebook()
        try await repository.replace(replacement, preserving: nil, revision: 1)
        let archives = try FileManager.default.contentsOfDirectory(
            at: directory.appendingPathComponent("Archives"), includingPropertiesForKeys: nil)
        XCTAssertEqual(archives.count, 1)
        XCTAssertEqual(try Data(contentsOf: archives[0].appendingPathComponent("notebook.json")), original)
        let (restored, _) = try await repository.load()
        XCTAssertEqual(restored, replacement)
    }

    func testRestoreArchivesCorruptPackageAndEveryOriginalRevisionBeforeReplacing() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RevisionStore(directory: directory)
        try store.save(Notebook())
        let manifest = directory.appendingPathComponent("manifest.json")
        let corrupt = Data("broken package manifest".utf8)
        try corrupt.write(to: manifest)
        let source = directory.appendingPathComponent("Revisions")
        let filenames = try FileManager.default.contentsOfDirectory(atPath: source.path)
        let originals = try filenames.map { try Data(contentsOf: source.appendingPathComponent($0)) }
        let replacement = Notebook()
        let repository = NotebookRepository(directory: directory)
        try await repository.replace(replacement, preserving: nil, revision: 1)
        let archives = try FileManager.default.contentsOfDirectory(
            at: directory.appendingPathComponent("Archives"), includingPropertiesForKeys: nil)
        XCTAssertEqual(archives.count, 1)
        XCTAssertEqual(try Data(contentsOf: archives[0].appendingPathComponent("manifest.json")), corrupt)
        for (file, bytes) in zip(filenames, originals) {
            XCTAssertEqual(try Data(contentsOf: archives[0].appendingPathComponent("Revisions/" + file)), bytes)
        }
        let (restored, _) = try await repository.load()
        XCTAssertEqual(restored, replacement)
    }

    func testExplicitRestoreCannotOverwriteFuturePackageFormat() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manifest = directory.appendingPathComponent("manifest.json")
        let bytes = Data("{\"formatVersion\":99}".utf8)
        try bytes.write(to: manifest)
        let repository = NotebookRepository(directory: directory)
        do {
            try await repository.replace(Notebook(), preserving: nil, revision: 1)
            XCTFail("Future package must remain protected")
        } catch RevisionError.unsupportedFormat(99) { }
        XCTAssertEqual(try Data(contentsOf: manifest), bytes)
    }
}
