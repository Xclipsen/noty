import SwiftUI
import NotebookCore
import CryptoKit
import Security
import PDFKit

struct NotyAccountUser: Codable, Sendable {
    var id: String
    var name: String
    var email: String?
    var emailVerified: Bool?
    var token: String?
}
@MainActor
private enum NotyAccountKeychain {
    private static let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "noty.account", kSecAttrAccount as String: "session"]
    static func read() -> NotyAccountUser? {
        var result: CFTypeRef?
        let q = query.merging([kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]) { _, n in n }
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(NotyAccountUser.self, from: data)
    }
    static func save(_ user: NotyAccountUser?) throws {
        guard let user else {
            let result = SecItemDelete(query as CFDictionary)
            guard result == errSecSuccess || result == errSecItemNotFound else { throw LawError.invalid("Anmeldeschlüssel konnte nicht entfernt werden.") }
            return
        }
        let attrs: [String: Any] = [kSecValueData as String: try JSONEncoder().encode(user),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let result = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if result == errSecItemNotFound {
            guard SecItemAdd(query.merging(attrs) { _, n in n } as CFDictionary, nil) == errSecSuccess else { throw LawError.invalid("Anmeldeschlüssel konnte nicht gesichert werden.") }
        } else if result != errSecSuccess { throw LawError.invalid("Anmeldeschlüssel konnte nicht gesichert werden.") }
    }
}
private final class LawSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}
private struct LawAPIError: LocalizedError {
    let status: Int
    let message: String
    var errorDescription: String? { message }
}

