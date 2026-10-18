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

    init(root: URL) {
        store = ToolbarPreferenceStore(root: root)
        Task {
            do {
                let (loaded, recovered) = try await store.load()
                preferences = loaded; writable = true
                status = recovered ? "Vorherige Werkzeugeinstellungen geladen" : ""
            } catch { status = error.localizedDescription }
        }
    }
    func save() {
        guard writable else { return }
        revision += 1
        let savingRevision = revision
        let snapshot = preferences
        // Do not cancel a dispatched write; actor revisions protect arrival order.
        pending = Task {
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
        save()
        while true {
            let flushingRevision = revision
            await pending?.value
            if flushingRevision == revision { return status.isEmpty }
        }
    }
}
