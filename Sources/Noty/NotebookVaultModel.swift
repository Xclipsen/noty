import SwiftUI
import UIKit
import NotebookCore

/// iCloud-Ablage (docs/ICLOUD.md): while the app is in use, each changed
/// notebook of „Meine Bibliothek“ is archived on its own into this app's
/// iCloud container (at most every 10 minutes per notebook; when leaving the
/// app at once). Only committed states are read; nothing in the library is
/// written. Writing a file into the container is not an upload: the upload
/// state is read from iCloud's own resource values and shown separately.
@MainActor
final class NotebookVaultModel: ObservableObject {
    /// One per app: only „Meine Bibliothek“ is archived, whatever area is open.
    static let shared = NotebookVaultModel()
    enum Availability: Equatable { case unknown, noContainer, signedOut, ready }

    /// `NotyICloudContainer` in Info.plist; set by publish_ota.sh only for
    /// channels whose container is assigned in the developer portal.
    let containerID = Bundle.main.object(forInfoDictionaryKey: "NotyICloudContainer") as? String
    @Published private(set) var enabled: Bool
    @Published private(set) var running = false
    @Published private(set) var availability: Availability = .unknown
    @Published private(set) var lastRun: Date?
    @Published private(set) var lastReport: VaultRunReport?
    @Published private(set) var failure: String?
    @Published private(set) var versionCount = 0
    @Published private(set) var storedBytes = 0
    /// Versions (and the head) iCloud reports as not uploaded yet; nil: unknown.
    @Published private(set) var waitingForUpload: Int?

    private var head: VaultHead?
    private var headLoaded = false
    private var root: URL?
    private var lastAttempt: Date?
    private static let enabledKey = "noty.v2.icloudVault.enabled"
    private static let deviceKey = "noty.v2.icloudVault.device"
    /// Between automatic passes; a pass with nothing changed only reads the manifests.
    private static let passInterval: TimeInterval = 120
    /// Per notebook while the app is in use.
    private static let versionInterval: TimeInterval = 600

    private init() { enabled = UserDefaults.standard.bool(forKey: Self.enabledKey) }

    var available: Bool { containerID != nil }

    /// One ID per installation; a new install starts its own head (the old
    /// one stays readable for restores).
    private var device: UUID {
        if let raw = UserDefaults.standard.string(forKey: Self.deviceKey), let id = UUID(uuidString: raw) { return id }
        let id = UUID()
        UserDefaults.standard.set(id.uuidString, forKey: Self.deviceKey)
        return id
    }

    func setEnabled(_ value: Bool) {
        enabled = value
        UserDefaults.standard.set(value, forKey: Self.enabledKey)
    }

    /// The vault root inside the container. Resolving can take a moment the
    /// first time (iOS sets the container up), so it runs off the UI actor.
    func resolve() async -> URL? {
        guard let containerID else { availability = .noContainer; return nil }
        guard FileManager.default.ubiquityIdentityToken != nil else { availability = .signedOut; root = nil; return nil }
        if let root { return root }
        let container = await Task.detached(priority: .utility) { FileManager.default.url(forUbiquityContainerIdentifier: containerID) }.value
        guard let container else { availability = .signedOut; return nil }
        root = VaultLayout.root(container: container)
        availability = .ready
        return root
    }

