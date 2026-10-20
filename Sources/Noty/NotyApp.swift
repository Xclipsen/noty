import SwiftUI

@main
@MainActor
struct NotyApp: App {
    @StateObject private var laws = LawLibraryModel()
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var workspaces = WorkspaceAppModel()
    init() {
        // Read once at launch, off unless chosen; the settings toggle documents that it applies after a restart.
        if UserDefaults.standard.object(forKey: AppSettingsKey.hangProbe) as? Bool ?? false { HangProbe.install() }
    }
    var body: some Scene {
        WindowGroup {
            WorkspaceLibraryHost(workspaces: workspaces).id(workspaces.root.path).preferredColorScheme(.dark)
                .environmentObject(laws)
                .task {
                    await laws.start()
                    while !Task.isCancelled {
                        do { try await Task.sleep(for: .seconds(45)) } catch { return }
                        if laws.sceneActive { await laws.tick() }
                    }
                }
                .onChange(of: scenePhase, initial: true) { _, phase in laws.sceneActive = phase == .active; if phase == .active { Task { await laws.tick() } } }
                .alert("Gesetzessammlung / Konto", isPresented: Binding(get: { laws.error != nil }, set: { if !$0 { laws.error = nil } })) {
                    Button("OK") { laws.error = nil }
                } message: { Text(laws.error ?? "") }
        }
        .commands { NotyCommands() }
    }
}
