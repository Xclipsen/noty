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
    /// Switching views first commits a held stroke of the old view: afterwards
    /// it may no longer write (`isPaneActive`).
    @Published var activePane = 0 { willSet { if newValue != activePane { WorksheetView.settleHeldStrokes() } } }
    @Published var closing = false
    @Published var error: String?
    private var models: [UUID: EditorModel]
    init(document: OpenNotebook, root: URL) {
        self.root = root; primaryDocument = document
        primary = EditorModel(storageRoot: document.directory,
            restoreDirectory: root.appendingPathComponent("Restores", isDirectory: true),
            preferredPageID: document.preferredPageID, libraryTitle: document.title)
        models = [document.id: primary]
        InputProbe.register("Arbeitsbereich", state: { [weak self] in self?.probeState })
        // Paused input blocks writing and moving; long busy is reported later
        // (a big notebook may load slowly).
        InputProbe.lock("Pause", after: 15) { [weak self] in
            guard let self else { return nil }
            return (models.values.contains { $0.mutationsPaused }, probeState)
        }
        InputProbe.lock("Beschäftigt", after: 90) { [weak self] in
            guard let self else { return nil }
            return (models.values.contains { $0.busy }, probeState)
        }
    }
    /// Stage of a running backup commit, for input reports (`InputProbe`).
    private var commitStage = ""
    private var probeState: String {
        "ansicht=\(activePane) zweite=\(secondary != nil) schließt=\(closing) backup-commit=\(commitStage.isEmpty ? "-" : commitStage) | "
            + models.values.map(\.probeState).joined(separator: " | ")
    }
    /// The single writer of an open notebook (either view), for filing a
    /// shared file into it (`IncomingFiling`).
    func model(for id: UUID) -> EditorModel? { models[id] }
    /// Either view holds this notebook (also while it is being closed).
    func holds(_ id: UUID) -> Bool { models[id] != nil }
    /// The model of the view the user works in.
    func openSecondary(_ document: OpenNotebook) async {
        guard !closing else { return }
        // Reserved before waiting for the old second view: no library append
        // (or any other writer) can commit to this package between now and
        // the new model's load (`PackageWriteLock`). A pane holding it already
        // owns the claim.
        var reservation: PackageWriteLock.Claim?
        if models[document.id] == nil {
            guard let claim = PackageWriteLock.shared.claim(document.directory) else {
                error = "Dieses Heft wird gerade ergänzt oder ist an anderer Stelle geöffnet. Bitte gleich noch einmal öffnen."; return
            }
            reservation = claim
        }
        closing = true; defer { closing = false }
        if let secondary, secondary !== primary, secondaryID != document.id {
            // A failed flush keeps the old view; the reservation ends with this call.
            guard await secondary.flushBeforeClosing() else { reservation?.release(); return }
            if let secondaryID { models.removeValue(forKey: secondaryID) }
        }
        let model: EditorModel
        if let existing = models[document.id] { reservation?.release(); model = existing }
        else {
            model = EditorModel(storageRoot: document.directory,
                restoreDirectory: root.appendingPathComponent("Restores", isDirectory: true),
                preferredPageID: document.preferredPageID, libraryTitle: document.title, writeClaim: reservation)
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
            closing = false; commitStage = ""
        }
        commitStage = "Werkzeugeinstellungen"
        guard await toolbox.flush() else { return .failed }
        guard models.values.allSatisfy({ !$0.busy && !$0.inputInProgress }) else { return .busy }
        commitStage = "Speichern"
        for model in models.values { model.save() }
        commitStage = "Warten auf Speichern"
        for model in models.values { if !(await model.waitForSave()) { return .failed } }
        return .committed
    }
    static let blockedTitle = "Heft kann nicht gespeichert werden"
    static func blockedMessage(_ reason: String) -> String {
        "\(reason)\n\nDer zuletzt gespeicherte Stand bleibt erhalten. Beim Schließen gehen die Änderungen seitdem verloren."
    }
    static let blockedConfirm = "Ohne Speichern schließen"
    /// Saving cannot succeed for a pane: the user may leave it anyway, then
    /// the others close as usual.
    func closeAbandoningBlockedPanes() async -> Bool {
        let blocked = models.values.filter { $0.saveBlocked != nil }
        guard !closing, let reason = blocked.first?.saveBlocked,
              await TopAlert.ask(Self.blockedTitle, Self.blockedMessage(reason), confirm: Self.blockedConfirm) else { return false }
        for model in blocked { model.abandonUnsavedChanges() }
        return await closeAll()
    }
    func closeAll() async -> Bool {
        guard !closing else { return false }
        closing = true; defer { closing = false }
        // Persist every owner first. Only disable the owners after all saves
        // succeeded, otherwise one failed pane could strand its sibling.
        for model in models.values {
            if model.busy || model.imageReading { error = "Bitte den laufenden Vorgang abwarten."; return false }
            model.save()
        }
        for model in models.values { if !(await model.waitForSave()) { return false } }
        for model in models.values { model.writable = false }
        // After every pane's last commit: each package's asset GC.
        for model in models.values { await model.collectAssetGarbageAfterClosing() }
        for model in models.values { model.releaseWriteClaim() }
        return true
    }
}

