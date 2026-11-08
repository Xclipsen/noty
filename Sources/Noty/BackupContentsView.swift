import SwiftUI
import NotebookCore

/// One backup of the active target: its notebooks compared with today's
/// library; chosen notebooks come back into the library as a copy (default)
/// or in place of today's state, which moves to the trash first
/// (BACKUP-RESTORE-PLAN Phase 1). Each notebook takes the checked `.noty`
/// import path (`LibraryModel.importBackup`); nothing is overwritten.
struct BackupContentsView: View {
    let name: String
    @ObservedObject var model: ExternalBackupModel
    @ObservedObject var library: LibraryModel
    @Environment(\.dismiss) private var dismiss
    @State private var archive: PreparedLibraryArchive?
    @State private var catalog: BackupCatalog?
    @State private var limitedComparison = false
    @State private var failure: String?
    @State private var onlyDifferences = true
    @State private var selection = Set<UUID>()
    @State private var working: String?
    @State private var confirmingReplace = false
    @State private var report: Report?

    struct Report: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    var body: some View {
        NavigationStack {
            Group {
                if let catalog { contents(catalog) }
                else if let failure {
                    ContentUnavailableView("Backup nicht lesbar", systemImage: "exclamationmark.triangle", description: Text(failure))
                } else { ProgressView(working ?? "Backup wird geladen und geprüft …") }
            }
            .navigationTitle(catalog.map { "Backup vom \(NotyText.listDate($0.createdAt))" } ?? "Backup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Schließen") { dismiss() }.disabled(working != nil) }
                if let catalog {
                    ToolbarItem(placement: .primaryAction) {
                        let visible = shown(catalog).map(\.id)
                        if !visible.isEmpty, Set(visible).isSubset(of: selection) {
                            Button("Keine auswählen") { selection.subtract(visible) }
                        } else {
                            Button("Alle auswählen") { selection.formUnion(visible) }.disabled(visible.isEmpty)
                        }
                    }
                }
            }
            .overlay {
                if let working, catalog != nil {
                    ProgressView(working).padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .disabled(working != nil && catalog != nil)
            .interactiveDismissDisabled(working != nil)
            .confirmationDialog("Heutigen Stand ersetzen?", isPresented: $confirmingReplace, titleVisibility: .visible) {
                Button("Ersetzen", role: .destructive) { Task { await restore(replacing: true) } }
            } message: { Text(replaceMessage) }
            .alert(item: $report) { report in
                Alert(title: Text(report.title), message: Text(report.message), dismissButton: .default(Text("OK")))
            }
        }
        .task { await load() }
        .onDisappear { if let archive { BackupScratch.remove(archive.url) } }
    }

    // MARK: List

    private func shown(_ catalog: BackupCatalog) -> [BackupNotebookEntry] {
        onlyDifferences ? catalog.differences : catalog.entries
    }

    @ViewBuilder private func contents(_ catalog: BackupCatalog) -> some View {
        List {
            Section {
                Text(summary(catalog)).font(.subheadline)
                if !catalog.newSince.isEmpty {
                    Text("Seitdem neu: \(NotyText.count(catalog.newSince.count, "Heft", "Hefte")). Sie bleiben beim Zurückholen unverändert.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if limitedComparison {
                    Text("Ein Heft der heutigen Bibliothek ist nicht vollständig lesbar. Der Vergleich ist eingeschränkt: Vorhandene Hefte erscheinen als „geändert“.")
                        .font(.caption).foregroundStyle(.orange)
                }
                Toggle("Nur Unterschiede zeigen", isOn: $onlyDifferences)
            } footer: {
                Text("Zurückgeholte Hefte kommen als Kopie in die Bibliothek, in ihren damaligen Ordner, falls es ihn noch gibt. „Ersetzen“ legt den heutigen Stand vorher in den Papierkorb.")
            }
            let entries = shown(catalog)
            if entries.isEmpty {
                Text(onlyDifferences ? "Keine Unterschiede: Alle Hefte dieses Backups sind heute unverändert vorhanden." : "Dieses Backup enthält keine Hefte.")
                    .foregroundStyle(.secondary)
            }
            group("Seitdem endgültig gelöscht", entries.filter { $0.change == .deleted })
            group("Heute im Papierkorb", entries.filter { $0.change == .trashed })
            group("Seitdem geändert", entries.filter { $0.change == .changed })
            group("Unverändert", entries.filter { $0.change == .unchanged })
        }
        .safeAreaInset(edge: .bottom) { actions(catalog) }
    }

    @ViewBuilder private func group(_ title: String, _ entries: [BackupNotebookEntry]) -> some View {
        if !entries.isEmpty {
            Section(title) {
                ForEach(entries) { entry in
                    Button { toggle(entry.id) } label: { row(entry) }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selection.contains(entry.id) ? .isSelected : [])
                }
            }
        }
    }

