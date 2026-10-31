import SwiftUI
import PDFKit
import PencilKit
import Vision
import NotebookCore

private struct RecognizedLine: Sendable { let text: String; let bounds: PageRect }

/// One derived index directory per area (library root) under Library/Caches.
/// Never part of a notebook package, revision or backup; safe to delete.
@MainActor
enum ContentSearchIndexLocation {
    private static var stores: [String: ContentSearchIndexStore] = [:]
    static func store(area: String) -> ContentSearchIndexStore {
        if let store = stores[area] { return store }
        var name = ContentFingerprint("area"); name.add(area)
        let store = ContentSearchIndexStore(directory: URL.cachesDirectory
            .appendingPathComponent("NotySearchIndex", isDirectory: true)
            .appendingPathComponent(name.value, isDirectory: true))
        stores[area] = store
        return store
    }
}

private struct SearchIndexAreaKey: EnvironmentKey { static let defaultValue: String? = nil }
extension EnvironmentValues {
    /// Area scope (`StableDefaults.scope(libraryRoot)`) shared by library and editor search.
    var searchIndexArea: String? {
        get { self[SearchIndexAreaKey.self] }
        set { self[SearchIndexAreaKey.self] = newValue }
    }
}

@MainActor
final class ContentSearchModel: ObservableObject {
    @Published var records: [ContentSearchHit] = [] { didSet { hitRevision += 1 } }
    /// Counts changes of `records` and `tasks`: the view filters again off the main actor.
    @Published private(set) var hitRevision = 0
    @Published var status = "Suche wird vorbereitet …"
    @Published var running = false
    @Published var error: String?
    private var worker: Task<Void, Never>?
    private var generation = 0
    /// Hits per notebook and page: a recognised page only rebuilds its own hits.
    private var pageHits: [UUID: [[ContentSearchHit]]] = [:]
    private var order: [UUID] = []
    private var total = 0
    private var lastPublish = ContinuousClock.now
    @Published var tasks: [ContentSearchHit] = [] { didSet { hitRevision += 1 } }
    @Published var taskStatus = "Offene Aufgaben werden gesucht …"
    @Published var collectingTasks = false
    private(set) var tasksCollected = false
    private var taskWorker: Task<Void, Never>?
    func cancel() { generation += 1; worker?.cancel(); worker = nil; running = false }
    func cancelTasks() { taskWorker?.cancel(); taskWorker = nil; collectingTasks = false }
    /// Unchecked checkboxes only: no OCR, so the list is ready quickly.
    func collectTasks(documents: [OpenNotebook], current: Notebook? = nil) {
        cancelTasks(); tasks = []; collectingTasks = true; tasksCollected = true
        taskStatus = "Offene Aufgaben werden gesucht …"
        taskWorker = Task {
            var found: [ContentSearchHit] = [], failed = 0
            for document in documents {
                if Task.isCancelled { return }
                let notebook: Notebook
                if let current { notebook = current }
                else {
                    guard let loaded = try? await Task.detached(priority: .userInitiated, operation: {
                        try RevisionStore(directory: document.directory, readOnly: true).load()
                    }).value else { failed += 1; continue }
                    notebook = loaded
                }
                if Task.isCancelled { return }
                found += Self.taskHits(notebook, document: document)
                tasks = found
                await Task.yield()
            }
            let count = NotyText.count(found.count, "offene Aufgabe", "offene Aufgaben")
            taskStatus = found.isEmpty ? "Keine offenen Aufgaben" : count
            if failed > 0 { taskStatus += " · \(NotyText.count(failed, "Heft", "Hefte")) nicht lesbar" }
            collectingTasks = false
        }
    }
    /// Highlight the task's own lines (same native layout as editor/PDF).
    private static func taskHits(_ notebook: Notebook, document: OpenNotebook) -> [ContentSearchHit] {
        var layouts: [UUID: TextObjectLayout] = [:]
        return notebook.openTasks.compactMap { task in
            let page = notebook.pages[task.pageIndex]
            guard let box = page.effectiveTextBoxes.first(where: { $0.id == task.boxID }) else { return nil }
            let layout = layouts[box.id] ?? TextObjectLayout(box, on: page); layouts[box.id] = layout
            let start = max(0, task.body.location - 2)
            let glyphs = layout.manager.glyphRange(forCharacterRange: NSRange(location: start, length: NSMaxRange(task.body) - start), actualCharacterRange: nil)
            let rect = layout.manager.boundingRect(forGlyphRange: glyphs, in: layout.container)
            let scale = Double(layout.coordinateScale)
            let bounds = rect.isEmpty || !rect.minX.isFinite || box.rotation != nil ? box.rotatedBounds
                : PageRect(x: box.x + Double(rect.minX) * scale, y: box.y + Double(rect.minY) * scale,
                           width: max(1, Double(rect.width) * scale), height: max(1, Double(rect.height) * scale))
            return ContentSearchHit(documentID: document.id, pageID: task.pageID, pageNumber: task.pageIndex + 1,
                title: document.title, text: task.text.isEmpty ? "(leere Aufgabe)" : task.text, kind: .task, bounds: bounds)
        }
    }

