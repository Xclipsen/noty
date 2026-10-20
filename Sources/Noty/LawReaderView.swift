import SwiftUI
import UIKit
import PDFKit
import NotebookCore

struct LawReaderView: View {
    @EnvironmentObject private var laws: LawLibraryModel
    @State private var query = ""
    @State private var number = ""
    @State private var letters = false
    @State private var selectedID = ""
    @State private var versionID = ""
    @State private var document: LawDocument?
    @State private var sectionID = ""
    @State private var pdfURL: URL?
    @State private var viewPDF = false
    @State private var pdfPage = 1
    @State private var pdfTarget: Int?
    @State private var selectionText = ""
    @State private var selection = NSRange(location: 0, length: 0)
    @State private var loadError = ""
    @State private var loading = false
    @State private var showContents = false
    @State private var showBookmarks = false
    @State private var fontSize = 18.0
    @State private var jumpParagraph: String?
    @State private var requestID = UUID()
    @FocusState private var queryFocused: Bool
    /// Closed or stashed at the screen edge: no hidden field may keep the keyboard.
    private var hidden: Bool { !laws.panelOpen || laws.stashed }
    private var entry: LawEntry? { laws.entries.first { $0.id == selectedID } }
    private var section: LawSection? { document?.sections.first { $0.id == sectionID } }
    private var marks: [LawPersonalItem] {
        laws.items.filter { !$0.deleted && $0.payload["lawId"]?.string == selectedID && $0.payload["versionId"]?.string == document?.version }
    }
    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            if loading { ProgressView("Wird geladen …").padding() }
            if !loadError.isEmpty { Text(loadError).font(.caption).foregroundStyle(.orange).padding(8) }
            if let section, let doc = document {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(section.label).font(.headline)
                        Text(section.title).font(.subheadline).lineLimit(2)
                    }
                    Spacer()
                    Button { bookmark() } label: { Image(systemName: "bookmark") }.accessibilityLabel("Fundstelle als Lesezeichen speichern")
                }.padding(12)
                if viewPDF, let pdfURL {
                    NativeLawPDF(url: pdfURL, page: pdfTarget ?? section.pdf?.page ?? 1, top: pdfTarget == nil ? (section.pdf?.top ?? 0) : 0, onPage: { pdfPage = $0 },
                        items: marks.filter { $0.kind == "annotation" }, onMark: { payload in Task { await laws.save(kind: "annotation", payload: payload.merging(basePayload(doc)) { _, new in new }) } })
                        .id(pdfURL)
                } else {
                    NativeLawText(text: section.text, html: section.html, notes: section.notes, sectionID: section.id, fontSize: fontSize,
                        anchors: marks.compactMap { item in
                            guard item.kind == "annotation", case let .object(a) = item.payload["anchor"], a["sectionId"]?.string == section.id,
                                  let start = a["start"]?.int, let end = a["end"]?.int, let quote = a["quote"]?.string else { return nil }
                            return LawAnchor(sectionId: section.id, start: start, end: end, quote: quote)
                        }, paragraph: jumpParagraph, selection: $selection, selectionText: $selectionText)
                        .overlay(alignment: .bottomTrailing) {
                            if selection.length > 0 {
                                Button("Markieren", systemImage: "highlighter") {
                                    guard let anchor = LawTextAnchor.anchor(text: selectionText.isEmpty ? section.text : selectionText, range: selection, sectionID: section.id),
                                          let data = try? JSONEncoder().encode(anchor), let value = try? JSONDecoder().decode(LawJSON.self, from: data) else { return }
                                    var payload = basePayload(doc); payload["kind"] = .string("text"); payload["page"] = .number(0); payload["anchor"] = value
                                    Task { await laws.save(kind: "annotation", payload: payload) }
                                    selection = NSRange(location: 0, length: 0)
                                }.buttonStyle(.borderedProminent).padding(12)
                            }
                        }
                }
                if !viewPDF, let note = doc.textNote { Text(note).font(.caption2).foregroundStyle(.secondary).lineLimit(3).padding(8) }
                footer(doc, section: section)
            } else if !loading {
                ContentUnavailableView(laws.entries.isEmpty ? "Noch keine Gesetze geladen" : "Gesetz auswählen", systemImage: "books.vertical", description: Text(laws.entries.isEmpty ? "Unter Einstellungen → Gesetzessammlung den Offlinebestand laden." : "Tippe ein Gesetz an oder suche zum Beispiel nach 144 HGB."))
            }
        }
        .background(Color(uiColor: .systemBackground))
        .task { await laws.start(); if selectedID.isEmpty, let first = laws.entries.first { await open(first) } }
        .task(id: query) {
            guard !query.isEmpty else { return }
            do { try await Task.sleep(for: .milliseconds(450)) } catch { return }
            await search(query)
        }
        .task(id: number) {
            guard !number.isEmpty else { return }
            do { try await Task.sleep(for: .milliseconds(450)) } catch { return }
            await search(number)
        }
        .onChange(of: hidden) { _, hidden in if hidden { queryFocused = false } }
        .sheet(isPresented: $showContents) { contents }
        .sheet(isPresented: $showBookmarks) { bookmarks }
    }
    private var controls: some View {
        VStack(spacing: 8) {
            HStack {
                Menu {
                    ForEach(laws.entries) { entry in Button("\(entry.abbr) · \(entry.name)") { Task { await open(entry) } } }
                } label: { Label(entry?.abbr ?? "Gesetz wählen", systemImage: "books.vertical").lineLimit(1) }
                Spacer()
                Button { showContents = true } label: { Image(systemName: "list.bullet") }.accessibilityLabel("Inhaltsverzeichnis")
                Button { showBookmarks = true } label: { Image(systemName: "bookmark") }.accessibilityLabel("Lesezeichen und Markierungen")
                Menu {
                    if let entry {
                        ForEach(entry.versions) { v in
                            Button(v.status.last ?? v.id) { Task { await open(entry, version: v.id) } }
                        }
                    }
                    Divider()
                    if let last = marks.last(where: { $0.kind == "annotation" }) {
                        Button("Letzte Markierung rückgängig", systemImage: "arrow.uturn.backward") { Task { await laws.remove(last) } }
                    }
                    Button("Schrift größer", systemImage: "textformat.size.larger") { fontSize = min(32, fontSize + 2) }
                    Button("Schrift kleiner", systemImage: "textformat.size.smaller") { fontSize = max(12, fontSize - 2) }
                } label: { Image(systemName: "ellipsis") }.accessibilityLabel("Fassung und Schrift")
            }
            HStack {
                TextField("Schnellsuche · 144 HGB", text: $query).textInputAutocapitalization(.never).autocorrectionDisabled().submitLabel(.search)
                    .focused($queryFocused)
                    .onSubmit { Task { await search(query, allowFullText: true) } }
                if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }.accessibilityLabel("Suche leeren") }
            }.padding(8).background(.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            HStack {
                LawParagraphField(placeholder: entry?.kind == "administration" ? "Abschnitt / R" : "Paragraph", text: $number, letters: letters, active: !hidden) {
                    Task { await search(number, allowFullText: true) }
                }
                // A UITextField otherwise takes all offered height and pushes
                // the law text down (empty box under the quick search).
                .fixedSize(horizontal: false, vertical: true).frame(minHeight: 32)
                Button(letters ? "123" : "abc / Abs.") { letters.toggle() }.font(.caption)
                    .accessibilityLabel("Zwischen Zahlen- und Texttastatur wechseln")
                Button(viewPDF ? "Lesetext" : "PDF") { Task { await togglePDF() } }.disabled(document == nil)
            }.padding(8).background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }.padding(10).buttonStyle(.borderless)
    }
    private func basePayload(_ doc: LawDocument) -> [String: LawJSON] { ["lawId": .string(doc.id), "versionId": .string(doc.version)] }
    private func footer(_ doc: LawDocument, section: LawSection) -> some View {
        HStack {
            Button { move(-1) } label: { Image(systemName: "chevron.left") }.accessibilityLabel("Vorherige Vorschrift")
            Spacer()
            VStack(spacing: 2) {
                Text(doc.status.last ?? doc.version).lineLimit(1)
                if doc.version != entry?.currentVersion { Text("Ältere gespeicherte Fassung").foregroundStyle(.orange) }
                if let source = URL(string: doc.sourceUrl), source.scheme == "https" { Link("Quelle", destination: source) }
            }.font(.caption2)
            Spacer()
            Button { move(1) } label: { Image(systemName: "chevron.right") }.accessibilityLabel("Nächste Vorschrift")
        }.padding(10)
    }
    private func move(_ direction: Int) {
        guard let sections = document?.sections, let i = sections.firstIndex(where: { $0.id == sectionID }), sections.indices.contains(i + direction) else { return }
        pdfTarget = nil; sectionID = sections[i + direction].id; selection = NSRange(location: 0, length: 0); jumpParagraph = nil
    }
    private func bookmark() {
        guard let doc = document, let section else { return }
        var payload = basePayload(doc)
        payload["sectionId"] = .string(section.id); payload["view"] = .string(viewPDF ? "pdf" : "text")
        if viewPDF { payload["page"] = .number(Double(pdfPage)) }
        payload["label"] = .string(viewPDF ? "\(doc.abbr) · PDF-Seite \(pdfPage)" : "\(doc.abbr) · \(section.label) \(section.title)")
        Task { await laws.save(kind: "bookmark", payload: payload) }
    }
    private func open(_ entry: LawEntry, version: String? = nil, target: String? = nil, paragraph: String? = nil) async {
        let request = UUID(); requestID = request
        loading = true; loadError = ""
        defer { if requestID == request { loading = false } }
        do {
            let doc = try await laws.document(entry, version: version)
            guard !Task.isCancelled, requestID == request else { return }
            let found = target.flatMap { key in doc.sections.first { $0.id == key || $0.keys.contains(key) } }
            if target != nil && found == nil { loadError = "Diese Fundstelle ist in dieser Fassung nicht vorhanden."; return }
            selectedID = entry.id; versionID = doc.version; document = doc
            sectionID = found?.id ?? doc.sections.first?.id ?? ""; jumpParagraph = paragraph
            pdfURL = nil; viewPDF = false; pdfTarget = nil; selection = NSRange(location: 0, length: 0)
        } catch { if requestID == request { loadError = error.localizedDescription } }
    }
    private func search(_ value: String, allowFullText: Bool = false) async {
        if let target = LawQuickTarget.parse(value, entries: laws.entries), let entry = laws.entries.first(where: { $0.id == target.lawID }) {
            await open(entry, target: target.reference.key, paragraph: target.reference.paragraph)
        } else if let ref = LawReference.parse(value), let entry {
            if let doc = document, let s = doc.sections.first(where: { $0.keys.contains(ref.key) }) {
                pdfTarget = nil; sectionID = s.id; jumpParagraph = ref.paragraph; loadError = ""; selection = NSRange(location: 0, length: 0)
            } else { await open(entry, version: document?.version, target: ref.key, paragraph: ref.paragraph) }
        } else if allowFullText, let doc = document, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let term = value.lowercased()
            if let found = doc.sections.first(where: { ("\($0.label) \($0.title) \($0.text) \($0.notes)").lowercased().contains(term) }) {
                sectionID = found.id; jumpParagraph = nil; loadError = ""
            }
        }
    }
    private func togglePDF() async {
        guard let entry, let doc = document else { return }
        if viewPDF { viewPDF = false; pdfTarget = pdfPage; return }
        guard section?.pdf != nil || pdfTarget != nil else { loadError = "Keine eindeutig zugeordnete PDF-Fundstelle; der Lesetext bleibt geöffnet."; return }
        let id = requestID
        do { let url = try await laws.pdf(entry, version: doc.version); guard requestID == id else { return }; pdfURL = url; viewPDF = true; loadError = "" }
        catch { loadError = error.localizedDescription }
    }
    private var contents: some View {
        NavigationStack {
            List(document?.sections ?? []) { s in
                Button { pdfTarget = nil; sectionID = s.id; jumpParagraph = nil; selection = NSRange(location: 0, length: 0); showContents = false } label: {
                    VStack(alignment: .leading) { Text(s.label).font(.headline); Text(s.title).font(.caption) }
                }
            }.navigationTitle("Inhaltsverzeichnis")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { showContents = false } } }
        }
    }
    private var bookmarks: some View {
        NavigationStack {
            List(laws.items.filter { !$0.deleted }) { item in
                HStack {
                    Button {
                        guard let id = item.payload["lawId"]?.string, let entry = laws.entries.first(where: { $0.id == id }) else { return }
                        var target = item.payload["sectionId"]?.string
                        if case let .object(a) = item.payload["anchor"] { target = a["sectionId"]?.string }
                        let version = item.payload["versionId"]?.string
                        showBookmarks = false
                        Task {
                            await open(entry, version: version, target: target)
                            if item.payload["view"]?.string == "pdf", let page = item.payload["page"]?.int, let doc = document, doc.id == entry.id, doc.version == version {
                                let request = requestID
                                do { let url = try await laws.pdf(entry, version: doc.version); guard requestID == request else { return }; pdfURL = url; pdfTarget = page; viewPDF = true }
                                catch { loadError = error.localizedDescription }
                            }
                        }
                    } label: {
                        VStack(alignment: .leading) {
                            Text(item.payload["label"]?.string ?? "Markierung · \(item.payload["lawId"]?.string?.uppercased() ?? "")")
                            if case let .object(a) = item.payload["anchor"], let quote = a["quote"]?.string { Text(quote).font(.caption).lineLimit(2).foregroundStyle(.secondary) }
                            if item.dirty { Text("Lokal gespeichert").font(.caption2).foregroundStyle(.secondary) }
                        }
                    }
                    Spacer()
                    Button(role: .destructive) { Task { await laws.remove(item) } } label: { Image(systemName: "trash") }.accessibilityLabel("Eintrag löschen")
                }
            }.navigationTitle("Lesezeichen & Markierungen")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { showBookmarks = false } } }
        }
    }
}

