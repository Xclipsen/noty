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
        // File and archive verification (assets, backups, restores) streams up to
        // 500 MB per notebook; the portable digest reaches only a few MB/s in debug builds.
        NotebookCore.SHA256.installAcceleratedStreaming { CryptoKitStream() }
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

/// CryptoKit's SHA-256 behind Core's streaming protocol (checked by Core
/// against its own implementation before it is used).
private final class CryptoKitStream: SHA256StreamingHasher {
    private var hasher = CryptoKit.SHA256()
    func update(_ bytes: UnsafeRawBufferPointer) { hasher.update(bufferPointer: bytes) }
    func finalize() -> [UInt8] { Array(hasher.finalize()) }
}
