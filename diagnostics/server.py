#!/usr/bin/env python3
"""Empfang der noty-Fehlerberichte (docs/DIAGNOSE.md).

Kleiner Dienst nur mit der Python-Standardbibliothek. Er lauscht auf
127.0.0.1 und wird über nginx unter einem geheimen Pfad erreicht.

Annahme nur
- mit gültigem Build-Schlüssel (Header ``X-Noty-Key``; Schlüssel zeilenweise in
  ``NOTY_DIAG_KEYS_FILE``, nie im Repo),
- bis 1 MB pro Bericht,
- innerhalb der Ratenbegrenzung (pro Absender-IP und gesamt pro Tag),
- im Berichtsformat 1 mit festen Namen in Ereignissen und Angaben.

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
SAFE_NAME = re.compile(r"^[A-Za-z0-9._-]{1,48}$")
REPORT_ID = re.compile(r"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$")
BUILD = re.compile(r"^[0-9]{1,6}$")
# Detail values: printable ASCII without slashes, as DiagnosticPrivacy.safeDetail.
SAFE_DETAIL = re.compile(r"^[\x20-\x2e\x30-\x5b\x5d-\x7d]{0,160}$")


class Rejected(Exception):
    def __init__(self, status: int, reason: str):
        super().__init__(reason)
        self.status = status
        self.reason = reason


def validate(report: object) -> dict:
    """Checks the fixed form; raises Rejected(400) with a short reason."""
    if not isinstance(report, dict):
        raise Rejected(400, "kein Objekt")
    if report.get("formatVersion") != FORMAT_VERSION:
        raise Rejected(400, "formatVersion")
    if report.get("kind") not in KINDS:
        raise Rejected(400, "kind")
    if not isinstance(report.get("id"), str) or not REPORT_ID.match(report["id"]):
        raise Rejected(400, "id")
    if not isinstance(report.get("createdAt"), int):
        raise Rejected(400, "createdAt")
    app = report.get("app")
    if not isinstance(app, dict) or app.get("channel") not in CHANNELS:
        raise Rejected(400, "app.channel")
    if not isinstance(app.get("build"), str) or not BUILD.match(app["build"]):
        raise Rejected(400, "app.build")
    if not isinstance(report.get("device"), dict):
        raise Rejected(400, "device")
    details = report.get("details", {})
    if not isinstance(details, dict):
        raise Rejected(400, "details")
    for key, value in details.items():
        if not SAFE_NAME.match(key) or not isinstance(value, str) or not SAFE_DETAIL.match(value):
            raise Rejected(400, "details." + (key if SAFE_NAME.match(key) else "?"))
    crumbs = report.get("breadcrumbs", [])
    if not isinstance(crumbs, list) or len(crumbs) > 1000:
        raise Rejected(400, "breadcrumbs")
    for crumb in crumbs:
        if not isinstance(crumb, dict) or not isinstance(crumb.get("e"), str) or not SAFE_NAME.match(crumb["e"]):
            raise Rejected(400, "breadcrumbs.e")
        values = crumb.get("v") or {}
        if not isinstance(values, dict) or any(not SAFE_NAME.match(k) or not isinstance(v, int) for k, v in values.items()):
            raise Rejected(400, "breadcrumbs.v")
    stack = report.get("callStack", [])
    if not isinstance(stack, list) or len(stack) > 4096:
        raise Rejected(400, "callStack")
    for frame in stack:
        if not isinstance(frame, dict) or not isinstance(frame.get("offset"), int) or not isinstance(frame.get("image"), str):
            raise Rejected(400, "callStack.frame")
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
                report = validate(json.loads(body))
            except (ValueError, UnicodeDecodeError):
                raise Rejected(400, "kein JSON")
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
