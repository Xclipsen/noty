import SwiftUI
import NotebookCore

/// Backup files opened from the Files app ("In noty öffnen"). The file is first
/// copied into the app (security-scoped access and a coordinated read only for
/// that copy), checked completely, then offered with a summary. Confirming uses
/// the existing restore paths: a library always becomes a new area, a notebook
/// backup a separate copy. Nothing existing is overwritten.
@MainActor
enum IncomingBackup {
    static func receive(_ url: URL, library: LibraryModel, workspaces: WorkspaceAppModel) async {
        let kind = url.pathExtension.lowercased()
        guard kind == "notylibrary" || kind == "notybackup" else { return }
        let progress = TopAlert.progress("Backup wird geprüft …")
        let copy: URL
        do {
            copy = try BackupScratch.newFile(kind)
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let limit = kind == "notybackup" ? BackupArchive.maximumBytes : LibraryArchive.maximumBytes
            try await Task.detached(priority: .userInitiated) {
                try CoordinatedBackupFiles().reading(url, metadataOnly: false) { source in _ = try BoundedFile.copy(from: source, to: copy, limit: limit) }
            }.value
        } catch {
            await TopAlert.dismiss(progress)
            TopAlert.show("Datei nicht lesbar", "Die Datei konnte nicht in noty kopiert werden. Es wurde nichts verändert.")
            return
        }
        defer { BackupScratch.remove(copy) }
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
        do {
            let area = try await workspaces.commitLibraryRestore(prepared)
            await TopAlert.dismiss(running)
            TopAlert.show("Als neuen Bereich wiederhergestellt", "„\(area.title)“ ist unter Einstellungen › Backup & Daten › Bereich verfügbar. Die aktuelle Bibliothek bleibt erhalten.")
        } catch {
            await TopAlert.dismiss(running)
            TopAlert.show("Wiederherstellung fehlgeschlagen", error.localizedDescription)
        }
    }

    private static func offerNotebook(_ copy: URL, progress: UIAlertController?, library: LibraryModel) async {
        let decoded: DecodedBackup
        do { decoded = try await Task.detached(priority: .userInitiated) { try BackupArchive.decode(BackupArchive.read(copy)) }.value }
        catch {
            await TopAlert.dismiss(progress)
            TopAlert.show("Heft-Backup abgelehnt", error.localizedDescription + " Es wurde nichts verändert.")
            return
        }
        await TopAlert.dismiss(progress)
        let document = decoded.document, trashed = document.deletedPages?.count ?? 0
        let message = "„\(document.title)“ · \(document.pages.count) Seiten" + (trashed > 0 ? ", \(trashed) im Seitenpapierkorb" : "")
            + (decoded.isLegacyJSON ? " · altes Format ohne Prüfsumme" : "")
            + ".\n\nWird als getrennte Kopie „\(document.title) (Wiederhergestellt)“ angelegt. Vorhandene Notizbücher bleiben unverändert."
        guard await TopAlert.ask("Heft-Backup wiederherstellen?", message, confirm: "Als Kopie wiederherstellen") else { return }
        guard library.opened == nil else {
            TopAlert.show("Notizbuch geöffnet", "Bitte zuerst das Notizbuch schließen und die Datei danach erneut aus der Dateien-App öffnen.")
            return
        }
        if let restored = await library.importBackup(copy, parent: nil) {
            TopAlert.show("Als Kopie wiederhergestellt", "„\(restored.title)“ liegt jetzt in der Bibliothek.")
        } else if library.error == nil {
            TopAlert.show("Bibliothek beschäftigt", "Bitte die Datei gleich noch einmal öffnen. Es wurde nichts verändert.")
        }
    }
}

/// Alerts above whatever is on screen (also the full-screen editor), so a file
/// opened from Files is answered immediately instead of behind a cover.
@MainActor
enum TopAlert {
    private static var top: UIViewController? {
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
