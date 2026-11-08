import SwiftUI
import NotebookCore

// Settings › Schreiben: Ansicht & Seiten, Text & Tastatur, Stift & Werkzeuge,
// Papier für neue Hefte. Per-area values come from the area's toolbar.json
// (`ToolbarSettingsModel`), app-wide ones from UserDefaults.

struct ViewSettingsPage: View {
    @ObservedObject var toolbox: ToolbarSettingsModel
    @ObservedObject var workspaces: WorkspaceAppModel
    @AppStorage(AppSettingsKey.writingScroll) private var writingScroll = false
    @AppStorage(AppSettingsKey.sidebarVisible) private var sidebarVisible = true
    @AppStorage(AppSettingsKey.snapping) private var snapping = true
    var body: some View {
        Form {
            Section {
                settingToggle("Blättern statt Scrollen",
                              detail: "Seite für Seite wie in einem Buch statt fortlaufend untereinander.",
                              isOn: Binding(get: { toolbox.preferences.paging ?? false }, set: { toolbox.preferences.paging = $0 }))
                settingToggle("PDFs einheitlich anzeigen",
                              detail: "Arbeitsblätter erscheinen gleich breit, mit Schreibraum daneben. Ändert nur die Anzeige; PDF-Original und Export bleiben unverändert.",
                              isOn: Binding(get: { toolbox.preferences.normalizePageWidths ?? false }, set: { toolbox.preferences.normalizePageWidths = $0 }))
            } header: { Text("Seiten") } footer: { AreaScopeFooter(workspaces: workspaces) }
            .disabled(!toolbox.writable)
            Section("Schreiben") {
                settingToggle("Schreibscrollen bis zur Bildschirmmitte",
                              detail: "Der Blattrand lässt sich bis zur Bildschirmmitte ziehen, damit du bequem am Rand schreibst. Auch über den Knopf in der Heftleiste.",
                              isOn: $writingScroll)
                settingToggle("Seitenleiste im Heft anzeigen",
                              detail: "Seitenübersicht beim Öffnen eines Hefts. Merkt sich auch, wenn du sie im Heft ein- oder ausblendest.",
                              isOn: $sidebarVisible)
            }
            Section("Bearbeiten") {
                settingToggle("Einrasten",
                              detail: "Textfelder, Bilder, Formen und Auswahlen rasten beim langsamen Verschieben an Kanten, Mitten, Linien und Seitenrändern ein. Ein zweiter Finger auf dem Bildschirm unterdrückt es.",
                              isOn: $snapping)
            }
            if !toolbox.status.isEmpty { Section { Text(toolbox.status).font(.caption) } }
        }
        .navigationTitle(SettingsPage.view.title)
        .keyboardSheet()
    }
}

struct TextSettingsPage: View {
    @AppStorage(AppSettingsKey.typewriter) private var typewriter = false
    @AppStorage(AppSettingsKey.calculator) private var calculator = true
    @AppStorage(AppSettingsKey.arrows) private var arrows = true
    @AppStorage(AppSettingsKey.automaticTextColor) private var automaticTextColor = true
    @AppStorage(AppSettingsKey.alignTextToLines) private var alignTextToLines = true
    @AppStorage(AppSettingsKey.helixTextDocuments) private var helix = false
    @AppStorage(AppSettingsKey.autoPairs) private var autoPairs = false
    var body: some View {
        Form {
            Section("Neue Textfelder") {
                settingToggle("Automatische Farbe",
                              detail: "Schwarz oder Weiß passend zum Papier. Aus: Neue Felder übernehmen die zuletzt benutzte Farbe.",
                              isOn: $automaticTextColor)
                settingToggle("An Linien ausrichten",
                              detail: "Auf liniertem oder kariertem Papier stehen die Zeilen auf den Linien. Bestehende Felder bleiben unverändert; jedes Feld lässt sich in der Formatleiste umschalten.",
                              isOn: $alignTextToLines)
            }
            Section("Beim Tippen") {
                settingToggle("Rechnen mit „=“",
                              detail: "2+3= wird zu 2+3=5. Untereinander geschriebene Zahlen mit = allein in einer neuen Zeile werden von oben nach unten zusammengerechnet.",
                              isOn: $calculator)
                settingToggle("Pfeile ersetzen",
                              detail: "Mit dem folgenden Leerzeichen wird -> zu →, => zu ⇒, <- zu ←, <-> zu ↔. ⌫ direkt danach stellt das Getippte wieder her.",
                              isOn: $arrows)
                settingToggle("Schreibmaschinen-Modus",
                              detail: "Hält die Schreibzeile beim Tippen im oberen Drittel, auch mit schwebender oder externer Tastatur.",
                              isOn: $typewriter)
            }
            Section {
                settingToggle("Helix-Tastatur in Textdokumenten", badge: "Experimentell", isOn: $helix)
                settingToggle("Klammern automatisch schließen",
                              detail: "Nur mit der Helix-Tastatur: Runde, eckige und geschweifte Klammern und Anführungszeichen schließen sich selbst, außer direkt neben einem Wort.",
                              isOn: $autoPairs)
                    .disabled(!helix)
            } header: { Text("Hardware-Tastatur") } footer: {
                Text("Die Helix-Tastatur steuert Textdokumente mit einer Hardware-Tastatur: erst auswählen, dann handeln. i schreibt, Esc geht eine Ebene zurück, die Leertaste öffnet das Menü, Leertaste und h zeigen alle Tasten. Hefte und Bibliothek bleiben unverändert.")
            }
        }
        .navigationTitle(SettingsPage.text.title)
        .keyboardSheet()
    }
}

