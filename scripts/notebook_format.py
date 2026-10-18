"""Shared read-only schema audit; never prints private note contents."""
import base64
import math
from uuid import UUID


def geometry(value):
    boxes = []
    for key in ("mediaBox", "cropBox"):
        box = value[key]
        assert all(type(box[k]) in (int, float) and math.isfinite(box[k]) for k in ("x", "y", "width", "height"))
        assert box["width"] > 0 and box["height"] > 0
        boxes.append(box)
    a, b = boxes
    w = min(a["x"] + a["width"], b["x"] + b["width"]) - max(a["x"], b["x"])
    h = min(a["y"] + a["height"], b["y"] + b["height"]) - max(a["y"], b["y"])
    assert 1 <= w <= 14_400 and 1 <= h <= 14_400 and value["rotation"] in (0, 90, 180, 270)


def text_style(style):
    assert style["font"] in ("system", "serif", "monospaced")
    assert style["color"] in ("black", "white", "blue", "red")
    assert type(style["fontSize"]) in (int, float) and math.isfinite(style["fontSize"]) and 8 <= style["fontSize"] <= 96
    assert all(type(style[k]) is bool for k in ("bold", "italic", "underline"))
    assert style.get("highlighted") is None or type(style["highlighted"]) is bool
    assert style.get("alignment") in (None, "left", "center", "right", "justified")
    indent = style.get("indent")
    assert indent is None or (type(indent) in (int, float) and math.isfinite(indent) and 0 <= indent <= 240)
    assert style.get("fontName") is None or (isinstance(style["fontName"], str) and 0 < len(style["fontName"].encode("utf-8")) <= 200)
    assert style.get("strikethrough") is None or type(style["strikethrough"]) is bool
    assert style.get("baseline") is None or (type(style["baseline"]) is int and -1 <= style["baseline"] <= 1)
    if style.get("ink") is not None:
        assert all(type(style["ink"][k]) in (int, float) and math.isfinite(style["ink"][k]) and 0 <= style["ink"][k] <= 1 for k in ("red", "green", "blue", "alpha"))
    link = style.get("link")
    if link is not None:
        from urllib.parse import urlsplit
        assert len(link.encode("utf-8")) <= 2048 and urlsplit(link).scheme.lower() in ("http", "https", "mailto")


def appearance(value):
    if value is None:
        return
    assert type(value["coverEnabled"]) is bool and type(value["landscape"]) is bool
    assert value["cover"] in ("blue", "purple", "green", "yellow", "coral", "gray")
    assert value["format"] in ("a4", "a5", "a3", "letter")
    assert value["paper"] in ("blank", "lined", "grid")
    assert value["color"] in ("white", "dark")


