import SwiftUI
import Security
import NotebookCore

private enum BackupTargetError: LocalizedError {
    case missing, folderUnreachable, invalidResponse, verification, http(Int), credential, listing
    var errorDescription: String? {
        switch self {
        case .missing: "Backupziel nicht erreichbar. Ordner erneut wählen bzw. WebDAV-Zugang prüfen."
        case .folderUnreachable: ExternalBackupModel.folderUnreachableText
        case .invalidResponse: "Backupziel antwortet ungültig oder leitet um. Bitte die endgültige HTTPS-Ordneradresse verwenden."
        case .verification: "Die zurückgelesene Sicherung stimmt nicht überein. Ältere Sicherungen bleiben erhalten."
        case .http(let code): "WebDAV meldet HTTP \(code). Zugang, Ordneradresse und Schreibrechte prüfen."
        case .credential: "WebDAV-Zugang konnte nicht im Schlüsselbund gelesen oder gesichert werden."
        case .listing: "Die Sicherung ist geprüft; die Liste älterer Stände konnte nicht vollständig gelesen werden. Keine Bereinigung."
        }
    }
}

/// No redirect may forward the Authorization header to another endpoint.
private final class BackupSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}

private enum BackupKeychain {
    struct Credentials: Codable { let username: String; let password: String }
    static func credentials(_ account: String) throws -> Credentials {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "noty.external-backup", kSecAttrAccount as String: account,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, let credentials = try? JSONDecoder().decode(Credentials.self, from: data) else { throw BackupTargetError.credential }
        return credentials
    }
    static func save(_ value: String, username: String, account: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "noty.external-backup", kSecAttrAccount as String: account]
        let attributes: [String: Any] = [kSecValueData as String: try JSONEncoder().encode(Credentials(username: username, password: value)),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            guard SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil) == errSecSuccess else { throw BackupTargetError.credential }
        } else if status != errSecSuccess { throw BackupTargetError.credential }
    }
}

