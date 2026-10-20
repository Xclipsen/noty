"""Shared read-only schema audit; never prints private note contents.

Every rule is an explicit check raising ValueError, so `python -O` (which
drops `assert`) cannot weaken it. Malformed structure (missing keys, wrong
types) is reported as ValueError, too. Mirrors the Swift validation in
Core/Sources/NotebookCore.
"""
import base64
import functools
import math
import re
import unicodedata

UUID_PATTERN = re.compile(r"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}")
PDF_SOURCE_LIMIT = 100_000_000
LEGACY_PDF_SOURCE_LIMIT = 20_000_000  # Build 46; larger sources need schema 10
PDF_SOURCES_TOTAL_LIMIT = 100_000_000
IMAGE_LIMIT = 20_000_000
IMAGES_TOTAL_LIMIT = 40_000_000
# Foundation dates: seconds since 2001 (JSONEncoder default); Swift accepts years 1…9999.
REFERENCE_DATE_UNIX = 978_307_200
UNIX_RANGE = (-62_135_596_800, 253_402_300_799)


def check(condition, message="Invalid notebook data"):
    """Explicit replacement for assert; also active under python -O."""
    if not condition:
        raise ValueError(message)


def strict(function):
    """Report malformed input (missing keys, wrong types) as ValueError."""
    @functools.wraps(function)
    def wrapper(*args, **kwargs):
        try:
            return function(*args, **kwargs)
        except (KeyError, TypeError, AttributeError, IndexError) as error:
            raise ValueError(f"Malformed data ({type(error).__name__})") from None
    return wrapper


def number(value):
    return type(value) in (int, float) and math.isfinite(value)


def uuid_string(value, message="Invalid identity"):
    """Swift UUID decoding: canonical hyphenated form only (no braces/URN)."""
    check(isinstance(value, str) and UUID_PATTERN.fullmatch(value) is not None, message)
    return value.upper()


def base64_bytes(value):
    check(isinstance(value, str), "Binary data is not Base64 text")
    try:
        return base64.b64decode(value, validate=True)
    except ValueError:
        raise ValueError("Invalid Base64 data") from None


def foundation_date(value, message="Date outside supported range"):
    check(number(value), message)
    check(UNIX_RANGE[0] <= value + REFERENCE_DATE_UNIX <= UNIX_RANGE[1], message)


_TRIMMED = set("\t\n\x0b\x0c\r\x85")


def valid_title(value):
    """LibraryStore.validTitle: trimmed, 1…120 characters, no control/format
    characters. Python cannot count grapheme clusters exactly; a conservative
    lower bound only rejects titles Swift rejects, too."""
    if not isinstance(value, str):
        return False
    start, end = 0, len(value)
    trims = lambda c: c in _TRIMMED or unicodedata.category(c) in ("Zs", "Zl", "Zp")
    while start < end and trims(value[start]):
        start += 1
    while end > start and trims(value[end - 1]):
        end -= 1
    name = value[start:end]
    if not name or any(unicodedata.category(c) in ("Cc", "Cf") for c in name):
        return False
    starts = 0
    regional = 0
    for c in name:
        code = ord(c)
        if 0x1F1E6 <= code <= 0x1F1FF:
            regional += 1
        elif not (unicodedata.category(c).startswith("M") or 0x1F3FB <= code <= 0x1F3FF
                  or 0x1160 <= code <= 0x11FF or 0xD7B0 <= code <= 0xD7FF):
            starts += 1
    return starts + regional // 2 <= 120


def color(value):
    check(all(number(value[k]) and 0 <= value[k] <= 1 for k in ("red", "green", "blue", "alpha")), "Invalid color")