/// App-wide services, intentionally outside the per-notebook/area writers.
@MainActor
final class LawLibraryModel: ObservableObject {
    static let enabledKey = "noty.laws.enabled"
    static let syncKey = "noty.laws.personalSync"
    static let updatesKey = "noty.laws.automaticUpdates"
    static let root = URL.documentsDirectory.appendingPathComponent("NotyLaws", isDirectory: true)
    private let offline = LawOfflineStore(root: root)
    private let personal = LawPersonalStore(root: root)
    private let session: URLSession
    private let base = URL(string: "https://law.xclipsen.de")!
    @Published private(set) var user: NotyAccountUser?
    @Published private(set) var catalog: LawCatalog?
    @Published private(set) var items: [LawPersonalItem] = []
    @Published private(set) var downloading = false
    @Published private(set) var syncing = false
    @Published private(set) var accountBusy = false
    @Published private(set) var sessionExpired = false
    @Published private(set) var progress = ""
    @Published private(set) var syncStatus = "Lokal gespeichert"
    @Published private(set) var byteCount: Int64 = 0
    @Published var error: String?
    @Published var panelOpen = false { didSet { if !panelOpen { stashed = false } } }
    /// Pushed past the screen edge like iPad Slide Over: hidden behind an edge
    /// tab, reader state kept. Closing the window clears it.
    @Published var stashed = false
    @Published var docked = false
    @Published var panelOnLeft = false
    var sceneActive = true
    private var started = false
    private var epoch = 0
    private var lastCheck = Date.distantPast
    private var lastAttempt = Date.distantPast
    private var lastSync = Date.distantPast
    private var lastOwner: String?
    var enabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }
    var syncEnabled: Bool { UserDefaults.standard.object(forKey: Self.syncKey) as? Bool ?? true }
    var automaticUpdates: Bool { UserDefaults.standard.object(forKey: Self.updatesKey) as? Bool ?? true }
    var entries: [LawEntry] { catalog?.entries ?? [] }
    var pendingCount: Int { items.filter { $0.dirty && $0.owner == user?.id }.count }
    init() {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 25; config.timeoutIntervalForResource = 300
        session = URLSession(configuration: config, delegate: LawSessionDelegate(), delegateQueue: nil)
        user = NotyAccountKeychain.read()
    }
    func start() async {
        guard !started else { return }
        started = true
        do {
            catalog = try await offline.catalog()
            items = try await personal.items(); lastOwner = try await personal.lastOwner()
            byteCount = await offline.byteCount()
            if let user { try await personal.adoptGuests(owner: user.id); await refreshItems() }
        } catch { self.error = "Lokaler Gesetzesbestand: \(error.localizedDescription)" }
        await tick()
    }
    func tick() async {
        guard enabled else { return }
        let needsUpdate = catalog == nil || (automaticUpdates && Date().timeIntervalSince(lastCheck) > 6 * 3600)
        if needsUpdate && Date().timeIntervalSince(lastAttempt) > (catalog == nil ? 60 : 900) { await updateLaws(manual: false) }
        if Date().timeIntervalSince(lastSync) > 30 { await synchronize() }
    }
    func settingsChanged() async {
        epoch += 1
        if !enabled { panelOpen = false; return }
        await tick()
    }
    private nonisolated func fetch(_ path: String, method: String = "GET", body: [String: LawJSON]? = nil, token: String? = nil, limit: Int = 64_000_000) async throws -> Data {
        guard let url = URL(string: path, relativeTo: base)?.absoluteURL, url.scheme == "https", url.host == base.host, url.port == nil else { throw LawError.invalid("Unsicheres Serverziel.") }
        var request = URLRequest(url: url)
        request.httpMethod = method; request.setValue("1", forHTTPHeaderField: "X-Noty-Client")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body { request.httpBody = try JSONEncoder().encode(body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw LawError.invalid("Ungültige Serverantwort.") }
        guard response.expectedContentLength <= Int64(limit) else { throw LawError.invalid("Serverdatei ist zu groß.") }
        var data = Data(); data.reserveCapacity(min(limit, max(0, Int(response.expectedContentLength))))
        for try await byte in bytes {
            if data.count >= limit { throw LawError.invalid("Serverdatei ist zu groß.") }
            data.append(byte)
        }
        guard (200..<300).contains(response.statusCode) else {
            let message = (try? JSONDecoder().decode([String: String].self, from: data)["error"]) ?? "Server nicht erreichbar (\(response.statusCode))."
            throw LawAPIError(status: response.statusCode, message: message)
        }
        return data
    }
    private nonisolated func decode<T: Decodable & Sendable>(_ type: T.Type, from data: Data) async throws -> T {
        try JSONDecoder().decode(type, from: data)
    }
    private nonisolated func verify(_ data: Data, sha: String?) async throws {
        guard let sha, sha.count == 64, SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == sha else { throw LawError.invalid("Prüfsumme der Gesetzesdatei fehlt oder stimmt nicht.") }
    }
    func updateLaws(manual: Bool = true) async {
        guard enabled, !downloading else { return }
        downloading = true; lastAttempt = Date(); progress = "Gesetzeskatalog wird geprüft …"
        defer { downloading = false }
        do {
            let data = try await fetch("/api/law-catalog", limit: 8_000_000)
            var next = try await decode(LawCatalog.self, from: data).validated()
            for (index, entry) in next.entries.enumerated() {
                guard enabled else { throw CancellationError() }
                guard let version = entry.versions.first(where: { $0.id == entry.currentVersion }) else { throw LawError.invalid("Gesetzesfassung fehlt.") }
                progress = "\(index + 1)/\(next.entries.count) · \(entry.abbr)"
                if (try? await offline.document(entry, version: version)) == nil {
                    let bytes = try await fetch(version.dataUrl)
                    try await verify(bytes, sha: version.sha256["json"])
                    try await offline.putDocument(bytes, entry: entry, version: version)
                }
            }
            // Retain old catalog entries/versions so old markings remain navigable.
            func merged(_ entries: [LawEntry], old: [LawEntry]) -> [LawEntry] {
                var result = entries.map { entry in
                    var e = entry
                    if let previous = old.first(where: { $0.id == e.id }) { e.versions += previous.versions.filter { v in !e.versions.contains(where: { $0.id == v.id }) } }
                    return e
                }
                result += old.filter { e in !result.contains(where: { $0.id == e.id }) }
                return result
            }
            next.laws = merged(next.laws, old: catalog?.laws ?? [])
            next.administrative = merged(next.administrative ?? [], old: catalog?.administrative ?? [])
            try await offline.publish(next)
            catalog = next; lastCheck = Date(); progress = "\(next.entries.count) Dokumente offline verfügbar"
            byteCount = await offline.byteCount()
        } catch is CancellationError { progress = "Download pausiert; vorhandene Fassungen bleiben verfügbar." }
        catch { if manual { self.error = error.localizedDescription }; progress = "Aktualisierung fehlgeschlagen; vorhandene Fassungen bleiben verfügbar. \(error.localizedDescription)" }
    }
    func document(_ entry: LawEntry, version: String? = nil) async throws -> LawDocument {
        guard let v = entry.versions.first(where: { $0.id == (version ?? entry.currentVersion) }) else { throw LawError.invalid("Gesetzesfassung fehlt.") }
        if let doc = try? await offline.document(entry, version: v) { return doc }
        let data = try await fetch(v.dataUrl); try await verify(data, sha: v.sha256["json"])
        try await offline.putDocument(data, entry: entry, version: v)
        return try await offline.document(entry, version: v)
    }
    func pdf(_ entry: LawEntry, version: String) async throws -> URL {
        let url = try await offline.pdfURL(entry.id, version: version)
        guard let v = entry.versions.first(where: { $0.id == version }), let path = v.pdfUrl else { throw LawError.invalid("Für dieses Dokument ist kein Original-PDF vorhanden.") }
        if FileManager.default.fileExists(atPath: url.path) {
            let bytes = try await offline.pdfData(entry.id, version: version)
            try await verify(bytes, sha: v.sha256["pdf"])
            guard PDFDocument(url: url) != nil else { throw LawError.invalid("Gespeicherte PDF-Datei nicht lesbar.") }
            return url
        }
        let data = try await fetch(path, limit: 150_000_000); try await verify(data, sha: v.sha256["pdf"])
        let result = try await offline.putPDF(data, id: entry.id, version: version)
        byteCount = await offline.byteCount()
        return result
    }
    func login(email: String, password: String, registering: Bool) async {
        guard !accountBusy else { return }
        accountBusy = true; defer { accountBusy = false }
        do {
            // E-mail registration needs mail delivery, which is switched off on the
            // server; a username account is created at once without any e-mail.
            if registering && email.contains("@") { throw LawError.invalid("Bitte wähle einen Benutzernamen ohne @. Registrieren per E-Mail ist noch nicht freigeschaltet.") }
            if registering && email.range(of: "^[\\p{L}\\p{N}_.-]{2,32}$", options: .regularExpression) == nil { throw LawError.invalid("Der Benutzername braucht 2–32 Buchstaben, Zahlen oder . _ -") }
            if registering && password.count < 12 { throw LawError.invalid("Das Passwort braucht mindestens 12 Zeichen.") }
            var body: [String: LawJSON] = ["password": .string(password)]
            body[email.contains("@") ? "email" : "name"] = .string(email)
            struct Response: Decodable, Sendable { var user: NotyAccountUser }
            let response = try await decode(Response.self, from: await fetch(registering ? "/api/register" : "/api/login", method: "POST", body: body, limit: 65536))
            guard let token = response.user.token, token.count == 64 else { throw LawError.invalid("Server unterstützt die native Anmeldung noch nicht.") }
            try NotyAccountKeychain.save(response.user)
            epoch += 1; user = response.user; sessionExpired = false
            try await personal.adoptGuests(owner: response.user.id)
            lastOwner = response.user.id; await refreshItems()
            Task { await synchronize() }
        } catch { self.error = error.localizedDescription }
    }
    func logout() async {
        do { try NotyAccountKeychain.save(nil) }
        catch { self.error = error.localizedDescription; return }
        let token = user?.token
        epoch += 1; user = nil; sessionExpired = false; syncStatus = "Abgemeldet · Markierungen bleiben lokal"
        if let token { _ = try? await fetch("/api/logout", method: "POST", body: [:], token: token, limit: 65536) }
    }
    func accountAction(_ path: String, email: String = "", password: String = "", code: String = "") async -> Bool {
        guard !accountBusy else { return false }
        accountBusy = true; defer { accountBusy = false }
        do {
            var body: [String: LawJSON] = [:]
            if !email.isEmpty { body["email"] = .string(email) }
            if !password.isEmpty { body["password"] = .string(password) }
            if !code.isEmpty { body["token"] = .string(code.trimmingCharacters(in: .whitespacesAndNewlines)) }
            _ = try await fetch(path, method: "POST", body: body, token: user?.token, limit: 65536)
            if (path == "/api/email/verify" || path == "/api/email"), let token = user?.token {
                struct Session: Decodable, Sendable { var user: NotyAccountUser? }
                if var fresh = try await decode(Session.self, from: await fetch("/api/session", token: token, limit: 65536)).user {
                    fresh.token = token; try NotyAccountKeychain.save(fresh); user = fresh
                }
            }
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func refreshItems() async {
        do { items = try await personal.items() } catch { self.error = error.localizedDescription }
    }
    func save(kind: String, payload: [String: LawJSON]) async {
        let owner = user?.id ?? lastOwner
        if kind == "bookmark", items.contains(where: { item in
            item.kind == kind && !item.deleted && item.owner == owner && ["lawId", "versionId", "view", "sectionId", "page"].allSatisfy { item.payload[$0] == payload[$0] }
        }) { return }
        do { try await personal.put(kind: kind, payload: payload, owner: user?.id ?? lastOwner); await refreshItems(); await synchronize() }
        catch { self.error = error.localizedDescription }
    }
    func remove(_ item: LawPersonalItem) async {
        do { try await personal.remove(id: item.id, owner: item.owner); await refreshItems(); await synchronize() }
        catch { self.error = error.localizedDescription }
    }
    func synchronize() async {
        guard enabled, syncEnabled, !syncing, let u = user, let token = u.token else { return }
        syncing = true
        let generation = epoch
        defer { syncing = false }
        func current() -> Bool { generation == epoch && user?.id == u.id && syncEnabled && enabled }
        func pull() async throws {
            var more = true, pages = 0
            while more && pages < 100 {
                guard current() else { throw CancellationError() }
                let cursor = try await personal.cursor(owner: u.id)
                let data = try await fetch("/api/sync?after=\(cursor)", token: token, limit: 32_000_000)
                let page = try await decode(LawSyncPage.self, from: data)
                guard current() else { throw CancellationError() }
                try await personal.apply(page, owner: u.id); more = page.hasMore; pages += 1
                if more && page.cursor <= cursor { throw LawError.invalid("Synchronisierung kommt nicht voran.") }
            }
            if more { throw LawError.invalid("Viele Änderungen: Synchronisierung wird beim nächsten Versuch fortgesetzt.") }
        }
        do {
            syncStatus = "Wird synchronisiert …"
            try await pull()
            for item in try await personal.pending(owner: u.id) {
                guard current() else { throw CancellationError() }
                let path = item.kind == "bookmark" ? "/api/bookmarks" : "/api/annotations"
                do {
                    let data = try await fetch(item.deleted ? path + "/" + item.id : path, method: item.deleted ? "DELETE" : "POST", body: item.deleted ? [:] : item.payload, token: token, limit: 65536)
                    guard current() else { throw CancellationError() }
                    let response = try await decode([String: LawJSON].self, from: data)
                    var payload: [String: LawJSON]?
                    if case let .object(value) = response[item.kind] { payload = value }
                    try await personal.acknowledge(item, payload: payload)
                } catch let error as LawAPIError where item.deleted && error.status == 404 {
                    guard current() else { throw CancellationError() }
                    try await personal.acknowledge(item)
                } catch let error as LawAPIError where error.status == 409 {
                    // Pull authoritative tombstones, retaining any unrelated pending work.
                    try await pull()
                    throw error
                }
            }
            try await pull(); lastSync = Date(); await refreshItems()
            syncStatus = "Synchronisiert · \(Date().formatted(date: .omitted, time: .shortened))"
        } catch is CancellationError { syncStatus = "Synchronisierung pausiert" }
        catch let error as LawAPIError where error.status == 401 {
            sessionExpired = true; syncStatus = "Anmeldung abgelaufen · Unter Konto erneut anmelden; Änderungen bleiben lokal"
        } catch { syncStatus = "Offline/Fehler · Änderungen bleiben lokal: \(error.localizedDescription)" }
    }
    func exportPersonal() async throws -> URL {
        let bytes = try await personal.exportData()
        let url = URL.temporaryDirectory.appendingPathComponent("Noty-Gesetzesmarkierungen-\(UUID().uuidString).json")
        try await Task.detached(priority: .utility) { try bytes.write(to: url, options: .atomic) }.value
        return url
    }
    func restorePersonal(_ url: URL) async {
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        do { let data = try Data(contentsOf: url, options: .mappedIfSafe); try await personal.importData(data); await refreshItems() }
        catch { self.error = error.localizedDescription }
    }
}
