import SwiftUI
import NotebookCore

/// Settings › Backup & Daten: switch and state of the iCloud-Ablage. Shown
/// only in builds that carry an iCloud container.
struct NotebookVaultSection: View {
    @ObservedObject var vault: NotebookVaultModel
    @ObservedObject var library: LibraryModel
    @ObservedObject var workspaces: WorkspaceAppModel
    @State private var browsing = false

    var body: some View {
        if vault.available {
            Section {
                Toggle("Hefte einzeln in iCloud sichern", isOn: Binding(get: { vault.enabled }, set: { value in
                    vault.setEnabled(value)
                    if value { Task { await vault.attempt(library: library, workspaces: workspaces, force: true) } }
                }))
                .task { if vault.enabled { _ = await vault.resolve(); await vault.refreshUploadState() } }
                if vault.enabled {
                    Text(vault.statusText).font(.subheadline).foregroundStyle(.secondary)
                    if let upload = vault.uploadText {
                        Text(upload).font(.caption).foregroundStyle(vault.waitingForUpload == 0 ? Color.secondary : Color.orange)
                    }
                    if let failure = vault.failure { Text(failure).font(.caption).foregroundStyle(.orange) }
                    if vault.versionCount > 0 {
                        LabeledContent("In iCloud", value: "\(NotyText.count(vault.versionCount, "Stand", "Stände")) · "
                            + ByteCountFormatter.string(fromByteCount: Int64(vault.storedBytes), countStyle: .file))
                    }
                    if workspaces.areaID != nil {
                        Text("Gesichert wird nur „Meine Bibliothek“, nicht der geöffnete Bereich.").font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Jetzt sichern") { Task { await vault.attempt(library: library, workspaces: workspaces, force: true) } }
                        .disabled(vault.running || workspaces.areaID != nil)
                }
                Button("Stände in iCloud ansehen und zurückholen …") { browsing = true }
                    .sheet(isPresented: $browsing) { VaultBrowserView(vault: vault, library: library) }
            } header: {
                Text("iCloud-Ablage")
            } footer: {
                Text("Jedes geänderte Heft kommt als eigene Datei in den iCloud-Ordner dieser App: höchstens alle 10 Minuten und beim Verlassen der App. Es bleiben die drei neuesten Stände sowie je einer der letzten 7 Tage, 4 Wochen und 6 Monate. Belegt deinen iCloud-Speicher. Das tägliche Komplettbackup unten bleibt davon unabhängig.")
            }
        }
    }
}

/// The notebooks in the iCloud-Ablage (all devices and earlier installs),
/// grouped by today's state; a notebook opens its list of states.
struct VaultBrowserView: View {
    @ObservedObject var vault: NotebookVaultModel
    @ObservedObject var library: LibraryModel
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [VaultCatalogEntry]?
    @State private var unreadable = 0
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            Group {
                if let entries {
                    List {
                        if unreadable > 0 {
                            Text("\(NotyText.count(unreadable, "Geräteliste", "Gerätelisten")) nicht lesbar (neueres Format oder beschädigt); deren Stände fehlen hier.")
                                .font(.caption).foregroundStyle(.orange)
                        }
                        if entries.isEmpty { Text("Noch keine Hefte in der iCloud-Ablage.").foregroundStyle(.secondary) }
                        group("In der Bibliothek", entries.filter { $0.today == .active })
                        group("Heute im Papierkorb", entries.filter { $0.today == .trashed })
                        group("Gelöscht", entries.filter { $0.today == .deleted })
                    }
                    .refreshable { await load() }
                } else if let failure {
                    ContentUnavailableView("iCloud-Ablage nicht lesbar", systemImage: "icloud.slash", description: Text(failure))
                } else {
                    ProgressView("iCloud-Ablage wird gelesen …")
                }
            }
            .navigationTitle("iCloud-Ablage")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Schließen") { dismiss() } } }
        }
        .task { await load() }
    }

    @ViewBuilder private func group(_ title: String, _ entries: [VaultCatalogEntry]) -> some View {
        if !entries.isEmpty {
            Section(title) {
                ForEach(entries) { entry in
                    NavigationLink {
                        VaultVersionsView(entry: entry, vault: vault, library: library) { await load() }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Label(entry.title, systemImage: entry.isTextDocument ? "doc.text" : "book.closed").lineLimit(2)
                            Text(detail(entry)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                }
            }
        }
    }

    private func detail(_ entry: VaultCatalogEntry) -> String {
        var parts = [entry.folderPath.isEmpty ? "Oberste Ebene" : entry.folderPath.joined(separator: " › "),
                     NotyText.count(entry.versions.count, "Stand", "Stände")]
        if let newest = entry.versions.first { parts.append("zuletzt \(NotyText.listDate(newest.version.savedAt))") }
        if let today = entry.currentTitle, today != entry.title { parts.append("heute \(NotyText.quoted(today))") }
        return parts.joined(separator: " · ")
    }

    private func load() async {
        guard let root = await vault.resolve() else {
            failure = vault.statusText; return
        }
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try NotebookVault.heads(root: root, coordination: CoordinatedBackupFiles())
            }.value
            unreadable = result.unreadable
            entries = VaultCatalogEntry.catalog(heads: result.heads, current: library.snapshot)
        } catch {
            failure = "Die iCloud-Ablage konnte nicht gelesen werden. Es wurde nichts verändert."
        }
    }
}