@strict
def geometry(value):
    boxes = []
    for key in ("mediaBox", "cropBox"):
        box = value[key]
        check(all(number(box[k]) for k in ("x", "y", "width", "height")), "Invalid page box")
        check(box["width"] > 0 and box["height"] > 0, "Invalid page box")
        boxes.append(box)
    a, b = boxes
    w = min(a["x"] + a["width"], b["x"] + b["width"]) - max(a["x"], b["x"])
    h = min(a["y"] + a["height"], b["y"] + b["height"]) - max(a["y"], b["y"])
    check(1 <= w <= 14_400 and 1 <= h <= 14_400 and value["rotation"] in (0, 90, 180, 270), "Invalid page geometry")
    check(type(value["rotation"]) is int, "Invalid page rotation")


@strict
def text_style(style):
    check(style["font"] in ("system", "serif", "monospaced"), "Unknown text font")
    check(style["color"] in ("black", "white", "blue", "red"), "Unknown text color")
    check(number(style["fontSize"]) and 8 <= style["fontSize"] <= 96, "Invalid font size")
    check(all(type(style[k]) is bool for k in ("bold", "italic", "underline")), "Invalid text style")
    check(style.get("highlighted") is None or type(style["highlighted"]) is bool, "Invalid text style")
    check(style.get("alignment") in (None, "left", "center", "right", "justified"), "Unknown text alignment")
    indent = style.get("indent")
    check(indent is None or (number(indent) and 0 <= indent <= 240), "Invalid indent")
    font_name = style.get("fontName")
    check(font_name is None or (isinstance(font_name, str) and 0 < len(font_name.encode("utf-8")) <= 200), "Invalid font name")
    check(style.get("strikethrough") is None or type(style["strikethrough"]) is bool, "Invalid text style")
    check(style.get("baseline") is None or (type(style["baseline"]) is int and -1 <= style["baseline"] <= 1), "Invalid baseline")
    check(style.get("automaticColor") is None or type(style["automaticColor"]) is bool, "Invalid automatic color")
    if style.get("automaticColor") is True:
        check(style.get("ink") is None and style["color"] in ("black", "white"), "Invalid automatic color")
    check(style.get("highlightColor") in (None, "yellow", "green", "blue", "pink", "orange", "purple"), "Unknown highlight color")
    if style.get("ink") is not None:
        color(style["ink"])
    link = style.get("link")
    if link is not None:
        from urllib.parse import urlsplit
        check(isinstance(link, str) and len(link.encode("utf-8")) <= 2048, "Invalid link")
        check(urlsplit(link).scheme.lower() in ("http", "https", "mailto"), "Invalid link")


@strict
def appearance(value):
    if value is None:
        return
    check(type(value["coverEnabled"]) is bool and type(value["landscape"]) is bool, "Invalid appearance")
    check(value["cover"] in ("blue", "purple", "green", "yellow", "coral", "gray"), "Unknown cover")
    check(value["format"] in ("a4", "a5", "a3", "letter"), "Unknown paper format")
    check(value["paper"] in ("blank", "lined", "grid"), "Unknown paper style")
    check(value["color"] in ("white", "dark"), "Unknown paper color")


def _page_size(page):
    w, h = 595, 842
    if page.get("geometry"):
        g = page["geometry"]; a, b = g["mediaBox"], g["cropBox"]
        w = min(a["x"] + a["width"], b["x"] + b["width"]) - max(a["x"], b["x"])
        h = min(a["y"] + a["height"], b["y"] + b["height"]) - max(a["y"], b["y"])
        if g["rotation"] in (90, 270):
            w, h = h, w
    return w, h


