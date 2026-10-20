import SwiftUI
import NotebookCore

@MainActor
final class WorkspaceAppModel: ObservableObject {
    static var mainRoot: URL { URL.documentsDirectory.appendingPathComponent("Noty", isDirectory: true) }
    private let store = WorkspaceStore(root: URL.documentsDirectory.appendingPathComponent("NotyWorkspaces", isDirectory: true))
    @Published var root = mainRoot
    @Published var title = "Meine Bibliothek"
    @Published var kind: WorkspaceKind?
    @Published private(set) var areaID: UUID?
    @Published var areas: [TestWorkspace] = []
    @Published var busy = false
    @Published var error: String?

    func refresh() async {
        do {
            let result = try await store.list()
            areas = result.workspaces
            if result.unreadableCount > 0 { error = "\(result.unreadableCount) Bereich(e) nicht lesbar. Dateien bleiben erhalten." }
        } catch { self.error = error.localizedDescription }
    }
    func select(_ record: TestWorkspace?) async {
        guard !busy else { return }
        do {
            if let record {
                root = try await store.directory(for: record.id)
                title = record.title; kind = record.kind; areaID = record.id
            } else { root = Self.mainRoot; title = "Meine Bibliothek"; kind = nil; areaID = nil }
        } catch { self.error = error.localizedDescription }
    }
    func createTest() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let existing = try await store.list()
            _ = try await store.createTest(title: "Test \(existing.workspaces.count + 1) · \(Date().formatted(date: .abbreviated, time: .shortened))")
            await refresh()
        } catch { self.error = error.localizedDescription }
    }
    func restoreLibrary(_ url: URL) async -> Bool {
        guard !busy else { return false }
        busy = true
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() }; busy = false }
        do {
            let prepared = try await store.prepareRestore(file: url)
            for document in prepared.bundle.documents { try EditorModelValidation.validate(document) }
            let existing = try await store.list()
            _ = try await store.commitRestore(prepared, title: "Restore \(existing.workspaces.count + 1) · \(Date().formatted(date: .abbreviated, time: .shortened))")
            await refresh()
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
}

struct WorkspaceLibraryHost: View {
    @ObservedObject var workspaces: WorkspaceAppModel
    @StateObject private var library: LibraryModel
    @StateObject private var toolbox: ToolbarSettingsModel
    @StateObject private var externalBackup: ExternalBackupModel
    @Environment(\.scenePhase) private var scenePhase
    init(workspaces: WorkspaceAppModel) {
        self.workspaces = workspaces
        _library = StateObject(wrappedValue: LibraryModel(root: workspaces.root))
        _toolbox = StateObject(wrappedValue: ToolbarSettingsModel(root: workspaces.root))
        _externalBackup = StateObject(wrappedValue: ExternalBackupModel(root: workspaces.root))
    }
    var body: some View {
        LibraryView(model: library, workspaces: workspaces).environmentObject(toolbox).environmentObject(externalBackup)
            .task {
                while !Task.isCancelled {
                    if scenePhase == .active { await externalBackup.attempt(library: library, toolbox: toolbox) }
                    do { try await Task.sleep(for: .seconds(60)) } catch { break }
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await externalBackup.attempt(library: library, toolbox: toolbox) } }
            }
    }
}

struct WorkspacePickerView: View {
    @ObservedObject var model: WorkspaceAppModel
    let onSelect: (TestWorkspace?) -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            WorkspacePickerList(model: model, onSelect: onSelect)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } } }
        }
    }
}

/// Area list shared by the sheet and Settings › Backup & Daten. Without
/// `onSelect` (e.g. while a notebook is open) areas are listed but not switchable.
struct WorkspacePickerList: View {
    @ObservedObject var model: WorkspaceAppModel
    let onSelect: ((TestWorkspace?) -> Void)?
    var body: some View {
        List {
            Section {
                areaButton("Meine Bibliothek", icon: "books.vertical", current: model.areaID == nil) { onSelect?(nil) }
                Text("Test- und Restore-Bereiche haben eigene Unterlagen und Werkzeugeinstellungen. Alle liegen im App-Container; ein externes Backup bleibt nötig.")
                    .font(.caption).foregroundStyle(.secondary)
                if onSelect == nil {
                    Text("Bereich wechseln ist nur in der Bibliothek möglich, nicht bei geöffnetem Notizbuch.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Getrennte Bereiche") {
                ForEach(model.areas) { area in
                    Button { onSelect?(area) } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Label(area.title, systemImage: area.kind == .test ? "flask" : "archivebox")
                                Text(area.createdAt, format: .dateTime.day().month().hour().minute().second()).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if model.areaID == area.id {
                                Image(systemName: "checkmark").foregroundStyle(Color.accentColor).accessibilityLabel("Aktueller Bereich")
                            }
                        }
                    }.disabled(onSelect == nil)
                }
                if model.areas.isEmpty { Text("Noch keine getrennten Bereiche.").foregroundStyle(.secondary) }
                Button("Neuen Testbereich anlegen", systemImage: "plus") { Task { await model.createTest() } }
                if model.busy { ProgressView() }
            }
        }
        .disabled(model.busy)
        .navigationTitle("Bereiche")
        .task { await model.refresh() }
    }
    private func areaButton(_ title: String, icon: String, current: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Label(title, systemImage: icon)
                Spacer()
                if current { Image(systemName: "checkmark").foregroundStyle(Color.accentColor).accessibilityLabel("Aktueller Bereich") }
            }
        }.disabled(onSelect == nil)
    }
}