struct EditorWorkspaceView: View {
    @EnvironmentObject private var laws: LawLibraryModel
    /// Open/stashed/docked, edge, live width and height of the law window.
    @EnvironmentObject private var lawPanel: LawPanelModel
    @AppStorage(LawLibraryModel.enabledKey) private var lawsEnabled = false
    @State private var lawResizeStart: Double?
    @GestureState private var lawResizing = false
    /// Live drag of the law window's top bar or of its edge tab, with the drop
    /// that releasing now would perform (shown as a preview).
    @State private var lawDrag: LawDrag?
    /// The edge tab's drag (the bar reports its own cancellation).
    @GestureState private var lawDragActive = false
    /// Top of the workspace in app-window points while the scene is a window
    /// (not full screen): the law window's bar then leaves the band free that
    /// moves the app window (`LawPanelLayout.windowDragClearance`).
    @State private var appWindowTop: CGFloat?
    /// Set once the law window was on screen; the reader is created only then
    /// and kept while parked, dropped again when the window closes (B14).
    @State private var lawReaderLoaded = false
    /// Shown for a moment when docking hides the second notebook.
    @State private var lawDockHint: UUID?
    /// A field of the law window is typed into (`LawKeyboard.fieldEditing`):
    /// only then does the window move above the on-screen keyboard.
    @State private var lawFieldTyping = false
    /// What Apple Pencil does in the law reader (`none`/`marker`/`eraser`).
    @AppStorage("noty.laws.pencil") private var lawPencil = "none"
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
        // The law window is laid out on the whole workspace (a docked window
        // must not start floating because a keyboard appeared); the keyboard
        // is the difference of both readers. The notebooks give way to it as
        // before the law window (`LawPanelLayout.notebookFrame`, a vertical
        // split keeps its lower notebook above it); the window only while one
        // of its own fields types, so it never covers notebook text being typed.
        GeometryReader { avoiding in
        GeometryReader { geometry in
            let lawPhase: LawPanelState.Phase = lawsEnabled ? lawPanel.phase : .closed
            let lawVisible = lawPhase == .visible
            let keyboard = max(0, geometry.size.height - avoiding.size.height)
            // A stashed window keeps its docked/floating shape for the way back
            // but gives the notebook its full width meanwhile.
            let law = LawPanelLayout(size: PageSize(width: geometry.size.width, height: geometry.size.height),
                                     width: lawPanel.width, height: lawPanel.height, docked: lawPanel.docked, edge: lawPanel.edge,
                                     keyboard: keyboard, avoidsKeyboard: lawVisible && lawFieldTyping)
            let docking = lawVisible && law.docked
            let hidesSecond = docking && workspace.secondary != nil
            // Docked at a side or along the bottom: the notebooks keep the rest.
            let notebookArea = docking ? law.notebookFrame : PageRect(x: 0, y: 0, width: geometry.size.width, height: law.freeHeight)
            // Notebooks at the bottom reach on under the keyboard as before:
            // their viewport keeps its size and measures the keyboard itself.
            let overhang = docking ? law.notebookOverhang : keyboard
            let editorWidth = notebookArea.width
            let size = PageSize(width: editorWidth, height: notebookArea.height)
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
                        let reach = frame.y + frame.height >= size.height - 0.5 ? overhang : 0
                        paneView(entry, split: hidden ? true : split, current: current, size: hidden ? preservedSize : size)
                            .frame(width: max(0, hidden ? preservedFrame.width : frame.width), height: max(0, hidden ? preservedFrame.height : frame.height + reach))
                            .frame(width: max(0, frame.width), height: max(0, frame.height), alignment: .topLeading)
                            .clipped()
                            .opacity(hidden ? 0 : (paneDrag?.pane == entry.pane ? 0.4 : 1))
                            .allowsHitTesting(!hidden).accessibilityHidden(hidden)
                    }
                }
                .frame(width: editorWidth, height: notebookArea.height, alignment: .topLeading)
                .offset(x: notebookArea.x, y: notebookArea.y)
                if split {
                    divider(current, size: size)
                    if let paneDrag { dropPreview(paneDrag, arrangement: current, size: size).allowsHitTesting(false).transition(.opacity) }
                    if let dividerFraction { resizePreview(dividerFraction, arrangement: current, size: size).allowsHitTesting(false).transition(.opacity) }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            .background(AppWindowPlacementReader { top in if appWindowTop != top { appWindowTop = top } })
            .overlay {
                if lawsEnabled { lawLayer(law, phase: lawPhase, hidesSecond: workspace.secondary != nil) }
            }
            .overlay(alignment: .top) {
                if lawDockHint != nil && hidesSecond { lawDockHintView(in: notebookArea).transition(.opacity) }
            }
            // Panes clip themselves already; this keeps a stashed law window
            // from drawing beyond the workspace edge.
            .clipped()
            .onReceive(LawKeyboard.shared.$fieldEditing.removeDuplicates()) { typing in
                guard typing != lawFieldTyping else { return }
                withAnimation(NotyMotion.panel(reduceMotion)) { lawFieldTyping = typing }
            }
            .onChange(of: lawPhase, initial: true) { _, phase in
                if phase == .visible { lawReaderLoaded = true } else if phase == .closed { lawReaderLoaded = false }
            }
            .onChange(of: hidesSecond) { _, hides in
                withAnimation(NotyMotion.highlight(reduceMotion)) { lawDockHint = hides ? UUID() : nil }
                if hides { AccessibilityNotification.Announcement(Self.lawDockHintText).post() }
            }
            .task(id: lawDockHint) {
                guard lawDockHint != nil else { return }
                do { try await Task.sleep(for: .seconds(4)) } catch { return }
                withAnimation(NotyMotion.highlight(reduceMotion)) { lawDockHint = nil }
            }
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
        .ignoresSafeArea(.keyboard, edges: .bottom)
        }
        // A cancelled gesture never reaches onEnded: drop the preview.
        .onChange(of: lawResizing) { _, active in
            if !active {
                lawResizeStart = nil
                lawPanel.saveSize()
            }
        }
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
                    // A second notebook is never hidden by a docked window it was opened beside.
                    if workspace.secondary != nil && lawPanel.isOpen && lawPanel.docked { lawPanel.docked = false }
                }
            }
        }
        .alert("Ansichten", isPresented: Binding(get: { workspace.error != nil }, set: { if !$0 { workspace.error = nil } })) {
            Button("OK") { workspace.error = nil }.keyboardShortcut(.defaultAction)
        } message: { Text(workspace.error ?? "") }
        .onAppear { library.editorCommit = { await workspace.commitForBackup(toolbox: toolbox) }; library.workspace = workspace }
        .onDisappear { library.editorCommit = nil; if library.workspace === workspace { library.workspace = nil } }
        .interactiveDismissDisabled()
    }

    private func paneView(_ entry: PaneEntry, split: Bool, current: SplitPaneArrangement, size: PageSize) -> some View {
        VStack(spacing: 0) {
            if split { paneStrip(entry, current: current, size: size) }
            pane(entry.model, index: entry.pane.rawValue)
        }
    }

    private func pane(_ model: EditorModel, index: Int) -> some View {
        let panelModel = lawPanel
        return ContentView(model: model, isRestoredCopy: false, isLibraryDocument: true, initialSearchBounds: index == 0 ? workspace.primaryDocument.searchBounds : nil,
            initialFlowRange: index == 0 ? workspace.primaryDocument.searchFlowRange : nil,
            isPaneActive: { workspace.activePane == index && !workspace.closing }, isPaneSelected: { workspace.activePane == index }, onActivatePane: { workspace.activePane = index },
            onCloseWorkspace: { Task {
                // Toolbar settings are no reason to keep a notebook open.
                _ = await toolbox.flush()
                var closed = await workspace.closeAll()
                if !closed { closed = await workspace.closeAbandoningBlockedPanes() }
                if closed { library.notebookClosedByUser(); dismiss() }
            } },
            onSecondView: { choose() }, onLaws: lawsEnabled ? {
                // Real switch: closed → open, parked → brought out, visible → closed.
                _ = panelModel.toggle()
            } : nil, lawsPhase: lawsEnabled ? { panelModel.phase } : nil, onLawKeys: lawsEnabled ? {
                // Opens with the keys; a reader created by this opening takes
                // the set focus when it appears (no timed second request).
                if !LawKeyboard.shared.openWithKeys() { panelModel.open(); laws.keyFocus += 1 }
            } : nil, onToolChange: { tool in
                // Picking the highlighter or an eraser in the active notebook
                // switches the law reader along; other tools leave its choice.
                guard workspace.activePane == index else { return }
                switch tool {
                case .marker: lawPencil = "marker"
                case .strokeEraser, .precisionEraser: lawPencil = "eraser"
                default: break
                }
            })
    }

    // MARK: Law window

    private struct LawDrag: Equatable {
        var translation: CGSize
        var drop: LawPanelDrop
        var fromTab: Bool
    }
    /// Touch width of the edge tab; the visible tab is narrower and sits at the screen edge.
    private static let lawTabTouch = 48.0
    static let lawDockHintText = "Zweites Heft ausgeblendet – kommt zurück, sobald die Gesetze wieder schweben"

    private func lawAlignment(_ edge: LawPanelEdge) -> Alignment {
        switch edge { case .left: .leading; case .right: .trailing; case .bottom: .bottom }
    }

    /// The tab sits mid-edge, exactly where a toolbar docked at the same edge
    /// has its buttons; then it moves to the end of that edge.
    private func lawTabClearsToolbar(_ edge: LawPanelEdge) -> Bool {
        switch (edge, toolbox.preferences.effectiveDock) {
        case (.left, .left), (.right, .right), (.bottom, .bottom): true
        default: false
        }
    }
    private func lawTabAlignment(_ edge: LawPanelEdge) -> Alignment {
        guard lawTabClearsToolbar(edge) else { return lawAlignment(edge) }
        switch edge { case .left: return .bottomLeading; case .right, .bottom: return .bottomTrailing }
    }
    private func lawTabEdges(_ edge: LawPanelEdge) -> Edge.Set { edge == .bottom ? .trailing : .bottom }

    /// Window, edge tab and drop preview. A closed window is not in the view
    /// tree at all; a parked one keeps its reader (B14). Every way in or out
    /// (✕, „An den Rand“, tab, its ✕, menus, keys, dragging) animates the
    /// same: along the window's edge, with `NotyMotion.panel`.
    @ViewBuilder
    private func lawLayer(_ l: LawPanelLayout, phase: LawPanelState.Phase, hidesSecond: Bool) -> some View {
        let visible = phase == .visible, stashed = phase == .parked
        let offset = lawPanelOffset(l, stashed: stashed)
        let lifted = lawDrag.map { !$0.fromTab } ?? false
        let frame = l.frame
        let out = CGSize(width: l.hiddenShift * l.outward.x, height: l.hiddenShift * l.outward.y)
        let preview = lawDrag.flatMap { l.changes($0.drop) ? $0.drop : nil }
        // Measured at the resting place: the strip does not change while dragging.
        let windowClearance = CGFloat(LawPanelLayout.windowDragClearance(barTopInWindow: appWindowTop.map { Double($0) + frame.y }))
        ZStack {
            // Own container: only the preview animates when its target changes.
            ZStack {
                if let preview {
                    lawDropPreview(preview, l, hidesSecond: hidesSecond && preview.docks).transition(.opacity)
                }
            }
            .allowsHitTesting(false)
            .animation(NotyMotion.highlight(reduceMotion), value: preview)
            if phase != .closed {
                LawPanelView(move: lawMoveActions(l), moveSpace: Self.space, windowDragClearance: windowClearance, pen: lawPen, onPenChange: { next in
                    lawPencil = next.kind == .marker ? "marker" : next.kind == .eraser ? "eraser" : "none"
                    // One highlighter colour for notebook and law reader.
                    if next.color != toolbox.preferences.markerColor { toolbox.preferences.markerColor = next.color }
                }, canDock: l.canDock, docked: l.docked, dragging: lifted,
                   loadsReader: lawReaderLoaded || visible, hidesSecondNotebook: hidesSecond)
                    .frame(width: frame.width, height: frame.height)
                    .allowsHitTesting(visible).accessibilityHidden(!visible)
                    .scaleEffect(lifted && !reduceMotion ? 0.97 : 1)
                    .padding(l.margin)
                    .overlay(alignment: l.edge == .left ? .trailing : l.edge == .right ? .leading : .top) {
                        if visible && lawDrag == nil { lawResizeHandle(l) }
                    }
                    .offset(offset)
                    .position(x: frame.x + frame.width / 2, y: frame.y + frame.height / 2)
                    // Opening and closing slide along the same way as parking.
                    .transition(.offset(out))
            }
            if stashed {
                lawEdgeTab(l)
                    .offset(x: offset.width - out.width, y: offset.height - out.height)
                    .padding(lawTabEdges(l.edge), lawTabClearsToolbar(l.edge) ? 24 : 0)
                    .padding(.bottom, l.keyboard)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: lawTabAlignment(l.edge))
                    .transition(.opacity)
            }
        }
        .notyTooltipHost()
    }

    /// Near the bottom of the notebooks, away from a toolbar at the top; near
    /// the top when the toolbar is docked at the bottom.
    private func lawDockHintY(in area: PageRect) -> CGFloat {
        let top = CGFloat(area.y) + 72
        if toolbox.preferences.effectiveDock == .bottom { return top }
        return max(top, CGFloat(area.y + area.height) - 120)
    }
    /// Short note over the notebooks when docking hides the second one; at
    /// the edge away from the notebook toolbar, never over it.
    private func lawDockHintView(in area: PageRect) -> some View {
        Label(Self.lawDockHintText, systemImage: "eye.slash")
            .font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
            .lineLimit(2).multilineTextAlignment(.center)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Color(white: 0.11).opacity(0.96), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.16), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
            .frame(maxWidth: max(0, area.width - 32))
            .position(x: area.x + area.width / 2, y: lawDockHintY(in: area))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    /// Width handle on the inner edge of a side window, height handle on the
    /// top edge of a bottom window. Measured in the fixed workspace space: the
    /// handle itself moves while the size changes. Brightens while held.
    private func lawResizeHandle(_ l: LawPanelLayout) -> some View {
        let bottom = l.edge == .bottom
        return Capsule().fill(.white.opacity(lawResizing ? 0.9 : 0.5))
            .frame(width: bottom ? 44 : 5, height: bottom ? 5 : 44)
            .scaleEffect(lawResizing && !reduceMotion ? 1.15 : 1)
            .shadow(color: .black.opacity(0.35), radius: 3)
            .frame(width: bottom ? 120 : 20, height: bottom ? 20 : 120)
            .contentShape(Rectangle())
            .animation(NotyMotion.highlight(reduceMotion), value: lawResizing)
            // Docked at the bottom the handle straddles the seam instead of the top bar (the grip).
            .offset(y: bottom && l.docked ? -10 : 0)
            .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .named(Self.space))
                .updating($lawResizing) { _, state, _ in state = true }
                .onChanged { drag in
                    if bottom {
                        if lawResizeStart == nil { lawResizeStart = l.frame.height }
                        let height = (lawResizeStart ?? l.frame.height) - drag.translation.height
                        // Above an open keyboard: the handle cannot be dragged into it.
                        lawPanel.height = min(max(LawPanelLayout.minimumHeight, height), l.heightLimit)
                    } else {
                        if lawResizeStart == nil { lawResizeStart = l.frame.width }
                        let width = (lawResizeStart ?? l.frame.width) + drag.translation.width * (l.edge == .left ? 1 : -1)
                        lawPanel.width = min(max(LawPanelLayout.minimumWidth, width), l.widthLimit)
                    }
                }.onEnded { _ in lawResizeStart = nil })
            .sensoryFeedback(.selection, trigger: lawResizing) { _, active in active }
            .accessibilityLabel(bottom ? "Höhe der Gesetzessammlung ändern" : "Breite der Gesetzessammlung ändern")
            .notyTooltip(bottom ? "Höhe ändern" : "Breite ändern")
    }

    /// Marking uses the notebook highlighter's colour and straightening options.
    private var lawPen: LawPenMode {
        let preferences = toolbox.preferences
        let kind: LawPenMode.Kind = lawPencil == "marker" ? .marker : lawPencil == "eraser" ? .eraser : .none
        return LawPenMode(kind: kind, color: preferences.markerColor, straight: preferences.markerStraight ?? false, holdStraighten: preferences.markerHoldStraighten ?? true)
    }

    private func lawPanelOffset(_ l: LawPanelLayout, stashed: Bool) -> CGSize {
        let out = l.outward
        guard let drag = lawDrag else {
            return stashed ? CGSize(width: l.hiddenShift * out.x, height: l.hiddenShift * out.y) : .zero
        }
        if stashed {
            // Pulled in by its edge tab: only along its axis, never past the resting place.
            let inward = -(drag.translation.width * out.x + drag.translation.height * out.y)
            let along = min(l.hiddenShift, max(0, l.hiddenShift - inward))
            return CGSize(width: along * out.x, height: along * out.y)
        }
        let offset = l.dragOffset(PagePoint(x: drag.translation.width, y: drag.translation.height))
        return CGSize(width: offset.x, height: offset.y)
    }

    /// The top bar drags the window like a card; `LawPanelLayout.drop`
    /// decides on release (stash behind an edge tab, dock left/right/bottom,
    /// or float). Measured in the fixed workspace space because the bar
    /// itself moves with the finger (`lawWindowMove`, UIKit pan on iOS 18+
    /// so the app window's own drag waits for it).
    private func lawMoveActions(_ l: LawPanelLayout) -> LawMoveActions {
        LawMoveActions(changed: { sample in
            lawDrag = LawDrag(translation: sample.translation, drop: lawDrop(sample, l), fromTab: false)
        }, ended: { sample in
            let drop = lawDrop(sample, l)
            withAnimation(NotyMotion.panel(reduceMotion)) {
                lawDrag = nil
                lawPanel.apply(drop)
            }
        }, cancelled: {
            // A cancelled drag never reaches `ended`: drop the preview.
            if lawDrag != nil { withAnimation(NotyMotion.panel(reduceMotion)) { lawDrag = nil } }
        })
    }

    private func lawDrop(_ sample: LawMoveSample, _ l: LawPanelLayout) -> LawPanelDrop {
        l.drop(translation: PagePoint(x: sample.translation.width, y: sample.translation.height),
               location: PagePoint(x: sample.location.x, y: sample.location.y),
               predictedTranslation: sample.predictedTranslation.map { PagePoint(x: $0.width, y: $0.height) },
               predictedLocation: sample.predictedLocation.map { PagePoint(x: $0.x, y: $0.y) })
    }

    /// Where the window lands: docked area, floating outline or the edge tab,
    /// drawn like the pane drop preview (accent area, label in a capsule).
    @ViewBuilder
    private func lawDropPreview(_ drop: LawPanelDrop, _ l: LawPanelLayout, hidesSecond: Bool) -> some View {
        switch drop {
        case .dock(let edge):
            let target = LawPanelLayout(size: l.size, width: lawPanel.width, height: lawPanel.height, docked: true, edge: edge, keyboard: l.keyboard, avoidsKeyboard: l.avoidsKeyboard).frame
            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.accentColor.opacity(0.16))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.accentColor, lineWidth: 2))
                .overlay {
                    VStack(spacing: 6) {
                        lawPreviewLabel("Andocken", symbol: edge == .left ? "rectangle.lefthalf.inset.filled"
                                        : edge == .right ? "rectangle.righthalf.inset.filled" : "rectangle.bottomhalf.inset.filled", accent: true)
                        if hidesSecond {
                            Text("Zweites Heft wird ausgeblendet").font(.caption.weight(.medium)).foregroundStyle(.white.opacity(0.9))
                        }
                    }
                }
                .frame(width: max(0, target.width - 12), height: max(0, target.height - 12))
                .position(x: target.x + target.width / 2, y: target.y + target.height / 2)
        case .float(let edge):
            let target = LawPanelLayout(size: l.size, width: lawPanel.width, height: lawPanel.height, docked: false, edge: edge, keyboard: l.keyboard, avoidsKeyboard: l.avoidsKeyboard).frame
            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white.opacity(0.06))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.6), style: StrokeStyle(lineWidth: 2, dash: [8, 6])))
                .overlay { lawPreviewLabel("Schweben", symbol: "rectangle.on.rectangle", accent: false) }
                .frame(width: max(0, target.width), height: max(0, target.height))
                .position(x: target.x + target.width / 2, y: target.y + target.height / 2)
        case .stash(let edge):
            lawTabShape(edge, highlighted: true)
                .padding(lawTabEdges(edge), lawTabClearsToolbar(edge) ? 24 : 0)
                .padding(.bottom, l.keyboard)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: lawTabAlignment(edge))
        case .stay:
            EmptyView()
        }
    }

    private func lawPreviewLabel(_ title: String, symbol: String, accent: Bool) -> some View {
        Label(title, systemImage: symbol)
            .font(.headline).foregroundStyle(.white)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Capsule().fill(accent ? Color.accentColor.opacity(0.85) : Color(white: 0.16).opacity(0.94)))
            .overlay(Capsule().strokeBorder(.white.opacity(accent ? 0 : 0.18)))
    }

    private func lawTabShape(_ edge: LawPanelEdge, highlighted: Bool = false) -> some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: edge == .left ? 0 : 12, bottomLeadingRadius: edge == .right ? 12 : 0,
                                           bottomTrailingRadius: edge == .left ? 12 : 0, topTrailingRadius: edge == .right ? 0 : 12,
                                           style: .continuous)
        let symbol = switch edge { case .left: "chevron.compact.right"; case .right: "chevron.compact.left"; case .bottom: "chevron.compact.up" }
        return Image(systemName: symbol)
            .font(.system(size: 20, weight: .regular))
            .foregroundStyle(highlighted ? Color.accentColor : Color.white.opacity(0.88))
            .frame(width: edge == .bottom ? 92 : 30, height: edge == .bottom ? 30 : 92)
            .lawGlass(shape)
            .overlay(shape.stroke(highlighted ? Color.accentColor.opacity(0.8) : Color.white.opacity(0.18), lineWidth: 1))
            .shadow(color: .black.opacity(0.4), radius: 6)
    }

    /// The tab left at the screen edge while the window is parked, like iPad
    /// Slide Over: tap it, or pull it inward and the window follows. The small
    /// ✕ beside it closes the window completely; the notebook menu
    /// „Gesetzessammlung“ opens it again.
    private func lawEdgeTab(_ l: LawPanelLayout) -> some View {
        let edge = l.edge, out = l.outward
        let tab = Button { lawPanel.unpark() } label: {
            lawTabShape(edge)
                // Larger touch area than the visible tab, extending inward only.
                .frame(width: edge == .bottom ? 140 : Self.lawTabTouch, height: edge == .bottom ? Self.lawTabTouch : 140,
                       alignment: lawAlignment(edge))
                .contentShape(Rectangle())
        }
            .buttonStyle(NotyPressStyle())
            .simultaneousGesture(DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.space))
                .updating($lawDragActive) { _, state, _ in state = true }
                .onChanged {
                    // Pulled in: the window follows with its reader (B14).
                    if !lawReaderLoaded { lawReaderLoaded = true }
                    lawDrag = LawDrag(translation: $0.translation, drop: .stay, fromTab: true)
                }
                .onEnded { value in
                    let inward = -(value.translation.width * out.x + value.translation.height * out.y)
                    let flung = -(value.predictedEndTranslation.width * out.x + value.predictedEndTranslation.height * out.y)
                    let extent = l.hiddenShift
                    withAnimation(NotyMotion.panel(reduceMotion)) {
                        lawDrag = nil
                        if inward > extent * 0.25 || (inward > 12 && flung > extent * 0.5) { lawPanel.unpark() }
                    }
                })
            .accessibilityLabel("Gesetzessammlung hervorholen")
            .accessibilityAction(named: "Schließen") { lawPanel.close() }
            .notyTooltip("Hervorholen (⌥⌘L)")
        let close = Button { lawPanel.close() } label: {
            Image(systemName: "xmark").font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.88))
                .frame(width: 28, height: 28)
                .lawGlass(Circle())
                .overlay(Circle().stroke(Color.white.opacity(0.18), lineWidth: 1))
                .shadow(color: .black.opacity(0.4), radius: 4)
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }
            .buttonStyle(NotyPressStyle())
            .accessibilityLabel("Gesetzessammlung schließen")
            .accessibilityHint("Schließt ganz, auch die Lasche. Wieder öffnen: Heft-Menü › Gesetzessammlung oder ⇧⌘L.")
            .notyTooltip("Ganz schließen")
        return Group {
            if edge == .bottom {
                HStack(alignment: .bottom, spacing: 6) { tab; close.padding(.bottom, -6) }
            } else {
                VStack(alignment: edge == .left ? .leading : .trailing, spacing: 6) { close.padding(edge == .left ? .leading : .trailing, -6); tab }
                    .environment(\.notyTooltipAxis, .vertical)
            }
        }
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
        model.documentLoaded ? model.notebook.title : "Heft"
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
            if entry.pane == .secondary { Button("Anderes Heft wählen …") { choose() } }
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
                    }.pickerStyle(.segmented).keyOption(.toggle($vertical))
                    Picker("Position", selection: $slot) {
                        Text(vertical ? "Oben" : "Links").tag(SplitSlot.first)
                        Text(vertical ? "Unten" : "Rechts").tag(SplitSlot.second)
                    }.pickerStyle(.segmented).keyOption(.choice($slot, SplitSlot.allCases))
                } header: { Text("Zweite Ansicht") }
                if let documents {
                    let recent = recentDocuments(documents)
                    if !recent.isEmpty {
                        Section("Zuletzt geöffnet") { ForEach(recent) { row($0) } }
                    }
                    Section(recent.isEmpty ? "Hefte" : "Alle Hefte") {
                        ForEach(documents) { row($0) }
                        if documents.isEmpty { Text("Keine Hefte verfügbar.").foregroundStyle(.secondary) }
                    }
                } else {
                    Section {
                        HStack(spacing: 10) { ProgressView(); Text("Hefte werden geladen …").foregroundStyle(.secondary) }
                            .accessibilityElement(children: .combine)
                    }
                }
            }
            .navigationTitle("Heft für zweite Ansicht")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } } }
            .task { if documents == nil { documents = await library.editorChoices() } }
        }
        .keyboardSheet()
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
                if document.id == primaryID { Text("gleiches Heft").font(.caption).foregroundStyle(.secondary) }
                if document.id == currentID { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
            }
        }
        .accessibilityValue(document.id == primaryID ? "gleiches Heft" : "")
        .keyOption(.action { onPick(document, slot, vertical) })
    }
}