/// The states of one notebook: each comes back as a copy (default) or, for
/// a notebook that exists today, in its place; today's state then waits in
/// the trash. Both take the checked `.noty` import path.
struct VaultVersionsView: View {
    let entry: VaultCatalogEntry
    @ObservedObject var vault: NotebookVaultModel
    @ObservedObject var library: LibraryModel
    let changed: () async -> Void
    @State private var working = false
    @State private var replacing: VaultCatalogEntry.Version?
    @State private var report: Report?
    struct Report: Identifiable { let id = UUID(); let title: String; let message: String }

    var body: some View {
        List {
            Section {
                ForEach(entry.versions) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(NotyText.listDate(item.version.savedAt))
                        Text("\(NotyText.count(item.version.pageCount, "Seite", "Seiten")) · "
                             + ByteCountFormatter.string(fromByteCount: Int64(item.version.byteCount), countStyle: .file)
                             + " · \(item.deviceName)")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button("Als Kopie zurückholen") { Task { await restore(item, replace: false) } }
                            Spacer()
                            if entry.today == .active {
                                Button("Ersetzen …", role: .destructive) { replacing = item }
                            }
                        }
                        .font(.callout).buttonStyle(.borderless)
                    }
                    .padding(.vertical, 2)
                }
            } footer: {
                Text(entry.today == .active
                     ? "„Als Kopie zurückholen“ legt den Stand als „\(entry.currentTitle ?? entry.title) (Stand …)“ neben das Heft. „Ersetzen“ legt den heutigen Stand vorher in den Papierkorb."
                     : "Das Heft kommt unter seinem damaligen Namen zurück, in seinen Ordner, falls es ihn noch gibt.")
            }
        }
        .navigationTitle(entry.title)
        .disabled(working)
        .overlay { if working { ProgressView("Wird zurückgeholt …").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
        .confirmationDialog("Heutigen Stand ersetzen?", isPresented: Binding(get: { replacing != nil }, set: { if !$0 { replacing = nil } }),
                            titleVisibility: .visible, presenting: replacing) { item in
            Button("Ersetzen", role: .destructive) { Task { await restore(item, replace: true) } }
        } message: { item in
            Text("Der heutige Stand von „\(entry.currentTitle ?? entry.title)“ kommt in den Papierkorb, der Stand vom \(NotyText.listDate(item.version.savedAt)) nimmt seinen Platz ein.")
        }
        .alert(item: $report) { report in
            Alert(title: Text(report.title), message: Text(report.message), dismissButton: .default(Text("OK")))
        }
    }

    private func restore(_ item: VaultCatalogEntry.Version, replace: Bool) async {
        guard library.opened == nil else {
            report = Report(title: "Heft geöffnet", message: "Bitte zuerst das geöffnete Heft bzw. Textdokument schließen. Es wurde nichts verändert.")
            return
        }
        guard let root = await vault.resolve() else {
            report = Report(title: "iCloud nicht erreichbar", message: vault.statusText); return
        }
        working = true
        defer { working = false }
        let local: URL
        do {
            local = try BackupScratch.newFile("notybackup")
            let id = entry.id, version = item.version
            try await Task.detached(priority: .userInitiated) {
                try NotebookVault.copyVersion(root: root, notebook: id, version: version, to: local, coordination: CoordinatedBackupFiles())
            }.value
        } catch {
            report = Report(title: "Stand nicht lesbar", message: "Der Stand konnte nicht aus iCloud geladen werden (\(error.localizedDescription)). Es wurde nichts verändert.")
            return
        }
        defer { BackupScratch.remove(local) }
        let current = library.snapshot
        let exists = current.activeNotebook(entry.id) != nil
        let title = exists && !replace
            ? LibraryBackupBrowser.copyTitle(entry.currentTitle ?? entry.title, savedAt: item.version.savedAt, withTime: true) : nil
        let collision: LibraryModel.ImportCollision? = exists ? (replace ? .replace : .keepBoth) : nil
        if let imported = await library.importBackup(local, parent: entry.destination(in: current), collision: collision, title: title) {
            report = Report(title: "Zurückgeholt", message: "„\(imported.title)“ liegt jetzt in der Bibliothek."
                            + (imported.replaced ? " Der bisherige Stand liegt im Papierkorb." : ""))
            await changed()
        } else {
            let reason = library.error ?? "Die Bibliothek ist gerade beschäftigt."
            library.error = nil
            report = Report(title: "Nicht zurückgeholt", message: reason + " Es wurde nichts verändert.")
        }
    }
}
