import SwiftUI
import NotebookCore

/// Files opened from the Files app or another app ("In noty öffnen"). The file
/// is first copied into the app (security-scoped access and a coordinated read
/// only for that copy), checked completely, then offered with a summary.
/// A library always becomes a new area. A notebook file (`.noty`, older
/// `.notybackup`) becomes a normal notebook with its exact title (or
/// „Titel (n)“) and a new identity; if its notebook already exists here, the
/// user chooses „Vorhandenes ersetzen“ (current state to the trash first) or
/// „Beide behalten“. Nothing is overwritten.
@MainActor
enum IncomingBackup {
    /// One file at a time: several files opened together would otherwise
    /// present their alerts over each other, and an alert that cannot be
    /// presented never answers.
    private static var running: Task<Void, Never>?
    static func receive(_ url: URL, library: LibraryModel, workspaces: WorkspaceAppModel) async {
        let previous = running
        let next = Task { @MainActor in
            await previous?.value
            await handle(url, library: library, workspaces: workspaces)
        }
        running = next
        await next.value
    }

    /// AirDrop, Mail and „Kopieren nach noty“ deliver copies iOS leaves in
    /// `Documents/Inbox` for the app to remove. Only files directly inside it.
    private static var inbox: URL { URL.documentsDirectory.appendingPathComponent("Inbox", isDirectory: true) }
    private static func removeFromInbox(_ url: URL) {
        guard url.standardizedFileURL.deletingLastPathComponent().path == inbox.standardizedFileURL.path else { return }
        try? FileManager.default.removeItem(at: url)
    }
    /// Launch: delivered files whose handling did not finish (still open
    /// notebook, app ended). The user decides within a day, the source stays elsewhere.
    nonisolated static func removeStaleInboxFiles(olderThan age: TimeInterval = 24 * 3600, now: Date = Date()) {
        let fm = FileManager.default
        let folder = URL.documentsDirectory.appendingPathComponent("Inbox", isDirectory: true)
        guard let files = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]) else { return }
        for file in files {
            guard let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]), values.isRegularFile == true,
                  now.timeIntervalSince(values.contentModificationDate ?? now) > age else { continue }
            try? fm.removeItem(at: file)
        }
    }

    private static func handle(_ url: URL, library: LibraryModel, workspaces: WorkspaceAppModel) async {
        let kind = url.pathExtension.lowercased()
        guard kind == "notylibrary" || NotyFile.notebookExtensions.contains(kind) else { return }
        // On a cold launch the library first loads and may reopen the last
        // notebook as a full-screen cover; present only above that, not under it.
        var waited = 0
        while !library.ready, waited < 100 { try? await Task.sleep(for: .milliseconds(100)); waited += 1 }
        try? await Task.sleep(for: .milliseconds(800))
        // Before any question: a notebook file cannot go in while one is open.
        guard kind == "notylibrary" || library.opened == nil else {
            TopAlert.show("Notizbuch geöffnet", "Bitte zuerst das Notizbuch schließen und die Datei danach erneut aus der Dateien-App öffnen.")
            return
        }
        let progress = TopAlert.progress("Datei wird geprüft …")
        let copy: URL
        do {
            copy = try BackupScratch.newFile(kind)
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let limit = kind == "notylibrary" ? LibraryArchive.maximumBytes : BackupArchive.maximumFileBytes
            try await Task.detached(priority: .userInitiated) {
                try CoordinatedBackupFiles().reading(url, metadataOnly: false) { source in _ = try BoundedFile.copy(from: source, to: copy, limit: limit) }
            }.value
        } catch {
            await TopAlert.dismiss(progress)
            TopAlert.show("Datei nicht lesbar", "Die Datei konnte nicht in noty kopiert werden. Es wurde nichts verändert.")
            return
        }
        defer { BackupScratch.remove(copy); removeFromInbox(url) }
        if kind == "notylibrary" { await offerLibrary(copy, progress: progress, workspaces: workspaces) }
        else { await offerNotebook(copy, progress: progress, library: library) }
    }

    private static func offerLibrary(_ copy: URL, progress: UIAlertController?, workspaces: WorkspaceAppModel) async {
        let prepared: PreparedLibraryRestore
        do { prepared = try await workspaces.prepareLibraryRestore(copy) }
        catch {
            await TopAlert.dismiss(progress)
            TopAlert.show("Bibliotheksbackup abgelehnt", error.localizedDescription + " Es wurde nichts verändert.")
            return
        }
        await TopAlert.dismiss(progress)
        let summary = prepared.summary
        let size = ByteCountFormatter.string(fromByteCount: Int64(summary.file.byteCount), countStyle: .file)
        let message = "Gesichert am \(summary.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(summary.notebooks.count) Notizbücher, \(summary.folderCount) Ordner, \(summary.trashedCount) Einträge im Papierkorb · \(size).\n\nWird als neuer getrennter Bereich wiederhergestellt. Die aktuelle Bibliothek bleibt unverändert."
        guard await TopAlert.ask("Bibliotheksbackup wiederherstellen?", message, confirm: "Als neuen Bereich wiederherstellen") else {
            await workspaces.discardLibraryRestore(prepared); return
        }
        let running = TopAlert.progress("Bereich wird angelegt …")
        // A running area switch is no reason to throw the checked file away.
        while workspaces.busy { try? await Task.sleep(for: .milliseconds(100)) }
        do {
            let area = try await workspaces.commitLibraryRestore(prepared)
            await TopAlert.dismiss(running)
            TopAlert.show("Als neuen Bereich wiederhergestellt", "„\(area.title)“ ist unter Einstellungen › Backup & Daten › Bereich verfügbar. Die aktuelle Bibliothek bleibt erhalten.")
        } catch {
            await workspaces.discardLibraryRestore(prepared)
            await TopAlert.dismiss(running)
            TopAlert.show("Wiederherstellung fehlgeschlagen", error.localizedDescription + " Die Datei bitte erneut öffnen.")
        }
    }

    private static func offerNotebook(_ copy: URL, progress: UIAlertController?, library: LibraryModel) async {
        let decoded: DecodedBackup
        // One streaming pass (format 2: every asset verified, nothing kept).
        do { decoded = try await Task.detached(priority: .userInitiated) { try BackupArchive.verify(copy) }.value }
        catch {
            await TopAlert.dismiss(progress)
            TopAlert.show("Heft-Datei abgelehnt", error.localizedDescription + " Es wurde nichts verändert.")
            return
        }
        await TopAlert.dismiss(progress)
        let document = decoded.document, trashed = document.deletedPages?.count ?? 0
        let summary = "„\(document.title)“ · \(document.pages.count) Seiten" + (trashed > 0 ? ", \(trashed) im Seitenpapierkorb" : "")
            + (decoded.isLegacyJSON ? " · altes Format ohne Prüfsumme" : "")
        let collision: LibraryModel.ImportCollision?
        if let existing = library.snapshot.activeNotebook(document.id) {
            let message = summary + ".\n\nDieses Heft liegt bereits als „\(existing.title)“ in der Bibliothek. "
                + "„Vorhandenes ersetzen“ legt dessen aktuellen Stand vorher in den Papierkorb, die Datei kommt an seine Stelle. "
                + "„Beide behalten“ legt die Datei als „\(NotebookTitles.unique(document.title, taken: library.snapshot.activeNotebookTitles()))“ daneben."
            guard let choice = await TopAlert.choose("Heft schon vorhanden", message, actions: [
                ("Vorhandenes ersetzen", .destructive, LibraryModel.ImportCollision.replace),
                ("Beide behalten", .default, .keepBoth)]) else { return }
            collision = choice
        } else {
            let title = NotebookTitles.unique(document.title, taken: library.snapshot.activeNotebookTitles())
            let message = summary + ".\n\nWird als Heft „\(title)“ in die Bibliothek übernommen. Vorhandene Notizbücher bleiben unverändert."
            guard await TopAlert.ask("Heft öffnen?", message, confirm: "In Bibliothek übernehmen") else { return }
            collision = nil
        }
        guard library.opened == nil else {
            TopAlert.show("Notizbuch geöffnet", "Bitte zuerst das Notizbuch schließen und die Datei danach erneut aus der Dateien-App öffnen.")
            return
        }
        if let imported = await library.importBackup(copy, parent: nil, collision: collision) {
            TopAlert.show("Heft übernommen", "„\(imported.title)“ liegt jetzt in der Bibliothek."
                + (imported.replaced ? " Der vorherige Stand liegt im Papierkorb." : ""))
        } else if library.error == nil, !library.importDeclined {
            TopAlert.show("Bibliothek beschäftigt", "Bitte die Datei gleich noch einmal öffnen. Es wurde nichts verändert.")
        }
    }
}

