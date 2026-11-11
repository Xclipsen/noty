"""Tests für den Empfangsdienst: python3 -B -m unittest diagnostics/test_server.py"""
import json
import os
import sys
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import server  # noqa: E402

KEY = "k" * 32


def report(**changes):
    base = {
        "formatVersion": 1, "id": str(uuid.uuid4()).upper(), "kind": "slow", "createdAt": 1_800_000_000_000,
        "app": {"channel": "dev", "bundleID": "de.la.noty.dev", "version": "1.0", "build": "140", "commit": "abc1234"},
        "device": {"model": "iPad16,3", "os": "iPadOS 18.1"}, "summary": "Langsam: Speichern 1412 ms (Schwelle 1000 ms)",
        "signature": "slow:save", "details": {"operation": "save", "durationMs": "1412"},
        "callStack": [{"image": "Noty", "offset": 4096}],
        "breadcrumbs": [{"t": 1, "e": "notebook.open", "v": {"pages": 34}}],
    }
    base.update(changes)
    return base


class ServerCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.keys = root / "keys"
        self.keys.write_text("# Schlüssel\n" + KEY + "\n")
        self.store = server.Store(root / "reports", 90)
        self.limiter = server.RateLimiter(5, 600, 100)
        self.http = server.serve(self.store, str(self.keys), 0, self.limiter)
        self.port = self.http.server_address[1]
        threading.Thread(target=self.http.serve_forever, daemon=True).start()

    def tearDown(self):
        self.http.shutdown()
        self.http.server_close()
        self.tmp.cleanup()

    def post(self, body, key=KEY, ip="203.0.113.1", raw=False):
        data = body if raw else json.dumps(body).encode()
        request = urllib.request.Request(f"http://127.0.0.1:{self.port}/v1/report", data=data, method="POST",
                                         headers={"Content-Type": "application/json", "X-Noty-Key": key, "X-Real-IP": ip})
        try:
            with urllib.request.urlopen(request) as response:
                return response.status
        except urllib.error.HTTPError as error:
            return error.code

    def stored(self):
        return sorted(p.relative_to(self.store.root).as_posix() for p in self.store.root.glob("*/*/*.json"))


class ServerTests(ServerCase):
    def test_accepts_valid_report_sorted_by_app_and_build(self):
        item = report()
        self.assertEqual(self.post(item), 201)
        files = self.stored()
        self.assertEqual(len(files), 1)
        self.assertTrue(files[0].startswith("dev/140/20270115T080000-slow-"), files[0])
        self.assertEqual(json.loads((self.store.root / files[0]).read_text())["id"], item["id"])
        self.assertEqual((self.store.root / files[0]).stat().st_mode & 0o007, 0, "never world-readable")
        # Same report again: not stored twice.
        self.assertEqual(self.post(item), 409)
        self.assertEqual(len(self.stored()), 1)

    def test_accepts_the_shared_swift_fixture(self):
        fixture = Path(__file__).resolve().parent / "fixtures" / "report-v1.json"
        self.assertEqual(self.post(fixture.read_bytes(), raw=True), 201)

    def test_rejects_missing_or_wrong_key(self):
        self.assertEqual(self.post(report(), key=""), 401)
        self.assertEqual(self.post(report(), key="x" * 32), 401)
        self.assertEqual(self.stored(), [])

    def test_rejects_reports_over_one_megabyte(self):
        big = report(payload="a" * (server.MAX_BYTES + 10))
        self.assertEqual(self.post(big), 413)

    def test_rejects_wrong_form_and_free_text(self):
        # Rejected reports count against the rate limit too; enough room here.
        self.limiter.per_ip = 100
        self.assertEqual(self.post(b"{kaputt", raw=True), 400)
        self.assertEqual(self.post(report(formatVersion=2)), 400)
        self.assertEqual(self.post(report(kind="unbekannt")), 400)
        self.assertEqual(self.post(report(app={"channel": "fremd", "build": "1"})), 400)
        self.assertEqual(self.post(report(breadcrumbs=[{"t": 1, "e": "Mein Heft Mathe"}])), 400)
        self.assertEqual(self.post(report(breadcrumbs=[{"t": 1, "e": "x", "v": {"Titel hier": 1}}])), 400)
        self.assertEqual(self.post(report(details={"path": "/var/mobile/Mathe.noty"})), 400)
        self.assertEqual(self.stored(), [])

    def test_rate_limit_per_sender(self):
        statuses = [self.post(report(), ip="198.51.100.7") for _ in range(7)]
        self.assertEqual(statuses[:5], [201] * 5)
        self.assertEqual(statuses[5:], [429, 429])
        self.assertEqual(self.post(report(), ip="198.51.100.8"), 201)

    def test_health_and_unknown_paths(self):
        with urllib.request.urlopen(f"http://127.0.0.1:{self.port}/v1/health") as response:
            self.assertEqual(response.status, 200)
        request = urllib.request.Request(f"http://127.0.0.1:{self.port}/v1/other", data=b"{}", method="POST",
                                         headers={"X-Noty-Key": KEY})
        with self.assertRaises(urllib.error.HTTPError) as caught:
            urllib.request.urlopen(request)
        self.assertEqual(caught.exception.code, 404)

    def test_prune_after_retention(self):
        self.assertEqual(self.post(report()), 201)
        path = self.store.root / self.stored()[0]
        old = time.time() - 91 * 86_400
        os.utime(path, (old, old))
        self.assertEqual(self.store.prune(), 1)
        self.assertEqual(self.stored(), [])
        self.assertEqual(list(self.store.root.iterdir()), [])


