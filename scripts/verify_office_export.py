#!/usr/bin/env python3
"""Check a `.docx` or `.rtf` export independently, without printing its text.

A `.docx` must be a sound ZIP with well-formed XML parts, declared content
types, resolving relationships and only paragraph styles and numbering that
exist. `--expect` names the page breaks, paragraph styles and links it must
hold. Every rule raises ValueError, so `python -O` keeps them.
"""
import argparse
import json
import re
import sys
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path
from posixpath import dirname, normpath

W = "{http://schemas.openxmlformats.org/wordprocessingml/2006/main}"
R = "{http://schemas.openxmlformats.org/officeDocument/2006/relationships}"
REL = "{http://schemas.openxmlformats.org/package/2006/relationships}"
TYPES = "{http://schemas.openxmlformats.org/package/2006/content-types}"
REQUIRED = ("[Content_Types].xml", "_rels/.rels", "word/document.xml", "word/styles.xml", "word/numbering.xml")


def check(condition, message):
    if not condition:
        raise ValueError(message)


def word(path):
    check(zipfile.is_zipfile(path), "Not a ZIP container")
    with zipfile.ZipFile(path) as archive:
        check(archive.testzip() is None, "ZIP entry fails its CRC")
        names = archive.namelist()
        check(len(names) == len(set(names)), "Duplicate ZIP entries")
        check(names[0] == "[Content_Types].xml", "Content types are not the first entry")
        for name in REQUIRED:
            check(name in names, f"Missing part {name}")
        parts = {}
        for name in names:
            check(not name.startswith("/") and ".." not in name.split("/"), "Unsafe entry name")
            try:
                parts[name] = ET.fromstring(archive.read(name))
            except ET.ParseError:
                raise ValueError(f"Malformed XML in {name}") from None

    types = parts["[Content_Types].xml"]
    defaults = {item.get("Extension") for item in types.findall(TYPES + "Default")}
    overrides = {item.get("PartName") for item in types.findall(TYPES + "Override")}
    for name in names:
        if name != "[Content_Types].xml":
            check("/" + name in overrides or name.rsplit(".", 1)[-1] in defaults, f"No content type for {name}")
    for override in overrides:
        check(override.lstrip("/") in names, f"Content type for missing part {override}")

    links = {}
    for name in names:
        if not name.endswith(".rels"):
            continue
        base = dirname(dirname(name))
        ids = set()
        for item in parts[name].findall(REL + "Relationship"):
            check(item.get("Id") not in ids, "Duplicate relationship id")
            ids.add(item.get("Id"))
            if item.get("TargetMode") == "External":
                check(item.get("Target"), "Empty external target")
                if name == "word/_rels/document.xml.rels":
                    links[item.get("Id")] = item.get("Target")
            else:
                check(normpath(f"{base}/{item.get('Target')}".lstrip("/")) in names, f"Relationship to a missing part: {item.get('Target')}")

    document = parts["word/document.xml"]
    body = document.find(W + "body")
    check(body is not None and body.find(W + "sectPr") is not None, "No document body with section")
    styles = {item.get(W + "styleId") for item in parts["word/styles.xml"].findall(W + "style")}
    numbering = parts["word/numbering.xml"]
    abstract = {item.get(W + "abstractNumId") for item in numbering.findall(W + "abstractNum")}
    nums = {}
    for item in numbering.findall(W + "num"):
        target = item.find(W + "abstractNumId").get(W + "val")
        check(target in abstract, "List without its definition")
        nums[item.get(W + "numId")] = target
    used, list_levels = [], 0
    for paragraph in document.iter(W + "p"):
        properties = paragraph.find(W + "pPr")
        if properties is None:
            continue
        style = properties.find(W + "pStyle")
        if style is not None:
            check(style.get(W + "val") in styles, "Paragraph style without a definition")
            used.append(style.get(W + "val"))
        number = properties.find(W + "numPr")
        if number is not None:
            check(number.find(W + "numId").get(W + "val") in nums, "Paragraph in an undefined list")
            check(0 <= int(number.find(W + "ilvl").get(W + "val")) <= 8, "List level out of range")
            list_levels += 1
    hyperlinks = 0
    for item in document.iter(W + "hyperlink"):
        check(item.get(R + "id") in links, "Link without a target")
        hyperlinks += 1
    for item in document.iter(W + "rStyle"):
        check(item.get(W + "val") in styles, "Character style without a definition")
    breaks = sum(1 for item in document.iter(W + "br") if item.get(W + "type") == "page")
    text = "".join(item.text or "" for item in document.iter(W + "t"))
    check(not re.search("[\x00-\x08\x0b\x0c\x0e-\x1f]", text), "Control character in the text")
    return {"kind": "docx", "paragraphs": sum(1 for _ in document.iter(W + "p")), "pageBreaks": breaks,
            "styles": sorted(set(used)), "listParagraphs": list_levels, "links": hyperlinks,
            "formats": sorted(name for name in ("b", "i", "u", "strike", "color", "highlight", "shd")
                              if next(document.iter(W + name), None) is not None)}


def rtf(path):
    data = path.read_bytes()
    check(data.startswith(b"{\\rtf1"), "No RTF header")
    check(all(byte < 128 for byte in data), "RTF must stay 7-bit")
    depth = 0
    index = 0
    while index < len(data):
        byte = data[index]
        if byte == 0x5C:
            index += 2
            continue
        if byte == 0x7B:
            depth += 1
        elif byte == 0x7D:
            depth -= 1
            check(depth >= 0, "Unbalanced groups")
        index += 1
    check(depth == 0, "Unbalanced groups")
    return {"kind": "rtf", "pageBreaks": data.count(b"\\page\n"), "links": data.count(b"HYPERLINK")}


def verify(path):
    path = Path(path)
    check(path.is_file(), "No such file")
    return word(path) if path.suffix == ".docx" else rtf(path)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("file", type=Path)
    parser.add_argument("--expect", type=json.loads, default={}, help="JSON object of report values that must match")
    arguments = parser.parse_args()
    report = verify(arguments.file)
    for key, value in arguments.expect.items():
        check(report.get(key) == value, f"Expected {key} = {value}, found {report.get(key)}")
    print(json.dumps(report))
