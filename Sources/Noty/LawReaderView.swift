import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass
import PDFKit
import NotebookCore

/// A text marking resolved for the current section; `id` is the personal item.
struct LawTextMark: Hashable {
    var id: String
    var anchor: LawAnchor
    var color: String?
}

/// What Apple Pencil does in the law reader, taken from the notebook's active
/// tool: the highlighter marks (in its colour, straightened like in the
/// notebook), an eraser removes marks, every other tool leaves Pencil to scroll
/// and select like a finger.
struct LawPenMode: Equatable {
    enum Kind: Hashable { case none, marker, eraser }
    var kind = Kind.none
    var color = InkColor(1, 1, 0)
    /// „Immer gerade“ of the notebook highlighter.
    var straight = false
    /// „Linie nach Halten begradigen“ of the notebook highlighter.
    var holdStraighten = true
    var hex: String { String(format: "#%02X%02X%02X", Int((color.red * 255).rounded()), Int((color.green * 255).rounded()), Int((color.blue * 255).rounded())) }
    static let presets: [(name: String, color: InkColor)] = [
        ("Gelb", InkColor(1, 1, 0)), ("Grün", InkColor(0.35, 0.9, 0.35)), ("Blau", InkColor(0.35, 0.75, 1)),
        ("Rosa", InkColor(1, 0.45, 0.8)), ("Orange", InkColor(1, 0.62, 0.15)),
    ]
}

