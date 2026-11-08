import SwiftUI
import NotebookCore

// Lernfelder in the event window (docs/LERNFELDER.md): the topic card in the
// details (topic, own key sentence, pinned material with video and script)
// and the note area of a Lernfeld lesson without its section yet.

/// Thema der Stunde: topic, pinned material, key sentence.
struct CalendarTopicCard: View {
    let event: CalendarEntry
    @ObservedObject var model: CalendarModel
    @ObservedObject private var materials = MaterialLibrary.shared
    @Environment(\.openURL) private var openURL
    @State private var topicText = ""
    @State private var summaryText = ""
    /// What `load()` read: only text the user changed is saved, so a card
    /// shown before another card's save landed never writes the older value back.
    @State private var loadedTopic = ""
    @State private var loadedSummary = ""
    @State private var searching = false
    @State private var script: ScriptRequest?
    @FocusState private var focus: Field?
    private enum Field { case topic, summary }

    var body: some View {
        let topic = model.topic(for: event)
        let field = model.studyField(for: event)
        VStack(alignment: .leading, spacing: CalendarSpace.s) {
            HStack(spacing: 6) {
                Text("Thema").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                if let field {
                    Text(field.shortName).font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.18), in: Capsule())
                        .help(field.displayName)
                        .accessibilityLabel(field.displayName)
                }
            }
            TextField("Worum ging es?", text: $topicText)
                .textFieldStyle(.roundedBorder)
                .focused($focus, equals: .topic)
                .submitLabel(.done)
                .onSubmit { saveTopic() }
                .disabled(!model.canWrite || model.showsSamples)
            if let pinned = topic?.materials, !pinned.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(pinned, id: \.self) { ref in pinnedRow(ref) }
                }
            }
            Button {
                saveTopic()
                searching = true
            } label: {
                Label(topic?.materials.isEmpty ?? true ? "Skript und Video suchen" : "Weiteres Material", systemImage: "books.vertical")
                    .font(.subheadline)
            }
            .buttonStyle(.bordered).controlSize(.small)
            .disabled(!model.canWrite || model.showsSamples)
            TextField("Merksatz in eigenen Worten", text: $summaryText, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.roundedBorder)
                .font(.subheadline)
                .focused($focus, equals: .summary)
                .disabled(!model.canWrite || model.showsSamples)
        }
        .onAppear { load() }
        .onChange(of: focus) { old, _ in
            if old == .topic { saveTopic() }
            if old == .summary { saveSummary() }
        }
        // Saved elsewhere meanwhile (the other lesson of the block): shown here unless being edited.
        .onChange(of: model.topic(for: event)) { _, topic in
            if focus != .topic, topicText == loadedTopic { topicText = topic?.topic ?? ""; loadedTopic = topicText }
            if focus != .summary, summaryText == loadedSummary { summaryText = topic?.summary ?? ""; loadedSummary = summaryText }
        }
        .onDisappear { saveTopic(); saveSummary() }
        .sheet(isPresented: $searching) {
            MaterialSearchSheet(initialQuery: topicText, field: field?.number,
                                pinned: Set((model.topic(for: event)?.materials ?? []).map { $0.package + "/" + $0.key }),
                                onPin: { _, ref in Task { await model.pin(ref, for: event) } })
        }
        .sheet(item: $script) { MaterialScriptSheet(request: $0) }
    }

    private func load() {
        let topic = model.topic(for: event)
        topicText = topic?.topic ?? ""
        summaryText = topic?.summary ?? ""
        loadedTopic = topicText
        loadedSummary = summaryText
    }

    private func saveTopic() {
        let text = topicText
        guard text != loadedTopic else { return }
        loadedTopic = text
        Task { await model.setTopic(text, for: event) }
    }

    private func saveSummary() {
        let text = summaryText
        guard text != loadedSummary else { return }
        loadedSummary = text
        Task { await model.updateTopic(for: event) { $0.summary = text } }
    }

    /// A pinned item: its snapshot always; video and script when the package is here.
    private func pinnedRow(_ ref: CalendarMaterialRef) -> some View {
        let match = materials.result(for: ref)
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: ref.key.hasPrefix("lesson:") ? "play.rectangle" : "doc.text").foregroundStyle(.tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(ref.label).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                if let detail = ref.detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
                HStack(spacing: 8) {
                    if let match, let link = materials.lessonLink(match) {
                        Button { openURL(link) } label: { Label("Video", systemImage: "play.fill") }
                    }
                    if let match, match.hit.pages != nil, let (url, title) = materials.script(match) {
                        Button {
                            script = ScriptRequest(url: url, title: title, page: match.hit.pages?.lowerBound ?? 1)
                        } label: { Label("Skript", systemImage: "doc.richtext") }
                    }
                    if match == nil {
                        Text("Material nicht auf diesem iPad").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .font(.caption).buttonStyle(.borderless)
            }
            Spacer(minLength: 0)
            Button { Task { await model.unpin(ref, for: event) } } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
                .accessibilityLabel("„\(ref.label)“ lösen")
        }
    }
}

