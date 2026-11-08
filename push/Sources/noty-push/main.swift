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
    noty-push serve|check|status|test-push ID [--config PFAD]   (Standard: /etc/noty-push/config.json)
    noty-push genkey
    """)
}
