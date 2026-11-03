import SwiftUI
import UIKit
import NotebookCore

// Reader chrome in the grammar of `EditorToolOptions`: 44-pt cells, white
// 18-pt symbols, the common selection plate, thin group dividers, hover names.
// One bar instead of several rows; only when the window is too narrow the
// Apple Pencil group moves to a second row. Search and paragraph share one
// input surface that appears on demand.

extension LawReaderView {
    var controls: some View {
        VStack(spacing: 0) {
            toolRows
            if let mode = lookupShown {
                lookupSurface(mode)
                    .padding(.horizontal, 8).padding(.bottom, 8)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
            }
        }
        .font(.system(size: 13, weight: .medium))
        .buttonStyle(NotyToolStyle())
        .foregroundStyle(.white)
        .environment(\.notyTooltipAxis, .horizontal)
        .background(Color(white: 0.1))
        .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.14)).frame(height: 0.5).accessibilityHidden(true) }
        .animation(NotyMotion.panel(reduceMotion), value: lookupShown)
    }

    /// One row when everything fits, otherwise reading tools and the Apple
    /// Pencil group in two rows; each row scrolls sideways if still too narrow.
    @ViewBuilder private var toolRows: some View {
        if let onPenChange {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Self.cellSpacing) {
                    readingTools
                    NotyGroupDivider()
                    penTools(onPenChange)
                    Spacer(minLength: 0)
                    statusTools
                }.frame(height: 44).padding(.horizontal, 6).padding(.vertical, 4)
                VStack(spacing: 0) {
                    HStack(spacing: 2) { scrolling { readingTools }; statusTools }
                    scrolling { penTools(onPenChange) }
                }.padding(.horizontal, 6).padding(.vertical, 4)
            }
        } else {
            HStack(spacing: 2) { scrolling { readingTools }; statusTools }
                .padding(.horizontal, 6).padding(.vertical, 4)
        }
    }
    static var cellSpacing: CGFloat { EditorToolOptions.itemSpacing }

    private func scrolling<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Self.cellSpacing) { content() }.frame(height: 44).fixedSize()
        }.scrollBounceBehavior(.basedOnSize)
    }

    /// Law | contents | search, paragraph | text/PDF, bookmark, list | font size.
    @ViewBuilder private var readingTools: some View {
        // The one place to choose a law (also `t` and the empty reader).
        Button { showLaws = true } label: {
            HStack(spacing: 6) {
                Image(systemName: "books.vertical").font(.system(size: 18))
                Text(entry?.abbr ?? "Gesetz").lineLimit(1)
            }.padding(.horizontal, 8).frame(minHeight: 44).contentShape(Rectangle())
        }
        .accessibilityLabel(entry.map { "Gesetz wählen, geöffnet: \($0.abbr)" } ?? "Gesetz wählen")
        .notyTooltip(entry.map { "\($0.name) – anderes Gesetz wählen" } ?? "Gesetz wählen")
        cell("Inhaltsverzeichnis", symbol: "list.bullet.indent", help: "Inhaltsverzeichnis – alle Vorschriften", enabled: document != nil) {
            showContents = true
        }
        NotyGroupDivider()
        cell("Im Gesetz suchen", symbol: "magnifyingglass", selected: lookupShown == .query, help: "Suchen – Begriff oder Fundstelle wie 144 HGB") {
            toggleLookup(.query)
        }
        enable(document != nil) {
            NotyGlyphOption("Vorschrift aufrufen", selected: lookupShown == .number, help: "Paragraph – Nummer der Vorschrift eingeben") {
                toggleLookup(.number)
            } glyph: { Text("§").font(.system(size: 21, weight: .medium)) }
        }
        NotyGroupDivider()
        cell(viewPDF ? "Lesetext zeigen" : "Original-PDF zeigen", symbol: "doc.richtext", selected: viewPDF,
             help: viewPDF ? "Lesetext – zurück zum Text" : "PDF – amtliche Seite zeigen", enabled: document != nil) {
            Task { await togglePDF() }
        }
        cell(bookmarkItem == nil ? "Lesezeichen setzen" : "Lesezeichen entfernen", symbol: bookmarkItem == nil ? "bookmark" : "bookmark.fill",
             selected: bookmarkItem != nil, help: bookmarkItem == nil ? "Lesezeichen – diese Stelle merken" : "Lesezeichen entfernen",
             enabled: section != nil) { toggleBookmark() }
        cell("Lesezeichen und Markierungen", symbol: "list.star", help: "Liste – Lesezeichen und Markierungen") { showBookmarks = true }
        NotyGroupDivider()
        // Directly in the bar, not in a menu: several taps in a row stay quick.
        cell("Schrift kleiner", symbol: "textformat.size.smaller", help: "Schrift kleiner", enabled: !viewPDF && fontSize > 12) {
            fontSize = max(12, fontSize - 2)
        }
        cell("Schrift größer", symbol: "textformat.size.larger", help: "Schrift größer", enabled: !viewPDF && fontSize < 32) {
            fontSize = min(32, fontSize + 2)
        }
    }

    /// What Apple Pencil does in the law text and PDF, as tool cells, and the
    /// highlighter colour as dots. Fingers always scroll and select; choosing
    /// the highlighter or an eraser in the notebook switches along.
    @ViewBuilder private func penTools(_ change: @escaping (LawPenMode) -> Void) -> some View {
        let set = { (kind: LawPenMode.Kind) in var next = pen; next.kind = kind; change(next) }
        HStack(spacing: Self.cellSpacing) {
            NotyGlyphOption("Apple Pencil liest", selected: pen.kind == .none, help: "Lesen – Stift scrollt und wählt aus") { set(.none) } glyph: {
                ToolbarGlyph(tool: .read, selected: pen.kind == .none)
            }
            NotyGlyphOption("Apple Pencil markiert", selected: pen.kind == .marker, help: "Markieren – Stift markiert in der gewählten Farbe") { set(.marker) } glyph: {
                ToolbarGlyph(tool: .marker, selected: pen.kind == .marker, ink: Color(lawMarkColor(pen.hex)))
            }
            NotyGlyphOption("Apple Pencil radiert", selected: pen.kind == .eraser, help: "Radieren – Stift entfernt Markierungen") { set(.eraser) } glyph: {
                ToolbarGlyph(tool: .strokeEraser, selected: pen.kind == .eraser)
            }
            NotyGroupDivider()
            ForEach(LawPenMode.presets, id: \.name) { preset in
                let hex = LawPenMode(color: preset.color).hex
                // A colour choice switches to marking.
                NotySwatch(Color(lawMarkColor(hex)), selected: pen.hex == hex, title: "Markierfarbe \(preset.name)") {
                    var next = pen; next.color = preset.color; next.kind = .marker; change(next)
                }
            }
        }
        .accessibilityElement(children: .contain).accessibilityLabel("Apple Pencil")
    }

    /// Sync status and the overflow menu stay visible at the end of the first row.
    private var statusTools: some View {
        HStack(spacing: 0) {
            syncButton
            moreMenu
        }
    }

    // MARK: Sync status

    /// Small status mark instead of a text line in the menu (B9).
    private var syncButton: some View {
        let look = LawSyncLook(markController.syncBadge)
        return Button { showSync = true } label: {
            HStack(spacing: 2) {
                Image(systemName: look.symbol).font(.system(size: 13, weight: .semibold))
                if let count = look.count { Text("\(count)").font(.caption2.monospacedDigit().weight(.semibold)) }
            }
            .foregroundStyle(look.tint)
            .frame(minWidth: 36, minHeight: 44).contentShape(Rectangle())
        }
        .accessibilityLabel("Abgleich: \(look.title)")
        .accessibilityHint("Zeigt Einzelheiten")
        .notyTooltip(look.title)
        .popover(isPresented: $showSync, arrowEdge: .top) { syncDetails(look) }
    }

    private func syncDetails(_ look: LawSyncLook) -> some View {
        let canSync = laws.user != nil && !laws.sessionExpired && laws.syncEnabled
        return VStack(alignment: .leading, spacing: 12) {
            Label { Text(look.title) } icon: { Image(systemName: look.symbol).foregroundStyle(look.tint) }.font(.headline)
            if let user = laws.user, !laws.sessionExpired {
                Text("Angemeldet als \(user.email ?? user.name)").font(.subheadline)
            }
            Text(markController.syncBadge.detail).font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !canSync {
                // Marking never needs an account; the account only syncs.
                Text("Markieren braucht kein Konto. Zum Abgleich unter Einstellungen › Konto anmelden.")
                    .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                Button { Task { await laws.synchronize() } } label: {
                    Label("Jetzt synchronisieren", systemImage: "arrow.triangle.2.circlepath").frame(minHeight: 44)
                }
                .buttonStyle(.bordered).disabled(laws.syncing)
                if markController.syncBadge.status.rejected > 0 {
                    Button { Task { await laws.retryRejected() } } label: {
                        Label("Abgelehnte erneut versuchen", systemImage: "arrow.clockwise").frame(minHeight: 44)
                    }
                    .buttonStyle(.bordered).disabled(laws.syncing)
                    Text("Einzelne Einträge „Nur lokal behalten“: Einstellungen › Gesetzessammlung.")
                        .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(20).frame(width: 320, alignment: .leading)
        .presentationCompactAdaptation(.popover)
        .preferredColorScheme(.dark)
    }

    // MARK: Overflow

    /// Versions as a section with a check mark and the official source.
    /// Undo of marks: the toast, ⌘Z/⇧⌘Z and Helix `u`/`U` (own stack).
    private var moreMenu: some View {
        Menu {
            if let entry, !entry.versions.isEmpty {
                Section("Fassung") {
                    ForEach(entry.versions) { version in
                        Button {
                            guard version.id != document?.version else { return }
                            Task { await open(entry, version: version.id, target: sectionID, resume: true) }
                        } label: {
                            let title = versionTitle(version.id) + (version.id == entry.currentVersion ? " (aktuell)" : "")
                            if version.id == document?.version { Label(title, systemImage: "checkmark") } else { Text(title) }
                        }
                    }
                }
            }
            if let doc = document, let source = URL(string: doc.sourceUrl), source.scheme == "https" {
                Section { Link(destination: source) { Label("Amtliche Quelle öffnen", systemImage: "safari") } }
            }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 18)).frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .accessibilityLabel("Weitere Optionen")
        .notyTooltip("Fassung und weitere Optionen")
    }
    /// Display name of a version of the open law.
    func versionTitle(_ id: String) -> String {
        if let version = entry?.versions.first(where: { $0.id == id }), let status = version.status.last, !status.isEmpty { return status }
        if id == document?.version, let status = document?.status.last, !status.isEmpty { return status }
        return id
    }

    // MARK: Cells

    private func cell(_ title: String, symbol: String, selected: Bool = false, help: String, enabled: Bool = true,
                      action: @escaping () -> Void) -> some View {
        enable(enabled) { NotySymbolOption(title, symbol: symbol, selected: selected, help: help, action: action) }
    }
    /// Custom button styles are not dimmed by the system when disabled.
    private func enable<Content: View>(_ enabled: Bool, @ViewBuilder _ content: () -> Content) -> some View {
        content().disabled(!enabled).opacity(enabled ? 1 : 0.35)
    }

    // MARK: Search and paragraph

    /// A typed search keeps the surface open (also when typed via the keys).
    var lookupShown: LawLookupField? { lookupMode ?? (query.isEmpty ? nil : .query) }

    /// Opens the surface in the given mode with the keyboard, or closes it.
    func toggleLookup(_ mode: LawLookupField) {
        if lookupShown == mode { closeLookup() } else { openLookup(mode) }
    }
    /// ⌘F, ⌘L and the Helix `/` open `.query` (`focusQuickSearch`), the
    /// paragraph field `.number`; both share this surface.
    func openLookup(_ mode: LawLookupField) {
        lookupMode = mode
        if mode == .query {
            // After the field exists in the hierarchy.
            DispatchQueue.main.async { queryFocused = true }
        } else {
            queryFocused = false
            paragraphFocus += 1
        }
    }
    /// Closing the search clears it; the paragraph field keeps following the reader.
    func closeLookup() {
        queryFocused = false
        if lookupShown == .query { query = "" }
        lookupMode = nil
    }

    private func lookupSurface(_ mode: LawLookupField) -> some View {
        HStack(spacing: 2) {
            // Lupe or §: shows the mode and switches to the other one.
            Button { openLookup(mode == .query ? .number : .query) } label: {
                Group {
                    if mode == .query { Image(systemName: "magnifyingglass").font(.system(size: 16, weight: .medium)) }
                    else { Text("§").font(.system(size: 18, weight: .semibold)) }
                }
                .foregroundStyle(.white.opacity(0.7)).frame(width: 36, height: 44).contentShape(Rectangle())
            }
            .accessibilityLabel(mode == .query ? "Suche, zur Paragrapheingabe wechseln" : "Paragraph, zur Suche wechseln")
            .notyTooltip(mode == .query ? "Zur Paragrapheingabe" : "Zur Suche")
            if mode == .query {
                TextField("Suchen oder 144 HGB", text: $query)
                    .font(.body).foregroundStyle(.white)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().submitLabel(.search)
                    .focused($queryFocused)
                    .onSubmit { Task { await submitQuery() } }
                    .frame(maxWidth: .infinity, minHeight: 44)
                if !hits.isEmpty { hitStepper }
                if !query.isEmpty {
                    Button { query = ""; queryFocused = true } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 15)).foregroundStyle(.white.opacity(0.5))
                            .frame(width: 36, height: 44).contentShape(Rectangle())
                    }.accessibilityLabel("Suche leeren")
                }
            } else {
                LawParagraphField(placeholder: entry?.kind == "administration" ? "Abschnitt / R" : "Paragraph", text: $number, letters: letters,
                                  active: !hidden, focus: paragraphFocus) {
                    Task { await search(number, allowFullText: true, from: .number) }
                }
                // A UITextField otherwise takes all offered height and pushes
                // the law text down.
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 44)
                Button { letters.toggle() } label: {
                    Text(letters ? "123" : "abc").font(.system(size: 13, weight: .semibold))
                        .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                }
                .accessibilityLabel(letters ? "Zahlentastatur" : "Texttastatur für Zusätze und Absätze")
                .notyTooltip(letters ? "Zahlentastatur" : "Texttastatur – für 4a oder 4 Abs. 2")
            }
            Button { closeLookup() } label: {
                Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.7))
                    .frame(width: 40, height: 44).contentShape(Rectangle())
            }
            .accessibilityLabel(mode == .query ? "Suche schließen" : "Paragrapheingabe schließen")
            .notyTooltip("Schließen")
        }
        .padding(.leading, 2)
        .frame(minHeight: 44)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
    }

    /// Previous/next section with the searched words and where the reader is among them.
    private var hitStepper: some View {
        let position = hits.firstIndex(of: sectionID)
        return HStack(spacing: 0) {
            Button { stepHit(-1) } label: {
                Image(systemName: "chevron.up").font(.system(size: 14, weight: .semibold)).frame(width: 36, height: 44).contentShape(Rectangle())
            }.accessibilityLabel("Vorheriger Treffer").notyTooltip("Vorheriger Treffer")
            Text(position.map { "\($0 + 1)/\(hits.count)" } ?? "\(hits.count)")
                .font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.7)).fixedSize()
                .accessibilityLabel(position.map { "Treffer \($0 + 1) von \(hits.count)" } ?? "\(hits.count) Treffer")
            Button { stepHit(1) } label: {
                Image(systemName: "chevron.down").font(.system(size: 14, weight: .semibold)).frame(width: 36, height: 44).contentShape(Rectangle())
            }.accessibilityLabel("Nächster Treffer").notyTooltip("Nächster Treffer")
        }
    }

    // MARK: Footer

    /// Glass navigator like the notebook's page navigator: previous/next
    /// section, where the reader is and which version. Tapping the middle
    /// opens the contents.
    func footer(_ doc: LawDocument, section: LawSection) -> some View {
        let index = doc.sections.firstIndex { $0.id == section.id } ?? 0
        let previous = doc.sections.indices.contains(index - 1) ? doc.sections[index - 1] : nil
        let next = doc.sections.indices.contains(index + 1) ? doc.sections[index + 1] : nil
        let older = doc.version != entry?.currentVersion
        let version = versionTitle(doc.version)
        return HStack(spacing: 2) {
            Button { move(-1) } label: {
                Image(systemName: "chevron.left").font(.system(size: 17, weight: .semibold)).frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .disabled(previous == nil)
            .foregroundStyle(previous == nil ? Color.gray.opacity(0.5) : .white)
            .accessibilityLabel(previous.map { "Vorherige Vorschrift: \($0.label)" } ?? "Keine vorherige Vorschrift")
            .notyTooltip(previous.map { "Zurück – \($0.label)" } ?? "Anfang")
            Button { showContents = true } label: {
                VStack(spacing: 1) {
                    Text(section.label).font(.caption.weight(.semibold)).foregroundStyle(.white).lineLimit(1)
                    HStack(spacing: 4) {
                        Text(version).lineLimit(1)
                        if older { Text("Ältere Fassung").foregroundStyle(.orange).fixedSize() }
                        Text("\(index + 1)/\(doc.sections.count)").monospacedDigit().fixedSize()
                    }.font(.caption).foregroundStyle(.white.opacity(0.6))
                }
                .padding(.horizontal, 6).frame(minWidth: 110, maxWidth: 230, minHeight: 44).contentShape(Rectangle())
            }
            .accessibilityLabel("\(section.label), Vorschrift \(index + 1) von \(doc.sections.count), Fassung \(version)\(older ? ", ältere Fassung" : "")")
            .accessibilityHint("Öffnet das Inhaltsverzeichnis")
            .notyTooltip("Inhaltsverzeichnis")
            Button { move(1) } label: {
                Image(systemName: "chevron.right").font(.system(size: 17, weight: .semibold)).frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .disabled(next == nil)
            .foregroundStyle(next == nil ? Color.gray.opacity(0.5) : .white)
            .accessibilityLabel(next.map { "Nächste Vorschrift: \($0.label)" } ?? "Keine nächste Vorschrift")
            .notyTooltip(next.map { "Weiter – \($0.label)" } ?? "Ende")
        }
        .padding(4).notyGlass()
        .buttonStyle(NotyToolStyle())
        .environment(\.notyTooltipAxis, .horizontal)
        .padding(.horizontal, 10).padding(.bottom, 10)
    }
    func move(_ direction: Int) {
        guard let sections = document?.sections, let i = sections.firstIndex(where: { $0.id == sectionID }), sections.indices.contains(i + direction) else { return }
        showSection(sections[i + direction])
    }
    /// Shows another section of the open version (arrows, contents, hits).
    func showSection(_ shown: LawSection, from field: LawLookupField? = nil) {
        textSelection.clear()
        pdfTarget = nil; sectionID = shown.id; jumpParagraph = nil; loadError = ""
        follow(shown, from: field)
        // Without a PDF position the PDF view would silently fall back to page 1.
        if viewPDF, shown.pdf == nil {
            viewPDF = false; loadError = "Keine PDF-Fundstelle für diese Vorschrift; der Lesetext wird angezeigt."
        }
    }
    /// Both fields describe where the reader is. After arrows, contents,
    /// bookmarks or another law the paragraph field shows the new section's
    /// number and a quick-search location that no longer applies is cleared;
    /// the field a lookup was typed into keeps its input (e.g. „4 Abs. 2“).
    func follow(_ shown: LawSection?, from field: LawLookupField? = nil) {
        if field != .number { number = shown?.keys.first ?? "" }
        if field != .query, !query.isEmpty,
           LawQuickTarget.parse(query, entries: laws.entries) != nil || LawReference.parse(query) != nil { query = "" }
    }
    /// `value` names the shown section without a paragraph, so a lookup would
    /// change nothing (in particular the paragraph field following the reader).
    func showsCurrentSection(_ value: String) -> Bool {
        guard let section, let ref = LawReference.parse(value), ref.paragraph == nil else { return false }
        return section.keys.contains(ref.key)
    }

    // MARK: Marks in other versions (B10)

    /// „n Markierungen in Fassung … – anzeigen“ while the open version is
    /// another one than where marks of this law were made.
    @ViewBuilder var versionHint: some View {
        if let entry, let doc = document {
            // The current owner's marks per version in catalogue order (B10, B12);
            // only versions the catalogue can still open.
            let others = laws.markCounts(law: entry.id)
                .filter { other in other.versionId != doc.version && other.count > 0 && entry.versions.contains { $0.id == other.versionId } }
            let total = others.reduce(0) { $0 + $1.count }
            let key = "\(entry.id)|\(doc.version)|\(others.map { "\($0.versionId):\($0.count)" }.joined(separator: ","))"
            if total > 0, dismissedVersionHint != key {
                let count = total == 1 ? "1 Markierung" : "\(total) Markierungen"
                let text = others.count == 1 ? "\(count) in Fassung \(versionTitle(others[0].versionId))" : "\(count) in \(others.count) anderen Fassungen"
                let label = HStack(spacing: 8) {
                    Image(systemName: "highlighter").font(.caption).foregroundStyle(Color.notyAccent).accessibilityHidden(true)
                    Text("\(text) – \(Text("anzeigen").foregroundStyle(Color.notyAccent).fontWeight(.semibold))")
                        .font(.caption).foregroundStyle(.white.opacity(0.85))
                        .frame(maxWidth: .infinity, alignment: .leading).multilineTextAlignment(.leading)
                }.frame(minHeight: 36).contentShape(Rectangle())
                HStack(spacing: 4) {
                    if others.count == 1 {
                        Button { Task { await open(entry, version: others[0].versionId, target: sectionID, resume: true) } } label: { label }
                            .accessibilityLabel(text).accessibilityHint("Öffnet diese Fassung an derselben Vorschrift")
                    } else {
                        Menu {
                            ForEach(others, id: \.versionId) { other in
                                Button("\(versionTitle(other.versionId)) · \(other.count)") {
                                    Task { await open(entry, version: other.versionId, target: sectionID, resume: true) }
                                }
                            }
                        } label: { label }
                            .accessibilityLabel(text).accessibilityHint("Fassung wählen")
                    }
                    Button { dismissedVersionHint = key } label: {
                        Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).frame(width: 44, height: 36).contentShape(Rectangle())
                    }.foregroundStyle(.white.opacity(0.7)).accessibilityLabel("Hinweis ausblenden")
                }
                .buttonStyle(NotyPressStyle())
                .padding(.leading, 16).padding(.trailing, 4).padding(.vertical, 2)
                .background(Color.notyAccent.opacity(0.08))
                .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.14)).frame(height: 0.5) }
            }
        }
    }
}

