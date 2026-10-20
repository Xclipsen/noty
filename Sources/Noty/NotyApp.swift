import SwiftUI
import CryptoKit
import NotebookCore

@main
@MainActor
struct NotyApp: App {
    @StateObject private var workspaces = WorkspaceAppModel()
    init() {
        // Inline image originals are hashed once per session (content addresses);
        // CryptoKit instead of the portable Swift SHA-256, checked against test vectors first.
        NotebookCore.SHA256.installAccelerated { data in Array(CryptoKit.SHA256.hash(data: data)) }
        // Read once at launch, off unless chosen; the settings toggle documents that it applies after a restart.
        if UserDefaults.standard.object(forKey: AppSettingsKey.hangProbe) as? Bool ?? false { HangProbe.install() }
    }
    var body: some Scene {
        WindowGroup {
            WorkspaceLibraryHost(workspaces: workspaces).id(workspaces.root.path).preferredColorScheme(.dark)
        }
        .commands { NotyCommands() }
    }
}
