import SwiftUI
import UIKit
import NotebookCore

/// A jump from an answer to a page of the active notebook, through the search
/// path of the pane it was asked in.
struct AIPageJump: Equatable {
    let id = UUID()
    let pane: Int
    let pageID: UUID
}

/// One laid-out block of an answer.
struct AIRenderedBlock: Equatable, Identifiable {
    enum Style: Equatable { case body, title, heading, subheading }
    enum Kind: Equatable {
        case text(AttributedString, Style)
        case listItem(indent: Int, marker: String, AttributedString)
        case quote(AttributedString)
        case code(String)
        case rule
    }
    let id: Int
    let kind: Kind
}

/// What the panel keeps between two runs of its body.
@MainActor
private final class AIPanelCache {
    var answers = AIRenderCache<[AIRenderedBlock]>()
    private var known: (changes: Int, document: UUID, pages: Set<UUID>)?

    /// IDs of the notebook's pages, built anew only after a change.
    func pages(of editor: EditorModel) -> Set<UUID> {
        let notebook = editor.notebook
        if let known, known.changes == editor.contentChanges, known.document == notebook.id { return known.pages }
        let pages = Set(notebook.pages.map(\.id))
        known = (editor.contentChanges, notebook.id, pages)
        return pages
    }
}

extension AIAnswerMode {
    var symbol: String {
        switch self { case .fast: "bolt"; case .balanced: "circle.lefthalf.filled"; case .thinking: "lightbulb" }
    }
}

/// Chat beside the notebook. Reads snapshots, writes nothing into a notebook.
/// The open notebook goes along automatically once the user agreed in the
/// settings (docs/AI-ASSISTANT.md); a notebook can be excluded.
struct AIPanelView: View {
    @EnvironmentObject private var ai: AIAssistantModel
    @Environment(\.searchIndexArea) private var searchIndexArea
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var editor: EditorModel
    let docked: Bool
    /// Page in `document`; the workspace checks it is still the active one.
    let onJump: (UUID, UUID) -> Void
    /// Only while floating: the panel changes the side.
    let onSwitchSide: (() -> Void)?
    let onClose: () -> Void

    @AppStorage(AIAssistantModel.modeKey) private var mode: AIAnswerMode = .fast
    @AppStorage(AIAssistantModel.scopeKey) private var scope: AIContextScope = .notebook
    @State private var draft = ""
    @State private var composing = false
    @State private var showingChats = false
    @State private var preview: Preview?
    @State private var cache = AIPanelCache()
    /// Local recognition of pages the search index does not know yet.
    @StateObject private var reader = ContentSearchModel()

    private struct Preview: Equatable { let key: PreviewKey; let plan: AIContextPlan }
    private struct PreviewKey: Hashable {
        let document: UUID
        let scope: AIContextScope
        let page: UUID
        /// Moves with every change of the notebook.
        let revision: Int
        /// Only while a selection depends on the question.
        let query: String
        /// Moves while background reading fills the index.
        let reading: Int
        func sameContent(as other: PreviewKey?) -> Bool {
            document == other?.document && scope == other?.scope && page == other?.page
        }
    }
    private struct ReadingKey: Hashable { let document: UUID?; let allowed: Bool }

