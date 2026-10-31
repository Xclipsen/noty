import Foundation

/// Shared German wording (Build 65): real plurals instead of „Heft(e)“ and
/// one date format for lists and one for status lines.
enum NotyText {
    /// „1 Heft“, „3 Hefte“, „0 Hefte“.
    static func count(_ number: Int, _ one: String, _ many: String) -> String {
        number == 1 ? "1 \(one)" : "\(number) \(many)"
    }

    /// Lists and detail values (library, trash, history, backups, restore
    /// questions): absolute date and time, e.g. „22. Okt. 2026, 18:21“.
    static func listDate(_ date: Date, seconds: Bool = false) -> String {
        seconds ? date.formatted(.dateTime.day().month(.abbreviated).year().hour().minute().second())
            : date.formatted(date: .abbreviated, time: .shortened)
    }

    /// Status lines and badges: „heute, 18:21“, „gestern, 18:21“, else the
    /// list format. Stays correct while a status text is shown for a while
    /// (a relative „vor 1 Minute“ would go stale).
    static func statusDate(_ date: Date) -> String {
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(date) { return "heute, \(time)" }
        if calendar.isDateInYesterday(date) { return "gestern, \(time)" }
        if calendar.isDateInTomorrow(date) { return "morgen, \(time)" }
        return listDate(date)
    }

    /// Empty value of a „last …“ date.
    static let never = "Noch nie"

    /// Manually exported library backups: one scheme with the local date,
    /// e.g. „noty-bibliothek-2026-10-22-1821“ (the file dialog adds
    /// `.notylibrary`). Automatic backups keep their own parsed names.
    static func libraryFileName(_ date: Date = Date()) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return String(format: "noty-bibliothek-%04d-%02d-%02d-%02d%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0)
    }

    /// After restoring a library backup as a new area (all three ways).
    static let restoredAreaMessage = "Der neue Bereich ist unter Einstellungen › Backup › Bereiche verfügbar. Die aktuelle Bibliothek bleibt erhalten."
}
