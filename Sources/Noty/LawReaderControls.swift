import SwiftUI
import UIKit
import NotebookCore

// Reader chrome in the grammar of `EditorToolOptions`: 44-pt cells, white
// 18-pt symbols, the common selection plate, thin group dividers, hover names.
// First row: law · contents | search (one cell; the input surface switches
// between words and §) · PDF · list, then the sync mark (only when something
// needs doing) and „…“ (font size, undo of marks, version, details). The
// bookmark sits next to the section heading. When the window is too narrow
// the Apple Pencil group moves to a second row; a row that still overflows
// scrolls sideways under a 16-pt fade.

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
    /// Pencil group in two rows. The first row fits about 380 pt (420 with
    /// the sync mark); the Pencil row fits 320 pt with compact dots and
    /// switches to a colour menu below that.
    @ViewBuilder private var toolRows: some View {
        if let onPenChange {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Self.cellSpacing) {
                    readingTools
                    NotyGroupDivider()
                    penTools(onPenChange, swatches: .full)
                    Spacer(minLength: 0)
                    statusTools
                }.frame(height: 44).padding(.horizontal, 6).padding(.vertical, 4)
                VStack(spacing: 0) {
                    HStack(spacing: 2) { LawFadingScroll { readingTools }; statusTools }
                    ViewThatFits(in: .horizontal) {
                        penRow(onPenChange, swatches: .full)
                        penRow(onPenChange, swatches: .compact)
                        penRow(onPenChange, swatches: .menu)
                    }
                }.padding(.horizontal, 6).padding(.vertical, 4)
            }
        } else {
            HStack(spacing: 2) { LawFadingScroll { readingTools }; statusTools }
                .padding(.horizontal, 6).padding(.vertical, 4)
        }
    }
    static var cellSpacing: CGFloat { EditorToolOptions.itemSpacing }

    private func penRow(_ change: @escaping (LawPenMode) -> Void, swatches: LawSwatchLayout) -> some View {
        HStack(spacing: 0) { penTools(change, swatches: swatches); Spacer(minLength: 0) }.frame(height: 44)
    }

    /// „Name (⌘D)“: hover names carry the shortcut of the law focus.
    func keyHint(_ text: String, _ id: String) -> String {
        guard let keys = LawShortcuts.shortcut(id: id)?.combo?.label else { return text }
        return "\(text) (\(keys))"
    }

    /// Law · contents | search · PDF · list.
    @ViewBuilder private var readingTools: some View {
        // The one place to choose a law (also ⌘T and the empty reader).
        Button { showLaws = true } label: {
            HStack(spacing: 6) {
                Image(systemName: "books.vertical").font(.system(size: 18))
                Text(Self.shortAbbr(entry?.abbr ?? "Gesetz")).lineLimit(1).fixedSize()
            }.padding(.horizontal, 8).frame(minHeight: 44).contentShape(Rectangle())
        }
        .accessibilityLabel("Gesetz wählen")
        .accessibilityValue(entry?.abbr ?? "keines gewählt")
        .notyTooltip(keyHint(entry.map { "\($0.name) – anderes Gesetz wählen" } ?? "Gesetz wählen", "focus.choose"))
        cell("Inhaltsverzeichnis", symbol: "list.bullet.indent", help: keyHint("Inhaltsverzeichnis", "focus.contents"), enabled: document != nil) {
            showContents = true
        }
        NotyGroupDivider()
        // Words, a citation like 144 HGB or a § number: one cell, the surface switches.
        cell("Suchen", symbol: "magnifyingglass", selected: lookupShown != nil,
             help: keyHint("Suchen – Begriff, Fundstelle oder §", "focus.find")) {
            if lookupShown != nil { closeLookup() } else { openLookup(.query) }
        }
        cell("Original-PDF", symbol: "doc.richtext", selected: viewPDF,
             help: keyHint(viewPDF ? "Lesetext zeigen" : "PDF zeigen", "focus.view"), enabled: document != nil) {
            Task { await togglePDF() }
        }
        cell("Lesezeichen und Markierungen", symbol: "list.star", help: keyHint("Liste – Lesezeichen und Markierungen", "focus.list")) {
            showBookmarks = true
        }
    }
    /// Long abbreviations would push the row past 380 pt.
    static func shortAbbr(_ abbr: String) -> String { abbr.count > 8 ? String(abbr.prefix(7)) + "…" : abbr }

    /// What Apple Pencil does in the law text and PDF, as tool cells, and the
    /// highlighter colour as dots (narrower dots or a menu in a narrow
    /// window). Fingers always scroll and select; choosing the highlighter or
    /// an eraser in the notebook switches along.
    @ViewBuilder private func penTools(_ change: @escaping (LawPenMode) -> Void, swatches: LawSwatchLayout) -> some View {
        let set = { (kind: LawPenMode.Kind) in var next = pen; next.kind = kind; change(next) }
        // A colour choice switches to marking.
        let choose = { (color: InkColor) in var next = pen; next.color = color; next.kind = .marker; change(next) }
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
            switch swatches {
            case .full, .compact:
                HStack(spacing: 0) {
                    ForEach(LawPenMode.presets, id: \.name) { preset in
                        let hex = LawPenMode(color: preset.color).hex
                        if swatches == .full {
                            NotySwatch(Color(lawMarkColor(hex)), selected: pen.hex == hex, title: "Markierfarbe \(preset.name)") { choose(preset.color) }
                        } else {
                            LawCompactSwatch(color: Color(lawMarkColor(hex)), selected: pen.hex == hex, title: "Markierfarbe \(preset.name)") { choose(preset.color) }
                        }
                    }
                }
            case .menu:
                Menu {
                    ForEach(LawPenMode.presets, id: \.name) { preset in
                        let hex = LawPenMode(color: preset.color).hex
                        Button { choose(preset.color) } label: {
                            Label { Text(preset.name) } icon: { Image(uiImage: lawMarkSwatchImage(hex)) }
                            if pen.hex == hex { Text("Gewählt") }
                        }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Circle().fill(Color(lawMarkColor(pen.hex))).frame(width: 20, height: 20)
                            .overlay(Circle().strokeBorder(.white.opacity(0.3), lineWidth: 1))
                        Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.7))
                    }.frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                }
                .accessibilityLabel("Markierfarbe")
                .accessibilityValue(LawPenMode.presets.first { LawPenMode(color: $0.color).hex == pen.hex }?.name ?? "")
                .notyTooltip("Markierfarbe")
            }
        }
        .accessibilityElement(children: .contain).accessibilityLabel("Apple Pencil")
    }

    /// The sync mark (only when something needs doing) and „…“ at the end of
    /// the first row; the details open from either.
    private var statusTools: some View {
        HStack(spacing: 0) {
            if syncMarkShown { syncButton }
            moreMenu
        }
        .popover(isPresented: $showSync, arrowEdge: .top) { syncDetails(LawSyncLook(markController.syncBadge)) }
    }

    // MARK: Sync status

    /// Guest, paused and synced need nothing: no mark. Waiting changes,
    /// a run that sends them, errors and refusals show one.
    var syncMarkShown: Bool {
        let status = markController.syncBadge.status
        switch status.state {
        case .guest, .paused, .synced: return false
        case .pending, .syncing: return status.pending > 0
        case .expired, .failed, .rejected: return true
        }
    }

    /// Small status mark instead of a text line in the menu (B9).
    private var syncButton: some View {
        let look = LawSyncLook(markController.syncBadge)
        return Button { showSync = true } label: {
            HStack(spacing: 2) {
                Image(systemName: look.symbol).font(.system(size: 15, weight: .semibold))
                    .symbolEffect(.pulse, isActive: look.running && !reduceMotion)
                if let count = look.count { Text("\(count)").font(.caption2.monospacedDigit().weight(.semibold)) }
            }
            .foregroundStyle(look.tint)
            .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
        }
        .accessibilityLabel("Abgleich")
        .accessibilityValue(look.title)
        .accessibilityHint("Zeigt Einzelheiten")
        .notyTooltip(look.title)
    }

    /// One heading, one cause, one step per state; never a server code.
    private func syncDetails(_ look: LawSyncLook) -> some View {
        let status = markController.syncBadge.status
        let account = laws.user.map { "Angemeldet als \($0.email ?? $0.name)" }
        let canSync = laws.user != nil && !laws.sessionExpired && laws.syncEnabled
        let cause: String, step: String?
        var action: (title: String, symbol: String, run: () async -> Void)?
        let sync = { [laws] in await laws.synchronize() }
        switch status.state {
        case .guest:
            cause = "Ohne Konto bleiben Lesezeichen und Markierungen auf diesem iPad."
            step = "Zum Abgleichen unter Einstellungen › Konto anmelden."
        case .paused:
            cause = "Lesezeichen und Markierungen bleiben so lange auf diesem iPad."
            step = "Einschalten unter Einstellungen › Gesetzessammlung."
        case .expired:
            cause = "Änderungen bleiben auf diesem iPad und werden später gesendet."
            step = "Unter Einstellungen › Konto erneut anmelden."
        case .failed:
            cause = "Änderungen bleiben auf diesem iPad und werden später gesendet."
            step = nil; action = ("Erneut abgleichen", "arrow.clockwise", sync)
        case .syncing:
            cause = status.pending > 0 ? "\(NotyText.count(status.pending, "Änderung", "Änderungen")) werden gesendet." : (account ?? "Wird mit dem Konto abgeglichen.")
            step = nil
        case .pending:
            cause = status.pending > 0 ? "Sie werden beim nächsten Abgleich gesendet." : (account ?? "")
            step = nil; action = ("Jetzt abgleichen", "arrow.triangle.2.circlepath", sync)
        case .rejected:
            cause = "Der Server hat sie nicht angenommen; sie bleiben auf diesem iPad."
            step = "Einzeln „Nur lokal behalten“: Einstellungen › Gesetzessammlung."
            action = ("Erneut versuchen", "arrow.clockwise", { [laws] in await laws.retryRejected() })
        case .synced:
            cause = [account, status.lastSynced.map { "zuletzt \(NotyText.statusDate($0))" }].compactMap { $0 }.joined(separator: " · ")
            step = nil; action = ("Jetzt abgleichen", "arrow.triangle.2.circlepath", sync)
        }
        return VStack(alignment: .leading, spacing: 12) {
            Label { Text(look.heading) } icon: { Image(systemName: look.symbol).foregroundStyle(look.tint) }.font(.headline)
            if !cause.isEmpty {
                Text(cause).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let action, canSync {
                Button { Task { await action.run() } } label: {
                    Label(action.title, systemImage: action.symbol).frame(minHeight: 44)
                }
                .buttonStyle(.bordered).tint(Color.notyAccent).disabled(laws.syncing)
            }
            if let step {
                Text(step).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20).frame(width: 320, alignment: .leading)
        .presentationCompactAdaptation(.popover)
        .preferredColorScheme(.dark)
    }

    // MARK: Overflow

    /// Undo of marks for touch, font size, versions with a check mark, the
    /// sync details and the official source. Without a law it is off.
    private var moreMenu: some View {
        let look = LawSyncLook(markController.syncBadge)
        return Menu {
            Section {
                Button { markController.undo() } label: { Label("Markieren widerrufen", systemImage: "arrow.uturn.backward") }
                    .disabled(!markController.canUndo)
                Button { markController.redo() } label: { Label("Wiederholen", systemImage: "arrow.uturn.forward") }
                    .disabled(!markController.canRedo)
            }
            // Several taps in a row stay in the open menu.
            ControlGroup {
                Button { changeFontSize(-1) } label: { Label("Schrift kleiner", systemImage: "textformat.size.smaller") }
                    .disabled(viewPDF || fontSize <= LawReadingStyle.fontRange.lowerBound)
                Button { changeFontSize(1) } label: { Label("Schrift größer", systemImage: "textformat.size.larger") }
                    .disabled(viewPDF || fontSize >= LawReadingStyle.fontRange.upperBound)
            } label: { Text("Schriftgröße") }
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
            Section {
                // Synced, guest and paused have no mark in the row: the state is here, quietly.
                Button { showSync = true } label: { Label("Abgleich: \(look.title)", systemImage: look.menuSymbol) }
                if let doc = document, let source = URL(string: doc.sourceUrl), source.scheme == "https" {
                    Link(destination: source) { Label("Amtliche Quelle öffnen", systemImage: "safari") }
                }
            }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 18)).frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .disabled(entry == nil)
        .opacity(entry == nil ? 0.35 : 1)
        .accessibilityLabel("Weitere Optionen")
        .notyTooltip("Schrift, Widerrufen, Fassung und mehr")
    }
    /// ⌘+ (1), ⌘- (-1), ⌘0 (0) and the „…“ menu.
    func changeFontSize(_ step: Int) {
        guard !viewPDF else { return }
        let range = LawReadingStyle.fontRange
        fontSize = step == 0 ? LawReadingStyle.defaultFontSize : min(range.upperBound, max(range.lowerBound, fontSize + Double(step * 2)))
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
        HStack(spacing: 0) {
            // Lupe or §: shows the mode and switches to the other one.
            Button { openLookup(mode == .query ? .number : .query) } label: {
                Group {
                    if mode == .query { Image(systemName: "magnifyingglass").font(.system(size: 16, weight: .medium)) }
                    else { Text("§").font(.system(size: 18, weight: .semibold)) }
                }
                .foregroundStyle(.white.opacity(0.7)).frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .disabled(mode == .query && document == nil)
            .accessibilityLabel("Eingabeart")
            .accessibilityValue(mode == .query ? "Suche" : "Paragraph")
            .accessibilityHint(mode == .query ? "Wechselt zur Paragrapheingabe" : "Wechselt zur Suche")
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
                            .frame(width: 44, height: 44).contentShape(Rectangle())
                    }.accessibilityLabel("Suche leeren").notyTooltip("Leeren")
                }
            } else {
                LawParagraphField(placeholder: entry?.kind == "administration" ? "Abschnitt oder R" : "Paragraph", text: $number, letters: letters,
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
                .accessibilityLabel("Tastatur")
                .accessibilityValue(letters ? "Buchstaben" : "Zahlen")
                .notyTooltip(letters ? "Zahlentastatur" : "Texttastatur – für 4a oder 4 Abs. 2")
            }
            Button { closeLookup() } label: {
                Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.7))
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .accessibilityLabel(mode == .query ? "Suche schließen" : "Paragrapheingabe schließen")
            .notyTooltip("Schließen (Esc)")
        }
        .frame(minHeight: 44)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
    }

    /// Previous/next section with the searched words and where the reader is among them.
    private var hitStepper: some View {
        let position = hits.firstIndex(of: sectionID)
        return HStack(spacing: 0) {
            Button { stepHit(-1) } label: {
                Image(systemName: "chevron.up").font(.system(size: 14, weight: .semibold)).frame(width: 44, height: 44).contentShape(Rectangle())
            }.accessibilityLabel("Vorheriger Treffer").notyTooltip(keyHint("Vorheriger Treffer", "focus.hit.previous"))
            Text(position.map { "\($0 + 1)/\(hits.count)" } ?? "\(hits.count)")
                .font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.7)).fixedSize()
                .accessibilityLabel(position.map { "Treffer \($0 + 1) von \(hits.count)" } ?? "\(hits.count) Treffer")
            Button { stepHit(1) } label: {
                Image(systemName: "chevron.down").font(.system(size: 14, weight: .semibold)).frame(width: 44, height: 44).contentShape(Rectangle())
            }.accessibilityLabel("Nächster Treffer").notyTooltip(keyHint("Nächster Treffer", "focus.hit.next"))
        }
    }

    // MARK: Footer

    /// Glass navigator like the notebook's page navigator: previous/next
    /// section, where the reader is and which version. The section itself is
    /// named once, in the heading above the text. Tapping the middle opens
    /// the contents.
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
            .notyTooltip(previous.map { keyHint("Zurück – \($0.label)", "focus.section.previous") } ?? "Anfang")
            Button { showContents = true } label: {
                VStack(spacing: 1) {
                    Text("\(index + 1) von \(doc.sections.count)").font(.caption.weight(.semibold)).monospacedDigit()
                        .foregroundStyle(.white).lineLimit(1)
                    HStack(spacing: 4) {
                        Text(version).lineLimit(1)
                        if older { Text("Ältere Fassung").foregroundStyle(.orange).fixedSize() }
                    }.font(.caption).foregroundStyle(.white.opacity(0.6))
                }
                .padding(.horizontal, 6).frame(minWidth: 110, maxWidth: 230, minHeight: 44).contentShape(Rectangle())
            }
            .accessibilityLabel("Stelle im Gesetz")
            .accessibilityValue("Vorschrift \(index + 1) von \(doc.sections.count), Fassung \(version)\(older ? ", ältere Fassung" : "")")
            .accessibilityHint("Öffnet das Inhaltsverzeichnis")
            .notyTooltip(keyHint("Inhaltsverzeichnis", "focus.contents"))
            Button { move(1) } label: {
                Image(systemName: "chevron.right").font(.system(size: 17, weight: .semibold)).frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .disabled(next == nil)
            .foregroundStyle(next == nil ? Color.gray.opacity(0.5) : .white)
            .accessibilityLabel(next.map { "Nächste Vorschrift: \($0.label)" } ?? "Keine nächste Vorschrift")
            .notyTooltip(next.map { keyHint("Weiter – \($0.label)", "focus.section.next") } ?? "Ende")
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
        pdfTarget = nil; sectionID = shown.id; jumpParagraph = nil; restoreOffset = nil; loadError = ""
        follow(shown, from: field)
        // Without a PDF position the PDF view would silently fall back to page 1.
        if viewPDF, shown.pdf == nil {
            viewPDF = false; loadError = LawReaderView.noPDFPosition
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
                }.frame(minHeight: 44).contentShape(Rectangle())
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
                        Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).frame(width: 44, height: 44).contentShape(Rectangle())
                    }.foregroundStyle(.white.opacity(0.7)).accessibilityLabel("Hinweis ausblenden")
                }
                .buttonStyle(NotyPressStyle())
                .padding(.leading, 16).padding(.trailing, 4)
                .background(Color.notyAccent.opacity(0.08))
                .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.14)).frame(height: 0.5) }
            }
        }
    }
}

