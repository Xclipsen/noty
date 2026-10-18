"""Generate a small deterministic PDF fixture without additional dependencies."""
from pathlib import Path

pages = [
    ((0, 0, 595, 842), (40, 60, 555, 802), 0),
    ((0, 0, 842, 595), (60, 40, 782, 555), 90),
    ((-50, -50, 550, 750), (0, 80, 500, 700), 180),
    ((0, 0, 400, 300), (20, 30, 350, 270), 270),
]
objects = []


def add(value):
    objects.append(value.encode("ascii") if isinstance(value, str) else value)
    return len(objects)


add("<< /Type /Catalog /Pages 2 0 R >>")
add("<< /Type /Pages /Kids [4 0 R 6 0 R 8 0 R 10 0 R] /Count 4 >>")
add("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
for index, (media, crop, rotation) in enumerate(pages, 1):
    x0, y0 = max(media[0], crop[0]), max(media[1], crop[1])
    x1, y1 = min(media[2], crop[2]), min(media[3], crop[3])
    stream = ["q 1 1 1 rg", f"{x0} {y0} {x1-x0} {y1-y0} re f"]
    for x, y, color, label in [
        (x0+12, y0+12, "1 0 0", "A"),
        (x1-30, y0+12, "0 0.7 0", "B"),
        (x0+12, y1-30, "0 0 1", "C"),
        (x1-30, y1-30, "1 0.5 0", "D"),
    ]:
        stream += [f"{color} rg {x} {y} 18 18 re f", "0 0 0 rg",
                   f"BT /F1 12 Tf {x} {y-12} Td ({label}) Tj ET"]
    stream += ["0 0 0 RG 1 w", f"{x0+40} {y0+40} m {x1-40} {y1-40} l S",
               f"BT /F1 18 Tf {x0+55} {(y0+y1)/2} Td (SOURCE-{index} ROTATE-{rotation}) Tj ET", "Q"]
    data = "\n".join(stream).encode("ascii")
    page_id = len(objects) + 1
    add(f"<< /Type /Page /Parent 2 0 R /Resources << /Font << /F1 3 0 R >> >> "
        f"/MediaBox [{' '.join(map(str, media))}] /CropBox [{' '.join(map(str, crop))}] "
        f"/Rotate {rotation} /Contents {page_id+1} 0 R >>")
    add(f"<< /Length {len(data)} >>\nstream\n".encode() + data + b"\nendstream")

output = bytearray(b"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n")
offsets = [0]
for index, value in enumerate(objects, 1):
    offsets.append(len(output))
    output.extend(f"{index} 0 obj\n".encode() + value + b"\nendobj\n")
start = len(output)
output.extend(f"xref\n0 {len(offsets)}\n0000000000 65535 f \n".encode())
for offset in offsets[1:]:
    output.extend(f"{offset:010d} 00000 n \n".encode())
output.extend(f"trailer\n<< /Size {len(offsets)} /Root 1 0 R >>\nstartxref\n{start}\n%%EOF\n".encode())
path = Path(__file__).resolve().parents[1] / "fixtures" / "Seitenformate.pdf"
path.parent.mkdir(exist_ok=True)
path.write_bytes(output)
print(path)
