import SwiftUI
import NotebookCore

/// Mode indicator, input line, which-key popup, key overview and command
/// palette of the keyboard mode. The editor is a full-screen cover above the
/// library, so each has its own.
struct KeyboardOverlay: View {
    let scope: KeyboardRouter.Scope
    @ObservedObject private var router = KeyboardRouter.shared
    @AppStorage(AppSettingsKey.keyboardMode) private var enabled = true

    /// Editor: below the back button and above every palette position
    /// (`ToolbarLayout`: 76 pt and lower), where neither the keyboard nor its
    /// format bar can reach, whatever height the system reports for them.
    /// The format bar lives in the keyboard's own window: only the place
    /// keeps popup and input line clear of it.
    private var inEditor: Bool { scope == .editor }

    var body: some View {
        ZStack(alignment: inEditor ? .topLeading : .bottomLeading) {
            Color.clear.allowsHitTesting(false)
            if enabled, router.scope == scope {
                VStack(alignment: .leading, spacing: 6) {
                    if !inEditor { panels }
                    if router.keyboardSeen { indicator }
                    if inEditor { panels }
                }
                .padding(.leading, 10).padding(inEditor ? .top : .bottom, inEditor ? 54 : 8)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                if router.helpVisible { KeyboardHelpView(context: router.shownContext, onClose: { router.helpVisible = false }) }
                if router.paletteVisible { KeyboardPaletteView(commands: router.paletteCommands()) { router.paletteVisible = false } }
            }
        }
    }

    private var indicator: some View {
        HStack(spacing: 6) {
            Text(router.label).font(.caption2.weight(.bold).monospaced())
            if !router.contextLabel.isEmpty { Text(router.contextLabel).font(.caption2.weight(.medium).monospaced()) }
            if router.selectionCount > 1 { Text("\(router.selectionCount) Auswahlen").font(.caption2.monospaced()) }
            if !router.pending.isEmpty { Text(router.pending).font(.caption2.monospaced()).foregroundStyle(.secondary) }
            if let notice = router.notice { Text(notice).font(.caption2).foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(.ultraThinMaterial, in: Capsule())
    }
    @ViewBuilder private var panels: some View {
        if let prompt = router.textPrompt { KeyboardPromptView(prompt: prompt) }
        if let menu = router.menu { KeyboardMenuView(menu: menu) }
    }
}

/// The input line: shows what the router collects, it never takes the focus.
private struct KeyboardPromptView: View {
    let prompt: TextPrompt
    var body: some View {
        HStack(spacing: 6) {
            Text(prompt.symbol).font(.callout.weight(.bold).monospaced()).foregroundStyle(.secondary)
            Text(prompt.query + "▏").font(.callout.monospaced()).lineLimit(1).truncationMode(.head)
            Spacer(minLength: 12)
            if prompt.noMatch { Text("Kein Treffer").font(.caption).foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(width: 320, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
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
        }
    }
    /// The current context first.
    private var contexts: [HelixContext] { [context] + HelixContext.allCases.filter { $0 != context } }
    var body: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea().onTapGesture(perform: onClose)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
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
        let direct = KeyPalette.direct(query)
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
                TextField("Befehl, :w, :q oder Seitenzahl", text: $query)
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
                                    .background(position == index ? Color.accentColor.opacity(0.28) : .clear)
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