    private struct Summary {
        var pages = 0, failed = 0, unreadable = 0
        func text(records: Int, total: Int) -> String {
            var text = "\(records) Textstellen erfasst"
            if total >= ContentSearchIndexFormat.hitLimit { text += " · Grenze 50.000 erreicht" }
            text += pages == 0 ? " · Suchindex aktuell" : pages == 1 ? " · 1 Seite neu erfasst" : " · \(pages) Seiten neu erfasst"
            if failed > 0 { text += " · \(NotyText.count(failed, "Erkennung", "Erkennungen")) fehlgeschlagen" }
            if unreadable > 0 { text += " · \(NotyText.count(unreadable, "Heft", "Hefte")) nicht lesbar" }
            return text + " · lokal, Deutsch/Englisch"
        }
    }

    /// Cached hits appear at once; only pages whose inputs changed are recognised
    /// again. Progress is stored while running, so closing the sheet keeps it.
    /// `retain`: all notebook IDs of the area (library search); other indexes are removed.
    func start(documents: [OpenNotebook], current: Notebook? = nil, currentSources: (@MainActor (Page) -> PDFPage?)? = nil,
               area: String, retain: Set<UUID>? = nil, rebuild: Bool = false) {
        cancel(); running = true; error = nil
        let expected = generation
        let store = ContentSearchIndexLocation.store(area: area)
        order = documents.map(\.id); pageHits = [:]; publish(force: true)
        status = rebuild ? "Suchindex wird neu erfasst …" : "Gespeicherte Treffer werden geladen …"
        worker = Task {
            defer { if generation == expected { running = false } }
            if rebuild { await store.remove(documents.map(\.id)) }
            var cached: [UUID: SearchDocumentIndex] = [:]
            for document in documents {
                guard let index = await store.load(document.id) else { continue }
                guard generation == expected else { return }
                cached[document.id] = index; show(index, document)
            }
            publish(force: true)
            if let retain { await store.prune(keeping: retain) }
            var summary = Summary()
            do {
                for document in documents {
                    try Task.checkCancellation()
                    try await indexDocument(document, cached: cached[document.id], current: current, currentSources: currentSources,
                                    store: store, expected: expected, summary: &summary)
                }
                guard generation == expected else { return }
                publish(force: true)
                status = summary.text(records: records.count, total: total)
            } catch is CancellationError {
                if generation == expected { publish(force: true); status = "Suche angehalten · bisherige Treffer bleiben sichtbar und gespeichert" }
            } catch {
                if generation == expected { publish(force: true); self.error = error.localizedDescription; status = "Suche unvollständig · bisherige Treffer sichtbar" }
            }
        }
    }

