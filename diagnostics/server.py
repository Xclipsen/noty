#!/usr/bin/env python3
"""Empfang der noty-Fehlerberichte (docs/DIAGNOSE.md).

Kleiner Dienst nur mit der Python-Standardbibliothek. Er lauscht auf
127.0.0.1 und wird über nginx unter einem geheimen Pfad erreicht.

Annahme nur
- mit gültigem Build-Schlüssel (Header ``X-Noty-Key``; Schlüssel zeilenweise in
  ``NOTY_DIAG_KEYS_FILE``, nie im Repo),
- bis 1 MB pro Bericht,
- innerhalb der Ratenbegrenzung (pro Absender-IP und gesamt pro Tag),
- im Berichtsformat 1: genau die Felder aus ``DiagnosticReport.swift``, jedes
  mit Typ, Länge und Zeichenvorrat geprüft; unbekannte Felder, Steuerzeichen
  und Zeiten außerhalb 2020–2100 werden mit 400 abgelehnt.

Ablage: ``STORE/<kanal>/<build>/<zeit>-<art>-<id>.json``; dieselbe ID wird nur
einmal angenommen (409). Nach 90 Tagen wird gelöscht. Keine Weitergabe.

Umgebung: NOTY_DIAG_STORE, NOTY_DIAG_KEYS_FILE, NOTY_DIAG_PORT (8794),
NOTY_DIAG_RETENTION_DAYS (90), NOTY_DIAG_RATE (30 je 10 min und IP),
NOTY_DIAG_DAILY (2000).
"""
from __future__ import annotations

import hmac
import json
import os
import re
import sys
import threading
import time
from collections import deque
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

FORMAT_VERSION = 1
MAX_BYTES = 1_000_000
CHANNELS = {"stable", "dev", "ai", "calendar"}
KINDS = {"crash", "hang", "appHang", "cpu", "memory", "diskWrite", "launch", "slow",
         "failure", "abnormalExit", "metrics", "test"}

# The form is fixed (DiagnosticReport.swift): exactly these fields, nothing
# else. Swift, this file and scripts/diag_report.py change together, so an
# unknown field is an error and is not stored. Optional fields are left out by
# the app, never null.
REPORT_FIELDS = {"formatVersion", "id", "kind", "createdAt", "app", "device", "summary", "signature",
                 "details", "callStack", "breadcrumbs"}
REPORT_OPTIONAL = {"occurredAt", "launchID", "launchPhase", "payload"}
APP_FIELDS = {"channel", "bundleID", "version", "build", "commit"}
DEVICE_FIELDS = {"model", "os"}
FRAME_FIELDS, FRAME_OPTIONAL = {"image", "offset"}, {"uuid"}
CRUMB_FIELDS, CRUMB_OPTIONAL = {"t", "e"}, {"v"}

# What the app sends at most: DiagnosticJournal.capacity, DiagnosticReport.finalized
# (a stack over 512 frames is cut to 448, a payload over 600 000 bytes dropped).
MAX_BREADCRUMBS = 200
MAX_FRAMES = 512
MAX_PAYLOAD = 600_000
MAX_DETAILS = 64
MAX_VALUES = 32
# Milliseconds since 1970: 01.01.2020 up to 01.01.2100 for the report's own
# times. Breadcrumbs only need to stay inside what a date can hold.
MIN_MS = 1_577_836_800_000
MAX_MS = 4_102_444_800_000

