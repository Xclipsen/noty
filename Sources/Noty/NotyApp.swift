import SwiftUI

@main
@MainActor
struct NotyApp: App {
    @StateObject private var workspaces = WorkspaceAppModel()
    var body: some Scene {
        WindowGroup {
            WorkspaceLibraryHost(workspaces: workspaces).id(workspaces.root.path).preferredColorScheme(.dark)
        }
    }
}
