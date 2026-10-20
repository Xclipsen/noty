import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass
import PDFKit
import NotebookCore

/// A text marking resolved for the current section; `id` is the personal item.
struct LawTextMark: Hashable {
    var id: String
    var anchor: LawAnchor
}

/// Shared between the reader and its UITextView: the live selection, the marks
/// under it (or the tapped mark) and the rendered text the range refers to.
/// HTML rendering may differ from the plain section text in non-letters.
@MainActor
final class LawTextSelection: ObservableObject {
    @Published var range = NSRange(location: 0, length: 0)
    @Published var marks: [String] = []
    var text = ""
    weak var view: UITextView?
    var active: Bool { range.length > 0 || !marks.isEmpty }
    func clear() {
        view?.selectedTextRange = nil
        if range.length > 0 { range = NSRange(location: 0, length: 0) }
        if !marks.isEmpty { marks = [] }
    }
}

/// Last read section per law and the last law, so reopening a law, a notebook
/// or the app continues there instead of at the beginning. Display state only.
private enum LawReadingPosition {
    static let sectionsKey = "noty.laws.readingSections"
    static let lastKey = "noty.laws.lastLaw"
    static func section(_ law: String) -> String? {
        (UserDefaults.standard.dictionary(forKey: sectionsKey) as? [String: String])?[law]
    }
    static var lastLaw: String? { UserDefaults.standard.string(forKey: lastKey) }
    static func remember(law: String, section: String) {
        var all = UserDefaults.standard.dictionary(forKey: sectionsKey) as? [String: String] ?? [:]
        guard all[law] != section || lastLaw != law else { return }
        all[law] = section
        UserDefaults.standard.set(all, forKey: sectionsKey)
        UserDefaults.standard.set(law, forKey: lastKey)
    }
}

