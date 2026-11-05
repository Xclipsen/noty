import SwiftUI
import NotebookCore

extension InkColor {
    var color: Color { Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha) }
    init(_ color: Color) { self.init(UIColor(color)) }
    /// Every UI colour that becomes stored ink goes through here. The system
    /// colour picker delivers Display P3/extended sRGB; `getRed` alone returns
    /// components beyond 0…1 for them, which preferences, shapes and text
    /// refuse (blocked tool settings, saving and backups). Such a colour is
    /// converted to (non-extended) sRGB and clamped (`InkColor.clamped`);
    /// in-range colours keep exactly the components they had before.
    init(_ color: UIColor) {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1
        let direct = color.getRed(&r, green: &g, blue: &b, alpha: &a)
        if !direct || ![r, g, b, a].allSatisfy({ (0...1).contains($0) }),
           let space = CGColorSpace(name: CGColorSpace.sRGB),
           let converted = color.cgColor.converted(to: space, intent: .relativeColorimetric, options: nil),
           let components = converted.components, components.count == 4 {
            (r, g, b, a) = (components[0], components[1], components[2], components[3])
        }
        self = InkColor(Double(r), Double(g), Double(b), Double(a)).clamped
    }
}

@MainActor
final class ToolbarSettingsModel: ObservableObject {
    @Published var preferences = ToolbarPreferences()
    @Published var writable = false
    @Published var status = "Werkzeugeinstellungen werden geladen …"
    private let store: ToolbarPreferenceStore
    private var revision = 0
    /// Nothing can be written then, and nothing waits to be: no reason to
    /// refuse closing or a backup.
    private var loadFailed = false
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
            } catch { status = error.localizedDescription; loadFailed = true }
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
        guard writable else { return loadFailed }
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
