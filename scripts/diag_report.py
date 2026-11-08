#!/usr/bin/env python3
"""Fehlerberichte der noty-Apps auswerten (docs/DIAGNOSE.md).

Liest die Ablage von ``diagnostics/server.py``
(``STORE/<kanal>/<build>/<zeit>-<art>-<id>.json``), fasst gleiche Ursachen
zusammen, übersetzt App-Adressen mit ``llvm-symbolizer`` und
``swift-demangle`` in Funktionsnamen (Binärdateien aus
``scripts/publish_ota.sh``) und zeigt die letzten Schritte vor dem Problem.

Gedacht für einen Agenten, der „irgendwas hängt / stürzt ab“ beheben soll:

    python3 -B scripts/diag_report.py              # Gruppen der letzten 14 Tage
    python3 -B scripts/diag_report.py --since 24h --channel dev
    python3 -B scripts/diag_report.py --show 3F2A  # ein Bericht vollständig
    python3 -B scripts/diag_report.py --json       # maschinenlesbar

The pattern rules mirror ``DiagnosticAnalysis`` in
``Core/Sources/NotebookCore/DiagnosticAnalysis.swift``; keep both in step.
Python standard library only.
"""
from __future__ import annotations

import argparse
import glob
import json
import os
import re
import shutil
import subprocess
import sys
import time
from collections import Counter
from datetime import datetime
from pathlib import Path

FORMAT_VERSION = 1
APP_IMAGE = "Noty"
TEXT_BASE = 0x100000000
DEFAULT_STORE = os.environ.get("NOTY_DIAG_STORE", "/var/lib/noty-diagnostics/reports")
DEFAULT_BINARIES = os.environ.get("DIAG_BINARIES", "/home/la/workspace/noty/.tools/diag-binaries")
TOOLCHAIN_GLOB = "/home/la/.local/share/swiftly/toolchains/*/usr/bin"

KINDS = ["crash", "hang", "appHang", "cpu", "memory", "diskWrite", "launch", "slow",
         "failure", "abnormalExit", "metrics", "test"]
KIND_LABELS = {
    "crash": "Absturz", "hang": "Hänger (System)", "appHang": "Hänger", "cpu": "CPU-Last",
    "memory": "Speicherlimit", "diskWrite": "Schreiblast", "launch": "Langsamer Start",
    "slow": "Langsam", "failure": "Fehler", "abnormalExit": "Unerwartet beendet",
    "metrics": "Tageswerte", "test": "Test",
}

# DiagnosticAnalysis.Pattern
PATTERN_TEXT = {
    "stackOverflow": "Stapelüberlauf (meist beim View-Aufbau: tief verschachtelte SwiftUI-Typen oder Rekursion)",
    "watchdog": "Watchdog-Abbruch: der Hauptthread blockierte zu lange",
    "swiftTrap": "Swift-Laufzeitfalle (fatalError, erzwungenes Entpacken, Index außerhalb, Überlauf)",
    "objcException": "Objective-C-Ausnahme",
    "abort": "Abbruch (SIGABRT)",
    "badAccess": "Speicherzugriffsfehler",
    "memoryLimit": "Vom System wegen Speicherverbrauch beendet",
}
PATTERN_HINT = {
    "stackOverflow": "Zu tief verschachtelte SwiftUI-View-Typen (große body, lange Modifier-Ketten, viele if/Group) "
                     "oder eine Rekursion. body in kleinere Views zerlegen, Teile in eigene Funktionen/Views auslagern, "
                     "Rekursion begrenzen.",
    "watchdog": "Der Hauptthread war beim Start, beim Wechsel in den Vordergrund oder durch eine Sperre zu lange blockiert. "
                "Dateizugriffe und lange Rechnungen vom Hauptthread nehmen.",
    "swiftTrap": "fatalError, erzwungenes Entpacken (!), try!, Index außerhalb des Bereichs, Ganzzahlüberlauf oder "
                 "precondition. Die innerste App-Funktion prüfen.",
    "objcException": "Eine Systembibliothek hat eine Ausnahme geworfen, z. B. ungültiger Index in UIKit/PDFKit, "
                     "ungültiger Zustand oder UI-Zugriff außerhalb des Hauptthreads.",
    "abort": "abort() oder eine Assertion in einer Bibliothek, oft Folge einer nicht abgefangenen Ausnahme.",
    "badAccess": "Zugriff auf freigegebenen oder ungültigen Speicher: unowned/Unsafe-Zeiger, Datenrennen zwischen Threads, "
                 "C-/Objective-C-APIs mit falscher Lebensdauer.",
    "memoryLimit": "Zu viel Speicher: viele große Bilder oder PDF-Seiten gleichzeitig, Vorschauen oder Caches ohne Grenze.",
}

# DiagnosticAnalysis.operationLabel
OPERATION_LABELS = {
    "notebook.open": "Heft öffnen", "page.switch": "Seite wechseln", "save": "Speichern",
    "stroke.commit": "Strich abschließen", "law.window": "Gesetzesfenster", "law.load": "Gesetz laden",
    "search": "Suche", "search.index": "Suchindex erfassen", "pdf.export": "PDF-Export", "backup": "Backup",
    "appSync": "App-Abgleich (Abzug)", "appSync.mirror": "App-Abgleich (Spiegel)", "restore": "Wiederherstellen",
}

COCOA_ERRORS = {
    "4": "Datei fehlt", "256": "Datei nicht lesbar", "257": "keine Leserechte", "260": "Datei fehlt",
    "512": "Schreibfehler", "513": "keine Schreibrechte", "516": "Datei existiert schon",
    "640": "Speicher voll", "642": "Datenträger schreibgeschützt", "3840": "JSON/Plist beschädigt",
    "4864": "Daten beschädigt (Decoder)", "4865": "Wert fehlt (Decoder)",
}

