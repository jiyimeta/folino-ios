#!/usr/bin/env python3
"""Map a payload's points into page space, so they can be compared with the annotation's own /InkList.

An exported mark is described twice: by the vector `/AP` and `/InkList` that every PDF reader draws, and by the
payload that Apple's markup re-renders from. They are built from different code paths, so they can disagree --
and when they do, the mark sits in one place in Preview and another in Files, which is exactly the symptom
this exists to diagnose.

Prints, per stroke: the stored bbox, the archive rectangle, the canvas size, and the first and last few points
converted to page space with the same formula the encoder uses.

  python3 comparegeometry.py <archive.bin> [pageWidth pageHeight]
"""
import struct
import sys

sys.path.insert(0, __file__.rsplit("/", 1)[0])
import mkbisect  # noqa: E402
import mkbisect5  # noqa: E402
import pbcodec  # noqa: E402

PAGE_W, PAGE_H = 595.2756, 841.8898  # overridden by argv; printed so a mismatch is visible


def archive_rect(archive):
    objs = archive["$objects"]
    for o in objs:
        if isinstance(o, dict) and "NS.keys" in o:
            keys = [objs[u.data] for u in o["NS.keys"]]
            if "X" in keys and "Y" in keys:
                v = dict(zip(keys, o["NS.objects"]))
                return tuple(objs[v[k].data] for k in ("X", "Y", "Width", "Height"))
    return None


def main():
    path = sys.argv[1]
    page_w, page_h = (float(sys.argv[2]), float(sys.argv[3])) if len(sys.argv) > 3 else (PAGE_W, PAGE_H)

    archive, _, raw = mkbisect.load(path)
    canvas_w, canvas_h = mkbisect5.canvas_size(archive)
    sx, sy = page_w / canvas_w, page_h / canvas_h

    print(f"{path.rsplit('/', 1)[-1]}")
    print(f"  page {page_w} x {page_h}   canvas {canvas_w:.4f} x {canvas_h:.4f}   sx={sx:.6f} sy={sy:.6f}")
    rect = archive_rect(archive)
    if rect:
        print(f"  archive rectangle  X={rect[0]:.4f} Y={rect[1]:.4f} W={rect[2]:.4f} H={rect[3]:.4f}")

    for drawing in pbcodec.get(pbcodec.parse(raw), 2):
        for stroke in pbcodec.get(pbcodec.parse(drawing), 3):
            fields = pbcodec.parse(stroke)
            for ink in pbcodec.get(fields, 4):
                tool = [v for f, _, v in pbcodec.parse(ink) if f == 2]
                if tool:
                    print(f"  tool: {tool[0].decode(errors='replace')}")
                rgba = pbcodec.get(pbcodec.parse(ink), 1)
                if rgba:
                    vals = [struct.unpack("<f", v)[0] for _, _, v in pbcodec.parse(rgba[0])]
                    print(f"  rgba: {['%.4f' % v for v in vals]}")

            for body in pbcodec.get(fields, 5):
                points = pbcodec.parse(body)
                bbox = pbcodec.get(points, 6)
                if bbox:
                    b = [struct.unpack("<f", v)[0] for _, _, v in pbcodec.parse(bbox[0])]
                    print(f"  stored bbox (canvas)  x={b[0]:.4f} y={b[1]:.4f} w={b[2]:.4f} h={b[3]:.4f}")
                    print(f"  -> page space         X={b[0] * sx:.4f} Y={page_h - (b[1] + b[3]) * sy:.4f}"
                          f" W={b[2] * sx:.4f} H={b[3] * sy:.4f}")

                blob = pbcodec.get(points, 5)
                if not blob:
                    continue
                records = [blob[0][i:i + 24] for i in range(0, len(blob[0]), 24)]
                widths = {struct.unpack("<H", r[12:14])[0] for r in records}
                print(f"  {len(records)} points, width values {sorted(widths)}")
                for label, chosen in (("first", records[:3]), ("last", records[-2:])):
                    for r in chosen:
                        t, x, y = struct.unpack("<fff", r[0:12])
                        w = struct.unpack("<H", r[12:14])[0]
                        print(f"    {label:5s} canvas ({x:9.4f}, {y:9.4f}) w={w:5d}"
                              f"   -> page ({x * sx:9.4f}, {page_h - y * sy:9.4f})  pen width {w / 10 * sx:.3f}pt")


if __name__ == "__main__":
    main()
