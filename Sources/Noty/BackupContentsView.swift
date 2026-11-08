import SwiftUI
import NotebookCore

/// A library backup compared with today's library: an automatic backup of the
/// active target, an opened `.notylibrary` file or another area of this iPad.
/// Chosen notebooks come back as a copy (default) or in place of today's
/// state, which moves to the trash first (BACKUP-RESTORE-PLAN Phase 1); „Ganze
/// Bibliothek auf diesen Stand bringen“ does that for every difference and
/// moves notebooks created since to the trash (Phase 4). Each notebook takes
/// the checked `.noty` import path (`LibraryModel.importBackup`); nothing is
/// deleted for good.
struct BackupContentsView: View {
    enum Source {
        /// An automatic backup at the active target (loaded and checked here).
        case automatic(name: String, model: ExternalBackupModel)
        /// A local `.notylibrary` (opened file, an area): the view owns it and removes it at the end.
        case file(URL, title: String)
    }
    let source: Source
    @ObservedObject var library: LibraryModel
    /// Everything selected from the start (taking over an area's notebooks).
    var selectAll = false
    /// „Als eigenen Bereich öffnen“ (only where areas exist; never in the normal noty).
    var openAsArea: ((URL) async -> Bool)?
    @Environment(\.dismiss) private var dismiss
    @State private var archiveURL: URL?
    @State private var catalog: BackupCatalog?
    @State private var limitedComparison = false
    @State private var failure: String?
    @State private var onlyDifferences = true
    @State private var selection = Set<UUID>()
    @State private var working: String?
    @State private var confirmingReplace = false
    @State private var confirmingWhole = false
    /// „Ganze Bibliothek …“ ran in this view: once is enough (a second run
    /// would replace the restored notebooks, which have new identities, again).
    @State private var ranWhole = false
    @State private var report: Report?

    struct Report: Identifiable {
        let id = UUID()
        let title: String
        let message: String
        var failed = 0
    }

    /// Phase 4 only for the own automatic backups: a foreign file or an area
    /// would move every notebook it does not hold into the trash.
    private var offersWhole: Bool { if case .automatic = source { true } else { false } }