SWIFTUI_IMAGES = {"SwiftUI", "SwiftUICore", "AttributeGraph"}
PENCILKIT_IMAGES = {"PencilKit", "PencilKitCore"}
WAIT_IMAGES = {"libsystem_pthread.dylib", "libdispatch.dylib", "libsystem_platform.dylib"}
FILE_SYMBOL = re.compile(r"FileManager|FileHandle|contentsOf|write\(to|\bfsync\b|\bread\(|\bwrite\(|\bopen\(|replaceItem|moveItem|copyItem|createDirectory|removeItem")
WAIT_SYMBOL = re.compile(r"semaphore_wait|__psynch|mach_msg|DispatchSemaphore|\.wait\(|_dispatch_sync|pthread_mutex|os_unfair_lock|NSLock|OSAllocatedUnfairLock|dispatch_sync|\bsleep|usleep|nanosleep")

HANG_HINTS = {
    "swiftui": ("Hänger beim View-Aufbau (SwiftUI)",
                "body wird zu oft oder zu teuer neu berechnet: große Listen ohne Lazy-Container, teure Berechnungen in body, "
                "zu breite Beobachtung (@Observable/@Published) oder Layoutschleifen."),
    "pencilkit": ("Hänger in PencilKit",
                  "Große Zeichnungen laden/zusammenführen, PKDrawing-Serialisierung oder Canvas-Neuaufbau auf dem Hauptthread."),
    "file": ("Dateizugriff auf dem Hauptthread",
             "Lesen, Schreiben oder fsync auf dem Hauptthread. In einen Hintergrund-Task verschieben."),
    "kernel": ("Hauptthread blockiert in einem Systemaufruf",
               "Warten, Schlafen oder Ein-/Ausgabe. Ohne Symbole der Systemfunktionen ist das nicht zu unterscheiden; "
               "die innerste App-Funktion zeigt, wer den Aufruf macht. Ein solcher Aufruf gehört nicht auf den Hauptthread."),
    "wait": ("Hauptthread wartet auf eine Sperre oder einen anderen Thread",
             "DispatchQueue.sync, Semaphore oder Lock auf dem Hauptthread, während ein anderer Thread die Sperre hält "
             "(oft Speichern/I/O). Synchrones Warten vermeiden."),
    "app": ("Hänger in App-Code", "Lange Rechnung auf dem Hauptthread. Die oberste App-Funktion prüfen."),
    "unknown": ("Hänger ohne erkennbare Stelle", "Keine App-Frames im Stapel; Breadcrumbs vor dem Hänger prüfen."),
}


# ---------------------------------------------------------------------------
# Loading


def ms_to_local(ms: int | None) -> str:
    if not ms:
        return "?"
    return datetime.fromtimestamp(ms / 1000).strftime("%d.%m.%Y %H:%M:%S")


def ms_to_iso(ms: int | None) -> str | None:
    if not ms:
        return None
    return datetime.fromtimestamp(ms / 1000).astimezone().isoformat(timespec="seconds")


def parse_since(text: str, now: float | None = None) -> int | None:
    """Returns the cutoff in ms since 1970, None for no cutoff."""
    now = time.time() if now is None else now
    text = text.strip()
    if text in ("all", "alle", "0"):
        return None
    match = re.fullmatch(r"(\d+)\s*([mhdw])", text)
    if match:
        factor = {"m": 60, "h": 3600, "d": 86400, "w": 7 * 86400}[match.group(2)]
        return int((now - int(match.group(1)) * factor) * 1000)
    try:
        return int(datetime.strptime(text, "%Y-%m-%d").timestamp() * 1000)
    except ValueError:
        raise argparse.ArgumentTypeError(f"--since: '{text}' verstehe ich nicht (z. B. 24h, 7d, 2026-11-01, all)")


def is_report(obj: object) -> bool:
    return (isinstance(obj, dict) and obj.get("formatVersion") == FORMAT_VERSION and obj.get("kind") in KINDS
            and isinstance(obj.get("id"), str) and isinstance(obj.get("createdAt"), int)
            and isinstance(obj.get("app"), dict))


def load_store(store: Path) -> tuple[list[dict], int]:
    reports, skipped, seen = [], 0, set()
    if not store.is_dir():
        return [], 0
    for path in sorted(store.rglob("*.json")):
        try:
            obj = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError, UnicodeDecodeError):
            skipped += 1
            continue
        if not is_report(obj):
            skipped += 1
            continue
        if obj["id"].upper() in seen:
            continue
        seen.add(obj["id"].upper())
        obj["_path"] = str(path)
        obj.setdefault("details", {})
        obj.setdefault("callStack", [])
        obj.setdefault("breadcrumbs", [])
        if not isinstance(obj["details"], dict):
            obj["details"] = {}
        obj["callStack"] = [f for f in obj["callStack"] if isinstance(f, dict) and isinstance(f.get("offset"), int)]
        obj["breadcrumbs"] = [c for c in obj["breadcrumbs"] if isinstance(c, dict) and isinstance(c.get("t"), int)]
        reports.append(obj)
    return reports, skipped


def build_of(report: dict) -> str:
    """The build the problem belongs to: MetricKit's/the run's build if given."""
    build = str(report["details"].get("build", ""))
    return build if build.isdigit() else str(report["app"].get("build", "?"))


def channel_of(report: dict) -> str:
    return str(report["app"].get("channel", "?"))


