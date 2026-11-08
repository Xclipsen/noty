import SwiftUI
import NotebookCore

// MARK: Appearance

/// App-wide accent (Settings › Darstellung). Applied once as `.tint` at the
/// window; views use the `.tint` shape style instead of `Color.accentColor`,
/// so a change shows at once everywhere. The editor's own tool highlight
/// (`Color.notyAccent`) stays as it is.
enum AccentChoice: String, CaseIterable, Identifiable {
    case blue, sky, mint, green, amber, coral, rose, iris, graphite
    var id: String { rawValue }
    /// For places without the environment (Canvas, attributed strings).
    static var current: AccentChoice {
        UserDefaults.standard.string(forKey: AppSettingsKey.accent).flatMap(AccentChoice.init(rawValue:)) ?? .blue
    }
    var title: String {
        switch self {
        case .blue: "Blau"
        case .sky: "Himmel"
        case .mint: "Minze"
        case .green: "Grün"
        case .amber: "Bernstein"
        case .coral: "Koralle"
        case .rose: "Rosa"
        case .iris: "Iris"
        case .graphite: "Graphit"
        }
    }
    var color: Color {
        switch self {
        // Dark enough for white text on a filled accent (selected rows, labels).
        case .blue: Color(red: 0.04, green: 0.52, blue: 1.0)
        case .sky: Color(red: 0.16, green: 0.58, blue: 0.88)
        case .mint: Color(red: 0.08, green: 0.60, blue: 0.56)
        case .green: Color(red: 0.16, green: 0.60, blue: 0.29)
        case .amber: Color(red: 0.84, green: 0.48, blue: 0.02)
        case .coral: Color(red: 0.90, green: 0.34, blue: 0.28)
        case .rose: Color(red: 0.88, green: 0.28, blue: 0.50)
        case .iris: Color(red: 0.48, green: 0.40, blue: 0.94)
        case .graphite: Color(white: 0.42)
        }
    }
}

// MARK: Developer tools

/// Developer and test tools (diagnostics, Bereiche, app sync, internals) are
/// shown in noty dev, noty AI and noty calendar, and in the normal noty only
/// after unlocking them (seven taps on the build in „Über noty“).
enum DeveloperAccess {
    @MainActor static var isTestApp: Bool { AppSyncModel.shared.channel.map { $0 != .stable } ?? true }
    @MainActor static var visible: Bool { isTestApp || UserDefaults.standard.bool(forKey: AppSettingsKey.developerMode) }
    /// Bereiche stay reachable whenever one exists or is open, also in the
    /// normal noty (a restored library opens as a Bereich).
    @MainActor static func showsAreas(_ workspaces: WorkspaceAppModel) -> Bool {
        visible || !workspaces.areas.isEmpty || workspaces.areaID != nil
    }
}

// MARK: Building blocks

/// The coloured icon tile of a settings page (sidebar, search results).
struct SettingsTile: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 28
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.52, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.27, style: .continuous).fill(color.gradient))
            .accessibilityHidden(true)
    }
}

/// Title with a short visible explanation below (instead of a hint only
/// VoiceOver reads), the T3-style row.
struct SettingLabel: View {
    let title: String
    var detail: String?
    var badge: String?
    init(_ title: String, detail: String? = nil, badge: String? = nil) {
        self.title = title; self.detail = detail; self.badge = badge
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(title)
                if let badge { SettingsBadge(badge) }
            }
            if let detail {
                Text(detail).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, detail == nil ? 0 : 2)
    }
}

/// A switch with a visible explanation that takes part in the keys of its page.
@MainActor func settingToggle(_ title: String, detail: String? = nil, badge: String? = nil, isOn: Binding<Bool>) -> some View {
    Toggle(isOn: isOn) { SettingLabel(title, detail: detail, badge: badge) }
        .keyOption(.toggle(isOn))
}

struct SettingsBadge: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(.secondary.opacity(0.15)))
    }
}

/// Footer of a section stored with the open Bereich. In „Meine Bibliothek“
/// (the normal case) it says nothing; Bereiche are a test tool.
struct AreaScopeFooter: View {
    @ObservedObject var workspaces: WorkspaceAppModel
    var text: String?
    var body: some View {
        let area = workspaces.areaID == nil ? nil : "Gilt nur für Bereich \(NotyText.quoted(workspaces.title))."
        let parts = [text, area].compactMap { $0 }
        if !parts.isEmpty { Text(parts.joined(separator: " ")) }
    }
}

