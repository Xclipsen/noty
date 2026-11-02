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
    /// Page numbers the answer may cite, by stable ID.
    var pages: [Int: UUID] = [:]
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
    /// Local bookkeeping of the panel, not part of any notebook or backup.
    static let citationsKey = "noty.ai.citationPages"
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
    @Published private(set) var approvals = AIApproval.valid(UserDefaults.standard.stringArray(forKey: AIAssistantModel.approvalsKey) ?? [])
    @Published private(set) var citations = UserDefaults.standard.data(forKey: AIAssistantModel.citationsKey)
        .flatMap { try? JSONDecoder().decode(AICitationLedger.self, from: $0) } ?? AICitationLedger()

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
    private var panelPresence = AIPanelPresence()
    /// Delivered without a clear answer: sending the same content again repeats
    /// its `requestId`, so a lost reply cannot start a second run.
    private var pending: AIPendingDelivery?
    /// Set by a failed list or chat request, gone with the next one that works.
    private var loadError: String?

    var enabled: Bool { UserDefaults.standard.bool(forKey: AppSettingsKey.aiEnabled) }
    var serverAddress: String { server?.absoluteString ?? "" }
    var serverHost: String? { server.map(AIServerAddress.authority) }
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
        session = nil; sessions = []; lastSession = [:]; limitReached = false; loadError = nil
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
            guard accountGeneration == expected, !AIRequestFailure.isCancellation(error) else { return }
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

    /// nil while no server or no account is set: nothing can be approved then.
    func approvalKey(for document: UUID) -> String? {
        guard let server, let account = laws?.user?.id else { return nil }
        return AIApproval.key(server: server, account: account, document: document)
    }
    func isApproved(_ document: UUID) -> Bool { approvalKey(for: document).map(approvals.contains) ?? false }
    /// The key of the moment the dialog was shown: it named that server.
    func approve(key: String) { approvals.insert(key); storeApprovals() }
    func resetApprovals() { approvals = []; storeApprovals() }
    private func storeApprovals() { UserDefaults.standard.set(approvals.sorted(), forKey: Self.approvalsKey) }

    // MARK: Citations

    /// Pages noted for the question of `requestID`; empty leaves its citations as text.
    func citationPages(requestID: String, document: UUID) -> [Int: UUID] {
        citations.pages(requestID: requestID, document: document)
    }
    private func noteCitations(requestID: String, document: UUID, pages: [Int: UUID]) {
        citations.record(requestID: requestID, document: document, pages: pages)
        if let data = try? JSONEncoder().encode(citations) { UserDefaults.standard.set(data, forKey: Self.citationsKey) }
    }

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
            clearLoadError()
            // A question on its way is a newer wish than picking up an old chat.
            guard resume, session == nil, !sending else { return }
            // A run under way continues; otherwise the chat left in this notebook.
            let target = list.first { $0.status == .running }?.id ?? lastSession[document].flatMap { id in list.contains { $0.id == id } ? id : nil }
            if let target { await select(target) }
        } catch {
            guard generation == expected else { return }
            reportLoad(error)
        }
    }

    private func report(_ error: Error) {
        guard !AIRequestFailure.isCancellation(error), !note(rejection: error) else { return }
        self.error = describe(error)
    }
    private func reportLoad(_ error: Error) {
        guard !AIRequestFailure.isCancellation(error), !note(rejection: error) else { return }
        let message = describe(error)
        self.error = message; loadError = message
    }
    private func clearLoadError() {
        if let loadError, error == loadError { error = nil }
        loadError = nil
    }

    func select(_ id: String) async {
        guard let route, let document = documentID else { return }
        invalidate()
        let expected = generation
        error = nil
        do {
            let next = try await client.session(id, after: nil, base: route.base, token: route.token)
            guard generation == expected, !sending else { return }
            guard let next, next.belongs(to: document) else { watchShownRun(); return }
            session = next; clearLoadError(); startPolling()
        } catch {
            guard generation == expected, !sending else { return }
            reportLoad(error)
            watchShownRun()
        }
    }

    /// A failed change of chat leaves the former one on screen: if it runs, it
    /// is followed further or at least offered for checking again.
    private func watchShownRun() {
        guard session?.status == .running else { return }
        startPolling()
        stalled = poll == nil
    }

    func newChat() {
        if let documentID { lastSession[documentID] = nil }
        invalidate(); session = nil; error = nil; limitReached = false
    }

    func delete(_ id: String) async {
        guard let route else { return }
        let expected = accountGeneration
        do {
            _ = try await client.send(base: route.base, token: route.token, path: "/v1/sessions/\(id)", method: "DELETE")
            guard accountGeneration == expected else { return }
            if session?.id == id { newChat() }
            sessions.removeAll { $0.id == id }
        } catch {
            guard accountGeneration == expected else { return }
            report(error)
        }
    }

    /// `prepare` runs for every attempt: what goes out is always today's
    /// content. A repeat with the same content keeps its `requestId`, changed
    /// content is a new question. True once the server took the question.
    func send(question: String, document: UUID, prepare: @escaping @MainActor () async throws -> AIAttachment) async -> Bool {
        guard !sending, session?.status != .running, document == documentID else { return false }
        sending = true
        // From here on any change of account, server, notebook or chat ends this question.
        let expected = generation
        defer { if generation == expected { sending = false } }
        // Nothing is prepared or uploaded for a server that has not answered yet.
        if me == nil { await refreshStatus() }
        guard generation == expected, route != nil, access.canSend else { return false }
        guard me != nil else { error = statusError ?? "Der KI-Server konnte nicht erreicht werden."; return false }
        error = nil; limitReached = false; stalled = false
        let attachment: AIAttachment
        do {
            attachment = try await prepare()
        } catch {
            if generation == expected, !AIRequestFailure.isCancellation(error) { self.error = error.localizedDescription }
            return false
        }
        guard generation == expected else { return false }
        var request = AITurnRequest(text: question, context: attachment.context, images: attachment.images.isEmpty ? nil : attachment.images)
        if let problem = request.violation(of: limits) { error = problem; return false }
        let content = request
        let fingerprint = await Task.detached(priority: .userInitiated) { content.contentFingerprint }.value
        guard generation == expected else { return false }
        let delivery = AIPendingDelivery.resolve(fingerprint: fingerprint, previous: pending)
        request.requestId = delivery.requestID
        pending = delivery
        noteCitations(requestID: delivery.requestID, document: document, pages: attachment.pages)
        return await deliver(request, document: document, expected: expected)
    }

    private func deliver(_ request: AITurnRequest, document: UUID, expected: Int) async -> Bool {
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
            let body = try await client.encoded(request)
            let updated = try await client.json(AISession.self, base: route.base, token: route.token, path: "/v1/sessions/\(target ?? "")/turns", method: "POST", body: body)
            guard generation == expected else { return false }
            session = updated; pending = nil; stopping = false
            startPolling()
            return true
        } catch {
            guard generation == expected else { return false }
            // Only an unclear outcome keeps the turn for its repeat.
            if let server = error as? AIServerError, server.status < 500 { pending = nil }
            report(error)
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
            report(error)
        }
    }

    // MARK: Polling

    func setSceneActive(_ active: Bool) { sceneActive = active; syncPolling() }
    func panelAppeared() { panelPresence.appeared(); syncPolling() }
    func panelDisappeared() { panelPresence.disappeared(); syncPolling() }

    private func syncPolling() {
        guard sceneActive, panelPresence.visible else { poll?.cancel(); poll = nil; return }
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
            if let next, next.supersedes(session) { session = next }
            startPolling()
            // Ended while nobody was asking.
            if current.status == .running, session?.status != .running { await runEnded() }
        } catch {
            guard generation == expected, !AIRequestFailure.isCancellation(error) else { return }
            if !note(rejection: error) { self.error = describe(error); stalled = true }
        }
    }

    private func startPolling() {
        poll?.cancel(); poll = nil
        guard sceneActive, panelPresence.visible, let route, let id = session?.id, session?.status == .running else { return }
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
                    if let next, next.supersedes(self.session) { self.session = next }
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
    private static var pdfTexts = AIPDFTextCache()

    /// Off the main actor; cancelling the caller also cancels this work.
    private static func detached<T: Sendable>(_ priority: TaskPriority, _ work: @escaping @Sendable () -> T) async -> T {
        let task = Task.detached(priority: priority, operation: work)
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    /// `pageID` nil: the whole notebook. PDF text missing from the index comes
    /// from the PDF itself, read once per page and source and not past `limit`;
    /// PDFKit stays on the main actor with a pause per page.
    static func context(_ editor: EditorModel, notebook: Notebook, pageID: UUID?, area: String, limit: Int,
                        priority: TaskPriority) async throws -> AIContext {
        let index = await ContentSearchIndexLocation.store(area: area).loadRemembered(notebook.id)
        var pages = await detached(priority) {
            AIContextBuilder.pages(of: notebook, index: index, only: pageID, drawingIsEmpty: EditorModel.drawingIsEmpty)
        }
        try Task.checkCancellation()
        if pages.contains(where: { $0.missing.contains(.pdfText) }) {
            var budget = AIContextBudget(limit: limit)
            for offset in pages.indices {
                if pages[offset].missing.contains(.pdfText) {
                    if budget.exhausted { pages[offset].skipAtLimit(); continue }
                    try await readPDFText(&pages[offset], editor, notebook: notebook)
                }
                budget.add(pages[offset])
            }
        }
        let finished = pages
        return await detached(priority) { AIContextBuilder.build(finished, limit: limit) }
    }

    private static func readPDFText(_ target: inout AIContextPage, _ editor: EditorModel, notebook: Notebook) async throws {
        let page = notebook.pages[target.number - 1]
        let key = AIPDFTextCache.key(page: page, document: notebook.id)
        if let known = pdfTexts.text(for: key) { target.fillPDFText(known); return }
        guard let source = editor.sourcePage(for: page) else { return }
        let text = source.string ?? ""
        pdfTexts.remember(text, for: key)
        target.fillPDFText(text)
        try await Task.sleep(for: .milliseconds(10))
    }

    /// Every layer of the page through the thumbnail renderer, JPEG off the main actor.
    static func image(_ editor: EditorModel, page: Page, label: String, limit: Int) async throws -> AITurnImage {
        let source = editor.sourcePage(for: page)
        // A PDFPage holds its document weakly, its CGPDFPage needs it alive.
        let document = source?.document
        defer { withExtendedLifetime(document) {} }
        let rendered = try await PageThumbnailCache.render(page, source: source?.pageRef.map { .page($0) } ?? .none,
                                                           longestSide: 1600, assets: editor.imageAssets)
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
