import SwiftUI
import NotebookCore

/// Classification of the external backup shared by the library badge and
/// Settings › Backup (logic and tests in Core). Never claims a
/// completed cloud upload; a postponed attempt is never shown as failure.
typealias BackupHealth = ExternalBackupHealth

extension ExternalBackupHealth {
    @MainActor init(_ backup: ExternalBackupModel, now: Date = Date()) {
        self.init(backup.policy, folderUnreachable: backup.folderUnreachable, running: backup.busy, now: now)
    }

    /// Short status for the top right of Settings › Backup.
    var shortTitle: String {
        switch self {
        case .notConfigured: "Nicht eingerichtet"
        case .folderUnreachable: "Backup-Ordner neu wählen"
        case .unreachable: "Nicht erreichbar"
        case .failed: "Fehlgeschlagen"
        case .stale: "Überfällig"
        case .warning: "Backup mit Hinweis"
        case .ok, .firstPending: "Eingerichtet"
        }
    }
}

/// Compact backup hint in the library toolbar. Shown only when something needs
/// attention; tapping opens Settings › Backup.
struct BackupStatusBadge: View {
    @ObservedObject var externalBackup: ExternalBackupModel
    @ObservedObject var library: LibraryModel
    let action: () -> Void

    /// Background runs never toggle the badge, so the toolbar stays calm.
    @MainActor static func needsAttention(_ backup: ExternalBackupModel) -> Bool {
        if case .ok = BackupHealth(backup) { return false }
        return true
    }

    private var last: String {
        externalBackup.policy.lastSuccess.map { " · zuletzt \(NotyText.statusDate($0))" } ?? ""
    }

    private var state: (String, String) {
        switch BackupHealth(externalBackup) {
        case .folderUnreachable: return ("folder.badge.questionmark", "Backup-Ordner neu wählen")
        case .unreachable: return ("wifi.exclamationmark", "Backup-Ziel nicht erreichbar" + last)
        case .failed(let reason): return ("exclamationmark.triangle", "Backup fehlgeschlagen: \(reason)")
        case .firstPending: return ("clock.badge.exclamationmark", "Erstes Backup ausstehend")
        case .stale(let date?):
            let days = max(3, Int(Date().timeIntervalSince(date) / 86_400))
            return ("exclamationmark.triangle", "Seit \(days) Tagen kein Backup")
        case .stale(nil): return ("exclamationmark.triangle", "Noch kein Backup seit der Einrichtung")
        case .ok(let date): return ("checkmark.circle", "Backup \(NotyText.statusDate(date))")
        case .warning(_, let warning): return ("exclamationmark.circle", "Backup mit Hinweis: \(warning)")
        case .notConfigured:
            if let export = library.lastLibraryExport {
                return ("archivebox", "Nur Bibliotheksbackup · \(NotyText.statusDate(export))")
            }
            return ("exclamationmark.triangle", "Kein Backup eingerichtet")
        }
    }

    var body: some View {
        let (symbol, text) = state
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                Text(text).lineLimit(1)
            }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .foregroundStyle(Color.orange)
            .background(Capsule().fill(Color.orange.opacity(0.14)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Backup-Status: \(text)")
        .accessibilityHint("Öffnet die Backup-Einstellungen")
    }
}
