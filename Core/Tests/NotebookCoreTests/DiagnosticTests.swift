import XCTest
@testable import NotebookCore

final class DiagnosticTests: XCTestCase {
    private let app = DiagnosticAppInfo(channel: "dev", bundleID: "de.la.noty.dev", version: "1.0", build: "140", commit: "abc1234")
    private let device = DiagnosticDeviceInfo(model: "iPad16,3", os: "iPadOS 18.1")
    private var reporter: DiagnosticReporter { DiagnosticReporter(app: app, device: device, launchID: "L1") }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("diag-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    // MARK: Format

    func testReportRoundTripsAndRejectsOtherVersions() throws {
        let report = reporter.slow("save", milliseconds: 1412, threshold: 1000, values: ["pages": 34], phase: "running",
                                   breadcrumbs: [DiagnosticBreadcrumb(t: 1, e: "notebook.open", v: ["pages": 34])], at: 1_700_000_000_000)
        let data = try report.encoded()
        XCTAssertEqual(try DiagnosticReport.decode(data), report)
        XCTAssertEqual(report.formatVersion, 1)
        XCTAssertEqual(report.summary, "Langsam: Speichern 1412 ms (Schwelle 1000 ms)")
        XCTAssertEqual(report.signature, "slow:save")
        XCTAssertEqual(report.details["pages"], "34")

        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        // Fixed top-level keys the server and diag_report.py rely on.
        for key in ["formatVersion", "id", "kind", "createdAt", "app", "device", "summary", "signature", "details", "callStack", "breadcrumbs"] {
            XCTAssertNotNil(object[key], key)
        }
        object["formatVersion"] = 2
        let future = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try DiagnosticReport.decode(future)) { XCTAssertEqual($0 as? DiagnosticFormatError, .unsupportedVersion(2)) }
    }

    func testDeepStacksAreTrimmedAndNamedAsStackOverflow() {
        let recursion = (0..<3000).map { DiagnosticFrame(image: "Noty", offset: UInt64(0x1000 + ($0 % 3) * 8)) }
        var facts = DiagnosticReporter.MetricKitFacts(kind: .crash)
        facts.exceptionType = 1; facts.signal = 11
        let report = reporter.metricKit(facts, session: nil, breadcrumbs: [], at: 5)
        XCTAssertEqual(DiagnosticAnalysis.pattern(for: report), .badAccess)
        var deep = report; deep.callStack = recursion; deep.summary = ""; deep.signature = ""
        let finalized = deep.finalized()
        XCTAssertEqual(finalized.callStack.count, 448)
        XCTAssertEqual(finalized.details["stackDepth"], "3000")
        XCTAssertEqual(DiagnosticAnalysis.pattern(for: finalized), .stackOverflow)
        XCTAssertTrue(finalized.summary.contains("Stapelüberlauf"))
        XCTAssertTrue(finalized.signature.hasPrefix("crash:stackOverflow|Noty+0x1000"))
    }

    func testKnownPatterns() {
        var facts = DiagnosticReporter.MetricKitFacts(kind: .crash)
        facts.terminationReason = "Namespace SPRINGBOARD, Code 0x8badf00d"
        XCTAssertEqual(DiagnosticAnalysis.pattern(for: reporter.metricKit(facts, session: nil, breadcrumbs: [], at: 1)), .watchdog)
        facts = .init(kind: .crash); facts.exceptionType = 6; facts.signal = 5
        XCTAssertEqual(DiagnosticAnalysis.pattern(for: reporter.metricKit(facts, session: nil, breadcrumbs: [], at: 1)), .swiftTrap)
        facts = .init(kind: .crash); facts.signal = 6; facts.objcExceptionName = "NSInvalidArgumentException"
        XCTAssertEqual(DiagnosticAnalysis.pattern(for: reporter.metricKit(facts, session: nil, breadcrumbs: [], at: 1)), .objcException)
        facts = .init(kind: .crash); facts.exceptionType = 1; facts.signal = 11; facts.stackGuard = true
        XCTAssertEqual(DiagnosticAnalysis.pattern(for: reporter.metricKit(facts, session: nil, breadcrumbs: [], at: 1)), .stackOverflow)
        facts = .init(kind: .crash); facts.exceptionType = 1; facts.signal = 11
        XCTAssertEqual(DiagnosticAnalysis.pattern(for: reporter.metricKit(facts, session: nil, breadcrumbs: [], at: 1)), .badAccess)
    }

