import SwiftUI
import PDFKit
import NotebookCore

private final class AISessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    /// The session key goes to the entered address only: no redirect is followed.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}

private struct AIServerError: LocalizedError {
    let status: Int
    let message: String
    let code: String?
    var errorDescription: String? { message }
}

/// HTTP to the bridge, off the main actor. Never sees anything but the
/// address it is given; a request without valid address does not leave.
private struct AIBridgeClient: Sendable {
    let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false
        config.urlCache = nil; config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 180
        session = URLSession(configuration: config, delegate: AISessionDelegate(), delegateQueue: nil)
    }

    func send(base: URL, token: String, path: String, query: [URLQueryItem] = [], method: String = "GET", body: Data? = nil) async throws -> (Data, Int) {
        guard let address = AIServerAddress.parse(base.absoluteString),
              var components = URLComponents(url: address, resolvingAgainstBaseURL: false) else {
            throw AIServerError(status: 0, message: "Die Server-Adresse ist ungültig.", code: nil)
        }
        components.path = path
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url else { throw AIServerError(status: 0, message: "Die Server-Adresse ist ungültig.", code: nil) }
        var request = URLRequest(url: url)
        request.httpMethod = method; request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(response.statusCode) else {
            let reply = try? JSONDecoder().decode(AIErrorReply.self, from: data)
            let fallback = response.statusCode >= 500 ? "Der KI-Server antwortet nicht (\(response.statusCode))." : "Der KI-Server hat die Anfrage abgelehnt (\(response.statusCode))."
            throw AIServerError(status: response.statusCode, message: reply?.error ?? fallback, code: reply?.code)
        }
        return (data, response.statusCode)
    }

    func json<T: Decodable & Sendable>(_ type: T.Type, base: URL, token: String, path: String, query: [URLQueryItem] = [],
                                       method: String = "GET", body: Data? = nil) async throws -> T {
        let (data, _) = try await send(base: base, token: token, path: path, query: query, method: method, body: body)
        return try JSONDecoder().decode(type, from: data)
    }

    /// nil: nothing new since `after` (204).
    func session(_ id: String, after revision: Int?, base: URL, token: String) async throws -> AISession? {
        let query = revision.map { [URLQueryItem(name: "after", value: String($0))] } ?? []
        let (data, status) = try await send(base: base, token: token, path: "/v1/sessions/\(id)", query: query)
        return status == 204 ? nil : try JSONDecoder().decode(AISession.self, from: data)
    }

    /// Async: a request with a page image is encoded off the main actor.
    func encoded<T: Encodable & Sendable>(_ value: T) async throws -> Data { try JSONEncoder().encode(value) }
}

/// What goes with a question besides its text.
struct AIAttachment: Sendable {
    var context: AITurnContext?
    var images: [AITurnImage] = []
}

enum AIContextChoice: String, CaseIterable, Identifiable, Sendable {
    case none, page, notebook
    var id: String { rawValue }
    var title: String {
        switch self { case .none: "Keiner"; case .page: "Diese Seite"; case .notebook: "Ganzes Heft" }
    }
}

/// App-wide, outside the per-notebook writers; it reads snapshots and never
/// touches a notebook. The bearer is read from the noty account for every
/// request (`LawLibraryModel.user?.token`) and kept nowhere here.
@MainActor
final class AIAssistantModel: ObservableObject {
    static let serverKey = "noty.ai.serverURL"
    static let approvalsKey = "noty.ai.approvedDocuments"
    /// Display state only, like the law window.
    static let panelOpenKey = "noty.ai.panelOpen"