/// Highlight colour of a stored mark (`#RRGGBB`), yellow like the website otherwise.
func lawMarkColor(_ hex: String?) -> UIColor {
    guard let hex, hex.count == 7, hex.hasPrefix("#"), let value = UInt32(hex.dropFirst(), radix: 16) else { return .systemYellow }
    return UIColor(red: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255, blue: CGFloat(value & 0xFF) / 255, alpha: 1)
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

/// Which input started a lookup; that field keeps what was typed there.
private enum LawLookupField { case query, number }

struct LawReaderView: View {
    @EnvironmentObject private var laws: LawLibraryModel
    /// Shown in the notebook's law window, which can be closed or stashed.
    var inPanel = false
    var pen = LawPenMode()
    /// Lets the reader switch what Apple Pencil does; nil hides the switch.
    var onPenChange: ((LawPenMode) -> Void)? = nil
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
    /// Reading size of the law text, kept across sections, notebooks and launches.
    @AppStorage("noty.laws.fontSize") private var fontSize = 18.0
    @State private var jumpParagraph: String?
    @State private var requestID = UUID()
    @FocusState private var queryFocused: Bool
    /// Closed or stashed at the screen edge: no hidden field may keep the keyboard.
    private var hidden: Bool { inPanel && (!laws.panelOpen || laws.stashed) }
    @State private var errorsShownHere = false
    /// While the reader is visible it shows `laws.error` itself.
    private func showErrors(_ shown: Bool) {
        guard shown != errorsShownHere else { return }
        errorsShownHere = shown
        laws.inlineErrorPages += shown ? 1 : -1
    }
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
            return LawTextMark(id: item.id, anchor: LawAnchor(sectionId: section.id, start: start, end: end, quote: quote), color: item.payload["color"]?.string)
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
            // The app-level alert cannot appear over an open notebook: show it here.
            if let error = laws.error {
                HStack {
                    Text(error).font(.caption).foregroundStyle(.orange)
                    Spacer()
                    Button("OK") { laws.error = nil }.font(.caption)
                }.padding(8)
            }
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
                        items: marks.filter { $0.kind == "annotation" }, pen: pen,
                        onMark: { payload in
                            var payload = payload.merging(basePayload(doc)) { _, new in new }
                            payload["color"] = .string(pen.hex)
                            Task { await laws.save(kind: "annotation", payload: payload) }
                        }, onRemove: { unmark($0) })
                        .id(pdfURL)
                } else {
                    NativeLawText(text: section.text, html: section.html, notes: section.notes, sectionID: section.id, fontSize: fontSize,
                        marks: textMarks, paragraph: jumpParagraph, selection: textSelection, pen: pen,
                        onMark: { mark($0) }, onRemove: { unmark($0) })
                        .overlay(alignment: .bottom) { if textSelection.active { selectionBar } }
                }
                footer(doc, section: section)
            } else if !loading {
                ContentUnavailableView(laws.entries.isEmpty ? "Noch keine Gesetze geladen" : "Gesetz wählen", systemImage: "books.vertical", description: Text(laws.entries.isEmpty ? "Unter Einstellungen › Gesetzessammlung den Offlinebestand laden." : "Ein Gesetz antippen oder zum Beispiel nach 144 HGB suchen."))
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
            loadError = ""
            do { try await Task.sleep(for: .milliseconds(450)) } catch { return }
            // While typing only a complete „144 HGB“ jumps: a bare „144“ may
            // still become that and must not move the reader (and its saved
            // place) to § 144 of the open law. Return searches it.
            await search(query, bareReference: false, from: .query)
        }
        .task(id: number) {
            // The field following the reader (arrows, contents) is no new lookup.
            guard !number.isEmpty, !showsCurrentSection(number) else { return }
            do { try await Task.sleep(for: .milliseconds(450)) } catch { return }
            await search(number, from: .number)
        }
        .onChange(of: hidden) { _, hidden in
            if hidden { queryFocused = false; textSelection.clear() }
            showErrors(!hidden)
        }
        .onAppear { showErrors(!hidden) }
        .onDisappear { showErrors(false) }
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
                // Directly in the bar, not in a menu: several taps in a row stay quick.
                if !viewPDF {
                    Button { fontSize = max(12, fontSize - 2) } label: { Image(systemName: "textformat.size.smaller").frame(minWidth: 30, minHeight: 32) }
                        .disabled(fontSize <= 12).accessibilityLabel("Schrift kleiner")
                    Button { fontSize = min(32, fontSize + 2) } label: { Image(systemName: "textformat.size.larger").frame(minWidth: 30, minHeight: 32) }
                        .disabled(fontSize >= 32).accessibilityLabel("Schrift größer")
                }
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
                    Divider()
                    // Marking never needs an account; the account only syncs.
                    if let user = laws.user, !laws.sessionExpired {
                        Text("Angemeldet als \(user.email ?? user.name) · \(laws.syncStatus)")
                    } else {
                        Text("Nicht angemeldet · Markierungen bleiben auf diesem iPad. Konto unter Einstellungen › Konto.")
                    }
                } label: { Image(systemName: "ellipsis") }.accessibilityLabel("Fassung und Markierungen")
            }
            HStack {
                TextField("Schnellsuche · 144 HGB", text: $query).textInputAutocapitalization(.never).autocorrectionDisabled().submitLabel(.search)
                    .focused($queryFocused)
                    .onSubmit { Task { await search(query, allowFullText: true, from: .query) } }
                if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }.accessibilityLabel("Suche leeren") }
            }.padding(8).background(.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            HStack {
                LawParagraphField(placeholder: entry?.kind == "administration" ? "Abschnitt / R" : "Paragraph", text: $number, letters: letters, active: !hidden) {
                    Task { await search(number, allowFullText: true, from: .number) }
                }
                // A UITextField otherwise takes all offered height and pushes
                // the law text down (empty box under the quick search).
                .fixedSize(horizontal: false, vertical: true).frame(minHeight: 32)
                Button(letters ? "123" : "abc / Abs.") { letters.toggle() }.font(.caption)
                    .accessibilityLabel("Zwischen Zahlen- und Texttastatur wechseln")
                Button(viewPDF ? "Lesetext" : "PDF") { Task { await togglePDF() } }.disabled(document == nil)
            }.padding(8).background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
            if let onPenChange { penSwitch(onPenChange) }
        }.padding(10).buttonStyle(.borderless)
    }
    /// What Apple Pencil does in the law text and PDF. Fingers always scroll and
    /// select; choosing the highlighter or an eraser in the notebook switches along.
    private func penSwitch(_ change: @escaping (LawPenMode) -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "applepencil").foregroundStyle(.secondary).accessibilityHidden(true)
            Picker("Apple Pencil", selection: Binding(get: { pen.kind }, set: { var next = pen; next.kind = $0; change(next) })) {
                Text("Lesen").tag(LawPenMode.Kind.none)
                Text("Markieren").tag(LawPenMode.Kind.marker)
                Text("Radieren").tag(LawPenMode.Kind.eraser)
            }.pickerStyle(.segmented)
            Menu {
                ForEach(LawPenMode.presets, id: \.name) { preset in
                    Button(preset.name) { var next = pen; next.color = preset.color; next.kind = .marker; change(next) }
                }
            } label: {
                Circle().fill(Color(lawMarkColor(pen.hex))).frame(width: 22, height: 22)
                    .overlay(Circle().stroke(.secondary, lineWidth: 1)).frame(width: 32, height: 32)
            }.accessibilityLabel("Markierfarbe")
        }
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
        follow(sections[i + direction])
        // Without a PDF position the PDF view would silently fall back to page 1.
        if viewPDF, sections[i + direction].pdf == nil {
            viewPDF = false; loadError = "Keine PDF-Fundstelle für diese Vorschrift; der Lesetext wird angezeigt."
        }
    }
    /// Both fields describe where the reader is. After arrows, contents,
    /// bookmarks or another law the paragraph field shows the new section's
    /// number and a quick-search location that no longer applies is cleared;
    /// the field a lookup was typed into keeps its input (e.g. „4 Abs. 2“).
    private func follow(_ shown: LawSection?, from field: LawLookupField? = nil) {
        if field != .number { number = shown?.keys.first ?? "" }
        if field != .query, !query.isEmpty,
           LawQuickTarget.parse(query, entries: laws.entries) != nil || LawReference.parse(query) != nil { query = "" }
    }
    /// `value` names the shown section without a paragraph, so a lookup would
    /// change nothing (in particular the paragraph field following the reader).
    private func showsCurrentSection(_ value: String) -> Bool {
        guard let section, let ref = LawReference.parse(value), ref.paragraph == nil else { return false }
        return section.keys.contains(ref.key)
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
        guard (anchor.quote as NSString).length <= 4000 else { loadError = "Bitte eine kürzere Textstelle markieren."; return }
        var payload = basePayload(doc); payload["kind"] = .string("text"); payload["page"] = .number(0); payload["anchor"] = value
        payload["color"] = .string(pen.hex)
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
    private func open(_ entry: LawEntry, version: String? = nil, target: String? = nil, paragraph: String? = nil, resume: Bool = false, from field: LawLookupField? = nil) async {
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
            let shown = found ?? doc.sections.first
            sectionID = shown?.id ?? ""; jumpParagraph = paragraph
            pdfURL = nil; viewPDF = false; pdfTarget = nil
            follow(shown, from: field)
        } catch { if requestID == request { loadError = error.localizedDescription } }
    }
    private func search(_ value: String, allowFullText: Bool = false, bareReference: Bool = true, from field: LawLookupField) async {
        if let target = LawQuickTarget.parse(value, entries: laws.entries), let entry = laws.entries.first(where: { $0.id == target.lawID }) {
            await open(entry, target: target.reference.key, paragraph: target.reference.paragraph, from: field)
        } else if bareReference, let ref = LawReference.parse(value), let entry {
            if let doc = document, let s = doc.sections.first(where: { $0.keys.contains(ref.key) }) {
                textSelection.clear()
                pdfTarget = nil; sectionID = s.id; jumpParagraph = ref.paragraph; loadError = ""
                follow(s, from: field)
            } else { await open(entry, version: document?.version, target: ref.key, paragraph: ref.paragraph, from: field) }
        } else if allowFullText, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let doc = document else { loadError = "Bitte zuerst ein Gesetz wählen."; return }
            let term = value.lowercased()
            if let found = doc.sections.first(where: { ("\($0.label) \($0.title) \($0.text) \($0.notes)").lowercased().contains(term) }) {
                textSelection.clear()
                sectionID = found.id; jumpParagraph = nil; loadError = ""
                follow(found, from: field)
            } else { loadError = "„\(value)“ wurde in \(entry?.abbr ?? "diesem Dokument") nicht gefunden." }
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
                Button { textSelection.clear(); pdfTarget = nil; sectionID = s.id; jumpParagraph = nil; follow(s); showContents = false } label: {
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

/// Apple Pencil stroke that begins on touch-down. A pan waits for its movement
/// threshold and then loses against the text view's own Pencil selection,
/// which made marking hit-or-miss; beginning at once prevents those gestures.
/// Enabled only while the notebook tool gives Pencil a job here.
private final class LawPencilStroke: UIGestureRecognizer {
    private(set) var startLocation: CGPoint?
    private weak var touch: UITouch?
    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard touch == nil, let first = touches.first else { touches.forEach { ignore($0, for: event) }; return }
        touch = first; startLocation = first.location(in: view)
        state = .began
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        if let touch, touches.contains(touch) { state = .changed }
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        if let touch, touches.contains(touch) { state = .ended }
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        if let touch, touches.contains(touch) { state = .cancelled }
    }
    override func location(in view: UIView?) -> CGPoint { touch?.location(in: view) ?? super.location(in: view) }
    override func reset() {
        super.reset()
        startLocation = nil; touch = nil
    }
}

private var lawTouchTypesWithoutPencil: [NSNumber] { [UITouch.TouchType.direct, .indirect, .indirectPointer].map { NSNumber(value: $0.rawValue) } }
private var lawAllTouchTypes: [NSNumber] { [UITouch.TouchType.direct, .indirect, .pencil, .indirectPointer].map { NSNumber(value: $0.rawValue) } }

private struct NativeLawText: UIViewRepresentable {
    var text: String
    var html: String?
    var notes: String
    var sectionID: String
    var fontSize: Double
    var marks: [LawTextMark]
    var paragraph: String?
    var selection: LawTextSelection
    var pen: LawPenMode
    var onMark: (NSRange) -> Void
    var onRemove: ([String]) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UITextView {
        // TextKit 1: highlights are changed in place as text attributes. TextKit 2
        // (default since iOS 16) did not reliably redraw such changes, so new and
        // removed marks only showed after the section was rebuilt.
        let v = UITextView(usingTextLayoutManager: false); v.isEditable = false; v.isSelectable = true; v.backgroundColor = .systemBackground
        // Bottom room for the floating selection bar.
        v.textContainerInset = UIEdgeInsets(top: 8, left: 12, bottom: 72, right: 12); v.delegate = context.coordinator
        v.scrollsToTop = false
        let stroke = LawPencilStroke(target: context.coordinator, action: #selector(Coordinator.pencil(_:)))
        v.addGestureRecognizer(stroke)
        context.coordinator.stroke = stroke
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
        // Highlighter/eraser: Pencil marks; fingers keep scrolling and selecting.
        // Other notebook tools: Pencil scrolls and selects like a finger.
        let penActive = pen.kind != .none
        if c.penActive != penActive {
            c.penActive = penActive
            c.stroke?.isEnabled = penActive
            v.panGestureRecognizer.allowedTouchTypes = penActive ? lawTouchTypesWithoutPencil : lawAllTouchTypes
        }
        let bodyKey = "\(sectionID):\(fontSize):\(text.hashValue):\(html.hashValue):\(notes.hashValue)"
        if c.bodyKey != bodyKey {
            let changedSection = c.sectionID != sectionID
            let resized = !changedSection && c.fontSize != fontSize
            let offset = v.contentOffset
            // The first visible character stays on top when the size changes.
            let topCharacter = resized ? v.closestPosition(to: CGPoint(x: v.textContainerInset.left + 1, y: offset.y + v.textContainerInset.top + 1)) .map { v.offset(from: v.beginningOfDocument, to: $0) } : nil
            let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: fontSize), .foregroundColor: UIColor.label]
            let richKey = "\(sectionID):\(text.hashValue):\(html.hashValue)"
            if c.richKey != richKey { c.richKey = richKey; c.importRich(html: html, text: text) }
            let body = c.rich.map { c.scaled($0, to: fontSize) } ?? NSMutableAttributedString(string: text, attributes: attributes)
            let rendered = body.string
            if !notes.isEmpty { body.append(NSAttributedString(string: "\n\n" + notes, attributes: attributes)) }
            c.renderedText = rendered; c.bodyLength = (rendered as NSString).length
            selection.text = rendered
            c.updating = true
            v.attributedText = body
            if changedSection { v.setContentOffset(.zero, animated: false) } else {
                v.layoutIfNeeded()
                var y = offset.y
                if let topCharacter, let start = v.position(from: v.beginningOfDocument, offset: topCharacter),
                   let end = v.position(from: start, offset: 1), let range = v.textRange(from: start, to: end) {
                    let rect = v.firstRect(for: range)
                    if rect.minY.isFinite { y = rect.minY - v.textContainerInset.top }
                }
                v.setContentOffset(CGPoint(x: 0, y: min(max(0, y), max(0, v.contentSize.height - v.bounds.height))), animated: false)
            }
            c.updating = false
            c.bodyKey = bodyKey; c.sectionID = sectionID; c.fontSize = fontSize; c.marksKey = nil
        }
        // Marks only change attributes in place: no new text, no scroll jump.
        if c.marksKey != marks.hashValue {
            c.marksKey = marks.hashValue
            let ranges = LawTextAnchor.originalRanges(text: c.renderedText, anchors: marks.map(\.anchor))
            c.markRanges = zip(marks, ranges).compactMap { mark, range in range.map { (mark.id, $0, lawMarkColor(mark.color)) } }
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
        var bodyKey = "", sectionID = "", jump = "", richKey = ""
        var fontSize = 0.0
        var marksKey: Int?
        /// HTML rendering of the current section at a reference size, or nil when
        /// the plain text is used. Imported once per section, not per size step.
        var rich: NSAttributedString?
        private var richBase: CGFloat = 17
        var updating = false
        var renderedText = ""
        var bodyLength = 0
        var markRanges: [(id: String, range: NSRange, color: UIColor)] = []
        weak var stroke: LawPencilStroke?
        var penActive: Bool?
        private var strokeStart: Int?
        private var strokePreview: NSRange?
        init(_ parent: NativeLawText) { self.parent = parent }

        /// Rich native HTML supports tables/lists. Only use it if its exact
        /// canonical text matches the shared anchor contract; otherwise plain
        /// source text is authoritative. Never fetch remote HTML resources.
        func importRich(html: String?, text: String) {
            rich = nil
            guard let html, !html.isEmpty, html.utf8.count <= 250_000,
                  html.range(of: "<(?:script|iframe|img|link|object|style)|(?:src|href)\\s*=", options: [.regularExpression, .caseInsensitive]) == nil else { return }
            let markup = "<html><head><meta charset='utf-8'><style>body{font-family:-apple-system;font-size:17px;color:#eeeeee}table{border-collapse:collapse}td,th{border:1px solid #666;padding:4px}</style></head><body>" + html + "</body></html>"
            guard let data = markup.data(using: .utf8),
                  let imported = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil),
                  LawTextAnchor.canonical(imported.string) == LawTextAnchor.canonical(text) else { return }
            // Body size as the importer actually produced it (its px/pt mapping).
            var lengths: [CGFloat: Int] = [:]
            imported.enumerateAttribute(.font, in: NSRange(location: 0, length: imported.length)) { value, range, _ in
                if let font = value as? UIFont { lengths[font.pointSize, default: 0] += range.length }
            }
            richBase = lengths.max { $0.value < $1.value }?.key ?? 17
            rich = imported
        }
        /// The imported text with every font scaled so the body text is `size` pt.
        func scaled(_ source: NSAttributedString, to size: Double) -> NSMutableAttributedString {
            let result = NSMutableAttributedString(attributedString: source)
            let factor = CGFloat(size) / max(1, richBase)
            result.enumerateAttribute(.font, in: NSRange(location: 0, length: result.length)) { value, range, _ in
                guard let font = value as? UIFont else { return }
                result.addAttribute(.font, value: font.withSize(font.pointSize * factor), range: range)
            }
            return result
        }
        func applyHighlights(preview: NSRange?) {
            guard let storage = view?.textStorage else { return }
            let body = NSRange(location: 0, length: min(bodyLength, storage.length))
            storage.beginEditing()
            storage.removeAttribute(.backgroundColor, range: body)
            for mark in markRanges where NSMaxRange(mark.range) <= body.length {
                storage.addAttribute(.backgroundColor, value: mark.color.withAlphaComponent(0.4), range: mark.range)
            }
            if let preview, NSMaxRange(preview) <= body.length {
                let color = parent.pen.kind == .eraser ? UIColor.systemGray.withAlphaComponent(0.5) : lawMarkColor(parent.pen.hex).withAlphaComponent(0.6)
                storage.addAttribute(.backgroundColor, value: color, range: preview)
            }
            storage.endEditing()
            view?.layoutManager.invalidateDisplay(forCharacterRange: body)
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
        /// Highlighter: the stroke covers whole words from its start to its end, so
        /// the result is always a straight band along the lines. Eraser: marks
        /// under the stroke are removed.
        @objc func pencil(_ gesture: LawPencilStroke) {
            guard let v = view else { return }
            switch gesture.state {
            case .began:
                strokeStart = caret(at: gesture.startLocation ?? gesture.location(in: v))
                showStroke(stroke(to: gesture.location(in: v)))
            case .changed:
                showStroke(stroke(to: gesture.location(in: v)))
            case .ended:
                let range = stroke(to: gesture.location(in: v))
                strokeStart = nil; strokePreview = nil
                applyHighlights(preview: nil)
                guard let range else { return }
                if parent.pen.kind == .eraser {
                    let hit = marks(in: range)
                    if !hit.isEmpty { parent.onRemove(hit) }
                } else { parent.onMark(range) }
            default:
                strokeStart = nil; strokePreview = nil
                applyHighlights(preview: nil)
            }
        }
        /// Restyles only when the covered characters change, not per Pencil sample.
        private func showStroke(_ range: NSRange?) {
            guard range != strokePreview else { return }
            strokePreview = range
            applyHighlights(preview: range)
        }
        private func stroke(to point: CGPoint) -> NSRange? {
            guard let start = strokeStart else { return nil }
            let end = caret(at: point)
            guard end != start else { return nil }
            return words(NSRange(location: min(start, end), length: abs(end - start)))
        }
        /// Widens a stroke range to whole words and drops spaces at its ends.
        private func words(_ range: NSRange) -> NSRange? {
            let text = renderedText as NSString
            func word(_ i: Int) -> Bool {
                guard i >= 0, i < text.length, let scalar = UnicodeScalar(text.character(at: i)) else { return false }
                return CharacterSet.alphanumerics.contains(scalar)
            }
            var lo = range.location, hi = min(NSMaxRange(range), text.length)
            while lo < hi, !word(lo), CharacterSet.whitespacesAndNewlines.contains(UnicodeScalar(text.character(at: lo)) ?? "x") { lo += 1 }
            while hi > lo, !word(hi - 1), CharacterSet.whitespacesAndNewlines.contains(UnicodeScalar(text.character(at: hi - 1)) ?? "x") { hi -= 1 }
            guard hi > lo else { return nil }
            while lo > 0, word(lo), word(lo - 1) { lo -= 1 }
            while hi < text.length, word(hi - 1), word(hi) { hi += 1 }
            return NSRange(location: lo, length: hi - lo)
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
    var pen: LawPenMode
    var onMark: ([String: LawJSON]) -> Void
    var onRemove: ([String]) -> Void
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
        let stroke = LawPencilStroke(target: c, action: #selector(Coordinator.pencil(_:)))
        stroke.delegate = c
        v.addGestureRecognizer(stroke)
        c.view = v; c.ink = ink; c.markButton = mark; c.stroke = stroke
        return v
    }
    func updateUIView(_ v: PDFView, context: Context) {
        let c = context.coordinator
        c.parent = self
        c.stroke?.isEnabled = pen.kind != .none
        // PDFKit builds its scroll view lazily; route Pencil on every update.
        c.routePencil(in: v)
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
                let color = lawMarkColor(item.payload["color"]?.string).withAlphaComponent(0.4)
                if case let .array(rects) = item.payload["rectangles"] {
                    for rect in rects {
                        guard case let .object(r) = rect, case let .number(x) = r["x"], case let .number(y) = r["y"], case let .number(w) = r["width"], case let .number(h) = r["height"] else { continue }
                        let a = PDFAnnotation(bounds: CGRect(x: bounds.minX + x * bounds.width, y: bounds.maxY - (y + h) * bounds.height, width: w * bounds.width, height: h * bounds.height), forType: .highlight, withProperties: nil)
                        a.color = color; a.userName = "noty-law"; p.addAnnotation(a)
                    }
                } else if case let .array(points) = item.payload["points"] {
                    let path = UIBezierPath()
                    for (i, point) in points.enumerated() {
                        guard case let .array(pair) = point, pair.count == 2, case let .number(x) = pair[0], case let .number(y) = pair[1] else { continue }
                        let pos = CGPoint(x: x * bounds.width, y: (1 - y) * bounds.height)
                        if i == 0 { path.move(to: pos) } else { path.addLine(to: pos) }
                    }
                    let a = PDFAnnotation(bounds: bounds, forType: .ink, withProperties: nil)
                    a.add(path); a.color = color; let border = PDFBorder(); border.lineWidth = bounds.width * 0.018; a.border = border; a.userName = "noty-law"; p.addAnnotation(a)
                }
            }
        }
    }
    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: NativeLawPDF
        weak var view: PDFView?
        weak var ink: LawPDFInkOverlay?
        weak var markButton: UIButton?
        weak var stroke: LawPencilStroke?
        var destination = ""
        var items: [LawPersonalItem] = []
        private var straightened = false
        private var lastMove = CGPoint.zero
        private var holdToken = 0
        init(_ parent: NativeLawPDF) { self.parent = parent }
        /// With highlighter/eraser Pencil marks and fingers scroll; otherwise
        /// Pencil scrolls and selects like a finger.
        func routePencil(in root: UIView) {
            let types = parent.pen.kind == .none ? lawAllTouchTypes : lawTouchTypesWithoutPencil
            for sub in root.subviews {
                if let scroll = sub as? UIScrollView, scroll.panGestureRecognizer.allowedTouchTypes != types {
                    scroll.panGestureRecognizer.allowedTouchTypes = types
                }
                routePencil(in: sub)
            }
        }
        /// The „Markieren“ button stays tappable with Pencil.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool { !(touch.view is UIControl) }
        @objc func pageChanged() {
            guard let v = view, let doc = v.document, let page = v.currentPage else { return }
            routePencil(in: v)
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
        /// Like the notebook highlighter: „Immer gerade“ straightens on release,
        /// „nach Halten begradigen“ when Pencil rests at the end; after that the
        /// line end follows Pencil with angle snapping. The eraser removes marks
        /// the stroke touches.
        @objc func pencil(_ gesture: LawPencilStroke) {
            guard let v = view, let ink else { return }
            let point = gesture.location(in: v)
            switch gesture.state {
            case .began:
                straightened = false
                ink.begin(at: gesture.startLocation ?? point, color: parent.pen.kind == .eraser ? .systemGray : lawMarkColor(parent.pen.hex))
                ink.extend(to: point); lastMove = point; scheduleHold()
            case .changed:
                if straightened { ink.moveStraightEnd(to: point); return }
                ink.extend(to: point)
                if hypot(point.x - lastMove.x, point.y - lastMove.y) > 4 { lastMove = point; scheduleHold() }
            case .ended:
                holdToken += 1
                if !straightened { ink.extend(to: point) }
                if parent.pen.kind == .eraser {
                    let hit = erased()
                    ink.cancel()
                    if !hit.isEmpty { parent.onRemove(hit) }
                } else {
                    if parent.pen.straight && !straightened { ink.straighten() }
                    if let payload = ink.finish() { parent.onMark(payload) }
                }
            default:
                holdToken += 1
                ink.cancel()
            }
        }
        private func scheduleHold() {
            holdToken += 1
            guard parent.pen.kind == .marker, parent.pen.holdStraighten else { return }
            let token = holdToken
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(500))
                guard let self, self.holdToken == token, !self.straightened, let ink = self.ink, ink.isDrawing, ink.straighten() else { return }
                self.straightened = true
                UISelectionFeedbackGenerator().selectionChanged()
            }
        }
        /// Marks on the stroke's page that the stroke touches (page units, y down).
        private func erased() -> [String] {
            guard let ink, let page = ink.page, let doc = view?.document else { return [] }
            let number = doc.index(for: page) + 1, bounds = page.bounds(for: .cropBox)
            let scale = { (p: CGPoint) in CGPoint(x: p.x * bounds.width, y: p.y * bounds.height) }
            let stroke = ink.normalizedPoints.map(scale)
            let reach = bounds.width * 0.02
            func distance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
                let dx = b.x - a.x, dy = b.y - a.y, length = dx * dx + dy * dy
                let t = length > 0 ? min(1, max(0, ((p.x - a.x) * dx + (p.y - a.y) * dy) / length)) : 0
                return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
            }
            func point(_ value: LawJSON) -> CGPoint? {
                guard case let .array(pair) = value, pair.count == 2, case let .number(x) = pair[0], case let .number(y) = pair[1] else { return nil }
                return scale(CGPoint(x: x, y: y))
            }
            return items.filter { item in
                guard item.payload["page"]?.int == number else { return false }
                if case let .array(rects) = item.payload["rectangles"] {
                    return rects.contains { rect in
                        guard case let .object(r) = rect, case let .number(x) = r["x"], case let .number(y) = r["y"], case let .number(w) = r["width"], case let .number(h) = r["height"] else { return false }
                        let box = CGRect(x: x * bounds.width, y: y * bounds.height, width: w * bounds.width, height: h * bounds.height).insetBy(dx: -reach, dy: -reach)
                        return stroke.contains { box.contains($0) }
                    }
                }
                if case let .array(values) = item.payload["points"] {
                    let line = values.compactMap(point)
                    let segments = line.count == 1 ? [(line[0], line[0])] : Array(zip(line, line.dropFirst()))
                    return stroke.contains { p in segments.contains { distance(p, $0.0, $0.1) < reach } }
                }
                return false
            }.map(\.id)
        }
    }
}

