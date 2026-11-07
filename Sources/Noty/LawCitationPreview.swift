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
//   Teilung, Gesetzesfenster, Tastatur) und das Schließen des Hefts.
// - Esc schließt die Karte (`consumeEscape`, von KeyboardRouter und den Tasten
//   des Gesetzesfensters gefragt), aber nur solange eine Karte zu sehen ist;
//   sonst bleibt Esc bei Helix, Feldern und dem Gesetzesfenster.
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
        /// Found by handwriting OCR (P3): the card asks „Erkannt: … – stimmt das?“.
        var fromHandwriting = false
        /// A notebook page or a cross-reference in the law reader's text.
        var origin: Origin = .page
    }
    enum Origin: Equatable {
        case page
        /// Hovered in the reader showing `versionID` of `lawID`; the card
        /// follows the link inside the reader, never via „Zurück zur Notiz“.
        case reader(lawID: String, versionID: String)
        var isReader: Bool { if case .reader = self { true } else { false } }
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
        /// `quote`: the whole cited Absatz (or the section's start) for „Als Zitat einfügen“.
        /// `absatzFound`: false when a cited Absatz is not in the text (the
        /// excerpt then starts at the beginning and nothing can be quoted).
        case section(label: String, title: String, excerpt: String, quote: String, absatzFound: Bool)
    }

    /// Which version the card shows, under its heading.
    struct VersionNote: Equatable {
        /// „Fassung für 2023“ or „Stand 29.6.2026“ (plus „– für 2023 ggf. abweichend“).
        var text: String
        /// The text may differ from what applied in the notebook's tax year.
        var caution: Bool
        /// The version opened by a tap; nil: the current one.
        var versionID: String?
        /// „Stand …“ of the version the excerpt comes from, for the quote's source.
        var stand: String?
    }

    @Published private(set) var presentation: Presentation?
    /// Set by the card's „Als Zitat einfügen“; the editor of that page consumes and clears it.
    @Published var quoteRequest: LawQuoteRequest?
    /// Setting „Handschrift einbeziehen“ (`LawLibraryModel.citationHandwritingKey`,
    /// default on, only with links on); pages only OCR ink while true.
    @Published private(set) var handwritingEnabled = false
    @Published private(set) var content: Content = .loading
    @Published private(set) var versionNote: VersionNote?
    /// The version the card's text comes from, for „… ist in der Fassung für
    /// 2023 nicht enthalten“: „der aktuellen Fassung“, „der Fassung für 2023“, „dieser Fassung“.
    @Published private(set) var shownVersion = "der aktuellen Fassung"
    /// Counts new cards (another citation or place); the card view's identity.
    @Published private(set) var cardID = 0

    /// Built from the law catalog; nil while the collection is off, has no
    /// catalog, or the user turned links off. Pages scan with this.
    @Published private(set) var scanner: LawCitationScanner?
    /// Bumps whenever `scanner` changes, so pages rescan.
    @Published private(set) var scannerGeneration = 0
    /// The same scanner for cross-references in the law reader: there
    /// whenever the collection has a catalog, also with links in notebooks off.
    @Published private(set) var readerScanner: LawCitationScanner?
    @Published private(set) var readerScannerGeneration = 0

    /// Grace period after the hover left the citation (to reach the card).
    static let hoverGrace: Duration = .milliseconds(350)
    /// Card contents per (law, version, section, Absatz), newest last.
    private static let excerptLimit = 64

    private weak var laws: LawLibraryModel?
    private var watching: [AnyCancellable] = []
    /// Identity of the catalog the scanner was built for; nil without scanner.
    private var catalogKey = ""
    /// Catalog the scanner `built` belongs to (nil: none wanted).
    private var builtKey: String?
    private var built: (id: Int, scanner: LawCitationScanner)?
    private var buildCount = 0
    private var linksOn = false
    private var publishedPage: Int?
    private var publishedReader: Int?
    /// The way the last card-closing Esc came (`consumeEscape`).
    private var escapeLatch = KeyDeliveryLatch()
    private var entries: [LawEntry] = []
    /// Small card contents; the documents themselves are not kept, except
    /// the one decoded last (`document`). Both go on a memory warning.
    private var excerpts: [String: Content] = [:]
    /// Documents (law|version) found not to be on this iPad: the card does
    /// not try them again on every hover (cleared when a law is opened, which may load it).
    private var notOffline: Set<String> = []
    private var excerptOrder: [String] = []
    private var document: (key: String, value: LawDocument)?
    /// One decoding per (law, version) at a time, shared by every card that
    /// asks; its result is always kept, also when the card asking has gone.
    private var decoding: [String: Task<LawDocument?, Never>] = [:]
    private var hideTask: Task<Void, Never>?
    /// The reader's navigation for a card of its own (`hoverInReader`).
    private var readerFollow: ((LawCitation) -> Void)?
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
        excerpts.removeAll(); excerptOrder.removeAll(); document = nil; notOffline.removeAll()
    }

    /// One scanner per catalog, for pages (only with links on) and the reader.
    private func refreshScanner() {
        guard let laws else { return }
        let key = laws.enabled && !entries.isEmpty ? catalogKey : nil
        linksOn = laws.citationLinks
        let handwriting = linksOn && (UserDefaults.standard.object(forKey: LawLibraryModel.citationHandwritingKey) as? Bool ?? true)
        if handwriting != handwritingEnabled { handwritingEnabled = handwriting }
        if key != builtKey {
            builtKey = key; built = nil
            if let key {
                let entries = entries
                Task {
                    // Precompiling the patterns of a few hundred laws stays off the main thread.
                    let scanner = await Task.detached(priority: .userInitiated) { LawCitationScanner(entries: entries) }.value
                    guard builtKey == key else { return }
                    buildCount += 1
                    built = (buildCount, scanner)
                    publishScanners()
                }
            }
        }
        publishScanners()
    }
    private func publishScanners() {
        let page = linksOn ? built?.id : nil
        if page != publishedPage {
            publishedPage = page
            if page == nil { dismiss() }
            scanner = linksOn ? built?.scanner : nil; scannerGeneration += 1
        }
        if built?.id != publishedReader {
            publishedReader = built?.id
            readerScanner = built?.scanner; readerScannerGeneration += 1
        }
    }

    // MARK: Called by the page (WorksheetView). All coordinates in window space.

    func hover(_ citation: LawCitation, anchor: CGRect, input: LawCitationInput, pageID: UUID?,
               context: NotebookLawContext = NotebookLawContext(), pageRect: PageRect? = nil, fromHandwriting: Bool = false) {
        hideTask?.cancel(); hideTask = nil
        show(Presentation(citation: citation, anchor: anchor, input: input, pageID: pageID, context: context, pageRect: pageRect, fromHandwriting: fromHandwriting))
    }
    func endHover() {
        // A card a finger opened stays until the page is touched again.
        guard let presentation, presentation.input != .touch else { return }
        scheduleHide()
    }
    /// Finger tap on an underline: shows the card (second tap on the card opens).
    func tap(_ citation: LawCitation, anchor: CGRect, pageID: UUID?,
             context: NotebookLawContext = NotebookLawContext(), pageRect: PageRect? = nil, fromHandwriting: Bool = false) {
        hideTask?.cancel(); hideTask = nil
        if let presentation, Self.sameCard(presentation, citation: citation, anchor: anchor, pageID: pageID) {
            open(citation)
        } else {
            show(Presentation(citation: citation, anchor: anchor, input: .touch, pageID: pageID, context: context, pageRect: pageRect, fromHandwriting: fromHandwriting))
        }
    }
    /// Pointer click: opens the law window at the citation directly, in the
    /// version of the notebook's tax year when the catalog can tell it.
    /// Without `context` the shown card's context is used when it is this
    /// citation (the page's click on its card).
    func open(_ citation: LawCitation, context: NotebookLawContext? = nil) {
        let presented = presentation?.citation == citation ? presentation : nil
        if let presented, presented.origin.isReader {
            let follow = readerFollow
            dismiss()
            follow?(citation)
            return
        }
        let used = context ?? presented?.context ?? NotebookLawContext()
        let version = presented != nil ? versionNote?.versionID : yearVersion(citation.lawID, context: used)?.id
        dismiss()
        // Opening may download that version: try it again next time.
        notOffline.removeAll()
        laws?.openCitation(lawID: citation.lawID, key: citation.reference.key, paragraph: citation.reference.paragraph,
                           version: version, year: version == nil ? nil : used.taxYear)
    }

    // MARK: Called by the law reader (cross-references in its text)

    /// Hover over a cross-reference in the reader: the same card; tapping it
    /// calls `follow` (the reader's own navigation with its back history).
    func hoverInReader(_ citation: LawCitation, anchor: CGRect, input: LawCitationInput, lawID: String, versionID: String,
                       follow: @escaping (LawCitation) -> Void) {
        hideTask?.cancel(); hideTask = nil
        readerFollow = follow
        show(Presentation(citation: citation, anchor: anchor, input: input, pageID: nil, origin: .reader(lawID: lawID, versionID: versionID)))
    }
    /// Reader scrolled, changed section or law, was touched, parked or closed.
    func dismissReaderCard() {
        guard presentation?.origin.isReader == true else { return }
        dismiss()
    }
    /// Esc while a card is shown closes it and is used up; otherwise it stays
    /// with whoever has it (Helix, fields, the law window). Only the other way
    /// of the same press (key command after `pressesBegan` or the reverse,
    /// within `KeyDeliveryLatch.window`) is used up too, once: a quick second
    /// Esc goes on as usual. `.press`: `KeyboardRouter.handle(presses)`;
    /// `.keyCommand`: `handle(token:)` and the law window's key commands.
    func consumeEscape(by route: KeyDeliveryLatch.Route) -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        if presentation != nil {
            dismiss()
            escapeLatch.used("esc", by: route, now: now)
            return true
        }
        return !escapeLatch.allows("esc", by: route, now: now)
    }
    func dismiss() {
        hideTask?.cancel(); hideTask = nil
        loadTask?.cancel(); loadTask = nil
        cardHovered = false
        if presentation != nil { presentation = nil }
        readerFollow = nil
    }
    /// Pencil touched the paper, page scrolled/zoomed or page changed: hide at once.
    func pageInteractionBegan() {
        guard presentation != nil else { return }
        NotyMotion.instant { dismiss() }
    }

    // MARK: Called by the card

    /// The card was tapped or clicked.
    func openPresented() {
        guard let presentation else { return }
        open(presentation.citation, context: presentation.context)
    }
    /// „Als Zitat einfügen“ is offered: a page place to put it and the text there
    /// (never for a card of the reader).
    var canQuote: Bool {
        guard let presentation, !presentation.origin.isReader, presentation.pageID != nil, presentation.pageRect != nil,
              presentation.context.canQuote,
              case let .section(_, _, _, quote, found) = content else { return false }
        return found && !quote.isEmpty
    }
    /// „Als Zitat einfügen“: the editor of that page inserts a text field
    /// below the citation (`quoteRequest`), the card goes.
    func quotePresented() {
        guard canQuote, let presentation, let pageID = presentation.pageID, let rect = presentation.pageRect,
              case let .section(label, _, _, quote, _) = content else { return }
        let citation = presentation.citation
        var source = LawCitationText.reference(citation.reference.key, paragraph: citation.reference.paragraph, abbr: lawAbbreviation, label: label)
        if let stand = versionNote?.stand { source += " (Stand \(stand))" }
        quoteRequest = LawQuoteRequest(pageID: pageID, below: rect, text: quote, source: source, notebookID: presentation.context.notebookID)
        dismiss()
    }
    /// Hover over the card keeps it; leaving it hides after the grace period.
    func cardHover(_ inside: Bool) {
        guard inside != cardHovered else { return }
        cardHovered = inside
        if inside { hideTask?.cancel(); hideTask = nil }
        else if let presentation, presentation.input != .touch { scheduleHide() }
    }

    // MARK: Content

    /// „§ 35a Abs. 2 EStG“: the section's own label once it is loaded;
    /// without „Abs. 2“ when that Absatz is not in the text shown.
    var heading: String {
        guard let citation = presentation?.citation else { return "" }
        let abbr = entry(citation.lawID)?.abbr ?? citation.lawID.uppercased()
        if case let .section(label, _, _, _, found) = content {
            return LawCitationText.reference(citation.reference.key, paragraph: found ? citation.reference.paragraph : nil, abbr: abbr, label: label)
        }
        return LawCitationText.reference(citation.reference.key, paragraph: citation.reference.paragraph, abbr: abbr)
    }
    var lawAbbreviation: String {
        guard let citation = presentation?.citation else { return "" }
        return entry(citation.lawID)?.abbr ?? citation.lawID.uppercased()
    }

    private func entry(_ id: String) -> LawEntry? { entries.first { $0.id == id } }

    /// The version for the notebook's tax year when it is not the current one.
    private func yearVersion(_ lawID: String, context: NotebookLawContext) -> LawVersion? {
        guard let year = context.taxYear, let entry = entry(lawID),
              let version = LawVersionChoice.version(for: year, in: entry), version.id != entry.currentVersion else { return nil }
        return version
    }
    /// „Fassung für 2023“ or „Stand …“ with a caution when that is after the tax year.
    private func versionNote(_ entry: LawEntry, context: NotebookLawContext) -> VersionNote? {
        if let year = context.taxYear, let version = yearVersion(entry.id, context: context) {
            return VersionNote(text: "Fassung für \(year)", caution: false, versionID: version.id, stand: LawVersionChoice.lastChange(version)?.text)
        }
        guard let current = entry.versions.first(where: { $0.id == entry.currentVersion }) else { return nil }
        let stand = LawVersionChoice.lastChange(current)
        guard let stand else { return nil }
        if let year = context.taxYear, stand.year > year {
            return VersionNote(text: "Stand \(stand.text) – für \(year) ggf. abweichend", caution: true, versionID: nil, stand: stand.text)
        }
        return VersionNote(text: "Stand \(stand.text)", caution: false, versionID: nil, stand: stand.text)
    }

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
    private static func sameAnchor(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 2 && abs(a.minY - b.minY) < 2 && abs(a.width - b.width) < 2 && abs(a.height - b.height) < 2
    }
    static func sameCard(_ presentation: Presentation, citation: LawCitation, anchor: CGRect, pageID: UUID?) -> Bool {
        let a = presentation.anchor
        return presentation.citation == citation && presentation.pageID == pageID && !presentation.origin.isReader
            && abs(a.minX - anchor.minX) < 2 && abs(a.minY - anchor.minY) < 2 && abs(a.width - anchor.width) < 2 && abs(a.height - anchor.height) < 2
    }

    private func show(_ next: Presentation) {
        guard (next.origin.isReader ? readerScanner : scanner) != nil else { return }
        if let presentation, presentation.origin == next.origin, presentation.citation == next.citation, presentation.pageID == next.pageID,
           Self.sameAnchor(presentation.anchor, next.anchor) {
            // Same citation: follow the anchor (a pointer may replace the
            // pencil), without reloading or animating the card again.
            if presentation != next { self.presentation = next }
            return
        }
        cardHovered = false
        cardID &+= 1
        presentation = next
        load(next.citation, context: next.context, origin: next.origin)
    }

    private func load(_ citation: LawCitation, context: NotebookLawContext, origin: Origin = .page) {
        loadTask?.cancel(); loadTask = nil
        guard let laws, let entry = entry(citation.lawID) else { content = .unavailable; versionNote = nil; return }
        var note = versionNote(entry, context: context)
        // In the reader a reference into the same law stays in the version read there.
        if case let .reader(law, version) = origin, law == entry.id, version != entry.currentVersion,
           let shown = entry.versions.first(where: { $0.id == version }) {
            let stand = LawVersionChoice.lastChange(shown)?.text
            note = VersionNote(text: stand.map { "Fassung wie im Leser – Stand \($0)" } ?? "Fassung wie im Leser", caution: false, versionID: version, stand: stand)
        }
        versionNote = note
        let currentKey = "\(entry.id)|\(entry.currentVersion)"
        let reference = "|\(citation.reference.key)|\(citation.reference.paragraph ?? "")"
        var yearVersion = note?.versionID
        if let wanted = yearVersion, notOffline.contains("\(entry.id)|\(wanted)") {
            // Known not to be here: straight to the current text's caches.
            previewCurrent(entry, context: context)
            yearVersion = nil
        }
        shownVersion = yearVersion == nil ? "der aktuellen Fassung" : origin.isReader ? "dieser Fassung" : context.taxYear.map { "der Fassung für \($0)" } ?? "dieser Fassung"
        let documentKey = yearVersion.map { "\(entry.id)|\($0)" } ?? currentKey
        if let hit = excerpts[documentKey + reference] { content = hit; return }
        if let document, document.key == documentKey {
            content = remember(documentKey + reference, Self.content(document.value, citation: citation))
            return
        }
        content = .loading
        let decoding = documentTask(entry, version: yearVersion, key: documentKey, laws: laws)
        loadTask = Task { [weak self] in
            var value = await decoding.value
            guard let self, !Task.isCancelled, self.presentation?.citation == citation else { return }
            var key = documentKey
            if value == nil, yearVersion != nil {
                // The year's version is not on this iPad (only current versions
                // are kept offline): preview the current text, say so, and
                // still open the year's version (which loads it then).
                self.notOffline.insert(documentKey)
                self.previewCurrent(entry, context: context)
                self.shownVersion = "der aktuellen Fassung"
                key = currentKey
                if let hit = self.excerpts[currentKey + reference] { self.content = hit; return }
                if let document = self.document, document.key == currentKey {
                    self.content = self.remember(currentKey + reference, Self.content(document.value, citation: citation))
                    return
                }
                value = await self.documentTask(entry, version: nil, key: currentKey, laws: laws).value
                guard !Task.isCancelled, self.presentation?.citation == citation else { return }
            }
            guard let value else { self.content = .notOffline; return }
            self.content = self.remember(key + reference, Self.content(value, citation: citation))
        }
    }

    /// The wanted version is not on this iPad: the card previews the current text and says so.
    private func previewCurrent(_ entry: LawEntry, context: NotebookLawContext) {
        let stand = entry.versions.first(where: { $0.id == entry.currentVersion }).flatMap { LawVersionChoice.lastChange($0)?.text }
        let wanted = context.taxYear.map { "Fassung für \($0)" } ?? "Diese Fassung"
        versionNote?.text = "\(wanted) wird beim Öffnen geladen – Vorschau: " + (stand.map { "Stand \($0)" } ?? "aktuelle Fassung")
        versionNote?.caution = true
        versionNote?.stand = stand
    }

    private func documentTask(_ entry: LawEntry, version: String?, key: String, laws: LawLibraryModel) -> Task<LawDocument?, Never> {
        if let running = decoding[key] { return running }
        let task = Task { [weak self] () -> LawDocument? in
            let value = await laws.offlineDocument(entry, version: version)
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
        let paragraph = citation.reference.paragraph
        let found = paragraph.map { LawAbsatz.range($0, in: section.text) != nil } ?? true
        return .section(label: section.label, title: section.title, excerpt: excerpt(section.text, paragraph: found ? paragraph : nil),
                        quote: found ? quote(section.text, paragraph: paragraph) : "", absatzFound: found)
    }

    /// The whole cited Absatz, or the section's beginning without one; at
    /// most about 1500 characters, then cut after a sentence with „…“.
    static func quote(_ text: String, paragraph: String?, limit: Int = 1500) -> String {
        let source = text as NSString
        var body = text
        if let paragraph, let range = LawAbsatz.range(paragraph, in: text) { body = source.substring(with: range) }
        // Lines kept, runs of blanks folded.
        body = body.components(separatedBy: .newlines)
            .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        guard body.count > limit else { return body }
        let head = String(body.prefix(limit))
        // The last sentence end in the second half, else the last word.
        let ends = [". ", ".\n", "; ", ";\n", ": "].compactMap { head.range(of: $0, options: .backwards)?.lowerBound }
        if let end = ends.max(), head.distance(from: head.startIndex, to: end) > limit / 2 {
            return String(head[...end]) + " …"
        }
        if let space = head.lastIndex(where: \.isWhitespace) { return String(head[..<space]) + " …" }
        return head + " …"
    }

    /// The beginning of the section text, from the cited Absatz on when it is
    /// found: „(2)“ at the start of a line, else anywhere (like the reader's
    /// `jumpParagraph`). Short enough for a few lines of the card.
    static func excerpt(_ text: String, paragraph: String?) -> String {
        let source = text as NSString
        // The same Absatz as the reader's jump and the quote.
        let start = paragraph.flatMap { LawAbsatz.range($0, in: text)?.location } ?? 0
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