# Every text is matched as a whole (fullmatch): "$" would let a trailing
# newline through. No class contains control characters, so none can reach the
# store, the journal or the terminal of scripts/diag_report.py.
SAFE_NAME = re.compile(r"[A-Za-z0-9._-]{1,48}")
REPORT_ID = re.compile(r"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}")
BUILD = re.compile(r"[0-9]{1,6}")
# Detail values: printable ASCII without slashes, as DiagnosticPrivacy.safeDetail.
SAFE_DETAIL = re.compile(r"[\x20-\x2e\x30-\x5b\x5d-\x7d]{0,160}")
# CFBundleShortVersionString, NotyCommit ("" locally, "-dirty" possible) and
# the bundle identifier; "?" where the app found none.
VERSION = re.compile(r"[A-Za-z0-9._+?-]{1,24}")
COMMIT = re.compile(r"[A-Za-z0-9._-]{0,48}")
BUNDLE_ID = re.compile(r"[A-Za-z0-9._?-]{1,160}")
# Hardware model (iPad17,1) and "iPadOS <version>".
MODEL = re.compile(r"[A-Za-z0-9,._?-]{1,32}")
SYSTEM = re.compile(r"iPadOS [A-Za-z0-9.]{1,24}|\?")
# Binary names (Noty, libc++.1.dylib, "?" when unknown) and Mach-O UUIDs.
IMAGE = re.compile(r"[A-Za-z0-9._+?-]{1,128}")
IMAGE_UUID = re.compile(REPORT_ID.pattern + r"|[0-9A-Fa-f]{32}")
# DiagnosticAnalysis.signature: kind:operation:pattern|image+0xoffset>…
SIGNATURE = re.compile(r"[A-Za-z0-9._:|>+?-]{1,700}")
# DiagnosticAnalysis.summary: fixed German words, detail values and frames on one line.
SUMMARY = re.compile(r"[\x20-\x2e\x30-\x5b\x5d-\x7dÄÖÜäöüß·×]{1,700}")
# MetricKit's JSON is not checked for content, but it is one line of text
# without control characters (C0, DEL, C1) or unpaired surrogates.
UNPRINTABLE = re.compile(r"[\x00-\x1f\x7f-\x9f\ud800-\udfff]")


class Rejected(Exception):
    def __init__(self, status: int, reason: str):
        super().__init__(reason)
        self.status = status
        self.reason = reason


def _fields(value: object, required: set, optional: set, reason: str) -> dict:
    """An object with all required and no unknown fields."""
    if not isinstance(value, dict) or not required <= value.keys() or not value.keys() <= required | optional:
        raise Rejected(400, reason)
    return value


def _text(value: object, pattern: re.Pattern, reason: str) -> str:
    if not isinstance(value, str) or not pattern.fullmatch(value):
        raise Rejected(400, reason)
    return value


def _whole(value: object, low: int, high: int, reason: str) -> int:
    """A whole number in low ..< high. JSON true is an int in Python and is not one here."""
    if type(value) is not int or not low <= value < high:
        raise Rejected(400, reason)
    return value