def when(report: dict) -> int:
    return report.get("occurredAt") or report["createdAt"]


def is_hidden_kind(report: dict) -> bool:
    return report["kind"] in ("metrics", "test") or report["details"].get("test") == "1"


# ---------------------------------------------------------------------------
# Symbolication


def find_tool(name: str) -> str | None:
    for folder in sorted(glob.glob(TOOLCHAIN_GLOB), reverse=True):
        candidate = os.path.join(folder, name)
        if os.access(candidate, os.X_OK):
            return candidate
    return shutil.which(name)


def norm_uuid(value: object) -> str:
    return str(value or "").replace("-", "").upper()


class Symbolizer:
    """Maps (channel, build, offset) of app frames to demangled names."""

    def __init__(self, binaries: Path | None):
        self.binaries = binaries
        self.symbolizer = find_tool("llvm-symbolizer")
        self.demangler = find_tool("swift-demangle")
        self._binary_cache: dict[tuple[str, str], tuple[Path, str] | None] = {}
        self._names: dict[tuple[str, int], str | None] = {}
        self.missing_builds: set[str] = set()

    @property
    def available(self) -> bool:
        return bool(self.symbolizer and self.binaries and self.binaries.is_dir())

    def binary(self, channel: str, build: str) -> tuple[Path, str] | None:
        key = (channel, build)
        if key in self._binary_cache:
            return self._binary_cache[key]
        found = None
        if self.binaries and self.binaries.is_dir() and build.isdigit():
            # Build numbers count up across all apps: any channel will do.
            folders = [self.binaries / channel / build] + sorted(self.binaries.glob(f"*/{build}"))
            for folder in folders:
                if (folder / APP_IMAGE).is_file():
                    try:
                        info = json.loads((folder / "info.json").read_text())
                    except (OSError, ValueError):
                        info = {}
                    found = ((folder / APP_IMAGE).resolve(), norm_uuid(info.get("uuid")))
                    break
        if found is None:
            self.missing_builds.add(build)
        self._binary_cache[key] = found
        return found

    @staticmethod
    def lookup_address(frame_index: int, offset: int) -> int:
        # Outer frames hold return addresses: step back into the call.
        return TEXT_BASE + offset - (1 if frame_index > 0 and offset > 0 else 0)

    def prepare(self, reports: list[dict]) -> None:
        """Symbolizes every app frame of these reports, one call per binary."""
        if not self.available:
            return
        wanted: dict[Path, set[int]] = {}
        for report in reports:
            located = self.binary(channel_of(report), build_of(report))
            if not located:
                continue
            path, image_uuid = located
            for index, frame in enumerate(report["callStack"]):
                if frame.get("image") != APP_IMAGE:
                    continue
                if frame.get("uuid") and image_uuid and norm_uuid(frame["uuid"]) != image_uuid:
                    continue
                address = self.lookup_address(index, frame["offset"])
                if (str(path), address) not in self._names:
                    wanted.setdefault(path, set()).add(address)
        mangled: dict[tuple[str, int], str] = {}
        for path, addresses in wanted.items():
            ordered = sorted(addresses)
            try:
                result = subprocess.run(
                    [self.symbolizer, f"--obj={path}", "--functions=linkage", "--output-style=JSON"],
                    input="\n".join(hex(a) for a in ordered) + "\n", capture_output=True, text=True, timeout=300)
            except (OSError, subprocess.SubprocessError):
                continue
            for line in result.stdout.splitlines():
                try:
                    entry = json.loads(line)
                    address = int(entry["Address"], 16)
                    name = (entry.get("Symbol") or [{}])[0].get("FunctionName") or ""
                except (ValueError, KeyError, IndexError, TypeError):
                    continue
                key = (str(path), address)
                if name and name not in ("??", "_mh_execute_header", "__mh_execute_header"):
                    mangled[key] = name
                else:
                    self._names[key] = None
        for key, name in zip(mangled.keys(), self.demangle(list(mangled.values()))):
            self._names[key] = name

    def demangle(self, names: list[str]) -> list[str]:
        if not names or not self.demangler:
            return names
        simple = self._run_demangle(names, ["--simplified", "--compact"])
        full = None
        out = []
        for index, (raw, short) in enumerate(zip(names, simple)):
            # "--simplified" drops the type of e.g. "one-time initialization
            # function for shared"; fall back to the full name without module.
            if "." not in short and short != raw:
                if full is None:
                    full = self._run_demangle(names, ["--compact"])
                short = re.sub(r"\b(Noty|NotebookCore)\.", "", full[index])
            out.append(short)
        return out

    def _run_demangle(self, names: list[str], flags: list[str]) -> list[str]:
        try:
            result = subprocess.run([self.demangler, *flags], input="\n".join(names) + "\n",
                                    capture_output=True, text=True, timeout=120)
            lines = result.stdout.splitlines()
            if len(lines) == len(names):
                return lines
        except (OSError, subprocess.SubprocessError):
            pass
        return list(names)

    def frame_info(self, report: dict, index: int) -> dict:
        frame = report["callStack"][index]
        image, offset = str(frame.get("image", "?")), frame["offset"]
        info = {"image": image, "offset": hex(offset), "app": image == APP_IMAGE, "function": None, "note": None}
        if image != APP_IMAGE:
            return info
        located = self.binary(channel_of(report), build_of(report)) if self.binaries else None
        if not located:
            info["note"] = "keine Binärdatei" if self.binaries else None
            return info
        path, image_uuid = located
        if frame.get("uuid") and image_uuid and norm_uuid(frame["uuid"]) != image_uuid:
            info["note"] = "UUID passt nicht zur Binärdatei"
            return info
        info["function"] = self._names.get((str(path), self.lookup_address(index, offset)))
        return info


