import SwiftUI
import NotebookCore

/// Owns exactly one writer/model per document, shared by both independent panes.
@MainActor
final class EditorWorkspace: ObservableObject {
    let primary: EditorModel
    let primaryDocument: OpenNotebook
    let root: URL
    @Published var secondary: EditorModel?
    @Published var secondaryID: UUID?
    @Published var activePane = 0
    @Published var closing = false
    @Published var error: String?
    private var models: [UUID: EditorModel]
    init(document: OpenNotebook, root: URL) {
        self.root = root; primaryDocument = document
        primary = EditorModel(storageRoot: document.directory,
            restoreDirectory: root.appendingPathComponent("Restores", isDirectory: true),
            preferredPageID: document.preferredPageID, libraryTitle: document.title)
        models = [document.id: primary]
    }
    func openSecondary(_ document: OpenNotebook) async {
        guard !closing else { return }
        closing = true; defer { closing = false }
        if let secondary, secondary !== primary, secondaryID != document.id {
            guard await secondary.flushBeforeClosing() else { return }
            if let secondaryID { models.removeValue(forKey: secondaryID) }
        }
        let model: EditorModel
        if let existing = models[document.id] { model = existing }
        else {
            model = EditorModel(storageRoot: document.directory,
                restoreDirectory: root.appendingPathComponent("Restores", isDirectory: true),
                preferredPageID: document.preferredPageID, libraryTitle: document.title)
            models[document.id] = model
        }
        secondary = model; secondaryID = document.id; activePane = 1
    }
    func closeSecondary() async {
        guard !closing else { return }
        closing = true; defer { closing = false }
        if let secondary, secondary !== primary {
            guard await secondary.flushBeforeClosing() else { return }
            if let secondaryID { models.removeValue(forKey: secondaryID) }
        }
        secondary = nil; secondaryID = nil; activePane = 0
    }
    /// Pauses the editors only until every pane and the tool settings are
    /// committed; the backup archive is then built from committed packages
    /// while editing continues. A pane whose save already failed is not saved
    /// again here (that would pause input, rewrite the whole snapshot and repeat
    /// its error); the backup is postponed with a longer pause instead.
    func commitForBackup(toolbox: ToolbarSettingsModel) async -> BackupCommit {
        guard !closing, models.values.allSatisfy({ !$0.busy && !$0.inputInProgress }) else { return .busy }
        guard models.values.allSatisfy({ $0.writable && !$0.saveFailed }) else { return .failed }
        closing = true
        for model in models.values { model.pauseMutations() }
        defer {
            for model in models.values { model.resumeMutations() }
            closing = false
        }
        guard await toolbox.flush() else { return .failed }
        guard models.values.allSatisfy({ !$0.busy && !$0.inputInProgress }) else { return .busy }
        for model in models.values { model.save() }
        for model in models.values { if !(await model.waitForSave()) { return .failed } }
        return .committed
    }
    func closeAll() async -> Bool {
        guard !closing else { return false }
        closing = true; defer { closing = false }
        // Persist every owner first. Only disable the owners after all saves
        // succeeded, otherwise one failed pane could strand its sibling.
        for model in models.values {
            if model.busy { error = "Bitte den laufenden Vorgang abwarten."; return false }
            model.save()
        }
        for model in models.values { if !(await model.waitForSave()) { return false } }
        for model in models.values { model.writable = false }
        return true
    }
}

struct EditorWorkspaceView: View {
    /// Display preference only (global, like the sidebar): side, axis, size.
    static let arrangementKey = "noty.editor.splitArrangement"
    private static let space = "noty-split-area"
    private static let strip = 28.0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var workspace: EditorWorkspace
    @ObservedObject var library: LibraryModel
    @EnvironmentObject private var toolbox: ToolbarSettingsModel
    @Environment(\.dismiss) private var dismiss
    /// One presentation of the document picker. The picker loads its own list
    /// (`.task`), so it can never show a list captured before loading: with
    /// `sheet(isPresented:)` and a separate `@State` array the body never read,
    /// the first presentation showed the stale initial empty array.
    @State private var picker: SecondViewRequest?
    @AppStorage(EditorWorkspaceView.arrangementKey) private var storedArrangement = ""
    @State private var paneDrag: PaneDrag?
    @GestureState private var paneGestureActive = false
    @State private var dividerFraction: Double?
    @GestureState private var dividerGestureActive = false
    @State private var menuPane: SplitPane?

