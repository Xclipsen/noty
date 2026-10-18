import SwiftUI
import PDFKit
import PencilKit
import Vision
import ImageIO
import NotebookCore

private struct RecognizedLine: Sendable { let text: String; let bounds: PageRect }

@MainActor
final class ContentSearchModel: ObservableObject {
    @Published var records: [ContentSearchHit] = []
    @Published var status = "Suche wird vorbereitet …"
    @Published var running = false
    @Published var error: String?
    private var worker: Task<Void, Never>?
    private var generation = 0
    func cancel() { generation += 1; worker?.cancel(); worker = nil; running = false }
    func start(documents: [OpenNotebook], current: Notebook? = nil) {
        cancel(); records = []; running = true
        let expected = generation
        worker = Task {
            defer { if generation == expected { running = false } }
            do {
                for document in documents {
                    try Task.checkCancellation()
                    let notebook: Notebook
                    if let current { notebook = current }
                    else {
                        notebook = try await Task.detached(priority: .utility) {
                            try RevisionStore(directory: document.directory).load()
                        }.value
                    }
                    try Task.checkCancellation()
                    let catalog = try NotebookPDFCatalog(notebook)
                    for (index, page) in notebook.pages.enumerated() {
                        try Task.checkCancellation()
                        status = "\(document.title) · Seite \(index + 1)/\(notebook.pages.count)"
                        let pdf = catalog.sourcePage(for: page)
                        let layout = try PageLayout(page: page, source: pdf?.pageRef)
                        for box in page.effectiveTextBoxes where !box.text.isEmpty {
                            var start = box.text.startIndex
                            while start < box.text.endIndex {
                                let end = box.text.index(start, offsetBy: 2_000, limitedBy: box.text.endIndex) ?? box.text.endIndex
                                append(document, page, index, String(box.text[start..<end]), .text, box.rect)
                                if end == box.text.endIndex { break }
                                start = box.text.index(end, offsetBy: -160)
                            }
                        }
                        if let pdf, let selection = pdf.selection(for: pdf.bounds(for: .cropBox)) {
                            for line in selection.selectionsByLine() {
                                guard let text = line.string, !text.isEmpty else { continue }
                                let canvas = line.bounds(for: pdf).applying(layout.pdfToCanvas.cgTransform)
                                    .offsetBy(dx: -layout.contentOrigin.x, dy: -layout.contentOrigin.y)
                                append(document, page, index, text, .pdf, PageRect(canvas))
                            }
                        }
                        if pdf != nil || !(page.images ?? []).isEmpty {
                            let bytes = try raster(page: page, source: pdf?.pageRef, layout: layout, ink: false)
                            let lines = try await Self.recognize(bytes)
                            try Task.checkCancellation()
                            for line in lines { append(document, page, index, line.text, .image, canonical(line.bounds, layout)) }
                        }
                        if !page.drawing.isEmpty {
                            let bytes = try raster(page: page, source: nil, layout: layout, ink: true)
                            let lines = try await Self.recognize(bytes)
                            try Task.checkCancellation()
                            for line in lines { append(document, page, index, line.text, .handwriting, canonical(line.bounds, layout)) }
                        }
                        await Task.yield()
                    }
                }
                status = "\(records.count) Textstellen erfasst\(records.count >= 50_000 ? " · Grenze 50.000 erreicht" : "") · lokal, Deutsch/Englisch"
            } catch is CancellationError { if generation == expected { status = "Suche angehalten · bisherige Treffer bleiben sichtbar" } }
            catch { if generation == expected { self.error = error.localizedDescription; status = "Suche unvollständig · bisherige Treffer sichtbar" } }
        }
    }
    private func append(_ doc: OpenNotebook, _ page: Page, _ index: Int, _ text: String, _ kind: SearchContentKind, _ rect: PageRect) {
        guard records.count < 50_000 else { return }
        // OCR of a text PDF can overlap its exact text layer. Prefer the exact layer.
        if kind == .image, records.suffix(300).contains(where: { $0.pageID == page.id && $0.kind == .pdf && $0.text == text }) { return }
        records.append(ContentSearchHit(documentID: doc.id, pageID: page.id, pageNumber: index + 1,
            title: doc.title, text: text, kind: kind, bounds: rect))
    }
    private func canonical(_ rect: PageRect, _ layout: PageLayout) -> PageRect {
        .init(x: rect.x * layout.canvas.width - layout.contentOrigin.x,
              y: (1 - rect.y - rect.height) * layout.canvas.height - layout.contentOrigin.y,
              width: rect.width * layout.canvas.width, height: rect.height * layout.canvas.height)
    }
    private func raster(page: Page, source: CGPDFPage?, layout: PageLayout, ink: Bool) throws -> Data {
        let scale = min(2, 2400 / max(layout.canvas.width, layout.canvas.height))
        let format = UIGraphicsImageRendererFormat(); format.scale = scale; format.opaque = true
        var failure: Error?
        let result = UIGraphicsImageRenderer(size: layout.canvas.cgSize, format: format).pngData { output in
            let context = output.cgContext
            UIColor.white.setFill(); context.fill(layout.canvas.bounds)
            if ink {
                if let drawing = try? PKDrawing(data: page.drawing) {
                    // Normalize ink color for OCR, retaining every original stroke in storage.
                    let strokes = drawing.strokes.map { stroke in
                        PKStroke(ink: PKInk(.pen, color: .black), path: stroke.path, transform: stroke.transform, mask: stroke.mask)
                    }
                    PKDrawing(strokes: strokes).image(from: layout.canonicalInkBounds, scale: scale).draw(in: layout.canvas.bounds)
                }
            } else {
                if let source {
                    context.saveGState(); context.clip(to: layout.sourceFrame.cgRect)
                    context.concatenate(layout.pdfToCanvas.cgTransform); context.drawPDFPage(source); context.restoreGState()
                }
                for image in page.images ?? [] {
                    do { try ImageRendering.draw(image, context: context, origin: layout.contentOrigin, limit: 2400) }
                    catch { failure = error }
                }
            }
        }
        if let failure { throw failure }; return result
    }
    nonisolated private static func recognize(_ bytes: Data) async throws -> [RecognizedLine] {
        try await Task.detached(priority: .utility) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate; request.recognitionLanguages = ["de-DE", "en-US"]
            request.usesLanguageCorrection = true
            try VNImageRequestHandler(data: bytes, options: [:]).perform([request])
            return (request.results ?? []).compactMap { observation in
                guard let candidate = observation.topCandidates(1).first else { return nil }
                return RecognizedLine(text: candidate.string, bounds: PageRect(observation.boundingBox))
            }
        }.value
    }
}

