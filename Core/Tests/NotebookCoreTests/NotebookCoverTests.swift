import Foundation
import XCTest
@testable import NotebookCore

/// Umschlagfarben (Schema 17) und „Umschlag ändern“ in der Bibliothek.
final class NotebookCoverTests: XCTestCase {
    private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }

    func testMainColoursComeFirstAndEveryColourIsListedOnce() {
        XCTAssertEqual(NotebookCover.main, [.pink, .orange, .yellow, .green, .blue])
        XCTAssertEqual(Array(NotebookCover.allCases.prefix(5)), NotebookCover.main)
        XCTAssertEqual(NotebookCover.main + NotebookCover.more, NotebookCover.allCases)
        XCTAssertEqual(Set(NotebookCover.allCases.filter(\.isLegacy)), [.blue, .purple, .green, .yellow, .coral, .gray])
    }

    func testOldColoursKeepSchemaSevenNewColoursNeedSeventeen() throws {
        var look = NotebookAppearance(); look.cover = .coral
        XCTAssertEqual(try Notebook.blank(title: "Alt", appearance: look).schemaVersion, 7)
        look.cover = .pink
        var book = try Notebook.blank(title: "Neu", appearance: look)
        XCTAssertEqual(book.schemaVersion, Notebook.coverPaletteSchemaVersion)
        XCTAssertEqual(try Notebook.decode(JSONEncoder().encode(book)), book)
        book.schemaVersion = 16
        XCTAssertThrowsError(try book.validate())
        XCTAssertThrowsError(try Notebook.decode(JSONEncoder().encode(book)))
        // Text documents never carry a new colour by default.
        XCTAssertEqual(try Notebook.textDocument(title: "Text").schemaVersion, Notebook.textDocumentSchemaVersion)
    }

    func testSetCoverChangesOnlyTheCover() throws {
        var look = NotebookAppearance(); look.cover = .blue; look.paper = .grid; look.color = .dark; look.format = .a5
        var book = try Notebook.blank(title: "Mathe", appearance: look)
        book.pages[0].drawing = Data([1, 2, 3])
        let pages = book.pages
        XCTAssertTrue(try book.setCover(enabled: true, cover: .orange))
        XCTAssertEqual(book.appearance?.cover, .orange)
        XCTAssertEqual(book.appearance?.paper, .grid); XCTAssertEqual(book.appearance?.color, .dark); XCTAssertEqual(book.appearance?.format, .a5)
        XCTAssertEqual(book.pages, pages)
        XCTAssertEqual(book.schemaVersion, 17)
        XCTAssertFalse(try book.setCover(enabled: true, cover: .orange), "unchanged")
        // Back to an old colour: the schema never drops.
        XCTAssertTrue(try book.setCover(enabled: false, cover: .green))
        XCTAssertEqual(book.appearance?.coverEnabled, false); XCTAssertEqual(book.schemaVersion, 17)
    }

    func testSetCoverOnOldNotebookStoresInferredDefaults() throws {
        var book = Notebook.blank(title: "Alt")
        XCTAssertNil(book.appearance)
        let inferred = book.pageDefaults
        XCTAssertTrue(try book.setCover(enabled: true, cover: .yellow))
        var expected = inferred; expected.coverEnabled = true; expected.cover = .yellow
        XCTAssertEqual(book.appearance, expected)
        XCTAssertEqual(book.schemaVersion, 7)
        try book.validate()
    }

    func testTextDocumentsHaveNoCover() throws {
        var text = try Notebook.textDocument(title: "Text")
        XCTAssertThrowsError(try text.setCover(enabled: true, cover: .pink))
    }

    func testLibraryCoverChangeCommitsOneRevisionAndArchivesOldBytes() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(root: root); _ = try await store.load()
        var look = NotebookAppearance(); look.cover = .blue
        var book = try Notebook.blank(title: "Deutsch", appearance: look)
        book.pages[0].drawing = Data([4, 5, 6])
        _ = try await store.createDocument(book, parentID: nil)
        let url = try await store.documentURL(id: book.id)
        let manifest = url.appendingPathComponent("manifest.json")
        let before = try Data(contentsOf: manifest)

        let unchanged = try await store.setCover(book.id, enabled: true, cover: .blue)
        XCTAssertFalse(unchanged)
        XCTAssertEqual(try Data(contentsOf: manifest), before, "no commit without a change")

        let changed = try await store.setCover(book.id, enabled: true, cover: .pink)
        XCTAssertTrue(changed)
        let stored = try RevisionStore(directory: url, readOnly: true).load()
        XCTAssertEqual(stored.appearance?.cover, .pink)
        XCTAssertEqual(stored.pages, book.pages)
        XCTAssertEqual(stored.schemaVersion, 17)
        let migrations = try FileManager.default.contentsOfDirectory(at: url.appendingPathComponent("Migrations"), includingPropertiesForKeys: nil)
        XCTAssertTrue(migrations.contains { folder in
            FileManager.default.fileExists(atPath: folder.appendingPathComponent("notebook-v7.json").path)
        }, "exact old bytes kept before the first schema-17 commit")
        let preview = try await store.previewDocument(id: book.id)
        XCTAssertEqual(preview.appearance?.cover, .pink)
    }

    func testLibraryCoverChangeRefusesOpenTrashedAndTextDocuments() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = LibraryStore(root: root); _ = try await store.load()
        let book = try Notebook.blank(title: "Bio", appearance: NotebookAppearance())
        _ = try await store.createDocument(book, parentID: nil)
        let url = try await store.documentURL(id: book.id)
        let manifest = try Data(contentsOf: url.appendingPathComponent("manifest.json"))
        let claim = try XCTUnwrap(PackageWriteLock.shared.claim(url))
        do {
            _ = try await store.setCover(book.id, enabled: true, cover: .green)
            XCTFail("open notebook changed")
        } catch CoverChangeError.inUse { }
        claim.release()
        XCTAssertEqual(try Data(contentsOf: url.appendingPathComponent("manifest.json")), manifest)

        let text = try Notebook.textDocument(title: "Text")
        _ = try await store.createDocument(text, parentID: nil)
        do { _ = try await store.setCover(text.id, enabled: true, cover: .pink); XCTFail("text document accepted") }
        catch LibraryError.unavailable { }

        _ = try await store.trash(book.id)
        do { _ = try await store.setCover(book.id, enabled: true, cover: .pink); XCTFail("trashed notebook accepted") }
        catch LibraryError.unavailable { }
    }
}
