// Vorschau und Öffnen von Gesetzesverweisen im Heft (docs/PARAGRAPH-LINKS.md).
// Die Seite (WorksheetView) meldet Hover/Tippen hierher; EditorWorkspace zeigt
// die Karte (`LawCitationCardLayer`) und öffnet das Gesetzesfenster.
//
// - Hover (Apple Pencil Pro, Trackpad): die Seite meldet `hover` (schon
//   verzögert) und `endHover`; die Karte verschwindet nach kurzer Nachfrist,
//   außer Stift/Zeiger sind über ihr.
// - Finger: `tap` auf die Unterstreichung zeigt die Karte, ein zweiter Tipp
//   (auf Karte oder Verweis) öffnet.
// - Zeigerklick: `open` öffnet direkt.
// - Stift aufs Papier, Scrollen, Zoomen, Seitenwechsel: `pageInteractionBegan`
//   blendet sofort aus; ebenso jede Änderung der Arbeitsfläche (Drehen,
//   Teilung, Gesetzesfenster, Tastatur) und das Schließen des Hefts. Kein
//   eigenes Esc: es würde Esc der Tastaturmodi abfangen; Tippen daneben schließt.
//
// Nur abgeleitete Anzeige: nichts davon wird im Heft gespeichert. Die Karte
// liest nur Gesetzestexte, die schon offline auf dem iPad liegen; bloßes
// Hovern lädt nie etwas herunter (erst Öffnen im Gesetzesfenster).
import SwiftUI
import Combine
import NotebookCore

/// How the citation was reached; decides what a tap/click does.
enum LawCitationInput: Equatable { case pencilHover, pointerHover, touch }

/// Shared model (one scene: UIApplicationSupportsMultipleScenes = false).
@MainActor
final class LawCitationPreviewModel: ObservableObject {
    static let shared = LawCitationPreviewModel()

    struct Presentation: Equatable {
        var citation: LawCitation
        /// Rect of the citation in window coordinates (for placing the card next to it).
        var anchor: CGRect
        var input: LawCitationInput
        var pageID: UUID?
        /// Notebook context (default law, tax year) of the page that showed it.
        var context = NotebookLawContext()
        /// Citation rect in canonical page coordinates (for „Als Zitat einfügen“).
        var pageRect: PageRect? = nil
    }

    /// What the card shows below its heading.
    enum Content: Equatable {
        case loading
        /// The law's text is not on this iPad yet; opening still loads it.
        case notOffline
        /// The current version has no such section.
        case missing
        /// The catalog no longer knows the law.
        case unavailable
        case section(label: String, title: String, excerpt: String)
    }

    @Published private(set) var presentation: Presentation?
    /// Set by the card's „Als Zitat einfügen“; the editor of that page consumes and clears it.
    @Published var quoteRequest: LawQuoteRequest?
    @Published private(set) var content: Content = .loading
    /// Counts new cards (another citation or place); the card view's identity.
    @Published private(set) var cardID = 0

    /// Built from the law catalog; nil while the collection is off, has no
    /// catalog, or the user turned links off. Pages scan with this.
    @Published private(set) var scanner: LawCitationScanner?
    /// Bumps whenever `scanner` changes, so pages rescan.
    @Published private(set) var scannerGeneration = 0

    /// Grace period after the hover left the citation (to reach the card).
    static let hoverGrace: Duration = .milliseconds(350)
    /// Card contents per (law, version, section, Absatz), newest last.
    private static let excerptLimit = 64

    private weak var laws: LawLibraryModel?
    private var watching: [AnyCancellable] = []
    /// Identity of the catalog the scanner was built for; nil without scanner.
    private var catalogKey = ""
    private var scannerKey: String?
    private var entries: [LawEntry] = []
    /// Small card contents; the documents themselves are not kept, except
    /// the one decoded last (`document`). Both go on a memory warning.
    private var excerpts: [String: Content] = [:]
    private var excerptOrder: [String] = []
    private var document: (key: String, value: LawDocument)?
    /// One decoding per (law, version) at a time, shared by every card that
    /// asks; its result is always kept, also when the card asking has gone.
    private var decoding: [String: Task<LawDocument?, Never>] = [:]
    private var hideTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    /// Stift or pointer rests on the card itself.
    private(set) var cardHovered = false

    // MARK: Wiring