    @Published private(set) var server = UserDefaults.standard.string(forKey: AIAssistantModel.serverKey).flatMap(AIServerAddress.parse)
    @Published private(set) var me: AIMe?
    @Published private(set) var info: AIInfo?
    @Published private(set) var usage: AIUsage?
    @Published private(set) var rejection: AIAccessRejection?
    /// Why the status could not be read (server unreachable and the like).
    @Published private(set) var statusError: String?
    @Published private(set) var checking = false
    /// Changes when the account or address changes: the panel loads anew.
    @Published private(set) var accountEpoch = 0
    @Published private(set) var sessions: [AISessionSummary] = []
    @Published private(set) var session: AISession?
    @Published private(set) var sending = false
    @Published private(set) var stopping = false
    /// Polling gave up: the run may go on, only the connection is gone.
    @Published private(set) var stalled = false
    @Published private(set) var limitReached = false
    @Published var error: String?
    @Published private(set) var approvals = Set(UserDefaults.standard.stringArray(forKey: AIAssistantModel.approvalsKey) ?? [])

    private let client = AIBridgeClient()
    private weak var laws: LawLibraryModel?
    private var documentID: UUID?
    /// Open chat per notebook while the app runs, to return to after a pane change.
    private var lastSession: [UUID: String] = [:]
    /// Moves on with every change of chat or notebook: whatever was underway
    /// for the old one finds it no longer current and writes nothing.
    private var generation = 0
    private var accountGeneration = 0
    private var poll: Task<Void, Never>?
    private var sceneActive = true
    private var panelVisible = false
    private struct PendingTurn { var key: String; var request: AITurnRequest }
    /// Delivered without a clear answer: sending the same again repeats its
    /// `requestId`, so a lost reply cannot start a second run.
    private var pending: PendingTurn?

    var enabled: Bool { UserDefaults.standard.bool(forKey: AppSettingsKey.aiEnabled) }
    var serverAddress: String { server?.absoluteString ?? "" }
    var accountName: String? { laws.flatMap { $0.user?.email ?? $0.user?.name } }
    var signedIn: Bool { laws?.user?.token?.isEmpty == false }
    var access: AIAccess {
        .resolve(hasServer: server != nil, signedIn: signedIn, sessionExpired: laws?.sessionExpired ?? false, me: me, rejection: rejection)
    }
    var limits: AILimits { info?.limits ?? .contract }
    /// Turns of today and what this account may use.
    var dailyUse: (used: Int, limit: Int)? {
        guard let limit = me?.dailyLimit ?? info?.limits.dailyTurns else { return nil }
        return (me?.today.turns ?? info?.limits.usedToday ?? 0, limit)
    }
    /// Address and key together, or nothing: no key without its address.
    private var route: (base: URL, token: String)? {
        guard enabled, laws?.sessionExpired == false, let server, let token = laws?.user?.token, !token.isEmpty else { return nil }
        return (server, token)
    }

    // MARK: Account

    /// Login, logout or an expired session: nothing of the former account stays.
    func accountChanged(_ laws: LawLibraryModel) {
        self.laws = laws
        resetAccount()
    }
    private func resetAccount() {
        accountGeneration += 1; accountEpoch += 1
        invalidate()
        me = nil; info = nil; usage = nil; rejection = nil; statusError = nil; error = nil; checking = false
        session = nil; sessions = []; lastSession = [:]; limitReached = false
    }

    /// Returns false for an address that is not plain `https://host[:port]`.
    func setServer(_ input: String) -> Bool {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.isEmpty || AIServerAddress.parse(text) != nil else { return false }
        let address = AIServerAddress.parse(text)
        guard address != server else { return true }
        server = address
        if let address { UserDefaults.standard.set(address.absoluteString, forKey: Self.serverKey) }
        else { UserDefaults.standard.removeObject(forKey: Self.serverKey) }
        resetAccount()
        return true
    }

    func settingsChanged() {
        guard !enabled else { return }
        invalidate(); session = nil; sessions = []; documentID = nil; error = nil
    }