def _text_boxes(page, version, text_ids):
    check(version >= 4 and page["text"] == "" and len(page["textBoxes"]) <= 200, "Invalid text layer")
    flow_ids = set()
    for box in page["textBoxes"]:
        flow = box.get("flowID")
        region = box.get("flowRegion")
        check((flow is None) == (region is None), "Invalid text flow")
        if flow is not None:
            check(version >= 8 and region in ("page", "left", "right", "top", "bottom"), "Invalid text flow")
            flow = uuid_string(flow)
            check(flow not in flow_ids, "Duplicate text flow on one page")
            flow_ids.add(flow)
        box_id = uuid_string(box["id"])
        check(box_id not in text_ids, "Duplicate text object identities")
        text_ids.add(box_id)
        check(all(number(box[k]) for k in ("x", "y", "width", "height")), "Invalid text frame")
        check(abs(box["x"]) <= 14_400 and abs(box["y"]) <= 14_400, "Invalid text frame")
        check(1 <= box["width"] <= 14_400 and 1 <= box["height"] <= 14_400, "Invalid text frame")
        check(isinstance(box["text"], str) and len(box["text"].encode("utf-8")) <= 1_000_000, "Invalid text")
        for style in [box["style"]] + [r["style"] for r in box.get("runs") or []]:
            if any(style.get(k) is not None for k in ("fontName", "ink", "strikethrough", "baseline")):
                check(version >= 8, "Text style needs schema 8")
            if any(style.get(k) is not None for k in ("automaticColor", "highlightColor")):
                check(version >= 9, "Text color needs schema 9")
        text_style(box["style"])
        if any(box["style"].get(k) is not None for k in ("highlighted", "alignment", "indent", "link")):
            check(version >= 7, "Text style needs schema 7")
        if box.get("runs") is not None:
            check(version >= 7 and len(box["runs"]) <= 50_000, "Invalid text runs")
            units = box["text"].encode("utf-16-le")
            count = len(units) // 2
            end = 0
            for run in box["runs"]:
                a, n = run["location"], run["length"]
                check(type(a) is int and type(n) is int and end <= a <= count and 0 < n <= count - a, "Invalid text run")
                for boundary in (a, a + n):
                    check(boundary in (0, count) or not 0xDC00 <= int.from_bytes(units[boundary * 2:boundary * 2 + 2], "little") <= 0xDFFF,
                          "Text run splits a surrogate pair")
                end = a + n
                text_style(run["style"])


def _shapes(page, version, shape_ids):
    check(version >= 6 and len(page["shapes"]) <= 500, "Invalid shape layer")
    w, h = _page_size(page)
    m = page.get("margins") or {}
    for shape in page["shapes"]:
        shape_id = uuid_string(shape["id"])
        check(shape_id not in shape_ids, "Duplicate shape identities")
        shape_ids.add(shape_id)
        check(shape["kind"] in ("line", "arrow", "rectangle", "ellipse"), "Unknown shape kind")
        check(shape["pattern"] in ("solid", "dashed", "dotted"), "Unknown stroke pattern")
        points = [shape[p][k] for p in ("start", "end") for k in ("x", "y")]
        check(all(number(v) and abs(v) <= 14_400 for v in points), "Invalid shape points")
        width = shape["lineWidth"]
        check(number(width) and 0.5 <= width <= 40, "Invalid line width")
        a, b = shape["start"], shape["end"]
        check(math.hypot(a["x"] - b["x"], a["y"] - b["y"]) >= 1, "Shape too small")
        if shape["kind"] in ("rectangle", "ellipse"):
            check(abs(a["x"] - b["x"]) >= 1 and abs(a["y"] - b["y"]) >= 1, "Shape too small")
        color(shape["color"])
        if shape.get("fill") is not None:
            color(shape["fill"])
        pad = max(10, width * 3) if shape["kind"] == "arrow" else width / 2
        check(min(a["x"], b["x"]) - pad >= -m.get("left", 0) - 0.02, "Shape outside page")
        check(min(a["y"], b["y"]) - pad >= -m.get("top", 0) - 0.02, "Shape outside page")
        check(max(a["x"], b["x"]) + pad <= w + m.get("right", 0) + 0.02, "Shape outside page")
        check(max(a["y"], b["y"]) + pad <= h + m.get("bottom", 0) + 0.02, "Shape outside page")