def frame_label(info: dict, width: int = 160) -> str:
    if info["function"]:
        name = info["function"]
        return name if len(name) <= width else name[: width - 1] + "…"
    text = f"{info['image']}+{info['offset']}"
    return text + (f" ({info['note']})" if info.get("note") else "")


# ---------------------------------------------------------------------------
# Analysis


def is_recursive(stack: list[dict]) -> tuple[bool, tuple | None, int]:
    if len(stack) < 64:
        return False, None, 0
    counts = Counter((f.get("image"), f["offset"]) for f in stack)
    frame, count = counts.most_common(1)[0]
    return count >= 32, frame, count


def to_int(value: object) -> int | None:
    try:
        return int(str(value))
    except (TypeError, ValueError):
        return None


def pattern_of(report: dict) -> str | None:
    """Mirrors DiagnosticAnalysis.pattern(for:)."""
    details, kind = report["details"], report["kind"]
    if kind == "memory":
        return "memoryLimit"
    if "8badf00d" in str(details.get("terminationReason", "")).lower():
        return "watchdog"
    if kind not in ("crash", "abnormalExit", "test"):
        return None
    signal, exception = to_int(details.get("signal")), to_int(details.get("exceptionType"))
    if details.get("stackGuard") == "1" or is_recursive(report["callStack"])[0] or (to_int(details.get("stackDepth")) or 0) >= 512:
        return "stackOverflow"
    if exception == 6 or signal == 5:
        return "swiftTrap"
    if "objcException" in details:
        return "objcException"
    if signal == 6:
        return "abort"
    if exception == 1 or signal in (11, 10):
        return "badAccess"
    return None


def operation_label(operation: str) -> str:
    return OPERATION_LABELS.get(operation, operation)


def top_segment(report: dict) -> list[dict]:
    """Innermost system frames up to the first app frame (at most 16)."""
    segment = []
    for frame in report["callStack"][:16]:
        if frame.get("image") == APP_IMAGE:
            break
        segment.append(frame)
    return segment


def hang_category(report: dict, infos: list[dict]) -> str:
    stack = report["callStack"]
    segment = top_segment(report) or stack[:16]
    images = [str(f.get("image", "")) for f in segment]
    symbols = " ".join(str(f.get("symbol", "")) for f in segment)
    app_names = " ".join(i["function"] or "" for i in infos if i["app"])[:4000]
    top = images[0] if images else ""
    inner_app = " ".join((i["function"] or "") for i in infos[:12] if i["app"])
    # Only what the evidence shows: system frames carry no names, so a kernel
    # frame on top alone does not tell waiting, sleeping and file access apart.
    if (WAIT_SYMBOL.search(symbols) or WAIT_SYMBOL.search(inner_app)
            or (top == "libsystem_kernel.dylib" and any(i in WAIT_IMAGES for i in images[1:3]))):
        return "wait"
    if FILE_SYMBOL.search(symbols) or FILE_SYMBOL.search(inner_app):
        return "file"
    if top == "libsystem_kernel.dylib":
        return "kernel"
    if any(i in PENCILKIT_IMAGES for i in images):
        return "pencilkit"
    if any(i in SWIFTUI_IMAGES for i in images) or ("body.getter" in app_names and any(i in SWIFTUI_IMAGES for i in
                                                                                       (str(f.get("image")) for f in stack))):
        return "swiftui"
    if any(i["app"] for i in infos):
        return "app"
    return "unknown"


def has_swiftui(report: dict, infos: list[dict]) -> bool:
    return (any(str(f.get("image")) in SWIFTUI_IMAGES for f in report["callStack"])
            or any("body.getter" in (i["function"] or "") for i in infos))


