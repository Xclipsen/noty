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


class ServerTests(unittest.TestCase):
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


if __name__ == "__main__":
    unittest.main()