private struct NativeLawText: UIViewRepresentable {
    var text: String
    var html: String?
    var notes: String
    var sectionID: String
    var fontSize: Double
    var anchors: [LawAnchor]
    var paragraph: String?
    @Binding var selection: NSRange
    @Binding var selectionText: String
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UITextView {
        let v = UITextView(); v.isEditable = false; v.isSelectable = true; v.backgroundColor = .systemBackground
        v.textContainerInset = UIEdgeInsets(top: 8, left: 12, bottom: 32, right: 12); v.delegate = context.coordinator
        return v
    }
    func updateUIView(_ v: UITextView, context: Context) {
        context.coordinator.parent = self
        let key = "\(sectionID):\(fontSize):\(text.hashValue):\(html.hashValue):\(anchors.hashValue)"
        if context.coordinator.key != key {
            let changedSection = context.coordinator.sectionID != sectionID
            let selected = v.selectedRange, offset = v.contentOffset
            let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: fontSize), .foregroundColor: UIColor.label]
            let bodyKey = "\(fontSize):\(text.hashValue):\(html.hashValue)"
            var body = (context.coordinator.bodyKey == bodyKey ? context.coordinator.cachedBody?.mutableCopy() as? NSMutableAttributedString : nil) ?? NSMutableAttributedString(string: text, attributes: attributes)
            // Rich native HTML supports tables/lists. Only use it if its exact
            // canonical text matches the shared anchor contract; otherwise plain
            // source text is authoritative. Never fetch remote HTML resources.
            if context.coordinator.bodyKey != bodyKey, let html, !html.isEmpty, html.utf8.count <= 250_000,
               html.range(of: "<(?:script|iframe|img|link|object|style)|(?:src|href)\\s*=", options: [.regularExpression, .caseInsensitive]) == nil {
                let markup = "<html><head><meta charset='utf-8'><style>body{font-family:-apple-system;font-size:\(fontSize)px;color:#eeeeee}table{border-collapse:collapse}td,th{border:1px solid #666;padding:4px}</style></head><body>" + html + "</body></html>"
                if let data = markup.data(using: .utf8),
                   let rich = try? NSMutableAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil),
                   LawTextAnchor.canonical(rich.string) == LawTextAnchor.canonical(text) { body = rich }
            }
            context.coordinator.cachedBody = body.copy() as? NSAttributedString
            context.coordinator.bodyKey = bodyKey
            let displayText = body.string
            context.coordinator.renderedText = displayText
            let attr = body
            if !notes.isEmpty { attr.append(NSAttributedString(string: "\n\n" + notes, attributes: attributes)) }
            for r in LawTextAnchor.originalRanges(text: displayText, anchors: anchors).compactMap({ $0 }) { attr.addAttribute(.backgroundColor, value: UIColor.systemYellow.withAlphaComponent(0.4), range: r) }
            context.coordinator.updating = true; v.attributedText = attr
            if changedSection { v.setContentOffset(.zero, animated: false) } else {
                if selected.location + selected.length <= attr.length { v.selectedRange = selected }
                v.setContentOffset(offset, animated: false)
            }
            context.coordinator.updating = false; context.coordinator.key = key; context.coordinator.sectionID = sectionID
        }
        let jump = "\(sectionID):\(paragraph ?? "")"
        if context.coordinator.jump != jump {
            context.coordinator.jump = jump
            if let paragraph {
                let r = (context.coordinator.renderedText as NSString).range(of: "(\(paragraph))")
                if r.location != NSNotFound { v.scrollRangeToVisible(r) }
            }
        }
    }
    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: NativeLawText
        var key = "", sectionID = "", jump = ""
        var updating = false
        var renderedText = ""
        var bodyKey = ""
        var cachedBody: NSAttributedString?
        init(_ parent: NativeLawText) { self.parent = parent }
        func textViewDidChangeSelection(_ textView: UITextView) {
            guard !updating else { return }
            let range = textView.selectedRange, id = parent.sectionID
            DispatchQueue.main.async { [weak self] in guard let self, self.parent.sectionID == id else { return }; self.parent.selectionText = self.renderedText; self.parent.selection = range }
        }
    }
}

