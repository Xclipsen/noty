import SwiftUI
import UIKit
import NotebookCore

struct LawReaderView: View {
    /// One message wherever a section has no PDF position.
    static let noPDFPosition = "Für diese Vorschrift gibt es keine PDF-Fundstelle – der Lesetext bleibt offen."
    @EnvironmentObject var laws: LawLibraryModel
    /// State of the law window the reader may be shown in.
    @EnvironmentObject var panel: LawPanelModel
    @Environment(\.accessibilityReduceMotion) var reduceMotion
    /// Shown in the notebook's law window, which can be closed or stashed.
    var inPanel = false
    var pen = LawPenMode()
    /// Lets the reader switch what Apple Pencil does; nil hides the switch.
    var onPenChange: ((LawPenMode) -> Void)? = nil
    @StateObject var textSelection = LawTextSelection()
    /// Interface of the marking controls for subviews (LawMarkController.swift).
    @StateObject var markController = LawMarkController()
    @State var query = ""
    @State var number = ""
    @State var letters = false
    @State var selectedID = ""
    @State var versionID = ""
    @State var document: LawDocument?
    @State var sectionID = ""
    @State var pdfURL: URL?
    @State var viewPDF = false
    @State var pdfPage = 1
    @State var pdfTarget: Int?
    @State var loadError = ""
    /// The notice shown in full (tap); others stay at three lines so a long
    /// error with a URL or path cannot push the text out of a small window.
    @State var expandedNotice: String?
    /// The open section's title in full (tap); reset with the section.
    @State var titleExpanded = false
    @State var loading = false
    @State var showContents = false
    @State var showBookmarks = false
    /// `t`: the law list, otherwise the bar's law cell.
    @State var showLaws = false
    /// Keyboard mode: set while the reader has the keys.
    @State var keyPanel: KeyPanel?
    @State var inputField = HelixLawField.query
    /// Reading size of the law text, kept across sections, notebooks and
    /// launches; starts at the body size of Dynamic Type.
    @AppStorage("noty.laws.fontSize") var fontSize = LawReadingStyle.defaultFontSize
    @State var jumpParagraph: String?
    /// Counts jumps (`jump(to:)`, `restore(offset:)`): the same Absatz again scrolls again.
    @State var jumpSerial = 0
    /// A text offset to go back to (cross-reference or citation way back).
    @State var restoreOffset: CGFloat?
    /// Cross-references followed in the text, newest last („Zurück zu § 10 EStG“).
    @State var crossBack: [LawCrossBack] = []
    /// Set while `followCrossReference`/`crossReferenceBack` navigate: every
    /// other way to another place ends the cross-reference trail (`endCrossTrail`).
    @State var crossNavigating = false
    /// The citation jump being opened now (`takeCitationJump`); a newer one replaces it.
    @State var citationJumpID: UUID?
    @State var requestID = UUID()
    @FocusState var queryFocused: Bool
    /// Which input the shared search/paragraph surface shows; nil hides it
    /// (a typed search keeps it visible, see `lookupShown`).
    @State var lookupMode: LawLookupField?
    /// Asks the paragraph field to take the keyboard (counts up).
    @State var paragraphFocus = 0
    /// Sections of the open version that contain `hitTerm` (full-text search).
    @State var hits: [String] = []
    @State var hitTerm = ""
    @State var showSync = false
    /// Hint about marks in other versions that was closed for this law/version.
    @State var dismissedVersionHint = ""
    @State var lawFilter = ""
    @State var contentsFilter = ""
    /// Closed or stashed at the screen edge: no hidden field may keep the keyboard.
    var hidden: Bool { inPanel && (!panel.isOpen || panel.stashed) }
    @State private var errorsShownHere = false
    /// While the reader is visible it shows `laws.error` itself.
    private func showErrors(_ shown: Bool) {
        guard shown != errorsShownHere else { return }
        errorsShownHere = shown
        laws.inlineErrorPages += shown ? 1 : -1
    }
    var entry: LawEntry? { laws.entries.first { $0.id == selectedID } }
    var section: LawSection? { document?.sections.first { $0.id == sectionID } }
    /// The current owner's entries of the open version (B12).
    var marks: [LawPersonalItem] {
        guard let version = document?.version, !selectedID.isEmpty else { return [] }
        return laws.visibleItems(law: selectedID, version: version)
    }
    private var textMarks: [LawTextMark] {
        guard let section else { return [] }
        return marks.compactMap { item in
            guard item.kind == "annotation", case let .object(a) = item.payload["anchor"], a["sectionId"]?.string == section.id,
                  let start = a["start"]?.int, let end = a["end"]?.int, let quote = a["quote"]?.string else { return nil }
            return LawTextMark(id: item.id, anchor: LawAnchor(sectionId: section.id, start: start, end: end, quote: quote), color: item.payload["color"]?.string)
        }
    }
    var bookmarkItem: LawPersonalItem? {
        guard let section else { return nil }
        return marks.first { item in
            item.kind == "bookmark" && item.payload["sectionId"]?.string == section.id
                && item.payload["view"]?.string == (viewPDF ? "pdf" : "text") && (!viewPDF || item.payload["page"]?.int == pdfPage)
        }
    }
    var body: some View {
        VStack(spacing: 0) {
            // Erased pieces keep the body's generic type shallow (Build 131
            // stack overflow while SwiftUI built the reader's type metadata).
            AnyView(controls)
            AnyView(notices)
            AnyView(citationBack)
            if let section, let doc = document {
                AnyView(sectionHeader(section))
                ZStack(alignment: .bottom) {
                    reading(doc, section: section)
                    // Floating like the notebook's page navigator; the text keeps
                    // room for it below its last line (`LawReadingStyle.bottomInset`),
                    // the mark bar floats at the selection inside the text/PDF view.
                    footer(doc, section: section)
                }
            } else if !loading {
                emptyState
            } else {
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(uiColor: LawReadingStyle.background))
        // The reader is part of noty's dark chrome in light and dark mode alike;
        // the hosted UIKit views (text, fields, menus) follow this trait.
        .environment(\.colorScheme, .dark)
        .tint(Color.notyAccent)
        // Hover names of the reader's cells, drawn inside the reader only.
        .notyTooltipHost()
        .transformPreference(NotyTooltipKey.self) { $0 = nil }
        // A citation that opened the window comes first (B14: the reader of a
        // closed window is created only by that opening).
        .task { await laws.start(); if !(await takeCitationJump()) { await openInitial() } }
        .onChange(of: laws.citationJump?.id) { _, id in if id != nil { Task { await takeCitationJump() } } }
        .onChange(of: "\(selectedID)|\(sectionID)") { _, _ in
            citationNavigated()
            // A card of a cross-reference points into text that is gone now.
            LawCitationPreviewModel.shared.dismissReaderCard()
        }
        .onChange(of: laws.entries.count) { _, _ in Task { if !(await takeCitationJump()) { await openInitial() } } }
        .onChange(of: "\(selectedID)|\(sectionID)|\(document?.version ?? "")|\(viewPDF)|\(pdfPage)") { _, _ in
            titleExpanded = false
            rememberReading()
            if viewPDF { LawCitationPreviewModel.shared.dismissReaderCard() }
        }
        // Titles of the menu bar entries „Lesezeichen setzen/entfernen“, „PDF/Lesetext zeigen“.
        .onChange(of: [bookmarkItem != nil, viewPDF, !hidden], initial: true) { _, _ in
            if inPanel, !hidden { LawReaderMenuState.shared.update(bookmarked: bookmarkItem != nil, showsPDF: viewPDF) }
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
        .onChange(of: query) { _, value in
            // The hit list belongs to the term it was searched for.
            if value != hitTerm, !hits.isEmpty || !hitTerm.isEmpty { hits = []; hitTerm = "" }
        }
        .task(id: number) {
            // The field following the reader (arrows, contents) is no new lookup.
            guard !number.isEmpty, !showsCurrentSection(number) else { return }
            do { try await Task.sleep(for: .milliseconds(450)) } catch { return }
            await search(number, from: .number)
        }
        .onChange(of: hidden) { _, hidden in
            if hidden { queryFocused = false; textSelection.clear(); leaveKeys(); LawCitationPreviewModel.shared.dismissReaderCard() }
            showErrors(!hidden)
        }
        .onChange(of: laws.keyFocus) { _, _ in if inPanel { startKeys() } }
        .onAppear {
            showErrors(!hidden)
            // The window's reader is created only when it becomes visible (B14):
            // a focus set by ⌘L/⇧⌘L/`Space l` before that is picked up here.
            if inPanel, !hidden, LawKeyboard.shared.focused { startKeys() }
        }
        .onDisappear { showErrors(false); leaveKeys(); LawCitationPreviewModel.shared.dismissReaderCard() }
        .onAppear { connectMarkController() }
        .onChange(of: pen) { _, _ in connectMarkController() }
        .onDisappear { markController.disconnect() }
        .sheet(isPresented: $showContents) { contents.keyboardSheet().preferredColorScheme(.dark) }
        .sheet(isPresented: $showBookmarks) { bookmarks.keyboardSheet().preferredColorScheme(.dark) }
        .sheet(isPresented: $showLaws) { lawList.keyboardSheet().preferredColorScheme(.dark) }
        // Last, so the sheets above receive it as well.
        .environmentObject(markController)
    }

    /// Law text or the official PDF of the open section.
    @ViewBuilder private func reading(_ doc: LawDocument, section: LawSection) -> some View {
        if viewPDF, let pdfURL {
            NativeLawPDF(url: pdfURL, page: pdfTarget ?? section.pdf?.page ?? 1, top: pdfTarget == nil ? (section.pdf?.top ?? 0) : 0, selection: textSelection, onPage: { pdfPage = $0 },
                items: marks.filter { $0.kind == "annotation" }, pen: pen)
                .id(pdfURL)
        } else {
            NativeLawText(text: section.text, html: section.html, notes: section.notes, sectionID: section.id, fontSize: fontSize,
                marks: textMarks, jump: LawTextJump(id: jumpSerial, paragraph: jumpParagraph, offset: restoreOffset),
                selection: textSelection, pen: pen, lawID: selectedID, versionID: doc.version, hoverCards: inPanel,
                onCitation: { citation in followCrossReference(citation) },
                hasSection: { [doc] key in doc.sections.contains { $0.id == key || $0.keys.contains(key) } })
        }
    }

    /// Number and title of the open section above its text, aligned with the
    /// text, and „Lesezeichen setzen“ for this place right beside it.
    private func sectionHeader(_ section: LawSection) -> some View {
        HStack(alignment: .top, spacing: 4) {
            VStack(alignment: .leading, spacing: 3) {
                Text(section.label)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color(uiColor: LawReadingStyle.text))
                if !section.title.isEmpty {
                    // The only place with the full title: three lines, the rest on tap.
                    Text(section.title)
                        .font(.subheadline)
                        .foregroundStyle(Color(uiColor: LawReadingStyle.secondaryText))
                        .lineLimit(titleExpanded ? nil : 3)
                        .fixedSize(horizontal: false, vertical: titleExpanded)
                        .contentShape(Rectangle())
                        .onTapGesture { titleExpanded.toggle() }
                        .help(section.title)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 14)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            bookmarkButton
                .padding(.top, 4)
        }
        .padding(.leading, LawReadingStyle.textLeading).padding(.trailing, 6).padding(.bottom, 2)
    }

    /// 44 × 44 beside the heading: sets or removes the bookmark of this place
    /// (section, text or PDF page).
    private var bookmarkButton: some View {
        let set = bookmarkItem != nil
        return Button { toggleBookmark() } label: {
            Image(systemName: set ? "bookmark.fill" : "bookmark").font(.system(size: 18))
                .foregroundStyle(set ? Color.notyAccent : .white.opacity(0.85))
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .buttonStyle(NotyToolStyle())
        .environment(\.notyTooltipAxis, .horizontal)
        .accessibilityLabel("Lesezeichen")
        .accessibilityValue(set ? "gesetzt" : "nicht gesetzt")
        .accessibilityHint(set ? "Entfernt das Lesezeichen dieser Stelle" : "Merkt diese Stelle")
        .notyTooltip(keyHint(set ? "Lesezeichen entfernen" : "Lesezeichen setzen", "focus.bookmark"))
    }

    /// Loading, errors and the hint about marks in other versions: one quiet
    /// line each, never a dialog over the text.
    @ViewBuilder private var notices: some View {
        if loading {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Wird geladen …").font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }.padding(.horizontal, 16).frame(minHeight: 36)
        }
        if !loadError.isEmpty {
            notice(loadError, symbol: "exclamationmark.triangle.fill", tint: .orange, closeLabel: "Hinweis schließen") { loadError = "" }
        }
        // The app-level alert cannot appear over an open notebook: show it here.
        if let error = laws.error {
            notice(error, symbol: "exclamationmark.triangle.fill", tint: .orange, closeLabel: "Fehlermeldung schließen") { laws.error = nil }
        }
        if !loading { versionHint }
    }

    func notice(_ text: String, symbol: String, tint: Color, closeLabel: String, close: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.caption).foregroundStyle(tint).accessibilityHidden(true)
            let expanded = expandedNotice == text
            Text(text).font(.caption).foregroundStyle(.white.opacity(0.85))
                .lineLimit(expanded ? nil : 3).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .contentShape(Rectangle())
                .onTapGesture { expandedNotice = expanded ? nil : text }
                .accessibilityAction(named: expanded ? "Gekürzt zeigen" : "Ganz zeigen") { expandedNotice = expanded ? nil : text }
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).frame(width: 44, height: 44).contentShape(Rectangle())
            }.buttonStyle(NotyPressStyle()).foregroundStyle(.white.opacity(0.7)).accessibilityLabel(closeLabel)
        }
        .padding(.leading, 16).padding(.trailing, 4)
        .background(Color.white.opacity(0.05))
        .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.14)).frame(height: 0.5) }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(laws.entries.isEmpty ? "Noch keine Gesetze geladen" : "Gesetz wählen", systemImage: "books.vertical")
        } description: {
            Text(laws.entries.isEmpty ? "Unter Einstellungen › Gesetzessammlung den Offlinebestand laden." : "Ein Gesetz wählen oder zum Beispiel nach 144 HGB suchen.")
        } actions: {
            if !laws.entries.isEmpty {
                // Black on the light accent: about 12.6:1 (white on it would be 1.7:1).
                Button { showLaws = true } label: {
                    Text("Gesetz wählen").font(.body.weight(.semibold)).foregroundStyle(.black)
                        .padding(.horizontal, 20).frame(minHeight: 44)
                        .background(Color.notyAccent, in: Capsule(style: .continuous))
                        .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(NotyPressStyle())
                .notyTooltip(keyHint("Gesetz wählen", "focus.choose"))
            }
        }
        .frame(maxHeight: .infinity)
    }
}

