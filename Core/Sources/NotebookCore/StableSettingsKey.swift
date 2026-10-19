import Foundation

/// UserDefaults keys that stay valid when iOS moves the app data container.
///
/// Earlier builds embedded absolute paths such as
/// `/var/mobile/Containers/Data/Application/<UUID>/Documents/Noty` in their keys.
/// iOS may assign a new container path on an in-place app update while keeping
/// the container contents (including `Library/Preferences`), so those keys no
/// longer matched after an update. Stable keys use the path relative to the
/// app's Documents directory instead ("Noty", "NotyWorkspaces/Areas/<id>/Data").
public enum StableSettingsKey {
    /// Path of `root` relative to `documents`, without leading/trailing slashes.
    public static func scope(of root: URL, documents: URL) -> String {
        if let relative = relative(root.standardizedFileURL.path, to: documents.standardizedFileURL.path) { return relative }
        if let relative = relative(root.resolvingSymlinksInPath().path, to: documents.resolvingSymlinksInPath().path) { return relative }
        let path = root.standardizedFileURL.path
        return legacyScope(absolutePath: path) ?? path
    }

    /// Scope of an absolute path stored by an earlier build: everything after the
    /// container's first `/Documents/` component. Independent of the container
    /// UUID and of a `/private` prefix.
    public static func legacyScope(absolutePath: String) -> String? {
        guard absolutePath.hasPrefix("/"), let range = absolutePath.range(of: "/Documents/") else { return nil }
        let rest = trimmed(String(absolutePath[range.upperBound...]))
        return rest.isEmpty ? nil : rest
    }

    /// `noty.v2.<name>.<scope><suffix>`; the `v2` namespace never collides with
    /// the old path-based (`noty.<name>./…`) or legacy name-only keys.
    public static func key(_ name: String, scope: String, suffix: String = "") -> String {
        "noty.v2.\(name).\(scope)\(suffix)"
    }

    /// Old keys of the form `<legacyPrefix><absolute path><suffix>` whose path
    /// belongs to `scope` in any (earlier) container. Sorted for determinism.
    public static func legacyKeys<S: Sequence>(in keys: S, prefix: String, suffix: String = "", scope: String) -> [String]
    where S.Element == String {
        keys.filter { key in
            guard key.hasPrefix(prefix), key.hasSuffix(suffix), key.count > prefix.count + suffix.count else { return false }
            let path = String(key.dropFirst(prefix.count).dropLast(suffix.count))
            return legacyScope(absolutePath: path) == scope
        }.sorted()
    }

    private static func relative(_ path: String, to base: String) -> String? {
        let base = base.hasSuffix("/") ? String(base.dropLast()) : base
        guard !base.isEmpty, path.hasPrefix(base + "/") else { return nil }
        let rest = trimmed(String(path.dropFirst(base.count + 1)))
        return rest.isEmpty ? nil : rest
    }
    private static func trimmed(_ value: String) -> String {
        var value = Substring(value)
        while value.hasPrefix("/") { value = value.dropFirst() }
        while value.hasSuffix("/") { value = value.dropLast() }
        return String(value)
    }
}

extension ExternalBackupPolicy {
    /// Among policies found under old container-path keys, prefer a valid one
    /// with the most recent activity; nil if none is valid.
    public static func preferredMigration(_ candidates: [ExternalBackupPolicy]) -> ExternalBackupPolicy? {
        let valid = candidates.filter { (try? $0.validate()) != nil }
        func activity(_ policy: ExternalBackupPolicy) -> Date {
            max(policy.lastSuccess ?? .distantPast, policy.lastAttempt ?? .distantPast)
        }
        return valid.max { lhs, rhs in
            if activity(lhs) != activity(rhs) { return activity(lhs) < activity(rhs) }
            // Without activity, a configured target beats a fresh default.
            return lhs.target == .disabled && rhs.target != .disabled
        }
    }
}