FIXTURES = Path(__file__).resolve().parent / "fixtures"
T0 = 1_800_000_000_000
NOTY_UUID = "4C4C4483-5555-3144-A1D4-85A5F72E486E"


def swift_report(kind, summary, signature, *, details=None, stack=None, phase="notebook", **changes):
    """A report the way DiagnosticReporter and DiagnosticAnalysis write it."""
    item = {
        "formatVersion": 1, "id": str(uuid.uuid4()).upper(), "kind": kind, "createdAt": T0 + 5000, "occurredAt": T0 + 2000,
        "app": {"channel": "dev", "bundleID": "de.la.noty.dev", "version": "1.0", "build": "149", "commit": "040b1f4"},
        "device": {"model": "iPad17,1", "os": "iPadOS 26.1"}, "launchID": str(uuid.uuid4()).upper(),
        "summary": summary, "signature": signature, "details": details or {}, "callStack": stack or [],
        "breadcrumbs": [{"t": T0, "e": "notebook.open", "v": {"ms": 412, "pages": 34}}, {"t": T0 + 1000, "e": "phase.notebook"}],
    }
    if phase is not None:
        item["launchPhase"] = phase
    item.update(changes)
    return item


def reporter_fixture():
    """One report per kind as DiagnosticReporter really builds them: written and compared by the Core test
    DiagnosticTests.testKindFixtureIsWhatTheReporterBuilds."""
    return json.loads((FIXTURES / "reports-v1-kinds.json").read_text(encoding="utf-8"))