    private var arrangement: SplitPaneArrangement {
        get { SplitPaneArrangement(storageValue: storedArrangement) }
        nonmutating set { if newValue.storageValue != storedArrangement { storedArrangement = newValue.storageValue } }
    }
    private func update(_ change: (inout SplitPaneArrangement) -> Void) {
        var updated = arrangement
        change(&updated)
        arrangement = updated
    }
    private enum PaneKey: Hashable { case primary, secondary(ObjectIdentifier) }
    private struct PaneEntry: Identifiable {
        let id: PaneKey
        let pane: SplitPane
        let model: EditorModel
    }
    private struct PaneDrag: Equatable {
        let pane: SplitPane
        var location: CGPoint
        var target: SplitSlot
    }
    /// Stable identities in display order: reordering moves the existing
    /// panes (canvases/text views are kept), a replaced second model gets a
    /// fresh pane without the previous notebook's selection, focus or draft.
    private func entries(_ arrangement: SplitPaneArrangement) -> [PaneEntry] {
        let primary = PaneEntry(id: .primary, pane: .primary, model: workspace.primary)
        guard let secondary = workspace.secondary else { return [primary] }
        let second = PaneEntry(id: .secondary(ObjectIdentifier(secondary)), pane: .secondary, model: secondary)
        return arrangement.order.map { $0 == .primary ? primary : second }
    }

