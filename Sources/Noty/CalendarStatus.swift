import SwiftUI
import NotebookCore

// Kalender, UI-Überarbeitung 06.11.2026: the former status line under the
// title is gone. WebUntis state („Stand“, refresh, errors, reconnect) lives
// behind one sync symbol in the toolbar; only problems that need the user
// appear as slim banners (`CalendarProblemBanner`).

/// Sync symbol of the toolbar: turns while the timetable refreshes (with
/// „Bewegung reduzieren“ a still symbol with a ring instead), carries an
/// orange dot when something needs attention (never colour alone: the
/// VoiceOver value and the popover say what).
struct CalendarSyncSymbol: View {
    @ObservedObject var model: CalendarModel
    let problem: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var webUntis: Bool { model.connection != nil && !model.showsSamples }
    private var system: Bool { model.systemEnabled && !model.showsSamples }
    private var symbol: String {
        if webUntis || system { return "arrow.triangle.2.circlepath" }
        return model.storageError != nil ? "exclamationmark.triangle" : "info.circle"
    }

    var body: some View {
        let working = (webUntis && model.syncing) || (system && model.systemReading)
        let turning = working && !reduceMotion
        ZStack(alignment: .topTrailing) {
            if working && reduceMotion {
                // Static substitute of the turning: the same arrows inside a ring.
                Image(systemName: "arrow.triangle.2.circlepath.circle")
            } else if #available(iOS 18.0, *) {
                // The system symbol effect finishes its turn when reading ends.
                Image(systemName: symbol)
                    .symbolEffect(.rotate, options: .repeat(.continuous), isActive: turning)
            } else {
                TimelineView(.animation(minimumInterval: nil, paused: !turning)) { context in
                    Image(systemName: symbol)
                        .rotationEffect(.degrees(turning ? context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.2) / 1.2 * 360 : 0))
                }
            }
            if problem {
                Circle().fill(Color.orange).frame(width: 9, height: 9)
                    .overlay { Circle().strokeBorder(Color(uiColor: .systemBackground), lineWidth: 1.5) }
                    .offset(x: 4, y: -3)
                    // A data change, not a user action: only a short fade.
                    .transition(.opacity)
            }
        }
        .animation(NotyMotion.fade, value: problem)
        .accessibilityElement()
        .accessibilityLabel(webUntis ? "Stundenplan-Status" : system ? "Kalender-Status" : "Kalenderstatus")
        .accessibilityValue(value)
        .accessibilityHint("Zeigt Stand und Aktualisieren")
        .help(webUntis || system ? "Stand und Aktualisieren" : "Kalenderstatus")
    }

    private var value: String {
        if model.storageError != nil { return "Speichern gesperrt" }
        if system, model.systemAccess.problem != nil || model.systemError != nil { return "Systemkalender: Problem" }
        if system && model.systemReading { return "Systemkalender werden eingelesen" }
        guard webUntis else { return model.truncatedSeries.isEmpty ? "" : "Nicht alle Wiederholungen angezeigt" }
        if model.syncing { return "Wird aktualisiert" }
        if model.credentialsMissing { return "Zugang neu verbinden" }
        if model.syncError != nil { return "Aktualisierung fehlgeschlagen" }
        return model.lastSuccess.map { model.standText($0) } ?? "Noch nicht geladen"
    }
}

/// Popover of the sync symbol: what is shown, from when, what failed, and
/// the actions („Jetzt aktualisieren“, „Verbinden …“).
struct CalendarStatusPopover: View {
    @ObservedObject var model: CalendarModel
    let connect: () -> Void
    let close: () -> Void
    @Environment(\.openURL) private var openURL