/// Live preview of a Pencil stroke over the PDF. Points are kept in PDF page
/// coordinates; the source PDF is never saved with the derived annotations.
@MainActor
private final class LawPDFInkOverlay: UIView {
    weak var pdf: PDFView?
    private(set) weak var page: PDFPage?
    private var pagePoints: [CGPoint] = []
    private var straightLine: (start: CGPoint, end: CGPoint)?
    private let preview = CAShapeLayer()
    var isDrawing: Bool { page != nil }
    override init(frame: CGRect) {
        super.init(frame: frame)
        preview.fillColor = UIColor.clear.cgColor; preview.lineCap = .round; preview.lineJoin = .round
        layer.addSublayer(preview)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func begin(at point: CGPoint, color: UIColor) {
        guard let pdf else { return }
        page = pdf.page(for: point, nearest: true); pagePoints = []; straightLine = nil
        preview.strokeColor = color.withAlphaComponent(0.45).cgColor
        if let page { preview.lineWidth = max(2, pdf.convert(page.bounds(for: .cropBox), from: page).width * 0.018) }
        extend(to: point)
    }
    func extend(to point: CGPoint) {
        guard pagePoints.count < 1500, let pdf, let page else { return }
        let p = pdf.convert(point, to: page)
        guard page.bounds(for: .cropBox).contains(p) else { return }
        pagePoints.append(p); redraw()
    }
    /// Replaces the drawn stroke by one fitted, angle-snapped segment.
    @discardableResult
    func straighten() -> Bool {
        guard let line = MarkerStraightening.line(pagePoints.map { PagePoint(x: $0.x, y: $0.y) }) else { return false }
        straightLine = (CGPoint(x: line.start.x, y: line.start.y), CGPoint(x: line.end.x, y: line.end.y)); redraw()
        return true
    }
    /// After straightening the start stays; the end follows Pencil, snapped in angle.
    func moveStraightEnd(to point: CGPoint) {
        guard let pdf, let page, let line = straightLine else { return }
        let p = pdf.convert(point, to: page)
        let end = LineSnapping.end(from: PagePoint(x: line.start.x, y: line.start.y), to: PagePoint(x: p.x, y: p.y))
        straightLine = (line.start, CGPoint(x: end.x, y: end.y)); redraw()
    }
    /// Stroke relative to the crop box: x to the right, y down from the top, 0…1.
    var normalizedPoints: [CGPoint] {
        guard let page else { return [] }
        let b = page.bounds(for: .cropBox)
        guard b.width > 0, b.height > 0 else { return [] }
        return (straightLine.map { [$0.start, $0.end] } ?? pagePoints).map {
            CGPoint(x: min(1, max(0, ($0.x - b.minX) / b.width)), y: min(1, max(0, (b.maxY - $0.y) / b.height)))
        }
    }
    func finish() -> [String: LawJSON]? {
        defer { cancel() }
        let points = normalizedPoints
        guard let page, let doc = pdf?.document, points.count >= 2 else { return nil }
        return ["kind": .string("pdf"), "page": .number(Double(doc.index(for: page) + 1)), "points": .array(points.map { .array([.number($0.x), .number($0.y)]) })]
    }
    func cancel() { pagePoints = []; straightLine = nil; page = nil; preview.path = nil }
    private func redraw() {
        guard let pdf, let page else { preview.path = nil; return }
        let path = UIBezierPath()
        for (index, p) in (straightLine.map { [$0.start, $0.end] } ?? pagePoints).enumerated() {
            let local = convert(pdf.convert(p, from: page), from: pdf)
            if index == 0 { path.move(to: local) } else { path.addLine(to: local) }
        }
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
        /// The field shows the current section: typing replaces that number.
        func textFieldDidBeginEditing(_ textField: UITextField) {
            DispatchQueue.main.async {
                textField.selectedTextRange = textField.textRange(from: textField.beginningOfDocument, to: textField.endOfDocument)
            }
        }
        func textFieldShouldReturn(_ textField: UITextField) -> Bool { parent.submit(); return true }
    }
}