    private func indexDocument(_ document: OpenNotebook, cached: SearchDocumentIndex?, current: Notebook?,
                       currentSources: (@MainActor (Page) -> PDFPage?)?, store: ContentSearchIndexStore,
                       expected: Int, summary: inout Summary) async throws {
        let directory = document.directory
        // Read before the notebook: a newer commit in between only causes a later re-check.
        let stamp: String? = current == nil
            ? await Task.detached(priority: .utility) { NotebookRevisionStamp.read(directory: directory) }.value : nil
        if let stamp, cached?.revisionStamp == stamp { return }
        guard generation == expected else { throw CancellationError() }
        status = "\(document.title) · wird gelesen …"
        let notebook: Notebook
        // Image originals of a closed notebook come from its package (read-only);
        // the open notebook's from the registry.
        var assets: ImageAssetProviding?
        if let current { notebook = current }
        else {
            do {
                let package = try await Task.detached(priority: .utility) { () throws -> (Notebook, NotebookAssets) in
                    let store = RevisionStore(directory: directory, readOnly: true)
                    return (try store.load(), store.assets)
                }.value
                notebook = package.0; assets = package.1
            } catch { summary.unreadable += 1; return }
        }
        try Task.checkCancellation()
        let prepared = await Task.detached(priority: .utility) { ContentSearchPlanner.prepare(notebook) }.value
        var index = ContentSearchPlanner.reconcile(cached, documentID: document.id, pages: prepared)
        guard generation == expected else { throw CancellationError() }
        show(index, document); publish()
        var catalog: NotebookPDFCatalog?, catalogError: Error?
        // PDFKit parses lazily, only for pages whose PDF layers need recognition.
        func source(_ page: Page) throws -> PDFPage? {
            if let currentSources { return currentSources(page) }
            if let catalogError { throw catalogError }
            if catalog == nil {
                do { catalog = try NotebookPDFCatalog(notebook) } catch { catalogError = error; throw error }
            }
            return catalog?.sourcePage(for: page)
        }
        var lastSave = ContinuousClock.now
        do {
            for (offset, entry) in prepared.enumerated() {
                let pending = ContentSearchPlanner.pending(entry, index.pages[offset])
                guard !pending.isEmpty else { continue }
                try Task.checkCancellation()
                guard generation == expected else { throw CancellationError() }
                status = "\(document.title) · Seite \(offset + 1)/\(prepared.count)"
                let page = notebook.pages[offset]
                var record = index.pages[offset]
                do {
                    let needsSource = entry.hasPDF && (pending.contains(.pdfText) || pending.contains(.imageOCR) || page.geometry == nil)
                    let pdf = needsSource ? try source(page) : nil
                    if needsSource, pdf?.pageRef == nil { throw SearchSourceError.missingSource }
                    let layout = try PageLayout(page: page, source: pdf?.pageRef)
                    for layer in pending {
                        guard let fingerprint = entry.fingerprints[layer] else { continue }
                        do {
                            let lines: [SearchLine]
                            switch layer {
                            case .pdfText:
                                lines = pdf.map { Self.pdfLines($0, layout) } ?? []
                            case .imageOCR:
                                let background = pdf != nil && !ContentSearchPlanner.hasMeaningfulTextLayer(record.pdfText?.lines ?? [])
                                let images = page.images ?? []
                                lines = background || !images.isEmpty
                                    ? try await Self.recognizeBackground(background ? pdf?.pageRef.map(SendablePDFPage.init) : nil,
                                                                         images: images, layout: layout, assets: assets,
                                                                         keepAlive: pdf?.document) : []
                            case .handwriting:
                                lines = try await Self.recognizeInk(page.drawing, layout: layout)
                            }
                            record[layer] = SearchLayerRecord(fingerprint: fingerprint, lines: lines)
                        } catch {
                            summary.failed += 1
                            if generation == expected, self.error == nil { self.error = error.localizedDescription }
                        }
                        try Task.checkCancellation()
                    }
                } catch is CancellationError { throw CancellationError() }
                catch {
                    summary.failed += 1
                    if generation == expected, self.error == nil { self.error = error.localizedDescription }
                }
                index.pages[offset] = record
                summary.pages += 1
                guard generation == expected else { throw CancellationError() }
                show(page: offset, record, document); publish()
                if lastSave.duration(to: .now) > .seconds(3) { await store.save(index); lastSave = .now }
                await Task.yield()
                // PDFKit stays on the main actor: a real pause between PDF pages
                // lets touches through while a long PDF is being read.
                if pending.contains(.pdfText) { try await Task.sleep(for: .milliseconds(10)) }
            }
        } catch {
            await store.save(index)
            throw error
        }
        if let stamp, ContentSearchPlanner.isComplete(index, prepared) { index.revisionStamp = stamp }
        await store.save(index)
    }

    private enum SearchSourceError: LocalizedError {
        case missingSource
        var errorDescription: String? { "Die PDF-Seite konnte für die Suche nicht gelesen werden." }
    }

    private func show(_ index: SearchDocumentIndex, _ document: OpenNotebook) {
        pageHits[document.id] = index.pages.enumerated().map { offset, record in
            ContentSearchPlanner.hits(record, pageNumber: offset + 1, documentID: document.id, title: document.title)
        }
    }
    private func show(page offset: Int, _ record: SearchPageRecord, _ document: OpenNotebook) {
        guard pageHits[document.id]?.indices.contains(offset) == true else { return }
        pageHits[document.id]?[offset] = ContentSearchPlanner.hits(record, pageNumber: offset + 1, documentID: document.id, title: document.title)
    }
    /// Notebook order, then page order; capped like the original search.
    private func publish(force: Bool = false) {
        guard force || lastPublish.duration(to: .now) > .milliseconds(250) else { return }
        lastPublish = .now
        let limit = ContentSearchIndexFormat.hitLimit
        var result: [ContentSearchHit] = [], count = 0
        for id in order {
            for page in pageHits[id] ?? [] {
                count += page.count
                if result.count < limit { result.append(contentsOf: page.prefix(limit - result.count)) }
            }
        }
        total = count; records = result
    }

