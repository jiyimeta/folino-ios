#!/usr/bin/env python3
"""Third bisect: isolate why moving the ink is rejected, and try a full synthesis.

Round two established that the payload's timestamp, its UUIDs and its point count can all be changed freely —
each was accepted on device. Only the variant that moved the ink was rejected, and that variant changed two
things at once: the protobuf bbox and the archive's rectangle, while leaving the PDF annotation's own /Rect
alone. A payload whose rectangle disagrees with the annotation's /Rect is the same shape of mismatch that made
round one's pages 2-6 fail, so that is the suspect.

Variants, each written back to the page it came from:

  1  points + protobuf bbox            archive rect and /Rect untouched   -> is the bbox itself the problem?
  2  points + archive rect + /Rect     protobuf bbox untouched            -> is the rect pair the problem?
  3  points + bbox + archive rect + /Rect, all consistent                 -> the shape production would emit
  4  fully synthesized geometry, everything consistent                    -> the actual goal

Prints a `page:archive:x,y,w,h` spec line per variant for applyvariants.swift.

  python3 mkbisect3.py <samples-dir> <outdir>
"""
import glob
import struct
import sys

sys.path.insert(0, __file__.rsplit("/", 1)[0])
import mkbisect  # noqa: E402
import pbcodec  # noqa: E402

PAGE_W, PAGE_H = 595.2756, 841.8898
DX = 80.0  # canvas units


def canvas_size(archive):
    """The archived drawingSize, i.e. the canvas the point coordinates live in."""
    objs = archive["$objects"]
    for o in objs:
        if isinstance(o, dict) and "NS.keys" in o:
            keys = [objs[u.data] for u in o["NS.keys"]]
            if set(keys) == {"Width", "Height"}:
                vals = dict(zip(keys, o["NS.objects"]))
                return objs[vals["Width"].data], objs[vals["Height"].data]
    raise SystemExit("no drawingSize in archive")


def page_rect(archive, cx, cy, cw, ch):
    """Canvas bbox -> page-space rect, using the archive's own canvas size.

    Verified against the single-dot sample: canvas (333, 449, 5, 4) -> stored (249.93, 502.07, 3.75, 3.0).
    """
    canvas_w, canvas_h = canvas_size(archive)
    sx, sy = PAGE_W / canvas_w, PAGE_H / canvas_h
    return (cx * sx, PAGE_H - (cy + ch) * sy, cw * sx, ch * sy)


def bbox_of(payload):
    xs, ys = [], []
    for _, body in pbcodec.strokes_of(payload):
        for r in mkbisect.records(body):
            _, x, y = struct.unpack("<fff", r[0:12])
            xs.append(x)
            ys.append(y)
    return min(xs), min(ys), max(xs) - min(xs), max(ys) - min(ys)


def set_bbox_from_points(payload):
    """Rewrite every stroke's bbox field to match its own points."""
    def stroke(sf):
        def body(b):
            recs = mkbisect.records(b)
            xs = [struct.unpack("<f", r[4:8])[0] for r in recs]
            ys = [struct.unpack("<f", r[8:12])[0] for r in recs]
            bb = pbcodec.serialize([
                (1, 5, struct.pack("<f", min(xs))),
                (2, 5, struct.pack("<f", min(ys))),
                (3, 5, struct.pack("<f", max(xs) - min(xs))),
                (4, 5, struct.pack("<f", max(ys) - min(ys))),
            ])
            return [(f, wt, bb if f == 6 else v) for f, wt, v in b]
        return mkbisect.map_body(sf, body)
    return mkbisect.map_strokes(payload, stroke)


def synthesize(payload):
    """Replace the geometry with a zigzag of our own; keep undecoded scaffolding as constants."""
    def stroke(sf):
        def body(b):
            template = mkbisect.records(b)[0]
            recs = []
            for i in range(48):
                t = i * 0.008
                x = 260.0 + i * 6.0
                y = 560.0 + (40.0 if i % 2 else -40.0)
                recs.append(struct.pack("<fff", t, x, y) + template[12:])
            joined = b"".join(recs)
            return [(f, wt, len(recs) if f == 4 else (joined if f == 5 else v)) for f, wt, v in b]
        return mkbisect.map_body(sf, body)
    return set_bbox_from_points(mkbisect.map_strokes(payload, stroke))


def main():
    samples, outdir = sys.argv[1], sys.argv[2]
    specs = []

    def emit(page, name, payload, archive, index, set_rects):
        out = f"{outdir}/v3-p{page}-{name}.archive"
        cx, cy, cw, ch = bbox_of(payload)
        rect = page_rect(archive, cx, cy, cw, ch)
        if set_rects:
            objs = archive["$objects"]
            for o in objs:
                if isinstance(o, dict) and "NS.keys" in o:
                    keys = [objs[u.data] for u in o["NS.keys"]]
                    if "X" in keys and "Y" in keys:
                        vals = dict(zip(keys, o["NS.objects"]))
                        objs[vals["X"].data], objs[vals["Y"].data] = rect[0], rect[1]
                        objs[vals["Width"].data], objs[vals["Height"].data] = rect[2], rect[3]
                        break
        mkbisect.save(archive, index, payload, out)
        spec = f"{page}:{out}" + (f":{rect[0]:.2f},{rect[1]:.2f},{rect[2]:.2f},{rect[3]:.2f}" if set_rects else "")
        specs.append(spec)
        print(f"page {page} {name:26s} bbox=({cx:.0f},{cy:.0f},{cw:.0f},{ch:.0f}) "
              f"rect={'set' if set_rects else 'untouched'}")

    def src(page):
        return glob.glob(f"{samples}/ppk-p{page}-*.bin")[0]

    # 1 — points + protobuf bbox, rects untouched
    a, i, raw = mkbisect.load(src(1))
    emit(1, "points+bbox", set_bbox_from_points(mkbisect.v_points_only(raw, DX)), a, i, False)

    # 2 — points + both rects, protobuf bbox untouched
    a, i, raw = mkbisect.load(src(2))
    emit(2, "points+rects", mkbisect.v_points_only(raw, DX), a, i, True)

    # 3 — everything consistent
    a, i, raw = mkbisect.load(src(3))
    emit(3, "points+bbox+rects", set_bbox_from_points(mkbisect.v_points_only(raw, DX)), a, i, True)

    # 4 — fully synthesized
    a, i, raw = mkbisect.load(src(4))
    emit(4, "synthesized", synthesize(raw), a, i, True)

    print("\nspecs:")
    print(" ".join(specs))


if __name__ == "__main__":
    main()
