import SwiftUI
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
    @State private var result: String?
    @State private var failure: String?
    @State private var confirmingDisconnect = false
    @State private var replacing = false

    private var setup: WebUntisSetup? { try? WebUntisSetup(server: server, school: school, user: user, key: key) }
    private var scannerAvailable: Bool { DataScannerViewController.isSupported }

    var body: some View {
        NavigationStack {
            Form {
                if let connection = model.connection, !replacing {
                    connectedSection(connection)
                } else {
                    entrySections
                }
            }
            .disabled(working)
            .navigationTitle("WebUntis")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Fertig") { dismiss() } }
                if working { ToolbarItem(placement: .confirmationAction) { ProgressView() } }
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
        Section {
            Button { scanning = true } label: { Label("QR-Code der Freigabe scannen", systemImage: "qrcode.viewfinder") }
                .disabled(!scannerAvailable)
            if !scannerAvailable {
                Text("Auf diesem Gerät ist kein Scannen möglich. Bitte die Angaben unten eingeben.").font(.footnote).foregroundStyle(.secondary)
            }
        } footer: { notice }
        Section {
            TextField("Server (z. B. schule.webuntis.com)", text: $server)
                .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
            TextField("Schule (Anmeldename)", text: $school).textInputAutocapitalization(.never).autocorrectionDisabled()
            TextField("Benutzer", text: $user).textInputAutocapitalization(.never).autocorrectionDisabled()
                .textContentType(.username)
            SecureField("Schlüssel", text: $key).textInputAutocapitalization(.never).autocorrectionDisabled()
        } header: { Text("Oder von Hand") } footer: {
            Text("Die Angaben stehen unter WebUntis → Profil → Freigaben → Untis Mobile (Benutzer und Schlüssel neben dem QR-Code).")
        }
        Section {
            Button("Verbindung testen") { test() }.disabled(setup == nil)
            Button("Verbinden") { connect() }.disabled(setup == nil || !model.canWrite)
            if replacing { Button("Abbrechen", role: .cancel) { replacing = false; failure = nil; result = nil } }
        } footer: {
            if !model.canWrite, let error = model.storageError { Text(error) }
        }
        if let result { Section { Label(result, systemImage: "checkmark.circle").foregroundStyle(.green) } }
        if let failure { Section { Label(failure, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) } }
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

    private func test() {
        guard let setup else { return }
        working = true; failure = nil; result = nil
        Task {
            let client = WebUntisClient(setup: setup)
            defer { client.finish() }
            do {
                let user = try await client.user()
                result = "Verbindung funktioniert: \(user.subjects.count) Fächer, \(user.holidays.count) Ferienzeiträume, \(user.teachers.isEmpty ? "keine Lehrkräfte freigegeben" : "\(user.teachers.count) Lehrkräfte")."
            } catch { failure = WebUntisClient.message(error) }
            working = false
        }
    }

    private func connect() {
        guard let setup else { return }
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
            } catch { failure = (error as? CalendarStoreError)?.localizedDescription ?? WebUntisClient.message(error) }
            working = false
        }
    }

    private func disconnect() {
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
