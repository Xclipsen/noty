import Foundation
import NotebookCore

/// Container-independent UserDefaults keys (see `StableSettingsKey`). The
/// defaults plist lives inside the app container and moves with it on an
/// update; only the absolute path formerly embedded in the keys did not.
enum StableDefaults {
    static func scope(_ root: URL) -> String { StableSettingsKey.scope(of: root, documents: URL.documentsDirectory) }

    /// Stable key for `root`. When it has no value yet, the value of a matching
    /// old absolute-path key (`<legacyPrefix><path><suffix>` from any earlier
    /// container) is copied over. Old keys stay untouched as a fallback.
    static func key(_ name: String, root: URL, suffix: String = "", legacyPrefix: String,
                    pick: ([Any]) -> Any? = { $0.first }) -> String {
        let scope = scope(root)
        let key = StableSettingsKey.key(name, scope: scope, suffix: suffix)
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: key) == nil else { return key }
        let legacy = StableSettingsKey.legacyKeys(in: defaults.dictionaryRepresentation().keys, prefix: legacyPrefix, suffix: suffix, scope: scope)
        let values = legacy.compactMap { defaults.object(forKey: $0) }
        if !values.isEmpty, let value = pick(values) { defaults.set(value, forKey: key) }
        return key
    }

    /// For date values: keep the most recent one.
    static func newestDate(_ values: [Any]) -> Any? { values.compactMap { $0 as? Date }.max() }
}