struct ToolSettingsPage: View {
    @ObservedObject var toolbox: ToolbarSettingsModel
    @ObservedObject var workspaces: WorkspaceAppModel
    /// A link has no action a key could run.
    @State private var customizing = false
    private var hoverPreview: String {
        if #available(iOS 17.5, *) { return UIPencilInteraction.prefersHoverToolPreview ? "Ein" : "Aus" }
        return "Systemeinstellung"
    }
    private var doubleTap: String {
        switch UIPencilInteraction.preferredTapAction {
        case .ignore: "Aus"
        case .switchEraser: "Radierer"
        case .switchPrevious: "Vorheriges Werkzeug"
        case .showColorPalette: "Farbpalette"
        case .showInkAttributes: "Werkzeugoptionen"
        default: "Systemeinstellung"
        }
    }
    private var squeeze: String {
        guard #available(iOS 17.5, *) else { return "–" }
        switch UIPencilInteraction.preferredSqueezeAction {
        case .ignore: return "Aus"
        case .switchEraser: return "Radierer"
        case .switchPrevious: return "Vorheriges Werkzeug"
        case .showColorPalette: return "Farbpalette"
        case .showInkAttributes: return "Werkzeugoptionen"
        case .showContextualPalette: return "Werkzeugpalette"
        case .runSystemShortcut: return "Kurzbefehl"
        default: return "Systemeinstellung"
        }
    }
    private var dockTitle: String {
        switch toolbox.preferences.effectiveDock {
        case .top: "Oben"
        case .bottom: "Unten"
        case .left: "Links"
        case .right: "Rechts"
        case .floating: "Schwebend"
        }
    }
    var body: some View {
        Form {
            AreaNotice(workspaces: workspaces)
            Section("Stift und Bleistift") {
                settingToggle("Autostift",
                              detail: "Neue Striche bekommen eine zur Seitenhelligkeit passende Farbe. Gilt für Stift, Formen und Bleistift und schaltet einen getrennt eingestellten Bleistift wieder mit.",
                              isOn: Binding(get: { toolbox.preferences.autoPen ?? false }, set: { toolbox.preferences.setAutomaticInk($0, for: .pen) }))
                settingToggle("Formen nach Halten erkennen",
                              detail: "Stift kurz am Ende eines Strichs halten: Linien, Kreise und Vielecke werden sauber nachgezogen.",
                              isOn: Binding(get: { toolbox.preferences.recognizeShapes ?? true }, set: { toolbox.preferences.recognizeShapes = $0 }))
                settingToggle("Durchkritzeln löscht",
                              detail: "Mit dem Stift dicht über Striche oder Formen kritzeln entfernt sie samt Gekritzel.",
                              isOn: Binding(get: { toolbox.preferences.scribbleErase ?? true }, set: { toolbox.preferences.scribbleErase = $0 }))
            }
            Section("Textmarker") {
                let tip = Binding(get: { toolbox.preferences.effectiveMarkerTip }, set: { toolbox.preferences.markerTip = $0 })
                Picker(selection: tip) {
                    Text("Rund").tag(MarkerTip.round); Text("Keil").tag(MarkerTip.chisel)
                } label: {
                    SettingLabel("Spitze", detail: "Rund: gleichmäßig breit und durchscheinend. Keil: klassischer Marker.")
                }
                .keyOption(.choice(tip, [.round, .chisel]))
                settingToggle("Linie nach Halten begradigen",
                              detail: "Am Strichende kurz halten: Der Strich wird gerade.",
                              isOn: Binding(get: { toolbox.preferences.markerHoldStraighten ?? true }, set: { toolbox.preferences.markerHoldStraighten = $0 }))
                settingToggle("Immer gerade",
                              detail: "Jeder Strich wird gerade; nahe 0°, 90°, 45° und 30° rastet er ein.",
                              isOn: Binding(get: { toolbox.preferences.markerStraight ?? false }, set: { toolbox.preferences.markerStraight = $0 }))
            }
            Section("Radierer") {
                let precise = Binding(get: { toolbox.preferences.eraserPrecision ?? false }, set: { toolbox.preferences.eraserPrecision = $0 })
                Picker(selection: precise) {
                    Text("Ganzer Strich").tag(false); Text("Präzise").tag(true)
                } label: { SettingLabel("Standard beim Wechsel zum Radierer") }
                .keyOption(.toggle(precise))
            }
            Section("Eingabe") {
                settingToggle("Auch mit dem Finger zeichnen",
                              detail: "Dann navigierst du mit zwei Fingern. Aus: Der Finger blättert und scrollt, nur der Apple Pencil schreibt.",
                              isOn: $toolbox.preferences.fingerDrawing)
            }
            Section {
                NavigationLink {
                    ToolbarCustomizationList(settings: toolbox).keyboardSheet()
                } label: {
                    LabeledContent {
                        Text(dockTitle)
                    } label: {
                        SettingLabel("Werkzeugleiste anpassen", detail: "Position, Reihenfolge, zweite Ebene und Lieblingsstifte.")
                    }
                }
                .keyOption(.action { customizing = true })
            } header: { Text("Werkzeugleiste") } footer: { AreaScopeFooter(workspaces: workspaces, text: "Bereits gezeichnete Striche ändern sich nicht.") }
            Section {
                LabeledContent("Doppeltippen", value: doubleTap)
                if #available(iOS 17.5, *) { LabeledContent("Drücken", value: squeeze) }
                LabeledContent("Werkzeugvorschau beim Schweben", value: hoverPreview)
            } header: { Text("Apple Pencil") } footer: {
                Text("noty folgt diesen Systemeinstellungen. Ändern unter iPad-Einstellungen › Apple Pencil.")
            }
            if !toolbox.status.isEmpty { Section { Text(toolbox.status).font(.caption) } }
        }
        .disabled(!toolbox.writable)
        .navigationTitle(SettingsPage.tools.title)
        .navigationDestination(isPresented: $customizing) { ToolbarCustomizationList(settings: toolbox).keyboardSheet() }
        .keyboardSheet()
    }
}

