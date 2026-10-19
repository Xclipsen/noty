import SwiftUI

@main
@MainActor
struct NotyApp: App {
    @StateObject private var workspaces = WorkspaceAppModel()
    init() {
        // Read once at launch, off unless chosen; the settings toggle documents that it applies after a restart.
        if UserDefaults.standard.object(forKey: AppSettingsKey.hangProbe) as? Bool ?? false { HangProbe.install() }
    }
    var body: some Scene {
        WindowGroup {
            WorkspaceLibraryHost(workspaces: workspaces).id(workspaces.root.path).preferredColorScheme(.dark)
        }
    }
}
