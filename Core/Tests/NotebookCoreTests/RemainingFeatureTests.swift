import Foundation
import XCTest
@testable import NotebookCore

final class ShapeObjectTests: XCTestCase {
    private func shape() -> ShapeObject { .init(kind: .arrow, start: .init(x: 210, y: 80), end: .init(x: 80, y: 210), pattern: .dashed) }
    func testOrientedEndpointsBoundsAndCodec() throws {
        let value = shape(); try value.validate()
        XCTAssertEqual(value.frame, PageRect(x: 80, y: 80, width: 130, height: 130))
        XCTAssertEqual(try JSONDecoder().decode(ShapeObject.self, from: JSONEncoder().encode(value)), value)
        let moved = value.translated(x: -50, y: 20)
        XCTAssertEqual(moved.start, PagePoint(x: 160, y: 100)); XCTAssertEqual(moved.id, value.id)
    }
    func testMigrationNeverDowngradesAndAllContentIsAtomic() throws {
        var note = Notebook(); note.pdf = Data([1]); note.pages[0].text = "Alttext"
        let original = note
        try note.replaceShapes([shape()], pageID: note.pages[0].id)
        XCTAssertEqual(note.schemaVersion, 6); XCTAssertEqual(note.pdfSources?.first?.data, original.pdf)
        XCTAssertEqual(note.pages[0].text, "Alttext")
        try note.replaceTextBoxes(note.pages[0].effectiveTextBoxes, pageID: note.pages[0].id)
        try note.replaceImages([], pageID: note.pages[0].id)
        XCTAssertEqual(note.schemaVersion, 6)
        var content = PageContent(page: note.pages[0]); content.textBoxes[0].text = "Neu"; content.shapes[0].end.x = 1000
        let before = note
        XCTAssertThrowsError(try note.replaceContent(content, pageID: note.pages[0].id)); XCTAssertEqual(note, before)
    }
    func testInvalidNumbersCountsBoundsAndCrossLayerIDs() throws {
        var note = Notebook.blank(title: "Formen"); let id = note.pages[0].id, before = note
        var value = shape(); value.start.x = .nan
        XCTAssertThrowsError(try note.replaceShapes([value], pageID: id))
        value = shape(); value.lineWidth = 0
        XCTAssertThrowsError(try note.replaceShapes([value], pageID: id))
        value = shape(); value.end.y = 840
        XCTAssertThrowsError(try note.replaceShapes([value], pageID: id))
        XCTAssertThrowsError(try note.replaceShapes((0..<501).map { _ in shape() }, pageID: id))
        XCTAssertEqual(note, before)
        let box = TextBox(x: 10, y: 10, width: 100, height: 50, text: "ID")
        try note.replaceTextBoxes([box], pageID: id)
        value = shape(); value.id = box.id
        XCTAssertThrowsError(try note.replaceShapes([value], pageID: id))
    }
    func testDuplicateTrashMarginsAndArchiveKeepEditableShapes() throws {
        var note = Notebook(); note.pdf = Data([1]); let id = note.pages[0].id
        try note.setMargins(PageMargins(left: 200), pageIDs: [id])
        let value = shape().translated(x: -200, y: 0)
        try note.replaceShapes([value], pageID: id)
        let copy = try note.duplicatePage(id)
        XCTAssertNotEqual(note.pages[1].shapes![0].id, value.id)
        XCTAssertEqual(note.pages[1].shapes![0].start, value.start)
        try note.trashPage(copy)
        XCTAssertThrowsError(try note.setMargins(PageMargins(), pageIDs: [id]))
        let archive = try BackupArchive.encode(note)
        XCTAssertEqual(try BackupArchive.decode(archive).document, note)
        try note.restorePage(copy); try note.validate()
    }
    func testSchemaFiveBytesArchivedExactlyBeforeFirstShapeCommit() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var note = Notebook.blank(title: "Migration")
        try note.replaceImages([], pageID: note.pages[0].id)
        let store = RevisionStore(directory: root); try store.save(note)
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: root.appendingPathComponent("Revisions"), includingPropertiesForKeys: nil).first)
        let bytes = try Data(contentsOf: file)
        try note.replaceShapes([shape()], pageID: note.pages[0].id); try store.save(note)
        let files = FileManager.default.enumerator(at: root.appendingPathComponent("Migrations"), includingPropertiesForKeys: nil)!.allObjects.compactMap { $0 as? URL }
        let migration = try XCTUnwrap(files.first { $0.lastPathComponent == "notebook-v5.json" })
        XCTAssertEqual(try Data(contentsOf: migration), bytes)
        XCTAssertEqual(try RevisionStore(directory: root).load(), note)
    }
    func testHeldArrowRecognition() {
        let shaft = (0...20).map { PagePoint(x: Double($0)*6+30, y: 100) }
        let wings: [PagePoint] = [.init(x: 130,y:85), .init(x: 150,y:100), .init(x:130,y:115)]
        XCTAssertEqual(ShapeRecognition.recognize(shaft + wings), .arrow)
    }
    func testRecognitionDoesNotReplaceNormalScribbles() {
        XCTAssertEqual(ShapeRecognition.recognize((0...30).map { .init(x: Double($0) * 4, y: 80 + sin(Double($0)) * 0.3) }), .line)
        XCTAssertEqual(ShapeRecognition.recognize((0...64).map { .init(x: 100 + 70 * cos(Double($0) * .pi / 32), y: 100 + 40 * sin(Double($0) * .pi / 32)) }), .ellipse)
        XCTAssertEqual(ShapeRecognition.recognize([.init(x: 50,y:50),.init(x:150,y:50),.init(x:150,y:150),.init(x:50,y:150),.init(x:50,y:50)]), .rectangle)
        XCTAssertNil(ShapeRecognition.recognize((0...50).map { .init(x: Double($0) * 4, y: Double($0 % 7) * 15) }))
        XCTAssertNil(ShapeRecognition.recognize([.init(x: 0,y:0),.init(x:1,y:1)]))
    }
}