/// Symbol, colour and names of the sync status („Abgleich“) for the mark,
/// its details and the „…“ menu.
struct LawSyncLook {
    var symbol: String
    var tint: Color
    /// Short name: hover, VoiceOver value, „…“ menu.
    var title: String
    /// Heading of the details.
    var heading: String
    var count: Int?
    /// A run sends changes now: the mark pulses.
    var running = false
    /// Quiet symbol for the „…“ menu (no green check next to „…“).
    var menuSymbol: String { running ? "arrow.triangle.2.circlepath" : symbol }
    /// From the data package's structured state (`LawSyncStatus`), never from its text.
    init(_ badge: LawMarkSyncBadge) {
        let status = badge.status
        let waiting = NotyText.count(status.pending, "Änderung wartet", "Änderungen warten")
        switch status.state {
        case .guest:
            symbol = "ipad"; tint = .white.opacity(0.55); title = "Nur auf diesem iPad"; heading = title
        case .paused:
            symbol = "pause.circle"; tint = .white.opacity(0.55); title = "Abgleich ist aus"; heading = title
        case .expired:
            symbol = "exclamationmark.triangle.fill"; tint = .orange; title = "Anmeldung abgelaufen"; heading = title
        case .failed:
            symbol = "icloud.slash"; tint = .orange; title = "Keine Verbindung"; heading = title
        case .rejected:
            symbol = "exclamationmark.triangle.fill"; tint = .orange; count = status.rejected
            title = NotyText.count(status.rejected, "Eintrag abgelehnt", "Einträge abgelehnt"); heading = title
        case .syncing:
            symbol = "arrow.up.circle"; tint = .notyAccent; running = true
            count = status.pending > 0 ? status.pending : nil
            title = "Wird abgeglichen"; heading = "Wird abgeglichen …"
        case .pending:
            symbol = "arrow.up.circle"; tint = .notyAccent; count = status.pending > 0 ? status.pending : nil
            title = status.pending == 0 ? "Noch nicht abgeglichen" : waiting; heading = title
        case .synced:
            symbol = "checkmark.circle"; tint = .white.opacity(0.55); title = "Abgeglichen"; heading = title
        }
    }
}