class Analysis:
    """Everything derived from one report."""

    def __init__(self, report: dict, symbols: Symbolizer):
        self.report = report
        details, kind = report["details"], report["kind"]
        self.infos = [symbols.frame_info(report, i) for i in range(len(report["callStack"]))]
        self.pattern = pattern_of(report)
        self.app_infos = [i for i in self.infos if i["app"]]
        names = [i["function"] for i in self.app_infos if i["function"]]
        self.top_names = dedupe(names)[:3]
        self.recursion = None
        recursive, frame, count = is_recursive(report["callStack"])
        if recursive:
            index = next(n for n, f in enumerate(report["callStack"]) if (f.get("image"), f["offset"]) == frame)
            self.recursion = (frame_label(self.infos[index]), count)

        operation = details.get("operation")
        self.headline, self.hint, self.category = report.get("summary") or KIND_LABELS.get(kind, kind), None, None
        if self.pattern:
            self.headline = PATTERN_TEXT[self.pattern]
            self.hint = PATTERN_HINT[self.pattern]
            if self.pattern == "stackOverflow":
                if has_swiftui(report, self.infos):
                    self.headline = "Stapelüberlauf beim View-Aufbau (SwiftUI)"
                elif self.recursion:
                    self.headline = "Stapelüberlauf durch Rekursion"
                else:
                    self.headline = "Stapelüberlauf"
        elif kind in ("hang", "appHang"):
            self.category = hang_category(report, self.infos)
            self.headline, self.hint = HANG_HINTS[self.category]
        elif kind == "slow":
            self.headline = f"Langsam: {operation_label(operation or 'Vorgang')}"
            self.hint = ("Vorgang über der Schwelle. Werte im Bericht (z. B. pages) und Schritte davor prüfen; "
                         "Arbeit vom Hauptthread nehmen, zerlegen oder zwischenspeichern.")
        elif kind == "failure":
            domain, code = details.get("errorDomain"), details.get("errorCode")
            self.headline = f"{operation_label(operation or 'Vorgang')} fehlgeschlagen" + (f" ({domain} {code})" if code else "")
            meaning = COCOA_ERRORS.get(str(code)) if domain == "NSCocoaErrorDomain" else None
            self.hint = (f"{domain} {code} bedeutet: {meaning}. " if meaning else "Fehlerdomäne und -code prüfen. ") + \
                "Nur Domäne und Code werden übertragen, keine Fehlertexte."
        elif kind == "abnormalExit":
            self.headline = f"Unerwartet beendet in Phase {report.get('launchPhase') or '?'}"
            self.hint = ("Ende im Vordergrund ohne sauberes Beenden: Speicherlimit, Watchdog oder Absturz ohne MetricKit-Bericht "
                         "(der kann einen Tag später nachkommen). Schritte davor prüfen.")
        elif kind == "cpu":
            self.hint = "Zu viel Rechenzeit über längere Zeit, oft eine Schleife oder ständiges Neuzeichnen."
        elif kind == "diskWrite":
            self.hint = "Zu viele Schreibvorgänge, z. B. Autosave oder Vorschauen in zu kurzen Abständen."
        elif kind == "launch":
            self.hint = "Langsamer Start: Arbeit in init/App-Start oder beim Öffnen des ersten Hefts."
        if kind == "test" or details.get("test") == "1":
            self.headline = f"Test: {details.get('test') if details.get('test') not in (None, '1') else self.headline}"

        head = kind + ":" + (self.pattern or operation or self.category or "")
        if self.top_names:
            self.key = head + "|" + ">".join(self.top_names)
        else:
            self.key = head + "|" + str(report.get("signature") or "")

    def system_top(self, limit: int = 5) -> list[str]:
        out = []
        for info in self.infos:
            if info["app"]:
                break
            out.append(frame_label(info))
            if len(out) >= limit:
                break
        return out


def dedupe(names: list[str]) -> list[str]:
    out = []
    for name in names:
        if not out or out[-1] != name:
            out.append(name)
    return out


def collapsed_app_frames(analysis: Analysis, limit: int) -> list[str]:
    """App frames innermost first, repeats folded into "(×n)"."""
    lines, last, count = [], None, 0
    for info in analysis.app_infos:
        label = frame_label(info)
        if label == last:
            count += 1
            continue
        if last is not None:
            lines.append(last + (f"  (×{count})" if count > 1 else ""))
        last, count = label, 1
        if len(lines) >= limit:
            break
    if last is not None and len(lines) < limit:
        lines.append(last + (f"  (×{count})" if count > 1 else ""))
    return lines


def crumbs_before(report: dict, limit: int | None) -> list[dict]:
    crumbs = sorted(report["breadcrumbs"], key=lambda c: c["t"])
    if not crumbs:
        return []
    ref = when(report)
    before = [c for c in crumbs if c["t"] <= ref]
    if not before:
        before, ref = crumbs, crumbs[-1]["t"]
    picked = before if limit is None else before[-limit:]
    out = []
    for crumb in picked:
        values = crumb.get("v") or {}
        text = " ".join([str(crumb.get("e", "?"))] + [f"{k}={values[k]}" for k in sorted(values)])
        out.append({"dt": round((crumb["t"] - ref) / 1000, 1), "e": crumb.get("e"), "v": values, "text": text})
    return out


def crumb_line(crumb: dict) -> str:
    dt = crumb["dt"]
    stamp = "±0.0" if dt == 0 else f"{dt:+.1f}"
    return f"{stamp} s {crumb['text']}"


# ---------------------------------------------------------------------------
# Grouping


def group_reports(reports: list[dict], all_reports: list[dict], symbols: Symbolizer) -> list[dict]:
    crash_launches = {r.get("launchID") for r in all_reports if r["kind"] == "crash" and r.get("launchID")}
    folded: dict[str, list[dict]] = {}
    remaining = []
    for report in reports:
        if report["kind"] == "abnormalExit" and report.get("launchID") in crash_launches:
            folded.setdefault(report["launchID"], []).append(report)
        else:
            remaining.append(report)
    # Folded exits also count when only their crash passed the filters.
    for report in all_reports:
        if report["kind"] == "abnormalExit" and report.get("launchID") in crash_launches:
            bucket = folded.setdefault(report["launchID"], [])
            if report not in bucket:
                bucket.append(report)

    groups: dict[str, dict] = {}
    for report in remaining:
        analysis = Analysis(report, symbols)
        group = groups.setdefault(analysis.key, {"key": analysis.key, "items": []})
        group["items"].append(analysis)

    def exits_of(report: dict) -> list[dict]:
        # Only a crash owns the exit of its run; a hang earlier in the same run does not.
        return folded.get(report.get("launchID"), []) if report["kind"] == "crash" else []

    result = []
    for group in groups.values():
        items = sorted(group["items"], key=lambda a: when(a.report))
        newest = items[-1]
        exits = [x for a in items for x in exits_of(a.report)]
        # Steps of the newest report that has any (its own or its folded exit's).
        crumb_source = newest.report
        for analysis in reversed(items):
            candidates = [analysis.report] + exits_of(analysis.report)
            found = next((r for r in candidates if r["breadcrumbs"]), None)
            if found:
                crumb_source = found
                break
        builds = Counter(build_of(a.report) for a in items)
        durations = [to_int(a.report["details"].get("durationMs")) for a in items]
        durations = [d for d in durations if d is not None]
        result.append({
            "key": group["key"],
            "kind": newest.report["kind"],
            "headline": newest.headline,
            "pattern": newest.pattern,
            "hint": newest.hint,
            "count": len(items),
            "builds": dict(sorted(builds.items(), key=lambda kv: (len(kv[0]), kv[0]))),
            "channels": sorted({channel_of(a.report) for a in items}),
            "phases": sorted({a.report.get("launchPhase") or "?" for a in items}),
            "firstSeen": when(items[0].report),
            "lastSeen": when(newest.report),
            "durationsMs": durations,
            "abnormalExits": len(exits),
            "reportIDs": [a.report["id"] for a in reversed(items)],
            "newest": newest,
            "crumbs": crumbs_before(crumb_source, 15),
            "crumbsFrom": crumb_source["id"] if crumb_source["breadcrumbs"] else None,
        })
    result.sort(key=lambda g: g["lastSeen"], reverse=True)
    return result


