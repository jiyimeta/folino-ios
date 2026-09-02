#!/usr/bin/env python3
"""Sixth round: is it the rectangle's value, or the act of writing it?

Round five kept the stored bbox, the archive rectangle and the annotation /Rect consistent to within 0.1pt and
was still rejected — including a variant whose rectangle was numerically the same as the original to two
decimal places. So the rejection is probably not about the value.

What every rejected variant has in common is that something rewrote a rectangle. The accepted ones never did.
PDFKit's `annotation.bounds` setter visibly rewrites the appearance stream (its length changes), and rewriting
the archive's rectangle means re-serializing the plist floats. Either could be what AnnotationKit objects to.

  1  synthesized geometry inside the ORIGINAL box; the stored bbox is written back byte-for-byte; neither
     rectangle is touched anywhere       -> can we synthesize at all, with nothing else disturbed?
  2  payload round-tripped unchanged, and /Rect set to its OWN current value
                                          -> does calling the setter break it even with an identical value?
  3  payload round-tripped unchanged, and the archive rectangle rewritten with its OWN current values
                                          -> does rewriting those floats break it, with identical values?

  python3 mkbisect6.py <samples-dir> <outdir>
"""
import glob
import struct
import sys

sys.path.insert(0, __file__.rsplit("/", 1)[0])
import mkbisect  # noqa: E402
import mkbisect5  # noqa: E402
import pbcodec  # noqa: E402


def original_bbox_bytes(payload):
    """The first stroke's bbox field, verbatim, so it can be written back unchanged."""
    for _, body in pbcodec.strokes_of(payload):
        vals = pbcodec.get(body, 6)
        if vals:
            return vals[0]
    raise SystemExit("no bbox field")


def synth_inside(payload):
    """New geometry that stays inside each stroke's existing bbox, with that bbox written back untouched."""
    def stroke(sf):
        def body(b):
            template = mkbisect.records(b)[0]
            bb = pbcodec.get(b, 6)[0]
            bx, by, bw, bh = [struct.unpack("<f", v)[0] for _, _, v in pbcodec.parse(bb)]
            pad = min(bw, bh) * 0.15
            n = 40
            recs = []
            for i in range(n):
                t = i * 0.008
                x = bx + pad + (bw - 2 * pad) * i / (n - 1)
                y = by + pad + (0 if i % 2 else max(bh - 2 * pad, 0.0))
                recs.append(struct.pack("<fff", t, x, y) + template[12:])
            joined = b"".join(recs)
            # field 6 is passed straight through: the box must not move.
            return [(f, wt, len(recs) if f == 4 else (joined if f == 5 else v)) for f, wt, v in b]
        return mkbisect.map_body(sf, body)
    return mkbisect.map_strokes(payload, stroke)


def main():
    samples, outdir = sys.argv[1], sys.argv[2]
    specs = []

    def src(page):
        return glob.glob(f"{samples}/ppk-p{page}-*.bin")[0]

    # 1 — synthesize inside the original box, touch no rectangle at all
    a, i, raw = mkbisect.load(src(1))
    payload = synth_inside(raw)
    out = f"{outdir}/v6-p1-synth-box-untouched.archive"
    mkbisect.save(a, i, payload, out)
    specs.append(f"1:{out}")
    n = sum(len(mkbisect.records(b)) for _, b in pbcodec.strokes_of(payload))
    same_box = original_bbox_bytes(payload) == original_bbox_bytes(raw)
    print(f"page 1  synth inside box     points -> {n}, bbox byte-identical: {same_box}, no rect written")

    # 2 — round trip only, but call the /Rect setter with the annotation's own current values
    a, i, raw = mkbisect.load(src(2))
    rect = mkbisect5.to_page(a, mkbisect5.stored_bbox(raw))
    out = f"{outdir}/v6-p2-setter-same-value.archive"
    mkbisect.save(a, i, pbcodec.serialize(pbcodec.parse(raw)), out)
    specs.append(f"2:{out}:{rect[0]:.2f},{rect[1]:.2f},{rect[2]:.2f},{rect[3]:.2f}")
    print(f"page 2  /Rect setter, same value ({rect[0]:.2f},{rect[1]:.2f},{rect[2]:.2f},{rect[3]:.2f})")

    # 3 — round trip only, but rewrite the archive rectangle with its own current values
    a, i, raw = mkbisect.load(src(3))
    objs = a["$objects"]
    current = None
    for o in objs:
        if isinstance(o, dict) and "NS.keys" in o:
            keys = [objs[u.data] for u in o["NS.keys"]]
            if "X" in keys and "Y" in keys:
                v = dict(zip(keys, o["NS.objects"]))
                current = (objs[v["X"].data], objs[v["Y"].data], objs[v["Width"].data], objs[v["Height"].data])
                break
    mkbisect5.set_archive_rect(a, current)
    out = f"{outdir}/v6-p3-archive-rect-same-value.archive"
    mkbisect.save(a, i, pbcodec.serialize(pbcodec.parse(raw)), out)
    specs.append(f"3:{out}")
    print(f"page 3  archive rect rewritten with identical values {tuple(round(c, 2) for c in current)}")

    print("\nspecs:")
    print(" ".join(f'"{s}"' for s in specs))


if __name__ == "__main__":
    main()