def validate(report: object) -> dict:
    """Checks the fixed form: every field with type, length and characters.

    Raises Rejected(400) with a short reason made of fixed words; the reason
    never repeats text from the report.
    """
    if not isinstance(report, dict):
        raise Rejected(400, "kein Objekt")
    if type(report.get("formatVersion")) is not int or report["formatVersion"] != FORMAT_VERSION:
        raise Rejected(400, "formatVersion")
    _fields(report, REPORT_FIELDS, REPORT_OPTIONAL, "Felder")
    if not isinstance(report["kind"], str) or report["kind"] not in KINDS:
        raise Rejected(400, "kind")
    _text(report["id"], REPORT_ID, "id")
    _whole(report["createdAt"], MIN_MS, MAX_MS, "createdAt")
    if "occurredAt" in report:
        _whole(report["occurredAt"], MIN_MS, MAX_MS, "occurredAt")

    app = _fields(report["app"], APP_FIELDS, set(), "app")
    if not isinstance(app["channel"], str) or app["channel"] not in CHANNELS:
        raise Rejected(400, "app.channel")
    _text(app["build"], BUILD, "app.build")
    _text(app["version"], VERSION, "app.version")
    _text(app["commit"], COMMIT, "app.commit")
    _text(app["bundleID"], BUNDLE_ID, "app.bundleID")
    device = _fields(report["device"], DEVICE_FIELDS, set(), "device")
    _text(device["model"], MODEL, "device.model")
    _text(device["os"], SYSTEM, "device.os")

    if "launchID" in report:
        _text(report["launchID"], REPORT_ID, "launchID")
    if "launchPhase" in report:
        _text(report["launchPhase"], SAFE_NAME, "launchPhase")
    _text(report["summary"], SUMMARY, "summary")
    _text(report["signature"], SIGNATURE, "signature")

    details = report["details"]
    if not isinstance(details, dict) or len(details) > MAX_DETAILS:
        raise Rejected(400, "details")
    for key, value in details.items():
        if not SAFE_NAME.fullmatch(key):
            raise Rejected(400, "details.?")
        _text(value, SAFE_DETAIL, "details." + key)

    crumbs = report["breadcrumbs"]
    if not isinstance(crumbs, list) or len(crumbs) > MAX_BREADCRUMBS:
        raise Rejected(400, "breadcrumbs")
    for crumb in crumbs:
        _fields(crumb, CRUMB_FIELDS, CRUMB_OPTIONAL, "breadcrumbs")
        _whole(crumb["t"], 0, MAX_MS, "breadcrumbs.t")
        _text(crumb["e"], SAFE_NAME, "breadcrumbs.e")
        if "v" in crumb:
            values = crumb["v"]
            if not isinstance(values, dict) or len(values) > MAX_VALUES:
                raise Rejected(400, "breadcrumbs.v")
            for key, value in values.items():
                if not SAFE_NAME.fullmatch(key):
                    raise Rejected(400, "breadcrumbs.v")
                _whole(value, -(1 << 63), 1 << 63, "breadcrumbs.v")  # Swift Int

    stack = report["callStack"]
    if not isinstance(stack, list) or len(stack) > MAX_FRAMES:
        raise Rejected(400, "callStack")
    for frame in stack:
        _fields(frame, FRAME_FIELDS, FRAME_OPTIONAL, "callStack.frame")
        _text(frame["image"], IMAGE, "callStack.image")
        _whole(frame["offset"], 0, 1 << 64, "callStack.offset")  # Swift UInt64
        if "uuid" in frame:
            _text(frame["uuid"], IMAGE_UUID, "callStack.uuid")

    if "payload" in report:
        payload = report["payload"]
        if not isinstance(payload, str) or len(payload) > MAX_PAYLOAD or UNPRINTABLE.search(payload):
            raise Rejected(400, "payload")
    return report


class RateLimiter:
    def __init__(self, per_ip: int, window: float, daily: int):
        self.per_ip, self.window, self.daily = per_ip, window, daily
        self.lock = threading.Lock()
        self.hits: dict[str, deque] = {}
        self.day: deque = deque()

    def allow(self, ip: str, now: float | None = None) -> bool:
        now = time.monotonic() if now is None else now
        with self.lock:
            while self.day and now - self.day[0] > 86_400:
                self.day.popleft()
            if len(self.day) >= self.daily:
                return False
            queue = self.hits.setdefault(ip, deque())
            while queue and now - queue[0] > self.window:
                queue.popleft()
            if len(queue) >= self.per_ip:
                return False
            queue.append(now)
            self.day.append(now)
            if len(self.hits) > 10_000:
                self.hits = {k: v for k, v in self.hits.items() if v}
            return True


class Store:
    def __init__(self, root: Path, retention_days: int):
        self.root = root
        self.retention_days = retention_days
        self.lock = threading.Lock()
        root.mkdir(parents=True, exist_ok=True)

    def save(self, report: dict, body: bytes) -> Path:
        channel, build, kind, rid = report["app"]["channel"], report["app"]["build"], report["kind"], report["id"].upper()
        folder = self.root / channel / build
        stamp = datetime.fromtimestamp(report["createdAt"] / 1000, tz=timezone.utc).strftime("%Y%m%dT%H%M%S")
        target = folder / f"{stamp}-{kind}-{rid}.json"
        with self.lock:
            folder.mkdir(parents=True, exist_ok=True, mode=0o750)
            if any(folder.glob(f"*-{rid}.json")):
                raise Rejected(409, "schon vorhanden")
            tmp = folder / f".{rid}.tmp"
            fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o640)
            with os.fdopen(fd, "wb") as handle:
                handle.write(body)
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(tmp, target)
        return target

    def prune(self, now: float | None = None) -> int:
        cutoff = (time.time() if now is None else now) - self.retention_days * 86_400
        removed = 0
        with self.lock:
            for path in self.root.glob("*/*/*.json"):
                try:
                    if path.stat().st_mtime < cutoff:
                        path.unlink()
                        removed += 1
                except FileNotFoundError:
                    pass
            for folder in sorted(self.root.glob("*/*"), reverse=True) + sorted(self.root.glob("*"), reverse=True):
                try:
                    if folder.is_dir() and not any(folder.iterdir()):
                        folder.rmdir()
                except OSError:
                    pass
        return removed