METRIC_FIELDS = [
    ("launchFirstDrawMsMean", "Start", "ms"), ("launchResumeMsMean", "Fortsetzen", "ms"),
    ("hangMsMean", "Hänger Ø", "ms"), ("hangCount", "Hänger", "×"), ("scrollHitchMsPerS", "Scroll-Ruckeln", "ms/s"),
    ("memoryPeakMB", "Speicher max", "MB"), ("exitForegroundMemory", "Speicher-Enden vorn", "×"),
    ("exitForegroundWatchdog", "Watchdog vorn", "×"), ("exitForegroundBadAccess", "Speicherfehler vorn", "×"),
    ("exitForegroundAbnormal", "unnormal vorn", "×"), ("exitBackgroundMemory", "Speicher-Enden hinten", "×"),
    ("exitBackgroundWatchdog", "Watchdog hinten", "×"),
]


def latest_metrics(reports: list[dict]) -> list[dict]:
    newest: dict[tuple[str, str], dict] = {}
    for report in reports:
        if report["kind"] != "metrics" or report["details"].get("test") == "1":
            continue
        key = (channel_of(report), build_of(report))
        if key not in newest or report["createdAt"] > newest[key]["createdAt"]:
            newest[key] = report
    out = []
    for (channel, build), report in newest.items():
        values = {}
        for field, label, unit in METRIC_FIELDS:
            value = report["details"].get(field)
            if value not in (None, "", "?"):
                values[field] = value
        out.append({"channel": channel, "build": build, "createdAt": report["createdAt"],
                    "from": to_int(report["details"].get("from")), "to": to_int(report["details"].get("to")),
                    "values": values, "id": report["id"]})
    out.sort(key=lambda m: (to_int(m["build"]) or 0, m["createdAt"]), reverse=True)
    return out


def metric_text(values: dict) -> str:
    parts = []
    for field, label, unit in METRIC_FIELDS:
        if field not in values:
            continue
        value = values[field]
        if field.startswith("exit") and value == "0":
            continue
        parts.append(f"{label} {value}{'' if unit == '×' else ' '}{unit}" if unit != "×" else f"{label} {value}×")
    return ", ".join(parts) or "keine Werte"


# ---------------------------------------------------------------------------
# Output


def short_id(rid: str, all_ids: list[str]) -> str:
    """Shortest prefix of at least 8 characters that is unique among all_ids."""
    for length in (8, 13, 18, 23):
        prefix = rid[:length]
        if sum(1 for other in set(all_ids) if other.startswith(prefix)) <= 1:
            return prefix
    return rid


def builds_text(builds: dict) -> str:
    return ", ".join(f"Build {b}: {n}" for b, n in builds.items())


def print_groups(groups: list[dict], metrics: list[dict], header: str, notes: list[str], out) -> None:
    print(header, file=out)
    for note in notes:
        print(note, file=out)
    ids_all = [i for g in groups for i in g["reportIDs"]] + [g["crumbsFrom"] for g in groups if g["crumbsFrom"]]
    for number, group in enumerate(groups, 1):
        newest: Analysis = group["newest"]
        print("", file=out)
        print(f"[{number}] {group['headline']}", file=out)
        line = f"    Art: {KIND_LABELS.get(group['kind'], group['kind'])} · {group['count']}× · {builds_text(group['builds'])}"
        line += f" · Kanal: {', '.join(group['channels'])}"
        print(line, file=out)
        print(f"    Zuerst: {ms_to_local(group['firstSeen'])} · Zuletzt: {ms_to_local(group['lastSeen'])}"
              f" · Phase: {', '.join(group['phases'])}", file=out)
        if group["durationsMs"]:
            d = sorted(group["durationsMs"])
            extra = ""
            threshold = newest.report["details"].get("thresholdMs")
            if threshold:
                extra = f" (Schwelle {threshold} ms)"
            print(f"    Dauer: max {d[-1]} ms, Median {d[len(d) // 2]} ms{extra}", file=out)
        if group["abnormalExits"]:
            print(f"    Auch als unerwartetes Ende erfasst ({group['abnormalExits']}×).", file=out)
        extra_details = summarize_details(newest.report)
        if extra_details:
            print(f"    Angaben: {extra_details}", file=out)
        if newest.recursion:
            print(f"    Rekursion: {newest.recursion[0]} ({newest.recursion[1]}× auf dem Stapel)", file=out)
        frames = collapsed_app_frames(newest, 8)
        if frames:
            print("    App-Frames (innen zuerst):", file=out)
            for frame in frames:
                print(f"      {frame}", file=out)
        elif newest.report["callStack"]:
            print("    Keine App-Frames im Stapel.", file=out)
        system = newest.system_top()
        if system:
            print(f"    System oben: {' ← '.join(system)}", file=out)
        if group["hint"]:
            print(f"    Typische Ursache: {group['hint']}", file=out)
        if group["crumbs"]:
            print(f"    Letzte Schritte (Bericht {short_id(group['crumbsFrom'], ids_all)}):", file=out)
            for crumb in group["crumbs"]:
                print(f"      {crumb_line(crumb)}", file=out)
        ids = ", ".join(short_id(i, ids_all) for i in group["reportIDs"][:5]) + (" …" if len(group["reportIDs"]) > 5 else "")
        print(f"    Berichte: {ids}  (Details: --show ID)", file=out)
    if metrics:
        print("", file=out)
        print("Tageswerte (neuester Bericht je Kanal und Build):", file=out)
        for m in metrics[:8]:
            print(f"  {m['channel']} Build {m['build']} ({ms_to_local(m['createdAt'])[:10]}): {metric_text(m['values'])}", file=out)