    private var sourceTitle: String {
        switch source {
        case .automatic: "Backup"
        case .file(_, let title): title
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let catalog { contents(catalog) }
                else if let failure {
                    ContentUnavailableView("Backup nicht lesbar", systemImage: "exclamationmark.triangle", description: Text(failure))
                } else { ProgressView(working ?? "Backup wird geladen und geprüft …") }
            }
            .navigationTitle(catalog.map { "\(sourceTitle) vom \(NotyText.listDate($0.createdAt))" } ?? sourceTitle)
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
                    if offersWhole || (openAsArea != nil && archiveURL != nil) { ToolbarItem(placement: .primaryAction) {
                        Menu {
                            if offersWhole {
                                Button("Ganze Bibliothek auf diesen Stand bringen …", systemImage: "clock.arrow.2.circlepath") {
                                    confirmingWhole = true
                                }
                                // A limited comparison would count every notebook as changed.
                                .disabled(ranWhole || limitedComparison || LibraryBackupBrowser.wholeRestorePlan(catalog).isEmpty)
                            }
                            if let openAsArea, let archiveURL {
                                Button("Als eigenen Bereich öffnen …", systemImage: "square.stack") { Task {
                                    working = "Bereich wird angelegt …"
                                    let done = await openAsArea(archiveURL)
                                    working = nil
                                    if done { dismiss() }
                                } }
                            }
                        } label: { Image(systemName: "ellipsis.circle") }
                        .accessibilityLabel("Weitere Aktionen")
                    } }
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
            .confirmationDialog("Ganze Bibliothek auf diesen Stand bringen?", isPresented: $confirmingWhole, titleVisibility: .visible) {
                Button("Auf diesen Stand bringen", role: .destructive) { Task { await restoreWhole() } }
            } message: { Text(wholeMessage) }
            .alert(item: $report) { report in
                Alert(title: Text(report.title), message: Text(report.message), dismissButton: .default(Text("OK")))
            }
        }
        .task { await load() }
        .onDisappear {
            // A file source belongs to this view even if it never loaded.
            if case .file(let url, _) = source { BackupScratch.remove(url) }
            if let archiveURL { BackupScratch.remove(archiveURL) }
        }
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
                    Text("Seitdem neu: \(NotyText.count(catalog.newSince.count, "Heft", "Hefte")). Beim Zurückholen einzelner Hefte bleiben sie unverändert.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if limitedComparison {
                    Text("Ein Heft der heutigen Bibliothek ist nicht vollständig lesbar. Der Vergleich ist eingeschränkt: Vorhandene Hefte erscheinen als „geändert“.")
                        .font(.caption).foregroundStyle(.orange)
                }
                Toggle("Nur Unterschiede zeigen", isOn: $onlyDifferences)
            } footer: {
                Text("Zurückgeholte Hefte kommen als Kopie in die Bibliothek, in ihren damaligen Ordner, falls es ihn noch gibt. „Ersetzen“ legt den heutigen Stand vorher in den Papierkorb."
                     + (offersWhole ? " Unter „…“ lässt sich die ganze Bibliothek auf diesen Stand bringen." : ""))
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

    private var wholeMessage: String {
        guard let catalog else { return "" }
        let plan = LibraryBackupBrowser.wholeRestorePlan(catalog)
        var parts: [String] = []
        if !plan.bringBack.isEmpty { parts.append("\(NotyText.count(plan.bringBack.count, "Heft", "Hefte")) zurückholen") }
        if !plan.replace.isEmpty { parts.append("\(NotyText.count(plan.replace.count, "Heft", "Hefte")) auf den damaligen Stand bringen (der heutige Stand kommt in den Papierkorb)") }
        if !plan.toTrash.isEmpty { parts.append("\(NotyText.count(plan.toTrash.count, "seitdem neues Heft", "seitdem neue Hefte")) in den Papierkorb legen") }
        return parts.joined(separator: ", ") + ". Fehlende Ordner werden nach dem Backup angelegt. Kalendernotizen und Lernfelder bleiben mit ihren Heften verbunden. Nichts wird endgültig gelöscht; alles lässt sich aus dem Papierkorb zurückholen."
    }

    private func toggle(_ id: UUID) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    // MARK: Work

    private func load() async {
        guard archiveURL == nil, failure == nil else { return }
        working = "Backup wird geladen und geprüft …"
        defer { working = nil }
        switch source {
        case .automatic(let name, let model):
            guard let fetched = await model.retrieve(name) else {
                failure = model.error ?? "Dieser Backup-Stand konnte nicht geladen werden. Es wurde nichts verändert."
                model.error = nil
                return
            }
            archiveURL = fetched.url
        case .file(let url, _):
            archiveURL = url
        }
        await compare()
        if selectAll, let catalog { selection = Set(catalog.entries.map(\.id)) }
    }

    private func compare() async {
        guard let archiveURL else { return }
        working = "Wird mit der Bibliothek verglichen …"
        var current = library.snapshot, prints: [UUID: LibraryArchiveFileInfo] = [:]
        do { (current, prints) = try await library.backupComparison(); limitedComparison = false }
        catch { limitedComparison = true }
        let url = archiveURL, snapshot = current, fingerprints = prints
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
        guard let catalog else { return }
        let chosen = catalog.entries.filter { selection.contains($0.id) }
        guard !chosen.isEmpty else { return }
        // A copy next to a notebook that still exists says which state it is.
        var titles: [UUID: String] = [:], collisions: [UUID: LibraryModel.ImportCollision] = [:]
        for entry in chosen {
            let exists = entry.change == .changed || entry.change == .unchanged
            let replace = replacing && entry.change == .changed
            titles[entry.id] = exists && !replace ? LibraryBackupBrowser.copyTitle(entry.title, savedAt: catalog.createdAt) : entry.title
            collisions[entry.id] = replace ? .replace : .keepBoth
        }
        guard let outcome = await bringBack(chosen, titles: titles, collisions: collisions, catalog: catalog, folders: false) else { return }
        selection.removeAll()
        report = outcome
        await compare()
    }

    /// Phase 4: every difference back, new notebooks since into the trash.
    private func restoreWhole() async {
        guard let catalog, offersWhole, !ranWhole, !limitedComparison else { return }
        let plan = LibraryBackupBrowser.wholeRestorePlan(catalog)
        guard !plan.isEmpty else { return }
        var titles: [UUID: String] = [:], collisions: [UUID: LibraryModel.ImportCollision] = [:]
        for entry in plan.replace { titles[entry.id] = entry.title; collisions[entry.id] = .replace }
        for entry in plan.bringBack { titles[entry.id] = entry.title; collisions[entry.id] = .keepBoth }
        var message = ""
        if !(plan.replace + plan.bringBack).isEmpty {
            guard let outcome = await bringBack(plan.replace + plan.bringBack, titles: titles, collisions: collisions, catalog: catalog,
                                                folders: true) else { return }
            ranWhole = true
            message = outcome.message
            // Not everything came back: the newer notebooks stay where they are,
            // so the library is never left with less than before.
            if outcome.failed > 0 {
                selection.removeAll()
                report = Report(title: "Teilweise auf den Stand gebracht",
                                message: message + "\n\nDie seitdem neuen Hefte bleiben deshalb in der Bibliothek.")
                await compare()
                return
            }
        }
        ranWhole = true
        var trashed = 0
        working = "Seitdem neue Hefte kommen in den Papierkorb …"
        for id in plan.toTrash where library.snapshot.activeNotebook(id) != nil {
            await library.trash(id)
            if library.snapshot.isTrashed(id) { trashed += 1 }
        }
        working = nil
        if trashed > 0 { message += (message.isEmpty ? "" : "\n\n") + "\(NotyText.count(trashed, "seitdem neues Heft liegt", "seitdem neue Hefte liegen")) im Papierkorb." }
        if trashed < plan.toTrash.count { message += " \(plan.toTrash.count - trashed) ließen sich nicht verschieben." }
        selection.removeAll()
        report = Report(title: "Bibliothek auf den Stand vom \(NotyText.listDate(catalog.createdAt)) gebracht", message: message)
        await compare()
    }

    /// Extracts `entries` (one pass, checked), then imports them one by one.
    /// `folders`: a folder of the backup missing today is created again
    /// (by its path of titles); otherwise the top level. Nil when nothing ran.
    private func bringBack(_ entries: [BackupNotebookEntry], titles: [UUID: String], collisions: [UUID: LibraryModel.ImportCollision],
                           catalog: BackupCatalog, folders: Bool) async -> Report? {
        guard let archiveURL else { return nil }
        guard library.opened == nil else {
            report = Report(title: "Heft geöffnet", message: "Bitte zuerst das geöffnete Heft bzw. Textdokument schließen. Es wurde nichts verändert.")
            return nil
        }
        working = "Hefte werden zurückgeholt …"
        defer { working = nil }
        let folder: URL, files: [UUID: URL]
        do { folder = try BackupScratch.newFolder() }
        catch { report = Report(title: "Zurückholen nicht möglich", message: "Kein Platz für die Zwischendateien. Es wurde nichts verändert."); return nil }
        defer { BackupScratch.removeFolder(folder) }
        do {
            let url = archiveURL, wanted = titles
            files = try await Task.detached(priority: .userInitiated) {
                try LibraryBackupBrowser.extract(archive: url, titles: wanted, into: folder)
            }.value
        } catch {
            report = Report(title: "Zurückholen nicht möglich", message: "Die Hefte konnten nicht aus dem Backup gelesen werden. Es wurde nichts verändert.")
            return nil
        }
        var restored: [String] = [], failed: [String] = [], replaced = 0, reason: String?
        for entry in entries {
            guard let file = files[entry.id] else { failed.append(NotyText.quoted(entry.title)); continue }
            let current = library.snapshot
            let wanted = collisions[entry.id] ?? .keepBoth
            let collision: LibraryModel.ImportCollision? = current.activeNotebook(entry.id) == nil ? nil : wanted
            var parent = LibraryBackupBrowser.destination(for: entry, in: current)
            // A replaced notebook keeps today's place; only new ones need the backup's folders.
            if parent == nil, folders, collision != .replace, !entry.folderPath.isEmpty { parent = await library.folderPath(entry.folderPath) }
            if let imported = await library.importBackup(file, parent: parent, collision: collision) {
                restored.append(NotyText.quoted(imported.title))
                if imported.replaced { replaced += 1 }
            } else {
                failed.append(NotyText.quoted(entry.title))
                if reason == nil { reason = library.error }
                library.error = nil
            }
        }
        var message = restored.isEmpty ? "" : "In der Bibliothek: \(restored.joined(separator: ", "))."
        if replaced > 0 { message += " Der bisherige Stand von \(NotyText.count(replaced, "Heft", "Heften")) liegt im Papierkorb." }
        if !failed.isEmpty {
            message += (message.isEmpty ? "" : "\n\n") + "Nicht zurückgeholt: \(failed.joined(separator: ", ")). " + (reason ?? "") + " Dafür wurde nichts verändert."
        }
        return Report(title: failed.isEmpty ? NotyText.count(restored.count, "Heft zurückgeholt", "Hefte zurückgeholt") : "Teilweise zurückgeholt",
                      message: message, failed: failed.count)
    }
}