    private var document: UUID? { editor.documentLoaded ? editor.notebook.id : nil }
    private var activePage: Page? {
        let pages = editor.notebook.pages
        return pages.indices.contains(editor.pageIndex) ? pages[editor.pageIndex] : pages.last
    }
    private var pageNumber: Int { max(1, min(editor.pageIndex + 1, editor.notebook.pages.count)) }
    private var area: String { searchIndexArea ?? StableDefaults.scope(editor.storageRoot) }
    private var excluded: Bool { document.map(ai.isExcluded) ?? false }
    /// Notebook content may be read for the assistant at all.
    private var mayRead: Bool { ai.hasConsent && !excluded && document != nil }
    private var trimmedDraft: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var running: Bool { ai.session?.status == .running }
    private var ready: Bool { ai.access.canSend && ai.hasConsent && document != nil }
    private var canSend: Bool { ready && !trimmedDraft.isEmpty && !ai.sending && !running }
    private var lastQuestion: String? { ai.session?.messages.last { $0.role == .user }?.text }
    private var previewKey: PreviewKey? {
        guard mayRead, let document, let page = activePage else { return nil }
        let query = preview?.plan.context.selected == true ? trimmedDraft : ""
        let reading = (reader.progress?.done ?? 0) * 2 + (reader.running ? 1 : 0)
        return PreviewKey(document: document, scope: scope, page: page.id, revision: editor.contentChanges, query: query, reading: reading)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            Group {
                if let reason = ai.access.reason { calmNotice(reason, symbol: "lock") }
                else if !ai.hasConsent { consentCard }
                else if showingChats { chats.transition(.opacity) }
                else { conversation }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if ready { footer }
        }
        .background(Color(uiColor: .systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: docked ? 0 : 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: docked ? 0 : 16, style: .continuous).strokeBorder(.secondary.opacity(0.25)))
        .shadow(color: .black.opacity(docked ? 0 : 0.3), radius: 16)
        .onAppear { ai.panelAppeared() }
        .onDisappear { ai.panelDisappeared(); reader.cancel(); composing = false }
        .onChange(of: document, initial: true) { _, document in
            guard let document else { return }
            ai.show(document: document); preview = nil
            Task { await ai.loadSessions(resume: true) }
        }
        .onChange(of: ai.accountEpoch) { _, _ in preview = nil }
        .task(id: ai.accountEpoch) {
            await ai.refreshStatus()
            await ai.loadSessions(resume: true)
        }
        .task(id: previewKey) { await updatePreview() }
        .task(id: ReadingKey(document: document, allowed: mayRead)) { await startReading() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 0) {
            titleMenu
            Spacer(minLength: 8)
            headerButton(showingChats ? "bubble.left" : "clock", showingChats ? "Zurück zum Chat" : "Frühere Chats") {
                withAnimation(NotyMotion.panel(reduceMotion)) { showingChats.toggle() }
            }
            headerButton("square.and.pencil", "Neuer Chat") {
                withAnimation(NotyMotion.panel(reduceMotion)) { showingChats = false }
                ai.newChat()
            }
            headerButton("xmark", "KI schließen") { composing = false; onClose() }
        }
        .padding(.leading, 16).padding(.trailing, 4)
        .frame(height: 48)
        .background(.ultraThinMaterial)
    }