DETAIL_KEYS = ["exceptionTypeName", "exceptionCode", "signalName", "terminationReason", "objcException", "stackDepth",
               "errorDomain", "errorCode", "state"]


def summarize_details(report: dict) -> str:
    details = report["details"]
    parts = [f"{k}={details[k]}" for k in DETAIL_KEYS if k in details]
    skip = set(DETAIL_KEYS) | {"source", "build", "reportingBuild", "operation", "durationMs", "thresholdMs",
                               "exceptionType", "signal", "exceptionName", "stackGuard", "test", "from", "to"}
    parts += [f"{k}={v}" for k, v in sorted(details.items()) if k not in skip]
    return ", ".join(parts)


def group_json(group: dict) -> dict:
    newest: Analysis = group["newest"]
    return {
        "key": group["key"], "kind": group["kind"], "headline": group["headline"], "pattern": group["pattern"],
        "hint": group["hint"], "count": group["count"], "builds": group["builds"], "channels": group["channels"],
        "phases": group["phases"], "firstSeen": ms_to_iso(group["firstSeen"]), "lastSeen": ms_to_iso(group["lastSeen"]),
        "durationsMs": group["durationsMs"], "abnormalExits": group["abnormalExits"], "reportIDs": group["reportIDs"],
        "newestReport": newest.report["id"],
        "recursion": {"frame": newest.recursion[0], "count": newest.recursion[1]} if newest.recursion else None,
        "details": {k: v for k, v in newest.report["details"].items()},
        "appFrames": [frame_json(i) for i in newest.app_infos[:20]],
        "systemTop": newest.system_top(),
        "breadcrumbs": group["crumbs"], "breadcrumbsFrom": group["crumbsFrom"],
    }


def frame_json(info: dict) -> dict:
    return {"image": info["image"], "offset": info["offset"], "function": info["function"], "note": info["note"]}


def show_report(report: dict, all_reports: list[dict], symbols: Symbolizer, as_json: bool, out) -> None:
    analysis = Analysis(report, symbols)
    related = [r for r in all_reports if r is not report and report.get("launchID")
               and r.get("launchID") == report.get("launchID")]
    crumbs = crumbs_before(report, None)
    later = [c for c in report["breadcrumbs"] if c["t"] > when(report)] if crumbs and crumbs[-1]["dt"] <= 0 else []
    if as_json:
        data = {k: v for k, v in report.items() if not k.startswith("_") and k != "payload"}
        data.update({"file": report["_path"], "headline": analysis.headline, "pattern": analysis.pattern,
                     "hint": analysis.hint, "groupKey": analysis.key, "payloadBytes": len(report.get("payload") or ""),
                     "callStack": [frame_json(i) for i in analysis.infos], "breadcrumbs": crumbs,
                     "related": [{"id": r["id"], "kind": r["kind"]} for r in related]})
        json.dump(data, out, ensure_ascii=False, indent=1)
        print(file=out)
        return
    app, device = report["app"], report.get("device") or {}
    print(f"{analysis.headline}", file=out)
    print(f"Bericht {report['id']} · {KIND_LABELS.get(report['kind'], report['kind'])}", file=out)
    print(f"Datei: {report['_path']}", file=out)
    print(f"Zeit: {ms_to_local(when(report))} (gesendet {ms_to_local(report['createdAt'])})", file=out)
    print(f"App: {app.get('channel')} {app.get('version')} Build {app.get('build')} Commit {app.get('commit') or '-'}"
          f" · Build des Problems: {build_of(report)}", file=out)
    print(f"Gerät: {device.get('model', '?')} iPadOS {device.get('os', '?')}", file=out)
    print(f"Start: {report.get('launchID') or '-'} · Phase: {report.get('launchPhase') or '-'}", file=out)
    print(f"Zusammenfassung: {report.get('summary') or '-'}", file=out)
    print(f"Signatur: {report.get('signature') or '-'}", file=out)
    if report["details"]:
        print("Angaben:", file=out)
        for key in sorted(report["details"]):
            print(f"  {key} = {report['details'][key]}", file=out)
    if analysis.recursion:
        print(f"Rekursion: {analysis.recursion[0]} ({analysis.recursion[1]}× auf dem Stapel)", file=out)
    if analysis.hint:
        print(f"Typische Ursache: {analysis.hint}", file=out)
    if related:
        print("Zum selben Start: " + ", ".join(f"{KIND_LABELS.get(r['kind'], r['kind'])} {r['id'][:8]}" for r in related),
              file=out)
    if report.get("payload"):
        print(f"MetricKit-Rohdaten: {len(report['payload'])} Zeichen (im Bericht unter payload)", file=out)
    print(f"Aufrufkette ({len(analysis.infos)} Frames, innen zuerst):", file=out)
    if not analysis.infos:
        print("  keine", file=out)
    for index, info in enumerate(analysis.infos):
        mark = "*" if info["app"] else " "
        print(f"  {index:3d} {mark} {frame_label(info, 240)}"
              + (f"  [{info['image']}+{info['offset']}]" if info["function"] else ""), file=out)
    print(f"Schritte vor dem Problem ({len(crumbs)}):", file=out)
    if not crumbs:
        print("  keine", file=out)
    for crumb in crumbs:
        print(f"  {crumb_line(crumb)}", file=out)
    if later:
        print(f"  ({len(later)} weitere Schritte danach)", file=out)