def swift_reports():
    """Further values the current app produces (docs/DIAGNOSE.md, DiagnosticReporter, DiagnosticsMetricKit)."""
    app_stack = [{"image": "libsystem_kernel.dylib", "offset": 0x6818}, {"image": "libc++.1.dylib", "offset": 0xD648},
                 {"image": "?", "offset": 2 ** 64 - 1}, {"image": "Noty", "offset": 0x10, "uuid": NOTY_UUID}]
    trap = [{"image": "libswiftCore.dylib", "offset": 0x1234, "uuid": NOTY_UUID.replace("4C4C", "5D5D")},
            {"image": "Noty", "offset": 0x1A91AC, "uuid": NOTY_UUID}, {"image": "Noty", "offset": 0x30}, {"image": "Noty", "offset": 0x40}]
    return [
        swift_report("slow", "Langsam: Heft öffnen 2400 ms (Schwelle 2000 ms)", "slow:notebook.open",
                     details={"operation": "notebook.open", "durationMs": "2400", "thresholdMs": "2000", "pages": "34"}),
        swift_report("failure", "Speichern fehlgeschlagen (NotebookCore.NotebookStoreError -1)", "failure:save",
                     details={"operation": "save", "errorDomain": "NotebookCore.NotebookStoreError", "errorCode": "-1"}),
        swift_report("failure", "App-Abgleich (Spiegel) fehlgeschlagen (NSCocoaErrorDomain 640)", "failure:appSync.mirror",
                     details={"operation": "appSync.mirror", "errorDomain": "NSCocoaErrorDomain", "errorCode": "640"}),
        swift_report("appHang", "Hänger · 3006 ms · bei Noty+0x10", "appHang|Noty+0x10",
                     details={"durationMs": "3006", "test": "1"}, stack=app_stack, phase="running"),
        swift_report("abnormalExit", "Unerwartet beendet · in Phase lawWindow", "abnormalExit",
                     details={"state": "active", "build": "148", "reportingBuild": "149"}, phase="lawWindow"),
        swift_report("crash", "Absturz · EXC_BREAKPOINT · SIGTRAP · Swift-Laufzeitfalle (fatalError, erzwungenes Entpacken, "
                     "Index außerhalb, Überlauf) · bei Noty+0x1a91ac", "crash:swiftTrap|Noty+0x1a91ac>Noty+0x30>Noty+0x40",
                     details={"source": "metrickit", "exceptionType": "6", "exceptionTypeName": "EXC_BREAKPOINT",
                              "exceptionCode": "1", "signal": "5", "signalName": "SIGTRAP", "build": "149"},
                     stack=trap, payload='{"diagnosticMetaData":{"appBuildVersion":"149","exceptionType":6}}'),
        swift_report("crash", "Absturz · NSRangeException · SIGABRT · Objective-C-Ausnahme · bei Noty+0x1a91ac",
                     "crash:objcException|Noty+0x1a91ac>Noty+0x30>Noty+0x40",
                     details={"source": "metrickit", "exceptionType": "10", "exceptionTypeName": "EXC_CRASH", "signal": "6",
                              "signalName": "SIGABRT", "objcException": "NSRangeException", "exceptionName": "NSRangeException"},
                     stack=trap),
        swift_report("crash", "Absturz · EXC_CRASH · SIGKILL · Watchdog-Abbruch: der Hauptthread blockierte zu lange",
                     "crash:watchdog", phase="launch",
                     details={"source": "metrickit", "exceptionType": "10", "exceptionTypeName": "EXC_CRASH", "signal": "9",
                              "signalName": "SIGKILL", "terminationReason": "Namespace SPRINGBOARD, Code 0x8badf00d"}),
        swift_report("hang", "Hänger (System) · 2100 ms · bei Noty+0x10", "hang|Noty+0x10",
                     details={"source": "metrickit", "durationMs": "2100", "build": "149"}, stack=app_stack),
        swift_report("cpu", "CPU-Last", "cpu", details={"source": "metrickit", "durationMs": "91000"}),
        swift_report("diskWrite", "Schreiblast", "diskWrite", details={"source": "metrickit"}),
        swift_report("launch", "Langsamer Start · bei Noty+0x10", "launch|Noty+0x10",
                     details={"source": "metrickit", "durationMs": "5200"}, stack=app_stack),
        swift_report("metrics", "Tageswerte", "metrics", phase=None,
                     details={"source": "metrickit", "from": str(T0 - 86_400_000), "to": str(T0), "build": "149",
                              "launchFirstDrawMsMean": "820", "launchResumeMsMean": "120", "hangMsMean": "450",
                              "hangCount": "3", "scrollHitchMsPerS": "2.10", "memoryPeakMB": "612", "cpuSeconds": "310",
                              "exitForegroundNormal": "4", "exitForegroundMemory": "0", "exitForegroundWatchdog": "1",
                              "exitForegroundBadAccess": "0", "exitForegroundIllegalInstruction": "0",
                              "exitForegroundAbnormal": "0", "exitBackgroundMemory": "2",
                              "exitBackgroundMemoryPressure": "7", "exitBackgroundWatchdog": "0",
                              "exitBackgroundSuspendedLockedFile": "0"}, payload='{"timeStampEnd":"2027-01-15 00:00:00"}'),
        swift_report("memory", "Speicherlimit · 2× vom System wegen Speicherverbrauch beendet", "memory:memoryLimit",
                     phase=None, details={"source": "metrickit", "memoryExits": "2", "build": "?"}),
        swift_report("test", "Test", "test", details={"test": "test.report"}),
        # Before Diagnostics.start and from a local build: no device facts, no commit.
        swift_report("test", "Test", "test", details={"test": "test.report"}, device={"model": "?", "os": "?"},
                     app={"channel": "calendar", "bundleID": "?", "version": "?", "build": "150", "commit": ""}),
        swift_report("slow", "Langsam: Speichern 1412 ms (Schwelle 1000 ms)", "slow:save",
                     details={"operation": "save", "durationMs": "1412", "thresholdMs": "1000"},
                     app={"channel": "stable", "bundleID": "XTL-AB12CD34EF.de.la.noty.prototype", "version": "1.0",
                          "build": "149", "commit": "040b1f4-dirty"}),
    ]