    func testMetricKitCallStackTreeIsFlattenedInnermostFirst() throws {
        let json = """
        {"callStackTree":{"callStackPerThread":true,"callStacks":[
          {"threadAttributed":false,"callStackRootFrames":[{"binaryName":"libsystem_kernel.dylib","offsetIntoBinaryTextSegment":10,"sampleCount":1,"binaryUUID":"K"}]},
          {"threadAttributed":true,"callStackRootFrames":[{"binaryName":"Noty","offsetIntoBinaryTextSegment":4096,"sampleCount":1,"binaryUUID":"A",
            "subFrames":[{"binaryName":"SwiftUI","offsetIntoBinaryTextSegment":200,"sampleCount":1,"binaryUUID":"S",
              "subFrames":[{"binaryName":"Noty","offsetIntoBinaryTextSegment":8192,"sampleCount":1,"binaryUUID":"A"}]}]}]}]},
         "diagnosticMetaData":{"exceptionType":1,"signal":11,"exceptionReason":{"composedMessage":"Heft Geheimtitel","className":"NSException"}}}
        """
        let data = Data(json.utf8)
        let threads = MetricKitCallStack.threads(fromJSON: data)
        XCTAssertEqual(threads.count, 2)
        XCTAssertEqual(MetricKitCallStack.mainStack(fromJSON: data).map(\.label), ["Noty+0x1000", "SwiftUI+0xc8", "Noty+0x2000"])

        var facts = DiagnosticReporter.MetricKitFacts(kind: .crash)
        facts.callStackJSON = data; facts.payloadJSON = data; facts.exceptionType = 1; facts.signal = 11
        let report = reporter.metricKit(facts, session: nil, breadcrumbs: [], at: 1)
        XCTAssertEqual(report.signature, "crash:badAccess|Noty+0x1000>Noty+0x2000")
        XCTAssertTrue(report.summary.contains("bei Noty+0x1000"), report.summary)
        let payload = try XCTUnwrap(report.payload)
        XCTAssertFalse(payload.contains("Geheimtitel"))
        XCTAssertTrue(payload.contains("NSException"))
    }