    /// Notebook and usage: everything that is not needed for every question.
    private var titleMenu: some View {
        Menu {
            if let document {
                Section(editor.notebook.title.isEmpty ? "Dieses Heft" : editor.notebook.title) {
                    Toggle(isOn: Binding(get: { ai.isExcluded(document) }, set: { ai.setExcluded(document, $0) })) {
                        Label("Dieses Heft von der KI ausschließen", systemImage: "eye.slash")
                    }
                }
            }
            Section {
                if let use = ai.dailyUse { Text("Heute \(use.used) von \(use.limit) Fragen") }
                if let usage = ai.lastUsage?.summary { Text("Letzte Antwort: \(usage) Tokens") }
                if let host = ai.serverHost { Text("Server: \(host)") }
            }
            if let onSwitchSide {
                Button("Auf die andere Seite", systemImage: "arrow.left.and.right", action: onSwitchSide)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "sparkle").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                Text("KI").font(.headline).foregroundStyle(.primary)
                Image(systemName: "chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .frame(minHeight: 44).contentShape(Rectangle())
        }
        .accessibilityLabel("KI-Menü")
        .accessibilityHint("Heft ausschließen, Verbrauch heute")
    }

    private func headerButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.body).foregroundStyle(.secondary)
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .buttonStyle(NotyPressStyle())
        .accessibilityLabel(label).help(label)
    }

    private func calmNotice(_ text: String, symbol: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.title2).foregroundStyle(.secondary)
            Text(text).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(24)
    }

    /// Only after a change of server or account: switching on in the settings asks already.
    private var consentCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Spacer(minLength: 0)
            Image(systemName: "hand.raised").font(.title2).foregroundStyle(.secondary)
            Text("Einmal zustimmen").font(.title3.weight(.semibold))
            Text(AIAssistantModel.consentText(host: ai.serverHost)).font(.subheadline).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Zustimmen") { ai.giveConsent() }
                .buttonStyle(.borderedProminent).disabled(ai.consentKey == nil)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    }

    // MARK: Chats of this notebook

    private var chats: some View {
        List {
            Section {
                if ai.sessions.isEmpty {
                    Text("Noch keine Chats zu diesem Heft.").font(.subheadline).foregroundStyle(.secondary)
                        .listRowBackground(Color.clear)
                }
                ForEach(ai.sessions) { summary in
                    Button {
                        withAnimation(NotyMotion.panel(reduceMotion)) { showingChats = false }
                        Task { await ai.select(summary.id) }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(summary.title ?? "Chat").font(.body).foregroundStyle(.primary).lineLimit(2)
                            Text(summary.status == .running ? "Antwort läuft …" : summary.updatedDate.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                    .listRowBackground(summary.id == ai.session?.id ? Color(uiColor: .secondarySystemBackground) : Color.clear)
                    .swipeActions {
                        Button("Löschen", role: .destructive) { Task { await ai.delete(summary.id) } }
                    }
                }
            } header: {
                Text("Frühere Chats")
            } footer: {
                if let use = ai.dailyUse { Text("Heute \(use.used) von \(use.limit) Fragen") }
            }
        }
        .listStyle(.plain).scrollContentBackground(.hidden)
        .task { await ai.loadSessions() }
    }

    // MARK: Conversation

    @ViewBuilder
    private var conversation: some View {
        if let session = ai.session, !session.messages.isEmpty {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 24) {
                        let answers = session.answerRequests
                        let questions = Dictionary(session.messages.filter { $0.role == .user }.map { ($0.id, $0.text) }) { first, _ in first }
                        let lastAnswer = session.messages.last { $0.role == .assistant }?.id
                        ForEach(session.messages) { message in
                            let request = answers[message.id]
                            let retry: String? = message.id == lastAnswer && session.status != .running ? request.flatMap { questions[$0] } : nil
                            row(message, in: session, request: request, retry: retry)
                        }
                        runStatus(session)
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(16)
                }
                .defaultScrollAnchor(.bottom)
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: ai.session?.revision) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
                .onChange(of: ai.session?.id) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
            }
        } else {
            emptyState
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 16) {
            Spacer(minLength: 0)
            Image(systemName: "sparkle").font(.title2).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text("Frag mich zum Heft").font(.title3.weight(.semibold))
                Text(greeting).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if !excluded {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(AIPromptSuggestion.all) { suggestion in
                        Button { use(suggestion) } label: {
                            Text(suggestion.title).font(.subheadline).foregroundStyle(.primary)
                                .padding(.horizontal, 16).frame(minHeight: 40)
                                .background(Capsule().fill(Color(uiColor: .secondarySystemBackground)))
                                .overlay(Capsule().strokeBorder(Color.white.opacity(0.08)))
                                .contentShape(Capsule())
                        }
                        .buttonStyle(NotyPressStyle())
                        .disabled(!ready || ai.sending || running)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    }

    private var greeting: String {
        if excluded { return "Dieses Heft ist ausgeschlossen. Fragen gehen ohne Heftinhalt." }
        let title = editor.notebook.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let pages = NotyText.count(editor.notebook.pages.count, "Seite", "Seiten")
        return title.isEmpty ? "Ich lese dieses Heft mit, \(pages)." : "Ich lese „\(title)“ mit, \(pages)."
    }

    private func use(_ suggestion: AIPromptSuggestion) {
        if suggestion.sendsDirectly { submit(suggestion.prompt, suggestion: suggestion) }
        else { draft = suggestion.prompt; composing = true }
    }

    private func row(_ message: AIMessage, in session: AISession, request: String?, retry: String?) -> some View {
        let pages = citablePages(request: request)
        var blocks: [AIRenderedBlock]?
        if message.role == .assistant {
            let growing = session.status == .running && message.id == session.messages.last?.id
            let answer = cache.answers.value(id: message.id, text: message.text, pages: Set(pages.keys), growing: growing) {
                AIMarkdown.blocks($0, pages: Set(pages.keys))
            }
            var value = answer.value
            if !answer.tail.isEmpty { value.append(AIRenderedBlock(id: value.count, kind: .text(AttributedString(String(answer.tail)), .body))) }
            blocks = value
        }
        let finished = !(session.status == .running && message.id == session.messages.last?.id)
        return AIMessageRow(message: message, blocks: blocks, pages: pages, showsActions: finished, canRetry: retry != nil && ready,
                            onJump: { page in if let document { onJump(document, page) } },
                            onRetry: { if let retry { submit(retry) } }).equatable()
    }

    /// Only pages of the question's own context, and only those that still exist.
    private func citablePages(request: String?) -> [Int: UUID] {
        guard let request, let document else { return [:] }
        let noted = ai.citationPages(requestID: request, document: document)
        guard !noted.isEmpty else { return [:] }
        let existing = cache.pages(of: editor)
        return noted.filter { existing.contains($0.value) }
    }

    @ViewBuilder
    private func runStatus(_ session: AISession) -> some View {
        switch session.status {
        case .running:
            let last = session.messages.last
            let waiting = last?.role != .assistant || last?.text.isEmpty == true
            let question = session.messages.last { $0.role == .user }?.id
            AITypingIndicator(thinking: waiting && (question.flatMap(ai.mode(of:))?.showsThinking ?? false))
        case .error:
            Label("Die Antwort ist fehlgeschlagen.", systemImage: "exclamationmark.circle").font(.footnote).foregroundStyle(.secondary)
        case .interrupted:
            Label("Abgebrochen", systemImage: "stop.circle").font(.footnote).foregroundStyle(.tertiary)
        case .idle:
            EmptyView()
        }
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            notice
            HStack(spacing: 8) {
                modeMenu
                if excluded {
                    Text("Heft ausgeschlossen").font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    scopePill
                }
                Spacer(minLength: 0)
            }
            contextLine
            composerField
        }
        .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 16)
    }

    private var noticeText: String? {
        if let error = ai.error { return error }
        if ai.stalled { return "Die Verbindung zur laufenden Antwort ist unterbrochen." }
        if let status = ai.statusError { return status }
        if let info = ai.info, info.account == nil { return "Der Server ist nicht bei ChatGPT angemeldet." }
        return nil
    }

    @ViewBuilder
    private var notice: some View {
        if let text = noticeText {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: ai.limitReached ? "hourglass" : "exclamationmark.circle").foregroundStyle(.orange.opacity(0.85))
                Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if ai.stalled {
                    Button("Erneut prüfen") { ai.error = nil; Task { await ai.refreshSession() } }.fontWeight(.semibold)
                }
                if ai.error != nil {
                    Button { ai.error = nil } label: { Image(systemName: "xmark").font(.caption2.weight(.bold)).frame(width: 28, height: 28) }
                        .foregroundStyle(.tertiary).accessibilityLabel("Hinweis schließen")
                }
            }
            .font(.footnote)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(uiColor: .secondarySystemBackground)))
            .transition(.opacity)
        }
    }

    private var modeMenu: some View {
        Menu {
            Picker("Antwortmodus", selection: $mode) {
                ForEach(AIAnswerMode.allCases) { option in
                    Label {
                        Text(option.title)
                        Text(option.detail)
                    } icon: { Image(systemName: option.symbol) }
                    .tag(option)
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: mode.symbol)
                Text(mode.title)
                Image(systemName: "chevron.down").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .font(.footnote).foregroundStyle(.secondary)
            .padding(.horizontal, 12).frame(height: 32)
            .background(Capsule().fill(Color(uiColor: .secondarySystemBackground)))
            .contentShape(Capsule())
        }
        .accessibilityLabel("Antwortmodus: \(mode.title)")
        .accessibilityHint("Gilt für die nächste Frage")
    }

    private var scopePill: some View {
        HStack(spacing: 2) {
            ForEach(AIContextScope.allCases) { option in
                let chosen = scope == option
                Button { withAnimation(NotyMotion.highlight(reduceMotion)) { scope = option } } label: {
                    Text(option.title).font(.footnote.weight(chosen ? .semibold : .regular))
                        .foregroundStyle(chosen ? .primary : .secondary)
                        .padding(.horizontal, 12).frame(height: 28)
                        .background { if chosen { Capsule().fill(Color(uiColor: .tertiarySystemFill)) } }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(chosen ? .isSelected : [])
            }
        }
        .padding(2)
        .background(Capsule().fill(Color(uiColor: .secondarySystemBackground)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Kontext")
    }

    /// Reading progress, otherwise what the next question takes along.
    private var contextLine: some View {
        HStack(spacing: 6) {
            if mayRead, reader.running, let progress = reader.progress, progress.total > 0 {
                ProgressView().controlSize(.mini)
                Text(progress.label)
                Button { reader.cancel() } label: {
                    Image(systemName: "xmark").font(.caption2.weight(.bold)).frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .accessibilityLabel("Lesen abbrechen").help("Lesen abbrechen")
            } else {
                Text(contextDetail)
            }
        }
        .font(.caption).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
        .frame(minHeight: 20, alignment: .leading)
    }

    private var contextDetail: String {
        if excluded { return "Fragen gehen ohne Heftinhalt" }
        guard let preview, preview.key.sameContent(as: previewKey) else { return " " }
        return AIContextSummary.detail(scope: scope, plan: preview.plan, hasQuestion: !trimmedDraft.isEmpty)
    }

    private var composerField: some View {
        HStack(alignment: .bottom, spacing: 4) {
            AIComposerField(text: $draft, focused: $composing) { submit() }
                .overlay(alignment: .topLeading) {
                    if draft.isEmpty {
                        Text("Frag zum Heft …").font(.body).foregroundStyle(.tertiary)
                            .padding(.top, AIComposerField.inset).allowsHitTesting(false).accessibilityHidden(true)
                    }
                }
            sendButton
        }
        .padding(.leading, 16).padding(.trailing, 4).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(Color(uiColor: .secondarySystemBackground)))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Color.white.opacity(composing ? 0.2 : 0.08)))
        .animation(NotyMotion.highlight(reduceMotion), value: composing)
    }

    @ViewBuilder
    private var sendButton: some View {
        if running {
            Button { Task { await ai.stop() } } label: {
                Image(systemName: "stop.fill").font(.footnote.weight(.bold)).foregroundStyle(.black)
                    .frame(width: 32, height: 32).background(Circle().fill(.white))
                    .frame(width: 44, height: 44).contentShape(Circle())
            }
            .buttonStyle(NotyPressStyle())
            .disabled(ai.stopping).accessibilityLabel("Antwort stoppen").help("Antwort stoppen")
        } else if ai.sending {
            ProgressView().frame(width: 44, height: 44)
        } else {
            Button { submit() } label: {
                Image(systemName: "arrow.up").font(.callout.weight(.bold))
                    .foregroundStyle(canSend ? Color.black : Color(uiColor: .tertiaryLabel))
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(canSend ? Color.white : Color(uiColor: .tertiarySystemFill)))
                    .frame(width: 44, height: 44).contentShape(Circle())
            }
            .buttonStyle(NotyPressStyle())
            .disabled(!canSend).accessibilityLabel("Senden").help("Senden (Return)")
        }
    }

    // MARK: Context

    /// Waits for a pause in the work on the notebook; `.task(id:)` cancels this
    /// with every change, so nothing runs between strokes. An open text field
    /// counts as input too, hence the bound.
    private func updatePreview() async {
        guard let key = previewKey, let page = activePage else { preview = nil; return }
        do {
            try await Task.sleep(for: .milliseconds(key.sameContent(as: preview?.key) ? 1_200 : 350))
            for _ in 0..<20 where editor.inputInProgress { try await Task.sleep(for: .milliseconds(250)) }
            let request = AIContextRequest(scope: key.scope, current: pageNumber, question: key.query, previousQuestion: lastQuestion,
                                           limit: ai.limits.maxContextChars, maxImages: ai.limits.maxImages)
            let plan = try await AIContextCollector.plan(editor, notebook: editor.notebook, pageID: page.id, request: request,
                                                         area: area, priority: .utility)
            guard !Task.isCancelled else { return }
            preview = Preview(key: key, plan: plan)
        } catch {}
    }

    /// Local recognition of the pages the index lacks, once per opened
    /// notebook: only missing pages, paused during input, cancelled on close.
    private func startReading() async {
        reader.cancel()
        guard mayRead, let document, editor.documentLoaded else { return }
        do {
            try await Task.sleep(for: .seconds(1))
            for _ in 0..<40 where editor.inputInProgress { try await Task.sleep(for: .milliseconds(250)) }
        } catch { return }
        guard !Task.isCancelled, self.document == document, mayRead else { return }
        let editor = self.editor
        reader.collectsHits = false
        reader.shouldPause = { editor.inputInProgress }
        reader.start(documents: [OpenNotebook(id: document, directory: editor.storageRoot, title: editor.notebook.title, isRestored: false)],
                     current: editor.notebook, currentSources: { editor.sourcePage(for: $0) }, area: area)
    }

    /// Everything is taken from this moment's snapshot; a later change of
    /// page or notebook does not change what goes out.
    private func submit(_ text: String? = nil, suggestion: AIPromptSuggestion? = nil) {
        let question = (text ?? draft).trimmingCharacters(in: .whitespacesAndNewlines)
        guard ready, !question.isEmpty, !ai.sending, !running, let document, let page = activePage else { return }
        let fromDraft = text == nil
        let scope = suggestion?.scope ?? self.scope, excluded = self.excluded, mode = self.mode
        let notebook = editor.notebook, editor = self.editor, area = self.area, limits = ai.limits
        let number = (notebook.pages.firstIndex { $0.id == page.id } ?? 0) + 1
        let request = AIContextRequest(scope: scope, current: number, question: question, previousQuestion: lastQuestion,
                                       wholeNotebook: suggestion?.wholeNotebook ?? false,
                                       limit: limits.maxContextChars, maxImages: limits.maxImages)
        let key = previewKey
        let reader = self.reader
        Task {
            let accepted = await ai.send(question: question, document: document, mode: mode) {
                var attachment = AIAttachment()
                guard !excluded else { return attachment }
                let plan = try await AIContextCollector.plan(editor, notebook: notebook, pageID: page.id, request: request,
                                                             area: area, priority: .userInitiated)
                if let key, key.scope == scope { preview = Preview(key: key, plan: plan) }
                if !plan.context.isEmpty {
                    attachment.context = AITurnContext(label: AIContextSummary.label(title: notebook.title, scope: scope, plan: plan),
                                                       text: plan.context.text)
                }
                for number in plan.imagePages where notebook.pages.indices.contains(number - 1) {
                    attachment.images.append(try await AIContextCollector.image(editor, page: notebook.pages[number - 1],
                                                                                label: "Seite \(number)", limit: limits.maxImageBytes))
                }
                attachment.pages = plan.citablePages
                // Pages still unread: reading resumes for the next question.
                if !plan.context.unrecognizedPages.isEmpty, !reader.running { Task { await startReading() } }
                return attachment
            }
            if accepted, fromDraft, draft.trimmingCharacters(in: .whitespacesAndNewlines) == question { draft = "" }
        }
    }
}