final class TextListEditingTests: XCTestCase {
    func testBulletNumberAndUncheckedContinuation() {
        for (input, expected) in [("• Apfel", "\n• "), ("19. Apfel", "\n20. "), ("☑ Apfel", "\n☐ "), ("☐ Apfel", "\n☐ ")] {
            XCTAssertEqual(TextListEditing.newline(in: input, range: NSRange(location: (input as NSString).length, length: 0))?.replacement, expected)
        }
    }
    func testEmptyListItemExitsWithoutAddingBlankItem() {
        XCTAssertEqual(TextListEditing.newline(in: "Text\n• ", range: NSRange(location: 7, length: 0)), .init(range: NSRange(location: 5, length: 2), replacement: ""))
        XCTAssertNil(TextListEditing.newline(in: "Text", range: NSRange(location: 4, length: 0)))
    }
    func testUnicodeRangesAndCheckboxDoNotTouchOtherLines() {
        let source = "😀 davor\n☐ Prüfung\nEnde"
        let position = (source as NSString).range(of: "Prüfung").location
        let edit = TextListEditing.checkbox(in: source, range: NSRange(location: position, length: 0))!
        XCTAssertEqual((source as NSString).replacingCharacters(in: edit.range, with: edit.replacement), "😀 davor\n☑ Prüfung\nEnde")
        XCTAssertNil(TextListEditing.checkbox(in: source, range: NSRange(location: 9999, length: 1)))
    }
}

final class ExternalBackupPolicyTests: XCTestCase {
    func testDailyAttemptThrottleAndDisabledTarget() {
        var policy = ExternalBackupPolicy(); let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertFalse(policy.due(at: now)); policy.target = .webDAV; XCTAssertTrue(policy.due(at: now))
        policy.lastAttempt = now; XCTAssertFalse(policy.due(at: now.addingTimeInterval(899)))
        XCTAssertTrue(policy.due(at: now.addingTimeInterval(901)))
        policy.lastSuccess = now; XCTAssertFalse(policy.due(at: now.addingTimeInterval(86399)))
        XCTAssertTrue(policy.due(at: now.addingTimeInterval(86401)))
    }
    func testRetentionOwnSeriesOnlyAndNewestVerifiedNeverRemoved() {
        var policy = ExternalBackupPolicy(); policy.keep = 3
        let names = (0..<8).map { policy.filename(at: Date(timeIntervalSince1970: Double(1_700_000_000 + $0))) }
        let foreign = ExternalBackupPolicy().filename()
        let verified = names[0]
        let removed = policy.obsolete(names + [foreign, names[7] + ".partial", "manual.notylibrary"], verified: verified)
        XCTAssertEqual(Set(removed), Set(names[1...5])); XCTAssertFalse(removed.contains(verified))
        XCTAssertTrue(policy.obsolete(names, verified: "invalid").isEmpty)
        XCTAssertNil(policy.timestamp(policy.prefix + "../../a.notylibrary"))
    }
    func testHTTPSDirectoryOnlyAndNoCredentialsInURL() throws {
        XCTAssertEqual(try ExternalBackupPolicy.webDAVDirectory("https://example.org/dav/notes").absoluteString, "https://example.org/dav/notes/")
        for value in ["http://example.org/", "https://user:pass@example.org/", "https://example.org/?token=x", "https://example.org/#x", "file:///tmp/a", "garbage"] {
            XCTAssertThrowsError(try ExternalBackupPolicy.webDAVDirectory(value))
        }
    }
    func testPolicyRoundtripValidationAndLimits() throws {
        var policy = ExternalBackupPolicy(); policy.target = .folder; policy.folderBookmark = Data([1,2]); policy.keep = 30
        try policy.validate()
        XCTAssertEqual(try JSONDecoder().decode(ExternalBackupPolicy.self, from: JSONEncoder().encode(policy)), policy)
        policy.keep = 2; XCTAssertThrowsError(try policy.validate())
        policy.keep = 7; policy.folderBookmark = nil; XCTAssertThrowsError(try policy.validate())
    }
}

