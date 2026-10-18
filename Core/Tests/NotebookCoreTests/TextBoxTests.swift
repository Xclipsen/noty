import Foundation
import XCTest
@testable import NotebookCore

final class TextBoxTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root
    }

    func testLegacyGlyphOriginAndAllTextStayUnchangedUntilExplicitEdit() throws {
        var old = Notebook(); old.pages[0].text = "ÄÖÜ ß\nZweite Zeile 🖊️"
        let bytes = try JSONEncoder().encode(old)
        let loaded = try Notebook.decode(bytes)
        let field = try XCTUnwrap(loaded.pages[0].effectiveTextBoxes.first)
        XCTAssertEqual(field.x, 53); XCTAssertEqual(field.y, 633)
        XCTAssertEqual(field.width, 489); XCTAssertEqual(field.height, 153)
        XCTAssertEqual(field.text, old.pages[0].text)
        XCTAssertEqual(field.id, loaded.pages[0].effectiveTextBoxes.first?.id)
        XCTAssertEqual(loaded, old)
        var edited = loaded; var box = field; box.text += " ergänzt"
        try edited.replaceTextBoxes([box], pageID: old.pages[0].id)
        XCTAssertEqual(edited.schemaVersion, 4)
        XCTAssertEqual(edited.pages[0].effectiveTextBoxes, [box])
        XCTAssertTrue(edited.pages[0].text.isEmpty)
        XCTAssertEqual(loaded, old)
    }

    func testRotatedGeometryUsesDisplayedDimensionsAndMigrationIncludesTrash() throws {
        var old = Notebook(); old.pdf = Data([1, 2]); old.pages[0].text = "Text auf gedrehter PDF"
        old.pages[0].geometry = try PDFPageGeometry(mediaBox: .init(x: 0, y: 0, width: 800, height: 600),
            cropBox: .init(x: 10, y: 20, width: 700, height: 500), rotation: 90)
        let id = old.pages[0].id
        let other = try old.duplicatePage(id)
        try old.trashPage(other)
        let oldCopy = old
        let migrated = try old.preparedForTextEditing()
        XCTAssertEqual(old, oldCopy)
        let box = try XCTUnwrap(migrated.pages[0].textBoxes?.first)
        XCTAssertEqual(box.x, 500 * 48.0 / 595 + 8, accuracy: 1e-9)
        XCTAssertEqual(box.y, 700 * 625.0 / 842 + 8, accuracy: 1e-9)
        XCTAssertEqual(migrated.deletedPages?.first?.page.searchableText, old.pages[0].text)
        XCTAssertTrue(migrated.deletedPages?.first?.page.text.isEmpty == true)
        XCTAssertEqual(try migrated.preparedForTextEditing(), migrated)
    }

    func testNegativeMarginCoordinatesAndFormattingSurviveBackupAndIndependentDuplication() throws {
        var value = Notebook(); value.pdf = Data([1, 2]); let id = value.pages[0].id
        try value.setMargins(PageMargins(left: 200, top: 100), pageIDs: [id])
        let field = TextBox(x: -180, y: -80, width: 160, height: 60, text: "☐ ÄÖÜ ß\n• Beispiel",
            style: TextBoxStyle(font: .serif, fontSize: 22, bold: true, italic: true, underline: true, color: .blue))
        try value.replaceTextBoxes([field], pageID: id)
        let duplicate = try value.duplicatePage(id)
        let newField = try XCTUnwrap(value.pages.first { $0.id == duplicate }?.textBoxes?.first)
        XCTAssertNotEqual(newField.id, field.id)
        var expected = field; expected.id = newField.id
        XCTAssertEqual(newField, expected)
        var copyFields = [newField]; copyFields[0].text = "Nur Kopie"
        try value.replaceTextBoxes(copyFields, pageID: duplicate)
        XCTAssertEqual(value.pages.first { $0.id == id }?.textBoxes, [field])
        XCTAssertEqual(try BackupArchive.decode(BackupArchive.encode(value)).document, value)
    }

    func testInvalidOrDuplicateObjectsCannotPartiallyMigrateOrOverwriteCurrentData() throws {
        var value = Notebook(); value.pages[0].text = "Original bleibt"
        let original = value; let id = value.pages[0].id
        for invalid in [TextBox(x: -.infinity), TextBox(width: 0), TextBox(height: .nan),
                        TextBox(x: -1), TextBox(y: 840, height: 30), TextBox(style: TextBoxStyle(fontSize: 100))] {
            XCTAssertThrowsError(try value.replaceTextBoxes([invalid], pageID: id))
            XCTAssertEqual(value, original)
        }
        let field = TextBox()
        XCTAssertThrowsError(try value.replaceTextBoxes([field, field], pageID: id))
        XCTAssertEqual(value, original)
        XCTAssertThrowsError(try value.replaceTextBoxes([field], pageID: UUID()))
        XCTAssertEqual(value, original)
    }

    func testFormatGuardRejectsTextObjectsHiddenInOldSchemaOrAmbiguousLegacyText() throws {
        var value = try Notebook.blank(title: "Text").preparedForTextEditing()
        value.pages[0].textBoxes = [TextBox(text: "Nicht still verlieren")]
        value.schemaVersion = 3
        XCTAssertThrowsError(try Notebook.decode(JSONEncoder().encode(value)))
        value.schemaVersion = 4; value.pages[0].text = "Zweite widersprüchliche Ebene"
        XCTAssertThrowsError(try Notebook.decode(JSONEncoder().encode(value)))
        value.schemaVersion = Notebook.currentSchemaVersion + 1
        XCTAssertThrowsError(try Notebook.decode(JSONEncoder().encode(value))) { error in
            guard case StorageError.unsupportedSchema = error else { return XCTFail("Expected unknown schema") }
        }
    }

    func testMigrationArchivesExactAcknowledgedBytesAndFailureKeepsOldCommitReadable() throws {
        let root = try directory(); let store = RevisionStore(directory: root)
        var old = Notebook.blank(title: "Schema 3"); old.pages[0].text = "Vor Migration"
        try store.save(old)
        let manifestBytes = try Data(contentsOf: root.appendingPathComponent("manifest.json"))
        let manifest = try JSONDecoder().decode(RevisionManifest.self, from: manifestBytes)
        let oldBytes = try Data(contentsOf: root.appendingPathComponent("Revisions/" + manifest.revisions[0].file))
        var migrated = old; try migrated.replaceTextBoxes([TextBox(text: "Neue Textobjekte")], pageID: old.pages[0].id)
        let migrations = root.appendingPathComponent("Migrations")
        try Data([1]).write(to: migrations)
        XCTAssertThrowsError(try store.save(migrated))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("manifest.json")), manifestBytes)
        XCTAssertEqual(try RevisionStore(directory: root).load(), old)
        try FileManager.default.moveItem(at: migrations, to: root.appendingPathComponent("blocked-migrations-test"))
        try store.save(migrated)
        let children = try FileManager.default.contentsOfDirectory(at: migrations, includingPropertiesForKeys: nil)
        XCTAssertEqual(children.count, 1)
        XCTAssertEqual(try Data(contentsOf: children[0].appendingPathComponent("notebook-v3.json")), oldBytes)
        XCTAssertEqual(try RevisionStore(directory: root).load(), migrated)
    }

    func testMarginSnapshotsAndRepeatedRestoreKeepTextObjectIDsUniqueAndEveryStateEditable() throws {
        var value = Notebook(); value.pdf = Data([1, 2]); let id = value.pages[0].id
        try value.setMargins(PageMargins(right: 200), pageIDs: [id])
        try value.replaceTextBoxes([TextBox(text: "Alter Text")], pageID: id)
        try value.applyMargins(PageMargins(right: 100), pageIDs: [id], trimmedDrawings: [id: Data([3])])
        var latest = value.pages[0].textBoxes!; latest[0].text = "Neuere Eingabe"
        try value.replaceTextBoxes(latest, pageID: id)
        try value.restorePage(value.deletedPages![0].id)
        XCTAssertEqual(value.pages[0].searchableText, "Alter Text")
        XCTAssertEqual(value.deletedPages?[0].page.searchableText, "Neuere Eingabe")
        var reopened = try BackupArchive.decode(BackupArchive.encode(value)).document
        try reopened.restorePage(reopened.deletedPages![0].id)
        XCTAssertEqual(reopened.pages[0].searchableText, "Neuere Eingabe")
        try reopened.validate()
    }

    func testLateAutosaveCannotOverwriteNewerTextObjectRevision() async throws {
        let root = try directory(); let repository = NotebookRepository(directory: root)
        var first = Notebook.blank(title: "Text")
        try first.replaceTextBoxes([TextBox(text: "Alt")], pageID: first.pages[0].id)
        var latest = first; var boxes = latest.pages[0].textBoxes!; boxes[0].text = "Aktuell"
        try latest.replaceTextBoxes(boxes, pageID: first.pages[0].id)
        try await repository.save(latest, revision: 12)
        try await repository.save(first, revision: 11)
        let (loaded, _) = try await repository.load()
        XCTAssertEqual(loaded, latest)
    }
}
