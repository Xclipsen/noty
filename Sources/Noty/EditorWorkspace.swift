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
    func backup(library: LibraryModel, toolbox: ToolbarSettingsModel) async -> Data? {
        guard !closing, models.values.allSatisfy({ !$0.busy && !$0.inputInProgress && $0.writable }) else { return nil }
        closing = true
        for model in models.values { model.pauseMutations() }
        defer {
            for model in models.values { model.resumeMutations() }
            closing = false
        }
        guard await toolbox.flush(), models.values.allSatisfy({ !$0.busy && !$0.inputInProgress }) else { return nil }
        for model in models.values { model.save() }
        for model in models.values { if !(await model.waitForSave()) { return nil } }
        return await library.libraryBackup(editorsPaused: true)
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var workspace: EditorWorkspace
    @ObservedObject var library: LibraryModel
    @EnvironmentObject private var toolbox: ToolbarSettingsModel
    @Environment(\.dismiss) private var dismiss
    @State private var choosingDocument = false
    @State private var choices: [OpenNotebook] = []
    @State private var vertical = false
    var body: some View {
        VStack(spacing: 0) {
            if workspace.secondary != nil {
                HStack {
                    Button(vertical ? "Nebeneinander" : "Untereinander", systemImage: "rectangle.split.1x2") { vertical.toggle() }
                    Spacer()
                    Button("Zweite Ansicht schließen") { Task { await workspace.closeSecondary() } }
                }.font(.subheadline).padding(.horizontal, 12).padding(.vertical, 6).disabled(workspace.closing)
            }
            let split = workspace.secondary != nil
            let layout = vertical ? AnyLayout(VStackLayout(spacing: 2)) : AnyLayout(HStackLayout(spacing: 2))
            layout {
                pane(workspace.primary, index: 0).frame(maxWidth: .infinity, maxHeight: .infinity)
                if let secondary = workspace.secondary {
                    pane(secondary, index: 1).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(split ? Color.gray.opacity(0.25) : Color.clear)
            .animation(NotyMotion.panel(reduceMotion), value: vertical)
            .animation(NotyMotion.panel(reduceMotion), value: split)
        }
        .sheet(isPresented: $choosingDocument) {
            NavigationStack {
                List(choices) { document in
                    Button(document.id == workspace.primaryDocument.id ? "\(document.title) · gleiches Heft" : document.title) {
                        choosingDocument = false; Task { await workspace.openSecondary(document) }
                    }
                }.navigationTitle("Heft für zweite Ansicht")
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { choosingDocument = false } } }
            }
        }
        .alert("Ansichten", isPresented: Binding(get: { workspace.error != nil }, set: { if !$0 { workspace.error = nil } })) {
            Button("OK") { workspace.error = nil }
        } message: { Text(workspace.error ?? "") }
        .onAppear { library.editorBackup = { await workspace.backup(library: library, toolbox: toolbox) } }
        .onDisappear { library.editorBackup = nil }
        .interactiveDismissDisabled()
    }
    private func pane(_ model: EditorModel, index: Int) -> some View {
        ContentView(model: model, isRestoredCopy: false, isLibraryDocument: true, initialSearchBounds: index == 0 ? workspace.primaryDocument.searchBounds : nil,
            isPaneActive: { workspace.activePane == index && !workspace.closing }, onActivatePane: { workspace.activePane = index },
            onCloseWorkspace: { Task { if await toolbox.flush(), await workspace.closeAll() { dismiss() } } },
            onSecondView: { Task { choices = await library.editorChoices(); choosingDocument = true } })
    }
}
