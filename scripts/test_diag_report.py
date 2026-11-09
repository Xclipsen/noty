"""Tests for scripts/diag_report.py (python3 -B -m unittest scripts/test_diag_report.py)."""
from __future__ import annotations

import importlib.util
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
import uuid
from pathlib import Path

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("diag_report", HERE / "diag_report.py")
diag = importlib.util.module_from_spec(spec)
sys.modules["diag_report"] = diag
spec.loader.exec_module(diag)

TEST_BINARY = HERE.parent / "xtool" / "Noty.app" / "Noty"
NOW = int(time.time() * 1000)
HOUR = 3600 * 1000


def make_report(kind, build, *, channel="dev", at=NOW, details=None, stack=None, crumbs=None, launch=None,
                signature="", summary="", phase="notebook", rid=None):
    return {
        "formatVersion": 1, "id": rid or str(uuid.uuid4()).upper(), "kind": kind, "createdAt": at, "occurredAt": at,
        "app": {"channel": channel, "bundleID": "de.la.noty.dev", "version": "1.0", "build": str(build), "commit": "abc"},
        "device": {"model": "iPad16,3", "os": "26.1"}, "launchID": launch or str(uuid.uuid4()).upper(),
        "launchPhase": phase, "summary": summary or kind, "signature": signature or kind, "details": details or {},
        "callStack": stack or [], "breadcrumbs": crumbs or [],
    }


def write(store: Path, report: dict) -> Path:
    folder = store / report["app"]["channel"] / report["app"]["build"]
    folder.mkdir(parents=True, exist_ok=True)
    path = folder / f"{time.strftime('%Y%m%dT%H%M%S', time.gmtime(report['createdAt'] / 1000))}-{report['kind']}-{report['id']}.json"
    path.write_text(json.dumps(report))
    return path


def run(*argv) -> tuple[int, str]:
    out = io.StringIO()
    code = diag.main(list(argv), out=out)
    return code, out.getvalue()


CRASH_LAUNCH = "11111111-2222-3333-4444-555555555555"
CRASH_STACK = [{"image": "libswiftCore.dylib", "offset": 0x1234}, {"image": "SwiftUICore", "offset": 0x99},
               {"image": "Noty", "offset": 0x1A91AC}, {"image": "Noty", "offset": 0x1A9200}]
CRASH_SIG = "crash:stackOverflow|Noty+0x1a91ac>Noty+0x1a9200"


class SameRunTests(unittest.TestCase):
    """The device test of Build 135: a test hang, then a test crash, in one run."""

    def test_exit_folds_only_into_the_crash_and_kernel_hangs_are_not_called_file_access(self):
        with tempfile.TemporaryDirectory(prefix="diag-same-run-") as tmp:
            store, launch = Path(tmp) / "reports", "F4ABCC0B-E001-4F02-A37A-2CA0313777B9"
            kernel_stack = [{"image": "libsystem_kernel.dylib", "offset": 0x6818}, {"image": "libsystem_c.dylib", "offset": 0xD648},
                            {"image": "Foundation", "offset": 0x321A8C}, {"image": "Noty", "offset": 0x10}]
            write(store, make_report("appHang", 135, at=NOW - 70_000, launch=launch, details={"durationMs": "3006"},
                                     stack=kernel_stack, signature="appHang|Noty+0x10"))
            write(store, make_report("crash", 135, at=NOW, launch=launch, details={"exceptionType": "6", "signal": "5"},
                                     stack=[{"image": "Noty", "offset": 0x20}], signature="crash:swiftTrap|Noty+0x20"))
            write(store, make_report("abnormalExit", 135, at=NOW + 1000, launch=launch, details={"state": "active"}))
            code, text = run("--store", str(store), "--binaries", str(Path(tmp) / "none"), "--json", "--since", "all")
            self.assertEqual(code, 0)
            groups = {g["kind"]: g for g in json.loads(text)["groups"]}
            self.assertEqual(sorted(groups), ["appHang", "crash"])
            self.assertEqual(groups["crash"]["abnormalExits"], 1)
            self.assertEqual(groups["appHang"]["abnormalExits"], 0)
            self.assertEqual(groups["appHang"]["headline"], "Hauptthread blockiert in einem Systemaufruf")