/// First row of a page whose values all belong to the open Bereich; shown
/// only outside „Meine Bibliothek“.
struct AreaNotice: View {
    @ObservedObject var workspaces: WorkspaceAppModel
    var body: some View {
        if workspaces.areaID != nil {
            Section {
                Label("Gilt nur für Bereich \(NotyText.quoted(workspaces.title))", systemImage: workspaces.kind.symbol)
                    .foregroundStyle(.orange)
            }
        }
    }
}

// MARK: Search

/// One searchable setting: what it is called, where it lives, extra words.
struct SettingsSearchItem: Identifiable, Hashable {
    var id: String { page.rawValue + "·" + title }
    let title: String
    let page: SettingsPage
    var section: String?
    var keywords: [String] = []

    func matches(_ query: String) -> Bool {
        let words = query.lowercased().split(separator: " ").map(String.init)
        let haystack = ([title, page.title, section ?? ""] + keywords).joined(separator: " ").lowercased()
        return words.allSatisfy { haystack.contains($0) }
    }

    static func index(developer: Bool, vault: Bool) -> [SettingsSearchItem] {
        var items: [SettingsSearchItem] = [
            .init(title: "Anordnung der Bibliothek", page: .general, section: "Bibliothek", keywords: ["raster", "liste", "ansicht", "darstellung"]),
            .init(title: "Sortierung", page: .general, section: "Bibliothek", keywords: ["name", "zuletzt", "reihenfolge"]),
            .init(title: "Zuletzt geöffnetes Heft wieder öffnen", page: .general, section: "Beim Start", keywords: ["start", "öffnen"]),
            .init(title: "Einstellungen zurücksetzen", page: .general, keywords: ["standard", "reset"]),
            .init(title: "Akzentfarbe", page: .appearance, keywords: ["farbe", "design", "theme", "tint", "dunkel", "hell"]),
            .init(title: "Blättern statt Scrollen", page: .view, section: "Seiten", keywords: ["paging", "seitenweise"]),
            .init(title: "PDFs einheitlich anzeigen", page: .view, section: "Seiten", keywords: ["breite", "arbeitsblatt"]),
            .init(title: "Schreibscrollen bis zur Bildschirmmitte", page: .view, section: "Schreiben", keywords: ["scrollen", "mitte"]),
            .init(title: "Seitenleiste im Heft", page: .view, section: "Schreiben", keywords: ["seiten", "vorschau", "sidebar"]),
            .init(title: "Einrasten", page: .view, section: "Bearbeiten", keywords: ["magnet", "ausrichten", "snap"]),
            .init(title: "Neue Textfelder in automatischer Farbe", page: .text, section: "Neue Textfelder", keywords: ["schwarz", "weiß"]),
            .init(title: "Neue Textfelder an Linien ausrichten", page: .text, section: "Neue Textfelder", keywords: ["liniert", "kariert"]),
            .init(title: "Rechnen mit „=“", page: .text, section: "Beim Tippen", keywords: ["rechner", "calculator", "gleich"]),
            .init(title: "Pfeile ersetzen", page: .text, section: "Beim Tippen", keywords: ["->", "pfeil"]),
            .init(title: "Schreibmaschinen-Modus", page: .text, section: "Beim Tippen", keywords: ["typewriter", "zeile"]),
            .init(title: "Helix-Tastatur", page: .text, section: "Hardware-Tastatur", keywords: ["vim", "tasten", "experimentell"]),
            .init(title: "Klammern automatisch schließen", page: .text, section: "Hardware-Tastatur", keywords: ["klammer", "anführungszeichen"]),
            .init(title: "Autostift", page: .tools, section: "Stift und Bleistift", keywords: ["farbe", "automatisch", "schwarz"]),
            .init(title: "Formen nach Halten erkennen", page: .tools, section: "Stift und Bleistift", keywords: ["kreis", "linie", "form"]),
            .init(title: "Durchkritzeln löscht", page: .tools, section: "Stift und Bleistift", keywords: ["scribble", "löschen", "radieren"]),
            .init(title: "Textmarkerspitze", page: .tools, section: "Textmarker", keywords: ["keil", "rund", "marker"]),
            .init(title: "Textmarker immer gerade", page: .tools, section: "Textmarker", keywords: ["winkel", "gerade", "marker"]),
            .init(title: "Linie nach Halten begradigen", page: .tools, section: "Textmarker", keywords: ["gerade", "linie"]),
            .init(title: "Radierer-Standard", page: .tools, section: "Radierer", keywords: ["präzise", "ganzer strich"]),
            .init(title: "Auch mit dem Finger zeichnen", page: .tools, section: "Eingabe", keywords: ["finger", "touch"]),
            .init(title: "Apple Pencil: Doppeltippen und Drücken", page: .tools, section: "Apple Pencil", keywords: ["squeeze", "hover", "pencil"]),
            .init(title: "Werkzeugleiste anpassen", page: .tools, section: "Werkzeugleiste", keywords: ["leiste", "position", "lieblingsstifte", "dock"]),
            .init(title: "Papier für neue Hefte", page: .paper, keywords: ["umschlag", "liniert", "kariert", "vorlage"]),
            .init(title: "Gesetzessammlung", page: .laws, keywords: ["gesetze", "paragraphen", "markierungen", "lesezeichen"]),
            .init(title: "noty-Konto", page: .account, keywords: ["anmelden", "abmelden", "passwort", "apple", "registrieren", "login"]),
            .init(title: "Automatisches Backup", page: .backup, section: "Automatisches Backup", keywords: ["webdav", "icloud drive", "ordner", "sichern"]),
            .init(title: "Ältere Backups wiederherstellen", page: .backup, section: "Wiederherstellen", keywords: ["zurückholen", "restore"]),
            .init(title: "Bibliotheksbackup exportieren", page: .backup, section: "Bibliotheksbackup als Datei", keywords: ["export", "datei", ".notylibrary"]),
            .init(title: "Bibliotheksbackup-Datei öffnen", page: .backup, section: "Wiederherstellen", keywords: ["importieren", ".notylibrary", "bereich"]),
            .init(title: "WebDAV", page: .backup, section: "Ziel und Aufbewahrung", keywords: ["server", "nextcloud", "zugangsdaten"]),
            .init(title: "Anzahl automatischer Backups", page: .backup, section: "Ziel und Aufbewahrung", keywords: ["aufbewahrung", "stände", "behalten"]),
            .init(title: "Automatisches Backup ausschalten", page: .backup, section: "Ziel und Aufbewahrung", keywords: ["aus", "deaktivieren"]),
            .init(title: "Gesetzessammlung aktivieren", page: .laws, keywords: ["gesetze", "einschalten"]),
            .init(title: "Lesezeichen und Markierungen abgleichen", page: .laws, keywords: ["sync", "abgleich"]),
            .init(title: "Neue Gesetzesfassungen automatisch laden", page: .laws, keywords: ["update", "fassung"]),
            .init(title: "Markierungen sichern", page: .laws, section: "Persönliche Daten", keywords: ["export", "sicherung", "lesezeichen"]),
            .init(title: "Papierkorb", page: .trash, keywords: ["gelöscht", "wiederherstellen", "leeren"]),
            .init(title: "Version und Build", page: .about, keywords: ["version", "build", "über"]),
            .init(title: "Signierung erneuern", page: .about, section: "Signierung erneuern", keywords: ["profil", "ablauf", "erinnerung"]),
            .init(title: "Datenschutz", page: .privacy, keywords: ["daten", "privatsphäre", "server"]),
        ]
        if vault {
            items.append(.init(title: "Hefte einzeln in iCloud sichern", page: .backup, section: "iCloud-Ablage", keywords: ["icloud", "sync", "stände"]))
        }
        if developer {
            items += [
                .init(title: "Diagnose", page: .developer, keywords: ["hänger", "eingabe", "tipp"]),
                .init(title: "Bereiche", page: .developer, keywords: ["testbereich", "spiegel"]),
                .init(title: "Zwischen noty-Apps", page: .developer, keywords: ["app-abgleich", "spiegel", "abzug"]),
                .init(title: "Neuer Texteditor (Test)", page: .developer, keywords: ["experimentell", "editor"]),
            ]
        }
        return items
    }
}

/// The chosen accent for the whole window (Settings › Darstellung).
struct AccentTint: ViewModifier {
    @AppStorage(AppSettingsKey.accent) private var accent = AccentChoice.blue
    func body(content: Content) -> some View { content.tint(accent.color) }
}