# ---------------------------------------------------------------------------


def parse_args(argv: list[str] | None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="noty-Fehlerberichte gruppiert und symbolisiert anzeigen.")
    parser.add_argument("--store", default=DEFAULT_STORE, help=f"Ablage des Servers (Standard {DEFAULT_STORE})")
    parser.add_argument("--binaries", default=DEFAULT_BINARIES, help=f"Binärdateien je Build (Standard {DEFAULT_BINARIES})")
    parser.add_argument("--since", default="14d", help="Zeitraum: 24h, 7d, 2w, JJJJ-MM-TT oder all (Standard 14d)")
    parser.add_argument("--channel", action="append", help="nur dieser Kanal (stable, dev, ai, calendar); mehrfach möglich")
    parser.add_argument("--build", action="append", help="nur dieser Build; mehrfach möglich")
    parser.add_argument("--kind", action="append", choices=KINDS, help="nur diese Art; mehrfach möglich")
    parser.add_argument("--all", action="store_true", help="auch Tageswerte und Testberichte als Gruppen zeigen")
    parser.add_argument("--show", metavar="ID", help="einen Bericht vollständig zeigen (ID-Anfang genügt)")
    parser.add_argument("--json", action="store_true", help="maschinenlesbare Ausgabe")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None, out=None) -> int:
    out = out or sys.stdout
    args = parse_args(argv)
    try:
        cutoff = parse_since(args.since)
    except argparse.ArgumentTypeError as error:
        print(error, file=sys.stderr)
        return 2
    store = Path(args.store)
    all_reports, skipped = load_store(store)
    symbols = Symbolizer(Path(args.binaries) if args.binaries else None)

    if args.show:
        prefix = args.show.strip().upper()
        matches = [r for r in all_reports if r["id"].upper().startswith(prefix)]
        if not matches:
            print(f"Kein Bericht mit ID {args.show} in {store}.", file=out)
            return 1
        if len(matches) > 1:
            print(f"{len(matches)} Berichte passen zu {args.show}:", file=out)
            for r in sorted(matches, key=when, reverse=True):
                print(f"  {r['id']}  {ms_to_local(when(r))}  {r['kind']}  {r.get('summary', '')}", file=out)
            return 1
        symbols.prepare(matches)
        show_report(matches[0], all_reports, symbols, args.json, out)
        return 0

    def wanted(report: dict) -> bool:
        if cutoff is not None and max(report["createdAt"], report.get("occurredAt") or 0) < cutoff:
            return False
        if args.channel and channel_of(report) not in args.channel:
            return False
        if args.build and build_of(report) not in args.build and str(report["app"].get("build")) not in args.build:
            return False
        return True

    selected = [r for r in all_reports if wanted(r)]
    metric_source = [r for r in selected if r["kind"] == "metrics"] if not args.kind or "metrics" in args.kind else []
    hidden = 0
    shown = []
    for report in selected:
        if args.kind and report["kind"] not in args.kind:
            continue
        if not args.all and is_hidden_kind(report) and not (args.kind and report["kind"] in args.kind and report["kind"] != "metrics"):
            hidden += 1
            continue
        shown.append(report)

    symbols.prepare(shown)
    groups = group_reports(shown, [r for r in all_reports], symbols)
    metrics = latest_metrics(metric_source)

    notes = []
    if skipped:
        notes.append(f"{skipped} Dateien übersprungen (unlesbar oder fremdes Format).")
    if hidden:
        notes.append(f"{hidden} Tageswert-/Testberichte ausgeblendet (--all zeigt sie).")
    if shown and not symbols.available:
        reason = "llvm-symbolizer fehlt" if not symbols.symbolizer else f"keine Binärdateien unter {args.binaries}"
        notes.append(f"Ohne Symbole: {reason}.")
    elif symbols.missing_builds:
        notes.append("Keine Binärdatei für Build " + ", ".join(sorted(symbols.missing_builds, key=lambda b: to_int(b) or 0))
                     + ": dort nur Adressen.")

    since_text = "alle Zeit" if cutoff is None else f"seit {ms_to_local(cutoff)}"
    if args.json:
        data = {"store": str(store), "since": ms_to_iso(cutoff), "skipped": skipped, "hidden": hidden,
                "symbolication": symbols.available, "missingBinaries": sorted(symbols.missing_builds),
                "groups": [group_json(g) for g in groups], "metrics": metrics}
        json.dump(data, out, ensure_ascii=False, indent=1)
        print(file=out)
        return 0

    if not groups and not metrics:
        where = store if store.is_dir() else f"{store} (nicht vorhanden)"
        print(f"Keine Berichte in {where} ({since_text}).", file=out)
        for note in notes:
            print(note, file=out)
        return 0
    header = f"{sum(g['count'] for g in groups)} Berichte in {len(groups)} Gruppen, {since_text}, neueste zuerst."
    print_groups(groups, metrics, header, notes, out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