def maximal_report():
    """The app's limits at once: 512 frames (DiagnosticReport.finalized keeps up to 512), 200 breadcrumbs
    (DiagnosticJournal.capacity) and a MetricKit payload of 600 000 characters, nested as deep as its stack."""
    frame = '{"binaryName":"Noty","binaryUUID":"' + NOTY_UUID + '","offsetIntoBinaryTextSegment":4096,"sampleCount":1,"subFrames":['
    payload = '{"callStackTree":{"callStackPerThread":true,"callStacks":[{"callStackRootFrames":[' + frame * 448 + "]}" * 448 + '],"threadAttributed":true}]},"pad":"'
    payload += "x" * (server.MAX_PAYLOAD - len(payload) - 2) + '"}'
    stack = [{"image": "SwiftUICore", "offset": 0x99 + n, "uuid": NOTY_UUID.replace("4C4C", "5D5D")} for n in range(8)]
    stack += [{"image": "Noty", "offset": 0x1A91AC, "uuid": NOTY_UUID}] * 440
    stack += [{"image": "UIKitCore", "offset": 2 ** 40 + n, "uuid": NOTY_UUID.replace("4C4C", "6E6E")} for n in range(64)]
    crumbs = [{"t": T0 - (200 - n) * 250, "e": "page.switch", "v": {"index": n, "ms": 9_000_000_000_000, "pages": -1}}
              for n in range(200)]
    return swift_report(
        "crash", "Absturz · EXC_BAD_ACCESS · SIGSEGV · Stapelüberlauf (meist beim View-Aufbau: tief verschachtelte "
        "SwiftUI-Typen oder Rekursion) · bei Noty+0x1a91ac", "crash:stackOverflow|Noty+0x1a91ac>Noty+0x1a91ac>Noty+0x1a91ac",
        details={"source": "metrickit", "exceptionType": "1", "exceptionTypeName": "EXC_BAD_ACCESS", "exceptionCode": "2",
                 "signal": "11", "signalName": "SIGSEGV", "stackGuard": "1", "stackDepth": "2048", "build": "149",
                 "terminationReason": "Namespace SIGNAL, Code 11 Segmentation fault: 11"},
        stack=stack, breadcrumbs=crumbs, payload=payload, phase="lawWindow")


CONTROLS = {"ESC": "\x1b", "BEL": "\x07", "LF": "\n", "CR": "\r", "NUL": "\x00", "TAB": "\t", "DEL": "\x7f", "C1": "\x9b"}


def changed(item, path, value):
    """A copy of the report with the field at `path` replaced (list indexes allowed)."""
    copy = json.loads(json.dumps(item))
    target = copy
    for key in path[:-1]:
        target = target[key]
    target[path[-1]] = value
    return copy


