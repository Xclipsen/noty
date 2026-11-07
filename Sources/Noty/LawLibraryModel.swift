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
    /// Whether „Mit Apple anmelden“ is linked (`GET /api/session`); nil until
    /// the server has said. Only this flag is kept, never Apple's own data.
    var apple: Bool?
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
    /// The server's machine-readable `code` (e.g. `apple_unknown`), if any.
    var code: String? = nil
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
    @Published private(set) var user: NotyAccountUser? { didSet { if oldValue?.id != user?.id { publishItems() } } }
    @Published private(set) var catalog: LawCatalog?
    /// The current owner's live entries (B12): signed in the account's, signed
    /// out the guest's. Readers and lists show only these; entries of other
    /// owners stay stored (`hiddenItemCount`) and are never shown or deleted.
    @Published private(set) var items: [LawPersonalItem] = []
    /// The current owner's entries the server refused for good (B9), for
    /// „Erneut versuchen“ (`retryRejected`) or „Nur lokal behalten“ (`keepLocal`).
    @Published private(set) var rejectedItems: [LawPersonalItem] = []
    /// Live entries of other owners kept on this iPad, not shown.
    @Published private(set) var hiddenItemCount = 0
    /// Structured sync state (B9); `syncStatus` is its one-line text.
    @Published private(set) var syncState = LawSyncStatus(state: .guest)
    /// Set once when loading merged duplicate entries (B1); says where the
    /// exact prior file was kept. For the settings page.
    @Published var personalNotice: String?
    @Published private(set) var downloading = false
    @Published private(set) var syncing = false
    @Published private(set) var accountBusy = false
    @Published private(set) var sessionExpired = false { didSet { if oldValue != sessionExpired { refreshStatus() } } }
    @Published private(set) var progress = ""
    @Published private(set) var byteCount: Int64 = 0
    @Published var error: String?
    /// Visible pages that show `error` themselves; the app alert stays silent then.
    @Published var inlineErrorPages = 0
    /// Counts `Space l`: the open reader takes the keys.
    @Published var keyFocus = 0
    /// Mail delivery is switched off on the server (user decision, see
    /// LAW-INTEGRATION-PLAN). Everything waiting for an e-mail stays hidden until then.
    static let mailDelivery = false
    /// Window state (open, stashed, docked, edge, size), see `LawPanelModel`.
    /// Kept here only so that switching the collection off closes the window.
    let panel: LawPanelModel
    var sceneActive = true
    private var started = false
    private var epoch = 0
    /// Last successful catalogue check, kept over launches: a start within
    /// six hours of it checks nothing (S6). A future date (clock change) counts as due.
    private var lastCheck = UserDefaults.standard.object(forKey: LawLibraryModel.lastCheckKey) as? Date ?? .distantPast {
        didSet { UserDefaults.standard.set(lastCheck, forKey: Self.lastCheckKey) }
    }
    static let lastCheckKey = "noty.laws.lastCatalogCheck"
    /// Stored PDFs that matched their catalogue hash this session, with the
    /// file's size and date then and the hash they matched (`pdf`): reopening
    /// needs no new read; a catalogue with another hash checks again.
    private var verifiedPDFs: [String: PDFStamp] = [:]
    private struct PDFStamp: Equatable, Sendable { var size: Int; var modified: Date; var sha: String? }
    private var lastAttempt = Date.distantPast
    private var lastSync = Date.distantPast
    /// Every stored entry of every owner.
    private var allItems: [LawPersonalItem] = []
    private var ownPending = 0
    private var syncGate = LawSyncGate()
    private var lastSyncError: String?
    private var lastSynced: Date?
    static let readingSpotsKey = "noty.laws.readingSpots"
    private var readingSpots = LawReadingSpots.decode(UserDefaults.standard.data(forKey: LawLibraryModel.readingSpotsKey),
        legacySections: UserDefaults.standard.dictionary(forKey: "noty.laws.readingSections") as? [String: String],
        legacyLast: UserDefaults.standard.string(forKey: "noty.laws.lastLaw"))
    var enabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }
    var syncEnabled: Bool { UserDefaults.standard.object(forKey: Self.syncKey) as? Bool ?? true }
    var automaticUpdates: Bool { UserDefaults.standard.object(forKey: Self.updatesKey) as? Bool ?? true }
    var entries: [LawEntry] { catalog?.entries ?? [] }
    /// The signed-in account's entries waiting to be sent (0 for the guest).
    var pendingCount: Int { user == nil ? 0 : ownPending }
    /// Owner of new entries and of what is shown: the account, signed out the guest (`nil`).
    var owner: String? { user?.id }
    var syncStatus: String {
        var text = syncState.text(time: NotyText.statusDate)
        if user == nil, hiddenItemCount > 0 { text += " · \(NotyText.count(hiddenItemCount, "Eintrag", "Einträge")) eines Kontos bleiben gespeichert" }
        return text
    }
    init() {
        panel = LawPanelModel()
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 25; config.timeoutIntervalForResource = 300
        session = URLSession(configuration: config, delegate: LawSessionDelegate(), delegateQueue: nil)
        user = NotyAccountKeychain.read()
    }
    func start() async {
        guard !started else { return }
        started = true
        // B15: a damaged catalogue must not keep the personal data from loading.
        do { catalog = try await offline.catalog() }
        catch { self.error = "Lokaler Gesetzesbestand: \(error.localizedDescription)" }
        byteCount = await offline.byteCount()
        do {
            allItems = try await personal.items()
            if let repair = try await personal.takeRepairReport() {
                personalNotice = "\(NotyText.count(repair.merged, "doppelter Eintrag", "doppelte Einträge")) zusammengeführt. Vorheriger Stand gesichert als \(repair.backup.lastPathComponent)."
            }
            if let user { try await personal.adoptGuests(owner: user.id) }
            _ = try? await personal.pruneTombstones()
            await refreshItems()
        } catch { self.error = "Persönliche Gesetzesdaten: \(error.localizedDescription)"; publishItems() }
        await tick()
    }
    func tick() async {
        guard enabled else { return }
        let sinceCheck = Date().timeIntervalSince(lastCheck)
        let needsUpdate = catalog == nil || (automaticUpdates && (sinceCheck > 6 * 3600 || sinceCheck < 0))
        if needsUpdate && Date().timeIntervalSince(lastAttempt) > (catalog == nil ? 60 : 900) { await updateLaws(manual: false) }
        if Date().timeIntervalSince(lastSync) > 30 { await synchronize() }
    }
    func settingsChanged() async {
        epoch += 1
        refreshStatus()
        if !enabled { panel.close(); return }
        if catalog == nil { lastAttempt = .distantPast }
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
            let fields = try? JSONDecoder().decode([String: String].self, from: data)
            let message = fields?["error"] ?? (response.statusCode >= 500 ? "Server nicht erreichbar (\(response.statusCode))." : "Der Server hat die Anfrage abgelehnt (\(response.statusCode)).")
            throw LawAPIError(status: response.statusCode, message: message, code: fields?["code"])
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
                // Hash of the stored file instead of decoding every law (S6).
                if !(await offline.hasDocument(entry, version: version)) {
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
            catalog = next; lastCheck = Date(); progress = "\(NotyText.count(next.entries.count, "Dokument", "Dokumente")) offline verfügbar"
            byteCount = await offline.byteCount()
        } catch is CancellationError { progress = "Download pausiert; vorhandene Fassungen bleiben verfügbar." }
        catch {
            if manual { self.error = error.localizedDescription }
            progress = "Aktualisierung fehlgeschlagen; vorhandene Fassungen bleiben verfügbar." + (manual ? "" : " \(error.localizedDescription)")
        }
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
        let key = "\(entry.id)|\(version)", sha = v.sha256["pdf"]
        if let stamp = Self.pdfStamp(url, sha: sha) {
            if verifiedPDFs[key] == stamp { return url }
            // S13: mapped read, hash and parse off the main thread (up to 150 MB).
            if await Task.detached(priority: .userInitiated, operation: { Self.storedPDFIsIntact(url, sha: sha) }).value,
               Self.pdfStamp(url, sha: sha) == stamp {
                verifiedPDFs[key] = stamp; return url
            }
        }
        verifiedPDFs[key] = nil
        let data = try await fetch(path, limit: 150_000_000); try await verify(data, sha: sha)
        let result = try await offline.putPDF(data, id: entry.id, version: version, replacingDamaged: true)
        if let stamp = Self.pdfStamp(result, sha: sha) { verifiedPDFs[key] = stamp }
        byteCount = await offline.byteCount()
        return result
    }
    /// `sha`: the catalogue hash the file is (to be) checked against.
    private nonisolated static func pdfStamp(_ url: URL, sha: String?) -> PDFStamp? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]),
              values.isRegularFile == true, let size = values.fileSize, let modified = values.contentModificationDate else { return nil }
        return PDFStamp(size: size, modified: modified, sha: sha)
    }
    /// The stored PDF is the checked download: at most 150 MB, SHA-256 as in
    /// the catalogue, and CoreGraphics can open it (thread-safe, unlike
    /// building a `PDFDocument` just to throw it away).
    private nonisolated static func storedPDFIsIntact(_ url: URL, sha: String?) -> Bool {
        guard let sha, sha.count == 64, let stamp = pdfStamp(url, sha: sha), stamp.size <= 150_000_000,
              let data = try? Data(contentsOf: url, options: .alwaysMapped),
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == sha else { return false }
        return CGPDFDocument(url as CFURL) != nil
    }
    /// The PDF of this version is already on this iPad (no download needed).
    func pdfIsOffline(_ entry: LawEntry, version: String) async -> Bool {
        guard let url = try? await offline.pdfURL(entry.id, version: version) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }
    /// `true` once signed in; a failed attempt keeps the form as typed.
    func login(email rawName: String, password: String, registering: Bool) async -> Bool {
        guard !accountBusy else { return false }
        accountBusy = true; defer { accountBusy = false }
        let email = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            // E-mail registration needs mail delivery, which is switched off on the
            // server; a username account is created at once without any e-mail.
            if registering && email.contains("@") { throw LawError.invalid("Bitte einen Benutzernamen ohne @ wählen. Registrieren per E-Mail ist noch nicht freigeschaltet.") }
            if registering && email.range(of: "^[\\p{L}\\p{N}_.-]{2,32}$", options: .regularExpression) == nil { throw LawError.invalid("Der Benutzername braucht 2–32 Buchstaben, Zahlen oder . _ -") }
            if registering && password.count < 12 { throw LawError.invalid("Das Passwort braucht mindestens 12 Zeichen.") }
            var body: [String: LawJSON] = ["password": .string(password)]
            body[email.contains("@") ? "email" : "name"] = .string(email)
            struct Response: Decodable, Sendable { var user: NotyAccountUser }
            let response = try await decode(Response.self, from: await fetch(registering ? "/api/register" : "/api/login", method: "POST", body: body, limit: 65536))
            try await signedIn(response.user)
            Task { await refreshAccount() }
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    /// The same session for every way in (password, Apple): Keychain, account
    /// switch and guest markings.
    private func signedIn(_ account: NotyAccountUser) async throws {
        guard let token = account.token, token.count == 64 else { throw LawError.invalid("Server unterstützt die native Anmeldung noch nicht.") }
        try NotyAccountKeychain.save(account)
        epoch += 1; accountUpdates.changed(); user = account; sessionExpired = false
        try await personal.adoptGuests(owner: account.id)
        lastSyncError = nil; lastSynced = nil; await refreshItems()
        Task { await synchronize() }
    }
    private let apple = AppleSignInController()
    /// Local account changes (sign-in, Apple linked/unlinked, e-mail): an
    /// older `refreshAccount` answer never overwrites a newer change.
    private var accountUpdates = AccountUpdateGate()
    /// Markings of another account that are not transferred yet.
    private var foreignPendingCount: Int { allItems.filter { $0.dirty && $0.owner != nil && $0.owner != user?.id }.count }
    /// „Mit Apple anmelden“: `true` once signed in. Cancelling the Apple sheet
    /// is silent; a new account is reported in `message`. No account appears
    /// silently while the iPad belongs to another one (`AppleLoginPlan`):
    /// with an expired session of a known account an unknown Apple ID only
    /// explains linking; with another account's untransferred markings the
    /// user is asked before a new account is created.
    func appleLogin() async -> (signedIn: Bool, created: Bool) {
        guard !accountBusy else { return (false, false) }
        accountBusy = true; defer { accountBusy = false }
        let expired = sessionExpired && user != nil
        let expiredName = expired ? (user?.email ?? user?.name) : nil
        let foreign = foreignPendingCount
        switch await apple.authorize(withName: true) {
        case .canceled: return (false, false)
        case .failed(let message): error = message; return (false, false)
        case .authorized(let auth):
            func login(create: Bool) async throws -> AppleLoginResponse<NotyAccountUser> {
                let body = AppleSignIn.loginBody(identityToken: auth.identityToken, nonce: auth.nonce, givenName: auth.givenName, create: create)
                return try await decode(AppleLoginResponse<NotyAccountUser>.self, from: await fetch("/api/apple/login", method: "POST", body: body, limit: 65536))
            }
            do {
                var response: AppleLoginResponse<NotyAccountUser>
                do {
                    response = try await login(create: AppleLoginPlan.mayCreate(sessionExpired: expired, foreignPendingCount: foreign))
                } catch let failure as LawAPIError where failure.status == 401 && failure.code == AppleSignIn.unknownCode {
                    switch AppleLoginPlan.unknown(sessionExpired: expired, accountName: expiredName, foreignPendingCount: foreign) {
                    case .explainLinking(let text): self.error = text; return (false, false)
                    case .confirmCreation(let title, let message):
                        guard await TopAlert.ask(title, message, confirm: "Neues Konto anlegen") else { return (false, false) }
                        // The same token, still within its few minutes of validity.
                        response = try await login(create: true)
                    }
                }
                response.user.apple = true
                try await signedIn(response.user)
                return (true, response.created)
            } catch { self.error = appleMessage(error); return (false, false) }
        }
    }
    /// Links Apple to the account that is signed in now (never by e-mail).
    func appleLink() async -> Bool {
        guard !accountBusy, let account = user, let token = account.token, !sessionExpired else { return false }
        accountBusy = true; defer { accountBusy = false }
        let generation = epoch
        switch await apple.authorize(withName: false) {
        case .canceled: return false
        case .failed(let message): error = message; return false
        case .authorized(let auth):
            do {
                // Signed out or switched account while the sheet was open: link nothing.
                guard generation == epoch, user?.id == account.id else { throw CancellationError() }
                let body = AppleSignIn.linkBody(identityToken: auth.identityToken, nonce: auth.nonce)
                let response = try await decode(AppleLinkResponse<NotyAccountUser>.self, from: await fetch("/api/apple/link", method: "POST", body: body, token: token, limit: 65536))
                try storeApple(response.apple, fresh: response.user, account: account.id, generation: generation)
                return true
            } catch is CancellationError { return false }
            catch let failure as LawAPIError where failure.status == 401 {
                // The account session ended (the Apple token is checked separately): sign in again.
                if generation == epoch, user?.id == account.id { sessionExpired = true }
                self.error = "Die Anmeldung als „\(account.email ?? account.name)“ ist abgelaufen. Bitte erneut anmelden und Apple danach verknüpfen."
                return false
            }
            catch { self.error = appleMessage(error); return false }
        }
    }
    func appleUnlink() async -> Bool {
        guard !accountBusy, let account = user, let token = account.token, !sessionExpired else { return false }
        accountBusy = true; defer { accountBusy = false }
        let generation = epoch
        do {
            let response = try await decode(AppleLinkResponse<NotyAccountUser>.self, from: await fetch("/api/apple", method: "DELETE", body: [:], token: token, limit: 65536))
            try storeApple(response.apple, fresh: nil, account: account.id, generation: generation)
            return true
        } catch { self.error = appleMessage(error); return false }
    }
    private func appleMessage(_ error: Error) -> String {
        if let error = error as? LawAPIError, error.status == 404 || error.status == 405 { return "Der noty-Server kennt „Mit Apple anmelden“ noch nicht. Bitte später erneut versuchen." }
        if error is DecodingError { return "Ungültige Serverantwort bei der Anmeldung mit Apple." }
        return error.localizedDescription
    }
    private func storeApple(_ linked: Bool, fresh: NotyAccountUser?, account: String, generation: Int) throws {
        guard generation == epoch, var next = user, next.id == account else { return }
        if let fresh, fresh.id == account { next.name = fresh.name; next.email = fresh.email; next.emailVerified = fresh.emailVerified }
        next.apple = linked
        try NotyAccountKeychain.save(next); user = next
        accountUpdates.changed()
    }
    /// Best effort: learns `apple` (and name/e-mail changes) for the stored session.
    func refreshAccount() async {
        guard let account = user, let token = account.token, !sessionExpired else { return }
        let generation = epoch
        // A link/unlink finishing meanwhile wins over this older answer.
        let update = accountUpdates.begin()
        struct Session: Decodable, Sendable { var user: NotyAccountUser? }
        do {
            let session = try await decode(Session.self, from: await fetch("/api/session", token: token, limit: 65536))
            guard generation == epoch, user?.id == account.id else { return }
            guard var fresh = session.user, fresh.id == account.id else { sessionExpired = true; return }
            guard accountUpdates.isCurrent(update), !accountBusy else { return }
            fresh.token = token; try NotyAccountKeychain.save(fresh); user = fresh
            accountUpdates.changed()
        } catch let error as LawAPIError where error.status == 401 {
            if generation == epoch, user?.id == account.id { sessionExpired = true }
        } catch {}
    }
    func logout() async {
        do { try NotyAccountKeychain.save(nil) }
        catch { self.error = error.localizedDescription; return }
        let token = user?.token
        epoch += 1; user = nil; sessionExpired = false; lastSyncError = nil; lastSynced = nil; refreshStatus()
        if let token { _ = try? await fetch("/api/logout", method: "POST", body: [:], token: token, limit: 65536) }
    }
    func accountAction(_ path: String, email: String = "", password: String = "", code: String = "") async -> Bool {
        guard !accountBusy else { return false }
        accountBusy = true; defer { accountBusy = false }
        do {
            var body: [String: LawJSON] = [:]
            let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
            if !address.isEmpty { body["email"] = .string(address) }
            if !password.isEmpty { body["password"] = .string(password) }
            if !code.isEmpty { body["token"] = .string(code.trimmingCharacters(in: .whitespacesAndNewlines)) }
            _ = try await fetch(path, method: "POST", body: body, token: user?.token, limit: 65536)
            if (path == "/api/email/verify" || path == "/api/email"), let token = user?.token {
                struct Session: Decodable, Sendable { var user: NotyAccountUser? }
                if var fresh = try await decode(Session.self, from: await fetch("/api/session", token: token, limit: 65536)).user {
                    fresh.token = token; try NotyAccountKeychain.save(fresh); user = fresh
                    accountUpdates.changed()
                }
            }
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func refreshItems() async {
        do { allItems = try await personal.items(); publishItems() } catch { self.error = error.localizedDescription }
    }
    private func publishItems() {
        let owner = user?.id
        let visible = allItems.visible(to: owner)
        if visible != items { items = visible }
        let rejected = allItems.filter { $0.owner == owner && $0.isRejected }
        if rejected != rejectedItems { rejectedItems = rejected }
        let hidden = allItems.filter { $0.owner != owner && !$0.deleted }.count
        if hidden != hiddenItemCount { hiddenItemCount = hidden }
        ownPending = allItems.filter { $0.owner == owner && $0.awaitsUpload }.count
        refreshStatus()
    }
    private func refreshStatus() {
        let next = LawSyncStatus.derive(signedIn: user != nil, sessionExpired: sessionExpired, enabled: enabled, syncEnabled: syncEnabled,
                                        running: syncing, pending: pendingCount, rejected: rejectedItems.count, lastError: lastSyncError, lastSynced: lastSynced)
        if next != syncState { syncState = next }
    }
    /// The current owner's live entries, optionally of one kind, law and version.
    func visibleItems(kind: String? = nil, law: String? = nil, version: String? = nil) -> [LawPersonalItem] {
        items.filter { item in
            (kind.map { item.kind == $0 } ?? true) && (law.map { item.payload["lawId"]?.string == $0 } ?? true)
                && (version.map { item.payload["versionId"]?.string == $0 } ?? true)
        }
    }
    /// Visible markings of `law` per version, in catalogue order (B10), e.g.
    /// for „n Markierungen in Fassung …“ when another version is open.
    func markCounts(law: String) -> [LawVersionMarkCount] {
        items.markCounts(law: law, versionOrder: entries.first { $0.id == law }?.versions.map(\.id) ?? [])
    }
    /// Any number of new and removed entries of the current owner as one
    /// atomic write and one sync (B16). `false` (with `error` set) leaves the
    /// prior state complete. Removing another owner's entry does nothing.
    @discardableResult
    func commit(puts: [LawPersonalChange] = [], removes: [LawPersonalRef] = []) async -> Bool {
        guard !puts.isEmpty || !removes.isEmpty else { return true }
        do { try await personal.batch(puts: puts, removes: removes, owner: owner) }
        catch { self.error = error.localizedDescription; await refreshItems(); return false }
        await refreshItems()
        Task { await synchronize() }
        return true
    }
    /// `commit(puts:removes:)` for mark plans (`commit(plan:)`): every entry
    /// to remove must still be live, else nothing is written
    /// (`LawPersonalConflict`). Errors are thrown for the caller's message,
    /// not shown as an alert.
    func commitMarks(puts: [LawPersonalChange], removes: [LawPersonalRef]) async throws {
        guard !puts.isEmpty || !removes.isEmpty else { return }
        do { try await personal.batch(puts: puts, removes: removes, owner: owner, requireLive: true) }
        catch { await refreshItems(); throw error }
        await refreshItems()
        Task { await synchronize() }
    }
    func save(kind: String, payload: [String: LawJSON]) async {
        if kind == "bookmark", items.contains(where: { item in
            item.kind == kind && ["lawId", "versionId", "view", "sectionId", "page"].allSatisfy { item.payload[$0] == payload[$0] }
        }) { return }
        await commit(puts: [LawPersonalChange(kind: kind, payload: payload)])
    }
    func remove(_ item: LawPersonalItem) async {
        guard item.owner == owner else { return }
        await commit(removes: [item.ref])
    }
    /// „Erneut versuchen“ for refused entries; `nil` = all of the current owner.
    func retryRejected(_ entries: [LawPersonalItem]? = nil) async {
        do { try await personal.retry(entries?.map(\.ref), owner: owner) } catch { self.error = error.localizedDescription }
        await refreshItems()
        await synchronize()
    }
    /// „Nur lokal behalten“: the entries stay visible here and are never sent.
    func keepLocal(_ entries: [LawPersonalItem]) async {
        do { try await personal.keepLocal(entries.map(\.ref), owner: owner) } catch { self.error = error.localizedDescription }
        await refreshItems()
    }
    private var canSync: Bool { enabled && syncEnabled && !sessionExpired && user?.token != nil }
    /// Pull, push, pull. During a run another call does not return silently
    /// unseen: the running one goes once more (at most five runs in a row).
    func synchronize() async {
        guard canSync else { refreshStatus(); return }
        guard syncGate.request() else { return }
        syncing = true; refreshStatus()
        var runs = 0
        while true {
            await synchronizeOnce()
            runs += 1
            guard syncGate.finish() else { break }
            if runs >= 5 || !canSync { syncGate.stop(); break }
        }
        syncing = false; refreshStatus()
    }
    private func synchronizeOnce() async {
        guard canSync, let u = user, let token = u.token else { return }
        let generation = epoch
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
        /// All answers of one push are written together (B16), also when it stops early.
        func push() async throws {
            var receipts: [LawPushReceipt] = []
            var failures = LawPushFailures()
            do {
                // New entries before deletions (`pending`). One refused entry
                // must not hold back the ones behind it.
                for item in try await personal.pending(owner: u.id) {
                    guard current() else { throw CancellationError() }
                    let path = item.kind == "bookmark" ? "/api/bookmarks" : "/api/annotations"
                    do {
                        let data = try await fetch(item.deleted ? path + "/" + item.id : path, method: item.deleted ? "DELETE" : "POST", body: item.deleted ? [:] : item.payload, token: token, limit: 65536)
                        let response = try await decode([String: LawJSON].self, from: data)
                        var payload: [String: LawJSON]?
                        if case let .object(value) = response[item.kind] { payload = value }
                        receipts.append(LawPushReceipt(sent: item, outcome: .accepted(payload)))
                    } catch let error as LawAPIError where item.deleted && error.status == 404 {
                        receipts.append(LawPushReceipt(sent: item, outcome: .accepted(nil)))
                    } catch let error as LawAPIError where error.status == 401 {
                        throw error
                    } catch let error as LawAPIError where error.status == 409 && error.code == "deleted" {
                        // Deleted on the server for ever: the deletion wins here too.
                        receipts.append(LawPushReceipt(sent: item, outcome: .deletedOnServer))
                    } catch let error as LawAPIError where LawPushFailures.isPermanent(status: error.status, code: error.code) {
                        _ = failures.record(status: error.status)
                        receipts.append(LawPushReceipt(sent: item, outcome: .rejected(status: error.status, message: error.message)))
                    } catch let error as LawAPIError {
                        if failures.record(status: error.status) == .stop { throw error }
                    } catch is DecodingError {
                        _ = failures.record(status: 422)
                    }
                }
            } catch {
                try? await personal.record(receipts)
                throw error
            }
            try await personal.record(receipts)
        }
        do {
            try await pull()
            try await push()
            try await pull()
            lastSync = Date(); lastSynced = Date(); lastSyncError = nil
            _ = try? await personal.pruneTombstones()
        } catch is CancellationError { lastSyncError = nil }
        catch let error as LawAPIError where error.status == 401 {
            if generation == epoch, user?.id == u.id { sessionExpired = true }
        } catch { if generation == epoch { lastSyncError = error.localizedDescription } }
        await refreshItems()
    }
    /// Where the reader was in `law` (B10): version, text/PDF, section, PDF page, offset.
    func readingSpot(law: String) -> LawReadingSpot? { readingSpots.spot(law: law) }
    /// The spot of the law read last.
    var lastReadingSpot: LawReadingSpot? { readingSpots.last }
    /// Remembers the reading spot of its law (and the law read last). Cheap
    /// when nothing changed; also keeps the older section-only keys current.
    func rememberReading(_ spot: LawReadingSpot) {
        guard readingSpots.remember(spot), let data = try? JSONEncoder().encode(readingSpots) else { return }
        let defaults = UserDefaults.standard
        defaults.set(data, forKey: Self.readingSpotsKey)
        if let section = spot.sectionId {
            var sections = defaults.dictionary(forKey: "noty.laws.readingSections") as? [String: String] ?? [:]
            if sections[spot.lawId] != section { sections[spot.lawId] = section; defaults.set(sections, forKey: "noty.laws.readingSections") }
        }
        defaults.set(spot.lawId, forKey: "noty.laws.lastLaw")
    }
    func exportPersonal() async throws -> URL {
        let bytes = try await personal.exportData()
        let url = URL.temporaryDirectory.appendingPathComponent("Noty-Gesetzesmarkierungen-\(UUID().uuidString).json")
        try await Task.detached(priority: .utility) { try bytes.write(to: url, options: .atomic) }.value
        return url
    }
    func restorePersonal(_ url: URL) async {
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            // Signed in, restored guest entries go to the account like at
            // sign-in; otherwise they would stay hidden until the next login.
            try await personal.importData(data, adoptingGuestsFor: user?.id)
            await refreshItems(); Task { await synchronize() }
        }
        catch { self.error = error.localizedDescription }
    }
}