    /// `/v1/me` answers in every state; the rest only for active accounts.
    func refreshStatus() async {
        guard let route else { return }
        let expected = accountGeneration
        checking = true
        defer { if accountGeneration == expected { checking = false } }
        do {
            let me = try await client.json(AIMe.self, base: route.base, token: route.token, path: "/v1/me")
            guard accountGeneration == expected else { return }
            self.me = me; rejection = nil; statusError = nil
            guard me.status == .active else { info = nil; usage = nil; return }
            let info = try await client.json(AIInfo.self, base: route.base, token: route.token, path: "/v1/info")
            guard accountGeneration == expected else { return }
            self.info = info
            // Its own request: a missing plan display does not stop anything.
            let usage = try? await client.json(AIUsage.self, base: route.base, token: route.token, path: "/v1/usage")
            guard accountGeneration == expected else { return }
            if let usage { self.usage = usage }
        } catch {
            guard accountGeneration == expected else { return }
            if !note(rejection: error) { statusError = describe(error) }
        }
    }

    /// True if the error says something about this account.
    @discardableResult
    private func note(rejection error: Error) -> Bool {
        guard let error = error as? AIServerError, let rejected = AIAccessRejection(status: error.status, code: error.code) else { return false }
        rejection = rejected
        if rejected != .unauthorized { me?.status = rejected == .blocked ? .blocked : .pending }
        return true
    }

    private func describe(_ error: Error) -> String {
        if let error = error as? AIServerError { return error.message }
        if error is DecodingError { return "Der KI-Server hat unerwartet geantwortet." }
        if let error = error as? URLError {
            switch error.code {
            case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .timedOut, .dataNotAllowed, .internationalRoamingOff:
                return "KI-Server nicht erreichbar. Bitte prüfen, ob Tailscale auf diesem iPad aktiv ist."
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid:
                return "Keine sichere Verbindung zum KI-Server. Bitte Tailscale und die Server-Adresse prüfen."
            default: break
            }
        }
        return "Der KI-Server konnte nicht erreicht werden."
    }

    // MARK: Consent per notebook

    func isApproved(_ document: UUID) -> Bool { approvals.contains(document.uuidString) }
    func approve(_ document: UUID) { approvals.insert(document.uuidString); storeApprovals() }
    func resetApprovals() { approvals = []; storeApprovals() }
    private func storeApprovals() { UserDefaults.standard.set(approvals.sorted(), forKey: Self.approvalsKey) }

    // MARK: Chats

    /// The active notebook of the panel; a change leaves the former chat behind.
    func show(document: UUID) {
        guard document != documentID else { return }
        if let documentID, let session { lastSession[documentID] = session.id }
        invalidate()
        documentID = document; session = nil; sessions = []; error = nil; limitReached = false
    }

    private func invalidate() {
        generation += 1
        poll?.cancel(); poll = nil
        pending = nil; sending = false; stopping = false; stalled = false
    }

    func loadSessions(resume: Bool = false) async {
        guard let route, access.canSend, let document = documentID else { return }
        let expected = generation
        do {
            let list = try await client.json([AISessionSummary].self, base: route.base, token: route.token, path: "/v1/sessions",
                                             query: [URLQueryItem(name: "documentId", value: document.uuidString)])
            guard generation == expected else { return }
            sessions = list
            guard resume, session == nil else { return }
            // A run under way continues; otherwise the chat left in this notebook.
            let target = list.first { $0.status == .running }?.id ?? lastSession[document].flatMap { id in list.contains { $0.id == id } ? id : nil }
            if let target { await select(target) }
        } catch {
            guard generation == expected else { return }
            if !note(rejection: error) { self.error = describe(error) }
        }
    }

    func select(_ id: String) async {
        guard let route, let document = documentID else { return }
        invalidate()
        let expected = generation
        error = nil
        do {
            guard let next = try await client.session(id, after: nil, base: route.base, token: route.token) else { return }
            guard generation == expected, next.belongs(to: document) else { return }
            session = next; startPolling()
        } catch {
            guard generation == expected else { return }
            if !note(rejection: error) { self.error = describe(error) }
        }
    }

    func newChat() {
        if let documentID { lastSession[documentID] = nil }
        invalidate(); session = nil; error = nil; limitReached = false
    }