private struct NativeLawPDF: UIViewRepresentable {
    let url: URL
    let page: Int
    let top: Double
    var onPage: (Int) -> Void
    var items: [LawPersonalItem]
    var onMark: ([String: LawJSON]) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> PDFView {
        let v = PDFView(); v.autoScales = true; v.displayMode = .singlePageContinuous; v.displayDirection = .vertical
        v.document = PDFDocument(url: url)
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.pageChanged), name: .PDFViewPageChanged, object: v)
        let button = UIButton(type: .system); button.setTitle("Auswahl markieren", for: .normal)
        button.backgroundColor = .secondarySystemBackground; button.layer.cornerRadius = 10
        button.addTarget(context.coordinator, action: #selector(Coordinator.mark), for: .touchUpInside)
        v.addSubview(button); button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([button.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -12), button.bottomAnchor.constraint(equalTo: v.safeAreaLayoutGuide.bottomAnchor, constant: -12), button.widthAnchor.constraint(equalToConstant: 160), button.heightAnchor.constraint(equalToConstant: 44)])
        let ink = LawPDFInkOverlay()
        ink.backgroundColor = .clear; ink.frame = v.bounds; ink.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        ink.pdf = v; ink.finished = { [weak coordinator = context.coordinator] payload in coordinator?.parent.onMark(payload) }
        v.insertSubview(ink, belowSubview: button)
        context.coordinator.view = v
        return v
    }
    func updateUIView(_ v: PDFView, context: Context) {
        context.coordinator.parent = self
        let destination = "\(page):\(top)"
        if context.coordinator.destination != destination {
            context.coordinator.destination = destination
            if let p = v.document?.page(at: max(0, page - 1)) {
                let bounds = p.bounds(for: .cropBox)
                v.go(to: PDFDestination(page: p, at: CGPoint(x: bounds.minX, y: bounds.maxY - bounds.height * max(0, min(1, top)))))
            }
        }
        guard context.coordinator.items != items, let doc = v.document else { return }
        context.coordinator.items = items
        for index in 0..<doc.pageCount {
            guard let p = doc.page(at: index) else { continue }
            p.annotations.filter { $0.userName == "noty-law" }.forEach { p.removeAnnotation($0) }
            let bounds = p.bounds(for: .cropBox)
            for item in items where item.payload["page"]?.int == index + 1 {
                if case let .array(rects) = item.payload["rectangles"] {
                    for rect in rects {
                        guard case let .object(r) = rect, case let .number(x) = r["x"], case let .number(y) = r["y"], case let .number(w) = r["width"], case let .number(h) = r["height"] else { continue }
                        let a = PDFAnnotation(bounds: CGRect(x: bounds.minX + x * bounds.width, y: bounds.maxY - (y + h) * bounds.height, width: w * bounds.width, height: h * bounds.height), forType: .highlight, withProperties: nil)
                        a.color = UIColor.systemYellow.withAlphaComponent(0.4); a.userName = "noty-law"; p.addAnnotation(a)
                    }
                } else if case let .array(points) = item.payload["points"] {
                    let path = UIBezierPath()
                    for (i, point) in points.enumerated() {
                        guard case let .array(pair) = point, pair.count == 2, case let .number(x) = pair[0], case let .number(y) = pair[1] else { continue }
                        let pos = CGPoint(x: x * bounds.width, y: (1 - y) * bounds.height)
                        if i == 0 { path.move(to: pos) } else { path.addLine(to: pos) }
                    }
                    let a = PDFAnnotation(bounds: bounds, forType: .ink, withProperties: nil)
                    a.add(path); a.color = UIColor.systemYellow.withAlphaComponent(0.4); let border = PDFBorder(); border.lineWidth = bounds.width * 0.018; a.border = border; a.userName = "noty-law"; p.addAnnotation(a)
                }
            }
        }
    }
    @MainActor
    final class Coordinator: NSObject {
        var parent: NativeLawPDF
        weak var view: PDFView?
        var destination = ""
        var items: [LawPersonalItem] = []
        init(_ parent: NativeLawPDF) { self.parent = parent }
        @objc func pageChanged() {
            guard let v = view, let doc = v.document, let page = v.currentPage else { return }
            let n = doc.index(for: page) + 1
            DispatchQueue.main.async { [weak self] in self?.parent.onPage(n) }
        }
        @objc func mark() {
            guard let v = view, let doc = v.document, let selection = v.currentSelection else { return }
            for line in selection.selectionsByLine() {
                for page in line.pages {
                    let bounds = page.bounds(for: .cropBox), r = line.bounds(for: page).intersection(bounds)
                    guard !r.isNull, bounds.width > 0, bounds.height > 0, r.width > 0, r.height > 0 else { continue }
                    let rect: LawJSON = .object(["x": .number((r.minX - bounds.minX) / bounds.width), "y": .number((bounds.maxY - r.maxY) / bounds.height), "width": .number(r.width / bounds.width), "height": .number(r.height / bounds.height)])
                    parent.onMark(["kind": .string("pdf-text"), "page": .number(Double(doc.index(for: page) + 1)), "rectangles": .array([rect])])
                }
            }
            v.clearSelection()
        }
    }
}