class SyntheticStore(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp(prefix="diag-report-test-")
        cls.store = Path(cls.tmp) / "reports"
        cls.nobin = Path(cls.tmp) / "no-binaries"
        crumbs = [{"t": NOW - 5 * HOUR - 4000, "e": "notebook.open", "v": {"pages": 34, "ms": 412}},
                  {"t": NOW - 5 * HOUR - 800, "e": "key.cmdL"},
                  {"t": NOW - 5 * HOUR - 300, "e": "law.window.shown"}]
        cls.crash_old = make_report("crash", 140, at=NOW - 5 * HOUR, launch=CRASH_LAUNCH, signature=CRASH_SIG,
                                    details={"stackGuard": "1", "exceptionType": "1", "exceptionTypeName": "EXC_BAD_ACCESS",
                                             "signal": "11", "signalName": "SIGSEGV", "build": "140"},
                                    stack=CRASH_STACK, crumbs=crumbs, rid="AAAA0000-0000-0000-0000-000000000001")
        cls.crash_new = make_report("crash", 142, at=NOW - 2 * HOUR, signature=CRASH_SIG,
                                    details={"stackGuard": "1", "build": "141"}, stack=CRASH_STACK,
                                    rid="AAAA0000-0000-0000-0000-000000000002")
        cls.exit = make_report("abnormalExit", 141, at=NOW - 5 * HOUR + 500, launch=CRASH_LAUNCH,
                               details={"state": "foreground", "build": "140"}, crumbs=crumbs)
        cls.slow = make_report("slow", 141, at=NOW - 3 * HOUR, signature="slow:notebook.open",
                               details={"operation": "notebook.open", "durationMs": "2400", "thresholdMs": "1500",
                                        "pages": "34"},
                               crumbs=[{"t": NOW - 3 * HOUR - 2400, "e": "notebook.open.begin", "v": {"pages": 34}}])
        cls.hang = make_report("appHang", 141, channel="ai", at=NOW - 1 * HOUR, signature="appHang|Noty+0x10",
                               details={"durationMs": "3100"},
                               stack=[{"image": "AttributeGraph", "offset": 0x500}, {"image": "SwiftUICore", "offset": 0x40},
                                      {"image": "Noty", "offset": 0x10}])
        cls.test_hang = make_report("appHang", 141, at=NOW - 1 * HOUR, details={"durationMs": "2000", "test": "1"},
                                    signature="appHang:test")
        cls.metrics = make_report("metrics", 141, at=NOW - 4 * HOUR,
                                  details={"build": "141", "launchFirstDrawMsMean": "820", "hangMsMean": "450",
                                           "hangCount": "3", "scrollHitchMsPerS": "2.10", "exitForegroundWatchdog": "1",
                                           "exitForegroundMemory": "0"})
        cls.ancient = make_report("failure", 130, at=NOW - 40 * 24 * HOUR, details={"operation": "save",
                                  "errorDomain": "NSCocoaErrorDomain", "errorCode": "640"}, signature="failure:save")
        for report in (cls.crash_old, cls.crash_new, cls.exit, cls.slow, cls.hang, cls.test_hang, cls.metrics, cls.ancient):
            write(cls.store, report)
        (cls.store / "dev" / "141" / "broken.json").write_text("{nope")
        (cls.store / "dev" / "141" / "foreign.json").write_text(json.dumps({"hello": 1}))

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def json_out(self, *argv):
        code, text = run("--store", str(self.store), "--binaries", str(self.nobin), "--json", *argv)
        self.assertEqual(code, 0)
        return json.loads(text)

    def test_grouping_and_folding(self):
        data = self.json_out()
        kinds = [g["kind"] for g in data["groups"]]
        self.assertEqual(sorted(kinds), ["appHang", "crash", "slow"])
        crash = next(g for g in data["groups"] if g["kind"] == "crash")
        self.assertEqual(crash["count"], 2)
        self.assertEqual(crash["builds"], {"140": 1, "141": 1})  # details.build wins over app.build
        self.assertEqual(crash["abnormalExits"], 1)
        self.assertEqual(crash["pattern"], "stackOverflow")
        self.assertEqual(crash["headline"], "Stapelüberlauf beim View-Aufbau (SwiftUI)")
        self.assertNotIn("abnormalExit", kinds)
        # Newest group first.
        self.assertEqual(data["groups"][0]["kind"], "appHang")
        self.assertEqual(data["skipped"], 2)
        self.assertEqual(data["hidden"], 2)  # metrics + test hang
        # The newest crash has no breadcrumbs: the steps come from the older one.
        self.assertEqual(crash["newestReport"], self.crash_new["id"])
        self.assertEqual(crash["breadcrumbsFrom"], self.crash_old["id"])
        self.assertEqual(len(crash["breadcrumbs"]), 3)

    def test_breadcrumbs_relative_and_from_folded_exit(self):
        data = self.json_out("--build", "140")
        crash = data["groups"][0]
        self.assertEqual(crash["count"], 1)
        self.assertEqual([c["dt"] for c in crash["breadcrumbs"]], [-4.0, -0.8, -0.3])
        self.assertEqual(crash["breadcrumbs"][0]["text"], "notebook.open ms=412 pages=34")

    def test_hints(self):
        data = self.json_out()
        hang = next(g for g in data["groups"] if g["kind"] == "appHang")
        self.assertEqual(hang["headline"], "Hänger beim View-Aufbau (SwiftUI)")
        self.assertIn("body", hang["hint"])
        slow = next(g for g in data["groups"] if g["kind"] == "slow")
        self.assertEqual(slow["headline"], "Langsam: Heft öffnen")
        self.assertEqual(slow["durationsMs"], [2400])
        ancient = self.json_out("--since", "all", "--kind", "failure")["groups"][0]
        self.assertEqual(ancient["headline"], "Speichern fehlgeschlagen (NSCocoaErrorDomain 640)")
        self.assertIn("Speicher voll", ancient["hint"])

    def test_filters(self):
        self.assertEqual([g["kind"] for g in self.json_out("--kind", "slow")["groups"]], ["slow"])
        self.assertEqual([g["kind"] for g in self.json_out("--channel", "ai")["groups"]], ["appHang"])
        self.assertEqual(self.json_out("--since", "90m")["groups"][0]["kind"], "appHang")
        self.assertEqual(len(self.json_out("--since", "90m")["groups"]), 1)
        self.assertEqual(len(self.json_out("--since", "all")["groups"]), 4)
        all_groups = self.json_out("--all")["groups"]
        self.assertIn("metrics", [g["kind"] for g in all_groups])
        self.assertEqual(sum(1 for g in all_groups if g["kind"] == "appHang"), 2)

    def test_metrics_section(self):
        data = self.json_out()
        self.assertEqual(len(data["metrics"]), 1)
        self.assertEqual(data["metrics"][0]["values"]["hangCount"], "3")
        code, text = run("--store", str(self.store), "--binaries", str(self.nobin))
        self.assertIn("Tageswerte", text)
        self.assertIn("Start 820 ms", text)
        self.assertIn("Watchdog vorn 1×", text)
        self.assertNotIn("Speicher-Enden vorn", text)

    def test_text_output(self):
        code, text = run("--store", str(self.store), "--binaries", str(self.nobin))
        self.assertEqual(code, 0)
        self.assertIn("Build 140: 1, Build 141: 1", text)
        self.assertIn("Auch als unerwartetes Ende erfasst (1×).", text)
        self.assertIn("Typische Ursache:", text)
        self.assertIn("2 Dateien übersprungen", text)
        self.assertIn("Ohne Symbole", text)
        self.assertIn("Noty+0x1a91ac", text)

    def test_show(self):
        code, text = run("--store", str(self.store), "--binaries", str(self.nobin), "--show", "aaaa0000-0000-0000-0000-000000000001")
        self.assertEqual(code, 0)
        self.assertIn("Bericht AAAA0000-0000-0000-0000-000000000001", text)
        self.assertIn("-4.0 s notebook.open ms=412 pages=34", text)
        self.assertIn("Unerwartet beendet", text)  # related report of the same launch
        code, text = run("--store", str(self.store), "--binaries", str(self.nobin), "--show", "AAAA")
        self.assertEqual(code, 1)
        self.assertIn("2 Berichte passen", text)
        code, text = run("--store", str(self.store), "--binaries", str(self.nobin), "--show", self.slow["id"][:13], "--json")
        data = json.loads(text)
        self.assertEqual(data["id"], self.slow["id"])
        self.assertEqual(data["headline"], "Langsam: Heft öffnen")

    def test_empty_store(self):
        code, text = run("--store", str(Path(self.tmp) / "missing"))
        self.assertEqual(code, 0)
        self.assertIn("Keine Berichte", text)
        empty = Path(self.tmp) / "empty"
        empty.mkdir()
        code, text = run("--store", str(empty), "--json")
        self.assertEqual(json.loads(text)["groups"], [])

    def test_pattern_mirror(self):
        base = make_report("crash", 1)
        cases = [({"terminationReason": "Namespace SPRINGBOARD, Code 0x8badf00d"}, "watchdog"),
                 ({"exceptionType": "6"}, "swiftTrap"), ({"signal": "5"}, "swiftTrap"),
                 ({"objcException": "NSRangeException"}, "objcException"), ({"signal": "6"}, "abort"),
                 ({"signal": "10"}, "badAccess"), ({"stackDepth": "600"}, "stackOverflow"), ({}, None)]
        for details, expected in cases:
            base["details"] = details
            self.assertEqual(diag.pattern_of(base), expected, details)
        base["details"] = {}
        base["callStack"] = [{"image": "Noty", "offset": 8}] * 40 + [{"image": "Noty", "offset": i} for i in range(30)]
        self.assertEqual(diag.pattern_of(base), "stackOverflow")
        self.assertEqual(diag.pattern_of(make_report("memory", 1)), "memoryLimit")
        self.assertIsNone(diag.pattern_of(make_report("slow", 1, details={"signal": "6"})))


def nm_address(symbol: str) -> int | None:
    nm = diag.find_tool("llvm-nm")
    if not nm:
        return None
    result = subprocess.run([nm, "--defined-only", str(TEST_BINARY)], capture_output=True, text=True)
    for line in result.stdout.splitlines():
        parts = line.split()
        if len(parts) == 3 and parts[2] == symbol:
            return int(parts[0], 16)
    return None


@unittest.skipUnless(TEST_BINARY.is_file() and diag.find_tool("llvm-symbolizer") and diag.find_tool("swift-demangle")
                     and diag.find_tool("llvm-nm"), "Toolchain oder Testbinärdatei fehlt")
class Symbolization(unittest.TestCase):
    def test_symbolized_grouping_across_builds(self):
        address = nm_address("_$s4Noty13LawReaderViewV4bodyQrvg")
        if address is None:
            self.skipTest("Symbol LawReaderView.body fehlt")
        offset = address - diag.TEXT_BASE
        with tempfile.TemporaryDirectory(prefix="diag-symbols-") as tmp:
            store, binaries = Path(tmp) / "store", Path(tmp) / "bin"
            for build in ("150", "151"):
                folder = binaries / "dev" / build
                folder.mkdir(parents=True)
                os.symlink(TEST_BINARY, folder / "Noty")
                (folder / "info.json").write_text(json.dumps({"channel": "dev", "build": build, "uuid": "AB-CD"}))
            # Different offsets in the same function, different builds: one group.
            write(store, make_report("crash", 150, signature="a", details={"signal": "5"},
                                     stack=[{"image": "Noty", "offset": offset + 4}]))
            write(store, make_report("crash", 151, signature="b", details={"signal": "5"},
                                     stack=[{"image": "Noty", "offset": offset + 12}]))
            # A frame from another binary must not get a wrong name.
            write(store, make_report("crash", 151, signature="c", details={"signal": "11"},
                                     stack=[{"image": "Noty", "offset": offset + 4, "uuid": "FFFF"}]))
            code, text = run("--store", str(store), "--binaries", str(binaries), "--json")
            data = json.loads(text)
            self.assertTrue(data["symbolication"])
            trap = next(g for g in data["groups"] if g["pattern"] == "swiftTrap")
            self.assertEqual(trap["count"], 2)
            self.assertEqual(trap["builds"], {"150": 1, "151": 1})
            self.assertEqual(trap["appFrames"][0]["function"], "LawReaderView.body.getter")
            other = next(g for g in data["groups"] if g["pattern"] == "badAccess")
            self.assertIsNone(other["appFrames"][0]["function"])
            self.assertEqual(other["appFrames"][0]["note"], "UUID passt nicht zur Binärdatei")
            code, text = run("--store", str(store), "--binaries", str(binaries))
            self.assertIn("LawReaderView.body.getter", text)


if __name__ == "__main__":
    unittest.main()