    private var range: (start: Date, end: Date) {
        CalendarDates.range(model.mode, anchor: model.anchor, weekDays: model.weekDays == 7 ? 7 : 5, calendar: model.calendar)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CalendarSpace.l) {
                if let error = model.storageError {
                    row(symbol: "lock.trianglebadge.exclamationmark", tint: .orange, title: "Speichern gesperrt", text: error)
                }
                if model.connection != nil && !model.showsSamples { webUntis }
                if model.systemEnabled && !model.showsSamples { systemCalendars }
                if !model.showsSamples {
                    row(symbol: "sun.max", tint: .secondary, title: "Ferien und Feiertage", text: model.holidaySourceText)
                }
                if !model.truncatedSeries.isEmpty {
                    row(symbol: "repeat", tint: .secondary, title: "Nicht alle Wiederholungen angezeigt",
                        text: "Höchstens \(CalendarSeries.maximumPerSeries) je Serie im angezeigten Jahr: "
                            + model.truncatedSeries.prefix(3).map { "„\($0)“" }.joined(separator: ", "))
                }
            }
            .padding(CalendarSpace.l)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(idealWidth: 360, maxWidth: 380)
        .frame(minHeight: 120, idealHeight: 280)
        .presentationCompactAdaptation(.popover)
        .preferredColorScheme(.dark)
    }

    @ViewBuilder private var webUntis: some View {
        let coverage = model.coverage(range.start, range.end)
        VStack(alignment: .leading, spacing: CalendarSpace.m) {
            HStack(alignment: .top, spacing: CalendarSpace.m) {
                Image(systemName: "graduationcap").font(.title3).foregroundStyle(.secondary).frame(width: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Stundenplan aus WebUntis").font(.headline)
                    Text(standLine(coverage)).font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
            if model.credentialsMissing {
                Label("Die Zugangsdaten fehlen auf diesem iPad (zum Beispiel nach einer Wiederherstellung). Der Stundenplan ist veraltet, bis du neu verbindest.",
                      systemImage: "key")
                    .font(.footnote).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            } else if let error = model.syncError {
                Label("Aktualisierung fehlgeschlagen: \(error)", systemImage: "exclamationmark.icloud")
                    .font(.footnote).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: CalendarSpace.s) {
                if model.credentialsMissing {
                    Button { connect() } label: { Label("Neu verbinden …", systemImage: "key") }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button { model.refreshNow() } label: {
                        Label(model.syncing ? "Wird aktualisiert …" : "Jetzt aktualisieren", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.syncing)
                    Button("Verbindung …") { connect() }.buttonStyle(.bordered)
                }
            }
            .font(.subheadline.weight(.semibold))
            Text("Über die Untis-Mobile-Freigabe. Aktualisiert sich beim Öffnen und höchstens alle 15 Minuten, solange der Kalender sichtbar ist.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Apple Kalender/Outlook: last read, access problems, read anew.
    @ViewBuilder private var systemCalendars: some View {
        VStack(alignment: .leading, spacing: CalendarSpace.m) {
            HStack(alignment: .top, spacing: CalendarSpace.m) {
                Image(systemName: "calendar").font(.title3).foregroundStyle(.secondary).frame(width: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Apple Kalender und Outlook").font(.headline)
                    if model.systemAccess.problem == nil, model.systemError == nil, let status = model.systemStatusText {
                        Text(status).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .accessibilityElement(children: .combine)
            if let problem = model.systemAccess.problem {
                Label(problem, systemImage: "lock").font(.footnote).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            } else if let error = model.systemError {
                Label(error, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: CalendarSpace.s) {
                if model.systemAccess.problem != nil {
                    Button { if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) } } label: {
                        Label("iPad-Einstellungen", systemImage: "gear")
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button { model.reloadSystemCalendars() } label: {
                        Label(model.systemReading ? "Wird eingelesen …" : "Neu einlesen", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.systemReading)
                }
                Button("Verwalten …") { connect() }.buttonStyle(.bordered)
            }
            .font(.subheadline.weight(.semibold))
            Text("noty liest die Kalender dieses iPads. Den Abgleich mit iCloud oder Microsoft 365 übernimmt iPadOS; „eingelesen“ heißt nicht „mit dem Konto abgeglichen“.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// „Stand: heute 07:12“ of the shown range, „teilweise“, or not loaded.
    private func standLine(_ coverage: CalendarCoverage?) -> String {
        if model.syncing { return "Wird aktualisiert …" }
        switch coverage {
        case .loaded(let oldest)?: return model.standText(oldest) + (model.credentialsMissing ? " (veraltet)" : "")
        case .partial(let oldest)?: return model.standText(oldest) + " · angezeigter Zeitraum nur teilweise geladen"
        case .notLoaded?: return "Angezeigter Zeitraum noch nicht geladen"
        case nil: return model.hiddenSources.contains(.timetable) ? "Stundenplan ausgeblendet" : "Noch nicht geladen"
        }
    }

    private func row(symbol: String, tint: Color, title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: CalendarSpace.m) {
            Image(systemName: symbol).font(.title3).foregroundStyle(tint).frame(width: 28).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A slim problem line: symbol, at most two lines of text (tap shows all),
/// one action or „schließen“. Used only for what needs the user.
struct CalendarProblemBanner: View {
    let symbol: String
    let text: String
    /// With an action there is no close button: the problem stays until solved.
    var actionTitle: String?
    var closeLabel = "Hinweis schließen"
    let perform: () -> Void
    @State private var expanded = false

    var body: some View {
        HStack(alignment: .center, spacing: CalendarSpace.m) {
            Image(systemName: symbol).font(.subheadline.weight(.semibold)).foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(text).font(.footnote).lineLimit(expanded ? nil : 2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { expanded.toggle() }
                .accessibilityAddTraits(.isStaticText)
            if let actionTitle {
                Button(actionTitle, action: perform)
                    .font(.footnote.weight(.semibold))
                    .buttonStyle(.bordered).tint(.orange)
            } else {
                // Same size as before; it takes touches 44 × 44 pt.
                Button(action: perform) {
                    Image(systemName: "xmark").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .frame(width: 40, height: 40).contentShape(NotyHitShape())
                }
                .buttonStyle(NotyPressStyle())
                .accessibilityLabel(closeLabel)
            }
        }
        .padding(.leading, CalendarSpace.m).padding(.trailing, actionTitle == nil ? 2 : CalendarSpace.s).padding(.vertical, 4)
        .frame(minHeight: 44)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.orange.opacity(0.12)))
        .overlay { RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.orange.opacity(0.35), lineWidth: 0.5) }
        .accessibilityElement(children: .contain)
    }
}
