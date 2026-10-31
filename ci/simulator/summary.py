#!/usr/bin/env python3
"""Writes the per-key lines of the smoke test as a job summary (Markdown)."""
import json
import pathlib
import sys

out = pathlib.Path(sys.argv[1])
attachments = out / "attachments"
manifest = attachments / "manifest.json"

print("## Tasten im Simulator\n")
files = []
if manifest.exists():
    for test in json.loads(manifest.read_text()):
        for attachment in test.get("attachments", []):
            name = attachment.get("suggestedHumanReadableName", "")
            if name.startswith("tasten-"):
                files.append((name, attachments / attachment["exportedFileName"]))
if not files:
    print("Keine Ergebnisse: Der Test lief nicht bis zum Ende.")
for name, path in sorted(files):
    print(f"### {name.split('_', 1)[0].removeprefix('tasten-')}\n\n```\n{path.read_text()}```\n")