/// Alerts above whatever is on screen (also the full-screen editor), so a file
/// opened from Files is answered immediately instead of behind a cover.
@MainActor
enum TopAlert {
    static var top: UIViewController? {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        var top = (windows.first(where: \.isKeyWindow) ?? windows.first)?.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed { top = presented }
        return top
    }
    static func show(_ title: String, _ message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .cancel))
        top?.present(alert, animated: true)
    }
    static func ask(_ title: String, _ message: String, confirm: String) async -> Bool {
        await withCheckedContinuation { continuation in
            guard let top else { continuation.resume(returning: false); return }
            let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Abbrechen", style: .cancel) { _ in continuation.resume(returning: false) })
            alert.addAction(UIAlertAction(title: confirm, style: .default) { _ in continuation.resume(returning: true) })
            top.present(alert, animated: true)
        }
    }
    /// Several answers plus „Abbrechen“; nil when cancelled.
    static func choose<Choice: Sendable>(_ title: String, _ message: String, actions: [(String, UIAlertAction.Style, Choice)]) async -> Choice? {
        await withCheckedContinuation { continuation in
            guard let top else { continuation.resume(returning: nil); return }
            let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
            for (label, style, choice) in actions {
                alert.addAction(UIAlertAction(title: label, style: style) { _ in continuation.resume(returning: choice) })
            }
            alert.addAction(UIAlertAction(title: "Abbrechen", style: .cancel) { _ in continuation.resume(returning: nil) })
            top.present(alert, animated: true)
        }
    }
    static func progress(_ title: String) -> UIAlertController? {
        guard let top else { return nil }
        let alert = UIAlertController(title: title, message: "Das kann bei großen Dateien etwas dauern.", preferredStyle: .alert)
        top.present(alert, animated: true)
        return alert
    }
    static func dismiss(_ alert: UIAlertController?) async {
        guard let alert, alert.presentingViewController != nil else { return }
        await withCheckedContinuation { continuation in alert.dismiss(animated: true) { continuation.resume() } }
    }
}

/// The system share sheet for a checked `.noty` scratch file
/// (`BackupScratch.newShareFile`); the file and its folder are removed when
/// the sheet finishes (leftovers of interrupted runs: `removeStale`).
@MainActor
enum NotyShare {
    static func present(_ file: URL) {
        guard let top = TopAlert.top else { BackupScratch.removeShare(file); return }
        let sheet = UIActivityViewController(activityItems: [file], applicationActivities: nil)
        sheet.completionWithItemsHandler = { _, _, _, _ in BackupScratch.removeShare(file) }
        if let popover = sheet.popoverPresentationController {
            popover.sourceView = top.view
            popover.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
            popover.permittedArrowDirections = []
        }
        top.present(sheet, animated: true)
    }
}
