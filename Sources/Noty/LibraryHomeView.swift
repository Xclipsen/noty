import SwiftUI
import NotebookCore

/// Classification of the external backup shared by the library badge and
/// Settings › Backup & Daten. Never claims a completed cloud upload.
enum BackupHealth: Equatable {
    case notConfigured, folderUnreachable, failed, firstPending, stale(Date), ok(Date)

    @MainActor init(_ backup: ExternalBackupModel) {
        let policy = backup.policy
        if policy.target == .disabled { self = .notConfigured; return }
        if backup.folderUnreachable { self = .folderUnreachable; return }
        if let attempt = policy.lastAttempt, policy.lastSuccess.map({ attempt > $0 }) ?? true, !backup.busy {
            self = .failed; return
        }
        guard let success = policy.lastSuccess else { self = .firstPending; return }
        self = Date().timeIntervalSince(success) > 2 * 24 * 3600 ? .stale(success) : .ok(success)
    }

    /// Configured and working (or waiting for its first run).
    var isSetUp: Bool {
        switch self { case .ok, .firstPending: true; default: false }
    }

    /// Short status for the top right of Settings › Backup & Daten.
    var shortTitle: String {
        switch self {
        case .notConfigured: "Nicht eingerichtet"
        case .folderUnreachable: "Ordner neu wählen"
        case .failed: "Fehlgeschlagen"
        case .stale: "Überfällig"
        case .ok, .firstPending: "Eingerichtet"
        }
    }
}

/// Compact backup hint in the library toolbar. Shown only when something needs
/// attention; tapping opens Settings › Backup & Daten.
struct BackupStatusBadge: View {
    @ObservedObject var externalBackup: ExternalBackupModel
    @ObservedObject var library: LibraryModel
    let action: () -> Void

    /// Background runs never toggle the badge, so the toolbar stays calm.
    @MainActor static func needsAttention(_ backup: ExternalBackupModel) -> Bool {
        if case .ok = BackupHealth(backup) { return false }
        return true
    }

    private var state: (String, String) {
        switch BackupHealth(externalBackup) {
        case .folderUnreachable: return ("folder.badge.questionmark", "Backup-Ordner neu wählen")
        case .failed: return ("exclamationmark.triangle", "Backup prüfen")
        case .firstPending: return ("clock.badge.exclamationmark", "Erstes Backup ausstehend")
        case .stale(let date): return ("exclamationmark.triangle", "Backup \(date.formatted(.relative(presentation: .named)))")
        case .ok(let date): return ("checkmark.circle", "Backup \(date.formatted(.relative(presentation: .named)))")
        case .notConfigured:
            if let export = library.lastLibraryExport {
                return ("archivebox", "Nur Dateiexport \(export.formatted(.relative(presentation: .named)))")
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