/// The note area of a Lernfeld lesson without its section: one action.
struct CalendarStudyPromptView: View {
    let event: CalendarEntry
    let prompt: CalendarStudyPrompt
    @ObservedObject var model: CalendarModel

    var body: some View {
        VStack(spacing: CalendarSpace.s) {
            Image(systemName: "book.pages").font(.system(size: 30)).foregroundStyle(.secondary)
                .padding(.bottom, CalendarSpace.xs).accessibilityHidden(true)
            Text(prompt.field.displayName).font(.headline)
            Text(explanation).font(.subheadline).foregroundStyle(.secondary)
            if let failure = prompt.failure {
                Label(failure, systemImage: "exclamationmark.triangle.fill").font(.footnote).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: CalendarSpace.s) {
                if case .trashed(let id, _) = prompt.notebook {
                    Button { Task { await model.restoreStudyNotebook(id, for: event) } } label: {
                        Label("Heft wiederherstellen", systemImage: "arrow.uturn.backward")
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    Button { model.beginStudyNote(for: event, replacingTrashed: true) } label: {
                        Label("Neues Heft anlegen", systemImage: "plus")
                    }
                    .buttonStyle(.bordered).controlSize(.large)
                } else {
                    Button {
                        model.beginStudyNote(for: event)
                    } label: {
                        if prompt.creating { ProgressView() } else { Label("Mitschrift beginnen", systemImage: "square.and.pencil") }
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .keyboardShortcut(.return, modifiers: [.command])
                }
            }
            .disabled(prompt.creating)
            .padding(.top, CalendarSpace.m)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: 400)
        .padding(CalendarSpace.xl)
    }

    private var explanation: String {
        switch prompt.notebook {
        case .ready(let title):
            "Die Mitschrift dieser Stunde kommt als neue Seite mit Überschrift in „\(title)“ – an die passende Stelle nach Datum."
        case .trashed(_, let title):
            "Das Heft „\(title)“ dieses Lernfelds liegt im Papierkorb. Wiederherstellen und dort weiterschreiben, oder ein neues Heft anlegen (das alte bleibt im Papierkorb)."
        case .none:
            "Für dieses Lernfeld gibt es noch kein Heft. Die erste Mitschrift legt „\(prompt.field.notebookTitle)“ an."
        }
    }
}

/// Lernfelder: the sections of a Lernfeld notebook for the editor's page
/// list („Inhalt“). The open area's calendar provides them (its links know
/// which page starts which lesson); other notebooks have none.
@MainActor
final class StudyOutline: ObservableObject {
    static let shared = StudyOutline()
    @Published private(set) var revision = 0
    private var provider: ((Notebook) -> [StudySection])?
    private init() {}

    func attach(_ provider: @escaping (Notebook) -> [StudySection]) { self.provider = provider; revision += 1 }
    func changed() { revision += 1 }
    func sections(for notebook: Notebook) -> [StudySection] { provider?(notebook) ?? [] }
}

/// One lesson section in the page list.
struct StudySectionRow: View {
    let section: StudySection
    let pageNumber: Int
    let current: Bool
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(section.topic.isEmpty ? section.title : section.topic)
                        .font(.subheadline.weight(.semibold)).lineLimit(2).multilineTextAlignment(.leading)
                        .foregroundStyle(current ? Color.notyAccent : .primary)
                    Text(Self.date(section.start) + " · " + section.title + (section.pageIDs.count > 1 ? " · \(section.pageIDs.count) Seiten" : ""))
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text("\(pageNumber)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            .frame(minHeight: 40).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(section.topic.isEmpty ? section.title : section.topic), \(Self.date(section.start)), Seite \(pageNumber)")
    }

    static func date(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).day().month(.twoDigits).year().locale(Locale(identifier: "de_DE")))
    }
}