/// Symbol, colour and name of the sync status mark.
struct LawSyncLook {
    var symbol: String
    var tint: Color
    var title: String
    var count: Int?
    /// From the data package's structured state (`LawSyncStatus`), never from its text.
    init(_ badge: LawMarkSyncBadge) {
        let status = badge.status
        switch status.state {
        case .guest:
            symbol = "ipad"; tint = .white.opacity(0.55); title = "Nur auf diesem iPad"
        case .paused:
            symbol = "pause.circle"; tint = .white.opacity(0.55); title = "Abgleich aus – bleibt auf diesem iPad"
        case .expired:
            symbol = "exclamationmark.triangle.fill"; tint = .orange; title = "Anmeldung abgelaufen"
        case .failed:
            symbol = "exclamationmark.triangle.fill"; tint = .orange; title = "Abgleich gestört"
        case .rejected:
            symbol = "exclamationmark.triangle.fill"; tint = .orange; count = status.rejected
            title = status.rejected == 1 ? "1 Eintrag abgelehnt" : "\(status.rejected) Einträge abgelehnt"
        case .syncing:
            symbol = "arrow.triangle.2.circlepath"; tint = .white.opacity(0.75); title = "Wird synchronisiert"
        case .pending:
            symbol = "arrow.up"; tint = .notyAccent; count = status.pending > 0 ? status.pending : nil
            title = status.pending == 0 ? "Noch nicht synchronisiert"
                : status.pending == 1 ? "1 Änderung noch nicht synchronisiert" : "\(status.pending) Änderungen noch nicht synchronisiert"
        case .synced:
            symbol = "checkmark"; tint = .green; title = "Synchronisiert"
        }
    }
}

