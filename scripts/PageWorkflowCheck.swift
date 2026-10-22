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
        var colorStyle = textObjects[1].style; colorStyle.color = .black; colorStyle.automaticColor = true
        colorStyle.highlighted = true; colorStyle.highlightColor = .green
        textObjects[1].runs = [TextRun(location: 0, length: 3, style: richStyle), TextRun(location: 3, length: 2, style: colorStyle)]
        try document.replaceTextBoxes(textObjects, pageID: beforeTrim.id)
        var appearance = NotebookAppearance(); appearance.cover = .purple; appearance.format = .a5; appearance.landscape = true
        document.appearance = appearance
        document.pages[1].geometry = appearance.geometry
        let flowRect = document.pages[1].writingRect(.page)!
        // Page text (flows) no longer exists in notebooks (Textneubau, schema 14):
        // a plain free field here; the flow migration is checked separately.
        let continuation = TextBox(x: flowRect.x, y: flowRect.y, width: flowRect.width, height: flowRect.height, text: "Fortsetzung")
        try document.replaceTextBoxes([continuation], pageID: document.pages[1].id)
        // Schema 11: the paper sheet grows right/down in its own paper (seamless lines).
        try document.applyMargins(PageMargins(right: 300, bottom: 120, style: .blank, color: .white), pageIDs: [document.pages[1].id])
        guard document.schemaVersion == 11,
              document.pages[1].margins == PageMargins(right: 300, bottom: 120, style: .grid, color: .dark),
              document.pages[1].writingCoordinateScale == 1 else { throw StorageError.invalidDocument }
        let imageData = try Data(contentsOf: fixture.deletingLastPathComponent().appendingPathComponent("Bildobjekt.png"))
        // Schema 12: the original is staged in the package's asset store; the
        // next commit writes Assets/<sha256> before its revision.
        let imageAsset = try revisionStore.assets.stage(imageData)
        var image = ImageObject(asset: imageAsset, pixelWidth: 64, pixelHeight: 48,
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
        guard document.schemaVersion == 12, document.pdfSources?.first?.data == source, document.pages.first?.id == oldIDs[3],
              try RevisionStore(directory: storeRoot).load() == document else { throw StorageError.invalidDocument }
        // Duplicated, copied and trashed pages share one original: exactly one asset file.
        let assetFiles = try FileManager.default.contentsOfDirectory(atPath: storeRoot.appendingPathComponent("Assets").path)
        let storedOriginal = try Data(contentsOf: storeRoot.appendingPathComponent("Assets/\(imageAsset.sha256)"))
        guard document.allImages.count >= 3, assetFiles == [imageAsset.sha256], storedOriginal == imageData,
              revisionStore.assets.pendingReferences.isEmpty else { throw StorageError.invalidDocument }
        try JSONEncoder().encode(document).write(to: root.appendingPathComponent("current.json"))
        // The same state as Build 53 stored it (schema 11, original embedded).
        let legacyCurrent = try Self.legacyJSON(document, originals: [imageAsset.sha256: imageData])
        try legacyCurrent.write(to: root.appendingPathComponent("current-v11.json"))
        // Format 2 through the app's streaming file writer; format 1 as older builds wrote it.
        // Written as `.noty` (TEXT-REBUILD-62 §5): same format-2 content as `.notybackup`.
        let backupURL = root.appendingPathComponent("heft.noty")
        let writtenBackup = try BackupArchive.write(document, assets: revisionStore.assets, to: backupURL)
        let backup = try Data(contentsOf: backupURL)
        guard writtenBackup.formatVersion == 2, writtenBackup.file == (try BoundedFile.checksum(backupURL)),
              writtenBackup.assets == [imageAsset],
              try BackupArchive.encode(document, assets: revisionStore.assets, createdAt: Date()).count == backup.count else {
            throw StorageError.invalidDocument
        }
        // One flipped byte inside the asset record (SHA-256) must be refused.
        guard let assetRange = backup.range(of: imageData) else { throw StorageError.invalidDocument }
        var corrupt = backup; corrupt[assetRange.lowerBound + imageData.count / 2] ^= 1
        try corrupt.write(to: root.appendingPathComponent("corrupt.noty"))
        // Format 1 as Build 53 wrote it: schema 11 with the embedded original.
        let legacyBackupURL = root.appendingPathComponent("heft-v1.notybackup")
        try BackupArchive.encodeVersion1(payload: legacyCurrent).write(to: legacyBackupURL)
        // Both formats restore as separate copies through the staged repository path.
        let restoreRepository = NotebookRepository(directory: root.appendingPathComponent("RestoreCheck"))
        var restoredBackups: [Int] = []
        for url in [backupURL, legacyBackupURL] {
            let prepared = try await restoreRepository.prepareRestore(from: url)
            let restoredCopy = try await restoreRepository.commitRestore(prepared)
            let reopened = try RevisionStore(directory: restoredCopy.directory).load()
            let restoredOriginal = try Data(contentsOf: restoredCopy.directory.appendingPathComponent("Assets/\(imageAsset.sha256)"))
            guard reopened.id != document.id, reopened.pages == document.pages, reopened.deletedPages == document.deletedPages,
                  reopened.schemaVersion == 12, restoredOriginal == imageData,
                  reopened.title == document.title else { throw StorageError.invalidDocument }
            restoredBackups.append(try BackupArchive.verify(url).formatVersion)
        }
        let library = LibraryStore(root: storeRoot)
        _ = try await library.load()
        var tools = ToolbarPreferences(); tools.dock = .bottom; tools.floatingAxis = .vertical; tools.dockOnly = false; tools.normalizePageWidths = true; tools.autoPen = true; tools.pencilPreview = false; tools.paging = true
        tools.pencilColor = InkColor(0.3, 0.3, 0.32); tools.pencilWidth = 5; tools.autoPencil = true; tools.laserMode = .dot; tools.laserFade = .untilLift
        tools.laserColor = InkColor(0.2, 0.9, 0.3); tools.presets = [InkPreset(tool: .pencil, color: InkColor(0.1, 0.1, 0.1), width: 8), InkPreset(tool: .marker, color: InkColor(1, 1, 0), width: 14, markerTip: .round)]
        tools.markerTip = .chisel
        try await ToolbarPreferenceStore(root: storeRoot).save(tools, revision: 1)
        let bundle = try await library.backupBundle()
        let libraryFile = root.appendingPathComponent("bibliothek.notylibrary")
        // Streaming file writer of the app; re-read once more in memory here.
        let written = try LibraryArchive.write(try await library.backupPlan(), to: libraryFile)
        guard try LibraryArchive.decode(Data(contentsOf: libraryFile)) == bundle, written.assetCount == 1,
              written.file == (try BoundedFile.checksum(libraryFile)) else { throw StorageError.invalidDocument }
        var corruptLibrary = try Data(contentsOf: libraryFile); corruptLibrary[corruptLibrary.count / 2] ^= 1
        try corruptLibrary.write(to: root.appendingPathComponent("corrupt.notylibrary"))
        let workspaces = WorkspaceStore(root: root.appendingPathComponent("Workspaces"))
        let staged = try await workspaces.prepareRestore(file: libraryFile)
        let restored = try await workspaces.commitRestore(staged, title: "Seiten-Restore")
        let restoredRoot = try await workspaces.directory(for: restored.id)
        let restoredLibrary = LibraryStore(root: restoredRoot)
        let roundTrip = try await restoredLibrary.backupBundle()
        let restoredPackage = try await restoredLibrary.documentURL(id: document.id)
        guard roundTrip.toolbar == tools, roundTrip.documents == bundle.documents,
              try Data(contentsOf: restoredPackage.appendingPathComponent("Assets/\(imageAsset.sha256)")) == imageData else {
            throw StorageError.invalidDocument
        }
        var independent = roundTrip.documents[0]
        try independent.restorePage(copy)
        var copiedBoxes = independent.pages[0].effectiveTextBoxes
        copiedBoxes[0].text = "Nur in der Kopie"
        try independent.replaceTextBoxes(copiedBoxes, pageID: independent.pages[0].id)
        var editedImage = image; editedImage.locked = false; editedImage.rotation = -45
        try independent.replaceImages([editedImage], pageID: beforeTrim.id)
        var changedShapes = shapes; changedShapes[0] = changedShapes[0].translated(x: 20, y: 10)
        // Schema 13: a bent arrow and a polygon as held shapes with corners.
        changedShapes += [ShapeObject(kind: .arrow, vertices: [.init(x: 20, y: 250), .init(x: 20, y: 290), .init(x: 150, y: 290)], lineWidth: 2.5),
                          ShapeObject(kind: .polygon, vertices: [.init(x: 60, y: 300), .init(x: 160, y: 300), .init(x: 110, y: 380)], color: InkColor(0.8, 0, 0))]
        let schemaBeforeVertices = independent.schemaVersion
        try independent.replaceShapes(changedShapes, pageID: beforeTrim.id)
        let independentURL = try await restoredLibrary.documentURL(id: independent.id)
        let independentStore = RevisionStore(directory: independentURL)
        try independentStore.save(independent)
        guard try RevisionStore(directory: storeRoot).load() == document,
              try RevisionStore(directory: independentURL).load() == independent,
              schemaBeforeVertices == 12, independent.schemaVersion == 13,
              independent.pages.count == document.pages.count + 1,
              old.pages[0].text == "BULK-12 · Seite 1" else { throw StorageError.invalidDocument }
        // The schema-13 copy as a format-2 backup, checked by the Python verifier.
        _ = try BackupArchive.write(independent, assets: independentStore.assets, to: root.appendingPathComponent("heft-v13.notybackup"))
        try JSONEncoder().encode(independent).write(to: root.appendingPathComponent("current-v13.json"))
        let migrated = try FileManager.default.contentsOfDirectory(at: independentURL.appendingPathComponent("Migrations"), includingPropertiesForKeys: nil)
        guard migrated.contains(where: { FileManager.default.fileExists(atPath: $0.appendingPathComponent("notebook-v12.json").path) }) else {
            throw StorageError.invalidDocument
        }
        let legacyPackage = try await Self.checkLegacyPackage(root: root, image: imageData)
        let flowPackage = try await Self.checkTextFlowMigration(root: root)
        let textDocument = try await Self.checkTextDocument(root: root)
        let report: [String: Any] = ["schemaVersion": document.schemaVersion,
            "textFieldSurvivesLibraryRestore": roundTrip.documents[0].pages[1].textBoxes?.first == continuation,
            "unmaterializedDraftExcludedFromNotebookArchive": !roundTrip.documents[0].pages.contains(where: { $0.id == document.writingDraft().id }),
            "richFormattingSurvivesLibraryRestore": roundTrip.documents[0].pages.first(where: { $0.id == beforeTrim.id })?.textBoxes?[1].runs == textObjects[1].runs,
            "automaticColorAndHighlightSurviveLibraryRestore": roundTrip.documents[0].pages.first(where: { $0.id == beforeTrim.id })?.textBoxes?[1].runs?.last?.style == colorStyle,
            "notebookAppearanceSurvivesLibraryRestore": roundTrip.documents[0].appearance == appearance,
            "bottomDockAndPreviewSettingsSurviveLibraryRestore": roundTrip.toolbar == tools,
            "pencilAndLaserSettingsSurviveLibraryRestore": roundTrip.toolbar.formatVersion == 8 && roundTrip.toolbar.laserStyle == tools.laserStyle && roundTrip.toolbar.presets == tools.presets,
            "activePages": document.pages.count, "deletedPages": document.deletedPages?.count ?? 0,
            "originalPDFBytesUnchanged": true, "editableShapesSurviveLibraryRestore": independent.pages.first(where: { $0.id == beforeTrim.id })?.shapes == changedShapes, "independentRestore": true,
            "originalImageBytesUnchanged": storedOriginal == imageData && document.pages[marginPageIndex].images?.first?.asset == imageAsset,
            "duplicatedImagesShareOneAssetFile": assetFiles.count == 1,
            "editableImageSurvivesLibraryRestore": independent.pages.first(where: { $0.id == beforeTrim.id })?.images == [editedImage],
            "marginRestoreKeepsPageIDAndArchivesCurrent": true, "appleFrameworksExecuted": false,
            "libraryArchiveBytes": written.file.byteCount, "libraryArchiveCRC32": Int(written.file.crc32),
            "libraryArchiveFormat": written.formatVersion, "notebookBackupFormatsRestored": restoredBackups,
            "archiveAssets": written.assetCount + writtenBackup.assets.count,
            "legacySchema11OpenWritesNothing": legacyPackage.openWritesNothing,
            "legacySchema11EditKeepsExactBytesUnderMigrations": legacyPackage.exactBytesArchived,
            "legacySchema11EditWritesAssetThenSchema12": legacyPackage.assetWritten,
            "pageTextSchema13OpenWritesNothing": flowPackage.openWritesNothing,
            "pageTextSchema13EditKeepsExactBytesUnderMigrations": flowPackage.exactBytesArchived,
            "pageTextBecomesFieldsAtSameFrameInSchema14": flowPackage.sameFrames,
            "textDocumentSchema15KeepsFlowAndHandwritingPage": textDocument.flowKept,
            "textDocumentKindAndFieldStyleSurviveNotyImportAndLibraryRestore": textDocument.kindKept,
            "textDocumentMarkdownExport": textDocument.markdown]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }

    /// The stored form of Build 53 (schema 11): every image's original as
    /// Base64 `data` instead of `asset`. Only this fixture writes it.
    static func legacyJSON(_ document: Notebook, originals: [String: Data]) throws -> Data {
        guard var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(document)) as? [String: Any] else {
            throw StorageError.invalidDocument
        }
        object["schemaVersion"] = 11
        func embed(_ page: [String: Any]) throws -> [String: Any] {
            guard var images = page["images"] as? [[String: Any]] else { return page }
            for index in images.indices {
                guard let asset = images[index].removeValue(forKey: "asset") as? [String: Any],
                      let hash = asset["sha256"] as? String, let bytes = originals[hash] else { throw StorageError.invalidDocument }
                images[index]["data"] = bytes.base64EncodedString()
            }
            var result = page; result["images"] = images; return result
        }
        object["pages"] = try (object["pages"] as? [[String: Any]] ?? []).map(embed)
        if let deleted = object["deletedPages"] as? [[String: Any]] {
            object["deletedPages"] = try deleted.map { entry in
                var entry = entry; entry["page"] = try embed(entry["page"] as? [String: Any] ?? [:]); return entry
            }
        }
        let bytes = try JSONSerialization.data(withJSONObject: object)
        guard try NotebookDecoding.decode(bytes).storedSchemaVersion == 11 else { throw StorageError.invalidDocument }
        return bytes
    }

    /// An old package exactly as Build 53 committed it: handwritten schema-11
    /// JSON with an embedded image, one revision, Build-46 manifest. Opening
    /// (load plus the editor's unchanged save) must write nothing; the first
    /// edit keeps the exact old bytes under Migrations/, then writes the asset
    /// and a schema-12 revision.
    static func checkLegacyPackage(root: URL, image: Data) async throws -> (openWritesNothing: Bool, exactBytesArchived: Bool, assetWritten: Bool) {
        let fm = FileManager.default
        let package = root.appendingPathComponent("Legacy", isDirectory: true)
        let revisions = package.appendingPathComponent("Revisions", isDirectory: true)
        try fm.createDirectory(at: revisions, withIntermediateDirectories: true)
        let id = "6F1B2C3D-4E5F-4A6B-8C7D-0E1F2A3B4C5D"
        let json = """
        {"schemaVersion":11,"id":"\(id)","title":"Altheft mit Bild","pdfSources":[],"deletedPages":[],\
        "pages":[{"id":"0A1B2C3D-4E5F-4A6B-8C7D-111111111111","drawing":"","text":"","paper":"lined",\
        "geometry":{"mediaBox":{"x":0,"y":0,"width":595,"height":842},"cropBox":{"x":0,"y":0,"width":595,"height":842},"rotation":0},\
        "images":[{"id":"0A1B2C3D-4E5F-4A6B-8C7D-222222222222","data":"\(image.base64EncodedString())","pixelWidth":64,"pixelHeight":48,\
        "x":60,"y":80,"width":128,"height":96,"rotation":0,"crop":{"x":0,"y":0,"width":1,"height":1},"locked":false},\
        {"id":"0A1B2C3D-4E5F-4A6B-8C7D-333333333333","data":"\(image.base64EncodedString())","pixelWidth":64,"pixelHeight":48,\
        "x":260,"y":80,"width":128,"height":96,"rotation":0,"crop":{"x":0,"y":0,"width":1,"height":1},"locked":false}]}]}
        """
        let bytes = Data(json.utf8)
        let file = "11111111-2222-4333-8444-555555555555.json"
        try bytes.write(to: revisions.appendingPathComponent(file))
        let manifest = """
        {"formatVersion":1,"checksumAlgorithm":"crc32-iso-hdlc","revisions":[{"file":"\(file)","byteCount":\(bytes.count),"crc32":\(SnapshotChecksum.crc32(bytes)),"savedAtUnix":1800000000}]}
        """
        try Data(manifest.utf8).write(to: package.appendingPathComponent("manifest.json"))
        func inventory() throws -> [String: Data] {
            var result: [String: Data] = [:]
            let enumerator = fm.enumerator(at: package, includingPropertiesForKeys: nil)!
            for case let url as URL in enumerator {
                let isFile = (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true
                result[String(url.path.dropFirst(package.path.count))] = isFile ? try Data(contentsOf: url) : Data()
            }
            return result
        }
        let before = try inventory()
        let repository = NotebookRepository(directory: package)
        var (notebook, recovered) = try await repository.load()
        // Raised in memory: schema 12, one asset for both objects, nothing written.
        guard !recovered, notebook.schemaVersion == 12, notebook.externalImageAssets == [ImageAssetReference(of: image)],
              repository.assets.pendingReferences == [ImageAssetReference(of: image)] else { throw StorageError.invalidDocument }
        try await repository.save(notebook, revision: 1) // the editor's save right after opening
        // The editor's asset GC after opening: an empty run, nothing written.
        let openingRun = try await repository.collectAssetGarbage(.opening, current: notebook, keeping: [])
        let openWritesNothing = try inventory() == before && !fm.fileExists(atPath: package.appendingPathComponent("Assets").path)
            && openingRun == ImageAssetGarbageReport()
        notebook.pages[0].drawing = Data()
        var boxes = notebook.pages[0].effectiveTextBoxes
        boxes.append(TextBox(x: 60, y: 300, width: 300, height: 40, text: "Erste Änderung nach dem Update"))
        try notebook.replaceTextBoxes(boxes, pageID: notebook.pages[0].id)
        try await repository.save(notebook, revision: 2)
        let migrations = package.appendingPathComponent("Migrations", isDirectory: true)
        let archived = try fm.contentsOfDirectory(at: migrations, includingPropertiesForKeys: nil)
            .map { $0.appendingPathComponent("notebook-v11.json") }.filter { fm.fileExists(atPath: $0.path) }
        let exactBytesArchived = try archived.count == 1 && Data(contentsOf: archived[0]) == bytes
        let reference = ImageAssetReference(of: image)
        // The closing GC after the last commit keeps the migrated original.
        guard try await repository.collectAssetGarbage(.closing, current: notebook, keeping: []) == ImageAssetGarbageReport() else {
            throw StorageError.invalidDocument
        }
        let reopened = try RevisionStore(directory: package).load()
        let assetWritten = try Data(contentsOf: package.appendingPathComponent("Assets/\(reference.sha256)")) == image
            && reopened == notebook && repository.assets.pendingReferences.isEmpty
        guard openWritesNothing, exactBytesArchived, assetWritten else { throw StorageError.invalidDocument }
        return (openWritesNothing, exactBytesArchived, assetWritten)
    }

    /// Text document (schema 15, Textneubau Stufe 3): created in a library,
    /// text flowing over three pages around a page with handwriting, a free
    /// field; shared as `.noty`, imported again (kind recognised), backed up
    /// with the library and restored into a new area (kind taken from the
    /// document even though the archived index lost the hint). Python checks
    /// the package, the `.noty` file and the library archive.
    static func checkTextDocument(root: URL) async throws -> (flowKept: Bool, kindKept: Bool, markdown: Bool) {
        let libraryRoot = root.appendingPathComponent("TextDocument", isDirectory: true)
        let library = LibraryStore(root: libraryRoot); _ = try await library.load()
        var document = try Notebook.textDocument(title: "Referat Ökologie", landscape: false, paper: .lined)
        var draft = document.writingDraft(); draft.drawing = Data([7, 7, 7])
        try document.materializeWritingDraft(draft)
        let first = document.textFlowSegments[0]
        var typed = first.box
        typed.text = "Einleitung\n• Punkt eins\n☐ offen\n" + String(repeating: "Text ", count: 40)
        var heading = typed.style; TextStylePreset.title.apply(to: &heading)
        typed.runs = [TextRun(location: 0, length: 10, style: heading)]
        (document, _) = try document.reflowText(pageID: first.pageID, previous: first.box, replacement: typed,
            selection: NSRange(location: (typed.text as NSString).length, length: 0),
            pageCapacity: { _, box in min(90, (box.text as NSString).length) })
        var boxes = document.pages[0].effectiveTextBoxes
        var field = TextBox(x: 300, y: 600, width: 120, height: 24, text: "Randnotiz"); field.autoWidth = true
        field.fill = .blue; field.border = .accent // Feldstil (Stufe 4), schema 14 inside the text document's 15
        boxes.append(field)
        try document.replaceTextBoxes(boxes, pageID: document.pages[0].id)
        let flowKept = document.schemaVersion == 15 && document.isTextDocument && document.pages.count == 3
            && document.pages[1].id == draft.id && document.pages[1].drawing == Data([7, 7, 7])
            && document.textFlowSegments.count == 3 && document.textFlowContent?.text == typed.text
        _ = try await library.createDocument(document, parentID: nil)
        let package = try await library.documentURL(id: document.id)
        let reopened = try RevisionStore(directory: package, readOnly: true).load()
        let shareURL = root.appendingPathComponent("textdokument.noty")
        _ = try BackupArchive.write(reopened, to: shareURL)
        try JSONEncoder().encode(reopened).write(to: root.appendingPathComponent("current-textdokument.json"))
        let repository = NotebookRepository(directory: libraryRoot)
        let prepared = try await repository.prepareRestore(from: shareURL)
        let imported = try await NotebookImport.commit(prepared, repository: repository, library: library, parentID: nil, replacing: nil)
        // An older build rewrote the index without the hint: the restore takes the kind from the documents.
        var plan = try await library.backupBundle()
        plan.snapshot.items = plan.snapshot.items.map { var item = $0; item.kind = nil; return item }
        let archiveURL = root.appendingPathComponent("textdokument.notylibrary")
        try LibraryArchive.encode(plan).write(to: archiveURL)
        let written = try LibraryArchive.write(try await library.backupPlan(), to: root.appendingPathComponent("textdokument-index.notylibrary"))
        let workspaces = WorkspaceStore(root: root.appendingPathComponent("TextDocumentWorkspaces"))
        let staged = try await workspaces.prepareRestore(file: archiveURL)
        let restored = try await workspaces.commitRestore(staged, title: "Textdokument-Restore")
        let restoredSnapshot = try await LibraryStore(root: try await workspaces.directory(for: restored.id)).load().snapshot
        let importedDocument = try RevisionStore(directory: try await library.documentURL(id: imported.id), readOnly: true).load()
        let restoredLibrary = LibraryStore(root: try await workspaces.directory(for: restored.id))
        var restoredStyles: [TextBox?] = []
        for item in try await restoredLibrary.load().snapshot.items where !item.isFolder {
            let restoredDocument = try RevisionStore(directory: try await restoredLibrary.documentURL(id: item.id), readOnly: true).load()
            restoredStyles.append(restoredDocument.pages[0].textBoxes?.first(where: { $0.flowID == nil }))
        }
        let styleKept = importedDocument.pages[0].textBoxes?.first(where: { $0.flowID == nil })?.fill == .blue
            && restoredStyles.count == 2 && restoredStyles.allSatisfy { $0?.fill == .blue && $0?.border == .accent }
        let kindKept = reopened == document && styleKept
            && imported.snapshot.items.first(where: { $0.id == imported.id })?.kind == .textDocument
            && written.notebooks.count == 2
            && restoredSnapshot.items.filter { !$0.isFolder }.allSatisfy { $0.kind == .textDocument }
            && restoredSnapshot.items.filter { !$0.isFolder }.count == 2
        let markdown = TextDocumentExport.markdown(document).hasPrefix("# Einleitung\n\n- Punkt eins\n- [ ] offen\n\nText Text")
        guard flowKept, kindKept, markdown else { throw StorageError.invalidDocument }
        return (flowKept, kindKept, markdown)
    }

    /// Page text as Build ≤ 62 stored it (schema 13, flow segments over two
    /// pages and in the page trash). Opening writes nothing; the notebook is
    /// shown with free fields at exactly the same frames (schema 14 in
    /// memory). The first edit keeps the exact old bytes under Migrations/
    /// and commits schema 14; Python verifies the package and a backup.
    static func checkTextFlowMigration(root: URL) async throws -> (openWritesNothing: Bool, exactBytesArchived: Bool, sameFrames: Bool) {
        let fm = FileManager.default
        let package = root.appendingPathComponent("FlowMigration", isDirectory: true)
        let revisions = package.appendingPathComponent("Revisions", isDirectory: true)
        try fm.createDirectory(at: revisions, withIntermediateDirectories: true)
        var appearance = NotebookAppearance(); appearance.paper = .lined
        var old = try Notebook.blank(title: "Seitentext", appearance: appearance)
        _ = try old.insertPaper(.lined, at: 1, geometry: PaperStyle.geometry)
        old = try old.preparedForTextEditing()
        let rect = old.pages[0].writingRect(.page)!
        let flow = UUID()
        var first = TextBox(x: rect.x, y: rect.y, width: rect.width, height: rect.height, text: "Mitschrift ÄÖÜ ß\n• Punkt")
        first.flowID = flow; first.flowRegion = .page
        var bold = first.style; bold.bold = true
        first.runs = [TextRun(location: 0, length: 10, style: bold)]
        var second = first; second.id = UUID(); second.text = "Fortsetzung"; second.runs = nil
        try old.replaceTextBoxes([first], pageID: old.pages[0].id)
        try old.replaceTextBoxes([second], pageID: old.pages[1].id)
        let trashed = try old.duplicatePage(old.pages[0].id)
        try old.trashPage(trashed)
        old.schemaVersion = 13
        let bytes = try JSONEncoder().encode(old)
        guard try NotebookDecoding.decode(bytes).storedSchemaVersion == 13 else { throw StorageError.invalidDocument }
        let file = "21111111-2222-4333-8444-555555555555.json"
        try bytes.write(to: revisions.appendingPathComponent(file))
        let manifest = """
        {"formatVersion":1,"checksumAlgorithm":"crc32-iso-hdlc","revisions":[{"file":"\(file)","byteCount":\(bytes.count),"crc32":\(SnapshotChecksum.crc32(bytes)),"savedAtUnix":1800000000}]}
        """
        try Data(manifest.utf8).write(to: package.appendingPathComponent("manifest.json"))
        func inventory() throws -> [String: Data] {
            var result: [String: Data] = [:]
            let enumerator = fm.enumerator(at: package, includingPropertiesForKeys: nil)!
            for case let url as URL in enumerator {
                let isFile = (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true
                result[String(url.path.dropFirst(package.path.count))] = isFile ? try Data(contentsOf: url) : Data()
            }
            return result
        }
        let before = try inventory()
        let repository = NotebookRepository(directory: package)
        var (notebook, recovered) = try await repository.load()
        try await repository.save(notebook, revision: 1) // the editor's save right after opening
        let openWritesNothing = try inventory() == before
        let fields = notebook.pages.compactMap { $0.textBoxes?.first }
        let trashedField = notebook.deletedPages?.first?.page.textBoxes?.first
        let sameFrames = !recovered && notebook.schemaVersion == 14 && !notebook.containsTextFlow
            && fields.map(\.rect) == [first.rect, second.rect] && fields.map(\.text) == [first.text, second.text]
            && fields[0].runs == first.runs && fields.allSatisfy { $0.flowRegion == .page && $0.flowID == nil }
            && trashedField?.text == first.text && trashedField?.flowID == nil
        // A typical first edit after the update: a rotated, automatically wide field.
        var boxes = notebook.pages[0].effectiveTextBoxes
        var turned = TextBox(x: 300, y: 500, width: 120, height: 24, text: "Gedreht")
        turned.rotation = -30; turned.autoWidth = true
        turned.fill = .yellow; turned.border = .text // Feldstil (Stufe 4): schema 14, no further raise
        boxes.append(turned)
        try notebook.replaceTextBoxes(boxes, pageID: notebook.pages[0].id)
        try await repository.save(notebook, revision: 2)
        let archived = try fm.contentsOfDirectory(at: package.appendingPathComponent("Migrations"), includingPropertiesForKeys: nil)
            .map { $0.appendingPathComponent("notebook-v13.json") }.filter { fm.fileExists(atPath: $0.path) }
        let exactBytesArchived = try archived.count == 1 && Data(contentsOf: archived[0]) == bytes
        let reopened = try RevisionStore(directory: package).load()
        guard openWritesNothing, sameFrames, exactBytesArchived, reopened == notebook else { throw StorageError.invalidDocument }
        // Schema 14 written by Swift, verified independently by Python.
        _ = try BackupArchive.write(notebook, assets: repository.assets, to: root.appendingPathComponent("heft-v14.notybackup"))
        try JSONEncoder().encode(notebook).write(to: root.appendingPathComponent("current-v14.json"))
        return (openWritesNothing, exactBytesArchived, sameFrames)
    }
}