/// Width of the highlighter colours in the Pencil group.
enum LawSwatchLayout { case full, compact, menu }

/// A narrower colour dot (28 × 44) for the Pencil row in a narrow window.
private struct LawCompactSwatch: View {
    let color: Color
    let selected: Bool
    let title: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Circle().fill(color).frame(width: 20, height: 20)
                .overlay(Circle().strokeBorder(.white.opacity(selected ? 0.95 : 0.3), lineWidth: selected ? 2.5 : 1))
                .frame(width: 28, height: 44).contentShape(Rectangle())
        }.accessibilityLabel(title).accessibilityAddTraits(selected ? .isSelected : []).notyTooltip(title)
    }
}

private let lawFadingScrollSpace = "noty-law-fading-scroll"

/// A sideways row that fits without scrolling where it can; otherwise the
/// edges where more cells wait fade out over 16 pt.
struct LawFadingScroll<Content: View>: View {
    private let content: Content
    @State private var viewport: CGFloat = 0
    @State private var frame = CGRect.zero
    init(@ViewBuilder _ content: () -> Content) { self.content = content() }
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: LawReaderView.cellSpacing) { content }.frame(height: 44).fixedSize()
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(lawFadingScrollSpace)) } action: { frame = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .coordinateSpace(name: lawFadingScrollSpace)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { viewport = $0 }
        .mask {
            let leading = frame.minX < -0.5, trailing = frame.maxX > viewport + 0.5
            HStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing).frame(width: leading ? 16 : 0)
                Rectangle().fill(.black)
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: trailing ? 16 : 0)
            }
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