/// Reading look of the law text: one colour for HTML and plain text, a calm
/// line height and room between paragraphs, on noty's dark reading surface.
/// The reader's chrome uses it directly; `NativeLawText` applies it to the
/// text view: background, `attributes(fontSize:)` for plain text and notes,
/// `css` for the HTML import and `apply(to:fontSize:)` on the rendered body
/// (marks only draw behind the text, see `LawMarkLayoutManager`).
enum LawReadingStyle {
    /// Reading size range (⌘+/⌘-, „…“ › Schriftgröße).
    static let fontRange: ClosedRange<Double> = 12...32
    /// Start and ⌘0: the body size of Dynamic Type plus one point (18 at the
    /// default size), within `fontRange`.
    static var defaultFontSize: Double {
        let scaled = UIFontMetrics(forTextStyle: .body).scaledValue(for: 18)
        return min(fontRange.upperBound, max(fontRange.lowerBound, scaled.rounded()))
    }
    /// noty's dark surface (`white 0.065`), also behind the reader's chrome.
    static var background: UIColor { UIColor(white: 0.065, alpha: 1) }
    /// One text colour for HTML and plain text.
    static var text: UIColor { UIColor(white: textWhite, alpha: 1) }
    static var secondaryText: UIColor { UIColor(white: 0.62, alpha: 1) }
    static let textWhite: CGFloat = 0.9
    /// Leading edge of the text in the text view (inset 12 + line fragment padding 5),
    /// so the section header lines up with the text below.
    static let textLeading: CGFloat = 17
    static let lineHeightMultiple: CGFloat = 1.28
    /// Height of the floating footer (44-pt cells, 4 pt glass padding, 10 pt
    /// to the bottom edge, which keeps it clear of the floating window's
    /// 16-pt corners); the mark overlay keeps its bar and toast above it.
    static let footerReserve: CGFloat = 44 + 2 * 4 + 10
    /// Room below the last line of text: the footer plus a mark bar placed
    /// under a selection on the last line.
    @MainActor static var bottomInset: CGFloat { footerReserve + LawMarkBar.height + 20 }
    static func paragraphSpacing(_ fontSize: Double) -> CGFloat { CGFloat(fontSize) * 0.55 }