struct ContentSearchView: View {
    let documents: [OpenNotebook]
    var current: Notebook? = nil
    let onSelect: (ContentSearchHit) -> Void
    @StateObject private var model = ContentSearchModel()
    @State private var query = ""
    @Environment(\.dismiss) private var dismiss
    private var hits: [ContentSearchHit] { Array(model.records.lazy.filter { $0.matches(query) }.prefix(300)) }
    var body: some View {
        NavigationStack {
            VStack(alignment: .leading) {
                Text(model.status).font(.caption).padding(.horizontal)
                if model.running { ProgressView().padding(.horizontal) }
                Text("Handschrift und Scan-/Bild-OCR sind lokal. Die Erkennungsqualität muss mit deinen Unterlagen geprüft werden.")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal)
                if let error = model.error { Text(error).foregroundStyle(.red).font(.caption).padding(.horizontal) }
                List(hits) { hit in
                    Button { model.cancel(); onSelect(hit); dismiss() } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(hit.title) · Seite \(hit.pageNumber)").font(.headline)
                            Text(hit.text).lineLimit(3)
                            Text(label(hit.kind)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }.overlay { if !model.running && !query.isEmpty && hits.isEmpty { ContentUnavailableView.search(text: query) } }
            }.searchable(text: $query, prompt: "Inhalt suchen")
                .navigationTitle(current == nil ? "In allen Heften suchen" : "Im Heft suchen")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Schließen") { dismiss() } }
                    ToolbarItem(placement: .primaryAction) {
                        if model.running { Button("Anhalten") { model.cancel() } }
                        else { Button("Neu erfassen") { model.start(documents: documents, current: current) } }
                    }
                }
                .task { model.start(documents: documents, current: current) }
                .onDisappear { model.cancel() }
        }
    }
    private func label(_ kind: SearchContentKind) -> String {
        switch kind { case .text: "Textfeld"; case .pdf: "PDF-Text"; case .image: "Scan/Bild · OCR"; case .handwriting: "Handschrift · OCR" }
    }
}
