import Foundation

/// Process-wide single-writer reservation per notebook package (its
/// directory). Every writer of an existing package holds a claim for as long
/// as it may commit: an editor model for its whole lifetime (from before it
/// loads until its last commit and asset GC), the library while it appends a
/// shared file to a closed notebook. A second claim on the same package is
/// refused, so two writers can never build revisions on the same manifest.
/// `RevisionStore.save` additionally refuses a commit whose manifest changed
/// on disk since its own last read or write (`RevisionError.concurrentChange`).
///
/// Keys are standardized, symlink-resolved paths; the claim is released by
/// `release()` or when the claim object goes away.
public final class PackageWriteLock: @unchecked Sendable {
    public static let shared = PackageWriteLock()

    private let lock = NSLock()
    private var held: [String: UUID] = [:]

    public init() {}

    public final class Claim: @unchecked Sendable {
        public let directory: URL
        let key: String
        let id = UUID()
        private let owner: PackageWriteLock
        private let state = NSLock()
        private var released = false

        fileprivate init(directory: URL, key: String, owner: PackageWriteLock) {
            self.directory = directory; self.key = key; self.owner = owner
        }

        public var isReleased: Bool { state.lock(); defer { state.unlock() }; return released }

        /// Idempotent.
        public func release() {
            state.lock()
            let first = !released
            released = true
            state.unlock()
            if first { owner.release(self) }
        }

        deinit { release() }
    }

    public static func key(_ directory: URL) -> String {
        var path = directory.standardizedFileURL.resolvingSymlinksInPath().path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// nil while another claim holds this package.
    public func claim(_ directory: URL) -> Claim? {
        let key = Self.key(directory)
        lock.lock(); defer { lock.unlock() }
        guard held[key] == nil else { return nil }
        let claim = Claim(directory: directory, key: key, owner: self)
        held[key] = claim.id
        return claim
    }

    /// Waits (bounded) for a running writer, e.g. an append that is just
    /// committing, instead of failing at once. A cancelled waiter gives up
    /// with nil at once (a cancelled `Task.sleep` returns immediately, the
    /// loop would otherwise spin until the deadline).
    public func claim(_ directory: URL, waitingUpTo seconds: Double) async -> Claim? {
        let deadline = Date().addingTimeInterval(seconds)
        while true {
            if let claim = claim(directory) { return claim }
            guard Date() < deadline, !Task.isCancelled else { return nil }
            do { try await Task.sleep(nanoseconds: 50_000_000) } catch { return nil }
        }
    }

    public func isHeld(_ directory: URL) -> Bool {
        let key = Self.key(directory)
        lock.lock(); defer { lock.unlock() }
        return held[key] != nil
    }

    fileprivate func release(_ claim: Claim) {
        lock.lock(); defer { lock.unlock() }
        if held[claim.key] == claim.id { held[claim.key] = nil }
    }
}
