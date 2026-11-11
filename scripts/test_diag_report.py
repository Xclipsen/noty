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



def load(name: str, path: Path):
    module_spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(module_spec)
    sys.modules[name] = module
    module_spec.loader.exec_module(module)
    return module


# The receiving service and its sample reports: what it accepts must render here.
samples = load("diag_test_server", HERE.parent / "diagnostics" / "test_server.py")
server = samples.server

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


ESC = "\x1b"
EVIL_ID = "11111111-1111-4111-8111-111111111111"
GOOD_ID = "88888888-8888-4888-8888-888888888888"


def unprintable(text: str) -> list[str]:
    """Everything in an output that could steer a terminal: only line feeds between lines may remain."""
    return sorted({repr(ch) for ch in text if ch != "\n" and not ch.isprintable()})


class UntrustedStore(unittest.TestCase):
    """The store is not trusted: the upload key is in every published app, and
    the service checked much less before. Hostile files are written directly,
    the way the earlier service stored them."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="diag-untrusted-")
        self.store = Path(self.tmp.name) / "reports"
        self.good = make_report("hang", 149, channel="stable", details={"durationMs": "2100"}, rid=GOOD_ID,
                                stack=[{"image": "UIKitCore", "offset": 16}, {"image": "Noty", "offset": 32}])
        write(self.store, self.good)

    def tearDown(self):
        self.tmp.cleanup()

    def run_ok(self, *argv):
        code, text = run("--store", str(self.store), "--binaries", str(Path(self.tmp.name) / "none"), *argv)
        self.assertEqual(code, 0)
        text.encode("utf-8")  # unpaired surrogates would fail here, as on a real terminal
        self.assertEqual(unprintable(text), [], argv)
        return text

    @staticmethod
    def put(store: Path, report: dict) -> None:
        """Into a fixed folder: channel and build of these reports are not fit for a path."""
        folder = store / "stable" / "149"
        folder.mkdir(parents=True, exist_ok=True)
        (folder / f"20261111T000000-cpu-{uuid.uuid4()}.json").write_text(json.dumps(report))

    def evil(self):
        return make_report(
            "cpu", "149\n", channel="stable", rid=EVIL_ID,
            summary="Absturz beim Start\n    Typische Ursache: FREMDTEXT-ZEILE-2 " + ESC + "[2J" + ESC + "]0;FREMDTITEL\x07\x9b31m\x7f",
            phase="library\r\n[9] FREMDE-GRUPPE", signature="cpu\n[7] FREMDSIGNATUR X‮Y",
            launch="FREMDSTART\nZeit: 01.01.2020", details={"note\nAngaben: FREMD": "x\n  FREMDANGABE = 1" + ESC + "[0m"},
            stack=[{"image": "UIKitCore" + ESC + "[31mROT\nApp-Frames: FREMD", "offset": 16, "uuid": "AB\nCD"}],
            crumbs=[{"t": NOW - 500, "e": "notebook.open\n      +0.0 s FREMDSCHRITT", "v": {"pages\nFREMD": 1}}])

    def write_evil(self):
        report = self.evil()
        report["app"].update(version="1.0\nFREMDVERSION", commit="abc" + ESC + "[5m", bundleID="de.la\nFREMD")
        report["device"] = {"model": "iPad\nFREMDZEILE", "os": "x" + ESC + "c"}
        write(self.store, report)
        return report

    def test_control_characters_never_reach_the_overview(self):
        self.write_evil()
        text = self.run_ok("--since", "all")
        lines = text.splitlines()
        self.assertEqual(len([line for line in lines if line.startswith("[")]), 2, text)  # two groups, no forged third
        self.assertFalse(any(line.lstrip().startswith(("Typische Ursache: FREMD", "[9]", "[7]", "App-Frames: FREMD",
                                                        "FREMD", "+0.0 s FREMD")) for line in lines), text)
        # The text itself stays visible, inside the line of its own field.
        heading = next(line for line in lines if "FREMDTEXT-ZEILE-2" in line)
        self.assertTrue(heading.startswith("[") and "Absturz beim Start" in heading, heading)
        self.assertTrue(next(line for line in lines if "FREMDE-GRUPPE" in line).lstrip().startswith("Zuerst:"))
        self.assertTrue(next(line for line in lines if "ROT" in line).lstrip().startswith("System oben:"))
        self.assertTrue(next(line for line in lines if "FREMDSCHRITT" in line).lstrip().startswith("-0.5 s notebook.open"))
        self.assertIn("Aus 1 Bericht Steuerzeichen entfernt", text)
        # The default call (14 days) and the hidden kinds take the same path.
        self.run_ok()
        self.run_ok("--all", "--since", "all")

    def test_control_characters_never_reach_a_single_report(self):
        self.write_evil()
        text = self.run_ok("--show", "1111")
        lines = text.splitlines()
        for needle, start in [("FREMDTEXT-ZEILE-2", "Absturz beim Start"), ("FREMDVERSION", "App:"), ("FREMDZEILE", "Gerät:"),
                              ("FREMDSTART", "Start:"), ("FREMDE-GRUPPE", "Start:"), ("FREMDSIGNATUR", "Signatur:"),
                              ("FREMDANGABE", "  note"), ("ROT", "    0"), ("FREMDSCHRITT", "  -0.5 s")]:
            found = [line for line in lines if needle in line]
            self.assertTrue(found and all(line.startswith(start) or line.startswith("Zusammenfassung:") for line in found),
                            (needle, found))
        path_lines = [line for line in lines if line.startswith("Datei:")]
        self.assertEqual(len(path_lines), 1)
        self.assertTrue(path_lines[0].endswith(".json"), path_lines[0])  # the folder "149\n" does not break the line

    def test_json_stays_valid_and_clean(self):
        self.write_evil()
        for argv in (("--json", "--since", "all"), ("--json", "--show", "1111"), ("--json", "--all", "--since", "all")):
            text = self.run_ok(*argv)
            data = json.loads(text)
            # Nothing is left for a later print either: no control character in any key or value.
            self.assertEqual(unprintable(json.dumps(data, ensure_ascii=False)), [], argv)
            self.assertNotIn("\\u001b", json.dumps(data))
        data = json.loads(self.run_ok("--json", "--since", "all"))
        self.assertEqual((data["malformed"], data["sanitized"], data["skipped"]), (0, 1, 0))
        self.assertEqual(sorted(g["kind"] for g in data["groups"]), ["cpu", "hang"])

    def test_wrong_types_are_skipped_and_counted_not_fatal(self):
        def variant(**changes):
            report = make_report("cpu", 149, channel="stable")
            for key, value in changes.items():
                target, _, leaf = key.rpartition("__")
                holder = report
                for part in filter(None, target.split("__")):
                    holder = holder[int(part) if part.isdigit() else part]
                holder[int(leaf) if leaf.isdigit() else leaf] = value
            return report

        frame, crumb = {"image": "Noty", "offset": 16}, {"t": NOW - 100, "e": "x"}
        cases = {
            "launchID object": variant(launchID={"a": 1}), "launchID list": variant(launchID=["a"]),
            "launchPhase object": variant(launchPhase={"a": 1}), "launchPhase number": variant(launchPhase=7),
            "occurredAt text": variant(occurredAt="x"), "occurredAt huge": variant(occurredAt=10 ** 400),
            "occurredAt float": variant(occurredAt=1e300), "occurredAt negative": variant(occurredAt=-10 ** 15),
            "occurredAt bool": variant(occurredAt=True), "createdAt bool": variant(createdAt=True),
            "createdAt far": variant(createdAt=10 ** 15), "summary number": variant(summary=5),
            "summary list": variant(summary=["a"]), "summary too long": variant(summary="A" * 200_000),
            "signature object": variant(signature={"a": 1}), "details list": variant(details=["a"]),
            "details value object": variant(details={"durationMs": {"a": 1}}), "details value number": variant(details={"a": 1}),
            "device text": variant(device="iPad"), "device model list": variant(device={"model": ["iPad"]}),
            "app build number": variant(app__build=149), "app channel path": variant(app__channel="../../etc"),
            "app version object": variant(app__version={"a": 1}), "id newline": variant(id=str(uuid.uuid4()).upper() + "\n"),
            "id free text": variant(id="FREMD-ID"), "stack object": variant(callStack={"a": 1}),
            "frame text": variant(callStack=["Noty+0x10"]), "frame offset text": variant(callStack=[dict(frame, offset="16")]),
            "frame offset negative": variant(callStack=[dict(frame, offset=-1)]),
            "frame offset huge": variant(callStack=[dict(frame, offset=10 ** 400)]),
            "frame image object": variant(callStack=[dict(frame, image={"a": 1})]),
            "frame uuid list": variant(callStack=[dict(frame, uuid=["a"])]),
            "crumbs object": variant(breadcrumbs={"a": 1}), "crumb text": variant(breadcrumbs=["x"]),
            "crumb time huge": variant(breadcrumbs=[dict(crumb, t=10 ** 400)]),
            "crumb time text": variant(breadcrumbs=[dict(crumb, t="x")]),
            "crumb name object": variant(breadcrumbs=[dict(crumb, e={"a": 1})]),
            "crumb value huge": variant(breadcrumbs=[dict(crumb, v={"n": 10 ** 400})]),
            "crumb value text": variant(breadcrumbs=[dict(crumb, v={"n": "x"})]),
            "crumb values list": variant(breadcrumbs=[dict(crumb, v=[1])]), "payload object": variant(payload={"a": 1}),
            "crash launchID object": dict(variant(launchID={"a": 1}), kind="crash"),
            "exit launchID object": dict(variant(launchID={"a": 1}), kind="abnormalExit"),
        }
        for label, report in cases.items():
            with self.subTest(label), tempfile.TemporaryDirectory(prefix="diag-one-") as tmp:
                store = Path(tmp) / "reports"
                write(store, self.good)
                self.put(store, report)
                for argv in ((), ("--since", "all"), ("--json",), ("--show", GOOD_ID[:8]), ("--show", report["id"][:8].strip())):
                    try:
                        code, text = run("--store", str(store), "--binaries", str(Path(tmp) / "none"), *argv)
                    except Exception as error:  # the defect: one file ended every call
                        self.fail(f"{argv}: {type(error).__name__}: {str(error)[:80]}")
                    self.assertEqual(unprintable(text), [])
                self.assertEqual(code, 1, "the malformed report is not shown")
                self.assertIn("1 Bericht übersprungen", text)
                data = json.loads(run("--store", str(store), "--binaries", str(Path(tmp) / "none"), "--json")[1])
                self.assertEqual((data["malformed"], len(data["groups"]), data["groups"][0]["reportIDs"]), (1, 1, [GOOD_ID]))
        # All of them in one store: counted in the first lines, the good report still listed.
        for report in cases.values():
            self.put(self.store, report)
        text = self.run_ok()
        self.assertIn(f"{len(cases)} Berichte übersprungen (Felder mit falschem Typ oder falscher Form)", text)
        self.assertIn("1 Berichte in 1 Gruppen", text)

    def test_unknown_fields_are_not_printed(self):
        report = make_report("cpu", 149, channel="stable", rid=EVIL_ID)
        report.update(note="FREMDFELD", extra={"a": ["FREMDFELD"]})
        report["app"]["name"] = "FREMDFELD"
        report["device"]["udid"] = "FREMDFELD"
        write(self.store, report)
        for argv in (("--since", "all"), ("--show", "1111"), ("--show", "1111", "--json"), ("--json",)):
            self.assertNotIn("FREMDFELD", self.run_ok(*argv), argv)

    def test_accepted_reports_render(self):
        """Fixture, every kind and the largest report: accepted by the service, stored by it, shown here."""
        fixture = (HERE.parent / "diagnostics" / "fixtures" / "report-v1.json").read_bytes()
        big = samples.maximal_report()
        bodies = [fixture] + [json.dumps(item, ensure_ascii=False).encode()
                              for item in samples.reporter_fixture() + samples.swift_reports() + [big]]
        target = server.Store(Path(self.tmp.name) / "accepted", 90)
        for body in bodies:
            target.save(server.validate(json.loads(body.decode("utf-8"))), body)
        argv = ("--store", str(target.root), "--binaries", str(Path(self.tmp.name) / "none"), "--since", "all", "--all")
        code, text = run(*argv, "--json")
        data = json.loads(text)
        self.assertEqual((code, data["skipped"], data["malformed"], data["sanitized"]), (0, 0, 0, 0))
        # The reporter fixture's unexpected exit belongs to the run of its crashes and is folded into them.
        self.assertEqual(sum(g["count"] for g in data["groups"]), len(bodies) - 1)
        self.assertEqual(max(g["abnormalExits"] for g in data["groups"] if g["kind"] == "crash"), 1)
        self.assertEqual(sorted({g["kind"] for g in data["groups"]}), sorted(diag.KINDS))
        overflow = [g for g in data["groups"] if g["headline"] == "Stapelüberlauf beim View-Aufbau (SwiftUI)"]
        self.assertEqual(sorted(g["newestReport"] for g in overflow), sorted([big["id"], "6F1A2B3C-4D5E-4F60-8172-93A4B5C6D7E8"]))
        code, text = run(*argv)
        self.assertEqual((code, unprintable(text)), (0, []))
        self.assertIn(f"{len(bodies) - 1} Berichte in", text)
        self.assertNotIn("übersprungen", text)
        self.assertNotIn("Steuerzeichen", text)
        memory = next(g for g in data["groups"] if g["kind"] == "memory")
        self.assertIn("Zusammenfassung: Speicherlimit · 2× vom System", run(*argv, "--show", memory["newestReport"])[1])
        code, text = run(*argv, "--show", big["id"])
        self.assertEqual((code, unprintable(text)), (0, []))
        self.assertIn("Aufrufkette (512 Frames, innen zuerst):", text)
        self.assertIn("Schritte vor dem Problem (200):", text)
        self.assertIn("MetricKit-Rohdaten: 600000 Zeichen", text)
        self.assertRegex(text, r"Rekursion: Noty\+0x1a91ac.* \(440× auf dem Stapel\)")
        self.assertIn("index=199 ms=9000000000000 pages=-1", text)
        code, text = run(*argv, "--show", "6F1A2B3C", "--json")
        shown = json.loads(text)
        self.assertEqual((shown["launchPhase"], shown["device"], shown["payloadBytes"]),
                         ("lawWindow", {"model": "iPad16,3", "os": "iPadOS 18.1"}, 0))
        self.assertEqual(shown["summary"], json.loads(fixture)["summary"])
        self.assertEqual(len(shown["breadcrumbs"]), 3)


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