def _images(page, version, image_ids):
    check(version >= 5 and len(page["images"]) <= 50, "Invalid image layer")
    total = 0
    w, h = _page_size(page)
    margin = page.get("margins") or {}
    for image in page["images"]:
        image_id = uuid_string(image["id"])
        check(image_id not in image_ids, "Duplicate image identities")
        image_ids.add(image_id)
        original = base64_bytes(image["data"])
        check(1 <= len(original) <= IMAGE_LIMIT, "Image original outside size limit")
        total += len(original)
        check(all(type(image[k]) is int and 1 <= image[k] <= 100_000 for k in ("pixelWidth", "pixelHeight")), "Invalid image size")
        check(image["pixelWidth"] * image["pixelHeight"] <= 200_000_000, "Image exceeds 200 megapixels")
        check(all(number(image[k]) for k in ("x", "y", "width", "height", "rotation")), "Invalid image frame")
        check(abs(image["x"]) <= 14_400 and abs(image["y"]) <= 14_400, "Invalid image frame")
        check(1 <= image["width"] <= 14_400 and 1 <= image["height"] <= 14_400, "Invalid image frame")
        check(-180 <= image["rotation"] <= 180 and type(image["locked"]) is bool, "Invalid image frame")
        crop = image["crop"]
        check(all(number(crop[k]) for k in ("x", "y", "width", "height")), "Invalid image crop")
        check(crop["x"] >= 0 and crop["y"] >= 0 and crop["width"] >= 0.0199999 and crop["height"] >= 0.0199999, "Invalid image crop")
        check(crop["x"] + crop["width"] <= 1.0000001 and crop["y"] + crop["height"] <= 1.0000001, "Invalid image crop")
        radians = math.radians(image["rotation"])
        rw = abs(math.cos(radians)) * image["width"] + abs(math.sin(radians)) * image["height"]
        rh = abs(math.sin(radians)) * image["width"] + abs(math.cos(radians)) * image["height"]
        x, y = image["x"] + (image["width"] - rw) / 2, image["y"] + (image["height"] - rh) / 2
        check(x >= -margin.get("left", 0) - 0.01 and y >= -margin.get("top", 0) - 0.01, "Image outside page")
        check(x + rw <= w + margin.get("right", 0) + 0.01 and y + rh <= h + margin.get("bottom", 0) + 0.01, "Image outside page")
    return total


