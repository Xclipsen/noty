import Foundation

/// Host-only integration fixture. Built with Core sources; no Apple frameworks.
@main
struct PageWorkflowCheck {
    static func main() async throws {
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1])
        let root = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = try Data(contentsOf: fixture)
        var document = Notebook(); document.title = "UI-Rebuild Test 21"; document.pdf = source
        let boxes: [(PageRect, PageRect, Int)] = [
            (.init(x: 0, y: 0, width: 595, height: 842), .init(x: 40, y: 60, width: 515, height: 742), 0),
            (.init(x: 0, y: 0, width: 842, height: 595), .init(x: 60, y: 40, width: 722, height: 515), 90),
            (.init(x: -50, y: -50, width: 600, height: 800), .init(x: 0, y: 80, width: 500, height: 620), 180),
            (.init(x: 0, y: 0, width: 400, height: 300), .init(x: 20, y: 30, width: 330, height: 240), 270)
        ]
        document.pages = try boxes.enumerated().map { index, item in
            var page = Page(); page.geometry = try PDFPageGeometry(mediaBox: item.0, cropBox: item.1, rotation: item.2)
            page.text = "BULK-12 · Seite \(index + 1)"; return page
        }
        let oldIDs = document.pages.map(\.id)
        let storeRoot = root.appendingPathComponent("Source")
        let revisionStore = RevisionStore(directory: storeRoot)
        try revisionStore.save(document)
        let old = document
        try document.movePage(oldIDs[3], to: 0)
        _ = try document.insertPaper(.grid, color: .dark, at: 1)
        let copy = try document.duplicatePage(oldIDs[2])
        try document.trashPage(copy)
        try document.toggleBookmark(oldIDs[1])
        let margins = try document.marginsByPage(PageMargins(left: 120, right: 180, top: 80, bottom: 100, style: .grid),
            relativeTo: oldIDs[0], wholeImport: true)
        try document.applyMargins(margins)
        let marginPageIndex = document.pages.firstIndex { $0.id == oldIDs[0] }!
        document.pages[marginPageIndex].drawing = Data([10, 20])
        let beforeTrim = document.pages[marginPageIndex]
        try document.applyMargins(PageMargins(left: 20), pageIDs: [beforeTrim.id],
            trimmedDrawings: [beforeTrim.id: Data([10])])
        document.pages[marginPageIndex].text += " · nach Verkleinerung"
        let beforeRestore = document.pages[marginPageIndex]
        let marginSnapshot = document.deletedPages!.first!.id
        let restoredPageID = try document.restorePage(marginSnapshot)
        var savedCurrent = beforeRestore
        savedCurrent.id = document.deletedPages!.first!.id
        guard restoredPageID == beforeTrim.id, document.pages[marginPageIndex] == beforeTrim,
              document.deletedPages!.first!.page == savedCurrent else { throw StorageError.invalidDocument }
        var textObjects = document.pages[marginPageIndex].effectiveTextBoxes
        textObjects.append(TextBox(x: -100, y: -60, width: 90, height: 50, text: "ÄÖÜ ß · Rand",
            style: TextBoxStyle(font: .serif, fontSize: 20, bold: true, italic: true, underline: true, color: .blue)))
        var richStyle = textObjects[1].style; richStyle.highlighted = true; richStyle.alignment = .center
        richStyle.link = "https://example.org"; richStyle.indent = 12
        richStyle.fontName = "Courier"; richStyle.ink = InkColor(0.2, 0.6, 0.3)
        richStyle.strikethrough = true; richStyle.baseline = 1
        textObjects[1].flowID = UUID(); textObjects[1].flowRegion = .left
        var colorStyle = textObjects[1].style; colorStyle.color = .black; colorStyle.automaticColor = true
        colorStyle.highlighted = true; colorStyle.highlightColor = .green
        textObjects[1].runs = [TextRun(location: 0, length: 3, style: richStyle), TextRun(location: 3, length: 2, style: colorStyle)]
        try document.replaceTextBoxes(textObjects, pageID: beforeTrim.id)
        var appearance = NotebookAppearance(); appearance.cover = .purple; appearance.format = .a5; appearance.landscape = true
        document.appearance = appearance
        document.pages[1].geometry = appearance.geometry
        let flowRect = document.pages[1].writingRect(.page)!
        var continuation = TextBox(x: flowRect.x, y: flowRect.y, width: flowRect.width, height: flowRect.height, text: "Fortsetzung")
        continuation.flowID = textObjects[1].flowID; continuation.flowRegion = .page
        try document.replaceTextBoxes([continuation], pageID: document.pages[1].id)
        // Schema 10: the paper sheet grows right/down in its own paper (seamless lines).
        try document.applyMargins(PageMargins(right: 300, bottom: 120, style: .blank, color: .white), pageIDs: [document.pages[1].id])
        guard document.schemaVersion == 10,
              document.pages[1].margins == PageMargins(right: 300, bottom: 120, style: .grid, color: .dark),
              document.pages[1].writingCoordinateScale == 1 else { throw StorageError.invalidDocument }
        let imageData = try Data(contentsOf: fixture.deletingLastPathComponent().appendingPathComponent("Bildobjekt.png"))
        var image = ImageObject(data: imageData, pixelWidth: 64, pixelHeight: 48,
            x: -60, y: 20, width: 120, height: 90, rotation: 37, locked: true)
        image = try image.cropped(to: .init(x: 0.1, y: 0.2, width: 0.8, height: 0.6), in: document.pages[marginPageIndex].textBounds)
        try document.replaceImages([image], pageID: beforeTrim.id)
        let shapes = [
            ShapeObject(kind: .arrow, start: .init(x: -80, y: 140), end: .init(x: 180, y: 220), color: InkColor(0, 0.3, 1), lineWidth: 3, pattern: .dashed),
            ShapeObject(kind: .ellipse, start: .init(x: 230, y: 300), end: .init(x: 400, y: 400), lineWidth: 4, pattern: .dotted, fill: InkColor(1, 0.3, 0, 0.2))
        ]
        try document.replaceShapes(shapes, pageID: beforeTrim.id)
        let imageCopy = try document.duplicatePage(beforeTrim.id)
        try document.trashPage(imageCopy)
        let copiedPage = try document.copyPage(beforeTrim.id)
        let pastedPage = try document.pastePage(copiedPage, after: beforeTrim.id)
        try document.movePage(pastedPage, after: oldIDs[3])
        try document.clearPage(pastedPage)
        _ = try document.restorePage(document.deletedPages!.first!.id)
        try document.trashPage(pastedPage)
        try revisionStore.save(document)
        guard document.pdfSources?.first?.data == source, document.pages.first?.id == oldIDs[3],
              try RevisionStore(directory: storeRoot).load() == document else { throw StorageError.invalidDocument }
        try JSONEncoder().encode(document).write(to: root.appendingPathComponent("current.json"))
        let backup = try BackupArchive.encode(document)
        try backup.write(to: root.appendingPathComponent("heft.notybackup"))
        var corrupt = backup; corrupt[corrupt.count - 1] ^= 1
        try corrupt.write(to: root.appendingPathComponent("corrupt.notybackup"))
        let library = LibraryStore(root: storeRoot)
        _ = try await library.load()
        var tools = ToolbarPreferences(); tools.dock = .bottom; tools.floatingAxis = .vertical; tools.dockOnly = false; tools.normalizePageWidths = true; tools.autoPen = true; tools.pencilPreview = false; tools.paging = true
        tools.pencilColor = InkColor(0.3, 0.3, 0.32); tools.pencilWidth = 5; tools.autoPencil = true; tools.laserMode = .dot; tools.laserFade = .untilLift
        tools.laserColor = InkColor(0.2, 0.9, 0.3); tools.presets = [InkPreset(tool: .pencil, color: InkColor(0.1, 0.1, 0.1), width: 8), InkPreset(tool: .marker, color: InkColor(1, 1, 0), width: 14, markerTip: .round)]
        tools.markerTip = .chisel
        try await ToolbarPreferenceStore(root: storeRoot).save(tools, revision: 1)
        let bundle = try await library.backupBundle()
        let libraryFile = root.appendingPathComponent("bibliothek.notylibrary")
        try LibraryArchive.encode(bundle).write(to: libraryFile)
        let workspaces = WorkspaceStore(root: root.appendingPathComponent("Workspaces"))
        let staged = try await workspaces.prepareRestore(file: libraryFile)
        let restored = try await workspaces.commitRestore(staged, title: "Seiten-Restore")
        let restoredRoot = try await workspaces.directory(for: restored.id)
        let restoredLibrary = LibraryStore(root: restoredRoot)
        let roundTrip = try await restoredLibrary.backupBundle()
        guard roundTrip.toolbar == tools, roundTrip.documents == bundle.documents else { throw StorageError.invalidDocument }
        var independent = roundTrip.documents[0]
        try independent.restorePage(copy)
        var copiedBoxes = independent.pages[0].effectiveTextBoxes
        copiedBoxes[0].text = "Nur in der Kopie"
        try independent.replaceTextBoxes(copiedBoxes, pageID: independent.pages[0].id)
        var editedImage = image; editedImage.locked = false; editedImage.rotation = -45
        try independent.replaceImages([editedImage], pageID: beforeTrim.id)
        var changedShapes = shapes; changedShapes[0] = changedShapes[0].translated(x: 20, y: 10)
        try independent.replaceShapes(changedShapes, pageID: beforeTrim.id)
        let independentURL = try await restoredLibrary.documentURL(id: independent.id)
        try RevisionStore(directory: independentURL).save(independent)
        guard try RevisionStore(directory: storeRoot).load() == document,
              try RevisionStore(directory: independentURL).load() == independent,
              independent.pages.count == document.pages.count + 1,
              old.pages[0].text == "BULK-12 · Seite 1" else { throw StorageError.invalidDocument }
        let report: [String: Any] = ["schemaVersion": document.schemaVersion,
            "textFlowSurvivesLibraryRestore": roundTrip.documents[0].pages[1].textBoxes?.first?.flowID == continuation.flowID,
            "unmaterializedDraftExcludedFromNotebookArchive": !roundTrip.documents[0].pages.contains(where: { $0.id == document.writingDraft().id }),
            "richFormattingSurvivesLibraryRestore": roundTrip.documents[0].pages.first(where: { $0.id == beforeTrim.id })?.textBoxes?[1].runs == textObjects[1].runs,
            "automaticColorAndHighlightSurviveLibraryRestore": roundTrip.documents[0].pages.first(where: { $0.id == beforeTrim.id })?.textBoxes?[1].runs?.last?.style == colorStyle,
            "notebookAppearanceSurvivesLibraryRestore": roundTrip.documents[0].appearance == appearance,
            "bottomDockAndPreviewSettingsSurviveLibraryRestore": roundTrip.toolbar == tools,
            "pencilAndLaserSettingsSurviveLibraryRestore": roundTrip.toolbar.formatVersion == 8 && roundTrip.toolbar.laserStyle == tools.laserStyle && roundTrip.toolbar.presets == tools.presets,
            "activePages": document.pages.count, "deletedPages": document.deletedPages?.count ?? 0,
            "originalPDFBytesUnchanged": true, "editableShapesSurviveLibraryRestore": independent.pages.first(where: { $0.id == beforeTrim.id })?.shapes == changedShapes, "independentRestore": true,
            "originalImageBytesUnchanged": document.pages[marginPageIndex].images?.first?.data == imageData,
            "editableImageSurvivesLibraryRestore": independent.pages.first(where: { $0.id == beforeTrim.id })?.images == [editedImage],
            "marginRestoreKeepsPageIDAndArchivesCurrent": true, "appleFrameworksExecuted": false]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