    func delete(_ id: String) async {
        guard let route else { return }
        do {
            _ = try await client.send(base: route.base, token: route.token, path: "/v1/sessions/\(id)", method: "DELETE")
            if session?.id == id { newChat() }
            sessions.removeAll { $0.id == id }
        } catch { if !note(rejection: error) { self.error = describe(error) } }
    }

    /// `key` names question and context: the same again repeats a delivery
    /// that got no clear answer. True once the server took the question.
    func send(question: String, document: UUID, key: String, prepare: @escaping @MainActor () async throws -> AIAttachment) async -> Bool {
        guard !sending, session?.status != .running, document == documentID else { return false }
        // Nothing is prepared or uploaded for a server that has not answered yet.
        if me == nil { await refreshStatus() }
        guard document == documentID, route != nil, access.canSend, !sending else { return false }
        guard me != nil else { error = statusError ?? "Der KI-Server konnte nicht erreicht werden."; return false }
        sending = true; error = nil; limitReached = false; stalled = false
        let expected = generation
        defer { if generation == expected { sending = false } }
        var turn = pending
        if turn?.key != key {
            do {
                let attachment = try await prepare()
                guard generation == expected else { return false }
                turn = PendingTurn(key: key, request: AITurnRequest(text: question, context: attachment.context,
                                                                    images: attachment.images.isEmpty ? nil : attachment.images))
            } catch {
                if generation == expected { self.error = error.localizedDescription }
                return false
            }
        }
        guard let turn else { return false }
        if let problem = turn.request.violation(of: limits) { error = problem; return false }
        pending = turn
        return await deliver(turn, document: document, expected: expected)
    }

    private func deliver(_ turn: PendingTurn, document: UUID, expected: Int) async -> Bool {
        guard let route else { return false }
        do {
            var target = session?.id
            if target == nil {
                // Without title: the server names a new chat after its first question.
                struct NewSession: Encodable, Sendable { let documentId: String }
                let body = try await client.encoded(NewSession(documentId: document.uuidString))
                let created = try await client.json(AISession.self, base: route.base, token: route.token, path: "/v1/sessions", method: "POST", body: body)
                guard generation == expected else { return false }
                session = created; target = created.id
            }
            let body = try await client.encoded(turn.request)
            let updated = try await client.json(AISession.self, base: route.base, token: route.token, path: "/v1/sessions/\(target ?? "")/turns", method: "POST", body: body)
            guard generation == expected else { return false }
            session = updated; pending = nil; stopping = false
            startPolling()
            return true
        } catch {
            guard generation == expected else { return false }
            // Only an unclear outcome keeps the turn for its repeat.
            if let server = error as? AIServerError, server.status < 500 { pending = nil }
            if !note(rejection: error) { self.error = describe(error) }
            if let server = error as? AIServerError {
                if server.status == 429 { limitReached = true; await refreshStatus() }
                if server.status == 409 { await refreshSession() }
            }
            return false
        }
    }

    func stop() async {
        guard let route, let id = session?.id, session?.status == .running, !stopping else { return }
        stopping = true
        let expected = generation
        do {
            _ = try await client.send(base: route.base, token: route.token, path: "/v1/sessions/\(id)/cancel", method: "POST")
        } catch {
            guard generation == expected else { return }
            stopping = false
            if !note(rejection: error) { self.error = describe(error) }
        }
    }

    // MARK: Polling

    func setSceneActive(_ active: Bool) { sceneActive = active; syncPolling() }
    func panelAppeared() { panelVisible = true; syncPolling() }
    func panelDisappeared() { panelVisible = false; syncPolling() }

    private func syncPolling() {
        guard sceneActive, panelVisible else { poll?.cancel(); poll = nil; return }
        if poll == nil, session != nil { Task { await refreshSession() } }
    }