    /// `force`: leaving the app or „Jetzt sichern“: every changed notebook at once.
    func attempt(library: LibraryModel, workspaces: WorkspaceAppModel, force: Bool = false) async {
        guard enabled, available, !running, library.ready else { return }
        // Only „Meine Bibliothek“, never a test, restore or mirror area.
        guard workspaces.areaID == nil, library.root.standardizedFileURL == WorkspaceAppModel.mainRoot.standardizedFileURL else { return }
        if !force, let lastAttempt, Date().timeIntervalSince(lastAttempt) < Self.passInterval { return }
        lastAttempt = Date()
        guard let root = await resolve() else { return }
        running = true
        defer { running = false }
        do {
            let plan = try await library.vaultPlan()
            let scratch = try BackupScratch.newFolder()
            defer { BackupScratch.removeFolder(scratch) }
            let device = self.device, name = UIDevice.current.name, known = head, loaded = headLoaded
            let interval = force ? 0 : Self.versionInterval
            let (next, report) = try await Task.detached(priority: .utility) {
                let coordination = CoordinatedBackupFiles()
                let current = loaded ? known : try NotebookVault.readHead(root: root, device: device, coordination: coordination)
                return try NotebookVault.run(plan: plan, root: root, head: current, device: device, deviceName: name,
                                             scratch: scratch, minimumInterval: interval, coordination: coordination)
            }.value
            head = next; headLoaded = true
            lastRun = Date(); lastReport = report
            failure = report.failed.isEmpty ? nil
                : "\(NotyText.count(report.failed.count, "Heft", "Hefte")) nicht gesichert: " + report.failed.prefix(3).map(NotyText.quoted).joined(separator: ", ")
            await refreshUploadState()
        } catch {
            failure = error.localizedDescription
        }
    }

    /// Leaving the app: every changed notebook at once, inside the short
    /// background time iOS grants. If it runs out, the pass stops between
    /// two notebooks at the latest when the app returns; a half-copied file
    /// never counts as a version (`.partial`).
    func attemptWhileLeaving(library: LibraryModel, workspaces: WorkspaceAppModel) async {
        let task = BackgroundTask()
        task.id = UIApplication.shared.beginBackgroundTask(withName: "iCloud-Ablage") { MainActor.assumeIsolated { task.end() } }
        await attempt(library: library, workspaces: workspaces, force: true)
        task.end()
    }

    /// Counts and the upload state iCloud reports for every own version.
    func refreshUploadState() async {
        guard let head, let root else { return }
        versionCount = head.notebooks.reduce(0) { $0 + $1.versions.count }
        storedBytes = head.notebooks.reduce(0) { $0 + $1.versions.reduce(0) { $0 + $1.byteCount } }
        var files = head.notebooks.flatMap { notebook in
            notebook.versions.compactMap { VaultLayout.versionURL(root: root, notebook: notebook.id, file: $0.file) }
        }
        files.append(VaultLayout.headURL(root: root, device: head.device))
        waitingForUpload = await Task.detached(priority: .utility) {
            var waiting = 0, known = false
            for file in files {
                guard let uploaded = (try? file.resourceValues(forKeys: [.ubiquitousItemIsUploadedKey]))?.ubiquitousItemIsUploaded else { continue }
                known = true
                if !uploaded { waiting += 1 }
            }
            return known ? waiting : nil
        }.value
    }

    var statusText: String {
        if !enabled { return "Aus." }
        switch availability {
        case .noContainer: return "Diese Version hat keinen iCloud-Zugang."
        case .signedOut: return "iCloud ist auf diesem iPad nicht angemeldet oder iCloud Drive ist aus."
        case .unknown, .ready: break
        }
        if running { return "Wird gesichert …" }
        guard let lastRun, let report = lastReport else { return "Noch nicht gesichert." }
        var text = "Zuletzt geprüft: \(NotyText.statusDate(lastRun))"
        if !report.uploaded.isEmpty { text += " · \(NotyText.count(report.uploaded.count, "Heft", "Hefte")) gesichert" }
        else if report.waiting == 0 && report.failed.isEmpty { text += " · alles aktuell" }
        if report.waiting > 0 { text += " · \(report.waiting) folgen in Kürze" }
        return text
    }

    var uploadText: String? {
        guard enabled, availability == .ready, let waitingForUpload else { return nil }
        return waitingForUpload == 0 ? "Alles in iCloud hochgeladen."
            : "\(NotyText.count(waitingForUpload, "Datei wartet", "Dateien warten")) noch auf den Upload zu iCloud."
    }
}

@MainActor
private final class BackgroundTask {
    var id: UIBackgroundTaskIdentifier = .invalid
    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
