import Foundation
import XCTest
@testable import NotebookCore

final class StableSettingsKeyTests: XCTestCase {
    private let oldContainer = "/var/mobile/Containers/Data/Application/11111111-1111-1111-1111-111111111111"
    private let newContainer = "/var/mobile/Containers/Data/Application/22222222-2222-2222-2222-222222222222"
    private let area = "NotyWorkspaces/Areas/33333333-3333-3333-3333-333333333333/Data"

    func testScopeIsRelativeToDocumentsAndIndependentOfContainer() {
        let documents = URL(fileURLWithPath: newContainer + "/Documents", isDirectory: true)
        XCTAssertEqual(StableSettingsKey.scope(of: documents.appendingPathComponent("Noty", isDirectory: true), documents: documents), "Noty")
        XCTAssertEqual(StableSettingsKey.scope(of: documents.appendingPathComponent(area, isDirectory: true), documents: documents), area)
        XCTAssertEqual(StableSettingsKey.scope(of: documents.appendingPathComponent("Noty/Library/Documents/X"), documents: documents), "Noty/Library/Documents/X")
        // Same relative location in another container yields the same key.
        let older = URL(fileURLWithPath: oldContainer + "/Documents", isDirectory: true)
        XCTAssertEqual(StableSettingsKey.key("externalBackup", scope: StableSettingsKey.scope(of: older.appendingPathComponent(area), documents: older)),
                       StableSettingsKey.key("externalBackup", scope: StableSettingsKey.scope(of: documents.appendingPathComponent(area), documents: documents)))
        // A root outside Documents falls back to the documented heuristic, then the full path.
        XCTAssertEqual(StableSettingsKey.scope(of: URL(fileURLWithPath: "/private" + oldContainer + "/Documents/Noty"), documents: documents), "Noty")
        XCTAssertEqual(StableSettingsKey.scope(of: URL(fileURLWithPath: "/tmp/x"), documents: documents), "/tmp/x")
    }

    func testLegacyScopeUsesFirstDocumentsComponent() {
        XCTAssertEqual(StableSettingsKey.legacyScope(absolutePath: oldContainer + "/Documents/Noty"), "Noty")
        XCTAssertEqual(StableSettingsKey.legacyScope(absolutePath: "/private" + oldContainer + "/Documents/Noty/"), "Noty")
        XCTAssertEqual(StableSettingsKey.legacyScope(absolutePath: oldContainer + "/Documents/Noty/Library/Documents/ABC"), "Noty/Library/Documents/ABC")
        XCTAssertNil(StableSettingsKey.legacyScope(absolutePath: "Noty"))
        XCTAssertNil(StableSettingsKey.legacyScope(absolutePath: oldContainer + "/Documents/"))
    }

    func testLegacyKeyMatchingSelectsOnlyTheSameScope() {
        let keys = [
            "noty.externalBackup." + oldContainer + "/Documents/Noty",
            "noty.externalBackup./private" + newContainer + "/Documents/Noty",
            "noty.externalBackup." + oldContainer + "/Documents/" + area,
            "noty.libraryBackup." + oldContainer + "/Documents/Noty",
            "noty.v2.externalBackup.Noty",
            "noty.externalBackup.Noty"
        ]
        XCTAssertEqual(StableSettingsKey.legacyKeys(in: keys, prefix: "noty.externalBackup.", scope: "Noty"),
                       [keys[0], keys[1]].sorted())
        XCTAssertEqual(StableSettingsKey.legacyKeys(in: keys, prefix: "noty.externalBackup.", scope: area), [keys[2]])
        XCTAssertEqual(StableSettingsKey.legacyKeys(in: keys, prefix: "noty.libraryBackup.", scope: "Noty"), [keys[3]])
    }

    func testLegacyPageKeysMatchPathAndNotebookSuffix() {
        let notebook = UUID().uuidString, other = UUID().uuidString
        let docScope = "Noty/Library/Documents/\(notebook)"
        let keys = [
            "noty.page." + oldContainer + "/Documents/" + docScope + "." + notebook,
            "noty.page." + oldContainer + "/Documents/Noty." + notebook,
            "noty.page." + oldContainer + "/Documents/" + docScope + "." + other,
            "noty.page." + notebook
        ]
        XCTAssertEqual(StableSettingsKey.legacyKeys(in: keys, prefix: "noty.page.", suffix: "." + notebook, scope: docScope), [keys[0]])
        XCTAssertEqual(StableSettingsKey.legacyKeys(in: keys, prefix: "noty.page.", suffix: "." + notebook, scope: "Noty"), [keys[1]])
        XCTAssertNotEqual(StableSettingsKey.key("page", scope: "Noty", suffix: "." + notebook), keys[3])
    }

    func testPolicyMigrationPrefersMostRecentValidActivity() throws {
        var folder = ExternalBackupPolicy(); folder.target = .folder; folder.folderBookmark = Data([1]); folder.folderName = "Noty-Backups"
        folder.lastAttempt = Date(timeIntervalSince1970: 1_700_000_000)
        let fresh = ExternalBackupPolicy()
        var invalid = ExternalBackupPolicy(); invalid.target = .folder; invalid.lastSuccess = Date()
        XCTAssertEqual(ExternalBackupPolicy.preferredMigration([fresh, folder, invalid]), folder)
        var disabledLater = folder; disabledLater.target = .disabled; disabledLater.lastAttempt = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(ExternalBackupPolicy.preferredMigration([folder, disabledLater]), disabledLater)
        var unused = fresh; unused.target = .folder; unused.folderBookmark = Data([2])
        XCTAssertEqual(ExternalBackupPolicy.preferredMigration([fresh, unused]), unused)
        XCTAssertNil(ExternalBackupPolicy.preferredMigration([invalid]))
        // The optional display name is backward compatible with stored policies.
        var legacyJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(folder)) as! [String: Any]
        legacyJSON.removeValue(forKey: "folderName")
        let decoded = try JSONDecoder().decode(ExternalBackupPolicy.self, from: JSONSerialization.data(withJSONObject: legacyJSON))
        XCTAssertNil(decoded.folderName); XCTAssertEqual(decoded.folderBookmark, folder.folderBookmark)
    }
}