class ValidationTests(unittest.TestCase):
    """The form check alone: what a holder of the build key could try (the key is in every published app)."""

    def setUp(self):
        self.base = swift_report("crash", "Absturz · EXC_BAD_ACCESS · SIGSEGV · bei Noty+0x10", "crash:badAccess|Noty+0x10",
                                 details={"signal": "11", "signalName": "SIGSEGV"},
                                 stack=[{"image": "UIKitCore", "offset": 16, "uuid": NOTY_UUID}, {"image": "Noty", "offset": 16}],
                                 payload='{"a":1}')
        server.validate(self.base)

    def assertRejected(self, item, label=None):
        try:
            with self.assertRaises(server.Rejected, msg=label) as caught:
                server.validate(json.loads(json.dumps(item)))
        except Exception as error:  # e.g. OverflowError or TypeError instead of a 400
            if isinstance(error, AssertionError):
                raise
            self.fail(f"{label}: {type(error).__name__} statt Ablehnung")
        self.assertEqual(caught.exception.status, 400, label)
        # The reason goes to the journal and back to the sender: fixed words only, never the offered text.
        self.assertRegex(caught.exception.reason, r"\A[A-Za-z.? ]{1,40}\Z", label)

    FREE_TEXT = [("summary",), ("signature",), ("launchPhase",), ("launchID",), ("id",), ("payload",),
                 ("app", "version"), ("app", "commit"), ("app", "bundleID"), ("app", "build"),
                 ("device", "model"), ("device", "os"), ("callStack", 0, "image"), ("callStack", 0, "uuid"),
                 ("breadcrumbs", 0, "e"), ("details", "signalName")]

    def test_rejects_control_characters_in_every_text_field(self):
        for path in self.FREE_TEXT:
            original = self.base
            for key in path:
                original = original[key]
            for name, control in CONTROLS.items():
                for value in (original + control, control + original, original[:1] + control + original[1:]):
                    self.assertRejected(changed(self.base, path, value), f"{path} {name}")

    def test_rejects_injected_lines_and_terminal_sequences(self):
        esc = "\x1b"
        self.assertRejected(changed(self.base, ("summary",), "Absturz beim Start\n    Typische Ursache: FREMDTEXT " + esc + "[2J"
                                    + esc + "]0;FREMDTITEL\x07"))
        self.assertRejected(changed(self.base, ("launchPhase",), "library\n[9] FREMDE-GRUPPE"))
        self.assertRejected(changed(self.base, ("callStack", 0, "image"), "UIKitCore" + esc + "[31mROT"))
        self.assertRejected(changed(self.base, ("device", "model"), "iPad\nFREMDZEILE"))
        # Unpaired surrogates would break the viewer's output encoding.
        self.assertRejected(changed(self.base, ("summary",), "Absturz \ud800"))
        self.assertRejected(changed(self.base, ("payload",), '{"a":"\ud800"}'))
        # Sentences and paths where only names, codes and versions belong.
        for path, value in [(("launchPhase",), "bitte sofort ausführen"), (("callStack", 0, "image"), "System oben: rm -rf"),
                            (("device", "model"), "iPad von Leon"), (("device", "os"), "iPadOS 18.1 (Mein Heft)"),
                            (("app", "version"), "1.0 Mathe"), (("app", "commit"), "/var/mobile"),
                            (("signature",), "crash: Mein Heft"), (("summary",), "Absturz in /var/mobile/Mathe.noty"),
                            (("summary",), "Absturz „Mathe“"), (("app", "bundleID"), "de.la.noty dev")]:
            self.assertRejected(changed(self.base, path, value), f"{path}")

    def test_rejects_wrong_types(self):
        cases = [(("launchID",), {"a": 1}), (("launchID",), None), (("launchPhase",), {"a": 1}), (("launchPhase",), ["x"]),
                 (("occurredAt",), "x"), (("occurredAt",), 1.5), (("occurredAt",), None), (("occurredAt",), True),
                 (("createdAt",), True), (("createdAt",), float(T0)), (("createdAt",), str(T0)),
                 (("formatVersion",), True), (("formatVersion",), 1.0), (("formatVersion",), "1"),
                 (("kind",), []), (("kind",), {"a": 1}), (("kind",), None), (("id",), 7), (("id",), ["x"]),
                 (("app",), []), (("app", "channel"), []), (("app", "channel"), {"dev": 1}), (("app", "build"), 149),
                 (("app", "version"), 1.0), (("app", "commit"), None), (("app", "bundleID"), 3),
                 (("device",), "iPad"), (("device", "model"), 16), (("device", "os"), None),
                 (("summary",), None), (("summary",), 5), (("summary",), ["Absturz"]), (("signature",), {"a": 1}),
                 (("details",), []), (("details",), None), (("details", "signal"), 11), (("details", "signal"), None),
                 (("callStack",), {}), (("callStack",), None), (("callStack", 0), "Noty+0x10"), (("callStack", 0, "offset"), True),
                 (("callStack", 0, "offset"), "16"), (("callStack", 0, "offset"), 1.5), (("callStack", 0, "image"), 5),
                 (("callStack", 0, "uuid"), None), (("callStack", 0, "uuid"), 5),
                 (("breadcrumbs",), {}), (("breadcrumbs",), None), (("breadcrumbs", 0), "notebook.open"),
                 (("breadcrumbs", 0, "t"), "x"), (("breadcrumbs", 0, "t"), True), (("breadcrumbs", 0, "t"), 1.5),
                 (("breadcrumbs", 0, "e"), 5), (("breadcrumbs", 0, "v"), [1]), (("breadcrumbs", 0, "v"), None),
                 (("breadcrumbs", 0, "v", "ms"), "412"), (("breadcrumbs", 0, "v", "ms"), True),
                 (("breadcrumbs", 0, "v", "ms"), 1.5), (("payload",), {"a": 1}), (("payload",), None)]
        for path, value in cases:
            self.assertRejected(changed(self.base, path, value), f"{path} = {value!r}")
        for whole in ([], "x", 1, None, [self.base]):
            self.assertRejected(whole, repr(whole)[:20])

    def test_rejects_a_trailing_newline_in_pattern_fields(self):
        for path in [("id",), ("launchID",), ("launchPhase",), ("signature",), ("summary",), ("app", "build"),
                     ("app", "channel"), ("app", "version"), ("app", "commit"), ("app", "bundleID"), ("device", "model"),
                     ("device", "os"), ("callStack", 0, "image"), ("callStack", 0, "uuid"), ("breadcrumbs", 0, "e"),
                     ("details", "signalName"), ("kind",)]:
            value = self.base
            for key in path:
                value = value[key]
            self.assertRejected(changed(self.base, path, value + "\n"), f"{path}")
        for field, key in ((("details",), "signal\n"), (("breadcrumbs", 0, "v"), "ms\n")):
            item = changed(self.base, field + (key,), "1" if field == ("details",) else 1)
            self.assertRejected(item, f"{field} key")

    def test_rejects_times_and_numbers_out_of_range(self):
        for path in [("createdAt",), ("occurredAt",)]:
            for value in (10 ** 400, 10 ** 15, server.MAX_MS, -1, 0, -10 ** 400, server.MIN_MS - 1, T0 // 1000):
                self.assertRejected(changed(self.base, path, value), f"{path} = {str(value)[:12]}")
            for value in (server.MIN_MS, server.MAX_MS - 1):
                server.validate(changed(self.base, path, value))
        for path, values in [(("breadcrumbs", 0, "t"), (10 ** 400, server.MAX_MS, -1)),
                             (("breadcrumbs", 0, "v", "ms"), (10 ** 400, 2 ** 63, -2 ** 63 - 1)),
                             (("callStack", 0, "offset"), (10 ** 400, 2 ** 64, -1))]:
            for value in values:
                self.assertRejected(changed(self.base, path, value), f"{path} = {str(value)[:12]}")
        server.validate(changed(self.base, ("breadcrumbs", 0, "v", "ms"), -2 ** 63))
        server.validate(changed(self.base, ("breadcrumbs", 0, "v", "ms"), 2 ** 63 - 1))
        server.validate(changed(self.base, ("callStack", 0, "offset"), 2 ** 64 - 1))

    def test_rejects_unknown_and_missing_fields_at_every_level(self):
        for path in [("note",), ("app", "name"), ("device", "name"), ("device", "udid"), ("callStack", 0, "symbol"),
                     ("breadcrumbs", 0, "text"), ("Summary",)]:
            self.assertRejected(changed(self.base, path, "x"), f"unbekannt {path}")
        for path in [("formatVersion",), ("id",), ("kind",), ("createdAt",), ("app",), ("device",), ("summary",),
                     ("signature",), ("details",), ("callStack",), ("breadcrumbs",), ("app", "channel"), ("app", "bundleID"),
                     ("app", "version"), ("app", "build"), ("app", "commit"), ("device", "model"), ("device", "os"),
                     ("callStack", 0, "image"), ("callStack", 0, "offset"), ("breadcrumbs", 0, "t"), ("breadcrumbs", 0, "e")]:
            item = changed(self.base, path, None)
            target = item
            for key in path[:-1]:
                target = target[key]
            del target[path[-1]]
            self.assertRejected(item, f"fehlt {path}")
        # Optional in the format (Swift optionals are left out, never null).
        item = json.loads(json.dumps(self.base))
        for key in ("occurredAt", "launchID", "launchPhase", "payload"):
            del item[key]
        del item["callStack"][0]["uuid"], item["breadcrumbs"][0]["v"]
        server.validate(item)

    def test_rejects_more_than_the_app_ever_sends(self):
        crumb, frame = self.base["breadcrumbs"][0], self.base["callStack"][0]
        self.assertRejected(changed(self.base, ("breadcrumbs",), [crumb] * (server.MAX_BREADCRUMBS + 1)))
        self.assertRejected(changed(self.base, ("callStack",), [frame] * (server.MAX_FRAMES + 1)))
        self.assertRejected(changed(self.base, ("details",), {f"k{n}": "1" for n in range(server.MAX_DETAILS + 1)}))
        self.assertRejected(changed(self.base, ("breadcrumbs", 0, "v"), {f"k{n}": 1 for n in range(server.MAX_VALUES + 1)}))
        self.assertRejected(changed(self.base, ("payload",), "x" * (server.MAX_PAYLOAD + 1)))
        self.assertRejected(changed(self.base, ("summary",), "Absturz " * 100))
        self.assertRejected(changed(self.base, ("signature",), "crash|" + "Noty+0x10>" * 80))
        self.assertRejected(changed(self.base, ("details", "signalName"), "S" * 161))
        self.assertRejected(changed(self.base, ("callStack", 0, "image"), "A" * 129))
        self.assertRejected(changed(self.base, ("summary",), ""))
        self.assertRejected(changed(self.base, ("callStack", 0, "image"), ""))
        server.validate(changed(self.base, ("payload",), "x" * server.MAX_PAYLOAD))

    def test_accepts_what_the_app_produces(self):
        server.validate(json.loads((FIXTURES / "report-v1.json").read_text(encoding="utf-8")))
        built = reporter_fixture()
        self.assertEqual(sorted({item["kind"] for item in built}), sorted(server.KINDS))
        for item in built + swift_reports() + [maximal_report()]:
            try:
                server.validate(json.loads(json.dumps(item)))
            except server.Rejected as rejected:
                self.fail(f"{item['kind']} „{item['summary'][:40]}“ abgelehnt: {rejected.reason}")
        self.assertEqual(sorted({item["kind"] for item in swift_reports()}), sorted(server.KINDS))


class HardenedServerTests(ServerCase):
    """The same over HTTP: nothing hostile is stored and no request ends in an unhandled exception."""

    def test_stores_a_maximal_report_unchanged(self):
        item = maximal_report()
        body = json.dumps(item, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode()
        self.assertLess(len(body), server.MAX_BYTES)
        self.assertGreater(len(body), 600_000)
        self.assertEqual(self.post(body, raw=True), 201)
        self.assertEqual((self.store.root / self.stored()[0]).read_bytes(), body)

    def test_hostile_reports_answer_400_and_store_nothing(self):
        self.limiter.per_ip = 100
        base = swift_reports()[0]
        hostile = [changed(base, ("summary",), "Langsam\n    Typische Ursache: FREMDTEXT \x1b[2J\x07"),
                   changed(base, ("launchID",), {"a": 1}), changed(base, ("launchPhase",), {"a": 1}),
                   changed(base, ("occurredAt",), "x"), changed(base, ("createdAt",), 10 ** 400),
                   changed(base, ("createdAt",), 10 ** 15), changed(base, ("app", "build"), "149\n"),
                   changed(base, ("id",), base["id"] + "\n"), changed(base, ("kind",), []),
                   changed(base, ("app", "channel"), []), changed(base, ("note",), "x"),
                   changed(base, ("breadcrumbs", 0, "v", "ms"), 10 ** 400)]
        for item in hostile:
            self.assertEqual(self.post(item), 400)
        # Not JSON for this service: other encodings, nesting beyond the parser, numbers beyond it.
        self.assertEqual(self.post(json.dumps(base).encode("utf-16"), raw=True), 400)
        self.assertEqual(self.post(b"\xff\xfe{}", raw=True), 400)
        self.assertEqual(self.post(b"[" * 200_000, raw=True), 400)
        self.assertEqual(self.post(b'{"createdAt":' + b"9" * 5000 + b"}", raw=True), 400)
        self.assertEqual(self.post(b'{"createdAt":NaN,"formatVersion":1}', raw=True), 400)
        self.assertEqual(self.stored(), [])
        self.assertEqual(list(self.store.root.rglob("*")), [])
        self.assertEqual(self.post(base), 201)


if __name__ == "__main__":
    unittest.main()