def validate_notebook(document):
    version = document["schemaVersion"]
    assert version in (1, 2, 3, 4, 5, 6, 7, 8), "Unsupported notebook schema"
    UUID(document["id"])
    if document.get("appearance") is not None:
        assert version >= 7
        appearance(document["appearance"])
    active = document["pages"]
    deleted = document.get("deletedPages") or []
    assert 1 <= len(active) <= 500 and len(deleted) <= 500
    pages = active + [entry["page"] for entry in deleted]
    assert len({p["id"] for p in pages}) == len(pages), "Duplicate page identities"
    text_ids = set()
    image_ids = set()
    shape_ids = set()
    image_bytes = 0
    for page in pages:
        UUID(page["id"])
        base64.b64decode(page["drawing"], validate=True)
        if page.get("textBoxes") is not None:
            assert version >= 4 and page["text"] == "" and len(page["textBoxes"]) <= 200
            flow_ids = set()
            for box in page["textBoxes"]:
                flow = box.get("flowID")
                region = box.get("flowRegion")
                assert (flow is None) == (region is None)
                if flow is not None:
                    assert version >= 8 and region in ("page", "left", "right", "top", "bottom")
                    UUID(flow)
                    assert flow not in flow_ids
                    flow_ids.add(flow)
                UUID(box["id"])
                assert box["id"] not in text_ids, "Duplicate text object identities"
                text_ids.add(box["id"])
                assert all(type(box[k]) in (int, float) and math.isfinite(box[k]) for k in ("x", "y", "width", "height"))
                assert abs(box["x"]) <= 14_400 and abs(box["y"]) <= 14_400
                assert 1 <= box["width"] <= 14_400 and 1 <= box["height"] <= 14_400
                assert len(box["text"].encode("utf-8")) <= 1_000_000
                for style in [box["style"]] + [r["style"] for r in box.get("runs") or []]:
                    if any(style.get(k) is not None for k in ("fontName", "ink", "strikethrough", "baseline")):
                        assert version >= 8
                text_style(box["style"])
                if any(box["style"].get(k) is not None for k in ("highlighted", "alignment", "indent", "link")):
                    assert version >= 7
                if box.get("runs") is not None:
                    assert version >= 7 and len(box["runs"]) <= 50_000
                    units = box["text"].encode("utf-16-le")
                    count = len(units) // 2
                    end = 0
                    for run in box["runs"]:
                        a, n = run["location"], run["length"]
                        assert type(a) is int and type(n) is int and end <= a <= count and 0 < n <= count-a
                        for boundary in (a, a+n):
                            assert boundary in (0, count) or not 0xDC00 <= int.from_bytes(units[boundary*2:boundary*2+2], "little") <= 0xDFFF
                        end = a+n
                        text_style(run["style"])
        if page.get("geometry") is not None:
            assert version >= 2
            geometry(page["geometry"])
        if page.get("shapes") is not None:
            assert version >= 6 and len(page["shapes"]) <= 500
            for shape in page["shapes"]:
                UUID(shape["id"])
                assert shape["id"] not in shape_ids
                shape_ids.add(shape["id"])
                assert shape["kind"] in ("line", "arrow", "rectangle", "ellipse")
                assert shape["pattern"] in ("solid", "dashed", "dotted")
                points = [shape[p][k] for p in ("start", "end") for k in ("x", "y")]
                assert all(type(v) in (int, float) and math.isfinite(v) and abs(v) <= 14_400 for v in points)
                width = shape["lineWidth"]
                assert type(width) in (int, float) and math.isfinite(width) and 0.5 <= width <= 40
                a, b = shape["start"], shape["end"]
                assert math.hypot(a["x"]-b["x"], a["y"]-b["y"]) >= 1
                if shape["kind"] in ("rectangle", "ellipse"):
                    assert abs(a["x"]-b["x"]) >= 1 and abs(a["y"]-b["y"]) >= 1
                for color in (shape["color"], shape.get("fill")):
                    if color is not None:
                        assert all(type(color[k]) in (int, float) and math.isfinite(color[k]) and 0 <= color[k] <= 1 for k in ("red", "green", "blue", "alpha"))
                w, h = 595, 842
                if page.get("geometry"):
                    g = page["geometry"]; a0, b0 = g["mediaBox"], g["cropBox"]
                    w = min(a0["x"]+a0["width"], b0["x"]+b0["width"]) - max(a0["x"], b0["x"])
                    h = min(a0["y"]+a0["height"], b0["y"]+b0["height"]) - max(a0["y"], b0["y"])
                    if g["rotation"] in (90, 270): w, h = h, w
                m = page.get("margins") or {}
                pad = max(10, width*3) if shape["kind"] == "arrow" else width/2
                assert min(a["x"], b["x"])-pad >= -m.get("left", 0)-0.02
                assert min(a["y"], b["y"])-pad >= -m.get("top", 0)-0.02
                assert max(a["x"], b["x"])+pad <= w+m.get("right", 0)+0.02
                assert max(a["y"], b["y"])+pad <= h+m.get("bottom", 0)+0.02
        if page.get("images") is not None:
            assert version >= 5 and len(page["images"]) <= 50
            for image in page["images"]:
                UUID(image["id"])
                assert image["id"] not in image_ids, "Duplicate image identities"
                image_ids.add(image["id"])
                original = base64.b64decode(image["data"], validate=True)
                assert 1 <= len(original) <= 20_000_000
                image_bytes += len(original)
                assert all(type(image[k]) is int and 1 <= image[k] <= 100_000 for k in ("pixelWidth", "pixelHeight"))
                assert image["pixelWidth"] * image["pixelHeight"] <= 200_000_000
                assert all(type(image[k]) in (int, float) and math.isfinite(image[k]) for k in ("x", "y", "width", "height", "rotation"))
                assert abs(image["x"]) <= 14_400 and abs(image["y"]) <= 14_400
                assert 1 <= image["width"] <= 14_400 and 1 <= image["height"] <= 14_400
                assert -180 <= image["rotation"] <= 180 and type(image["locked"]) is bool
                crop = image["crop"]
                assert all(type(crop[k]) in (int, float) and math.isfinite(crop[k]) for k in ("x", "y", "width", "height"))
                assert crop["x"] >= 0 and crop["y"] >= 0 and crop["width"] >= 0.0199999 and crop["height"] >= 0.0199999
                assert crop["x"] + crop["width"] <= 1.0000001 and crop["y"] + crop["height"] <= 1.0000001
                w, h = 595, 842
                if page.get("geometry"):
                    a, b = page["geometry"]["mediaBox"], page["geometry"]["cropBox"]
                    w = min(a["x"] + a["width"], b["x"] + b["width"]) - max(a["x"], b["x"])
                    h = min(a["y"] + a["height"], b["y"] + b["height"]) - max(a["y"], b["y"])
                    if page["geometry"]["rotation"] in (90, 270):
                        w, h = h, w
                margin = page.get("margins") or {}
                radians = math.radians(image["rotation"])
                rw = abs(math.cos(radians)) * image["width"] + abs(math.sin(radians)) * image["height"]
                rh = abs(math.sin(radians)) * image["width"] + abs(math.cos(radians)) * image["height"]
                x, y = image["x"] + (image["width"] - rw) / 2, image["y"] + (image["height"] - rh) / 2
                assert x >= -margin.get("left", 0) - 0.01 and y >= -margin.get("top", 0) - 0.01
                assert x + rw <= w + margin.get("right", 0) + 0.01 and y + rh <= h + margin.get("bottom", 0) + 0.01
    assert image_bytes <= 40_000_000 and image_ids.isdisjoint(text_ids)
    assert shape_ids.isdisjoint(text_ids | image_ids)
    if document.get("pdfSources") is None:
        assert document.get("deletedPages") is None
        assert all(all(p.get(key) is None for key in ("pdfReference", "paper", "paperColor", "bookmarked", "margins")) for p in pages)
        if document.get("pdf") is not None:
            base64.b64decode(document["pdf"], validate=True)
        return
    assert version >= 3 and document.get("pdf") is None
    sources = document["pdfSources"]
    assert len(sources) <= 500 and len({s["id"] for s in sources}) == len(sources)
    lookup = {}
    total = 0
    for source in sources:
        UUID(source["id"])
        data = base64.b64decode(source["data"], validate=True)
        assert 1 <= len(data) <= 20_000_000 and 1 <= source["pageCount"] <= 500
        total += len(data)
        lookup[source["id"]] = source["pageCount"]
    assert total <= 100_000_000
    a4 = {"x": 0, "y": 0, "width": 595, "height": 842}
    for page in pages:
        assert page.get("bookmarked") is None or type(page["bookmarked"]) is bool
        assert page.get("paperColor") in (None, "white", "dark")
        ref = page.get("pdfReference")
        if ref is not None:
            assert page.get("paper") is None and page.get("paperColor") is None and ref["sourceID"] in lookup
            assert type(ref["pageIndex"]) is int and 0 <= ref["pageIndex"] < lookup[ref["sourceID"]]
        else:
            assert page.get("margins") is None
            assert page.get("paper") in ("blank", "lined", "grid", "legacyTest")
            expected = None if page["paper"] == "legacyTest" else {"mediaBox": a4, "cropBox": a4, "rotation": 0}
            if version >= 7 and page["paper"] != "legacyTest":
                assert page.get("geometry") is not None
            else:
                assert page.get("geometry") == expected, "Invalid paper geometry"
        if page.get("margins") is not None:
            margin = page["margins"]
            assert margin["style"] in ("blank", "lined", "grid") and margin["color"] in ("white", "dark")
            assert all(type(margin[k]) in (int, float) and math.isfinite(margin[k]) and 0 <= margin[k] <= 14_400
                       for k in ("left", "right", "top", "bottom"))
            w, h = 595, 842
            if page.get("geometry") is not None:
                g = page["geometry"]
                a, b = g["mediaBox"], g["cropBox"]
                w = min(a["x"] + a["width"], b["x"] + b["width"]) - max(a["x"], b["x"])
                h = min(a["y"] + a["height"], b["y"] + b["height"]) - max(a["y"], b["y"])
                if g["rotation"] in (90, 270):
                    w, h = h, w
            assert w + margin["left"] + margin["right"] <= 14_400
            assert h + margin["top"] + margin["bottom"] <= 14_400
    for entry in deleted:
        assert 0 <= entry["originalIndex"] < 500 and math.isfinite(entry["deletedAt"])
        assert entry.get("nextPageID") != entry["page"]["id"] and entry.get("previousPageID") != entry["page"]["id"]
        if entry.get("reason") == "cleared":
            assert version >= 7
        assert entry.get("reason") in (None, "marginReduction", "cleared")