/// Only Pencil input is intercepted; fingers/trackpad keep PDFKit selection and
/// scrolling. The source PDF is never saved with these derived annotations.
@MainActor
private final class LawPDFInkOverlay: UIView {
    weak var pdf: PDFView?
    var finished: (([String: LawJSON]) -> Void)?
    private weak var page: PDFPage?
    private var points: [LawJSON] = []
    private let preview = CAShapeLayer()
    private var path = UIBezierPath()
    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = false
        preview.strokeColor = UIColor.systemYellow.withAlphaComponent(0.45).cgColor
        preview.fillColor = UIColor.clear.cgColor; preview.lineCap = .round; preview.lineJoin = .round
        layer.addSublayer(preview)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard bounds.contains(point), event?.allTouches?.contains(where: { $0.type == .pencil }) == true else { return nil }
        return self
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first, let pdf else { return }
        let pos = touch.location(in: pdf)
        page = pdf.page(for: pos, nearest: false); points = []; path = UIBezierPath()
        if let page {
            let b = page.bounds(for: .cropBox)
            let converted = pdf.convert(b, from: page)
            preview.lineWidth = max(2, converted.width * 0.018)
        }
        append(touch, first: true)
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        for sample in event?.coalescedTouches(for: touch) ?? [touch] { append(sample, first: false) }
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        if let touch = touches.first { append(touch, first: false) }
        if let page, let doc = pdf?.document, points.count >= 2 {
            finished?(["kind": .string("pdf"), "page": .number(Double(doc.index(for: page) + 1)), "points": .array(points)])
        }
        clear()
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { clear() }
    private func clear() { points = []; page = nil; preview.path = nil }
    private func append(_ touch: UITouch, first: Bool) {
        guard points.count < 1500, let pdf, let page else { return }
        let point = pdf.convert(touch.location(in: pdf), to: page), bounds = page.bounds(for: .cropBox)
        guard bounds.width > 0, bounds.height > 0, bounds.contains(point) else { return }
        let x = (point.x - bounds.minX) / bounds.width, y = (bounds.maxY - point.y) / bounds.height
        points.append(.array([.number(x), .number(y)]))
        let local = touch.location(in: self)
        if first { path.move(to: local) } else { path.addLine(to: local) }
        preview.path = path.cgPath
    }
}