@MainActor
final class ExternalBackupModel: ObservableObject {
    @Published private(set) var policy: ExternalBackupPolicy
    @Published private(set) var status: String
    @Published private(set) var busy = false
    @Published var history: [String] = []
    @Published var error: String?
    /// The stored folder bookmark could not be resolved; the target is kept, not forgotten.
    @Published private(set) var folderUnreachable = false
    nonisolated static let folderUnreachableText = "Backup-Ordner nicht mehr erreichbar – bitte neu wählen"
    private let key: String
    private let session: URLSession
    init(root: URL) {
        // Stable per-area key; migrates the former absolute-container-path key once.
        key = StableDefaults.key("externalBackup", root: root, legacyPrefix: "noty.externalBackup.") { values in
            let decoded = values.compactMap { ($0 as? Data).flatMap { try? JSONDecoder().decode(ExternalBackupPolicy.self, from: $0) } }
            return ExternalBackupPolicy.preferredMigration(decoded).flatMap { try? JSONEncoder().encode($0) } ?? values.first
        }
        let saved = UserDefaults.standard.data(forKey: key)
        if let saved, let value = try? JSONDecoder().decode(ExternalBackupPolicy.self, from: saved), (try? value.validate()) != nil {
            policy = value
            status = value.lastSuccess.map { "Zuletzt geprüft: \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "Noch keine externe Sicherung"
        } else { policy = ExternalBackupPolicy(); status = saved == nil ? "Externes Backup nicht eingerichtet" : "Backupziel unlesbar · bitte neu einrichten" }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 45; configuration.timeoutIntervalForResource = 180
        configuration.urlCredentialStorage = nil; configuration.httpCookieStorage = nil; configuration.urlCache = nil
        session = URLSession(configuration: configuration, delegate: BackupSessionDelegate(), delegateQueue: nil)
        if policy.target == .folder { Task { [weak self] in self?.checkFolder() } }
    }
    /// Resolves the bookmark early so an unreachable folder is reported instead of silently failing later.
    func checkFolder() {
        guard policy.target == .folder, !busy else { return }
        _ = try? folder()
    }
    var username: String { (try? BackupKeychain.credentials(credentialAccount).username) ?? "" }
    private var credentialAccount: String { policy.series.uuidString }
    private func persist() { if let data = try? JSONEncoder().encode(policy) { UserDefaults.standard.set(data, forKey: key) } }
    func disable() { guard !busy else { return }; policy.target = .disabled; persist(); history = []; status = "Automatisches externes Backup aus" }
    func setRetention(_ count: Int) { guard !busy else { return }; policy.keep = min(30, max(3, count)); persist() }
    func useFolder(_ url: URL) {
        guard !busy else { return }
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let bookmark = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
            policy.folderBookmark = bookmark; policy.folderName = url.lastPathComponent
            policy.target = .folder; policy.lastSuccess = nil; policy.lastAttempt = nil; folderUnreachable = false
            try policy.validate(); persist(); history = []; status = "Ordner gewählt · erste Sicherung steht aus"
        } catch { self.error = "Ordner konnte nicht eingerichtet werden." }
    }
    func useWebDAV(endpoint: String, username: String, password: String) {
        guard !busy else { return }
        do {
            let url = try ExternalBackupPolicy.webDAVDirectory(endpoint)
            guard !username.contains(":"), !username.contains("\n"), !username.contains("\r") else { throw BackupTargetError.credential }
            // Persist the credential before publishing the new active target.
            try BackupKeychain.save(password, username: username, account: credentialAccount)
            policy.endpoint = url.absoluteString; policy.target = .webDAV
            policy.lastSuccess = nil; policy.lastAttempt = nil
            try policy.validate(); persist(); history = []; status = "WebDAV gewählt · erste Sicherung steht aus"
        } catch { self.error = "WebDAV konnte nicht eingerichtet werden. HTTPS-Ordneradresse und Schlüsselbund prüfen." }
    }
    func attempt(library: LibraryModel, toolbox: ToolbarSettingsModel, manual: Bool = false) async {
        guard !busy, policy.target != .disabled, library.ready, !library.busy, manual || policy.due() else { return }
        busy = true; defer { busy = false }
        policy.lastAttempt = Date(); persist(); status = "Bibliothek wird für externes Backup gesichert …"
        let bytes: Data?
        if library.opened != nil { bytes = await library.editorBackup?() }
        else if await toolbox.flush() { bytes = await library.libraryBackup(background: !manual) }
        else { bytes = nil }
        guard let bytes else { status = "Backup ausstehend · Speichern oder laufenden Vorgang abwarten"; return }
        let name = policy.filename()
        do {
            try await validate(bytes)
            status = "Externes Backup wird geschrieben und zurückgelesen …"
            if policy.target == .folder { try await writeFolder(bytes, name: name) }
            else { try await writeWebDAV(bytes, name: name) }
            policy.lastSuccess = Date(); persist()
            status = policy.target == .folder
                ? "Zieldatei geprüft · Cloud-Upload übernimmt die Dateien-App"
                : "WebDAV-Sicherung vollständig zurückgelesen und geprüft"
            do { try await reloadHistory(); try await prune(verified: name) }
            catch { status += " · ältere Stände nicht bereinigt" }
        } catch {
            // Never display a URLSession error that might include a credential-bearing endpoint.
            if case .folderUnreachable? = error as? BackupTargetError { status = Self.folderUnreachableText }
            else { status = "Externes Backup fehlgeschlagen · ältere Sicherungen bleiben erhalten" }
            self.error = (error as? BackupTargetError)?.localizedDescription ?? "Ziel nicht erreichbar, nicht beschreibbar oder Sicherung unvollständig. Bitte erneut versuchen."
        }
    }
    private func validate(_ bytes: Data) async throws {
        try await Task.detached(priority: .utility) { _ = try LibraryArchive.decode(bytes) }.value
    }
    private func folder() throws -> URL {
        guard let data = policy.folderBookmark else { throw BackupTargetError.missing }
        var stale = false
        let url: URL
        do { url = try URL(resolvingBookmarkData: data, options: .withoutUI, relativeTo: nil, bookmarkDataIsStale: &stale) }
        catch {
            // Keep the configured target and bookmark; the user re-chooses explicitly.
            folderUnreachable = true; status = Self.folderUnreachableText
            throw BackupTargetError.folderUnreachable
        }
        if folderUnreachable { folderUnreachable = false }
        // A stale bookmark still resolves to a usable URL; Apple requires re-creating it.
        if stale { renewBookmark(url) }
        else if policy.folderName == nil { policy.folderName = url.lastPathComponent; persist() }
        return url
    }
    private func renewBookmark(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        // On failure the old bookmark stays stored; this resolution is still usable now.
        guard let fresh = try? url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil),
              !fresh.isEmpty else { return }
        policy.folderBookmark = fresh
        if policy.folderName == nil { policy.folderName = url.lastPathComponent }
        persist()
    }
    private func writeFolder(_ bytes: Data, name: String) async throws {
        let folder = try folder(), access = folder.startAccessingSecurityScopedResource()
        defer { if access { folder.stopAccessingSecurityScopedResource() } }
        let policy = policy
        try await Task.detached(priority: .utility) {
            let coordinator = NSFileCoordinator()
            var coordinationError: NSError?, writeError: Error?
            coordinator.coordinate(writingItemAt: folder, options: [], error: &coordinationError) { coordinated in
                do { try ExternalBackupFolder.write(bytes, name: name, policy: policy, directory: coordinated) }
                catch { writeError = error }
            }
            if let coordinationError { throw coordinationError }
            if let writeError { throw writeError }
        }.value
    }

    private func request(_ method: String, name: String? = nil) throws -> URLRequest {
        let base = try ExternalBackupPolicy.webDAVDirectory(policy.endpoint)
        let url = name.map { base.appendingPathComponent($0) } ?? base
        var request = URLRequest(url: url); request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let credentials = try BackupKeychain.credentials(credentialAccount)
        request.setValue("Basic " + Data("\(credentials.username):\(credentials.password)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        return request
    }
    private func check(_ response: URLResponse, allowed: Set<Int>) throws {
        guard let response = response as? HTTPURLResponse else { throw BackupTargetError.invalidResponse }
        guard allowed.contains(response.statusCode) else { throw BackupTargetError.http(response.statusCode) }
    }
    private func writeWebDAV(_ bytes: Data, name: String) async throws {
        let temporary = name + ".partial"
        var put = try request("PUT", name: temporary)
        put.setValue("*", forHTTPHeaderField: "If-None-Match"); put.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let (_, uploaded) = try await session.upload(for: put, from: bytes); try check(uploaded, allowed: [201])
        // Failed uploads remain clearly partial and are never counted as a backup.
        let partial = try await download(temporary)
        guard partial == bytes else { throw BackupTargetError.verification }; try await validate(partial)
        var move = try request("MOVE", name: temporary)
        move.setValue(try request("GET", name: name).url!.absoluteString, forHTTPHeaderField: "Destination")
        move.setValue("F", forHTTPHeaderField: "Overwrite")
        let (_, moved) = try await session.data(for: move); try check(moved, allowed: [201])
        guard try await download(name) == bytes else { throw BackupTargetError.verification }
    }
    private func download(_ name: String) async throws -> Data {
        guard policy.timestamp(name.replacingOccurrences(of: ".partial", with: "")) != nil else { throw BackupTargetError.verification }
        let (url, response) = try await session.download(for: request("GET", name: name))
        defer { try? FileManager.default.removeItem(at: url) }
        try check(response, allowed: [200])
        return try await Task.detached(priority: .utility) { try Self.read(url) }.value
    }
    func reloadHistory() async throws {
        let names: [String]
        if policy.target == .folder {
            let url = try folder(), access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            names = try await Task.detached(priority: .utility) { try FileManager.default.contentsOfDirectory(atPath: url.path) }.value
        } else if policy.target == .webDAV {
            var request = try request("PROPFIND"); request.setValue("1", forHTTPHeaderField: "Depth")
            request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data("<?xml version=\"1.0\"?><d:propfind xmlns:d=\"DAV:\"><d:prop><d:resourcetype/></d:prop></d:propfind>".utf8)
            let (url, response) = try await session.download(for: request)
            defer { try? FileManager.default.removeItem(at: url) }
            try check(response, allowed: [207])
            let bytes = try Self.read(url, limit: 2_000_000)
            names = try BackupDAVListing.names(bytes, directory: request.url!)
        } else { names = [] }
        history = Array(Set(names).filter { policy.timestamp($0) != nil }.sorted { policy.timestamp($0)! > policy.timestamp($1)! })
    }
    private func prune(verified: String) async throws {
        if policy.target == .folder {
            let directory = try folder(), access = directory.startAccessingSecurityScopedResource(), policy = policy
            defer { if access { directory.stopAccessingSecurityScopedResource() } }
            let removed = try await Task.detached(priority: .utility) {
                try ExternalBackupFolder.prune(policy: policy, directory: directory, verified: verified)
            }.value
            history.removeAll { removed.contains($0) }
        } else {
            // Only after the newest full archive has been read and validated above.
            for name in policy.obsolete(history, verified: verified) {
                let (_, response) = try await session.data(for: request("DELETE", name: name)); try check(response, allowed: [200, 204, 404])
                history.removeAll { $0 == name }
            }
        }
    }
    func retrieve(_ name: String) async -> Data? {
        guard !busy, history.contains(name), policy.timestamp(name) != nil else { return nil }
        busy = true; defer { busy = false }
        do {
            let bytes: Data
            if policy.target == .folder {
                let directory = try folder(), access = directory.startAccessingSecurityScopedResource()
                defer { if access { directory.stopAccessingSecurityScopedResource() } }
                bytes = try await Task.detached(priority: .utility) { try Self.read(directory.appendingPathComponent(name)) }.value
            } else { bytes = try await download(name) }
            try await validate(bytes); return bytes
        } catch { self.error = "Dieser Sicherungsstand konnte nicht vollständig gelesen und geprüft werden."; return nil }
    }
    nonisolated private static func read(_ url: URL, limit: Int = LibraryArchive.maximumBytes) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var data = Data()
        while let chunk = try handle.read(upToCount: 64_000), !chunk.isEmpty {
            guard chunk.count <= limit - data.count else { throw BackupTargetError.verification }; data.append(chunk)
        }
        return data
    }
}