    /// CSS for the HTML import: the same colour as the plain text.
    static var css: String {
        let hex = String(format: "%02X", Int((textWhite * 255).rounded()))
        return "body{font-family:-apple-system;font-size:17px;color:#\(hex)\(hex)\(hex)}"
            + "table{border-collapse:collapse}td,th{border:1px solid #555;padding:4px;vertical-align:top}"
    }
    static func paragraphStyle(_ fontSize: Double, base: NSParagraphStyle? = nil) -> NSParagraphStyle {
        let style = (base?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
        style.lineHeightMultiple = lineHeightMultiple
        style.paragraphSpacing = max(style.paragraphSpacing, paragraphSpacing(fontSize))
        return style
    }
    /// Attributes of plain section text and notes.
    static func attributes(fontSize: Double) -> [NSAttributedString.Key: Any] {
        [.font: UIFont.systemFont(ofSize: fontSize), .foregroundColor: text, .paragraphStyle: paragraphStyle(fontSize)]
    }
    /// Gives rendered text (HTML or plain) the reading colour and spacing,
    /// keeping the indents and alignment of the imported paragraph styles.
    static func apply(to string: NSMutableAttributedString, fontSize: Double) {
        let all = NSRange(location: 0, length: string.length)
        string.addAttribute(.foregroundColor, value: text, range: all)
        string.enumerateAttribute(.paragraphStyle, in: all) { value, range, _ in
            string.addAttribute(.paragraphStyle, value: paragraphStyle(fontSize, base: value as? NSParagraphStyle), range: range)
        }
    }
}
