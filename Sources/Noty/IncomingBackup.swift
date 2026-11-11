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
    static func removeFromInbox(_ url: URL) {
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
            TopAlert.show("Heft geöffnet", "Bitte zuerst das Heft schließen und die Datei danach erneut aus der Dateien-App öffnen.")
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
        if kind == "notylibrary" {
            // Three ways (docs/LIBRARY.md 11.11.2026, BACKUP-RESTORE-PLAN Phase 4): everything into this
            // library with its folders, the contents to bring single notebooks back, or – only in the
            // test apps – a separate Bereich.
            await TopAlert.dismiss(progress)
            var actions: [(String, UIAlertAction.Style, LibraryChoice)] = [
                ("Alles in diese Bibliothek übernehmen …", .default, .merge),
                ("Inhalt ansehen und Hefte zurückholen", .default, .browse)]
            if DeveloperAccess.visible { actions.append(("Als neuen Bereich wiederherstellen", .default, .area)) }
            guard let choice = await TopAlert.choose("Bibliotheksbackup öffnen",
                "„Alles übernehmen“ legt die Ordner der Datei in dieser Bibliothek an (gleichnamige werden benutzt) und holt jedes Heft als neues Heft dazu; vorhandene Hefte bleiben unverändert. „Inhalt ansehen“ zeigt die Hefte der Datei zum einzelnen Zurückholen.",
                actions: actions) else { return }
            switch choice {
            case .area: await offerLibrary(copy, progress: nil, library: library, workspaces: workspaces)
            case .merge: await library.importFolders(from: copy, base: nil, isScratchCopy: true)
            case .browse:
                // The view takes over the checked copy (the deferred removal then finds nothing).
                guard let own = try? BackupScratch.newFile("notylibrary"), (try? FileManager.default.moveItem(at: copy, to: own)) != nil else {
                    TopAlert.show("Kein Platz", "Die Datei konnte nicht zwischengespeichert werden. Es wurde nichts verändert.")
                    return
                }
                guard RestoreRouter.shared.show(RestoreRouter.Archive(url: own, title: "Bibliotheksbackup")) else {
                    TopAlert.show("Schon ein Bibliotheksbackup geöffnet", "Bitte zuerst das geöffnete Bibliotheksbackup schließen, dann diese Datei erneut öffnen. Es wurde nichts verändert.")
                    return
                }
                if !RestoreRouter.shared.libraryFree {
                    TopAlert.show("Bibliotheksbackup", "Der Inhalt erscheint, sobald das geöffnete Heft, die Einstellungen oder das offene Fenster geschlossen sind.")
                }
            }
            return
        }
        else { await offerNotebook(copy, progress: progress, library: library) }
    }

    private enum LibraryChoice: Sendable { case merge, browse, area }

    private static func offerLibrary(_ copy: URL, progress: UIAlertController?, library: LibraryModel, workspaces: WorkspaceAppModel) async {
        let prepared: PreparedLibraryRestore
        do { prepared = try await workspaces.prepareLibraryRestore(copy) }
        catch {
            Diagnostics.failure("restore", error)
            await TopAlert.dismiss(progress)
            TopAlert.show("Bibliotheksbackup abgelehnt", error.localizedDescription + " Es wurde nichts verändert.")
            return
        }
        await TopAlert.dismiss(progress)
        let summary = prepared.summary
        let size = ByteCountFormatter.string(fromByteCount: Int64(summary.file.byteCount), countStyle: .file)
        var message = "Gesichert am \(NotyText.listDate(summary.createdAt)) · \(NotyText.count(summary.notebooks.count, "Heft", "Hefte")), \(summary.folderCount) Ordner, \(NotyText.count(summary.trashedCount, "Eintrag", "Einträge")) im Papierkorb · \(size)."
        if let calendar = summary.calendar { message += "\n\n" + NotyText.calendarRestoreSummary(calendar) }
        message += "\n\nWird als neuer getrennter Bereich wiederhergestellt. Die aktuelle Bibliothek bleibt unverändert."
        guard await TopAlert.ask("Bibliotheksbackup wiederherstellen?", message, confirm: "Als neuen Bereich wiederherstellen") else {
            await workspaces.discardLibraryRestore(prepared); return
        }
        let running = TopAlert.progress("Bereich wird angelegt …")
        // A running area switch is no reason to throw the checked file away,
        // but this dialog has no button: never wait for ever.
        var waited = 0
        while workspaces.busy, waited < 300 { try? await Task.sleep(for: .milliseconds(100)); waited += 1 }
        guard !workspaces.busy else {
            await workspaces.discardLibraryRestore(prepared)
            await TopAlert.dismiss(running)
            TopAlert.show("Bereich nicht angelegt", "Ein anderer Bereichsvorgang läuft noch. Es wurde nichts verändert. Die Datei bitte später erneut öffnen.")
            return
        }
        do {
            let area = try await workspaces.commitLibraryRestore(prepared)
            await TopAlert.dismiss(running)
            TopAlert.show("Als neuen Bereich wiederhergestellt", "„\(area.title)“: " + NotyText.restoredAreaMessage)
        } catch {
            Diagnostics.failure("restore", error)
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
            TopAlert.show(".noty-Datei abgelehnt", error.localizedDescription + " Es wurde nichts verändert.")
            return
        }
        await TopAlert.dismiss(progress)
        let document = decoded.document, trashed = document.deletedPages?.count ?? 0
        let kind = document.isTextDocument ? "Textdokument" : "Heft"
        // The file's title is shown and stored only normalised (any length, line breaks).
        let summary = "„\(NotebookTitles.sanitized(document.title))“ · \(NotyText.count(document.pages.count, "Seite", "Seiten"))" + (trashed > 0 ? ", \(trashed) im Seitenpapierkorb" : "")
            + (decoded.isLegacyJSON ? " · altes Format ohne Prüfsumme" : "")
        let collision: LibraryModel.ImportCollision?
        if let existing = library.snapshot.activeNotebook(document.id) {
            let message = summary + ".\n\nDieses \(kind) liegt bereits als „\(existing.title)“ in der Bibliothek. "
                + "„Vorhandenes ersetzen“ legt dessen aktuellen Stand vorher in den Papierkorb, die Datei kommt an seine Stelle. "
                + "„Beide behalten“ legt die Datei als „\(NotebookTitles.unique(document.title, taken: library.snapshot.activeNotebookTitles()))“ daneben."
            guard let choice = await TopAlert.choose("\(kind) schon vorhanden", message, actions: [
                ("Vorhandenes ersetzen", .destructive, LibraryModel.ImportCollision.replace),
                ("Beide behalten", .default, .keepBoth)]) else { return }
            collision = choice
        } else {
            let title = NotebookTitles.unique(document.title, taken: library.snapshot.activeNotebookTitles())
            let message = summary + ".\n\nWird als \(kind) „\(title)“ in die Bibliothek übernommen. Vorhandene Hefte und Textdokumente bleiben unverändert."
            guard await TopAlert.ask("\(kind) übernehmen?", message, confirm: "In Bibliothek übernehmen") else { return }
            collision = nil
        }
        guard library.opened == nil else {
            TopAlert.show("Noch geöffnet", "Bitte zuerst das geöffnete Heft bzw. Textdokument schließen und die Datei danach erneut aus der Dateien-App öffnen.")
            return
        }
        if let imported = await library.importBackup(copy, parent: nil, collision: collision) {
            TopAlert.show("\(kind) übernommen", "„\(imported.title)“ liegt jetzt in der Bibliothek."
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
        present(alert)
    }
    /// `present` fails silently above a controller that is just going away. It
    /// is tried again; if the alert never appears, `unshown` answers for it, so
    /// nothing waits for a reply forever.
    /// A late first attempt may still land: the same controller is never
    /// presented twice (UIKit raises), and a reply arrives only once (`ReplyOnce`).
    private static func shown(_ alert: UIAlertController) -> Bool {
        alert.presentingViewController != nil || alert.isBeingPresented || alert.isViewLoaded
    }
    private static func present(_ alert: UIAlertController, unshown: (() -> Void)? = nil) {
        Task { @MainActor in
            for _ in 0..<8 {
                if shown(alert) { return }
                guard let top else { break }
                top.present(alert, animated: true)
                try? await Task.sleep(for: .milliseconds(300))
                if shown(alert) { return }
            }
            unshown?()
        }
    }
    static func ask(_ title: String, _ message: String, confirm: String) async -> Bool {
        await withCheckedContinuation { continuation in
            guard top != nil else { continuation.resume(returning: false); return }
            let reply = ReplyOnce(continuation)
            let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Abbrechen", style: .cancel) { _ in reply.resume(false) })
            alert.addAction(UIAlertAction(title: confirm, style: .default) { _ in reply.resume(true) })
            present(alert) { reply.resume(false) }
        }
    }
    /// Several answers plus „Abbrechen“; nil when cancelled.
    static func choose<Choice: Sendable>(_ title: String, _ message: String, actions: [(String, UIAlertAction.Style, Choice)]) async -> Choice? {
        await withCheckedContinuation { continuation in
            guard top != nil else { continuation.resume(returning: nil); return }
            let reply = ReplyOnce(continuation)
            let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
            for (label, style, choice) in actions {
                alert.addAction(UIAlertAction(title: label, style: style) { _ in reply.resume(choice) })
            }
            alert.addAction(UIAlertAction(title: "Abbrechen", style: .cancel) { _ in reply.resume(nil) })
            present(alert) { reply.resume(nil) }
        }
    }
    static func progress(_ title: String) -> UIAlertController? {
        guard let top else { return nil }
        let alert = UIAlertController(title: title, message: "Das kann bei großen Dateien etwas dauern.", preferredStyle: .alert)
        top.present(alert, animated: true)
        return alert
    }
    /// A dismissal during the present animation can be dropped without its
    /// completion: first wait for the alert to stand, and never wait for ever.
    static func dismiss(_ alert: UIAlertController?) async {
        guard let alert else { return }
        for _ in 0..<40 where alert.isBeingPresented { try? await Task.sleep(for: .milliseconds(25)) }
        guard alert.presentingViewController != nil else { return }
        let once = DismissOnce()
        await withCheckedContinuation { continuation in
            once.continuation = continuation
            alert.dismiss(animated: true) { once.finish() }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                once.finish()
            }
        }
    }
    /// Resumes its continuation at most once: an alert that appears after
    /// `unshown` answered must not resume it a second time (fatal).
    @MainActor private final class ReplyOnce<Value: Sendable> {
        private var continuation: CheckedContinuation<Value, Never>?
        init(_ continuation: CheckedContinuation<Value, Never>) { self.continuation = continuation }
        func resume(_ value: Value) { continuation?.resume(returning: value); continuation = nil }
    }
    @MainActor private final class DismissOnce {
        var continuation: CheckedContinuation<Void, Never>?
        func finish() { continuation?.resume(); continuation = nil }
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
