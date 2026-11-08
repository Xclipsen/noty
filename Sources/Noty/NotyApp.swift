import SwiftUI
import UIKit
import CryptoKit
import NotebookCore

@main
@MainActor
struct NotyApp: App {
    /// APNs token for the push service (docs/PUSH.md).
    @UIApplicationDelegateAdaptor(NotyAppDelegate.self) private var appDelegate
    @StateObject private var laws = LawLibraryModel()
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var workspaces = WorkspaceAppModel()
    init() {
        // Inline image originals are hashed once per session (content addresses);
        // CryptoKit instead of the portable Swift SHA-256, checked against test vectors first.
        NotebookCore.SHA256.installAccelerated { data in Array(CryptoKit.SHA256.hash(data: data)) }
        // File and archive verification (assets, backups, restores) streams up to
        // 500 MB per notebook; the portable digest reaches only a few MB/s in debug builds.
        NotebookCore.SHA256.installAcceleratedStreaming { CryptoKitStream() }
        // Read once at launch, off unless chosen; the settings toggle documents that it applies after a restart.
        if UserDefaults.standard.object(forKey: AppSettingsKey.hangProbe) as? Bool ?? false { HangProbe.install() }
        // Calendar notifications: taps route to the calendar (set before launch finishes).
        CalendarNotificationHub.shared.install()
    }
    var body: some Scene {
        WindowGroup {
            WorkspaceLibraryHost(workspaces: workspaces).id(workspaces.root.path).modifier(AccentTint()).preferredColorScheme(.dark)
                .environmentObject(laws)
                .environmentObject(laws.panel)
                .task {
                    await laws.start()
                    while !Task.isCancelled {
                        do { try await Task.sleep(for: .seconds(45)) } catch { return }
                        if laws.sceneActive { await laws.tick() }
                    }
                }
                .onChange(of: scenePhase, initial: true) { _, phase in laws.sceneActive = phase == .active; if phase == .active { TapDiagnostics.shared.refresh(); Task { await laws.tick() } } }
                .alert("Gesetzessammlung", isPresented: Binding(get: { laws.error != nil && laws.inlineErrorPages == 0 }, set: { if !$0 { laws.error = nil } })) {
                    Button("OK") { laws.error = nil }
                } message: { Text(laws.error ?? "") }
        }
        .commands { NotyCommands() }
        // Mitteilungen: background refresh through the shown area's calendar model, or nothing.
        .backgroundTask(.appRefresh(CalendarNotificationHub.refreshIdentifier)) { await CalendarNotificationHub.runBackgroundRefresh() }
    }
}

/// Only for the push service (docs/PUSH.md): start, and the APNs token or its failure.
@MainActor
final class NotyAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        CalendarPushClient.shared.launched()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        CalendarPushClient.shared.received(token: deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        CalendarPushClient.shared.failed(error)
    }
}

/// CryptoKit's SHA-256 behind Core's streaming protocol (checked by Core
/// against its own implementation before it is used).
private final class CryptoKitStream: SHA256StreamingHasher {
    private var hasher = CryptoKit.SHA256()
    func update(_ bytes: UnsafeRawBufferPointer) { hasher.update(bufferPointer: bytes) }
    func finalize() -> [UInt8] { Array(hasher.finalize()) }
}
