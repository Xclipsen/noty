import SwiftUI
import UIKit
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
    @EnvironmentObject private var laws: LawLibraryModel
    @AppStorage(LawLibraryModel.enabledKey) private var lawsEnabled = false
    @State private var lawWidth = 380.0
    @State private var lawResizeStart: Double?
    @GestureState private var lawResizing = false
    /// Live drag of the law window's top bar or of its edge tab, with the drop
    /// that releasing now would perform (shown as a preview).
    @State private var lawDrag: LawDrag?
    @GestureState private var lawDragActive = false
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
            let lawShown = lawsEnabled && laws.panelOpen
            let lawStashed = lawShown && laws.stashed
            let lawVisible = lawShown && !laws.stashed
            // A stashed window keeps its docked/floating shape for the way back
            // but gives the notebook its full width meanwhile.
            let law = LawLayout(geometry.size, width: lawWidth, docked: laws.docked, onLeft: laws.panelOnLeft)
            let docking = lawVisible && law.docked
            let editorWidth = docking ? max(0, geometry.size.width - law.dockWidth - 6) : geometry.size.width
            let size = PageSize(width: editorWidth, height: geometry.size.height)
            let split = workspace.secondary != nil && !docking
            let current = arrangement
            let stack = current.vertical && split ? AnyLayout(VStackLayout(spacing: split ? SplitPaneArrangement.gap : 0))
                : AnyLayout(HStackLayout(spacing: split ? SplitPaneArrangement.gap : 0))
            ZStack(alignment: .topLeading) {
                stack {
                    ForEach(entries(current)) { entry in
                        let hidden = docking && entry.pane == .secondary
                        let frame = hidden ? PageRect(x: 0, y: 0, width: 0, height: 0) : (split ? current.frame(of: entry.pane, in: size) : PageRect(x: 0, y: 0, width: size.width, height: size.height))
                        let preservedSize = PageSize(width: geometry.size.width, height: geometry.size.height)
                        let preservedFrame = current.frame(of: entry.pane, in: preservedSize)
                        paneView(entry, split: hidden ? true : split, current: current, size: hidden ? preservedSize : size)
                            .frame(width: max(0, hidden ? preservedFrame.width : frame.width), height: max(0, hidden ? preservedFrame.height : frame.height))
                            .frame(width: max(0, frame.width), height: max(0, frame.height), alignment: .topLeading)
                            .clipped()
                            .opacity(hidden ? 0 : (paneDrag?.pane == entry.pane ? 0.4 : 1))
                            .allowsHitTesting(!hidden).accessibilityHidden(hidden)
                    }
                }
                .frame(width: editorWidth, height: geometry.size.height, alignment: .topLeading)
                .offset(x: docking && laws.panelOnLeft ? law.dockWidth + 6 : 0)
                if split {
                    divider(current, size: size)
                    if let paneDrag { dropPreview(paneDrag, arrangement: current, size: size).allowsHitTesting(false).transition(.opacity) }
                    if let dividerFraction { resizePreview(dividerFraction, arrangement: current, size: size).allowsHitTesting(false).transition(.opacity) }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            .overlay {
                if lawsEnabled { lawLayer(law, shown: lawShown, visible: lawVisible, stashed: lawStashed) }
            }
            // Panes clip themselves already; this keeps a stashed law window
            // from drawing beyond the workspace edge.
            .clipped()
            .onChange(of: docking) { _, docked in
                if docked && workspace.activePane == 1 {
                    // Finish marked/IME text while its original pane still owns
                    // input, before deactivating the preserved secondary view.
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    workspace.activePane = 0
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
            .sensoryFeedback(.selection, trigger: lawDrag.flatMap { $0.drop == .stay ? nil : $0.drop })
        }
        // A cancelled gesture never reaches onEnded: drop the preview.
        .onChange(of: lawResizing) { _, active in if !active { lawResizeStart = nil } }
        .onChange(of: lawDragActive) { _, active in if !active, lawDrag != nil { withAnimation(NotyMotion.panel(reduceMotion)) { lawDrag = nil } } }
        .onChange(of: paneGestureActive) { _, active in if !active { paneDrag = nil } }
        .onChange(of: dividerGestureActive) { _, active in if !active { dividerFraction = nil } }
        .sheet(item: $picker) { request in
            SecondViewPicker(library: library, primaryID: workspace.primaryDocument.id, currentID: workspace.secondaryID,
                slot: request.slot, vertical: request.vertical) { document, slot, vertical in
                picker = nil
                update { $0.vertical = vertical; $0.place(.secondary, in: slot) }
                Task {
                    await workspace.openSecondary(document)
                    if workspace.secondary != nil && laws.panelOpen && laws.docked { laws.docked = false }
                }
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
            onSecondView: { choose() }, onLaws: lawsEnabled ? {
                if laws.panelOpen && laws.stashed { withAnimation(NotyMotion.panel(reduceMotion)) { laws.stashed = false } } else { laws.panelOpen.toggle() }
            } : nil)
    }

    // MARK: Law window

    private enum LawDrop: Equatable { case stay, float(left: Bool), dock(left: Bool), stash(left: Bool) }
    private struct LawDrag: Equatable {
        var translation: CGSize
        var drop: LawDrop
        var fromTab: Bool
    }
    /// Geometry of the law window for one workspace size. Docking needs room
    /// for the notebook next to it; narrower workspaces always float.
    private struct LawLayout {
        let size: CGSize
        let onLeft: Bool
        let canDock: Bool
        let docked: Bool
        let dockWidth: Double
        let floatWidth: Double
        init(_ size: CGSize, width: Double, docked: Bool, onLeft: Bool) {
            self.size = size; self.onLeft = onLeft
            canDock = size.width >= 640
            self.docked = docked && canDock
            dockWidth = min(size.width, min(max(300, width), max(300, size.width - 326)))
            floatWidth = min(max(0, size.width - 20), min(max(300, width), max(300, size.width - 24)))
        }
        var width: Double { docked ? dockWidth : floatWidth }
        var margin: Double { docked ? 0 : 10 }
        /// Resting left edge of the window.
        var restingX: Double { onLeft ? margin : size.width - margin - width }
        var outward: Double { onLeft ? -1 : 1 }
        /// Shift that puts the window completely past its screen edge.
        var hiddenShift: Double { width + margin }
    }
    /// Touch width of the edge tab; the visible tab is narrower and sits at the screen edge.
    private static let lawTabTouch = 48.0

    @ViewBuilder
    private func lawLayer(_ l: LawLayout, shown: Bool, visible: Bool, stashed: Bool) -> some View {
        let side: Alignment = l.onLeft ? .leading : .trailing
        let offset = lawPanelOffset(l, stashed: stashed)
        let lifted = lawDrag.map { !$0.fromTab } ?? false
        ZStack {
            if let drop = lawDrag?.drop, lawDropChanges(drop, l) {
                lawDropPreview(drop, l).allowsHitTesting(false).transition(.opacity)
            }
            LawPanelView(drag: lawMoveGesture(l))
                .frame(width: l.width, height: max(0, l.size.height - 2 * l.margin))
                .opacity(shown ? 1 : 0).allowsHitTesting(visible).accessibilityHidden(!visible)
                .scaleEffect(lifted ? 0.97 : 1)
                .padding(l.margin)
                .overlay(alignment: l.onLeft ? .trailing : .leading) {
                    if visible && lawDrag == nil {
                        Capsule().fill(.secondary.opacity(0.5)).frame(width: 5, height: 56).frame(width: 20)
                            .contentShape(Rectangle())
                            // Measured in the fixed workspace space: the handle
                            // itself moves while the width changes.
                            .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .named(Self.space))
                                .updating($lawResizing) { _, state, _ in state = true }
                                .onChanged { drag in
                                    if lawResizeStart == nil { lawResizeStart = l.width }
                                    let width = (lawResizeStart ?? l.width) + drag.translation.width * (l.onLeft ? 1 : -1)
                                    lawWidth = min(max(300, width), max(300, l.size.width - 326))
                                }.onEnded { _ in lawResizeStart = nil })
                            .accessibilityLabel("Breite der Gesetzessammlung ändern")
                    }
                }
                .offset(offset)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: side)
            if stashed {
                lawEdgeTab(l)
                    .offset(x: offset.width - l.hiddenShift * l.outward)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: side)
                    .transition(.opacity)
            }
        }
    }

    private func lawPanelOffset(_ l: LawLayout, stashed: Bool) -> CGSize {
        guard let drag = lawDrag else { return CGSize(width: stashed ? l.hiddenShift * l.outward : 0, height: 0) }
        if stashed {
            // Pulled in by its edge tab: only horizontally, never past the resting place.
            let along = min(l.hiddenShift, max(0, l.hiddenShift + drag.translation.width * l.outward))
            return CGSize(width: along * l.outward, height: 0)
        }
        return CGSize(width: min(l.size.width - l.restingX, max(-(l.restingX + l.width), drag.translation.width)),
                      height: min(l.size.height * 0.5, max(-l.margin, drag.translation.height)))
    }

    /// The top bar drags the window like a card. Decided by what the user sees
    /// on release: mostly past an edge (or flicked out) → stashed behind an
    /// edge tab; finger at a screen edge → docked there; otherwise floating on
    /// the finger's half. Measured in the fixed workspace space because the
    /// bar itself moves with the finger.
    private func lawMoveGesture(_ l: LawLayout) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named(Self.space))
            .updating($lawDragActive) { _, state, _ in state = true }
            .onChanged { value in lawDrag = LawDrag(translation: value.translation, drop: lawDrop(value, l, flick: false), fromTab: false) }
            .onEnded { value in
                let drop = lawDrop(value, l, flick: true)
                withAnimation(NotyMotion.panel(reduceMotion)) {
                    lawDrag = nil
                    applyLawDrop(drop)
                }
            }
    }

    private func lawDrop(_ value: DragGesture.Value, _ l: LawLayout, flick: Bool) -> LawDrop {
        let t = value.translation, w = l.size.width
        let minX = l.restingX + t.width
        if minX + l.width - w > l.width * 0.5 { return .stash(left: false) }
        if -minX > l.width * 0.5 { return .stash(left: true) }
        if flick {
            let ahead = value.predictedEndTranslation.width - t.width
            if ahead > 240, value.predictedEndLocation.x > w + 60 { return .stash(left: false) }
            if ahead < -240, value.predictedEndLocation.x < -60 { return .stash(left: true) }
        }
        guard hypot(t.width, t.height) > 40 else { return .stay }
        let x = value.location.x
        if l.canDock, x < 80 { return .dock(left: true) }
        if l.canDock, x > w - 80 { return .dock(left: false) }
        return .float(left: x < w / 2)
    }

    private func lawDropChanges(_ drop: LawDrop, _ l: LawLayout) -> Bool {
        switch drop {
        case .stay: false
        case .float(let left): l.docked || left != l.onLeft
        case .dock(let left): !l.docked || left != l.onLeft
        case .stash: true
        }
    }

    private func applyLawDrop(_ drop: LawDrop) {
        switch drop {
        case .stay: break
        case .float(let left): laws.docked = false; laws.panelOnLeft = left
        case .dock(let left): laws.docked = true; laws.panelOnLeft = left
        case .stash(let left): laws.panelOnLeft = left; laws.stashed = true
        }
    }

    /// Where the window lands: docked area, floating outline or the edge tab.
    @ViewBuilder
    private func lawDropPreview(_ drop: LawDrop, _ l: LawLayout) -> some View {
        switch drop {
        case .dock(let left):
            RoundedRectangle(cornerRadius: 14).fill(Color.accentColor.opacity(0.16))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.accentColor.opacity(0.8), lineWidth: 2))
                .overlay {
                    Label("Andocken", systemImage: left ? "rectangle.lefthalf.inset.filled" : "rectangle.righthalf.inset.filled")
                        .font(.headline).foregroundStyle(Color.accentColor)
                }
                .frame(width: max(0, l.dockWidth - 8), height: max(0, l.size.height - 8))
                .padding(4)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: left ? .leading : .trailing)
        case .float(let left):
            RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.06))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.white.opacity(0.6), style: StrokeStyle(lineWidth: 2, dash: [8, 6])))
                .overlay { Label("Schweben", systemImage: "rectangle.on.rectangle").font(.headline).foregroundStyle(.white.opacity(0.85)) }
                .frame(width: l.floatWidth, height: max(0, l.size.height - 20))
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: left ? .leading : .trailing)
        case .stash(let left):
            lawTabShape(onLeft: left, highlighted: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: left ? .leading : .trailing)
        case .stay:
            EmptyView()
        }
    }

    private func lawTabShape(onLeft: Bool, highlighted: Bool = false) -> some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: onLeft ? 0 : 12, bottomLeadingRadius: onLeft ? 0 : 12,
                                           bottomTrailingRadius: onLeft ? 12 : 0, topTrailingRadius: onLeft ? 12 : 0)
        return Image(systemName: onLeft ? "chevron.compact.right" : "chevron.compact.left")
            .font(.system(size: 24, weight: .semibold))
            .foregroundStyle(highlighted ? Color.accentColor : Color.white.opacity(0.9))
            .frame(width: 30, height: 92)
            .background(Color(white: 0.28), in: shape)
            .overlay(shape.stroke(Color.white.opacity(0.18), lineWidth: 1))
            .shadow(color: .black.opacity(0.4), radius: 6)
    }

    /// The arrow tab left at the screen edge while the window is stashed, like
    /// iPad Slide Over: tap it, or pull it inward and the window follows.
    private func lawEdgeTab(_ l: LawLayout) -> some View {
        lawTabShape(onLeft: l.onLeft)
            // Larger touch area than the visible tab, extending inward only.
            .frame(width: Self.lawTabTouch, height: 140, alignment: l.onLeft ? .leading : .trailing)
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(NotyMotion.panel(reduceMotion)) { laws.stashed = false } }
            .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.space))
                .updating($lawDragActive) { _, state, _ in state = true }
                .onChanged { lawDrag = LawDrag(translation: $0.translation, drop: .stay, fromTab: true) }
                .onEnded { value in
                    let inward = -value.translation.width * l.outward, flung = -value.predictedEndTranslation.width * l.outward
                    withAnimation(NotyMotion.panel(reduceMotion)) {
                        lawDrag = nil
                        if inward > l.width * 0.25 || (inward > 12 && flung > l.width * 0.5) { laws.stashed = false }
                    }
                })
            .accessibilityElement()
            .accessibilityLabel("Gesetzessammlung hervorholen")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { withAnimation(NotyMotion.panel(reduceMotion)) { laws.stashed = false } }
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