    private static func pdfLines(_ pdf: PDFPage, _ layout: PageLayout) -> [SearchLine] {
        guard let selection = pdf.selection(for: pdf.bounds(for: .cropBox)) else { return [] }
        return selection.selectionsByLine().compactMap { line in
            guard let text = line.string, !text.isEmpty else { return nil }
            let canvas = line.bounds(for: pdf).applying(layout.pdfToCanvas.cgTransform)
                .offsetBy(dx: -layout.contentOrigin.x, dy: -layout.contentOrigin.y)
            return SearchLine(text: text, kind: .pdf, bounds: PageRect(canvas))
        }
    }

    nonisolated private static func scale(_ layout: PageLayout) -> CGFloat {
        min(2, 2400 / max(layout.canvas.width, layout.canvas.height))
    }
    nonisolated private static func canonical(_ rect: PageRect, _ layout: PageLayout) -> PageRect {
        .init(x: rect.x * layout.canvas.width - layout.contentOrigin.x,
              y: (1 - rect.y - rect.height) * layout.canvas.height - layout.contentOrigin.y,
              width: rect.width * layout.canvas.width, height: rect.height * layout.canvas.height)
    }

    /// Scan/PDF background (only without a meaningful text layer) plus inserted images.
    /// `keepAlive` (the PDF document) outlives drawing its page off the main actor.
    /// `assets`: where image originals are read (nil: the registry).
    private static func recognizeBackground(_ pdf: SendablePDFPage?, images: [ImageObject], layout: PageLayout,
                                            assets: ImageAssetProviding? = nil, keepAlive: AnyObject?) async throws -> [SearchLine] {
        let lines = try await Task.detached(priority: .utility) { () throws -> [SearchLine] in
            let decoded = try images.map { object in
                let limit = ImageRendering.outputLimit(object, imagesOnPage: images.count, maximum: 2400, pixelsPerPoint: 3)
                return try ImageRendering.decoded(object, limit: limit, assets: assets)
            }
            guard let image = PageRaster.bitmap(size: layout.canvas.cgSize, scale: scale(layout), opaque: true, { context in
                UIColor.white.setFill(); context.fill(layout.canvas.bounds)
                if let pdf { PageRaster.drawSource(pdf.page, layout: layout, context: context) }
                for (object, image) in zip(images, decoded) { ImageRendering.draw(object, image: image, context: context, origin: layout.contentOrigin) }
            }) else { throw ImageImportError.invalid }
            return try recognize(image).map { SearchLine(text: $0.text, kind: .image, bounds: canonical($0.bounds, layout)) }
        }.value
        withExtendedLifetime(keepAlive) {}
        return lines
    }

    /// Ink normalised to black for OCR; stored strokes stay untouched.
    private static func recognizeInk(_ data: Data, layout: PageLayout) async throws -> [SearchLine] {
        try await Task.detached(priority: .utility) { () throws -> [SearchLine] in
            let drawing = try PKDrawing(data: data)
            let strokes = drawing.strokes.map { stroke in
                PKStroke(ink: PKInk(.pen, color: .black), path: stroke.path, transform: stroke.transform, mask: stroke.mask)
            }
            let pixelScale = scale(layout)
            let ink = PDFExporter.inkImage(PKDrawing(strokes: strokes), from: layout.canonicalInkBounds, scale: pixelScale)
            guard let image = PageRaster.bitmap(size: layout.canvas.cgSize, scale: pixelScale, opaque: true, { context in
                UIColor.white.setFill(); context.fill(layout.canvas.bounds)
                ink.draw(in: layout.canvas.bounds)
            }) else { throw ImageImportError.invalid }
            return try recognize(image).map { SearchLine(text: $0.text, kind: .handwriting, bounds: canonical($0.bounds, layout)) }
        }.value
    }

    nonisolated private static func recognize(_ image: CGImage) throws -> [RecognizedLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate; request.recognitionLanguages = ["de-DE", "en-US"]
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return RecognizedLine(text: candidate.string, bounds: PageRect(observation.boundingBox))
        }
    }
}