@strict
def validate_notebook(document):
    """Validates one notebook and returns its external image assets as
    {sha256: byteCount}. Schema <= 11 embeds every original in the JSON, so the
    result is empty until schema 12 (archive format 2 already carries asset
    records for such references)."""
    check(isinstance(document, dict), "Notebook is not an object")
    version = document["schemaVersion"]
    check(type(version) is int and version in range(1, 12), "Unsupported notebook schema")
    uuid_string(document["id"])
    check(isinstance(document["title"], str), "Invalid notebook title")
    if document.get("appearance") is not None:
        check(version >= 7, "Appearance needs schema 7")
        appearance(document["appearance"])
    active = document["pages"]
    deleted = document.get("deletedPages") or []
    check(isinstance(active, list) and isinstance(deleted, list), "Invalid page list")
    check(1 <= len(active) <= 500 and len(deleted) <= 500, "Page count outside limits")
    pages = active + [entry["page"] for entry in deleted]
    page_ids = [uuid_string(p["id"]) for p in pages]
    check(len(set(page_ids)) == len(pages), "Duplicate page identities")
    text_ids, image_ids, shape_ids = set(), set(), set()
    image_bytes = 0
    for page in pages:
        base64_bytes(page["drawing"])
        check(isinstance(page["text"], str), "Invalid page text")
        if page.get("textBoxes") is not None:
            _text_boxes(page, version, text_ids)
        if page.get("geometry") is not None:
            check(version >= 2, "Geometry needs schema 2")
            geometry(page["geometry"])
        if page.get("shapes") is not None:
            _shapes(page, version, shape_ids)
        if page.get("images") is not None:
            image_bytes += _images(page, version, image_ids)
    check(image_bytes <= IMAGES_TOTAL_LIMIT, "Image originals exceed 40 MB")
    check(image_ids.isdisjoint(text_ids) and shape_ids.isdisjoint(text_ids | image_ids), "Object identities overlap")
    if document.get("pdfSources") is None:
        check(document.get("deletedPages") is None, "Page trash needs PDF sources representation")
        check(all(all(p.get(key) is None for key in ("pdfReference", "paper", "paperColor", "bookmarked", "margins")) for p in pages),
              "Page fields need schema 3 representation")
        if document.get("pdf") is not None:
            base64_bytes(document["pdf"])
        return {}
    check(version >= 3 and document.get("pdf") is None, "Invalid PDF source representation")
    sources = document["pdfSources"]
    check(isinstance(sources, list) and len(sources) <= 500, "Too many PDF sources")
    lookup = {}
    total = 0
    for source in sources:
        source_id = uuid_string(source["id"])
        check(source_id not in lookup, "Duplicate PDF source identities")
        data = base64_bytes(source["data"])
        check(1 <= len(data) <= PDF_SOURCE_LIMIT, "PDF original outside size limit")
        check(len(data) <= LEGACY_PDF_SOURCE_LIMIT or version >= 10, "PDF original above 20 MB needs schema 10")
        check(type(source["pageCount"]) is int and 1 <= source["pageCount"] <= 500, "Invalid PDF page count")
        total += len(data)
        lookup[source_id] = source["pageCount"]
    check(total <= PDF_SOURCES_TOTAL_LIMIT, "PDF originals exceed 100 MB")
    a4 = {"x": 0, "y": 0, "width": 595, "height": 842}
    for page in pages:
        check(page.get("bookmarked") is None or type(page["bookmarked"]) is bool, "Invalid bookmark")
        check(page.get("paperColor") in (None, "white", "dark"), "Unknown paper color")
        ref = page.get("pdfReference")
        if ref is not None:
            check(page.get("paper") is None and page.get("paperColor") is None, "Page has PDF and paper background")
            source_id = uuid_string(ref["sourceID"])
            check(source_id in lookup, "Unknown PDF source reference")
            check(type(ref["pageIndex"]) is int and 0 <= ref["pageIndex"] < lookup[source_id], "Invalid PDF page reference")
        else:
            check(page.get("paper") in ("blank", "lined", "grid", "legacyTest"), "Unknown paper style")
            if page.get("margins") is not None:
                # Schema 11: paper grows right/down in its own paper (seamless lines).
                margin = page["margins"]
                check(version >= 11 and page["paper"] != "legacyTest", "Writing space beside paper needs schema 11")
                check(margin["left"] == 0 and margin["top"] == 0, "Paper writing space only right/below")
                check(margin["style"] == page["paper"] and margin["color"] == (page.get("paperColor") or "white"),
                      "Paper writing space uses the page's own paper")
            expected = None if page["paper"] == "legacyTest" else {"mediaBox": a4, "cropBox": a4, "rotation": 0}
            if version >= 7 and page["paper"] != "legacyTest":
                check(page.get("geometry") is not None, "Invalid paper geometry")
            else:
                check(page.get("geometry") == expected, "Invalid paper geometry")
        if page.get("margins") is not None:
            margin = page["margins"]
            check(margin["style"] in ("blank", "lined", "grid") and margin["color"] in ("white", "dark"), "Invalid margins")
            check(all(number(margin[k]) and 0 <= margin[k] <= 14_400 for k in ("left", "right", "top", "bottom")), "Invalid margins")
            w, h = _page_size(page)
            check(w + margin["left"] + margin["right"] <= 14_400, "Extended page too large")
            check(h + margin["top"] + margin["bottom"] <= 14_400, "Extended page too large")
    for entry in deleted:
        check(type(entry["originalIndex"]) is int and 0 <= entry["originalIndex"] < 500, "Invalid trash position")
        check(number(entry["deletedAt"]), "Invalid trash date")
        for key in ("nextPageID", "previousPageID"):
            if entry.get(key) is not None:
                check(uuid_string(entry[key]) != uuid_string(entry["page"]["id"]), "Trash entry links to itself")
        if entry.get("reason") == "cleared":
            check(version >= 7, "Cleared-page snapshot needs schema 7")
        check(entry.get("reason") in (None, "marginReduction", "cleared"), "Unknown trash reason")
    return {}
