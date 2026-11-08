#!/usr/bin/env python3
"""Builds a noty material package (`.notymaterial`, docs/LERNFELDER.md) from a
captured learning platform folder: `struktur.json` (fields → chapters →
lessons with platform ids, script file per chapter), `index.json` (topic
units, page heads/headings, cited norms and lesson → page mapping, from
`skript_index.py`) and the script PDFs below it.

The package is a ZIP with stored entries: `catalog.json` (MaterialCatalog
format 1), `text.json` (page texts via pdftotext, search only) and
`pdf/<file>` per script. The app checks everything again on import.

Private material: write the package OUTSIDE any repository. This script
contains no content of its own.

    python3 -I scripts/build_material_package.py SOURCE_DIR OUT.notymaterial \
        --id steuer-azubis --title "Steuer-Azubis" \
        --lesson-url 'https://app.steuer-azubis.de/#/lektion/{id}' \
        --field-url 'https://app.steuer-azubis.de/#/lernfeld/{id}'
"""
import argparse
import hashlib
import json
import re
import subprocess
import sys
import zipfile
from pathlib import Path

SAFE_FILE = re.compile(r"(?:[A-Za-z0-9_-][A-Za-z0-9._-]*/){0,3}[A-Za-z0-9_-][A-Za-z0-9._-]*\.pdf")
IDENTIFIER = re.compile(r"[a-z0-9-]{1,64}")
UUID = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")


def clip(text, limit):
    text = " ".join(str(text or "").split())
    return text[:limit] if text else None


def page_range(pages, count):
    if not isinstance(pages, list) or len(pages) != 2:
        return None
    first, last = int(pages[0]), int(pages[1])
    if 1 <= first <= last <= count:
        return [first, last]
    return None


def norms(values):
    out = []
    for value in values or []:
        text = clip(value, 120)
        if text and text not in out:
            out.append(text)
    return out[:200]


def page_texts(pdf, count):
    result = subprocess.run(["pdftotext", "-enc", "UTF-8", "-layout", str(pdf), "-"], capture_output=True, check=True)
    pages = result.stdout.decode("utf-8", "replace").split("\f")
    texts = [" ".join(page.split())[:150_000] for page in pages[:count]]
    return texts + [""] * (count - len(texts))


