import XCTest
@testable import NotebookCore

/// A law name takes one bracket with its abbreviation ("Einkommensteuergesetz
/// (EStG)") and nothing deeper: the scan of any text needs no stack and time
/// proportional to its length.
final class LawCitationNestingTests: XCTestCase {
    private let entries = [
        LawEntry(id: "estg", abbr: "EStG", name: "Einkommensteuergesetz", category: "", kind: "law", aliases: nil, currentVersion: "v", versions: []),
        LawEntry(id: "ao", abbr: "AO", name: "Abgabenordnung", category: "", kind: "law", aliases: nil, currentVersion: "v", versions: []),
    ]

    private func texts(_ text: String) -> [String] {
        LawCitationScanner(entries: entries).citations(in: text).map(\.text)
    }

    /// Seconds for one scan of `count` times "AO (", the best of `runs`.
    private func seconds(_ count: Int, runs: Int = 3) -> (seconds: Double, citations: Int) {
        let scanner = LawCitationScanner(entries: entries)
        let text = String(repeating: "AO (", count: count)
        var best = Double.infinity, found = 0
        for _ in 0..<runs {
            let start = Date()
            found = scanner.citations(in: text).count
            best = min(best, Date().timeIntervalSince(start))
        }
        return (best, found)
    }

    func testOneBracketBelongsToTheLaw() {
        XCTAssertEqual(texts("§ 15 Einkommensteuergesetz (EStG) gilt"), ["§ 15 Einkommensteuergesetz (EStG)"])
        XCTAssertEqual(texts("Einkommensteuergesetz (EStG) § 35a"), ["Einkommensteuergesetz (EStG) § 35a"])
        XCTAssertEqual(texts("§ 15 Einkommensteuergesetz (AO)"), [])
    }

    func testBracketInsideTheBracketIsNotPartOfTheLaw() {
        // Only the law itself: the bracket does not name it in the one accepted form.
        XCTAssertEqual(texts("§ 15 Einkommensteuergesetz (Einkommensteuergesetz (EStG)) gilt"), ["§ 15 Einkommensteuergesetz"])
        XCTAssertEqual(texts("§ 15 EStG (EStG (EStG (EStG))) gilt"), ["§ 15 EStG"])
    }

    /// The nesting bound, without a crash when it is wrong: the lookahead of
    /// one law must not reach the end of a nested run.
    private func nestingIsBounded() -> Bool {
        texts("§ 15 EStG (EStG (EStG)) gilt") == ["§ 15 EStG"]
    }

    func testNestedLawBracketsNeedNoStack() throws {
        // Both guards keep a wrong limit a failed assertion: without them the
        // thread below would overflow its stack or run for hours.
        guard nestingIsBounded() else { return XCTFail("law brackets nest, the deep scan would overflow the stack") }
        let probe = seconds(2_000, runs: 1)
        XCTAssertEqual(probe.citations, 0)
        guard probe.seconds < 1 else { return XCTFail("2000 nested brackets took \(probe.seconds) s, the long scan is skipped") }

        let scanner = LawCitationScanner(entries: entries)
        let text = String(repeating: "AO (", count: 100_000)
        let done = expectation(description: "scan")
        let result = Result()
        let thread = Thread {
            result.set(scanner.citations(in: text).count)
            done.fulfill()
        }
        thread.stackSize = 512 * 1024
        thread.start()
        wait(for: [done], timeout: 60)
        XCTAssertEqual(result.value, 0)
    }

    func testNestedLawBracketsScanInLinearTime() {
        guard nestingIsBounded() else { return XCTFail("law brackets nest, the timing run is skipped") }
        let small = seconds(10_000), large = seconds(40_000)
        XCTAssertEqual(small.citations, 0)
        XCTAssertEqual(large.citations, 0)
        // Four times the text: about four times the time, sixteen when quadratic.
        XCTAssertLessThan(large.seconds, max(small.seconds, 0.002) * 8, "more than linear: \(small.seconds) s, \(large.seconds) s")
    }

    func testTextWithManyLawsAndBracketsIsScannedOnce() {
        // Closed brackets, open brackets and citations mixed: every citation is
        // still found, each once.
        let unit = "AO (EStG) (AO (§ 4 EStG und AO ("
        let found = texts(String(repeating: unit, count: 5_000))
        XCTAssertEqual(found.count, 5_000)
        XCTAssertEqual(Set(found), ["§ 4 EStG"])
    }

    private final class Result: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Int?
        var value: Int? { lock.lock(); defer { lock.unlock() }; return stored }
        func set(_ value: Int) { lock.lock(); stored = value; lock.unlock() }
    }
}
