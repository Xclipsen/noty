import SwiftUI
import Security
import NotebookCore

private enum BackupTargetError: LocalizedError {
    case missing, folderUnreachable, folderNotWritable, invalidResponse, http(Int), credential, credentialsMissing
    var errorDescription: String? {
        switch self {
        case .missing: "Backupziel nicht erreichbar. Ordner erneut wählen bzw. WebDAV-Zugang prüfen."
        case .folderUnreachable: ExternalBackupModel.folderUnreachableText
        case .folderNotWritable: "Der Backup-Ordner ist nicht beschreibbar. Bitte einen anderen Ordner wählen."
        case .invalidResponse: "Backupziel antwortet ungültig oder leitet um. Bitte die endgültige HTTPS-Ordneradresse verwenden."
        case .http(let code): "WebDAV meldet HTTP \(code). Zugang, Ordneradresse und Schreibrechte prüfen."
        case .credential: "WebDAV-Zugang konnte nicht im Schlüsselbund gelesen oder gesichert werden."
        case .credentialsMissing: "Für WebDAV sind keine Zugangsdaten gespeichert. Bitte Benutzername und Passwort eingeben."
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
    static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "noty.external-backup", kSecAttrAccount as String: account]
    }
    static func credentials(_ account: String) throws -> Credentials {
        var result: CFTypeRef?
        let search = query(account).merging([kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]) { _, new in new }
        guard SecItemCopyMatching(search as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, let credentials = try? JSONDecoder().decode(Credentials.self, from: data) else { throw BackupTargetError.credential }
        return credentials
    }
    static func save(_ value: String, username: String, account: String) throws {
        let attributes: [String: Any] = [kSecValueData as String: try JSONEncoder().encode(Credentials(username: username, password: value)),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query(account) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            guard SecItemAdd(query(account).merging(attributes) { _, new in new } as CFDictionary, nil) == errSecSuccess else { throw BackupTargetError.credential }
        } else if status != errSecSuccess { throw BackupTargetError.credential }
    }
    static func delete(_ account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw BackupTargetError.credential }
    }
}

/// A little extra time when the app leaves the foreground mid-backup; always
/// ended in time (an expired, unended assertion would get the app terminated).
@MainActor
private final class BackgroundAssertion {
    private var id = UIBackgroundTaskIdentifier.invalid
    init(_ name: String) {
        id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in MainActor.assumeIsolated { self?.end() } }
    }
    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id); id = .invalid
    }
}

