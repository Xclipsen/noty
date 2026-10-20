import SwiftUI
import NotebookCore

extension InkColor {
    var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha) }
    init(_ color: Color) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        self.init(Double(r), Double(g), Double(b), Double(a))
    }
}

@MainActor
final class ToolbarSettingsModel: ObservableObject {
    @Published var preferences = ToolbarPreferences()
    @Published var writable = false
    @Published var status = "Werkzeugeinstellungen werden geladen …"
    private let store: ToolbarPreferenceStore
    private var revision = 0
    private var pending: Task<Void, Never>?
    private var debounce: Task<Void, Never>?
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []

    init(root: URL) {
        store = ToolbarPreferenceStore(root: root)
        Task {
            do {
                let (loaded, recovered) = try await store.load()
                preferences = loaded; writable = true
                status = recovered ? "Vorherige Werkzeugeinstellungen geladen" : ""
            } catch { status = error.localizedDescription }
        }
        for name in [UIApplication.didEnterBackgroundNotification, UIApplication.willTerminateNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.writePending() }
            })
        }
    }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    /// Sliders and the colour picker change the preferences many times per
    /// second: the file is written 0.5 s after the last change, at once by
    /// `flush()` (closing, backups) and when the app goes to the background.
    func save() {
        guard writable else { return }
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.write()
        }
    }
    private func writePending() { if debounce != nil { write() } }
    private func write() {
        debounce?.cancel(); debounce = nil
        guard writable else { return }
        revision += 1
        let savingRevision = revision
        let snapshot = preferences
        // The write often starts as the app goes to the background (pending
        // debounce): iPadOS keeps it running until it is done or time is up.
        let background = SettingsWriteTask()
        // Do not cancel a dispatched write; actor revisions protect arrival order.
        pending = Task {
            defer { background.end() }
            do {
                try await store.save(snapshot, revision: savingRevision)
                if revision == savingRevision { status = "" }
            } catch {
                if revision == savingRevision { status = "Werkzeugeinstellungen nicht gespeichert: \(error.localizedDescription)" }
            }
        }
    }
    func flush() async -> Bool {
        guard writable else { return false }
        write()
        while true {
            let flushingRevision = revision
            await pending?.value
            if flushingRevision == revision { return status.isEmpty }
        }
    }
}

/// Background execution time for one settings write (as `BackgroundSaveTask`
/// in EditorModel); ended by the write or by iPadOS when time runs out.
@MainActor
private final class SettingsWriteTask {
    private var identifier = UIBackgroundTaskIdentifier.invalid
    init() {
        identifier = UIApplication.shared.beginBackgroundTask(withName: "noty-tool-settings") { [weak self] in self?.end() }
    }
    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
