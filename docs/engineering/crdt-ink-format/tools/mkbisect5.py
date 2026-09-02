#!/usr/bin/env python3
"""Fifth round: move and synthesize ink with the rectangle rule finally derived correctly.

Rounds 1-4 established, on device:

  * the payload's points, its stored bbox, its timestamp, its UUIDs and its point count can all be changed
  * changing the archive's `rectangle` alone is rejected, and changing the annotation's /Rect alone is rejected
  * changing both together was also rejected -- but with a rect computed from the POINTS

The last of those was the harness's fault. Recomputing the bounding box from the point coordinates loses the
padding Apple stores (roughly half the stroke width, so it grows with pen thickness), which put the rect 0.7 to
5 points out. Measured across all eight samples, the archive rectangle is exactly the payload's *stored* bbox
field mapped into page space:

    sx, sy = pageW / drawingSize.Width, pageH / drawingSize.Height
    X = bbox.x * sx
    Y = pageH - (bbox.y + bbox.h) * sy
    W = bbox.w * sx
    H = bbox.h * sy

which agrees with the stored rectangle to within 0.12pt on every sample. So the rule under test is: the stored
bbox, the archive rectangle and the annotation's /Rect must all describe the same box.

  1  ink moved, all three kept consistent
  2  ink synthesized inside the original bbox, all three consistent  (renders without needing a new /AP)
  3  ink synthesized freely, all three consistent

  python3 mkbisect5.py <samples-dir> <outdir>
"""
import glob
import struct
import sys

sys.path.insert(0, __file__.rsplit("/", 1)[0])
import mkbisect  # noqa: E402
import pbcodec  # noqa: E402

# The PAGE's actual MediaBox, not A4's nominal size. Using 595.2756 x 841.8898 against a page that is
# really 595 x 842 puts the rect about 0.1pt out, and that is enough for Apple's markup to reject the
# annotation outright -- the match has to be exact.
PAGE_W, PAGE_H = 595.0, 842.0
PAD = 1.4  # canvas units of padding around the raw points, in the ballpark Apple leaves for a thin pen


def canvas_size(archive):
    objs = archive["$objects"]
    for o in objs:
        if isinstance(o, dict) and "NS.keys" in o:
            keys = [objs[u.data] for u in o["NS.keys"]]
            if set(keys) == {"Width", "Height"}:
                v = dict(zip(keys, o["NS.objects"]))
                return objs[v["Width"].data], objs[v["Height"].data]
    raise SystemExit("no drawingSize")


def stored_bbox(payload):
    """Union of every stroke's stored bbox field, in canvas units."""
    boxes = []
    for _, body in pbcodec.strokes_of(payload):
        for v in pbcodec.get(body, 6):
            boxes.append([struct.unpack("<f", x)[0] for _, _, x in pbcodec.parse(v)])
    x0 = min(b[0] for b in boxes)
    y0 = min(b[1] for b in boxes)
    x1 = max(b[0] + b[2] for b in boxes)
    y1 = max(b[1] + b[3] for b in boxes)
    return x0, y0, x1 - x0, y1 - y0


def to_page(archive, box):
    """Canvas bbox -> the archive's `rectangle`, in page space. Exact on all eight samples."""
    cw, ch = canvas_size(archive)
    sx, sy = PAGE_W / cw, PAGE_H / ch
    x, y, w, h = box
    return (x * sx, PAGE_H - (y + h) * sy, w * sx, h * sy)


def annotation_rect(archive_rect):
    """The PDF annotation's /Rect is the archive rectangle grown by exactly 1pt on every side.

    Measured at -1.0 / -1.0 / +2.0 / +2.0 on all eight samples, to four decimals. Setting /Rect equal to the
    archive rectangle instead -- which is what it looks like it should be -- puts it 1pt out on each edge and
    the annotation is rejected.
    """
    x, y, w, h = archive_rect
    return (x - 1.0, y - 1.0, w + 2.0, h + 2.0)