struct LawReaderView: View {
    @EnvironmentObject private var laws: LawLibraryModel
    @StateObject private var textSelection = LawTextSelection()
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
    private var textMarks: [LawTextMark] {
        guard let section else { return [] }
        return marks.compactMap { item in
            guard item.kind == "annotation", case let .object(a) = item.payload["anchor"], a["sectionId"]?.string == section.id,
                  let start = a["start"]?.int, let end = a["end"]?.int, let quote = a["quote"]?.string else { return nil }
            return LawTextMark(id: item.id, anchor: LawAnchor(sectionId: section.id, start: start, end: end, quote: quote))
        }
    }
    private var bookmarkItem: LawPersonalItem? {
        guard let section else { return nil }
        return marks.first { item in
            item.kind == "bookmark" && item.payload["sectionId"]?.string == section.id
                && item.payload["view"]?.string == (viewPDF ? "pdf" : "text") && (!viewPDF || item.payload["page"]?.int == pdfPage)
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            if loading { ProgressView("Wird geladen …").padding() }
            if !loadError.isEmpty { Text(loadError).font(.caption).foregroundStyle(.orange).padding(8) }
            if let section, let doc = document {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(section.label).font(.headline)
                        Text(section.title).font(.subheadline).lineLimit(2)
                    }
                    Spacer()
                    Button { toggleBookmark() } label: { Image(systemName: bookmarkItem == nil ? "bookmark" : "bookmark.fill").frame(width: 44, height: 44) }
                        .accessibilityLabel(bookmarkItem == nil ? "Fundstelle als Lesezeichen speichern" : "Lesezeichen entfernen")
                }.padding(.leading, 12).padding(.trailing, 4).padding(.vertical, 2)
                if viewPDF, let pdfURL {
                    NativeLawPDF(url: pdfURL, page: pdfTarget ?? section.pdf?.page ?? 1, top: pdfTarget == nil ? (section.pdf?.top ?? 0) : 0, onPage: { pdfPage = $0 },
                        items: marks.filter { $0.kind == "annotation" }, onMark: { payload in Task { await laws.save(kind: "annotation", payload: payload.merging(basePayload(doc)) { _, new in new }) } })
                        .id(pdfURL)
                } else {
                    NativeLawText(text: section.text, html: section.html, notes: section.notes, sectionID: section.id, fontSize: fontSize,
                        marks: textMarks, paragraph: jumpParagraph, selection: textSelection,
                        onMark: { mark($0) }, onRemove: { unmark($0) })
                        .overlay(alignment: .bottom) { if textSelection.active { selectionBar } }
                }
                footer(doc, section: section)
            } else if !loading {
                ContentUnavailableView(laws.entries.isEmpty ? "Noch keine Gesetze geladen" : "Gesetz auswählen", systemImage: "books.vertical", description: Text(laws.entries.isEmpty ? "Unter Einstellungen → Gesetzessammlung den Offlinebestand laden." : "Tippe ein Gesetz an oder suche zum Beispiel nach 144 HGB."))
            }
        }
        .background(Color(uiColor: .systemBackground))
        .task { await laws.start(); await openInitial() }
        .onChange(of: laws.entries.count) { _, _ in Task { await openInitial() } }
        .onChange(of: "\(selectedID)|\(sectionID)") { _, _ in
            guard !selectedID.isEmpty, !sectionID.isEmpty else { return }
            LawReadingPosition.remember(law: selectedID, section: sectionID)
        }
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
        .onChange(of: hidden) { _, hidden in if hidden { queryFocused = false; textSelection.clear() } }
        .sheet(isPresented: $showContents) { contents }
        .sheet(isPresented: $showBookmarks) { bookmarks }
    }
    private var controls: some View {
        VStack(spacing: 8) {
            HStack {
                Menu {
                    ForEach(laws.entries) { entry in Button("\(entry.abbr) · \(entry.name)") { Task { await choose(entry) } } }
                } label: { Label(entry?.abbr ?? "Gesetz wählen", systemImage: "books.vertical").lineLimit(1) }
                Spacer()
                Button { showContents = true } label: { Image(systemName: "list.bullet") }.accessibilityLabel("Inhaltsverzeichnis")
                Button { showBookmarks = true } label: { Image(systemName: "bookmark") }.accessibilityLabel("Lesezeichen und Markierungen")
                Menu {
                    if let entry {
                        ForEach(entry.versions) { v in
                            Button(v.status.last ?? v.id) { Task { await open(entry, version: v.id, target: sectionID, resume: true) } }
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
    /// Like the website's selection toolbar: mark, remove touched marks, dismiss.
    private var selectionBar: some View {
        HStack(spacing: 8) {
            if textSelection.range.length > 0 {
                Button("Markieren", systemImage: "highlighter") { mark(textSelection.range) }.buttonStyle(.borderedProminent)
            }
            if !textSelection.marks.isEmpty {
                Button(textSelection.marks.count == 1 ? "Markierung entfernen" : "Markierungen entfernen", systemImage: "eraser", role: .destructive) {
                    unmark(textSelection.marks)
                }.buttonStyle(.bordered)
            }
            Button { textSelection.clear() } label: { Image(systemName: "xmark") }.buttonStyle(.bordered).accessibilityLabel("Auswahl aufheben")
        }
        .padding(8).background(.regularMaterial, in: Capsule()).padding(.bottom, 10)
    }
    private func basePayload(_ doc: LawDocument) -> [String: LawJSON] { ["lawId": .string(doc.id), "versionId": .string(doc.version)] }
    /// Website-style pagination with the neighbouring labels as large targets;
    /// the version note and source sit above it instead of between the arrows.
    private func footer(_ doc: LawDocument, section: LawSection) -> some View {
        let index = doc.sections.firstIndex { $0.id == section.id } ?? 0
        let previous = doc.sections.indices.contains(index - 1) ? doc.sections[index - 1] : nil
        let next = doc.sections.indices.contains(index + 1) ? doc.sections[index + 1] : nil
        return VStack(spacing: 6) {
            HStack(spacing: 6) {
                Text(doc.status.last ?? doc.version).lineLimit(1)
                if doc.version != entry?.currentVersion { Text("Ältere Fassung").foregroundStyle(.orange).fixedSize() }
                if let source = URL(string: doc.sourceUrl), source.scheme == "https" { Link("Quelle", destination: source).fixedSize() }
            }.font(.caption2).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button { move(-1) } label: {
                    Label(previous?.label ?? "Anfang", systemImage: "chevron.left").lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                }
                .disabled(previous == nil)
                .accessibilityLabel(previous.map { "Vorherige Vorschrift: \($0.label)" } ?? "Keine vorherige Vorschrift")
                Text("\(index + 1) / \(doc.sections.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).fixedSize()
                Button { move(1) } label: {
                    HStack(spacing: 6) { Text(next?.label ?? "Ende").lineLimit(1); Image(systemName: "chevron.right") }
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .disabled(next == nil)
                .accessibilityLabel(next.map { "Nächste Vorschrift: \($0.label)" } ?? "Keine nächste Vorschrift")
            }
            .buttonStyle(.bordered)
        }.padding(.horizontal, 10).padding(.vertical, 8)
    }
    private func move(_ direction: Int) {
        guard let sections = document?.sections, let i = sections.firstIndex(where: { $0.id == sectionID }), sections.indices.contains(i + direction) else { return }
        textSelection.clear()
        pdfTarget = nil; sectionID = sections[i + direction].id; jumpParagraph = nil; loadError = ""
    }
    private func toggleBookmark() {
        if let existing = bookmarkItem { Task { await laws.remove(existing) }; return }
        guard let doc = document, let section else { return }
        var payload = basePayload(doc)
        payload["sectionId"] = .string(section.id); payload["view"] = .string(viewPDF ? "pdf" : "text")
        if viewPDF { payload["page"] = .number(Double(pdfPage)) }
        payload["label"] = .string(viewPDF ? "\(doc.abbr) · PDF-Seite \(pdfPage)" : "\(doc.abbr) · \(section.label) \(section.title)")
        Task { await laws.save(kind: "bookmark", payload: payload) }
    }
    /// Marks the given range of the rendered section text (selection, edit menu
    /// or Pencil stroke). Pure punctuation/whitespace strokes are ignored.
    private func mark(_ range: NSRange) {
        guard let doc = document, let section else { return }
        let text = textSelection.text as NSString
        guard range.location >= 0, NSMaxRange(range) <= text.length,
              !LawTextAnchor.canonical(text.substring(with: range)).isEmpty else { textSelection.clear(); return }
        guard let anchor = LawTextAnchor.anchor(text: textSelection.text, range: range, sectionID: section.id),
              let data = try? JSONEncoder().encode(anchor), let value = try? JSONDecoder().decode(LawJSON.self, from: data) else {
            loadError = "Diese Auswahl lässt sich nicht eindeutig zuordnen."; return
        }
        guard (anchor.quote as NSString).length <= 4000 else { loadError = "Bitte wähle eine kürzere Textstelle aus."; return }
        var payload = basePayload(doc); payload["kind"] = .string("text"); payload["page"] = .number(0); payload["anchor"] = value
        loadError = ""
        textSelection.clear()
        Task { await laws.save(kind: "annotation", payload: payload) }
    }
    private func unmark(_ ids: [String]) {
        let doomed = laws.items.filter { ids.contains($0.id) && !$0.deleted }
        textSelection.clear()
        Task { for item in doomed { await laws.remove(item) } }
    }
    /// Opens the law and section the reader showed last (or the first law).
    private func openInitial() async {
        guard selectedID.isEmpty, !loading,
              let entry = laws.entries.first(where: { $0.id == LawReadingPosition.lastLaw }) ?? laws.entries.first else { return }
        await open(entry, target: LawReadingPosition.section(entry.id), resume: true)
    }
    /// Picking the current law keeps the reading position; another law continues
    /// at its last read section instead of jumping to the beginning.
    private func choose(_ entry: LawEntry) async {
        guard entry.id != selectedID else { return }
        await open(entry, target: LawReadingPosition.section(entry.id), resume: true)
    }
    /// `resume`: a remembered target that no longer exists opens the beginning
    /// silently instead of reporting a missing citation.
    private func open(_ entry: LawEntry, version: String? = nil, target: String? = nil, paragraph: String? = nil, resume: Bool = false) async {
        let request = UUID(); requestID = request
        loading = true; loadError = ""
        defer { if requestID == request { loading = false } }
        do {
            let doc = try await laws.document(entry, version: version)
            guard !Task.isCancelled, requestID == request else { return }
            let found = target.flatMap { key in doc.sections.first { $0.id == key || $0.keys.contains(key) } }
            if target != nil && found == nil && !resume { loadError = "Diese Fundstelle ist in dieser Fassung nicht vorhanden."; return }
            textSelection.clear()
            selectedID = entry.id; versionID = doc.version; document = doc
            sectionID = found?.id ?? doc.sections.first?.id ?? ""; jumpParagraph = paragraph
            pdfURL = nil; viewPDF = false; pdfTarget = nil
        } catch { if requestID == request { loadError = error.localizedDescription } }
    }
    private func search(_ value: String, allowFullText: Bool = false) async {
        if let target = LawQuickTarget.parse(value, entries: laws.entries), let entry = laws.entries.first(where: { $0.id == target.lawID }) {
            await open(entry, target: target.reference.key, paragraph: target.reference.paragraph)
        } else if let ref = LawReference.parse(value), let entry {
            if let doc = document, let s = doc.sections.first(where: { $0.keys.contains(ref.key) }) {
                textSelection.clear()
                pdfTarget = nil; sectionID = s.id; jumpParagraph = ref.paragraph; loadError = ""
            } else { await open(entry, version: document?.version, target: ref.key, paragraph: ref.paragraph) }
        } else if allowFullText, let doc = document, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let term = value.lowercased()
            if let found = doc.sections.first(where: { ("\($0.label) \($0.title) \($0.text) \($0.notes)").lowercased().contains(term) }) {
                textSelection.clear()
                sectionID = found.id; jumpParagraph = nil; loadError = ""
            }
        }
    }
    private func togglePDF() async {
        guard let entry, let doc = document else { return }
        if viewPDF { viewPDF = false; pdfTarget = pdfPage; return }
        guard section?.pdf != nil || pdfTarget != nil else { loadError = "Keine eindeutig zugeordnete PDF-Fundstelle; der Lesetext bleibt geöffnet."; return }
        let id = requestID
        do { let url = try await laws.pdf(entry, version: doc.version); guard requestID == id else { return }; textSelection.clear(); pdfURL = url; viewPDF = true; loadError = "" }
        catch { loadError = error.localizedDescription }
    }
    private var contents: some View {
        NavigationStack {
            List(document?.sections ?? []) { s in
                Button { textSelection.clear(); pdfTarget = nil; sectionID = s.id; jumpParagraph = nil; showContents = false } label: {
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

/// Pencil-only pan that remembers where the stroke really began: a pan reports
/// only after its movement threshold.
private final class LawPencilPan: UIPanGestureRecognizer {
    private(set) var startLocation: CGPoint?
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if startLocation == nil { startLocation = touches.first?.location(in: view) }
        super.touchesBegan(touches, with: event)
    }
    override func reset() {
        super.reset()
        startLocation = nil
    }
}

private var lawTouchTypesWithoutPencil: [NSNumber] { [UITouch.TouchType.direct, .indirect, .indirectPointer].map { NSNumber(value: $0.rawValue) } }

private struct NativeLawText: UIViewRepresentable {
    var text: String
    var html: String?
    var notes: String
    var sectionID: String
    var fontSize: Double
    var marks: [LawTextMark]
    var paragraph: String?
    var selection: LawTextSelection
    var onMark: (NSRange) -> Void
    var onRemove: ([String]) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UITextView {
        let v = UITextView(); v.isEditable = false; v.isSelectable = true; v.backgroundColor = .systemBackground
        // Bottom room for the floating selection bar.
        v.textContainerInset = UIEdgeInsets(top: 8, left: 12, bottom: 72, right: 12); v.delegate = context.coordinator
        v.scrollsToTop = false
        // Apple Pencil marks like a highlighter; fingers keep scrolling and selecting.
        v.panGestureRecognizer.allowedTouchTypes = lawTouchTypesWithoutPencil
        let pen = LawPencilPan(target: context.coordinator, action: #selector(Coordinator.pencil(_:)))
        pen.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        pen.maximumNumberOfTouches = 1
        v.addGestureRecognizer(pen)
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
        tap.delegate = context.coordinator
        v.addGestureRecognizer(tap)
        context.coordinator.view = v
        return v
    }
    func updateUIView(_ v: UITextView, context: Context) {
        let c = context.coordinator
        c.parent = self
        selection.view = v
        let bodyKey = "\(sectionID):\(fontSize):\(text.hashValue):\(html.hashValue):\(notes.hashValue)"
        if c.bodyKey != bodyKey {
            let changedSection = c.sectionID != sectionID
            let offset = v.contentOffset
            let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: fontSize), .foregroundColor: UIColor.label]
            var body = NSMutableAttributedString(string: text, attributes: attributes)
            // Rich native HTML supports tables/lists. Only use it if its exact
            // canonical text matches the shared anchor contract; otherwise plain
            // source text is authoritative. Never fetch remote HTML resources.
            if let html, !html.isEmpty, html.utf8.count <= 250_000,
               html.range(of: "<(?:script|iframe|img|link|object|style)|(?:src|href)\\s*=", options: [.regularExpression, .caseInsensitive]) == nil {
                let markup = "<html><head><meta charset='utf-8'><style>body{font-family:-apple-system;font-size:\(fontSize)px;color:#eeeeee}table{border-collapse:collapse}td,th{border:1px solid #666;padding:4px}</style></head><body>" + html + "</body></html>"
                if let data = markup.data(using: .utf8),
                   let rich = try? NSMutableAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil),
                   LawTextAnchor.canonical(rich.string) == LawTextAnchor.canonical(text) { body = rich }
            }
            let rendered = body.string
            if !notes.isEmpty { body.append(NSAttributedString(string: "\n\n" + notes, attributes: attributes)) }
            c.renderedText = rendered; c.bodyLength = (rendered as NSString).length
            selection.text = rendered
            c.updating = true
            v.attributedText = body
            if changedSection { v.setContentOffset(.zero, animated: false) } else {
                v.layoutIfNeeded()
                v.setContentOffset(CGPoint(x: 0, y: min(offset.y, max(0, v.contentSize.height - v.bounds.height))), animated: false)
            }
            c.updating = false
            c.bodyKey = bodyKey; c.sectionID = sectionID; c.marksKey = nil
        }
        // Marks only change attributes in place: no new text, no scroll jump.
        if c.marksKey != marks.hashValue {
            c.marksKey = marks.hashValue
            let ranges = LawTextAnchor.originalRanges(text: c.renderedText, anchors: marks.map(\.anchor))
            c.markRanges = zip(marks, ranges).compactMap { mark, range in range.map { (mark.id, $0) } }
            c.applyHighlights(preview: nil)
        }
        let jump = "\(sectionID):\(paragraph ?? "")"
        if c.jump != jump {
            c.jump = jump
            if let paragraph {
                let r = (c.renderedText as NSString).range(of: "(\(paragraph))")
                if r.location != NSNotFound { v.scrollRangeToVisible(r) }
            }
        }
    }
    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate {
        var parent: NativeLawText
        weak var view: UITextView?
        var bodyKey = "", sectionID = "", jump = ""
        var marksKey: Int?
        var updating = false
        var renderedText = ""
        var bodyLength = 0
        var markRanges: [(id: String, range: NSRange)] = []
        private var strokeStart: Int?
        init(_ parent: NativeLawText) { self.parent = parent }

        func applyHighlights(preview: NSRange?) {
            guard let storage = view?.textStorage else { return }
            let body = NSRange(location: 0, length: min(bodyLength, storage.length))
            storage.beginEditing()
            storage.removeAttribute(.backgroundColor, range: body)
            for mark in markRanges where NSMaxRange(mark.range) <= body.length {
                storage.addAttribute(.backgroundColor, value: UIColor.systemYellow.withAlphaComponent(0.4), range: mark.range)
            }
            if let preview, NSMaxRange(preview) <= body.length {
                storage.addAttribute(.backgroundColor, value: UIColor.systemYellow.withAlphaComponent(0.6), range: preview)
            }
            storage.endEditing()
        }
        private func marks(in range: NSRange) -> [String] {
            markRanges.filter { NSIntersectionRange($0.range, range).length > 0 }.map(\.id)
        }
        /// Caret offset nearest to `point`, limited to the section text (not notes).
        private func caret(at point: CGPoint) -> Int {
            guard let v = view, let position = v.closestPosition(to: point) else { return 0 }
            return min(max(0, v.offset(from: v.beginningOfDocument, to: position)), bodyLength)
        }
        func textViewDidChangeSelection(_ textView: UITextView) {
            guard !updating else { return }
            let range = NSIntersectionRange(textView.selectedRange, NSRange(location: 0, length: bodyLength)), id = parent.sectionID
            let hit = range.length > 0 ? marks(in: range) : nil
            // Published state must not change during the SwiftUI update pass.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.parent.sectionID == id else { return }
                let selection = self.parent.selection
                selection.range = range.length > 0 ? range : NSRange(location: 0, length: 0)
                if let hit { selection.marks = hit }
            }
        }
        func textView(_ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
            let clipped = NSIntersectionRange(range, NSRange(location: 0, length: bodyLength))
            guard clipped.length > 0 else { return nil }
            var actions: [UIMenuElement] = [UIAction(title: "Markieren", image: UIImage(systemName: "highlighter")) { [weak self] _ in self?.parent.onMark(clipped) }]
            let hit = marks(in: clipped)
            if !hit.isEmpty {
                actions.append(UIAction(title: hit.count == 1 ? "Markierung entfernen" : "Markierungen entfernen", image: UIImage(systemName: "eraser"), attributes: .destructive) { [weak self] _ in
                    self?.parent.onRemove(hit)
                })
            }
            return UIMenu(children: actions + suggestedActions)
        }
        /// A tap on a highlight offers to remove it; a tap elsewhere dismisses that.
        @objc func tapped(_ gesture: UITapGestureRecognizer) {
            guard let v = view, gesture.state == .ended else { return }
            let point = gesture.location(in: v)
            var hit: [String] = []
            if let character = v.characterRange(at: point) {
                let index = v.offset(from: v.beginningOfDocument, to: character.start)
                hit = markRanges.filter { NSLocationInRange(index, $0.range) }.map(\.id)
            }
            let selection = parent.selection, id = parent.sectionID
            // After the text view has handled the same tap (it may clear a selection).
            DispatchQueue.main.async { [weak self] in
                guard let self, self.parent.sectionID == id, (self.view?.selectedRange.length ?? 0) == 0 else { return }
                selection.marks = hit
            }
        }
        @objc func pencil(_ gesture: LawPencilPan) {
            guard let v = view else { return }
            switch gesture.state {
            case .began:
                strokeStart = caret(at: gesture.startLocation ?? gesture.location(in: v))
                applyHighlights(preview: stroke(to: gesture.location(in: v)))
            case .changed:
                applyHighlights(preview: stroke(to: gesture.location(in: v)))
            case .ended:
                let range = stroke(to: gesture.location(in: v))
                strokeStart = nil
                applyHighlights(preview: nil)
                if let range { parent.onMark(range) }
            default:
                strokeStart = nil
                applyHighlights(preview: nil)
            }
        }
        private func stroke(to point: CGPoint) -> NSRange? {
            guard let start = strokeStart else { return nil }
            let end = caret(at: point)
            return end == start ? nil : NSRange(location: min(start, end), length: abs(end - start))
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
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
        let c = context.coordinator
        let v = PDFView(); v.autoScales = true; v.displayMode = .singlePageContinuous; v.displayDirection = .vertical
        v.document = PDFDocument(url: url)
        NotificationCenter.default.addObserver(c, selector: #selector(Coordinator.pageChanged), name: .PDFViewPageChanged, object: v)
        NotificationCenter.default.addObserver(c, selector: #selector(Coordinator.selectionChanged), name: .PDFViewSelectionChanged, object: v)
        // Pencil strokes are previewed here; the overlay itself takes no touches.
        let ink = LawPDFInkOverlay()
        ink.pdf = v; ink.isUserInteractionEnabled = false; ink.backgroundColor = .clear
        v.addSubview(ink); ink.translatesAutoresizingMaskIntoConstraints = false
        var button = UIButton.Configuration.borderedProminent()
        button.title = "Markieren"; button.image = UIImage(systemName: "highlighter"); button.imagePadding = 6
        let mark = UIButton(configuration: button, primaryAction: UIAction { [weak c] _ in c?.markSelection() })
        mark.isHidden = true
        v.addSubview(mark); mark.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            ink.leadingAnchor.constraint(equalTo: v.leadingAnchor), ink.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            ink.topAnchor.constraint(equalTo: v.topAnchor), ink.bottomAnchor.constraint(equalTo: v.bottomAnchor),
            mark.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -12), mark.bottomAnchor.constraint(equalTo: v.safeAreaLayoutGuide.bottomAnchor, constant: -12),
        ])
        let pen = LawPencilPan(target: c, action: #selector(Coordinator.pencil(_:)))
        pen.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        pen.maximumNumberOfTouches = 1
        v.addGestureRecognizer(pen)
        c.view = v; c.ink = ink; c.markButton = mark
        return v
    }
    func updateUIView(_ v: PDFView, context: Context) {
        let c = context.coordinator
        c.parent = self
        // PDFKit builds its scroll view lazily: Pencil marks, fingers scroll.
        c.keepPencilForMarking(in: v)
        let destination = "\(page):\(top)"
        if c.destination != destination {
            c.destination = destination
            if let p = v.document?.page(at: max(0, page - 1)) {
                let bounds = p.bounds(for: .cropBox)
                v.go(to: PDFDestination(page: p, at: CGPoint(x: bounds.minX, y: bounds.maxY - bounds.height * max(0, min(1, top)))))
            }
        }
        guard c.items != items, let doc = v.document else { return }
        c.items = items
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
        weak var ink: LawPDFInkOverlay?
        weak var markButton: UIButton?
        var destination = ""
        var items: [LawPersonalItem] = []
        init(_ parent: NativeLawPDF) { self.parent = parent }
        func keepPencilForMarking(in root: UIView) {
            for sub in root.subviews {
                if let scroll = sub as? UIScrollView, scroll.panGestureRecognizer.allowedTouchTypes != lawTouchTypesWithoutPencil {
                    scroll.panGestureRecognizer.allowedTouchTypes = lawTouchTypesWithoutPencil
                }
                keepPencilForMarking(in: sub)
            }
        }
        @objc func pageChanged() {
            guard let v = view, let doc = v.document, let page = v.currentPage else { return }
            keepPencilForMarking(in: v)
            let n = doc.index(for: page) + 1
            DispatchQueue.main.async { [weak self] in self?.parent.onPage(n) }
        }
        @objc func selectionChanged() {
            let empty = view?.currentSelection?.string?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
            markButton?.isHidden = empty
        }
        func markSelection() {
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
            markButton?.isHidden = true
        }
        @objc func pencil(_ gesture: LawPencilPan) {
            guard let v = view, let ink else { return }
            switch gesture.state {
            case .began:
                ink.begin(at: gesture.startLocation ?? gesture.location(in: v))
                ink.extend(to: gesture.location(in: v))
            case .changed:
                ink.extend(to: gesture.location(in: v))
            case .ended:
                ink.extend(to: gesture.location(in: v))
                if let payload = ink.finish() { parent.onMark(payload) }
            default:
                ink.cancel()
            }
        }
    }
}

/// Live preview of a Pencil stroke over the PDF, in the PDF view's coordinates.
/// The source PDF is never saved with the derived annotations.
@MainActor
private final class LawPDFInkOverlay: UIView {
    weak var pdf: PDFView?
    private weak var page: PDFPage?
    private var points: [LawJSON] = []
    private let preview = CAShapeLayer()
    private var path = UIBezierPath()
    override init(frame: CGRect) {
        super.init(frame: frame)
        preview.strokeColor = UIColor.systemYellow.withAlphaComponent(0.45).cgColor
        preview.fillColor = UIColor.clear.cgColor; preview.lineCap = .round; preview.lineJoin = .round
        layer.addSublayer(preview)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func begin(at point: CGPoint) {
        guard let pdf else { return }
        page = pdf.page(for: point, nearest: false); points = []; path = UIBezierPath()
        if let page { preview.lineWidth = max(2, pdf.convert(page.bounds(for: .cropBox), from: page).width * 0.018) }
        extend(to: point)
    }
    func extend(to point: CGPoint) {
        guard points.count < 1500, let pdf, let page else { return }
        let p = pdf.convert(point, to: page), bounds = page.bounds(for: .cropBox)
        guard bounds.width > 0, bounds.height > 0, bounds.contains(p) else { return }
        points.append(.array([.number((p.x - bounds.minX) / bounds.width), .number((bounds.maxY - p.y) / bounds.height)]))
        let local = convert(point, from: pdf)
        if path.isEmpty { path.move(to: local) } else { path.addLine(to: local) }
        preview.path = path.cgPath
    }
    func finish() -> [String: LawJSON]? {
        defer { cancel() }
        guard let page, let doc = pdf?.document, points.count >= 2 else { return nil }
        return ["kind": .string("pdf"), "page": .number(Double(doc.index(for: page) + 1)), "points": .array(points)]
    }
    func cancel() { points = []; page = nil; preview.path = nil }
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
