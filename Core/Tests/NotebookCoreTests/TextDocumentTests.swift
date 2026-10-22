import Foundation
import XCTest
@testable import NotebookCore

/// Textneubau Stufe 3 (docs/TEXT-REBUILD-62.md §4): text documents as their
/// own library kind, schema 15, flow over pages, export as text/Markdown.
final class TextDocumentTests: XCTestCase {
    private func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func json(_ document: Notebook) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(document)) as? [String: Any])
    }

    /// Types `text` into the flow of page 1, `capacity` characters per page.
    private func typed(_ document: Notebook, _ text: String, capacity: Int = 10,
                       drawingIsEmpty: (Data) -> Bool = { $0.isEmpty }) throws -> (Notebook, TextFlowFocus) {
        let first = try XCTUnwrap(document.textFlowSegments.first)
        var replacement = first.box
        let whole = try XCTUnwrap(document.textFlowContent)
        replacement.text = text; replacement.runs = nil
        _ = whole
        return try document.reflowText(pageID: first.pageID, previous: first.box, replacement: replacement,
            selection: NSRange(location: (text as NSString).length, length: 0), drawingIsEmpty: drawingIsEmpty,
            pageCapacity: { _, box in min(capacity, (box.text as NSString).length) })
    }

    // MARK: Format

    func testNewTextDocumentIsSchema15WithOneEmptyFlowAndKeepsItWhenDecoded() throws {
        let document = try Notebook.textDocument(title: "Aufsatz", landscape: true, paper: .lined)
        XCTAssertEqual(document.schemaVersion, 15)
        XCTAssertEqual(document.kind, .textDocument)
        XCTAssertTrue(document.isTextDocument)
        XCTAssertEqual(document.pages.count, 1)
        XCTAssertEqual(document.pages[0].paper, .lined)
        XCTAssertEqual(document.pages[0].geometry?.displaySize, PageSize(width: 842, height: 595))
        XCTAssertEqual(document.appearance?.coverEnabled, false)
        let flow = try XCTUnwrap(document.pages[0].textBoxes?.first)
        XCTAssertNotNil(flow.flowID)
        XCTAssertEqual(flow.flowRegion, .page)
        XCTAssertEqual(flow.rect, document.pages[0].writingRect(.page))
        XCTAssertEqual(flow.style.automaticColor, true)
        // Unlike a notebook the flow survives decoding (no migration to fields).
        let decoded = try NotebookDecoding.decode(JSONEncoder().encode(document))
        XCTAssertEqual(decoded.notebook, document)
        XCTAssertEqual(decoded.storedSchemaVersion, 15)
        XCTAssertEqual(try json(document)["kind"] as? String, "textDocument")
    }

    func testNotebookPageTextStillMigratesAndNotebooksStoreNoKind() throws {
        var book = try Notebook.blank(title: "Heft", appearance: NotebookAppearance())
        let rect = try XCTUnwrap(book.pages[0].writingRect(.page))
        var box = TextBox(x: rect.x, y: rect.y, width: rect.width, height: rect.height, text: "Seitentext")
        box.flowID = UUID(); box.flowRegion = .page
        try book.replaceTextBoxes([box], pageID: book.pages[0].id)
        XCTAssertNil(try json(book)["kind"])
        let decoded = try NotebookDecoding.decode(JSONEncoder().encode(book)).notebook
        XCTAssertFalse(decoded.containsTextFlow)
        XCTAssertEqual(decoded.schemaVersion, 14)
        XCTAssertNil(decoded.kind)
    }

    func testTextDocumentRulesAndLocks() throws {
        let document = try Notebook.textDocument(title: "Regeln")
        func rejects(_ change: (inout [String: Any]) -> Void, _ message: String, file: StaticString = #filePath, line: UInt = #line) throws {
            var object = try json(document); change(&object)
            XCTAssertThrowsError(try Notebook.decode(JSONSerialization.data(withJSONObject: object)), message, file: file, line: line)
        }
        try rejects({ $0["schemaVersion"] = 14 }, "text document below schema 15")
        try rejects({ $0["kind"] = "notebook" }, "stored notebook kind")
        try rejects({ $0["kind"] = "unbekannt" }, "unknown kind")
        // Schema 16 stays locked as a whole, before any other rule.
        var future = try json(document); future["schemaVersion"] = 16
        XCTAssertThrowsError(try Notebook.decode(JSONSerialization.data(withJSONObject: future))) { error in
            guard case StorageError.unsupportedSchema(16) = error else { return XCTFail("\(error)") }
        }
        // Only paper pages, no writing space, no PDF originals, one flow.
        var withMargins = document
        withMargins.pages[0].margins = PageMargins(right: 100, style: .blank, color: .white)
        XCTAssertThrowsError(try withMargins.validate())
        var withPDF = document
        withPDF.pdfSources = [PDFSource(id: UUID(), data: Data("%PDF".utf8), pageCount: 1)]
        XCTAssertThrowsError(try withPDF.validate())
        var twoFlows = document
        var second = twoFlows.pages[0].textBoxes![0]; second.id = UUID(); second.flowID = UUID()
        var page = twoFlows.writingDraft(); page.textBoxes = [second]
        twoFlows.pages.append(page)
        XCTAssertThrowsError(try twoFlows.validate())
        var marginFlow = document
        marginFlow.pages[0].textBoxes![0].flowRegion = .right
        XCTAssertThrowsError(try marginFlow.validate())
        // Page operations that would add a PDF are refused by validation.
        var inserting = document
        XCTAssertThrowsError(try inserting.insertPDF(Data("%PDF".utf8), geometries: [PaperStyle.geometry], at: 1))
        XCTAssertEqual(inserting, document)
    }

    // MARK: Flow over pages

    func testPagesComeFromTheTextAndAPageWithHandwritingIsReusedInPlace() throws {
        var document = try Notebook.textDocument(title: "Seiten")
        // Handwriting on the reserve page behind the text: a real page now.
        var draft = document.writingDraft(); draft.drawing = Data([1, 2, 3])
        try document.materializeWritingDraft(draft)
        XCTAssertEqual(document.pages.count, 2)
        let (grown, focus) = try typed(document, String(repeating: "a", count: 25))
        XCTAssertEqual(grown.pages.count, 3)
        // The handwriting page keeps its place, ID and ink; the text runs below it.
        XCTAssertEqual(grown.pages[1].id, draft.id)
        XCTAssertEqual(grown.pages[1].drawing, Data([1, 2, 3]))
        XCTAssertEqual(grown.textFlowSegments.map { ($0.box.text as NSString).length }, [10, 10, 5])
        XCTAssertEqual(grown.textFlowSegments.map(\.pageID), grown.pages.map(\.id))
        XCTAssertEqual(focus.pageID, grown.pages[2].id)
        XCTAssertEqual(grown.textFlowContent?.text, String(repeating: "a", count: 25))
        XCTAssertEqual(grown.schemaVersion, 15)
    }

    func testShrinkingTextRemovesEmptyTrailingPagesButKeepsHandwriting() throws {
        var document = try Notebook.textDocument(title: "Kürzen")
        (document, _) = try typed(document, String(repeating: "b", count: 35))
        XCTAssertEqual(document.pages.count, 4)
        // Handwriting on the last page, then the text of page 3 is deleted.
        document.pages[3].drawing = Data([9])
        let third = document.textFlowSegments[2]
        var cleared = third.box; cleared.text = ""
        func shrink(_ drawingIsEmpty: @escaping (Data) -> Bool) throws -> (Notebook, TextFlowFocus) {
            try document.reflowText(pageID: third.pageID, previous: third.box, replacement: cleared,
                selection: NSRange(location: 0, length: 0), drawingIsEmpty: drawingIsEmpty,
                pageCapacity: { _, box in min(10, (box.text as NSString).length) })
        }
        let (next, focus) = try shrink { $0.isEmpty }
        // Page 4 keeps its ink (fixed on the page) with an empty segment.
        XCTAssertEqual(next.pages.map(\.id), document.pages.map(\.id))
        XCTAssertEqual(next.pages[3].drawing, Data([9]))
        XCTAssertEqual(next.textFlowSegments.map { ($0.box.text as NSString).length }, [10, 10, 5, 0])
        XCTAssertEqual(focus.pageID, next.pages[2].id)
        // A tap below the text: caret behind its last character, not on the ink page.
        XCTAssertEqual(next.textFlowEndFocus?.pageID, next.pages[2].id)
        XCTAssertEqual(next.textFlowEndFocus?.selection, NSRange(location: 5, length: 0))
        // Ink the app reports as empty (all strokes erased) no longer holds the page.
        let (trimmed, _) = try shrink { $0.isEmpty || $0 == Data([9]) }
        XCTAssertEqual(trimmed.pages.map(\.id), Array(document.pages.prefix(3).map(\.id)))
        // PDF export leaves out trailing pages without content, never the first.
        XCTAssertEqual(next.exportedPageIDs(), next.pages.map(\.id))
        XCTAssertEqual(next.exportedPageIDs(drawingIsEmpty: { $0.isEmpty || $0 == Data([9]) }), Array(next.pages.prefix(3).map(\.id)))
        let empty = try Notebook.textDocument(title: "Leer")
        XCTAssertEqual(empty.exportedPageIDs(), [empty.pages[0].id])
    }

    func testNotebookReflowKeepsItsFormerRules() throws {
        // Notebooks never trim pages (they no longer create flows, but old code paths stay unchanged).
        var book = try Notebook.blank(title: "Heft", appearance: NotebookAppearance())
        let rect = try XCTUnwrap(book.pages[0].writingRect(.page))
        var box = TextBox(x: rect.x, y: rect.y, width: rect.width, height: rect.height, text: "")
        box.flowID = UUID(); box.flowRegion = .page
        try book.replaceTextBoxes([box], pageID: book.pages[0].id)
        _ = try book.insertPaper(.blank, at: 1)
        XCTAssertEqual(book.trimmingEmptyTrailingPages(), book)
        XCTAssertEqual(book.exportedPageIDs(), book.pages.map(\.id))
    }

    func testAddingAFlowOnlyWhereNoneExists() throws {
        let document = try Notebook.textDocument(title: "Fluss")
        XCTAssertNil(try document.addingTextFlow())
        var without = document; without.pages[0].textBoxes = []
        let (added, focus) = try XCTUnwrap(try without.addingTextFlow())
        XCTAssertEqual(added.textFlowSegments.count, 1)
        XCTAssertEqual(focus.pageID, added.pages[0].id)
        XCTAssertNil(try Notebook.blank(title: "Heft", appearance: NotebookAppearance()).addingTextFlow())
    }

    // MARK: Export

    private func document(_ paragraphs: [(String, (inout TextBoxStyle) -> Void)]) throws -> Notebook {
        var document = try Notebook.textDocument(title: "Export")
        var box = document.pages[0].textBoxes![0]
        var runs: [TextRun] = [], text = ""
        for (index, (line, change)) in paragraphs.enumerated() {
            let value = line + (index < paragraphs.count - 1 ? "\n" : "")
            var style = box.style; change(&style)
            runs.append(TextRun(location: (text as NSString).length, length: (value as NSString).length, style: style))
            text += value
        }
        box.text = text; box.runs = runs
        document.pages[0].textBoxes = [box]
        try document.validate()
        return document
    }

    func testMarkdownHeadingsListsAndEmphasis() throws {
        let doc = try document([
            ("Protokoll", { TextStylePreset.title.apply(to: &$0) }),
            ("Ablauf", { TextStylePreset.heading.apply(to: &$0) }),
            ("Details", { TextStylePreset.subheading.apply(to: &$0) }),
            ("Ein *normaler* Satz", { _ in }),
            ("• Punkt", { _ in }),
            ("◦ Unterpunkt", { $0.indent = TextPlacement.indentStep }),
            ("1. Erstens", { _ in }),
            ("☐ offen", { _ in }),
            ("☑ erledigt", { _ in }),
            ("", { _ in }),
            ("# kein Titel", { _ in }),
            ("fett", { $0.bold = true }),
            ("kursiv", { $0.italic = true })
        ])
        XCTAssertEqual(TextDocumentExport.markdown(doc), """
        # Protokoll

        ## Ablauf

        ### Details

        Ein \\*normaler\\* Satz

        - Punkt
            - Unterpunkt
        1. Erstens
        - [ ] offen
        - [x] erledigt

        \\# kein Titel

        **fett**

        _kursiv_

        """)
    }

    func testMarkdownEmphasisInsideAParagraphAndAcrossPages() throws {
        var doc = try Notebook.textDocument(title: "Mix")
        var box = doc.pages[0].textBoxes![0]
        box.text = "Ein fetter und kursiver Satz"
        var bold = box.style; bold.bold = true
        var both = bold; both.italic = true; both.highlighted = true
        var italic = box.style; italic.italic = true
        box.runs = [TextRun(location: 4, length: 7, style: bold), TextRun(location: 11, length: 3, style: both),
                    TextRun(location: 15, length: 8, style: italic)]
        doc.pages[0].textBoxes = [box]
        XCTAssertEqual(TextDocumentExport.markdown(doc), "Ein **fetter** **_und_** _kursiver_ Satz\n")
        // A flow over two pages is one text.
        (doc, _) = try typed(try Notebook.textDocument(title: "Zwei"), "Erste Zeile\nZweite", capacity: 12)
        XCTAssertEqual(doc.pages.count, 2)
        XCTAssertEqual(TextDocumentExport.markdown(doc), "Erste Zeile\n\nZweite\n")
        XCTAssertEqual(TextDocumentExport.plainText(doc), "Erste Zeile\nZweite\n")
        XCTAssertEqual(TextDocumentExport.export(doc, as: .plainText), TextDocumentExport.plainText(doc))
        XCTAssertEqual(TextDocumentExport.Format.markdown.fileExtension, "md")
        XCTAssertEqual(TextDocumentExport.markdown(try Notebook.textDocument(title: "Leer")), "")
    }

    func testPlainTextKeepsListMarkers() throws {
        let doc = try document([("Titel", { TextStylePreset.title.apply(to: &$0) }), ("☐ Aufgabe", { _ in })])
        XCTAssertEqual(TextDocumentExport.plainText(doc), "Titel\n☐ Aufgabe\n")
    }

    // MARK: Library

    func testLibraryKnowsTheKindAcrossCreateDuplicateDiscoverAndRepair() async throws {
        let root = try directory()
        let library = LibraryStore(root: root); _ = try await library.load()
        let text = try Notebook.textDocument(title: "Referat")
        var snapshot = try await library.createDocument(text, parentID: nil)
        XCTAssertEqual(snapshot.items.first { $0.id == text.id }?.kind, .textDocument)
        let heft = try Notebook.blank(title: "Heft", appearance: NotebookAppearance())
        snapshot = try await library.createDocument(heft, parentID: nil)
        XCTAssertNil(snapshot.items.first { $0.id == heft.id }?.kind)
        let copy = try await library.duplicateDocument(text.id, title: "Referat Kopie")
        XCTAssertEqual(copy.snapshot.items.first { $0.id == copy.id }?.kind, .textDocument)
        // Index entries of notebooks stay without the key.
        let payload = try JSONEncoder().encode(copy.snapshot)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: payload) as? [String: Any])
        let items = try XCTUnwrap(object["items"] as? [[String: Any]])
        XCTAssertNil(items.first { $0["id"] as? String == heft.id.uuidString }?["kind"])
        // An older build rewrote the index without the key: repair from the document.
        snapshot = try await library.setKind(text.id, kind: .notebook)
        XCTAssertNil(snapshot.items.first { $0.id == text.id }?.kind)
        snapshot = try await library.setKind(text.id, kind: .textDocument)
        XCTAssertEqual(snapshot.items.first { $0.id == text.id }?.kind, .textDocument)
        // A package without index entry is discovered with its kind.
        let orphan = try Notebook.textDocument(title: "Gefunden")
        try RevisionStore(directory: root.appendingPathComponent("Library/Documents/\(orphan.id.uuidString)")).save(orphan)
        let loaded = try await LibraryStore(root: root).load()
        XCTAssertEqual(loaded.snapshot.items.first { $0.id == orphan.id }?.kind, .textDocument)
    }

    func testFolderWithKindIsAnInvalidIndex() throws {
        var snapshot = LibrarySnapshot()
        var folder = LibraryItem(title: "Ordner"); folder.kind = .textDocument
        snapshot.items = [folder]
        XCTAssertThrowsError(try snapshot.validate())
        var notebook = LibraryItem(title: "Heft", source: .library); notebook.kind = .notebook
        snapshot.items = [notebook]
        XCTAssertThrowsError(try snapshot.validate())
    }

    func testLibraryBackupKeepsTextDocumentsAndRestoreTakesTheKindFromTheDocument() async throws {
        let root = try directory()
        let library = LibraryStore(root: root); _ = try await library.load()
        var text = try Notebook.textDocument(title: "Facharbeit", paper: .grid)
        (text, _) = try typed(text, "Einleitung über zwei Seiten hinweg", capacity: 20)
        _ = try await library.createDocument(text, parentID: nil)
        var bundle = try await library.backupBundle()
        XCTAssertEqual(bundle.documents, [text])
        // The archived index lost the hint (older build): the restore repairs it.
        bundle.snapshot.items = bundle.snapshot.items.map { var item = $0; item.kind = nil; return item }
        let data = try LibraryArchive.encode(bundle)
        let decoded = try LibraryArchive.decode(data)
        XCTAssertEqual(decoded.documents, [text])
        let target = try directory().appendingPathComponent("Bereich")
        try await LibraryStore(root: target).populateEmpty(decoded)
        let restored = try await LibraryStore(root: target).load().snapshot
        XCTAssertEqual(restored.items.first { $0.id == text.id }?.kind, .textDocument)
        let reopened = try RevisionStore(directory: target.appendingPathComponent("Library/Documents/\(text.id.uuidString)")).load()
        XCTAssertEqual(reopened, text)
    }

    func testNotyImportRecognisesTheTextDocument() async throws {
        let root = try directory(), outside = try directory()
        let library = LibraryStore(root: root); _ = try await library.load()
        var text = try Notebook.textDocument(title: "Geteilt")
        (text, _) = try typed(text, "Inhalt")
        let url = outside.appendingPathComponent(NotyFile.fileName(for: text.title))
        _ = try BackupArchive.write(text, to: url)
        let repository = NotebookRepository(directory: root)
        let prepared = try await repository.prepareRestore(from: url)
        XCTAssertTrue(prepared.document.isTextDocument)
        let result = try await NotebookImport.commit(prepared, repository: repository, library: library, parentID: nil, replacing: nil)
        XCTAssertEqual(result.snapshot.items.first { $0.id == result.id }?.kind, .textDocument)
        let package = try await library.documentURL(id: result.id)
        let reopened = try RevisionStore(directory: package, readOnly: true).load()
        XCTAssertTrue(reopened.isTextDocument)
        XCTAssertEqual(reopened.textFlowContent?.text, "Inhalt")
    }
}