@MainActor
final class ExternalBackupModel: ObservableObject {
    @Published private(set) var policy: ExternalBackupPolicy
    @Published private(set) var status: String
    @Published private(set) var busy = false
    @Published var history: [String] = []
    /// History entries that exist only as not-downloaded iCloud placeholders.
    @Published private(set) var placeholders: Set<String> = []
    /// Only manual actions raise alerts; automatic runs report via status/badge.
    @Published var error: String?
    /// The stored folder bookmark could not be resolved; the target is kept, not forgotten.
    @Published private(set) var folderUnreachable = false
    /// Keychain username, read once (not on every render).
    @Published private(set) var storedUsername: String?
    /// Kept current by the host from scenePhase; the long-running loop reads it here.
    var sceneActive = false
    nonisolated static let folderUnreachableText = "Backup-Ordner nicht mehr erreichbar – bitte neu wählen"
    private var temporaries: [String] = []
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
            status = Self.summary(value)
        } else { policy = ExternalBackupPolicy(); status = saved == nil ? "Externes Backup nicht eingerichtet" : "Backupziel unlesbar · bitte neu einrichten" }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60; configuration.timeoutIntervalForResource = 6 * 3600
        configuration.urlCredentialStorage = nil; configuration.httpCookieStorage = nil; configuration.urlCache = nil
        session = URLSession(configuration: configuration, delegate: BackupSessionDelegate(), delegateQueue: nil)
        storedUsername = try? BackupKeychain.credentials(credentialAccount).username
        if policy.target == .folder { Task { [weak self] in self?.checkFolder() } }
    }

    private static func summary(_ policy: ExternalBackupPolicy) -> String {
        switch policy.lastOutcome {
        case .unreachable?, .failed?:
            return "Letzter Versuch fehlgeschlagen: \(policy.lastFailureReason ?? "unbekannt") · ältere Sicherungen bleiben erhalten"
        default:
            return policy.lastSuccess.map { "Zuletzt geprüft: \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "Noch keine externe Sicherung"
        }
    }

    /// Resolves the bookmark early so an unreachable folder is reported instead of silently failing later.
    func checkFolder() {
        guard policy.target == .folder, !busy else { return }
        _ = try? folder()
    }
    var username: String { storedUsername ?? "" }
    var hasStoredCredentials: Bool { storedUsername != nil }
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
            policy.startTarget(.folder); folderUnreachable = false
            try policy.validate(); persist(); history = []; placeholders = []; status = "Ordner gewählt · erste Sicherung steht aus"
        } catch { self.error = "Ordner konnte nicht eingerichtet werden." }
    }
    /// An empty password keeps the stored one (also when only the name changes).
    func useWebDAV(endpoint: String, username: String, password: String) {
        guard !busy else { return }
        do {
            let url = try ExternalBackupPolicy.webDAVDirectory(endpoint)
            let name = username.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !name.contains(":"), !name.contains("\n"), !name.contains("\r") else { throw BackupTargetError.credential }
            let secret: String
            if password.isEmpty {
                guard let stored = try? BackupKeychain.credentials(credentialAccount) else {
                    self.error = "Bitte das Passwort bzw. App-Passwort eingeben."; return
                }
                secret = stored.password
            } else { secret = password }
            // Persist the credential before publishing the new active target.
            try BackupKeychain.save(secret, username: name, account: credentialAccount)
            storedUsername = name
            if policy.target != .webDAV || policy.endpoint != url.absoluteString { policy.startTarget(.webDAV); history = []; placeholders = [] }
            policy.endpoint = url.absoluteString
            try policy.validate(); persist(); status = "WebDAV gespeichert · nächste Sicherung steht aus"
        } catch { self.error = "WebDAV konnte nicht eingerichtet werden. HTTPS-Ordneradresse, Benutzername und Schlüsselbund prüfen." }
    }
    /// Explicit only; switching targets keeps the credential.
    func removeCredentials() {
        guard !busy else { return }
        do { try BackupKeychain.delete(credentialAccount); storedUsername = nil; status = "WebDAV-Zugangsdaten entfernt" }
        catch { self.error = "Zugangsdaten konnten nicht aus dem Schlüsselbund entfernt werden." }
    }

    /// Order: cheap local check → commit editors (paused only for that) →
    /// target reachable? → stream the archive from committed data off the UI actor →
    /// upload/copy and read back → prune. Automatic runs never raise alerts and
    /// follow the backoff in `policy.due()`; "Jetzt sichern" ignores it.
    func attempt(library: LibraryModel, toolbox: ToolbarSettingsModel, manual: Bool = false) async {
        guard !busy, policy.target != .disabled, manual || policy.due() else { return }
        if let reason = library.backupBlocker { postpone(reason, manual: manual); return }
        busy = true; defer { busy = false }
        let background = BackgroundAssertion("noty-external-backup")
        defer { background.end() }
        // A local commit is cheap and happens anyway; while the user writes it
        // fails, so the target is not contacted every minute during input.
        let committed = library.opened != nil
        let flushed: Bool
        if committed { flushed = await library.editorCommit?() ?? false } else { flushed = await toolbox.flush() }
        guard flushed else { postpone("Notizbuch wird bearbeitet oder gespeichert", manual: manual); return }
        status = "Backupziel wird geprüft …"
        let folderURL: URL?
        do { folderURL = try await reachableTarget() }
        catch { fail(Self.isUnreachable(error) ? .unreachable : .failed, error, manual: manual); return }
        status = "Bibliothek wird für externes Backup gesichert …"
        let archive: PreparedLibraryArchive
        do { archive = try await library.buildArchive(editorsCommitted: committed) }
        catch let postponed as BackupPostponed { postpone(postponed.reason, manual: manual); return }
        catch { fail(.failed, error, manual: manual); return }
        defer { BackupScratch.remove(archive.url) }
        let name = policy.filename()
        status = "Externes Backup wird geschrieben und zurückgelesen …"
        do {
            if let folderURL { try await writeFolder(archive, name: name, folder: folderURL) }
            else { try await writeWebDAV(archive, name: name) }
        } catch { fail(Self.isUnreachable(error) ? .unreachable : .failed, error, manual: manual); return }
        policy.recordSuccess(); persist()
        status = policy.target == .folder
            ? "Zieldatei geprüft · Cloud-Upload übernimmt die Dateien-App"
            : "WebDAV-Sicherung vollständig zurückgelesen und geprüft"
        do { try await reloadHistory(); try await prune(verified: name, file: archive.summary.file) }
        catch { status += " · ältere Stände nicht bereinigt" }
    }

    private func postpone(_ reason: String, manual: Bool) {
        // Not a failure: no attempt time, no backoff step; the loop retries shortly.
        status = "Backup verschoben: \(reason)"
        if manual { error = BackupPostponed(reason: reason).localizedDescription }
    }
    private func fail(_ outcome: ExternalBackupOutcome, _ error: Error, manual: Bool) {
        let reason = Self.reason(error)
        policy.recordFailure(outcome, reason: reason); persist()
        let next = policy.nextAttempt.map { " · nächster Versuch \($0.formatted(date: .omitted, time: .shortened))" } ?? ""
        status = (outcome == .unreachable ? "Backupziel nicht erreichbar: " : "Externes Backup fehlgeschlagen: ") + reason + next
        // Never display a URLSession error that might include a credential-bearing endpoint.
        if manual { self.error = Self.detail(error) }
    }
    private static func isUnreachable(_ error: Error) -> Bool {
        if let error = error as? URLError {
            return [.notConnectedToInternet, .timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
                    .dnsLookupFailed, .dataNotAllowed, .internationalRoamingOff, .callIsActive].contains(error.code)
        }
        switch error as? BackupTargetError {
        case .http(let code)?: return code >= 500
        case .folderUnreachable?, .missing?: return true
        default: return false
        }
    }
    /// Short German reason for badge/status; never contains URLs or credentials.
    private static func reason(_ error: Error) -> String {
        switch error {
        case let error as LibraryArchiveError:
            switch error {
            case .archiveTooLarge: return "Bibliothek größer als 4 GB"
            case .notebookTooLarge(let title): return "„\(title.prefix(40))“ größer als 200 MB"
            case .incomplete: return "Ein Notizbuch ist nicht vollständig lesbar"
            case .verificationFailed: return "Zurückgelesene Sicherung weicht ab"
            default: return "Archiv ungültig"
            }
        case let error as BackupTargetError:
            switch error {
            case .folderUnreachable, .missing: return "Backup-Ordner nicht erreichbar"
            case .folderNotWritable: return "Backup-Ordner nicht beschreibbar"
            case .http(let code) where code == 401 || code == 403: return "WebDAV-Zugang abgelehnt (HTTP \(code))"
            case .http(let code): return "WebDAV meldet HTTP \(code)"
            case .invalidResponse: return "Ungültige Antwort oder Umleitung"
            case .credential, .credentialsMissing: return "WebDAV-Zugangsdaten fehlen"
            }
        case is URLError: return isUnreachable(error) ? "Server nicht erreichbar (offline?)" : "Netzwerkfehler"
        case let error as CocoaError where error.code == .fileWriteOutOfSpace: return "Zu wenig freier Speicher auf dem iPad"
        case is StorageError, is RevisionError, is BackupError: return "Inhalt eines Notizbuchs ungültig"
        default: return "Sicherung nicht abgeschlossen"
        }
    }
    private static func detail(_ error: Error) -> String {
        if error is LibraryArchiveError || error is BackupTargetError || error is StorageError || error is RevisionError {
            return error.localizedDescription
        }
        return "Ziel nicht erreichbar, nicht beschreibbar oder Sicherung unvollständig (\(reason(error))). Ältere Sicherungen bleiben erhalten."
    }

    /// Folder: resolvable and writable (returns the URL). WebDAV: authenticated
    /// PROPFIND Depth 0 on the directory (returns nil). Nothing is built before.
    private func reachableTarget() async throws -> URL? {
        if policy.target == .folder {
            let url = try folder()
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let writable = await Task.detached(priority: .utility) {
                (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true && FileManager.default.isWritableFile(atPath: url.path)
            }.value
            guard writable else { throw BackupTargetError.folderNotWritable }
            return url
        }
        guard hasStoredCredentials else { throw BackupTargetError.credentialsMissing }
        var probe = try request("PROPFIND"); probe.setValue("0", forHTTPHeaderField: "Depth")
        probe.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        probe.httpBody = Data("<?xml version=\"1.0\"?><d:propfind xmlns:d=\"DAV:\"><d:prop><d:resourcetype/></d:prop></d:propfind>".utf8)
        let (_, response) = try await session.data(for: probe)
        try check(response, allowed: [207])
        return nil
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
    private func writeFolder(_ archive: PreparedLibraryArchive, name: String, folder: URL) async throws {
        let access = folder.startAccessingSecurityScopedResource()
        defer { if access { folder.stopAccessingSecurityScopedResource() } }
        let policy = policy
        try await Task.detached(priority: .utility) {
            try ExternalBackupFolder.write(archive: archive.url, file: archive.summary.file, name: name, policy: policy,
                                           directory: folder, coordination: CoordinatedBackupFiles())
        }.value
    }

    private func request(_ method: String, name: String? = nil) throws -> URLRequest {
        let base = try ExternalBackupPolicy.webDAVDirectory(policy.endpoint)
        let url = name.map { base.appendingPathComponent($0) } ?? base
        var request = URLRequest(url: url); request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        guard let credentials = try? BackupKeychain.credentials(credentialAccount) else { throw BackupTargetError.credentialsMissing }
        request.setValue("Basic " + Data("\(credentials.username):\(credentials.password)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        return request
    }
    private func check(_ response: URLResponse, allowed: Set<Int>) throws {
        guard let response = response as? HTTPURLResponse else { throw BackupTargetError.invalidResponse }
        guard allowed.contains(response.statusCode) else { throw BackupTargetError.http(response.statusCode) }
    }
    /// PUT the verified local file as `<name>.partial` (streamed from disk), read
    /// it back by size+CRC, MOVE without overwrite, read the final file back.
    /// Own leftovers are deleted best effort; they are never counted as backups.
    private func writeWebDAV(_ archive: PreparedLibraryArchive, name: String) async throws {
        let partial = name + ".partial"
        do {
            var put = try request("PUT", name: partial)
            put.setValue("*", forHTTPHeaderField: "If-None-Match"); put.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            let (_, uploaded) = try await session.upload(for: put, fromFile: archive.url); try check(uploaded, allowed: [201])
            guard try await downloadChecksum(partial) == archive.summary.file else { throw LibraryArchiveError.verificationFailed }
            var move = try request("MOVE", name: partial)
            move.setValue(try request("GET", name: name).url!.absoluteString, forHTTPHeaderField: "Destination")
            move.setValue("F", forHTTPHeaderField: "Overwrite")
            let (_, moved) = try await session.data(for: move); try check(moved, allowed: [201])
        } catch {
            await deleteQuietly(partial)
            throw error
        }
        do { guard try await downloadChecksum(name) == archive.summary.file else { throw LibraryArchiveError.verificationFailed } }
        catch {
            await deleteQuietly(name)
            throw error is URLError ? error : LibraryArchiveError.verificationFailed
        }
    }
    private func deleteQuietly(_ name: String) async {
        guard policy.timestamp(name) != nil || policy.temporaryTimestamp(name) != nil, let delete = try? request("DELETE", name: name) else { return }
        _ = try? await session.data(for: delete)
    }
    private func download(_ name: String) async throws -> URL {
        guard policy.timestamp(name) != nil || policy.temporaryTimestamp(name) != nil else { throw LibraryArchiveError.invalid }
        let (url, response) = try await session.download(for: request("GET", name: name))
        do { try check(response, allowed: [200]) } catch { try? FileManager.default.removeItem(at: url); throw error }
        return url
    }
    private func downloadChecksum(_ name: String) async throws -> LibraryArchiveFileInfo {
        let url = try await download(name)
        defer { try? FileManager.default.removeItem(at: url) }
        return try await Task.detached(priority: .utility) { try BoundedFile.checksum(url) }.value
    }

    func reloadHistory() async throws {
        let listing: ExternalBackupListing
        if policy.target == .folder {
            let url = try folder(), access = url.startAccessingSecurityScopedResource(), policy = policy
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            listing = try await Task.detached(priority: .utility) {
                try ExternalBackupFolder.list(policy: policy, directory: url, coordination: CoordinatedBackupFiles())
            }.value
        } else if policy.target == .webDAV {
            var request = try request("PROPFIND"); request.setValue("1", forHTTPHeaderField: "Depth")
            request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data("<?xml version=\"1.0\"?><d:propfind xmlns:d=\"DAV:\"><d:prop><d:resourcetype/></d:prop></d:propfind>".utf8)
            let (url, response) = try await session.download(for: request)
            defer { try? FileManager.default.removeItem(at: url) }
            try check(response, allowed: [207])
            let names = try BackupDAVListing.names(BoundedFile.read(url, limit: 2_000_000), directory: request.url!)
            var value = ExternalBackupListing()
            value.archives = Set(names).filter { policy.timestamp($0) != nil }.sorted { policy.timestamp($0)! > policy.timestamp($1)! }
            value.temporaries = Set(names).filter { policy.temporaryTimestamp($0) != nil }.sorted()
            listing = value
        } else { listing = ExternalBackupListing() }
        history = listing.archives; placeholders = listing.placeholders; temporaries = listing.temporaries
    }
    private func prune(verified: String, file: LibraryArchiveFileInfo) async throws {
        if policy.target == .folder {
            let directory = try folder(), access = directory.startAccessingSecurityScopedResource(), policy = policy
            defer { if access { directory.stopAccessingSecurityScopedResource() } }
            let removed = try await Task.detached(priority: .utility) {
                try ExternalBackupFolder.prune(policy: policy, directory: directory, verified: verified, file: file, coordination: CoordinatedBackupFiles())
            }.value
            history.removeAll { removed.contains($0) }
        } else {
            // Only after the newest full archive has been read back and checked above.
            for name in policy.obsolete(history, verified: verified) {
                let (_, response) = try await session.data(for: request("DELETE", name: name)); try check(response, allowed: [200, 204, 404])
                history.removeAll { $0 == name }
            }
            for name in policy.staleTemporaries(temporaries) { await deleteQuietly(name) }
        }
    }

    /// Copies one listed archive into a local temporary file (a cloud placeholder
    /// is downloaded by the coordinated read) and verifies it completely.
    func retrieve(_ name: String) async -> PreparedLibraryArchive? {
        guard !busy, history.contains(name), policy.timestamp(name) != nil else { return nil }
        busy = true; defer { busy = false }
        var local: URL?
        do {
            let destination = try BackupScratch.newFile(); local = destination
            if policy.target == .folder {
                let directory = try folder(), access = directory.startAccessingSecurityScopedResource(), policy = policy
                defer { if access { directory.stopAccessingSecurityScopedResource() } }
                _ = try await Task.detached(priority: .utility) {
                    try ExternalBackupFolder.copy(name: name, policy: policy, directory: directory, to: destination, coordination: CoordinatedBackupFiles())
                }.value
            } else {
                let downloaded = try await download(name)
                defer { try? FileManager.default.removeItem(at: downloaded) }
                try FileManager.default.moveItem(at: downloaded, to: destination)
            }
            let summary = try await Task.detached(priority: .utility) { try LibraryArchive.verify(destination) }.value
            return PreparedLibraryArchive(url: destination, summary: summary)
        } catch {
            if let local { BackupScratch.remove(local) }
            self.error = "Dieser Sicherungsstand konnte nicht vollständig gelesen und geprüft werden."
            return nil
        }
    }
}
