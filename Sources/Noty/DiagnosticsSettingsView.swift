import SwiftUI
import UniformTypeIdentifiers
import NotebookCore

/// Einstellungen › Diagnose, oberer Teil (docs/DIAGNOSE.md): automatic
/// sending, the recent reports in plain text, sharing, and in the test apps a
/// hidden test menu (tap the build line five times).
struct DiagnosticReportsSection: View {
    @AppStorage(Diagnostics.autoSendKey) private var autoSend = Diagnostics.defaultAutoSend
    @State private var entries: [DiagnosticOutbox.Entry] = []
    @State private var status: String?
    @State private var testTaps = 0
    @State private var showsTests = false

    var body: some View {
        Section {
            Toggle("Fehlerberichte automatisch senden", isOn: $autoSend)
                .disabled(!Diagnostics.canSend)
                .onChange(of: autoSend) { _, on in if on { Uploader.shared.schedule(after: 0) } }
            NavigationLink {
                DiagnosticReportList(entries: entries)
            } label: {
                LabeledContent("Letzte Berichte", value: entries.isEmpty ? "keine" : "\(entries.count)")
            }
            ShareLink(item: DiagnosticExport(), preview: SharePreview("noty-Diagnose")) {
                Label("Diagnose teilen …", systemImage: "square.and.arrow.up")
            }
            if Diagnostics.canSend, !entries.filter({ !$0.sent }).isEmpty {
                Button("Wartende Berichte jetzt senden") {
                    Task { await Uploader.shared.flush(force: true); reload() }
                }
            }
            Text("\(Diagnostics.channel) · Build \(Diagnostics.build)\(Diagnostics.commit.isEmpty ? "" : " · \(Diagnostics.commit)")")
                .font(.caption).foregroundStyle(.secondary)
                .contentShape(Rectangle())
                .onTapGesture {
                    guard Diagnostics.isTestChannel else { return }
                    testTaps += 1
                    if testTaps >= 5 { showsTests = true }
                }
        } header: {
            Text("Fehlerberichte")
        } footer: {
            Text(footer)
        }
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: Diagnostics.reportsChanged)) { _ in reload() }
        if showsTests { DiagnosticTestSection() }
    }

    private var footer: String {
        var text = "Abstürze, Hänger, langsame Vorgänge und Speicherfehler werden als Bericht festgehalten: Build, iPadOS, Codeadressen und die letzten Schritte als feste Namen und Zahlen (z. B. „Heft geöffnet, 34 Seiten“). Titel, Texte, Pfade und Heftinhalte sind nie enthalten."
        if !Diagnostics.canSend {
            text += " Dieser Build kennt keinen Server und sendet nichts; „Diagnose teilen“ geht immer."
        } else {
            text += " Gesendet wird nur an den eigenen Server von noty."
        }
        if let result = Uploader.shared.status { text += " Zuletzt: \(result)." }
        return text
    }

    private func reload() {
        let outbox = Diagnostics.outbox
        Task.detached(priority: .utility) {
            let recent = outbox.recent(limit: 30)
            await MainActor.run { entries = recent }
        }
    }
}

private struct DiagnosticReportList: View {
    let entries: [DiagnosticOutbox.Entry]
    var body: some View {
        List {
            if entries.isEmpty { Text("Noch keine Berichte.").foregroundStyle(.secondary) }
            ForEach(entries, id: \.report.id) { entry in
                NavigationLink {
                    DiagnosticReportDetail(report: entry.report, sent: entry.sent)
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.report.summary).lineLimit(3)
                        Text(subtitle(entry)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Letzte Berichte")
    }

    private func subtitle(_ entry: DiagnosticOutbox.Entry) -> String {
        let date = Date(timeIntervalSince1970: Double(entry.report.occurredAt ?? entry.report.createdAt) / 1000)
        return "\(date.formatted(date: .abbreviated, time: .shortened)) · Build \(entry.report.details["build"] ?? entry.report.app.build) · \(entry.sent ? "gesendet" : "wartet")"
    }
}

private struct DiagnosticReportDetail: View {
    let report: DiagnosticReport
    let sent: Bool
    var body: some View {
        List {
            Section {
                Text(report.summary)
                LabeledContent("Art", value: report.kind.label)
                LabeledContent("Phase", value: report.launchPhase ?? "–")
                LabeledContent("Status", value: sent ? "gesendet" : "wartet")
            }
            if !report.details.isEmpty {
                Section("Angaben") {
                    ForEach(report.details.sorted { $0.key < $1.key }, id: \.key) { item in
                        LabeledContent(item.key, value: item.value)
                    }
                }
            }
            if !report.breadcrumbs.isEmpty {
                Section("Letzte Schritte") {
                    ForEach(Array(report.breadcrumbs.suffix(40).reversed().enumerated()), id: \.offset) { _, crumb in
                        Text("\(Date(timeIntervalSince1970: Double(crumb.t) / 1000).formatted(date: .omitted, time: .standard))  \(crumb.text)")
                            .font(.caption.monospaced())
                    }
                }
            }
            if !report.callStack.isEmpty {
                Section("Aufrufkette (innen zuerst)") {
                    ForEach(Array(report.callStack.prefix(30).enumerated()), id: \.offset) { index, frame in
                        Text("\(index) \(frame.label)").font(.caption.monospaced())
                    }
                }
            }
        }
        .navigationTitle(report.kind.label)
    }
}

/// Only in the test apps, after five taps on the build line.
private struct DiagnosticTestSection: View {
    @State private var confirmCrash = false
    var body: some View {
        Section {
            Button("Testbericht senden") { Diagnostics.sendTestReport() }
            Button("Testhänger (3 s)") { HangProbe.testHang(seconds: 3) }
            Button("Testabsturz", role: .destructive) { confirmCrash = true }
                .confirmationDialog("noty jetzt absichtlich abstürzen lassen?", isPresented: $confirmCrash, titleVisibility: .visible) {
                    Button("Abstürzen", role: .destructive) { DiagnosticTestCrash.trigger() }
                }
        } header: {
            Text("Test")
        } footer: {
            Text("Nur in den Test-Apps. Der Absturz ist ein absichtlicher Abbruch; der Bericht erscheint nach dem nächsten Start (eigener Bericht sofort, Apples Bericht meist ebenfalls beim nächsten Start).")
        }
    }
}

enum DiagnosticTestCrash {
    /// A Swift trap like a real one; the breadcrumb says it was the test.
    @MainActor static func trigger() {
        Diagnostics.note("test.crash")
        let numbers: [Int] = []
        // Not optimised away: the index comes from the run.
        let index = Int(Diagnostics.launchID.utf8.count) - 36
        _ = numbers[index]
    }
}

/// „Diagnose teilen …“: the JSON file is made when it is shared.
struct DiagnosticExport: Transferable {
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .json) { _ in
            SentTransferredFile(try Diagnostics.exportFile())
        }
    }
}