/// Dots while an answer is written; „Denkt nach …“ for the thinking mode
/// until the first words arrive.
private struct AITypingIndicator: View {
    let thinking: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        HStack(spacing: 8) {
            if thinking {
                Image(systemName: "lightbulb").symbolEffect(.pulse, isActive: !reduceMotion)
                Text("Denkt nach …")
            } else {
                Image(systemName: "ellipsis").font(.title3).symbolEffect(.variableColor.iterative, isActive: !reduceMotion)
            }
        }
        .font(.subheadline).foregroundStyle(.secondary)
        .frame(minHeight: 24)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(thinking ? "Denkt nach" : "Antwort wird geschrieben")
    }
}

/// One message. Equatable: the panel's body also runs for changes of the
/// notebook, the row only when its content changed.
private struct AIMessageRow: View, Equatable {
    let message: AIMessage
    let blocks: [AIRenderedBlock]?
    /// Citable pages of this answer.
    let pages: [Int: UUID]
    let showsActions: Bool
    let canRetry: Bool
    let onJump: (UUID) -> Void
    let onRetry: () -> Void
    @State private var copied = false

    nonisolated static func == (a: AIMessageRow, b: AIMessageRow) -> Bool {
        a.message == b.message && a.blocks == b.blocks && a.pages == b.pages && a.showsActions == b.showsActions && a.canRetry == b.canRetry
    }