def set_archive_rect(archive, rect):
    objs = archive["$objects"]
    for o in objs:
        if isinstance(o, dict) and "NS.keys" in o:
            keys = [objs[u.data] for u in o["NS.keys"]]
            if "X" in keys and "Y" in keys:
                v = dict(zip(keys, o["NS.objects"]))
                objs[v["X"].data], objs[v["Y"].data] = rect[0], rect[1]
                objs[v["Width"].data], objs[v["Height"].data] = rect[2], rect[3]
                return


def shift_bbox(payload, dx):
    def stroke(sf):
        def body(b):
            out = []
            for f, wt, v in b:
                if f == 6:
                    parts = pbcodec.parse(v)
                    parts = [(bf, bwt, struct.pack("<f", struct.unpack("<f", bv)[0] + dx) if bf == 1 else bv)
                             for bf, bwt, bv in parts]
                    out.append((f, wt, pbcodec.serialize(parts)))
                else:
                    out.append((f, wt, v))
            return out
        return mkbisect.map_body(sf, body)
    return mkbisect.map_strokes(payload, stroke)


def synth(payload, box):
    """Replace the geometry with a zigzag inside `box` (canvas units), and set each stroke's bbox to match."""
    bx, by, bw, bh = box

    def stroke(sf):
        def body(b):
            template = mkbisect.records(b)[0]
            n = 40
            recs = []
            for i in range(n):
                t = i * 0.008
                x = bx + PAD + (bw - 2 * PAD) * i / (n - 1)
                y = by + PAD + (0 if i % 2 else (bh - 2 * PAD))
                recs.append(struct.pack("<fff", t, x, y) + template[12:])
            bb = pbcodec.serialize([
                (1, 5, struct.pack("<f", bx)),
                (2, 5, struct.pack("<f", by)),
                (3, 5, struct.pack("<f", bw)),
                (4, 5, struct.pack("<f", bh)),
            ])
            joined = b"".join(recs)
            return [(f, wt, len(recs) if f == 4 else (joined if f == 5 else (bb if f == 6 else v)))
                    for f, wt, v in b]
        return mkbisect.map_body(sf, body)
    return mkbisect.map_strokes(payload, stroke)


def main():
    samples, outdir = sys.argv[1], sys.argv[2]
    specs = []

    def src(page):
        return glob.glob(f"{samples}/ppk-p{page}-*.bin")[0]

    def emit(page, name, archive, index, payload):
        rect = to_page(archive, stored_bbox(payload))
        set_archive_rect(archive, rect)
        out = f"{outdir}/v5-p{page}-{name}.archive"
        mkbisect.save(archive, index, payload, out)
        # Full precision: the annotation is rejected outright if /Rect and the archive rectangle differ by as
        # little as 0.1pt, so this must not be rounded on the way through the spec string.
        ar = annotation_rect(rect)
        specs.append(f"{page}:{out}:{ar[0]:.6f},{ar[1]:.6f},{ar[2]:.6f},{ar[3]:.6f}")
        n = sum(len(mkbisect.records(b)) for _, b in pbcodec.strokes_of(payload))
        print(f"page {page}  {name:22s} points={n:3d}  rect=({rect[0]:.1f},{rect[1]:.1f},{rect[2]:.1f},{rect[3]:.1f})")

    # 1 — move the ink, keeping bbox, archive rect and /Rect consistent
    a, i, raw = mkbisect.load(src(1))
    dx = 60.0
    emit(1, "moved", a, i, shift_bbox(mkbisect.v_points_only(raw, dx), dx))

    # 2 — synthesize inside the original box, so the existing /AP still covers the ink
    a, i, raw = mkbisect.load(src(2))
    emit(2, "synth-in-place", a, i, synth(raw, stored_bbox(raw)))

    # 3 — synthesize somewhere else entirely
    a, i, raw = mkbisect.load(src(3))
    emit(3, "synth-moved", a, i, synth(raw, (260.0, 500.0, 280.0, 90.0)))

    print("\nspecs:")
    print(" ".join(f'"{s}"' for s in specs))


if __name__ == "__main__":
    main()