    /// The shared fixture that the server's tests validate as well
    /// (diagnostics/test_server.py): Swift and Python agree on format 1.
    func testSharedFixtureDecodesAndMatchesTheRules() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("diagnostics/fixtures/report-v1.json")
        let report = try DiagnosticReport.decode(Data(contentsOf: url))
        XCTAssertEqual(report.kind, .crash)
        XCTAssertEqual(DiagnosticAnalysis.pattern(for: report), .stackOverflow)
        var rebuilt = report; rebuilt.summary = ""; rebuilt.signature = ""
        rebuilt = rebuilt.finalized()
        XCTAssertEqual(rebuilt.summary, report.summary)
        XCTAssertEqual(rebuilt.signature, report.signature)
        XCTAssertEqual(try DiagnosticReport.decode(report.encoded()), report)
    }

    // MARK: Journal and sessions

    func testJournalKeepsTheLast200AndPersistsEveryEvent() throws {
        let directory = try temporaryDirectory()
        let journal = DiagnosticJournal(launchID: "L1", directory: directory)
        for index in 0..<250 { journal.record("page.switch", ["index": index]) }
        let recent = journal.recent()
        XCTAssertEqual(recent.count, 200)
        XCTAssertEqual(recent.first?.v?["index"], 50)
        XCTAssertEqual(recent.last?.v?["index"], 249)

        // A crash in mid-write leaves a broken last line; it is skipped.
        let url = try XCTUnwrap(journal.fileURL)
        let handle = try FileHandle(forWritingTo: url); _ = try handle.seekToEnd(); try handle.write(contentsOf: Data("{\"t\":1,".utf8)); try handle.close()
        let loaded = DiagnosticJournal.load(url)
        XCTAssertEqual(loaded.count, 200)
        XCTAssertEqual(loaded.last?.v?["index"], 249)
        XCTAssertEqual(DiagnosticJournal.load(url, until: loaded[100].t).last?.t, loaded[100].t)
    }

    func testJournalCompactsLongRuns() throws {
        let journal = DiagnosticJournal(launchID: "L2", directory: try temporaryDirectory())
        for index in 0..<(DiagnosticJournal.compactAfter + 10) { journal.record("tick", ["i": index]) }
        let lines = try String(contentsOf: XCTUnwrap(journal.fileURL), encoding: .utf8).split(separator: "\n")
        XCTAssertLessThan(lines.count, 300)
        XCTAssertEqual(DiagnosticJournal.load(try XCTUnwrap(journal.fileURL)).last?.v?["i"], DiagnosticJournal.compactAfter + 9)
    }

    func testSessionLogFindsAbnormalExitsAndTheRunOfAReport() throws {
        var log = DiagnosticSessionLog()
        XCTAssertNil(log.begin(launchID: "P", build: "140", at: 50).abnormal)
        XCTAssertNil(log.begin(launchID: "A", build: "140", at: 100).abnormal,
                     "a run that never got past launch and was never active (prewarm, install) is no abnormal exit")
        log.update(launchID: "A", phase: "library", state: .active, at: 150)
        log.update(launchID: "A", state: .background, at: 200)
        XCTAssertNil(log.begin(launchID: "B", build: "140", at: 300).abnormal, "a run that went to the background ended normally")
        log.update(launchID: "B", phase: "lawWindow", state: .active, at: 350)
        let next = log.begin(launchID: "C", build: "141", at: 400)
        XCTAssertEqual(next.abnormal?.launchID, "B")
        XCTAssertEqual(next.abnormal?.phase, "lawWindow")
        XCTAssertEqual(log.session(at: 320)?.launchID, "B")
        XCTAssertEqual(log.session(at: 120)?.launchID, "A")
        // MetricKit at launch C: never C itself, even for a payload ending after C began.
        XCTAssertEqual(log.session(before: 450, excluding: "C")?.launchID, "B")
        XCTAssertEqual(log.session(before: 320, excluding: "C")?.launchID, "B")
        XCTAssertEqual(log.session(before: 120, excluding: "C")?.launchID, "A")
        log.update(launchID: "C", phase: "library", at: 410)
        XCTAssertEqual(log.begin(launchID: "D", build: "141", at: 420).abnormal?.launchID, "C",
                       "launching past the launch phase without becoming active is abnormal")
        for index in 0..<5 { _ = log.begin(launchID: "X\(index)", build: "141", at: 500 + Int64(index)) }
        XCTAssertEqual(log.sessions.count, DiagnosticSessionLog.keptSessions)

        let url = try temporaryDirectory().appendingPathComponent("sessions.json")
        try log.save(url)
        XCTAssertEqual(DiagnosticSessionLog.load(url), log)
    }

    // MARK: Outbox

    func testOutboxMovesSentReportsAndLimitsNoisyKinds() throws {
        let outbox = DiagnosticOutbox(directory: try temporaryDirectory())
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let time = DiagnosticReport.milliseconds(now)
        XCTAssertTrue(try outbox.add(reporter.test("test.crash", phase: nil, breadcrumbs: [], at: time), now: now))
        XCTAssertEqual(outbox.pending().count, 1)
        try outbox.markSent(XCTUnwrap(outbox.pending().first), now: now)
        XCTAssertEqual(outbox.pending().count, 0)
        XCTAssertEqual(outbox.recent().map(\.sent), [true])

        for index in 0..<(DiagnosticOutbox.dailyLimit + 5) {
            _ = try outbox.add(reporter.slow("save", milliseconds: 1500 + index, threshold: 1000, phase: nil, breadcrumbs: [], at: time + Int64(index)), now: now)
        }
        XCTAssertEqual(outbox.pending().count, DiagnosticOutbox.dailyLimit)
        XCTAssertFalse(try outbox.add(reporter.slow("save", milliseconds: 9000, threshold: 1000, phase: nil, breadcrumbs: [], at: time + 999), now: now))
        // Crashes are never held back by the daily limit.
        XCTAssertTrue(try outbox.add(reporter.metricKit(.init(kind: .crash), session: nil, breadcrumbs: [], at: time + 1000), now: now))

        // After 90 days a report is gone.
        let later = now.addingTimeInterval(91 * 86_400)
        _ = try outbox.add(reporter.test("test.hang", phase: nil, breadcrumbs: [], at: DiagnosticReport.milliseconds(later)), now: later)
        XCTAssertEqual(outbox.recent(limit: 200).count, 1)
    }

    /// In noty nothing is sent: many noisy reports must not push out a crash
    /// or an abnormal exit when the 50 pending are full.
    func testOutboxPrunesNoisyKindsBeforeCrashes() throws {
        let outbox = DiagnosticOutbox(directory: try temporaryDirectory())
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let time = DiagnosticReport.milliseconds(start)
        XCTAssertTrue(try outbox.add(reporter.metricKit(.init(kind: .crash), session: nil, breadcrumbs: [], at: time), now: start))
        // Spread over days so that the daily limit does not hold them back.
        for index in 0..<(DiagnosticOutbox.maximumPending + 30) {
            let now = start.addingTimeInterval(Double(index) * 3_600)
            _ = try outbox.add(reporter.slow("save", milliseconds: 1500, threshold: 1000, phase: nil, breadcrumbs: [],
                                             at: DiagnosticReport.milliseconds(now)), now: now)
        }
        let pending = outbox.pending()
        XCTAssertEqual(pending.count, DiagnosticOutbox.maximumPending)
        XCTAssertEqual(pending.filter { $0.report.kind == .crash }.count, 1)
        XCTAssertEqual(DiagnosticOutbox.parse(pending[0].url.lastPathComponent)?.kind, .crash)
    }

    func testThrottleAllowsOneReportPerOperationAndHour() {
        var throttle = DiagnosticThrottle()
        XCTAssertTrue(throttle.allow("save", at: 0))
        XCTAssertFalse(throttle.allow("save", at: 1_000))
        XCTAssertTrue(throttle.allow("search", at: 1_000))
        XCTAssertTrue(throttle.allow("save", at: 3_600_001))
        XCTAssertEqual(DiagnosticThresholds.hangNoteMilliseconds, 250)
        XCTAssertEqual(DiagnosticThresholds.milliseconds(for: "save"), 1_000)
        XCTAssertEqual(DiagnosticThresholds.milliseconds(for: "notebook.open"), 2_000)
    }

    // MARK: Privacy

    func testPrivacyFilterDropsAnythingButFixedNamesAndCodes() {
        XCTAssertTrue(DiagnosticPrivacy.isSafeName("law.window.shown"))
        XCTAssertFalse(DiagnosticPrivacy.isSafeName("Mathe Klausur"))
        XCTAssertFalse(DiagnosticPrivacy.isSafeName("Übung"))
        XCTAssertFalse(DiagnosticPrivacy.isSafeName(String(repeating: "a", count: 49)))
        XCTAssertNil(DiagnosticPrivacy.safeDetail("/var/mobile/Containers/Data/Mathe.noty"))
        XCTAssertNil(DiagnosticPrivacy.safeDetail("Notizen zu § 433 BGB"))
        XCTAssertEqual(DiagnosticPrivacy.safeDetail("Namespace SPRINGBOARD, Code 0x8badf00d"), "Namespace SPRINGBOARD, Code 0x8badf00d")

        let crumbs = DiagnosticPrivacy.sanitized(breadcrumbs: [
            DiagnosticBreadcrumb(t: 1, e: "notebook.open", v: ["pages": 3, "Geheimer Titel": 1]),
            DiagnosticBreadcrumb(t: 2, e: "Mein Heft öffnen"),
        ])
        XCTAssertEqual(crumbs, [DiagnosticBreadcrumb(t: 1, e: "notebook.open", v: ["pages": 3])])
        XCTAssertEqual(DiagnosticPrivacy.sanitized(details: ["path": "/private/x", "Titel hier": "1", "code": "640"]),
                       ["path": "?", "code": "640"])
    }

    /// A notebook with a recognisable title and text goes through the paths
    /// the app reports from: saving, a failing load (whose error carries a
    /// path with the title), events with its numbers. Neither the report nor
    /// the run's journal file may contain any of it.
    func testNoNotebookContentReachesReportsOrTheJournal() throws {
        let secretTitle = "Geheimtitel Abitur Mathe"
        let secretText = "Streng private Notiz 4711"
        let root = try temporaryDirectory()
        var notebook = try Notebook.blank(title: secretTitle, appearance: NotebookAppearance())
        notebook.pages[0].textBoxes = [TextBox(x: 40, y: 80, width: 200, height: 30, text: secretText, style: TextBoxStyle(color: .black))]
        let package = root.appendingPathComponent("\(secretTitle).noty", isDirectory: true)
        let store = RevisionStore(directory: package)
        try store.save(notebook)

        let journal = DiagnosticJournal(launchID: "L-privacy", directory: root.appendingPathComponent("journal"))
        journal.record("notebook.open", ["pages": notebook.pages.count, "ms": 412])
        journal.record("save", ["ms": 37, "revision": 1])

        var caught: Error?
        do { _ = try Data(contentsOf: package.appendingPathComponent("\(secretText).missing")) } catch { caught = error }
        let failure = reporter.failure("save", error: try XCTUnwrap(caught), phase: "notebook", breadcrumbs: journal.recent(), at: 10)
        struct TitledError: Error { var title: String }
        let custom = reporter.failure("backup", error: TitledError(title: secretTitle), phase: nil, breadcrumbs: journal.recent(), at: 11)
        let slow = reporter.slow("notebook.open", milliseconds: 2500, threshold: 2000, values: ["pages": 1], phase: "notebook",
                                 breadcrumbs: journal.recent(), at: 12)
        let exit = reporter.abnormalExit(.init(launchID: "L-privacy", build: "140", startedAt: 1, phase: "notebook", state: .active, updatedAt: 2),
                                         breadcrumbs: DiagnosticJournal.load(try XCTUnwrap(journal.fileURL)), at: 13)

        var texts = [try String(contentsOf: XCTUnwrap(journal.fileURL), encoding: .utf8)]
        for report in [failure, custom, slow, exit] { texts.append(String(decoding: try report.encoded(), as: UTF8.self)) }
        for text in texts {
            for secret in [secretTitle, secretText, "Geheimtitel", "4711", root.path, package.lastPathComponent] {
                XCTAssertFalse(text.contains(secret), "\(secret) in \(text)")
            }
        }
        XCTAssertEqual(failure.details["operation"], "save")
        XCTAssertNotNil(Int(failure.details["errorCode"] ?? ""))
        XCTAssertEqual(failure.breadcrumbs.map(\.e), ["notebook.open", "save"])
    }
}