    var body: some View {
        switch message.role {
        case .user:
            VStack(alignment: .trailing, spacing: 4) {
                Text(message.text).font(.body).textSelection(.enabled)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                if let origin { Text(origin).font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle) }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.leading, 40)
        case .assistant:
            VStack(alignment: .leading, spacing: 12) {
                ForEach(blocks ?? [AIRenderedBlock(id: 0, kind: .text(AttributedString(message.text), .body))]) { block in
                    AIBlockView(block: block)
                }
                if showsActions { actions }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .environment(\.openURL, OpenURLAction { url in
                if let number = AICitation.page(from: url), let page = pages[number] { onJump(page) }
                return .handled
            })
        case .system:
            Label(message.text, systemImage: "info.circle").font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var actions: some View {
        HStack(spacing: 0) {
            action(copied ? "checkmark" : "doc.on.doc", copied ? "Kopiert" : "Antwort kopieren") {
                UIPasteboard.general.string = message.text
                copied = true
                Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
            }
            if canRetry { action("arrow.clockwise", "Erneut fragen", onRetry) }
        }
        .padding(.leading, -10).padding(.top, -4)
    }

    private func action(_ symbol: String, _ label: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Image(systemName: symbol).font(.footnote).foregroundStyle(.tertiary)
                .frame(width: 36, height: 32).contentShape(Rectangle())
        }
        .buttonStyle(NotyPressStyle())
        .accessibilityLabel(label).help(label)
    }

    private var origin: String? {
        var parts: [String] = []
        if let label = message.contextLabel, !label.isEmpty { parts.append(label) }
        if let count = message.imageCount, count > 0 { parts.append(NotyText.count(count, "Bild", "Bilder")) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

private struct AIBlockView: View {
    let block: AIRenderedBlock
    var body: some View {
        switch block.kind {
        case .text(let text, let style):
            Text(text).font(font(style)).lineSpacing(style == .body ? 4 : 2)
                .padding(.top, style == .body ? 0 : 4)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        case .listItem(let indent, let marker, let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(marker).foregroundStyle(.secondary).monospacedDigit()
                Text(text).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
            }
            .font(.body).textSelection(.enabled)
            .padding(.leading, Double(min(indent, 4)) * 16)
        case .quote(let text):
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: 1.5).fill(Color(uiColor: .tertiaryLabel)).frame(width: 3)
                Text(text).font(.body).foregroundStyle(.secondary).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .code(let code):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true).padding(12)
            }
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        case .rule:
            Divider().padding(.vertical, 4)
        }
    }

    private func font(_ style: AIRenderedBlock.Style) -> Font {
        switch style {
        case .body: .body
        case .title: .title3.weight(.semibold)
        case .heading: .headline
        case .subheading: .subheadline.weight(.semibold)
        }
    }
}

/// Answers block by block (`AIMarkdownBlocks`), inline Markdown per block.
/// Only citations stay links, shown as small pills: an answer may not offer
/// addresses that notebook text talked it into.
private enum AIMarkdown {
    static func blocks(_ text: String, pages: Set<Int>) -> [AIRenderedBlock] {
        AIMarkdownBlocks.parse(text).enumerated().map { offset, block in
            let kind: AIRenderedBlock.Kind
            switch block {
            case .heading(let level, let title):
                kind = .text(inline(title, pages: pages), level == 1 ? .title : level == 2 ? .heading : .subheading)
            case .paragraph(let value): kind = .text(inline(value, pages: pages), .body)
            case .listItem(let indent, let marker, let value): kind = .listItem(indent: indent, marker: marker, inline(value, pages: pages))
            case .quote(let value): kind = .quote(inline(value, pages: pages))
            case .code(let value): kind = .code(value)
            case .table(let rows): kind = .code(AIMarkdownBlocks.monospaced(rows))
            case .rule: kind = .rule
            }
            return AIRenderedBlock(id: offset, kind: kind)
        }
    }