    private func row(_ entry: BackupNotebookEntry) -> some View {
        HStack(spacing: 12) {
            Image(systemName: selection.contains(entry.id) ? "checkmark.circle.fill" : "circle")
                .font(.title3).foregroundStyle(selection.contains(entry.id) ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            Image(systemName: entry.isTextDocument ? "doc.text" : "book.closed").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title).lineLimit(2).truncationMode(.middle)
                Text(detail(entry)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    private func detail(_ entry: BackupNotebookEntry) -> String {
        var parts = [entry.folderPath.isEmpty ? "Oberste Ebene" : entry.folderPath.joined(separator: " › "),
                     NotyText.count(entry.pageCount, "Seite", "Seiten")]
        if let today = entry.currentTitle, today != entry.title { parts.append("heute \(NotyText.quoted(today))") }
        return parts.joined(separator: " · ")
    }

    private func summary(_ catalog: BackupCatalog) -> String {
        let differences = catalog.differences.count
        var text = "\(NotyText.count(catalog.entries.count, "Heft", "Hefte")) · "
            + (differences == 0 ? "keine Unterschiede zu heute" : "\(differences) mit Unterschied zu heute")
        if catalog.trashedInBackup > 0 { text += " · \(catalog.trashedInBackup) damals im Papierkorb (nicht aufgeführt)" }
        return text
    }

    private func actions(_ catalog: BackupCatalog) -> some View {
        let chosen = catalog.entries.filter { selection.contains($0.id) }
        return HStack {
            Button("Ersetzen …") { confirmingReplace = true }
                .disabled(!chosen.contains { $0.change == .changed })
            Spacer()
            Button {
                Task { await restore(replacing: false) }
            } label: {
                Text(chosen.isEmpty ? "Als Kopie zurückholen" : "\(NotyText.count(chosen.count, "Heft", "Hefte")) als Kopie zurückholen")
            }
            .buttonStyle(.borderedProminent)
            .disabled(chosen.isEmpty)
        }
        .padding(.horizontal).padding(.vertical, 10)
        .background(.bar)
    }

    private var replaceMessage: String {
        guard let catalog else { return "" }
        let chosen = catalog.entries.filter { selection.contains($0.id) }
        let replaced = chosen.filter { $0.change == .changed }
        var text = "\(NotyText.count(replaced.count, "Heft", "Hefte")): Der heutige Stand kommt jeweils in den Papierkorb, der Stand vom \(NotyText.listDate(catalog.createdAt)) nimmt seinen Platz ein."
        if chosen.count > replaced.count { text += " Die übrigen ausgewählten Hefte kommen als Kopie bzw. unter ihrem Namen zurück." }
        return text
    }

    private func toggle(_ id: UUID) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    // MARK: Work

    private func load() async {
        guard archive == nil, failure == nil else { return }
        working = "Backup wird geladen und geprüft …"
        defer { working = nil }
        guard let fetched = await model.retrieve(name) else {
            failure = model.error ?? "Dieser Backup-Stand konnte nicht geladen werden. Es wurde nichts verändert."
            model.error = nil
            return
        }
        archive = fetched
        await compare()
    }

    private func compare() async {
        guard let archive else { return }
        working = "Wird mit der Bibliothek verglichen …"
        var current = library.snapshot, prints: [UUID: LibraryArchiveFileInfo] = [:]
        do { (current, prints) = try await library.backupComparison(); limitedComparison = false }
        catch { limitedComparison = true }
        let url = archive.url, snapshot = current, fingerprints = prints
        do {
            catalog = try await Task.detached(priority: .userInitiated) {
                try LibraryBackupBrowser.catalog(archive: url, current: snapshot, fingerprints: fingerprints)
            }.value
        } catch {
            catalog = nil
            failure = "Der Inhalt dieses Backups konnte nicht gelesen werden. Es wurde nichts verändert."
        }
    }

    private func restore(replacing: Bool) async {
        guard let archive, let catalog else { return }
        guard library.opened == nil else {
            report = Report(title: "Heft geöffnet", message: "Bitte zuerst das geöffnete Heft bzw. Textdokument schließen. Es wurde nichts verändert.")
            return
        }
        let chosen = catalog.entries.filter { selection.contains($0.id) }
        guard !chosen.isEmpty else { return }
        working = "Hefte werden zurückgeholt …"
        defer { working = nil }
        // A copy next to a notebook that still exists says which state it is.
        var titles: [UUID: String] = [:]
        for entry in chosen {
            let exists = entry.change == .changed || entry.change == .unchanged
            let replace = replacing && entry.change == .changed
            titles[entry.id] = exists && !replace ? LibraryBackupBrowser.copyTitle(entry.title, savedAt: catalog.createdAt) : entry.title
        }
        let folder: URL, files: [UUID: URL]
        do { folder = try BackupScratch.newFolder() }
        catch { report = Report(title: "Zurückholen nicht möglich", message: "Kein Platz für die Zwischendateien. Es wurde nichts verändert."); return }
        defer { BackupScratch.removeFolder(folder) }
        do {
            let url = archive.url, wanted = titles
            files = try await Task.detached(priority: .userInitiated) {
                try LibraryBackupBrowser.extract(archive: url, titles: wanted, into: folder)
            }.value
        } catch {
            report = Report(title: "Zurückholen nicht möglich", message: "Die Hefte konnten nicht aus dem Backup gelesen werden. Es wurde nichts verändert.")
            return
        }
        var restored: [String] = [], failed: [String] = [], replaced = 0, reason: String?
        for entry in chosen {
            guard let file = files[entry.id] else { failed.append(entry.title); continue }
            let current = library.snapshot
            let collision: LibraryModel.ImportCollision? = current.activeNotebook(entry.id) == nil
                ? nil : (replacing && entry.change == .changed ? .replace : .keepBoth)
            if let imported = await library.importBackup(file, parent: LibraryBackupBrowser.destination(for: entry, in: current),
                                                         collision: collision) {
                restored.append(NotyText.quoted(imported.title))
                if imported.replaced { replaced += 1 }
            } else {
                failed.append(NotyText.quoted(entry.title))
                if reason == nil { reason = library.error }
                library.error = nil
            }
        }
        selection.removeAll()
        var message = restored.isEmpty ? "" : "In der Bibliothek: \(restored.joined(separator: ", "))."
        if replaced > 0 { message += " Der bisherige Stand von \(NotyText.count(replaced, "Heft", "Heften")) liegt im Papierkorb." }
        if !failed.isEmpty {
            message += (message.isEmpty ? "" : "\n\n") + "Nicht zurückgeholt: \(failed.joined(separator: ", ")). " + (reason ?? "") + " Dafür wurde nichts verändert."
        }
        report = Report(title: failed.isEmpty ? NotyText.count(restored.count, "Heft zurückgeholt", "Hefte zurückgeholt") : "Teilweise zurückgeholt",
                        message: message)
        await compare()
    }
}
