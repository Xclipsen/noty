import XCTest
@testable import NotebookCore

/// The stored WebDAV password belongs to one server (scheme, host, port); it
/// must never be reused for an address that points somewhere else.
final class ExternalBackupServerTests: XCTestCase {
    private func same(_ stored: String, _ entered: String) -> Bool { ExternalBackupPolicy.sameWebDAVServer(stored, entered) }

    func testSameHostWithAnotherPathKeepsThePassword() {
        XCTAssertTrue(same("https://cloud.example.org/dav/noty/", "https://cloud.example.org/remote.php/dav/files/la/Backups/"))
        XCTAssertTrue(same("https://cloud.example.org/dav/noty/", "  https://cloud.example.org/dav/noty  "))
    }
    func testHostCaseAndExplicitDefaultPortAreTheSameServer() {
        XCTAssertTrue(same("https://cloud.example.org/dav/", "https://Cloud.Example.ORG/dav/"))
        XCTAssertTrue(same("https://cloud.example.org/dav/", "HTTPS://cloud.example.org:443/dav/"))
        XCTAssertTrue(same("https://cloud.example.org:8443/dav/", "https://CLOUD.example.org:8443/other/"))
    }
    func testAnotherHostNeedsThePasswordAgain() {
        XCTAssertFalse(same("https://cloud.example.org/dav/", "https://evil.example.net/dav/"))
        XCTAssertFalse(same("https://cloud.example.org/dav/", "https://sub.cloud.example.org/dav/"))
        XCTAssertFalse(same("https://cloud.example.org/dav/", "https://cloud.example.org.evil.example.net/dav/"))
        // Only the host behind the user part receives the request.
        XCTAssertFalse(same("https://cloud.example.org/dav/", "https://cloud.example.org@evil.example.net/dav/"))
    }
    func testAnotherPortNeedsThePasswordAgain() {
        XCTAssertFalse(same("https://cloud.example.org/dav/", "https://cloud.example.org:8443/dav/"))
        XCTAssertFalse(same("https://cloud.example.org:8443/dav/", "https://cloud.example.org/dav/"))
        XCTAssertFalse(same("https://cloud.example.org:8443/dav/", "https://cloud.example.org:8444/dav/"))
    }
    func testAnotherSchemeNeedsThePasswordAgain() {
        XCTAssertFalse(same("https://cloud.example.org/dav/", "http://cloud.example.org/dav/"))
        XCTAssertFalse(same("https://cloud.example.org/dav/", "http://cloud.example.org:443/dav/"))
    }
    func testMissingOrUnusableAddressNeverMatches() {
        XCTAssertFalse(same("", "https://cloud.example.org/dav/"))
        XCTAssertFalse(same("https://cloud.example.org/dav/", ""))
        XCTAssertFalse(same("", ""))
        XCTAssertFalse(same("cloud.example.org/dav/", "cloud.example.org/dav/"))
        XCTAssertFalse(same("ftp://cloud.example.org/dav/", "ftp://cloud.example.org/dav/"))
    }
    func testNormalisedServerNamesSchemeHostAndPort() {
        XCTAssertEqual(ExternalBackupPolicy.webDAVServer("https://Cloud.Example.org/dav/x/"), "https://cloud.example.org:443")
        XCTAssertEqual(ExternalBackupPolicy.webDAVServer("https://cloud.example.org:8443"), "https://cloud.example.org:8443")
        XCTAssertNil(ExternalBackupPolicy.webDAVServer("https:///dav/"))
    }
}
