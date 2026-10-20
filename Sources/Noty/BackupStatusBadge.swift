import SwiftUI
import NotebookCore

/// Classification of the external backup shared by the library badge and
/// Settings › Backup & Daten. Never claims a completed cloud upload. A merely
/// postponed attempt (editor busy) is not recorded and never shown as failure.
enum BackupHealth: Equatable {
    case notConfigured, folderUnreachable, unreachable(String), failed(String), firstPending
    /// More than three days without a successful backup (or since setup).
    case stale(Date?)
    case ok(Date)

    static let overdueAfter: TimeInterval = 3 * 24 * 3600

    @MainActor init(_ backup: ExternalBackupModel, now: Date = Date()) {
        let policy = backup.policy
        if policy.target == .disabled { self = .notConfigured; return }
        if backup.folderUnreachable { self = .folderUnreachable; return }
        let since = policy.lastSuccess ?? policy.configuredAt
        if let since, now.timeIntervalSince(since) > Self.overdueAfter { self = .stale(policy.lastSuccess); return }
        let failing = policy.lastAttempt.map { attempt in policy.lastSuccess.map { attempt > $0 } ?? true } ?? false
        if failing, !backup.busy, let outcome = policy.lastOutcome {
            let reason = policy.lastFailureReason ?? "unbekannter Fehler"
            switch outcome {
            case .unreachable: self = .unreachable(reason); return
            case .failed: self = .failed(reason); return
            case .succeeded: break
            }
        }
        guard let success = policy.lastSuccess else { self = .firstPending; return }
        self = .ok(success)
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
        case .unreachable: "Nicht erreichbar"
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

    private var last: String {
        externalBackup.policy.lastSuccess.map { " · zuletzt \($0.formatted(.relative(presentation: .named)))" } ?? ""
    }

    private var state: (String, String) {
        switch BackupHealth(externalBackup) {
        case .folderUnreachable: return ("folder.badge.questionmark", "Backup-Ordner neu wählen")
        case .unreachable: return ("wifi.exclamationmark", "Backupziel nicht erreichbar" + last)
        case .failed(let reason): return ("exclamationmark.triangle", "Backup fehlgeschlagen: \(reason)")
        case .firstPending: return ("clock.badge.exclamationmark", "Erstes Backup ausstehend")
        case .stale(let date?):
            let days = max(3, Int(Date().timeIntervalSince(date) / 86_400))
            return ("exclamationmark.triangle", "Seit \(days) Tagen kein Backup")
        case .stale(nil): return ("exclamationmark.triangle", "Noch kein Backup seit der Einrichtung")
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
