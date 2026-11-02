import SwiftUI
import NotebookCore

/// A jump from an answer to a page of the active notebook, through the search
/// path of the pane it was asked in.
struct AIPageJump: Equatable {
    let id = UUID()
    let pane: Int
    let pageID: UUID
}

/// Chat beside the notebook. Reads snapshots, writes nothing into a notebook.
struct AIPanelView: View {
    @EnvironmentObject private var ai: AIAssistantModel
    @Environment(\.searchIndexArea) private var searchIndexArea
    @ObservedObject var editor: EditorModel
    let docked: Bool
    /// Page number in `document`; the workspace checks it is still the active one.
    let onJump: (UUID, Int) -> Void
    let onClose: () -> Void

    @State private var draft = ""
    @State private var choice = AIContextChoice.none
    @State private var withImage = false
    @State private var showingChats = false
    @State private var approval: ApprovalRequest?
    @State private var preview: Preview?
    @FocusState private var composing: Bool

    private struct ApprovalRequest { let document: UUID; let title: String; let choice: AIContextChoice }
    private struct Preview: Equatable { let key: PreviewKey; let context: AIContext }
    private struct PreviewKey: Hashable {
        let document: UUID
        let choice: AIContextChoice
        let page: UUID?
        /// Cheap sign of a change on the page; a whole notebook is read again on send.
        let revision: Int
    }

