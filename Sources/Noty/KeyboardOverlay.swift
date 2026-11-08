import SwiftUI
import NotebookCore

/// Mode indicator, input line, which-key popup, key overview and command
/// palette of the keyboard mode. The editor is a full-screen cover above the
/// library, so each has its own.
struct KeyboardOverlay: View {
    let scope: KeyboardRouter.Scope
    /// In a sheet: the sheet's panel. The overlays below it would stay hidden.
    var panel: KeyPanel.ID? = nil
    @ObservedObject private var router = KeyboardRouter.shared
    @AppStorage(AppSettingsKey.helixTextDocuments) private var helix = false
    private var enabled: Bool { helix && router.inTextDocument }

    /// Editor: below the back button and above every palette position
    /// (`ToolbarLayout`: 76 pt and lower), where neither the keyboard nor its
    /// format bar can reach, whatever height the system reports for them.
    /// The format bar lives in the keyboard's own window: only the place
    /// keeps popup and input line clear of it.
    private var inEditor: Bool { scope == .editor && panel == nil }
    private var isCurrent: Bool { panel.map { $0 == router.sheetPanel?.id } ?? (router.scope == scope && router.sheetPanel == nil) }

    var body: some View {
        ZStack(alignment: inEditor ? .topLeading : .bottomLeading) {
            Color.clear.allowsHitTesting(false)
            if isCurrent {
                if enabled {
                    VStack(alignment: .leading, spacing: 6) {
                        if !inEditor { panels }
                        if router.keyboardSeen { indicator }
                        if inEditor { panels }
                    }
                    .padding(.leading, 10).padding(inEditor ? .top : .bottom, inEditor ? 54 : 8)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
                // ⌘/ and ⇧⌘P work without the keyboard mode, too.
                if router.helpVisible { KeyboardHelpView(context: router.shownContext, onClose: { router.helpVisible = false }) }
                if router.paletteVisible { KeyboardPaletteView(commands: router.paletteCommands()) { router.paletteVisible = false } }
                if let question = router.question { KeyboardQuestionView(question: question) }
            }
        }
    }

    private var indicator: some View {
        HStack(spacing: 6) {
            Text(router.label).font(.caption2.weight(.bold).monospaced())
            if !router.contextLabel.isEmpty { Text(router.contextLabel).font(.caption2.weight(.medium).monospaced()) }
            if let register = router.recordingRegister { Text("REC \(register)").font(.caption2.weight(.bold).monospaced()).foregroundStyle(.red) }
            if router.selectionCount > 1 { Text("\(router.selectionCount) Auswahlen").font(.caption2.monospaced()) }
            if !router.pending.isEmpty { Text(router.pending).font(.caption2.monospaced()).foregroundStyle(.secondary) }
            if let notice = router.notice { Text(notice).font(.caption2).foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(.ultraThinMaterial, in: Capsule())
    }
    @ViewBuilder private var panels: some View {
        if let prompt = router.textPrompt { KeyboardPromptView(symbol: prompt.symbol, query: prompt.query, noMatch: prompt.noMatch) }
        if let line = router.activePanel, line.typing, let symbol = line.inputSymbol {
            KeyboardPromptView(symbol: symbol, query: line.input?.wrappedValue ?? "", noMatch: false)
        }
        if let choices = router.choices { KeyboardChoicesView(choices: choices) }
        if let menu = router.menu { KeyboardMenuView(menu: menu) }
    }
}

/// The input line: shows what the router collects, it never takes the focus.
private struct KeyboardPromptView: View {
    let symbol: String
    let query: String
    let noMatch: Bool
    var body: some View {
        HStack(spacing: 6) {
            Text(symbol).font(.callout.weight(.bold).monospaced()).foregroundStyle(.secondary)
            Text(query + "▏").font(.callout.monospaced()).lineLimit(1).truncationMode(.head)
            Spacer(minLength: 12)
            if noMatch { Text("Kein Treffer").font(.caption).foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(width: 320, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Colours and strokes of `Space c`: never takes the focus or a touch.
private struct KeyboardChoicesView: View {
    let choices: KeyChoices
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(choices.title).font(.caption.weight(.semibold))
            ForEach(Array(choices.rows.enumerated()), id: \.element.id) { row, line in
                VStack(alignment: .leading, spacing: 3) {
                    if !line.title.isEmpty { Text(line.title).font(.caption).foregroundStyle(.secondary) }
                    HStack(spacing: 6) {
                        ForEach(Array(line.items.enumerated()), id: \.element.id) { column, item in
                            cell(item, number: column + 1, chosen: choices.cursor.row == row && choices.cursor.column == column)
                        }
                    }
                }
            }
            if let line = choices.rows[safe: choices.cursor.row], let item = line.items[safe: choices.cursor.column] {
                Text(item.title).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
    @ViewBuilder private func cell(_ item: KeyChoiceItem, number: Int, chosen: Bool) -> some View {
        Group {
            if let color = item.color {
                Circle().fill(color).frame(width: 24, height: 24).overlay(Circle().strokeBorder(.white.opacity(0.3), lineWidth: 1))
            } else {
                Text(item.title).font(.caption).lineLimit(1).frame(minHeight: 24)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if number < 10, item.color != nil { Text("\(number)").font(.system(size: 9, weight: .bold).monospaced()).foregroundStyle(.secondary).offset(x: 3, y: 3) }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 7).strokeBorder(chosen ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.clear), lineWidth: 2))
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

/// A question raised by a key. The system dialog stays for touch.
private struct KeyboardQuestionView: View {
    let question: KeyQuestion
    private func close() { KeyboardRouter.shared.handleQuestionTap(nil) }
    var body: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea().onTapGesture(perform: close)
            VStack(alignment: .leading, spacing: 12) {
                Text(question.title).font(.headline)
                if !question.message.isEmpty { Text(question.message).font(.callout).foregroundStyle(.secondary) }
                VStack(spacing: 6) {
                    ForEach(question.options) { option in
                        Button { KeyboardRouter.shared.handleQuestionTap(option.id) } label: {
                            Text(option.title).frame(maxWidth: .infinity, minHeight: 34)
                                .foregroundStyle(option.destructive ? Color.red : .primary)
                                .background(option.id == question.chosen ? AnyShapeStyle(.tint.opacity(0.28)) : AnyShapeStyle(Color.clear), in: RoundedRectangle(cornerRadius: 8))
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
            }
            .padding(18).frame(maxWidth: 380)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .padding(24)
        }
    }
}

/// The next keys of an open menu.
private struct KeyboardMenuView: View {
    let menu: HelixMenu
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(menu.title).font(.caption.weight(.semibold))
            ForEach(menu.entries, id: \.key) { entry in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(HelixKeymap.label(entry.key)).font(.caption.monospaced()).frame(minWidth: 26, alignment: .leading)
                    Text(entry.isMenu ? entry.title + " …" : entry.title).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct KeyboardHelpView: View {
    let context: HelixContext
    let onClose: () -> Void
    private static func title(_ context: HelixContext) -> String {
        switch context {
        case .library: "Bibliothek"
        case .page: "Seite"
        case .text: "Text"
        case .sidebar: "Seitenleiste"
        case .list: "Trefferliste"
        case .dialog: "Dialog"
        case .law: "Gesetze"
        case .color: "Farbe und Strich"
        }
    }
    /// The current context first.
    private var contexts: [HelixContext] { [context] + HelixContext.allCases.filter { $0 != context } }
    var body: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea().onTapGesture(perform: onClose)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if !KeyboardRouter.shared.isEnabled {
                        Text("Diese Tasten gelten nur in Textdokumenten mit eingeschalteter Helix-Tastatur (Einstellungen › Text & Tastatur, experimentell).")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(contexts, id: \.self) { context in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(Self.title(context)).font(.headline)
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), alignment: .top)], alignment: .leading, spacing: 18) {
                                ForEach(HelixKeymap.groups(in: context), id: \.name) { group in
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(group.name).font(.subheadline.weight(.semibold))
                                        ForEach(group.rows, id: \.title) { row in
                                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                                Text(row.label).font(.caption.monospaced()).frame(width: 74, alignment: .leading)
                                                Text(row.title).font(.caption).foregroundStyle(.secondary)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }.padding(20)
            }
            .frame(maxWidth: 980, maxHeight: 640)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .padding(24)
            // Without a responder of the router, too; the same way, so that one Esc stays one.
            Button("") { if !KeyboardRouter.shared.handle(token: "<Esc>") { onClose() } }
                .keyboardShortcut(.cancelAction).frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
        }
    }
}

private struct KeyboardPaletteView: View {
    let commands: [PaletteCommand]
    let onClose: () -> Void
    @State private var query = ""
    @State private var index = 0
    @FocusState private var focused: Bool

    private var hits: [PaletteCommand] {
        commands.compactMap { command in KeyPalette.score(query, in: command.title).map { (command, $0) } }
            .sorted { $0.1 < $1.1 }.map(\.0)
    }
    private func run() {
        let hit = hits.indices.contains(index) ? hits[index] : nil
        let direct = KeyPalette.direct(query, in: KeyboardRouter.shared.shownContext)
        onClose()
        // After the palette is gone: the focus returns before the command runs.
        DispatchQueue.main.async {
            if let direct { KeyboardRouter.shared.runDirect(direct) } else { hit?.run() }
        }
    }
    private func step(_ delta: Int) {
        guard !hits.isEmpty else { return }
        index = (index + delta + hits.count) % hits.count
    }
    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.3).ignoresSafeArea().onTapGesture(perform: onClose)
            VStack(spacing: 0) {
                TextField(KeyboardRouter.shared.scope == .library ? "Befehl" : "Befehl, :w, :q oder Seitenzahl", text: $query)
                    .textFieldStyle(.plain).font(.title3).padding(14)
                    .focused($focused).autocorrectionDisabled().textInputAutocapitalization(.never)
                    .onSubmit(run).onChange(of: query) { _, _ in index = 0 }
                    .onKeyPress(.upArrow) { step(-1); return .handled }
                    .onKeyPress(.downArrow) { step(1); return .handled }
                    .onKeyPress(.escape) { onClose(); return .handled }
                Divider()
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(hits.enumerated()), id: \.element.id) { position, command in
                                Button {
                                    index = position; run()
                                } label: {
                                    HStack {
                                        Text(command.title)
                                        Spacer()
                                        if let keys = command.keys { Text(keys).font(.caption.monospaced()).foregroundStyle(.secondary) }
                                    }
                                    .padding(.horizontal, 14).padding(.vertical, 8).contentShape(Rectangle())
                                    .background(position == index ? AnyShapeStyle(.tint.opacity(0.28)) : AnyShapeStyle(Color.clear))
                                }.buttonStyle(.plain).id(position)
                            }
                        }
                    }
                    .frame(maxHeight: 380)
                    .onChange(of: index) { _, value in proxy.scrollTo(value) }
                }
                // Keyboards and focus differ: these also reach the list.
                Group {
                    Button("") { step(1) }.keyboardShortcut("n", modifiers: .control)
                    Button("") { step(-1) }.keyboardShortcut("p", modifiers: .control)
                    Button("", action: onClose).keyboardShortcut(.cancelAction)
                }.frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
            }
            .frame(maxWidth: 560)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .padding(.top, 60).padding(.horizontal, 24)
        }
        .onAppear { focused = true }
    }
}
