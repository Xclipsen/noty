import SwiftUI
import NotebookCore

/// Mode indicator, key overview and command palette of the keyboard mode.
/// The editor is a full-screen cover above the library, so each has its own.
struct KeyboardOverlay: View {
    let scope: KeyboardRouter.Scope
    @ObservedObject private var router = KeyboardRouter.shared
    @AppStorage(AppSettingsKey.keyboardMode) private var enabled = true

    /// Editor: below the back button and above every palette position
    /// (`ToolbarLayout`: 76 pt and lower), where neither the keyboard nor its
    /// format bar can reach, whatever height the system reports for them.
    private var inEditor: Bool { scope == .editor }

    var body: some View {
        ZStack(alignment: inEditor ? .topLeading : .bottomLeading) {
            Color.clear.allowsHitTesting(false)
            if enabled, router.scope == scope {
                if router.keyboardSeen {
                    HStack(spacing: 6) {
                        Text(router.label).font(.caption2.weight(.bold).monospaced())
                        if !router.pending.isEmpty { Text(router.pending).font(.caption2.monospaced()).foregroundStyle(.secondary) }
                    }
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.leading, 10).padding(inEditor ? .top : .bottom, inEditor ? 54 : 8)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
                if router.helpVisible { KeyboardHelpView(onClose: { router.helpVisible = false }) }
                if router.paletteVisible { KeyboardPaletteView(commands: router.paletteCommands()) { router.paletteVisible = false } }
            }
        }
    }
}

private struct KeyboardHelpView: View {
    let onClose: () -> Void
    private var groups: [(name: String, rows: [KeyBinding])] {
        var seen = Set<String>(), order: [String] = [], rows: [String: [KeyBinding]] = [:]
        for row in KeyMap.bindings where seen.insert(row.group + row.title).inserted {
            if rows[row.group] == nil { order.append(row.group) }
            rows[row.group, default: []].append(row)
        }
        return order.map { ($0, rows[$0] ?? []) }
    }
    var body: some View {
        ZStack {
            Color.black.opacity(0.45).ignoresSafeArea().onTapGesture(perform: onClose)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), alignment: .top)], alignment: .leading, spacing: 18) {
                    ForEach(groups, id: \.name) { group in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(group.name).font(.subheadline.weight(.semibold))
                            ForEach(group.rows, id: \.title) { row in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(row.keys.replacingOccurrences(of: " ", with: "")).font(.caption.monospaced()).frame(width: 74, alignment: .leading)
                                    Text(row.title).font(.caption).foregroundStyle(.secondary)
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