def build(source, out, package_id, title, lesson_url, field_url):
    if not IDENTIFIER.fullmatch(package_id):
        sys.exit("--id: nur a-z, 0-9 und -")
    structure = json.loads((source / "struktur.json").read_text(encoding="utf-8"))
    index = json.loads((source / "index.json").read_text(encoding="utf-8"))
    files = {entry["file"]: entry for entry in index["dateien"]}
    fields, texts, scripts, warnings = [], {}, [], []

    for field in structure["lernfelder"]:
        number = int(field["nummer"])
        chapters = []
        for chapter in field["kapitel"]:
            position = int(chapter["index"])
            key = f"LF{number:02d}-{position:02d}"
            part = chapter.get("teil")
            entry = {"key": key, "index": position, "number": int(chapter["nummer"]),
                     "title": clip(chapter["titel"], 300) or f"Kapitel {chapter['nummer']}",
                     "preface": bool(chapter.get("vorwort")), "lessons": [], "units": [], "pages": []}
            if isinstance(part, dict) and part.get("nummer"):
                entry["part"] = int(part["nummer"])
            script = chapter.get("skript") or {}
            info = files.get(script.get("datei") or "")
            count = 0
            if script.get("datei") and script.get("status") == "geladen" and info is not None:
                rel = script["datei"]
                if not SAFE_FILE.fullmatch(rel):
                    warnings.append(f"{key}: unsicherer Dateiname {rel!r}, Skript ausgelassen")
                else:
                    pdf = source / rel
                    data = pdf.read_bytes()
                    count = int(info["pages"])
                    digest = hashlib.sha256(data).hexdigest()
                    entry["script"] = {"file": rel, "pageCount": count, "byteCount": len(data), "sha256": digest}
                    scripts.append((rel, pdf))
                    texts[rel] = page_texts(pdf, count)
            mapping = {item["lessonId"]: item.get("seiten") for item in (info or {}).get("lektionsZuordnung", []) if item.get("lessonId")}
            for item in chapter["items"]:
                if item.get("kind") != "lektion" or not item.get("lessonId"):
                    continue
                lesson_id = item["lessonId"].lower()
                if not UUID.fullmatch(lesson_id):
                    warnings.append(f"{key}: Lektion ohne gültige Kennung ausgelassen")
                    continue
                lesson = {"id": lesson_id, "title": clip(item.get("titel"), 300) or "Lektion", "order": int(item.get("reihenfolge") or 0)}
                if item.get("dauerSek") is not None:
                    lesson["seconds"] = int(item["dauerSek"])
                pages = page_range(mapping.get(item["lessonId"]), count)
                if pages:
                    lesson["pages"] = pages
                entry["lessons"].append(lesson)
            if count:
                for unit in (info or {}).get("einheiten", []):
                    pages = page_range(unit.get("seiten"), count)
                    name = clip(unit.get("thema"), 300)
                    if not pages or not name:
                        continue
                    headings = [h for h in (clip(h, 300) for h in unit.get("ueberschriften", [])) if h][:200]
                    entry["units"].append({"title": name, "pages": pages, "headings": headings, "norms": norms(unit.get("normen"))})
                for page in (info or {}).get("seiten", []):
                    number_ = int(page["seite"])
                    if not 1 <= number_ <= count:
                        continue
                    value = {"page": number_, "norms": norms(page.get("normen"))}
                    if clip(page.get("kopf"), 300):
                        value["head"] = clip(page.get("kopf"), 300)
                    if clip(page.get("ueberschrift"), 300):
                        value["heading"] = clip(page.get("ueberschrift"), 300)
                    entry["pages"].append(value)
            chapters.append(entry)
        value = {"number": number, "title": clip(field.get("titel") or field.get("untertitel"), 300) or f"Lernfeld {number}",
                 "chapters": chapters}
        if field.get("courseId") and IDENTIFIER.fullmatch(field["courseId"].lower()):
            value["courseID"] = field["courseId"].lower()
        fields.append(value)

    catalog = {"format": 1, "id": package_id, "title": title, "lessonURL": lesson_url, "fieldURL": field_url,
               "created": (structure.get("erfasst") or "")[:40] or None, "fields": fields}
    catalog = {k: v for k, v in catalog.items() if v is not None}
    out.parent.mkdir(parents=True, exist_ok=True)
    temporary = out.with_suffix(out.suffix + ".part")
    with zipfile.ZipFile(temporary, "w", compression=zipfile.ZIP_STORED, allowZip64=False) as archive:
        archive.writestr("catalog.json", json.dumps(catalog, ensure_ascii=False, separators=(",", ":")))
        archive.writestr("text.json", json.dumps({"format": 1, "pages": texts}, ensure_ascii=False, separators=(",", ":")))
        for rel, pdf in scripts:
            archive.write(pdf, "pdf/" + rel)
    temporary.replace(out)
    lessons = sum(len(c["lessons"]) for f in fields for c in f["chapters"])
    mapped = sum(1 for f in fields for c in f["chapters"] for l in c["lessons"] if "pages" in l)
    print(f"{out}: {len(fields)} Lernfelder, {sum(len(f['chapters']) for f in fields)} Kapitel, {len(scripts)} Skripte, "
          f"{lessons} Lektionen ({mapped} mit Skriptseiten), {out.stat().st_size / 1e6:.1f} MB")
    for warning in warnings:
        print("Hinweis:", warning)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("source", type=Path)
    parser.add_argument("out", type=Path)
    parser.add_argument("--id", required=True)
    parser.add_argument("--title", required=True)
    parser.add_argument("--lesson-url")
    parser.add_argument("--field-url")
    args = parser.parse_args()
    build(args.source, args.out, args.id, args.title, args.lesson_url, args.field_url)


if __name__ == "__main__":
    main()