    private static func inline(_ text: String, pages: Set<Int>) -> AttributedString {
        let source = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { AICitation.markdown(String($0), pages: pages) }.joined(separator: "\n")
        guard let parsed = try? AttributedString(markdown: source, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else {
            return AttributedString(text)
        }
        var result = AttributedString()
        for run in parsed.runs {
            var piece = AttributedString(parsed[run.range])
            if let link = run.link {
                if link.scheme == AICitation.linkScheme {
                    var pill = AttributedString("\u{2009}" + String(piece.characters) + "\u{2009}")
                    pill.link = link
                    pill.font = .footnote.weight(.semibold)
                    pill.foregroundColor = Color.accentColor
                    pill.backgroundColor = Color.accentColor.opacity(0.18)
                    piece = pill
                } else { piece.link = nil }
            }
            result += piece
        }
        return result
    }
}

/// Multi-line input that grows to five lines. Return sends, Shift-Return on a
/// hardware keyboard breaks the line.
struct AIComposerField: UIViewRepresentable {
    static let inset: CGFloat = 10
    @Binding var text: String
    @Binding var focused: Bool
    let onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> AIComposerTextView {
        let view = AIComposerTextView()
        view.delegate = context.coordinator
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.backgroundColor = .clear
        view.textContainerInset = UIEdgeInsets(top: Self.inset, left: 0, bottom: Self.inset, right: 0)
        view.textContainer.lineFragmentPadding = 0
        view.isScrollEnabled = false
        view.returnKeyType = .send
        view.enablesReturnKeyAutomatically = true
        view.accessibilityLabel = "Frage zum Heft"
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateUIView(_ view: AIComposerTextView, context: Context) {
        context.coordinator.parent = self
        if view.text != text { view.text = text; view.invalidateIntrinsicContentSize() }
        if focused, !view.isFirstResponder, view.window != nil {
            DispatchQueue.main.async { view.becomeFirstResponder() }
        } else if !focused, view.isFirstResponder {
            DispatchQueue.main.async { view.resignFirstResponder() }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: AIComposerTextView, context: Context) -> CGSize? {
        let width = max(40, proposal.width ?? 280)
        let line = uiView.font?.lineHeight ?? 22
        let lowest = ceil(line + 2 * Self.inset), highest = ceil(5 * line + 2 * Self.inset)
        let fitting = ceil(uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height)
        let scrolls = fitting > highest
        if uiView.isScrollEnabled != scrolls { DispatchQueue.main.async { uiView.isScrollEnabled = scrolls } }
        return CGSize(width: width, height: min(max(fitting, lowest), highest))
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: AIComposerField
        init(_ parent: AIComposerField) { self.parent = parent }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            textView.invalidateIntrinsicContentSize()
        }
        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
            guard text == "\n" else { return true }
            if let view = textView as? AIComposerTextView, view.newlineRequested {
                view.newlineRequested = false
                return true
            }
            parent.onSubmit()
            return false
        }
        func textViewDidBeginEditing(_ textView: UITextView) { if !parent.focused { parent.focused = true } }
        func textViewDidEndEditing(_ textView: UITextView) { if parent.focused { parent.focused = false } }
    }
}

final class AIComposerTextView: UITextView {
    /// Set by Shift- or Option-Return on a hardware keyboard: that one breaks the line.
    var newlineRequested = false

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        for press in presses {
            guard let key = press.key else { continue }
            newlineRequested = key.keyCode == .keyboardReturnOrEnter && !key.modifierFlags.isDisjoint(with: [.shift, .alternate])
        }
        super.pressesBegan(presses, with: event)
    }
}
