import SwiftUI
import UIKit
import VisionKit
import NotebookCore

/// „WebUntis verbinden“ (Stufe B1). Inoffizieller Zugang über die
/// Untis-Mobile-Freigabe (WebUntis → Profil → Freigaben): QR code or
/// server, school, user and key by hand. „Verbindung testen“ only reads;
/// „Verbinden“ stores user and key in this iPad's keychain (never in files,
/// logs or backups) and loads the timetable. „Trennen“ removes access data
/// and offline timetable; own events and notes stay.
struct CalendarConnectionSheet: View {
    @ObservedObject var model: CalendarModel
    @Environment(\.dismiss) private var dismiss
    @State private var server = ""
    @State private var school = ""
    @State private var user = ""
    @State private var key = ""
    @State private var scanning = false
    @State private var working = false
    /// What runs while `working` (said beside the wait indicator).
    @State private var workingText = "Bitte warten …"
    @State private var result: String?
    @State private var failure: String?
    @State private var confirmingDisconnect = false
    @State private var replacing = false
    /// Push service (docs/PUSH.md): consent offered after connecting.
    @State private var offeringPush = false

    @FocusState private var focused: WebUntisEntryField?
    private var scannerAvailable: Bool { DataScannerViewController.isSupported }

    var body: some View {
        NavigationStack {
            Form {
                if let connection = model.connection, !replacing {
                    connectedSection(connection)
                } else {
                    entrySections
                }
                CalendarSystemSection(model: model)
            }
            .disabled(working)
            .navigationTitle("Kalender verbinden")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Fertig") { dismiss() } }
                if working { ToolbarItem(placement: .confirmationAction) { CalendarDelayedProgress(text: workingText) } }
            }
            .sheet(isPresented: $scanning) {
                CalendarQRScanner { text in
                    scanning = false
                    apply(scanned: text)
                } cancel: { scanning = false }
                .ignoresSafeArea()
            }
            .confirmationDialog("WebUntis trennen?", isPresented: $confirmingDisconnect, titleVisibility: .visible) {
                Button("Trennen", role: .destructive) { disconnect() }
            } message: {
                Text("Benutzer, Schlüssel und der offline gespeicherte Stundenplan werden von diesem iPad entfernt. Eigene Termine und Notizen bleiben erhalten.")
            }
        }
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled(working)
        .calendarPushConsent(isPresented: $offeringPush, model: model)
    }

    private var notice: some View {
        Text("Inoffizieller Zugang über die Untis-Mobile-Freigabe (WebUntis → Profil → Freigaben). noty liest damit nur Stundenplan und Ferien; Benutzer und Schlüssel bleiben ausschließlich im Schlüsselbund dieses iPads und gelangen in keine Datei und kein Backup.")
    }

    @ViewBuilder private func connectedSection(_ connection: CalendarConnectionRecord) -> some View {
        Section {
            LabeledContent("Schule", value: connection.label)
            LabeledContent("Verbunden seit", value: CalendarText.numericDate(connection.connectedAt, calendar: model.calendar))
            if model.syncing {
                Label("Stundenplan wird aktualisiert …", systemImage: "arrow.triangle.2.circlepath")
            } else if let success = model.lastSuccess {
                Label("Zuletzt aktualisiert: " + model.standText(success).replacingOccurrences(of: "Stand: ", with: ""), systemImage: "checkmark.circle")
            }
            if let error = model.syncError { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            if model.credentialsMissing {
                Label("Zugang auf diesem Gerät neu verbinden: Die Zugangsdaten fehlen auf diesem iPad (zum Beispiel nach einer Wiederherstellung aus einem Bibliotheksbackup – Zugangsdaten sind nie darin enthalten). Der gesicherte Stundenplan bleibt bis dahin mit altem Stand sichtbar.", systemImage: "key")
                    .foregroundStyle(.orange)
            }
        } footer: { notice }
        Section {
            Button { model.refreshNow() } label: { Label("Aktualisieren", systemImage: "arrow.clockwise") }
                .disabled(model.syncing || model.credentialsMissing)
            Button { replacing = true } label: {
                Label(model.credentialsMissing ? "Auf diesem Gerät neu verbinden …" : "Mit anderer Freigabe verbinden …", systemImage: "qrcode")
            }
            Button(role: .destructive) { confirmingDisconnect = true } label: { Label("Trennen", systemImage: "link.badge.minus") }
        } footer: {
            Text("Automatisch aktualisiert beim Öffnen des Kalenders und beim Zurückkehren in die App, während der Kalender sichtbar ist höchstens alle 15 Minuten.")
        }
        if let failure { Section { Label(failure, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) } }
    }

    @ViewBuilder private var entrySections: some View {
        let check = self.check
        Section {
            Button { scanning = true } label: {
                Label("QR-Code der Freigabe scannen", systemImage: "qrcode.viewfinder").font(.headline)
            }
            .disabled(!scannerAvailable)
            if !scannerAvailable {
                Text("Auf diesem Gerät ist kein Scannen möglich. Bitte die Freigabe einfügen oder die Angaben unten eingeben.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Button { pasteFromClipboard() } label: {
                Label("Freigabe aus Zwischenablage einfügen", systemImage: "doc.on.clipboard")
            }
        } footer: { notice }
        Section {
            entryField(.server, text: $server, prompt: "schulname.webuntis.com",
                       help: "Adresse, z. B. schulname.webuntis.com – steht in der Adresszeile, wenn WebUntis im Browser offen ist. Die ganze Adresse einzufügen geht auch.")
            entryField(.school, text: $school, prompt: "schulname",
                       help: "Schul-Anmeldename ohne Punkt, z. B. schulname – in der WebUntis-Adresse hinter „school=“.")
            entryField(.user, text: $user, prompt: "Benutzername",
                       help: "Der WebUntis-Benutzername aus der Freigabe.")
            entryField(.key, text: $key, prompt: "ABCD EFGH IJKL MNOP", secure: true,
                       help: "Lange Buchstaben-Zahlen-Folge unter WebUntis → Profil → Freigaben (neben dem QR-Code). Leerzeichen und Kleinschreibung sind egal.")
            if check.swapSuggested {
                Button { apply(check.entry.swapped, normalize: false) } label: {
                    Label("Vertauscht? Server und Schule tauschen", systemImage: "arrow.up.arrow.down")
                }
            }
        } header: { Text("Oder von Hand") } footer: {
            Text("Ein kompletter Freigabe-Link (untis://…) darf in jedes Feld eingefügt werden; dann werden alle Felder ausgefüllt.")
        }
        Section {
            Button("Verbindung testen") { test() }.disabled(check.setup == nil)
            Button("Verbinden") { connect() }.disabled(check.setup == nil || !model.canWrite)
            if replacing { Button("Abbrechen", role: .cancel) { replacing = false; failure = nil; result = nil } }
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(check.lines, id: \.self) { line in
                    Label(line, systemImage: "info.circle").foregroundStyle(.orange)
                }
                if !model.canWrite, let error = model.storageError { Text(error) }
            }
        }
        if let result { Section { Label(result, systemImage: "checkmark.circle").foregroundStyle(.green) } }
        if let failure { Section { Label(failure, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) } }
    }

    /// Field with a fixed visible label and help line (the placeholder alone
    /// disappeared while typing and fields were filled the wrong way round).
    /// VoiceOver reads label and help once, via the field itself.
    @ViewBuilder private func entryField(_ field: WebUntisEntryField, text: Binding<String>, prompt: String,
                                         secure: Bool = false, help: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(field.rawValue).font(.subheadline.weight(.semibold)).accessibilityHidden(true)
            Group {
                if secure {
                    SecureField(field.rawValue, text: text, prompt: Text(prompt))
                } else {
                    TextField(field.rawValue, text: text, prompt: Text(prompt))
                        .keyboardType(field == .server ? .URL : .default)
                        .textContentType(field == .user ? .username : nil)
                }
            }
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            .focused($focused, equals: field)
            .submitLabel(field == WebUntisEntryField.allCases.last ? .done : .next)
            // Return goes on to the next field (the last one closes the keyboard).
            .onSubmit {
                normalizeFields()
                let fields = WebUntisEntryField.allCases
                if let index = fields.firstIndex(of: field) { focused = fields.index(after: index) < fields.endIndex ? fields[fields.index(after: index)] : nil }
            }
            .onChange(of: text.wrappedValue) { old, new in
                // A pasted link or URL (a jump of several characters) is
                // resolved at once; normal typing only on leaving the field.
                if new.count - old.count > 8, new.contains("://") { normalizeFields() }
            }
            .accessibilityLabel(field.rawValue)
            .accessibilityHint(help)
            Text(help).font(.caption).foregroundStyle(.secondary).accessibilityHidden(true)
        }
        .padding(.vertical, 2)
    }

    private var entry: WebUntisEntry { WebUntisEntry(server: server, school: school, user: user, key: key) }
    private var check: WebUntisEntryCheck { WebUntis.check(entry) }

    private func apply(_ entry: WebUntisEntry, normalize: Bool = true) {
        let entry = normalize ? WebUntis.normalizedEntry(entry) : entry
        server = entry.server; school = entry.school; user = entry.user; key = entry.key
    }

    private func normalizeFields() {
        let normalized = WebUntis.normalizedEntry(entry)
        if normalized != entry { apply(normalized, normalize: false) }
    }

    /// Reads the pasteboard only on this tap (iPadOS may ask for permission).
    private func pasteFromClipboard() {
        result = nil; failure = nil
        guard let text = UIPasteboard.general.string, let pasted = WebUntis.parseEntry(text) else {
            failure = "In der Zwischenablage ist keine Freigabe (untis://setschool?…) und keine WebUntis-Adresse. In WebUntis unter Profil → Freigaben den Link kopieren oder den QR-Code scannen."
            return
        }
        var merged = entry
        var filled: [WebUntisEntryField] = []
        if !pasted.server.isEmpty { merged.server = pasted.server; filled.append(.server) }
        if !pasted.school.isEmpty { merged.school = pasted.school; filled.append(.school) }
        if !pasted.user.isEmpty { merged.user = pasted.user; filled.append(.user) }
        if !pasted.key.isEmpty { merged.key = pasted.key; filled.append(.key) }
        apply(merged)
        result = "Aus der Zwischenablage übernommen: " + filled.map(\.rawValue).joined(separator: ", ") + "."
    }

    private func apply(scanned text: String) {
        do {
            let parsed = try WebUntis.parseSetup(text)
            server = parsed.server; school = parsed.school; user = parsed.user; key = parsed.key
            failure = nil
            result = "QR-Code gelesen. Jetzt „Verbindung testen“ oder „Verbinden“."
        } catch {
            result = nil
            failure = error.localizedDescription
        }
    }

    /// Uses the normalized values and writes them back into the fields.
    private func preparedSetup() -> WebUntisSetup? {
        let setup = check.setup
        normalizeFields()
        return setup
    }

    private func test() {
        guard let setup = preparedSetup() else { return }
        workingText = "Wird getestet …"
        working = true; failure = nil; result = nil
        Task {
            let client = WebUntisClient(setup: setup)
            defer { client.finish() }
            do {
                let user = try await client.user()
                result = "Verbindung funktioniert: \(user.subjects.count) Fächer, \(user.holidays.count) Ferienzeiträume, \(user.teachers.isEmpty ? "keine Lehrkräfte freigegeben" : "\(user.teachers.count) Lehrkräfte")."
            } catch { failure = WebUntisClient.testMessage(error) }
            working = false
        }
    }

    private func connect() {
        guard let setup = preparedSetup() else { return }
        workingText = "Wird verbunden …"
        working = true; failure = nil; result = nil
        Task {
            let client = WebUntisClient(setup: setup)
            defer { client.finish() }
            do {
                // Only a working access is stored.
                _ = try await client.user()
                try await model.connect(setup, label: setup.school)
                replacing = false
                key = ""; user = ""
                result = nil
                // Only after a working local connection; nothing is uploaded without „Zustimmen“.
                if CalendarPushClient.shared.shouldOffer(for: model) { offeringPush = true }
            } catch { failure = (error as? CalendarStoreError)?.localizedDescription ?? WebUntisClient.testMessage(error) }
            working = false
        }
    }

    private func disconnect() {
        workingText = "Wird getrennt …"
        working = true
        Task {
            failure = await model.disconnect()
            working = false
            if failure == nil { dismiss() }
        }
    }
}