def load_keys(path: str | None) -> list[bytes]:
    if not path:
        return []
    try:
        lines = Path(path).read_text().splitlines()
    except OSError:
        return []
    return [line.strip().encode() for line in lines if len(line.strip()) >= 16 and not line.startswith("#")]


def make_handler(store: Store, keys_file: str | None, limiter: RateLimiter):
    class Handler(BaseHTTPRequestHandler):
        server_version = "noty-diagnostics"
        sys_version = ""
        protocol_version = "HTTP/1.1"

        def log_message(self, fmt, *args):  # nginx logs the requests; only the outcome here
            pass

        def reply(self, status: int, text: str):
            body = (json.dumps({"status": status, "text": text}) + "\n").encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            if self.path == "/v1/health":
                self.reply(200, "ok")
            else:
                self.reply(404, "unbekannt")

        def do_POST(self):
            try:
                self.handle_report()
            except Rejected as rejected:
                if rejected.status != 409:
                    sys.stderr.write(f"abgelehnt {rejected.status}: {rejected.reason}\n")
                self.reply(rejected.status, rejected.reason)

        def handle_report(self):
            if self.path != "/v1/report":
                raise Rejected(404, "unbekannt")
            presented = (self.headers.get("X-Noty-Key") or "").encode()
            keys = load_keys(keys_file)
            if not presented or not any(hmac.compare_digest(presented, key) for key in keys):
                raise Rejected(401, "Schlüssel")
            ip = self.headers.get("X-Real-IP") or self.client_address[0]
            if not limiter.allow(ip):
                raise Rejected(429, "zu viele Berichte")
            try:
                length = int(self.headers.get("Content-Length") or "-1")
            except ValueError:
                length = -1
            if length < 0:
                raise Rejected(411, "Länge fehlt")
            if length > MAX_BYTES:
                raise Rejected(413, "zu groß")
            body = self.rfile.read(length)
            try:
                # UTF-8 only, as the app writes it. Nesting or numbers beyond
                # the parser are not a report either.
                parsed = json.loads(body.decode("utf-8"))
            except (ValueError, RecursionError):
                raise Rejected(400, "kein JSON")
            report = validate(parsed)
            path = store.save(report, body)
            sys.stderr.write(f"angenommen {report['app']['channel']} {report['app']['build']} {report['kind']} {path.name}\n")
            self.reply(201, "angenommen")

    return Handler


def serve(store: Store, keys_file: str | None, port: int, limiter: RateLimiter, host: str = "127.0.0.1") -> ThreadingHTTPServer:
    server = ThreadingHTTPServer((host, port), make_handler(store, keys_file, limiter))
    server.daemon_threads = True
    return server


def main() -> None:
    store = Store(Path(os.environ.get("NOTY_DIAG_STORE", "/var/lib/noty-diagnostics/reports")),
                  int(os.environ.get("NOTY_DIAG_RETENTION_DAYS", "90")))
    keys_file = os.environ.get("NOTY_DIAG_KEYS_FILE", "/etc/noty-diagnostics/keys")
    if not load_keys(keys_file):
        sys.stderr.write(f"Keine Schlüssel in {keys_file}: jeder Bericht wird abgelehnt.\n")
    limiter = RateLimiter(int(os.environ.get("NOTY_DIAG_RATE", "30")), 600, int(os.environ.get("NOTY_DIAG_DAILY", "2000")))
    server = serve(store, keys_file, int(os.environ.get("NOTY_DIAG_PORT", "8794")), limiter)

    def prune_loop():
        while True:
            removed = store.prune()
            if removed:
                sys.stderr.write(f"{removed} alte Berichte gelöscht\n")
            time.sleep(6 * 3600)

    threading.Thread(target=prune_loop, daemon=True).start()
    sys.stderr.write(f"noty-diagnostics auf 127.0.0.1:{server.server_address[1]}, Ablage {store.root}\n")
    server.serve_forever()


if __name__ == "__main__":
    main()