struct ContentSearchView: View {
    let documents: [OpenNotebook]
    var current: Notebook? = nil
    /// The editor's PDF catalogue: no second parse of the open notebook's PDFs.
    var currentSources: (@MainActor (Page) -> PDFPage?)? = nil
    /// Index area (`StableDefaults.scope(libraryRoot)`).
    let area: String
    /// Library search only: every notebook ID of the area (including trashed ones).
    var retain: Set<UUID>? = nil
    let onSelect: (ContentSearchHit) -> Void
    @StateObject private var model = ContentSearchModel()
    @State private var query = ""
    @State private var searching = false
    @State private var openTasks = false
    @Environment(\.dismiss) private var dismiss
    /// Filtered off the main actor: the index can hold 50 000 lines and
    /// changes while it is built, typing must stay fluid.
    @State private var hits: [ContentSearchHit] = []
    private func refreshHits() async {
        if !hits.isEmpty || !query.isEmpty { try? await Task.sleep(for: .milliseconds(120)) }
        guard !Task.isCancelled else { return }
        let tasksOnly = openTasks, term = query, source = openTasks ? model.tasks : model.records
        let found = await Task.detached(priority: .userInitiated) { () -> [ContentSearchHit] in
            if tasksOnly { return source.filter { term.trimmingCharacters(in: .whitespaces).isEmpty || $0.matches(term) } }
            return Array(source.lazy.filter { $0.matches(term) }.prefix(300))
        }.value
        if !Task.isCancelled { hits = found }
    }
    /// The field takes the focus only once the sheet stands; iOS 17 has no
    /// `searchFocused`, and a refused `isPresented` gives no signal, so look.
    private func focusField() async {
        for delay in [50, 300, 500] {
            try? await Task.sleep(for: .milliseconds(delay))
            if Task.isCancelled || UIResponder.currentFirstResponder is UISearchTextField { return }
            if searching { searching = false; try? await Task.sleep(for: .milliseconds(30)) }
            searching = true
        }
    }
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading) {
                Picker("Bereich", selection: $openTasks) {
                    Text("Alle Inhalte").tag(false); Text("Offene Aufgaben").tag(true)
                }.pickerStyle(.segmented).padding(.horizontal)
                Text(openTasks ? model.taskStatus : model.status).font(.caption).padding(.horizontal)
                if openTasks ? model.collectingTasks : model.running { ProgressView().padding(.horizontal) }
                if !openTasks {
                    Text("Handschrift und Scan-/Bild-OCR sind lokal. Erkanntes bleibt als abgeleiteter Suchindex auf diesem iPad gespeichert und wird nur für geänderte Seiten neu erfasst. Die Erkennungsqualität muss mit den eigenen Unterlagen geprüft werden.")
                        .font(.caption).foregroundStyle(.secondary).padding(.horizontal)
                }
                if let error = model.error { Text(error).foregroundStyle(.red).font(.caption).padding(.horizontal) }
                List(hits) { hit in
                    Button { model.cancel(); model.cancelTasks(); onSelect(hit); dismiss() } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(hit.title) · Seite \(hit.pageNumber)").font(.headline)
                            Text(hit.text).lineLimit(3)
                            Text(label(hit.kind)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }.overlay {
                    if openTasks, !model.collectingTasks, model.tasks.isEmpty {
                        ContentUnavailableView("Keine offenen Aufgaben", systemImage: "checkmark.circle",
                            description: Text("Nicht abgehakte Checkboxen aus dem Text erscheinen hier."))
                    } else if !(openTasks ? model.collectingTasks : model.running) && !query.isEmpty && hits.isEmpty { ContentUnavailableView.search(text: query) }
                }
            }.searchable(text: $query, isPresented: $searching, prompt: openTasks ? "Aufgaben filtern" : "Inhalt suchen")
                .onChange(of: openTasks) { _, tasks in
                    if tasks && !model.tasksCollected { model.collectTasks(documents: documents, current: current) }
                }
                .navigationTitle(current == nil ? "In allen Heften suchen" : current?.isTextDocument == true ? "Im Dokument suchen" : "Im Heft suchen")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } }
                    ToolbarItem(placement: .primaryAction) {
                        if openTasks { Button("Aktualisieren") { model.collectTasks(documents: documents, current: current) }.disabled(model.collectingTasks) }
                        else if model.running { Button("Anhalten") { model.cancel() } }
                        else { Button("Neu erfassen") { start(rebuild: true) } }
                    }
                }
                .task { start(rebuild: false) }
                .task { await focusField() }
                .task(id: "\(query)|\(openTasks)|\(model.hitRevision)") { await refreshHits() }
                .onDisappear { model.cancel(); model.cancelTasks() }
        }
    }
    private func start(rebuild: Bool) {
        model.start(documents: documents, current: current, currentSources: currentSources, area: area, retain: retain, rebuild: rebuild)
    }
    private func label(_ kind: SearchContentKind) -> String {
        switch kind { case .text: "Textfeld"; case .pdf: "PDF-Text"; case .image: "Scan/Bild · OCR"; case .handwriting: "Handschrift · OCR"; case .task: "Offene Aufgabe" }
    }
}