/// QR scanner (VisionKit DataScanner, iPadOS 16+). Hands over the first code
/// that looks like a Untis Mobile „Freigabe“; anything else is ignored.
struct CalendarQRScanner: View {
    let found: (String) -> Void
    let cancel: () -> Void
    @State private var message = "QR-Code der Freigabe in den Rahmen halten."

    var body: some View {
        NavigationStack {
            Group {
                if DataScannerViewController.isAvailable {
                    CalendarQRScannerView(found: found, failed: { message = $0 })
                        .overlay(alignment: .bottom) {
                            Text(message).font(.callout).padding(.horizontal, 16).padding(.vertical, 10)
                                .notyGlass().padding(.bottom, 24)
                        }
                } else {
                    ContentUnavailableView("Kamera nicht verfügbar", systemImage: "camera",
                                           description: Text("Bitte den Kamerazugriff für noty in den Einstellungen erlauben oder die Angaben von Hand eingeben."))
                }
            }
            .navigationTitle("Freigabe scannen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { cancel() } } }
        }
        .preferredColorScheme(.dark)
    }
}

private struct CalendarQRScannerView: UIViewControllerRepresentable {
    let found: (String) -> Void
    let failed: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(found: found, failed: failed) }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], qualityLevel: .balanced,
                                                recognizesMultipleItems: false, isHighFrameRateTrackingEnabled: false,
                                                isPinchToZoomEnabled: true, isGuidanceEnabled: true, isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        do { try scanner.startScanning() } catch { failed("Scannen nicht möglich. Bitte die Angaben von Hand eingeben.") }
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {}

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        scanner.stopScanning()
    }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let found: (String) -> Void
        let failed: (String) -> Void
        private var done = false
        init(found: @escaping (String) -> Void, failed: @escaping (String) -> Void) { self.found = found; self.failed = failed }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !done else { return }
            for item in addedItems {
                guard case .barcode(let code) = item, let text = code.payloadStringValue else { continue }
                if text.lowercased().hasPrefix("untis://") {
                    done = true
                    dataScanner.stopScanning()
                    found(text)
                    return
                }
                failed("Das ist kein Untis-Mobile-QR-Code.")
            }
        }

        func dataScanner(_ dataScanner: DataScannerViewController, becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable) {
            failed("Kamera nicht verfügbar. Bitte die Angaben von Hand eingeben.")
        }
    }
}