    /// Follows the catalog and the settings („Gesetzessammlung aktivieren“,
    /// „Gesetzesverweise im Heft verlinken“). Called once by `NotyApp`.
    func connect(_ laws: LawLibraryModel) {
        guard self.laws !== laws else { return }
        self.laws = laws
        watching = [
            laws.$catalog.sink { [weak self] catalog in
                // `sink` runs before the property is set: use the value passed.
                MainActor.assumeIsolated { self?.catalogChanged(catalog?.entries ?? []) }
            },
            NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in MainActor.assumeIsolated { self?.refreshScanner() } },
            NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in MainActor.assumeIsolated { self?.purge() } },
        ]
    }

    private func catalogChanged(_ next: [LawEntry]) {
        let key = next.map { "\($0.id)|\($0.abbr)|\(($0.aliases ?? []).joined(separator: ","))|\($0.currentVersion)" }.joined(separator: ";")
        // A publish that changed nothing the cards depend on keeps the caches.
        guard key != catalogKey else { entries = next; return }
        entries = next; catalogKey = key
        purge()
        if let presentation, entry(presentation.citation.lawID) == nil { dismiss() }
        refreshScanner()
    }

    private func purge() {
        excerpts.removeAll(); excerptOrder.removeAll(); document = nil
    }

    private func refreshScanner() {
        guard let laws else { return }
        let active = laws.enabled && laws.citationLinks && !entries.isEmpty
        let key = active ? catalogKey : nil
        guard key != scannerKey else { return }
        scannerKey = key
        guard let key else {
            dismiss()
            scanner = nil; scannerGeneration += 1
            return
        }
        let entries = entries
        Task {
            // Precompiling the patterns of a few hundred laws stays off the main thread.
            let built = await Task.detached(priority: .userInitiated) { LawCitationScanner(entries: entries) }.value
            guard scannerKey == key else { return }
            scanner = built; scannerGeneration += 1
        }
    }

    // MARK: Called by the page (WorksheetView). All coordinates in window space.

    func hover(_ citation: LawCitation, anchor: CGRect, input: LawCitationInput, pageID: UUID?,
               context: NotebookLawContext = NotebookLawContext(), pageRect: PageRect? = nil) {
        hideTask?.cancel(); hideTask = nil
        show(Presentation(citation: citation, anchor: anchor, input: input, pageID: pageID, context: context, pageRect: pageRect))
    }
    func endHover() {
        // A card a finger opened stays until the page is touched again.
        guard let presentation, presentation.input != .touch else { return }
        scheduleHide()
    }
    /// Finger tap on an underline: shows the card (second tap on the card opens).
    func tap(_ citation: LawCitation, anchor: CGRect, pageID: UUID?,
             context: NotebookLawContext = NotebookLawContext(), pageRect: PageRect? = nil) {
        hideTask?.cancel(); hideTask = nil
        if let presentation, Self.sameCard(presentation, citation: citation, anchor: anchor, pageID: pageID) {
            open(citation)
        } else {
            show(Presentation(citation: citation, anchor: anchor, input: .touch, pageID: pageID, context: context, pageRect: pageRect))
        }
    }
    /// Pointer click: opens the law window at the citation directly.
    func open(_ citation: LawCitation) {
        dismiss()
        laws?.openCitation(lawID: citation.lawID, key: citation.reference.key, paragraph: citation.reference.paragraph)
    }
    func dismiss() {
        hideTask?.cancel(); hideTask = nil
        loadTask?.cancel(); loadTask = nil
        cardHovered = false
        if presentation != nil { presentation = nil }
    }
    /// Pencil touched the paper, page scrolled/zoomed or page changed: hide at once.
    func pageInteractionBegan() {
        guard presentation != nil else { return }
        dismiss()
    }

    // MARK: Called by the card

    /// The card was tapped or clicked.
    func openPresented() {
        guard let presentation else { return }
        open(presentation.citation)
    }
    /// Hover over the card keeps it; leaving it hides after the grace period.
    func cardHover(_ inside: Bool) {
        guard inside != cardHovered else { return }
        cardHovered = inside
        if inside { hideTask?.cancel(); hideTask = nil }
        else if let presentation, presentation.input != .touch { scheduleHide() }
    }

    // MARK: Content

    /// „§ 35a Abs. 2 EStG“: the section's own label once it is loaded.
    var heading: String {
        guard let citation = presentation?.citation else { return "" }
        let abbr = entry(citation.lawID)?.abbr ?? citation.lawID.uppercased()
        if case let .section(label, _, _) = content {
            return LawCitationText.reference(citation.reference.key, paragraph: citation.reference.paragraph, abbr: abbr, label: label)
        }
        return LawCitationText.reference(citation.reference.key, paragraph: citation.reference.paragraph, abbr: abbr)
    }
    var lawAbbreviation: String {
        guard let citation = presentation?.citation else { return "" }
        return entry(citation.lawID)?.abbr ?? citation.lawID.uppercased()
    }

    private func entry(_ id: String) -> LawEntry? { entries.first { $0.id == id } }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            do { try await Task.sleep(for: Self.hoverGrace) } catch { return }
            guard let self, !self.cardHovered else { return }
            self.dismiss()
        }
    }

    /// The same citation in the same place: equal text elsewhere (another
    /// field, another page) is another card.
    static func sameCard(_ presentation: Presentation, citation: LawCitation, anchor: CGRect, pageID: UUID?) -> Bool {
        let a = presentation.anchor
        return presentation.citation == citation && presentation.pageID == pageID
            && abs(a.minX - anchor.minX) < 2 && abs(a.minY - anchor.minY) < 2 && abs(a.width - anchor.width) < 2 && abs(a.height - anchor.height) < 2
    }

    private func show(_ next: Presentation) {
        guard scanner != nil else { return }
        if let presentation, Self.sameCard(presentation, citation: next.citation, anchor: next.anchor, pageID: next.pageID) {
            // Same citation: follow the anchor (a pointer may replace the
            // pencil), without reloading or animating the card again.
            if presentation != next { self.presentation = next }
            return
        }
        cardHovered = false
        cardID &+= 1
        presentation = next
        load(next.citation)
    }

    private func load(_ citation: LawCitation) {
        loadTask?.cancel(); loadTask = nil
        guard let laws, let entry = entry(citation.lawID) else { content = .unavailable; return }
        let documentKey = "\(entry.id)|\(entry.currentVersion)"
        let excerptKey = documentKey + "|\(citation.reference.key)|\(citation.reference.paragraph ?? "")"
        if let hit = excerpts[excerptKey] { content = hit; return }
        if let document, document.key == documentKey {
            content = remember(excerptKey, Self.content(document.value, citation: citation))
            return
        }
        content = .loading
        let decoding = documentTask(entry, key: documentKey, laws: laws)
        loadTask = Task { [weak self] in
            let value = await decoding.value
            guard let self, !Task.isCancelled, self.presentation?.citation == citation else { return }
            guard let value else { self.content = .notOffline; return }
            self.content = self.remember(excerptKey, Self.content(value, citation: citation))
        }
    }

    private func documentTask(_ entry: LawEntry, key: String, laws: LawLibraryModel) -> Task<LawDocument?, Never> {
        if let running = decoding[key] { return running }
        let task = Task { [weak self] () -> LawDocument? in
            let value = await laws.offlineDocument(entry)
            if let self {
                self.decoding[key] = nil
                if let value { self.document = (key, value) }
            }
            return value
        }
        decoding[key] = task
        return task
    }

    private func remember(_ key: String, _ content: Content) -> Content {
        if excerpts.updateValue(content, forKey: key) == nil { excerptOrder.append(key) }
        if excerptOrder.count > Self.excerptLimit {
            for old in excerptOrder.prefix(excerptOrder.count - Self.excerptLimit) { excerpts[old] = nil }
            excerptOrder.removeFirst(excerptOrder.count - Self.excerptLimit)
        }
        return content
    }

    /// Same lookup as the reader (`LawReaderView.open`): section id or one of its keys.
    private static func content(_ document: LawDocument, citation: LawCitation) -> Content {
        let key = citation.reference.key
        guard let section = document.sections.first(where: { $0.id == key || $0.keys.contains(key) }) else { return .missing }
        return .section(label: section.label, title: section.title, excerpt: excerpt(section.text, paragraph: citation.reference.paragraph))
    }

    /// The beginning of the section text, from the cited Absatz on when it is
    /// found: „(2)“ at the start of a line, else anywhere (like the reader's
    /// `jumpParagraph`). Short enough for a few lines of the card.
    static func excerpt(_ text: String, paragraph: String?) -> String {
        let source = text as NSString
        var start = 0
        if let paragraph {
            let marker = NSRegularExpression.escapedPattern(for: "(\(paragraph))")
            if let re = try? NSRegularExpression(pattern: "(?m)^\\s*" + marker),
               let match = re.firstMatch(in: text, range: NSRange(location: 0, length: source.length)) {
                start = match.range.location
            } else {
                let found = source.range(of: "(\(paragraph))")
                if found.location != NSNotFound { start = found.location }
            }
        }
        let rest = source.substring(from: start)
        // Lines kept (Absätze), blank runs folded; about six card lines.
        let lines = rest.components(separatedBy: .newlines)
            .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .filter { !$0.isEmpty }
        var result = ""
        for line in lines {
            if result.count >= 520 { break }
            result += (result.isEmpty ? "" : "\n") + line
        }
        if result.count > 600 { result = String(result.prefix(600)) + " …" }
        return result
    }
}
