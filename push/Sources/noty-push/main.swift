import Foundation
import NotyPushKit
#if canImport(Glibc)
import Glibc
#endif

// noty-push: Push-Dienst für noty calendar (docs/PUSH.md).
//   noty-push serve  --config /etc/noty-push/config.json
//   noty-push check  --config …        Konfiguration, Schlüssel, Ablage prüfen
//   noty-push status --config …        Geräte ohne Geheimnisse auflisten
//   noty-push test-push --config … ID  Testmitteilung an ein Gerät
//   noty-push genkey                   neuen Datenschlüssel (Base64) ausgeben

setvbuf(stdout, nil, _IOLBF, 0)
var arguments = Array(CommandLine.arguments.dropFirst())
let command = arguments.first ?? "help"
if !arguments.isEmpty { arguments.removeFirst() }
var configPath = "/etc/noty-push/config.json"
if let index = arguments.firstIndex(of: "--config"), index + 1 < arguments.count {
    configPath = arguments[index + 1]
    arguments.removeSubrange(index...(index + 1))
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

struct Runtime {
    let config: PushConfig
    let keyring: DataKeyring
    let store: DeviceStore
    let tokens: APNsTokenProvider
    let transport: CurlTransport
}

func loadRuntime() -> Runtime {
    let config: PushConfig
    do { config = try PushConfig.load(configPath) } catch { fail("Konfiguration nicht lesbar: \(configPath) (\(error))") }
    let problems = config.problems
    if !problems.isEmpty { fail("Konfiguration ungültig:\n- " + problems.joined(separator: "\n- ")) }
    do {
        let keyring = try DataKeyring.load(path: PushConfig.secretPath(config.dataKeyFile, configPath: configPath))
        let store = try DeviceStore(dataDirectory: config.dataDirectory, keyring: keyring)
        let tokens = try APNsTokenProvider.load(keyID: config.apnsKeyID, teamID: config.teamID,
                                                path: PushConfig.secretPath(config.apnsKeyFile, configPath: configPath))
        return Runtime(config: config, keyring: keyring, store: store, tokens: tokens, transport: CurlTransport(curlPath: config.curlPath))
    } catch { fail("\(error)") }
}

func iso(_ date: Date?) -> String {
    guard let date else { return "–" }
    return ISO8601DateFormatter().string(from: date)
}

switch command {
case "genkey":
    print(DataKeyring.generateKeyLine())

case "check":
    let runtime = loadRuntime()
    do { _ = try runtime.tokens.makeToken(at: Date()) } catch { fail("APNs-Token nicht erzeugbar: \(error)") }
    let loaded = runtime.store.loadAll()
    print("Konfiguration ok. Geräte: \(loaded.records.count), unlesbar: \(loaded.problems.count). APNs-JWT erzeugbar.")
    for problem in loaded.problems { print("unlesbar: \(problem)") }

case "status":
    let runtime = loadRuntime()
    let loaded = runtime.store.loadAll()
    for record in loaded.records.sorted(by: { $0.created < $1.created }) {
        let pending = record.history.filter { $0.delivery == .pending }.count
        print("\(record.id)  \(record.state.rawValue)  \(record.environment.rawValue)  \(record.bundleID)  zuletzt ok: \(iso(record.lastSuccess))  nächster Abruf: \(iso(record.nextPoll))  Fehler: \(record.failures)  Verlauf: \(record.history.count) (wartend \(pending))\(record.lastError.map { "  letzter Fehler: " + $0 } ?? "")")
    }
    for problem in loaded.problems { print("unlesbar: \(problem)") }
    if loaded.records.isEmpty && loaded.problems.isEmpty { print("keine Geräte") }

case "test-push":
    guard let id = arguments.first else { fail("Geräte-ID fehlt (siehe status)") }
    let runtime = loadRuntime()
    let record: DeviceRecord
    do { record = try runtime.store.load(id) } catch { fail("Gerät nicht lesbar: \(error)") }
    let client = APNsClient(transport: runtime.transport, tokens: runtime.tokens)
    let message = PushMessage(title: "noty calendar", body: "Testmitteilung des Mitteilungsdienstes.",
                              threadID: "noty.calendar.test", expiration: Date().addingTimeInterval(3600),
                              data: ["kind": .string("test")])
    let target = PushTarget(deviceToken: record.deviceToken, environment: record.environment, topic: record.bundleID)
    let semaphore = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var result = PushResult.rejected("nicht gesendet")
    Task { result = await client.send(message, to: target); semaphore.signal() }
    semaphore.wait()
    print("Ergebnis: \(result)")
    if result != .delivered { exit(1) }

case "demo-push":
    // Every kind of notification once, with sample texts in the real formats
    // (docs/PUSH.md). Kind „test“: tapping opens nothing, nothing is stored.
    guard let id = arguments.first else { fail("Geräte-ID fehlt (siehe status)") }
    let runtime = loadRuntime()
    let record: DeviceRecord
    do { record = try runtime.store.load(id) } catch { fail("Gerät nicht lesbar: \(error)") }
    let client = APNsClient(transport: runtime.transport, tokens: runtime.tokens)
    let target = PushTarget(deviceToken: record.deviceToken, environment: record.environment, topic: record.bundleID)
    let changes = "noty.calendar.demo.changes"
    let samples: [(String, String, String)] = [
        ("Stundenplanänderung", "Mo 9.11., 08:00 Deutsch fällt aus", changes),
        ("Stundenplanänderung", "Mo 9.11., 09:45 Mathematik jetzt in R 112 (statt R 101)", changes),
        ("Stundenplanänderung", "Di 10.11., 11:30 Englisch: Vertretung", changes),
        ("Stundenplanänderung", "Biologie verlegt auf Do 12.11., 13:15 (statt Mi 11.11., 08:00) in R 204", changes),
        ("Stundenplanänderung", "Fr 13.11., 08:00 Sport findet wieder statt in Halle 2", changes),
        ("4 Stundenplanänderungen", "Mo 9.11., 08:00 Deutsch fällt aus\nMo 9.11., 09:45 Mathematik jetzt in R 112 (statt R 101)\nDi 10.11., 11:30 Englisch: Vertretung\n…", changes),
        ("Dein Tag · Mo 9.11.", "Beginn 08:00: Rechnungswesen, R 204\nÄnderungen: 09:45 Mathematik in R 112; 11:30 Deutsch fällt aus\n2 Hausaufgaben fällig: Mathematik, Englisch\nTermin: 15:00 Zahnarzt", "noty.calendar.demo.overview"),
        ("Zahnarzt", "09.11.2026 · 15:00–15:45 · Praxis am Markt", "noty.calendar.demo.reminder"),
        ("Untis-Zugang prüfen", "Der Stundenplan kann nicht mehr abgerufen werden. Bitte in noty calendar die WebUntis-Freigabe neu verbinden.", "noty.calendar.demo.auth"),
    ]
    for (index, sample) in samples.enumerated() {
        let message = PushMessage(title: sample.0, body: sample.1, threadID: sample.2, collapseID: "demo.\(index)",
                                  expiration: Date().addingTimeInterval(3600), data: ["kind": .string("test")])
        let semaphore = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result = PushResult.rejected("nicht gesendet")
        Task { result = await client.send(message, to: target); semaphore.signal() }
        semaphore.wait()
        print("\(sample.0): \(result)")
        Thread.sleep(forTimeInterval: 1.5)
    }

case "serve":
    // SIGTERM/SIGINT end the process at once. Safe: every device file is
    // replaced by rename (old or new, never half), leftovers of an
    // interrupted write are removed at the next start, and nothing is
    // buffered in memory that is not on disk. Only async-signal-safe calls.
    // (A DispatchSource did not fire on Linux with the NIO threads.)
    let onSignal: @convention(c) (Int32) -> Void = { _ in
        let text: StaticString = "[info] beendet\n"
        _ = write(2, text.utf8Start, text.utf8CodeUnitCount)
        _exit(0)
    }
    signal(SIGTERM, onSignal)
    signal(SIGINT, onSignal)
    let runtime = loadRuntime()
    let source = WebUntisCurlSource(transport: runtime.transport)
    let sender = APNsClient(transport: runtime.transport, tokens: runtime.tokens)
    let service = PushService(config: runtime.config, store: runtime.store, source: source, sender: sender)
    let router = APIRouter(service: service, config: runtime.config)
    let server = HTTPServer(router: router, host: runtime.config.listenHost, port: runtime.config.port)
    do { try server.start() } catch { fail("Server startet nicht: \(error)") }
    _ = server
    Task {
        while true {
            await service.tick()
            try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
        }
    }
    dispatchMain()

default:
    print("""
    noty-push serve|check|status|test-push ID|demo-push ID [--config PFAD]   (Standard: /etc/noty-push/config.json)
    noty-push genkey
    """)
}