    private var document: UUID? { editor.documentLoaded ? editor.notebook.id : nil }
    private var activePage: Page? {
        let pages = editor.notebook.pages
        return pages.indices.contains(editor.pageIndex) ? pages[editor.pageIndex] : pages.last
    }
    private var pageNumber: Int { min(editor.pageIndex + 1, editor.notebook.pages.count) }
    private var pageCount: Int { editor.notebook.pages.count }
    private var area: String { searchIndexArea ?? StableDefaults.scope(editor.storageRoot) }
    /// A choice from another notebook or a withdrawn approval sends nothing.
    private var effectiveChoice: AIContextChoice {
        guard let document, ai.isApproved(document) else { return .none }
        return choice
    }
    private var previewKey: PreviewKey? {
        guard let document, let page = activePage, effectiveChoice != .none else { return nil }
        return PreviewKey(document: document, choice: effectiveChoice, page: effectiveChoice == .page ? page.id : nil,
                          revision: effectiveChoice == .page ? page.drawing.count &+ page.searchableText.utf16.count : 0)
    }
    private var trimmedDraft: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var running: Bool { ai.session?.status == .running }
    private var canSend: Bool { ai.access.canSend && document != nil && !trimmedDraft.isEmpty && !ai.sending && !running }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if showingChats { chats } else { conversation }
            Divider()
            if let reason = ai.access.reason { accessNotice(reason) }
            else {
                notices
                contextBar
                composer
            }
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: docked ? 0 : 16))
        .overlay(RoundedRectangle(cornerRadius: docked ? 0 : 16).strokeBorder(.secondary.opacity(0.25)))
        .shadow(color: .black.opacity(docked ? 0 : 0.3), radius: 16)
        .environment(\.openURL, OpenURLAction { url in
            if let document, let page = AICitation.page(from: url, pageCount: pageCount) { onJump(document, page) }
            return .handled
        })
        .onAppear { ai.panelAppeared() }
        .onDisappear { ai.panelDisappeared() }
        .onChange(of: document, initial: true) { _, document in
            guard let document else { return }
            ai.show(document: document); preview = nil; approval = nil
            if !ai.isApproved(document) { choice = .none; withImage = false }
            Task { await ai.loadSessions(resume: true) }
        }
        .task(id: ai.accountEpoch) {
            await ai.refreshStatus()
            await ai.loadSessions(resume: true)
        }
        .task(id: previewKey) { await updatePreview() }
        .alert("Inhalte dieses Hefts an ChatGPT senden?", isPresented: Binding(get: { approval != nil }, set: { if !$0 { approval = nil } })) {
            Button("Freigeben") {
                guard let approval else { return }
                ai.approve(approval.document)
                // The notebook may have changed behind the dialog.
                if approval.document == document { choice = approval.choice }
                self.approval = nil
            }
            Button("Abbrechen", role: .cancel) { approval = nil }
        } message: {
            Text("„\(approval?.title ?? "")“: Was du je Frage auswählst, geht an deinen eigenen Server und an OpenAI. Die Freigabe lässt sich in den Einstellungen zurücksetzen.")
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 4) {
            Label("KI-Assistent", systemImage: "sparkles").font(.subheadline.weight(.semibold)).lineLimit(1)
            if let use = ai.dailyUse {
                Text("\(use.used)/\(use.limit)").font(.caption2).monospacedDigit()
                    .foregroundStyle(use.used >= use.limit ? Color.orange : .secondary)
                    .accessibilityLabel("Heute \(use.used) von \(use.limit) Fragen")
                    .help("Fragen heute")
            }
            Spacer()
            headerButton("clock.arrow.circlepath", "Frühere Chats") { showingChats.toggle() }
            headerButton("square.and.pencil", "Neuer Chat") { showingChats = false; ai.newChat() }
            headerButton("xmark", "KI-Assistent schließen") { composing = false; onClose() }
        }
        .padding(.leading, 12).padding(.trailing, 4).padding(.vertical, 2)
    }

    private func headerButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 40, height: 36) }
            .accessibilityLabel(label).help(label)
    }

    private func accessNotice(_ reason: String) -> some View {
        Label(reason, systemImage: "lock").font(.footnote).foregroundStyle(.orange)
            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
    }

    // MARK: Chats of this notebook

    private var chats: some View {
        List {
            if ai.sessions.isEmpty {
                Text("Noch keine Chats zu diesem Heft.").font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(ai.sessions) { summary in
                Button {
                    showingChats = false
                    Task { await ai.select(summary.id) }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(summary.title ?? "Chat").font(.subheadline).lineLimit(2)
                        Text(summary.status == .running ? "Antwort läuft …" : summary.updatedDate.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .swipeActions {
                    Button("Löschen", role: .destructive) { Task { await ai.delete(summary.id) } }
                }
            }
        }
        .listStyle(.plain).scrollContentBackground(.hidden)
        .frame(maxHeight: .infinity)
        .task { await ai.loadSessions() }
    }

    // MARK: Conversation

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if let session = ai.session {
                        ForEach(session.messages) { message in
                            AIMessageRow(message: message, pageCount: pageCount).equatable()
                        }
                        runStatus(session.status)
                    } else if ai.access.canSend {
                        Text("Frage zu diesem Heft stellen. Es geht nur der unten gewählte Kontext mit.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(12)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: ai.session?.revision) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
            .onChange(of: ai.session?.id) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
        }
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private func runStatus(_ status: AISessionStatus) -> some View {
        switch status {
        case .running:
            HStack(spacing: 8) { ProgressView(); Text("Antwort wird erstellt …").font(.footnote).foregroundStyle(.secondary) }
        case .error:
            Label("Der Lauf ist fehlgeschlagen.", systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange)
        case .interrupted:
            Label("Abgebrochen.", systemImage: "stop.circle").font(.footnote).foregroundStyle(.secondary)
        case .idle:
            EmptyView()
        }
    }

    @ViewBuilder
    private var notices: some View {
        if let error = ai.error {
            HStack(alignment: .firstTextBaseline) {
                Label(error, systemImage: ai.limitReached ? "hourglass" : "exclamationmark.triangle")
                    .font(.footnote).foregroundStyle(.orange)
                Spacer(minLength: 4)
                if ai.stalled { Button("Erneut prüfen") { ai.error = nil; Task { await ai.refreshSession() } }.font(.footnote) }
                Button { ai.error = nil } label: { Image(systemName: "xmark.circle.fill") }
                    .foregroundStyle(.secondary).accessibilityLabel("Hinweis schließen")
            }
            .padding(.horizontal, 12).padding(.top, 8)
        } else if let status = ai.statusError {
            Label(status, systemImage: "wifi.exclamationmark").font(.footnote).foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.top, 8)
        } else if let info = ai.info, info.account == nil {
            Label("Der Server ist nicht bei ChatGPT angemeldet.", systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.top, 8)
        }
    }

    // MARK: Context

    private var contextBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Kontext", selection: Binding(get: { effectiveChoice }, set: choose)) {
                ForEach(AIContextChoice.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            if effectiveChoice == .page {
                Toggle("Seite als Bild", isOn: $withImage).font(.footnote).controlSize(.small)
                    .accessibilityHint("Nötig für Handschrift, die noch nicht erkannt ist.")
            }
            Text(contextLine).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(contextWarnings, id: \.self) { warning in
                Text(warning).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12).padding(.top, 8)
    }

    private func choose(_ next: AIContextChoice) {
        guard let document else { return }
        if next == .none || ai.isApproved(document) { choice = next; return }
        approval = ApprovalRequest(document: document, title: editor.notebook.title, choice: next)
    }

    private var currentPreview: Preview? { preview?.key == previewKey ? preview : nil }

    private var contextLine: String {
        switch effectiveChoice {
        case .none: return "Geht mit: nur die Frage, kein Heftinhalt."
        case .page, .notebook:
            let place = effectiveChoice == .page ? "Seite \(pageNumber)" : "ganzes Heft"
            var line = "Geht mit: \(AIContextBuilder.label(title: editor.notebook.title, place: place))"
            if let context = currentPreview?.context {
                if context.isEmpty { line += ", kein erkannter Text" }
                else {
                    if effectiveChoice == .notebook { line += ", \(NotyText.count(context.includedPages.count, "Seite", "Seiten")) mit Text" }
                    line += ", \(context.text.count.formatted()) Zeichen"
                }
            } else { line += " (wird geprüft …)" }
            if effectiveChoice == .page, withImage { line += ", dazu als Bild" }
            return line
        }
    }

    private var contextWarnings: [String] {
        guard let context = currentPreview?.context else { return [] }
        var warnings = context.truncationNotice.map { [$0] } ?? []
        let open = context.unrecognizedPages
        if effectiveChoice == .page, !open.isEmpty, !withImage {
            warnings.append("Handschrift oder Scan dieser Seite ist noch nicht erkannt. „Seite als Bild“ einschalten oder die Suche im Heft öffnen, damit der Suchindex sie erfasst.")
        } else if effectiveChoice == .notebook, !open.isEmpty {
            warnings.append("Handschrift oder Scans noch nicht erkannt (\(NotyText.count(open.count, "Seite", "Seiten")): \(AIContextBuilder.pageList(open))) und daher nicht dabei. Die Suche im Heft erfasst sie; einzelne Seiten gehen auch als Bild.")
        }
        return warnings
    }

    private func updatePreview() async {
        guard let key = previewKey else { preview = nil; return }
        do {
            try await Task.sleep(for: .milliseconds(350))
            let context = try await AIContextCollector.context(editor, notebook: editor.notebook, pageID: key.page, area: area, limit: ai.limits.maxContextChars)
            guard !Task.isCancelled else { return }
            preview = Preview(key: key, context: context)
        } catch {}
    }

    // MARK: Composer

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Frage zum Heft …", text: $draft, axis: .vertical)
                .lineLimit(1...6).textFieldStyle(.roundedBorder).focused($composing)
            if running {
                Button { Task { await ai.stop() } } label: { Image(systemName: "stop.circle.fill").font(.title2) }
                    .disabled(ai.stopping).accessibilityLabel("Antwort stoppen").help("Antwort stoppen")
            } else if ai.sending {
                ProgressView().frame(width: 30, height: 30)
            } else {
                Button(action: submit) { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                    .disabled(!canSend).accessibilityLabel("Senden").help("Senden")
            }
        }
        .padding(12)
    }

    /// Everything is taken from this moment's snapshot; a later change of
    /// page or notebook does not change what goes out.
    private func submit() {
        guard canSend, let document, let page = activePage else { return }
        let question = trimmedDraft, choice = effectiveChoice, image = choice == .page && withImage
        let notebook = editor.notebook, editor = self.editor, area = self.area, limits = ai.limits
        let number = (notebook.pages.firstIndex { $0.id == page.id } ?? 0) + 1
        let place = choice == .page ? "Seite \(number)" : "ganzes Heft"
        let label = AIContextBuilder.label(title: notebook.title, place: place)
        let key = [document.uuidString, choice.rawValue, page.id.uuidString, String(image), question].joined(separator: "|")
        Task {
            let accepted = await ai.send(question: question, document: document, key: key) {
                var attachment = AIAttachment()
                if choice != .none {
                    let context = try await AIContextCollector.context(editor, notebook: notebook, pageID: choice == .page ? page.id : nil,
                                                                       area: area, limit: limits.maxContextChars)
                    if !context.isEmpty { attachment.context = AITurnContext(label: label, text: context.text) }
                }
                if image {
                    attachment.images = [try await AIContextCollector.image(editor, page: page, label: "Seite \(number)", limit: limits.maxImageBytes)]
                }
                return attachment
            }
            if accepted, draft.trimmingCharacters(in: .whitespacesAndNewlines) == question { draft = "" }
        }
    }
}

/// One message. Equatable: the panel's body also runs for changes of the
/// notebook, parsing only happens when the message itself changed.
private struct AIMessageRow: View, Equatable {
    let message: AIMessage
    let pageCount: Int

    var body: some View {
        switch message.role {
        case .user:
            VStack(alignment: .trailing, spacing: 3) {
                Text(message.text).font(.callout).padding(.horizontal, 10).padding(.vertical, 7)
                    .background(Color.accentColor.opacity(0.28), in: RoundedRectangle(cornerRadius: 12))
                if let origin { Text(origin).font(.caption2).foregroundStyle(.secondary) }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        case .assistant:
            VStack(alignment: .leading, spacing: 4) {
                Text(AIMarkdown.rendered(message.text, pageCount: pageCount)).font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    UIPasteboard.general.string = message.text
                } label: { Image(systemName: "doc.on.doc").font(.caption).frame(width: 32, height: 28) }
                    .foregroundStyle(.secondary).accessibilityLabel("Antwort kopieren").help("Antwort kopieren")
            }
        case .system:
            Text(message.text).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var origin: String? {
        var parts: [String] = []
        if let label = message.contextLabel, !label.isEmpty { parts.append(label) }
        if let count = message.imageCount, count > 0 { parts.append(NotyText.count(count, "Bild", "Bilder")) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// Answers line by line: SwiftUI's `Text` drops block structure, so headings,
/// lists and code get their form here and `AttributedString` handles the
/// rest of each line. Only citations stay links: an answer may not offer
/// addresses that notebook text talked it into.
private enum AIMarkdown {
    static func rendered(_ text: String, pageCount: Int) -> AttributedString {
        var result = AttributedString()
        var code = false
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for (offset, line) in lines.enumerated() {
            let trimmed = line.drop { $0 == " " }
            if trimmed.hasPrefix("```") { code.toggle(); continue }
            var part: AttributedString
            if code {
                part = AttributedString(String(line))
                part.font = .system(.footnote, design: .monospaced)
            } else if let (level, title) = heading(trimmed) {
                part = inline(title, pageCount: pageCount)
                part.font = level == 1 ? .title3.bold() : .headline
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                part = AttributedString(String(repeating: " ", count: line.count - trimmed.count) + "•  ")
                    + inline(trimmed.dropFirst(2), pageCount: pageCount)
            } else {
                part = inline(line, pageCount: pageCount)
            }
            result += part
            if offset < lines.count - 1 { result += AttributedString("\n") }
        }
        return result
    }

    private static func heading(_ line: Substring) -> (Int, Substring)? {
        let level = line.prefix { $0 == "#" }.count
        guard (1...6).contains(level), line.dropFirst(level).first == " " else { return nil }
        return (level, line.dropFirst(level + 1))
    }

    private static func inline(_ line: Substring, pageCount: Int) -> AttributedString {
        let source = AICitation.markdown(String(line), pageCount: pageCount)
        guard var result = try? AttributedString(markdown: source, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else {
            return AttributedString(String(line))
        }
        for run in result.runs where run.link != nil && run.link?.scheme != AICitation.linkScheme {
            result[run.range].link = nil
        }
        return result
    }
}