    var body: some View {
        GeometryReader { geometry in
            let size = PageSize(width: geometry.size.width, height: geometry.size.height)
            let split = workspace.secondary != nil
            let current = arrangement
            let stack = current.vertical && split ? AnyLayout(VStackLayout(spacing: SplitPaneArrangement.gap))
                : AnyLayout(HStackLayout(spacing: SplitPaneArrangement.gap))
            ZStack(alignment: .topLeading) {
                stack {
                    ForEach(entries(current)) { entry in
                        let frame = split ? current.frame(of: entry.pane, in: size) : PageRect(x: 0, y: 0, width: size.width, height: size.height)
                        paneView(entry, split: split, current: current, size: size)
                            .frame(width: max(0, frame.width), height: max(0, frame.height))
                            .opacity(paneDrag?.pane == entry.pane ? 0.4 : 1)
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
                if split {
                    divider(current, size: size)
                    if let paneDrag { dropPreview(paneDrag, arrangement: current, size: size).allowsHitTesting(false).transition(.opacity) }
                    if let dividerFraction { resizePreview(dividerFraction, arrangement: current, size: size).allowsHitTesting(false).transition(.opacity) }
                }
            }
            .background(split ? Color(white: 0.2) : Color.clear)
            .coordinateSpace(name: Self.space)
            .animation(NotyMotion.panel(reduceMotion), value: current)
            .animation(NotyMotion.panel(reduceMotion), value: split)
            .animation(NotyMotion.highlight(reduceMotion), value: paneDrag?.target)
            .animation(NotyMotion.highlight(reduceMotion), value: dividerFraction)
            .sensoryFeedback(.selection, trigger: paneDrag?.target)
            .sensoryFeedback(.selection, trigger: dividerFraction)
        }
        // A cancelled gesture never reaches onEnded: drop the preview.
        .onChange(of: paneGestureActive) { _, active in if !active { paneDrag = nil } }
        .onChange(of: dividerGestureActive) { _, active in if !active { dividerFraction = nil } }
        .sheet(item: $picker) { request in
            SecondViewPicker(library: library, primaryID: workspace.primaryDocument.id, currentID: workspace.secondaryID,
                slot: request.slot, vertical: request.vertical) { document, slot, vertical in
                picker = nil
                update { $0.vertical = vertical; $0.place(.secondary, in: slot) }
                Task { await workspace.openSecondary(document) }
            }
        }
        .alert("Ansichten", isPresented: Binding(get: { workspace.error != nil }, set: { if !$0 { workspace.error = nil } })) {
            Button("OK") { workspace.error = nil }
        } message: { Text(workspace.error ?? "") }
        .onAppear { library.editorCommit = { await workspace.commitForBackup(toolbox: toolbox) } }
        .onDisappear { library.editorCommit = nil }
        .interactiveDismissDisabled()
    }

    private func paneView(_ entry: PaneEntry, split: Bool, current: SplitPaneArrangement, size: PageSize) -> some View {
        VStack(spacing: 0) {
            if split { paneStrip(entry, current: current, size: size) }
            pane(entry.model, index: entry.pane.rawValue)
        }
    }

    private func pane(_ model: EditorModel, index: Int) -> some View {
        ContentView(model: model, isRestoredCopy: false, isLibraryDocument: true, initialSearchBounds: index == 0 ? workspace.primaryDocument.searchBounds : nil,
            isPaneActive: { workspace.activePane == index && !workspace.closing }, onActivatePane: { workspace.activePane = index },
            onCloseWorkspace: { Task { if await toolbox.flush(), await workspace.closeAll() { library.notebookClosedByUser(); dismiss() } } },
            onSecondView: { choose() })
    }

    private func choose() {
        guard !workspace.closing else { return }
        let current = arrangement
        picker = SecondViewRequest(slot: current.slot(of: .secondary), vertical: current.vertical)
    }

    private func sideName(_ slot: SplitSlot, vertical: Bool) -> String {
        switch (slot, vertical) {
        case (.first, false): "links"
        case (.second, false): "rechts"
        case (.first, true): "oben"
        case (.second, true): "unten"
        }
    }

    private func title(_ model: EditorModel) -> String {
        model.documentLoaded ? model.notebook.title : "Notizbuch"
    }

    // MARK: Pane strip with grab handle

    private func paneStrip(_ entry: PaneEntry, current: SplitPaneArrangement, size: PageSize) -> some View {
        let active = workspace.activePane == entry.pane.rawValue
        return ZStack {
            // Activation stays with the pane content (it also syncs the shared
            // model's page when both panes show the same notebook).
            Color(uiColor: NotebookViewport.backdrop).accessibilityHidden(true)
            handle(entry, current: current, size: size, active: active)
            if entry.pane == .secondary {
                HStack {
                    Spacer()
                    Button { Task { await workspace.closeSecondary() } } label: {
                        Image(systemName: "xmark").font(.system(size: 12, weight: .semibold))
                            .frame(width: 44, height: Self.strip).contentShape(Rectangle())
                    }
                    .buttonStyle(NotyPressStyle())
                    .foregroundStyle(.white.opacity(0.7))
                    .disabled(workspace.closing)
                    .accessibilityLabel("Zweite Ansicht schließen")
                }.padding(.trailing, 4)
            }
        }
        .frame(height: Self.strip)
        .environment(\.colorScheme, .dark)
    }

    private func handle(_ entry: PaneEntry, current: SplitPaneArrangement, size: PageSize, active: Bool) -> some View {
        let target: (CGPoint) -> SplitSlot = { location in
            current.dropSlot(at: PagePoint(x: location.x, y: location.y), in: size) ?? current.slot(of: entry.pane)
        }
        return HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { _ in Circle().frame(width: 5, height: 5) }
        }
        .foregroundStyle(active ? Color.accentColor : Color.white.opacity(0.55))
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Capsule().fill(Color.white.opacity(paneDrag?.pane == entry.pane ? 0.22 : 0.1)))
        .frame(width: 88, height: Self.strip)
        .contentShape(Rectangle())
        .onTapGesture { menuPane = entry.pane }
        .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.space))
            .updating($paneGestureActive) { _, state, _ in state = true }
            .onChanged { value in
                guard !workspace.closing else { return }
                paneDrag = PaneDrag(pane: entry.pane, location: value.location, target: target(value.location))
            }
            .onEnded { value in
                // Decided from the release point: the preview state may
                // already be reset by the gesture state.
                paneDrag = nil
                guard !workspace.closing else { return }
                let slot = target(value.location)
                update { $0.place(entry.pane, in: slot) }
            })
        .confirmationDialog("Ansicht", isPresented: Binding(get: { menuPane == entry.pane }, set: { if !$0 { menuPane = nil } }),
                            titleVisibility: .hidden) {
            Button("Seiten tauschen") { update { $0.swapSides() } }
            Button(current.vertical ? "Nebeneinander anordnen" : "Untereinander anordnen") { update { $0.vertical.toggle() } }
            if abs(current.effectiveFraction(extent: current.vertical ? size.height : size.width) - 0.5) > 1e-9 {
                Button("Gleich groß") { update { $0.setFraction(0.5) } }
            }
            if entry.pane == .secondary { Button("Anderes Notizbuch wählen …") { choose() } }
            Button("Zweite Ansicht schließen") { Task { await workspace.closeSecondary() } }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Ansicht verschieben")
        .accessibilityValue("\(title(entry.model)), \(sideName(current.slot(of: entry.pane), vertical: current.vertical))")
        .accessibilityHint("Ziehen, um die Ansicht auf die andere Seite zu legen. Tippen für Optionen.")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { menuPane = entry.pane }
        .accessibilityAction(named: "Seiten tauschen") { update { $0.swapSides() } }
    }

    // MARK: Drop preview

    private func dropPreview(_ drag: PaneDrag, arrangement: SplitPaneArrangement, size: PageSize) -> some View {
        let landing = arrangement.placing(drag.pane, in: drag.target).frame(of: drag.pane, in: size)
        let model = drag.pane == .primary ? workspace.primary : (workspace.secondary ?? workspace.primary)
        let cardWidth = min(260, max(160, landing.width * 0.45))
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.accentColor.opacity(0.16))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.accentColor, lineWidth: 2))
                .overlay(
                    Label(sideName(drag.target, vertical: arrangement.vertical).capitalized, systemImage: arrangement.vertical
                          ? (drag.target == .first ? "rectangle.tophalf.inset.filled" : "rectangle.bottomhalf.inset.filled")
                          : (drag.target == .first ? "rectangle.lefthalf.inset.filled" : "rectangle.righthalf.inset.filled"))
                        .font(.headline).foregroundStyle(.white)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Capsule().fill(Color.accentColor.opacity(0.85))))
                .frame(width: max(0, landing.width - 12), height: max(0, landing.height - 12))
                .offset(x: landing.x + 6, y: landing.y + 6)
            VStack(spacing: 8) {
                HStack(spacing: 4) { ForEach(0..<3, id: \.self) { _ in Circle().frame(width: 5, height: 5) } }
                    .foregroundStyle(Color.accentColor)
                Image(systemName: "book.closed").font(.title2)
                Text(title(model)).font(.subheadline.weight(.semibold)).lineLimit(2).multilineTextAlignment(.center)
            }
            .foregroundStyle(.white)
            .padding(14)
            .frame(width: cardWidth, height: cardWidth * 0.62)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(white: 0.16).opacity(0.94)))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.18)))
            .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
            .position(drag.location)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .environment(\.colorScheme, .dark)
    }

    // MARK: Divider (snaps to 1/3 · 1/2 · 2/3)

    private func divider(_ current: SplitPaneArrangement, size: PageSize) -> some View {
        let position = current.dividerPosition(in: size)
        let extent = current.vertical ? size.height : size.width
        let allowed = SplitPaneArrangement.allowedFractions(extent: extent)
        // Grab zone around the gap that never covers a pane strip (handle,
        // close button): side by side it starts below the strips; stacked it
        // extends only into the upper pane.
        let strip = Self.strip
        let vertical = current.vertical
        let thickness = vertical ? 14.0 : 18.0
        return ZStack {
            Color.clear.contentShape(Rectangle())
            Capsule().fill(Color.white.opacity(dividerFraction == nil ? 0.5 : 0.9))
                .frame(width: vertical ? 44 : 5, height: vertical ? 5 : 44)
                // Stacked: centred on the gap, left of the lower pane's grab handle.
                .offset(x: vertical ? -size.width / 4 : 0, y: vertical ? 4 : -strip / 2)
        }
        .frame(width: vertical ? size.width : thickness, height: vertical ? thickness : max(0, size.height - strip))
        .offset(x: vertical ? 0 : position - thickness / 2, y: vertical ? position - 11 : strip)
        .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .named(Self.space))
            .updating($dividerGestureActive) { _, state, _ in state = true }
            .onChanged { value in
                guard allowed.count > 1, !workspace.closing else { return }
                let location = current.vertical ? value.location.y : value.location.x
                dividerFraction = SplitPaneArrangement.snappedFraction(location: location, extent: extent)
            }
            .onEnded { value in
                dividerFraction = nil
                guard allowed.count > 1, !workspace.closing else { return }
                let location = current.vertical ? value.location.y : value.location.x
                let fraction = SplitPaneArrangement.snappedFraction(location: location, extent: extent)
                update { $0.setFraction(fraction) }
            })
        .onTapGesture(count: 2) { update { $0.setFraction(0.5) } }
        .accessibilityElement()
        .accessibilityLabel("Größe der Ansichten")
        .accessibilityValue("\(Int((current.effectiveFraction(extent: extent) * 100).rounded())) Prozent für die \(current.vertical ? "obere" : "linke") Ansicht")
        .accessibilityAdjustableAction { direction in
            let effective = current.effectiveFraction(extent: extent)
            guard let index = allowed.firstIndex(where: { abs($0 - effective) < 1e-9 }) else { return }
            let next = direction == .increment ? min(index + 1, allowed.count - 1) : max(index - 1, 0)
            update { $0.setFraction(allowed[next]) }
        }
    }

    private func resizePreview(_ fraction: Double, arrangement: SplitPaneArrangement, size: PageSize) -> some View {
        let preview = SplitPaneArrangement(secondaryFirst: arrangement.secondaryFirst, vertical: arrangement.vertical, fraction: fraction)
        return ZStack(alignment: .topLeading) {
            ForEach(SplitSlot.allCases, id: \.self) { slot in
                let frame = preview.frame(of: slot, in: size)
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.accentColor.opacity(0.08)))
                    .frame(width: max(0, frame.width - 8), height: max(0, frame.height - 8))
                    .offset(x: frame.x + 4, y: frame.y + 4)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }
}

