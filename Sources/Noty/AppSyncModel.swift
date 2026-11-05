import SwiftUI
import NotebookCore

/// Abgleich zwischen noty, noty dev und noty AI über die gemeinsame App Group
/// (docs/APP-SYNC.md). Die normale noty legt nur einen geprüften Abzug ihrer
/// Bibliothek („Meine Bibliothek“) ab: lesend aus der eigenen Bibliothek, schreibend
/// nur im gemeinsamen Ordner. Spiegel-Apps übernehmen den Abzug als eigenen
/// Bereich und ersetzen ihn beim nächsten Stand; ihre eigene Bibliothek bleibt unberührt.
@MainActor
final class AppSyncModel: ObservableObject {
    static let shared = AppSyncModel()
    static let groupName = "de.la.noty.shared"

    let channel: AppSyncChannel?
    let groupRoot: URL?
    @Published private(set) var busy = false
    @Published private(set) var status: String?
    /// Zuletzt gelesene Abzüge der Quellen (Anzeige).
    @Published private(set) var sources: [AppSyncChannel: AppSyncSnapshot] = [:]
    @Published private(set) var published: AppSyncSnapshot?
    private var lastPublishAttempt: Date?
    private var lastMirrorCheck: Date?

    private init() {
        let bundleID = Bundle.main.bundleIdentifier
        channel = AppSyncChannel.resolve(declared: Bundle.main.object(forInfoDictionaryKey: "NotyChannel") as? String, bundleID: bundleID)
        groupRoot = ProvisionedIdentifier.groupCandidates(Self.groupName, bundleID: bundleID).lazy
            .compactMap { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) }.first
        if let channel, let groupRoot { published = try? AppSyncOutbox.read(groupRoot: groupRoot, channel: channel) }
    }

    var available: Bool { channel != nil && groupRoot != nil }
    var unavailableReason: String? {
        if channel == nil { return "Diese Version ist keiner noty-App zugeordnet." }
        if groupRoot == nil { return "Der gemeinsame Ordner der noty-Apps fehlt in dieser Signatur." }
        return nil
    }

    // MARK: Quelle

    /// Legt einen Abzug von „Meine Bibliothek“ ab, wenn sich seit dem letzten
    /// etwas geändert hat. Automatisch höchstens alle zwei Minuten (beim Wechsel
    /// in den Hintergrund und im Minutentakt alle 30 Minuten), manuell sofort.
    /// Offene Hefte werden wie beim externen Backup nur für den Commit pausiert.
    func publish(library: LibraryModel, toolbox: ToolbarSettingsModel, workspaces: WorkspaceAppModel,
                 manual: Bool = false, minimumInterval: TimeInterval = 120) async {
        guard let channel, channel.publishes, let groupRoot, !busy, library.ready else { return }
        // Nur die eigentliche Bibliothek, nie Test-, Restore- oder Spiegelbereiche.
        guard workspaces.areaID == nil, library.root.standardizedFileURL == WorkspaceAppModel.mainRoot.standardizedFileURL else {
            if manual { status = "Abzug nur aus „Meine Bibliothek“ möglich" }
            return
        }
        if !manual, let lastPublishAttempt, Date().timeIntervalSince(lastPublishAttempt) < minimumInterval { return }
        if library.backupBlocker != nil { if manual { status = "Später erneut: \(library.backupBlocker ?? "")" }; return }
        lastPublishAttempt = Date()
        busy = true; defer { busy = false }
        let background = BackgroundAssertion("noty-app-sync")
        defer { background.end() }
        let committed = library.opened != nil
        let commit: BackupCommit
        if committed { commit = await library.editorCommit?() ?? .busy } else { commit = await toolbox.flush() ? .committed : .failed }
        guard commit == .committed else { if manual { status = "Heft wird gerade gespeichert; gleich erneut versuchen" }; return }
        let archive: PreparedLibraryArchive
        do { archive = try await library.buildArchive(editorsCommitted: committed) }
        catch { status = "Abzug nicht erstellt: \(error.localizedDescription)"; return }
        defer { BackupScratch.remove(archive.url) }
        let previous = published
        do {
            let snapshot = try await Task.detached(priority: .utility) { () throws -> AppSyncSnapshot? in
                let content = try AppSyncSnapshot.contentKey(archive.summary)
                if let previous, previous.content == content, (try? AppSyncOutbox.read(groupRoot: groupRoot, channel: channel)) == previous {
                    return nil
                }
                return try AppSyncOutbox.publish(archive: archive.url, summary: archive.summary, channel: channel, groupRoot: groupRoot)
            }.value
            if let snapshot { published = snapshot }
            status = "Abzug für die anderen noty-Apps: \(NotyText.statusDate(published?.createdAt ?? Date()))"
                + (snapshot == nil ? " · unverändert" : "") + (archive.warning.map { " · \($0)" } ?? "")
        } catch { status = "Abzug nicht abgelegt: \(error.localizedDescription)" }
    }

    // MARK: Spiegel

    private func stateKey(_ source: AppSyncChannel) -> String { "appSync.mirror.\(source.rawValue)" }
    func mirrorState(_ source: AppSyncChannel) -> AppSyncMirrorState? {
        guard let data = UserDefaults.standard.data(forKey: stateKey(source)) else { return nil }
        return try? JSONDecoder().decode(AppSyncMirrorState.self, from: data)
    }
    private func save(_ state: AppSyncMirrorState, for source: AppSyncChannel) {
        if let data = try? JSONEncoder().encode(state) { UserDefaults.standard.set(data, forKey: stateKey(source)) }
    }

    /// Übernimmt neue Abzüge der Quellen als Spiegelbereiche. Nur in Spiegel-Apps:
    /// Die normale noty hat keine Quellen und kommt hier nie an (doppelt geprüft).
    func mirror(workspaces: WorkspaceAppModel, manual: Bool = false) async {
        guard let channel, channel != .stable, !channel.mirrors.isEmpty, let groupRoot, !busy, !workspaces.busy else { return }
        if !manual, let lastMirrorCheck, Date().timeIntervalSince(lastMirrorCheck) < 50 { return }
        lastMirrorCheck = Date()
        busy = true; defer { busy = false }
        await workspaces.refresh()
        var messages: [String] = []
        for source in channel.mirrors {
            let snapshot: AppSyncSnapshot?
            do { snapshot = try AppSyncOutbox.read(groupRoot: groupRoot, channel: source) }
            catch { messages.append("\(source.appName): \(error.localizedDescription)"); continue }
            if let snapshot { sources[source] = snapshot } else { sources[source] = nil }
            var state = mirrorState(source)
            await removeStale(&state, source: source, workspaces: workspaces)
            switch AppSyncMirror.decide(snapshot, state: state, activeArea: workspaces.areaID) {
            case .upToDate: continue
            case .waitForArea: messages.append("Neuer Stand von \(source.appName) wird übernommen, sobald du den Spiegelbereich verlässt"); continue
            case .importSnapshot: break
            }
            guard let snapshot else { continue }
            let url = AppSyncOutbox.archiveURL(snapshot, groupRoot: groupRoot)
            do {
                let prepared = try await workspaces.prepareLibraryRestore(url)
                guard prepared.summary.file == snapshot.file else {
                    await workspaces.discardLibraryRestore(prepared)
                    throw AppSyncError.changedWhileCopying
                }
                let area = try await workspaces.commitMirror(prepared, title: "Von \(source.appName) · \(NotyText.listDate(snapshot.createdAt))")
                var next: AppSyncMirrorState? = AppSyncMirrorState(sequence: snapshot.sequence, content: snapshot.content, area: area.id,
                                                                   importedAt: Date(), stale: (state?.stale ?? []) + [state?.area].compactMap { $0 })
                if let next { save(next, for: source) }
                await removeStale(&next, source: source, workspaces: workspaces)
                messages.append("Stand von \(source.appName) übernommen (\(NotyText.count(snapshot.notebooks, "Heft", "Hefte")))")
            } catch {
                messages.append("\(source.appName) nicht übernommen: \(error.localizedDescription)")
            }
        }
        if !messages.isEmpty || manual { status = messages.isEmpty ? "Alle Spiegel sind aktuell" : messages.joined(separator: " · ") }
    }

    /// Entfernt frühere Spiegelbereiche dieser Quelle, sobald sie nicht geöffnet
    /// sind. Nur Bereiche der Art `mirror`, nie „Meine Bibliothek“ (WorkspaceStore prüft erneut).
    private func removeStale(_ state: inout AppSyncMirrorState?, source: AppSyncChannel, workspaces: WorkspaceAppModel) async {
        guard var current = state, !current.stale.isEmpty else { return }
        var remaining: [UUID] = []
        for id in current.stale where id != current.area {
            guard let area = workspaces.areas.first(where: { $0.id == id }) else { continue }
            guard area.kind == .mirror, id != workspaces.areaID, await workspaces.removeMirror(area) else { remaining.append(id); continue }
        }
        current.stale = remaining
        state = current
        save(current, for: source)
    }
}