final class ContentSearchTests: XCTestCase {
    func testGermanCaseDiacriticsAndMultipleTerms() {
        let hit = ContentSearchHit(documentID: UUID(), pageID: UUID(), pageNumber: 2, title: "Heft", text: "Prüfung im öffentlichen Recht", kind: .text, bounds: .init(x: -20, y: 50, width: 100, height: 30))
        XCTAssertTrue(hit.matches("PRUFUNG recht")); XCTAssertFalse(hit.matches("Privatrecht")); XCTAssertFalse(hit.matches("   "))
        XCTAssertEqual(hit.bounds.x, -20)
    }
}

final class ExternalBackupTransportTests: XCTestCase {
    func testHundredPagesWithObjectsSurviveFullArchive() throws {
        var note = Notebook.blank(title: "100 Seiten")
        note.schemaVersion = 6
        let template = note.pages[0]
        note.pages = (0..<100).map { index in
            var page = template; page.id = UUID()
            page.textBoxes = [TextBox(x: 40, y: 50, width: 200, height: 50, text: "Seite \(index + 1) · Prüfung")]
            page.shapes = [ShapeObject(kind: .rectangle, start: .init(x: 40,y:140), end: .init(x:260,y:240), pattern: .dashed)]
            return page
        }
        try note.validate()
        XCTAssertEqual(try BackupArchive.decode(BackupArchive.encode(note)).document, note)
        let id = note.pages[49].id; try note.movePage(id, to: 0)
        XCTAssertEqual(note.pages[0].id, id)
        XCTAssertEqual(note.pages[0].textBoxes![0].text, "Seite 50 · Prüfung")
    }
    private func archive() throws -> Data { try LibraryArchive.encode(LibraryBundle(snapshot: LibrarySnapshot(), documents: [])) }
    func testFolderWriteReadAndRetentionNeverAffectManualOrForeignFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var policy = ExternalBackupPolicy(); policy.keep = 3
        let bytes = try archive()
        let names = (0..<5).map { policy.filename(at: Date(timeIntervalSince1970: Double(1_700_000_000+$0))) }
        let foreign = ExternalBackupPolicy().filename()
        try Data([1]).write(to: root.appendingPathComponent(foreign))
        try Data([2]).write(to: root.appendingPathComponent("manual.notylibrary"))
        for name in names { try ExternalBackupFolder.write(bytes, name: name, policy: policy, directory: root) }
        XCTAssertEqual(try ExternalBackupFolder.read(root.appendingPathComponent(names[4])), bytes)
        XCTAssertEqual(Set(try ExternalBackupFolder.prune(policy: policy, directory: root, verified: names[4])), Set(names.prefix(2)))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(foreign)), Data([1]))
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("manual.notylibrary")), Data([2]))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasSuffix(".partial") })
    }
    func testInvalidWritesCollisionAndInvalidNewestPreventCleanup() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let policy = ExternalBackupPolicy(), name = policy.filename(), bytes = try archive()
        XCTAssertThrowsError(try ExternalBackupFolder.write(Data([1]), name: name, policy: policy, directory: root))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
        try ExternalBackupFolder.write(bytes, name: name, policy: policy, directory: root)
        XCTAssertThrowsError(try ExternalBackupFolder.write(bytes, name: name, policy: policy, directory: root))
        XCTAssertEqual(try ExternalBackupFolder.read(root.appendingPathComponent(name)), bytes)
        let bad = policy.filename(); try Data([1]).write(to: root.appendingPathComponent(bad))
        XCTAssertThrowsError(try ExternalBackupFolder.prune(policy: policy, directory: root, verified: bad))
        XCTAssertEqual(try ExternalBackupFolder.read(root.appendingPathComponent(name)), bytes)
        XCTAssertThrowsError(try ExternalBackupFolder.write(bytes, name: "../evil.notylibrary", policy: policy, directory: root))
    }
    func testDAVListingNamespacesDirectChildrenAndForeignOrigins() throws {
        let xml = """
        <d:multistatus xmlns:d="DAV:" xmlns:x="urn:other">
          <d:response><d:href>/dav/notes/a.notylibrary</d:href></d:response>
          <d:response><d:href>https://example.org/dav/notes/b.notylibrary</d:href></d:response>
          <d:response><d:href>/dav/notes/sub/c.notylibrary</d:href></d:response>
          <d:response><d:href>https://evil.org/dav/notes/evil.notylibrary</d:href></d:response>
          <d:response><d:href>/dav/notes/../foreign.notylibrary</d:href></d:response>
          <x:href>/dav/notes/fake.notylibrary</x:href>
          <d:response><d:href>/dav/notes/</d:href></d:response>
        </d:multistatus>
        """
        XCTAssertEqual(try BackupDAVListing.names(Data(xml.utf8), directory: URL(string: "https://example.org/dav/notes/")!), ["a.notylibrary", "b.notylibrary"])
        XCTAssertThrowsError(try BackupDAVListing.names(Data("<broken>".utf8), directory: URL(string: "https://example.org/")!))
    }
}