/// One presentation of the second-view picker.
private struct SecondViewRequest: Identifiable {
    let id = UUID()
    let slot: SplitSlot
    let vertical: Bool
}

/// Notebook picker for the second view. Loads its own list on appear, shows
/// a loading state until then and offers the side (and axis) up front.
private struct SecondViewPicker: View {
    @ObservedObject var library: LibraryModel
    let primaryID: UUID
    let currentID: UUID?
    @State var slot: SplitSlot
    @State var vertical: Bool
    let onPick: (OpenNotebook, SplitSlot, Bool) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var documents: [OpenNotebook]?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Anordnung", selection: $vertical) {
                        Label("Nebeneinander", systemImage: "rectangle.split.2x1").tag(false)
                        Label("Untereinander", systemImage: "rectangle.split.1x2").tag(true)
                    }.pickerStyle(.segmented)
                    Picker("Position", selection: $slot) {
                        Text(vertical ? "Oben" : "Links").tag(SplitSlot.first)
                        Text(vertical ? "Unten" : "Rechts").tag(SplitSlot.second)
                    }.pickerStyle(.segmented)
                } header: { Text("Zweite Ansicht") }
                if let documents {
                    let recent = recentDocuments(documents)
                    if !recent.isEmpty {
                        Section("Zuletzt geöffnet") { ForEach(recent) { row($0) } }
                    }
                    Section(recent.isEmpty ? "Notizbücher" : "Alle Notizbücher") {
                        ForEach(documents) { row($0) }
                        if documents.isEmpty { Text("Keine Notizbücher verfügbar.").foregroundStyle(.secondary) }
                    }
                } else {
                    Section {
                        HStack(spacing: 10) { ProgressView(); Text("Notizbücher werden geladen …").foregroundStyle(.secondary) }
                            .accessibilityElement(children: .combine)
                    }
                }
            }
            .navigationTitle("Notizbuch für zweite Ansicht")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } } }
            .task { if documents == nil { documents = await library.editorChoices() } }
        }
    }

    private func recentDocuments(_ documents: [OpenNotebook]) -> [OpenNotebook] {
        let opened = Dictionary(library.snapshot.items.compactMap { item in item.lastOpened.map { (item.id, $0) } },
                                uniquingKeysWith: { max($0, $1) })
        guard documents.count > 4 else { return [] }
        return Array(documents.filter { opened[$0.id] != nil }
            .sorted { opened[$0.id]! > opened[$1.id]! }.prefix(3))
    }

    private func row(_ document: OpenNotebook) -> some View {
        Button { onPick(document, slot, vertical) } label: {
            HStack {
                Label(document.title, systemImage: document.isRestored ? "clock.arrow.circlepath" : "book.closed")
                    .foregroundStyle(.primary)
                Spacer()
                if document.id == primaryID { Text("gleiches Notizbuch").font(.caption).foregroundStyle(.secondary) }
                if document.id == currentID { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
            }
        }
        .accessibilityValue(document.id == primaryID ? "gleiches Notizbuch" : "")
    }
}