/// Einstellungen › Backup › „Zwischen noty-Apps“.
struct AppSyncSection: View {
    @ObservedObject var sync = AppSyncModel.shared
    @ObservedObject var library: LibraryModel
    @ObservedObject var toolbox: ToolbarSettingsModel
    @ObservedObject var workspaces: WorkspaceAppModel
    var body: some View {
        Section {
            if let reason = sync.unavailableReason {
                Text(reason).foregroundStyle(.secondary)
            } else if let channel = sync.channel {
                if channel.publishes {
                    LabeledContent("Letzter Abzug", value: sync.published.map { "\(NotyText.statusDate($0.createdAt)) · \(NotyText.count($0.notebooks, "Heft", "Hefte"))" } ?? NotyText.never)
                    Button("Jetzt Abzug ablegen", systemImage: "square.and.arrow.up.on.square") {
                        Task { await sync.publish(library: library, toolbox: toolbox, workspaces: workspaces, manual: true) }
                    }.disabled(sync.busy || !library.ready || workspaces.areaID != nil)
                }
                ForEach(channel.mirrors, id: \.self) { source in
                    LabeledContent("Von \(source.appName)", value: sync.sources[source].map { "\(NotyText.statusDate($0.createdAt)) · \(NotyText.count($0.notebooks, "Heft", "Hefte"))" } ?? "Kein Abzug")
                }
                if !channel.mirrors.isEmpty {
                    Button("Spiegel jetzt aktualisieren", systemImage: "arrow.triangle.2.circlepath") {
                        Task { await sync.mirror(workspaces: workspaces, manual: true) }
                    }.disabled(sync.busy || workspaces.busy)
                }
                if let status = sync.status { Text(status).font(.caption).foregroundStyle(.secondary) }
            }
        } header: { Text("Zwischen noty-Apps") } footer: {
            switch sync.channel {
            case .stable?:
                Text("noty legt nur eine Kopie von „Meine Bibliothek“ für noty dev und noty AI ab. Sie übernimmt nie etwas von dort; Änderungen und Löschungen in den anderen Apps erreichen deine Hefte hier nicht.")
            case .some(let channel) where !channel.mirrors.isEmpty:
                Text("Neue Stände von \(channel.mirrors.map(\.appName).joined(separator: " und ")) erscheinen als eigener Bereich „Von …“ und ersetzen den vorigen Spiegel. Änderungen im Spiegel gehen dabei verloren und kommen nie zurück; Bleibendes vorher in „Meine Bibliothek“ kopieren.")
            default: EmptyView()
            }
        }
    }
}