struct PaperSettingsPage: View {
    @ObservedObject var toolbox: ToolbarSettingsModel
    @ObservedObject var workspaces: WorkspaceAppModel
    private var appearance: Binding<NotebookAppearance> {
        Binding(get: { toolbox.preferences.defaultAppearance ?? NotebookAppearance() },
                set: { toolbox.preferences.defaultAppearance = $0 })
    }
    var body: some View {
        Form {
            Section {
                HStack(alignment: .top, spacing: 20) {
                    NotebookCoverPreview(appearance: appearance.wrappedValue).aspectRatio(0.71, contentMode: .fit).frame(maxWidth: 110)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 10) {
                        keyToggle("Umschlag", isOn: appearance.coverEnabled)
                        Text("Startwerte für neue Hefte und Textdokumente. Beim Anlegen weiterhin änderbar; bestehende bleiben unverändert.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                NotebookAppearanceEditor(appearance: appearance, paperHeading: "Papier").padding(.vertical, 6)
            } footer: { AreaScopeFooter(workspaces: workspaces) }
            Section {
                Button("Auf noty-Standard zurücksetzen") { toolbox.preferences.defaultAppearance = nil }
                    .disabled(toolbox.preferences.defaultAppearance == nil)
                    .keyOption(.action { toolbox.preferences.defaultAppearance = nil })
            }
        }
        .disabled(!toolbox.writable)
        .navigationTitle(SettingsPage.paper.title)
        .keyboardSheet()
    }
}