    /// Picks up the chat again, also after polling gave up.
    func refreshSession() async {
        guard let route, let current = session else { return }
        let expected = generation
        stalled = false
        do {
            let next = try await client.session(current.id, after: current.revision, base: route.base, token: route.token)
            guard generation == expected, session?.id == current.id else { return }
            if let next { session = next }
            startPolling()
            // Ended while nobody was asking.
            if current.status == .running, session?.status != .running { await runEnded() }
        } catch {
            guard generation == expected else { return }
            if !note(rejection: error) { self.error = describe(error); stalled = true }
        }
    }

    private func startPolling() {
        poll?.cancel(); poll = nil
        guard sceneActive, panelVisible, let route, let id = session?.id, session?.status == .running else { return }
        let expected = generation
        poll = Task { [weak self, client] in
            var failures = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(min(5_000, 700 << failures)))
                guard !Task.isCancelled, let revision = self?.session?.revision, self?.generation == expected, self?.session?.id == id else { return }
                do {
                    let next = try await client.session(id, after: revision, base: route.base, token: route.token)
                    guard !Task.isCancelled, let self, self.generation == expected else { return }
                    failures = 0
                    if let next { self.session = next }
                    if self.session?.status != .running { self.poll = nil; await self.runEnded(); return }
                } catch {
                    guard !Task.isCancelled, let self, self.generation == expected else { return }
                    failures += 1
                    if self.note(rejection: error) { self.poll = nil; return }
                    let missing = (error as? AIServerError)?.status == 404
                    if failures >= 6 || missing {
                        self.poll = nil; self.stalled = !missing; self.error = self.describe(error)
                        return
                    }
                }
            }
        }
    }

    private func runEnded() async {
        stopping = false
        await refreshStatus()
        await loadSessions()
    }
}

/// Snapshots of an open notebook for one question. Recognition is never
/// started here: what the search index does not know is reported instead.
@MainActor
enum AIContextCollector {
    /// `pageID` nil: the whole notebook. PDF text missing from the index comes
    /// from the PDF itself; PDFKit stays on the main actor with a pause per page.
    static func context(_ editor: EditorModel, notebook: Notebook, pageID: UUID?, area: String, limit: Int) async throws -> AIContext {
        let store = ContentSearchIndexLocation.store(area: area)
        let index = await store.load(notebook.id)
        var pages = await Task.detached(priority: .userInitiated) {
            AIContextBuilder.pages(of: notebook, index: index, only: pageID, drawingIsEmpty: EditorModel.drawingIsEmpty)
        }.value
        try Task.checkCancellation()
        for offset in pages.indices where pages[offset].missing.contains(.pdfText) {
            guard let source = editor.sourcePage(for: notebook.pages[pages[offset].number - 1]) else { continue }
            pages[offset].fillPDFText(source.string ?? "")
            try await Task.sleep(for: .milliseconds(10))
        }
        let finished = pages
        return await Task.detached(priority: .userInitiated) { AIContextBuilder.build(finished, limit: limit) }.value
    }

    /// Every layer of the page through the thumbnail renderer, JPEG off the main actor.
    static func image(_ editor: EditorModel, page: Page, label: String, limit: Int) async throws -> AITurnImage {
        let source = editor.sourcePage(for: page)
        let rendered = try await PageThumbnailCache.render(page, source: source?.pageRef.map { .page($0) } ?? .none,
                                                           longestSide: 1600, assets: editor.imageAssets)
        withExtendedLifetime(source?.document) {}
        let limit = min(limit, AILimits.contract.maxImageBytes - 1)
        let encoded = await Task.detached(priority: .userInitiated) { () -> String? in
            for quality in [0.8, 0.65, 0.5, 0.35] as [CGFloat] {
                if let data = rendered.jpegData(compressionQuality: quality), data.count <= limit { return data.base64EncodedString() }
            }
            return nil
        }.value
        guard let encoded else { throw AISendError.imageTooLarge }
        return AITurnImage(mimeType: "image/jpeg", base64: encoded, label: label)
    }
}

enum AISendError: LocalizedError {
    case imageTooLarge
    var errorDescription: String? { "Das Seitenbild ließ sich nicht klein genug speichern." }
}