private struct LawParagraphField: UIViewRepresentable {
    var placeholder: String
    @Binding var text: String
    var letters: Bool
    var active: Bool
    /// Each increase asks the field to take the keyboard.
    var focus: Int
    var submit: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UITextField {
        let field = UITextField(); field.delegate = context.coordinator
        field.autocorrectionType = .no; field.autocapitalizationType = .none
        field.returnKeyType = .search
        field.font = .preferredFont(forTextStyle: .body); field.adjustsFontForContentSizeCategory = true
        field.textColor = .white
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.addTarget(context.coordinator, action: #selector(Coordinator.changed), for: .editingChanged)
        let bar = UIToolbar(); bar.sizeToFit()
        bar.items = [UIBarButtonItem(systemItem: .flexibleSpace), UIBarButtonItem(title: "Suchen", style: .done, target: context.coordinator, action: #selector(Coordinator.search))]
        field.inputAccessoryView = bar
        return field
    }
    func updateUIView(_ field: UITextField, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        field.attributedPlaceholder = NSAttributedString(string: placeholder, attributes: [.foregroundColor: UIColor(white: 1, alpha: 0.4)])
        if field.text != text { field.text = text }
        let type: UIKeyboardType = letters ? .default : .numberPad
        if field.keyboardType != type { field.keyboardType = type; if field.isFirstResponder { field.reloadInputViews() } }
        if !active, field.isFirstResponder { field.resignFirstResponder() }
        if coordinator.focus != focus {
            coordinator.focus = focus
            if active { DispatchQueue.main.async { if field.window != nil { field.becomeFirstResponder() } } }
        }
    }
    @MainActor
    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: LawParagraphField
        /// The field's first request is the one it was created with.
        var focus: Int
        init(_ parent: LawParagraphField) { self.parent = parent; focus = parent.focus - 1 }
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