private struct LawParagraphField: UIViewRepresentable {
    var placeholder: String
    @Binding var text: String
    var letters: Bool
    var active: Bool
    var submit: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UITextField {
        let field = UITextField(); field.delegate = context.coordinator
        field.autocorrectionType = .no; field.autocapitalizationType = .none
        field.returnKeyType = .search
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed), for: .editingChanged)
        let bar = UIToolbar(); bar.sizeToFit()
        bar.items = [UIBarButtonItem(systemItem: .flexibleSpace), UIBarButtonItem(title: "Suchen", style: .done, target: context.coordinator, action: #selector(Coordinator.search))]
        field.inputAccessoryView = bar
        return field
    }
    func updateUIView(_ field: UITextField, context: Context) {
        context.coordinator.parent = self
        field.placeholder = placeholder
        if field.text != text { field.text = text }
        let type: UIKeyboardType = letters ? .default : .numberPad
        if field.keyboardType != type { field.keyboardType = type; if field.isFirstResponder { field.reloadInputViews() } }
        if !active, field.isFirstResponder { field.resignFirstResponder() }
    }
    @MainActor
    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: LawParagraphField
        init(_ parent: LawParagraphField) { self.parent = parent }
        @objc func changed(_ field: UITextField) { parent.text = field.text ?? "" }
        @objc func search() { parent.submit() }
        func textFieldShouldReturn(_ textField: UITextField) -> Bool { parent.submit(); return true }
    }
}
