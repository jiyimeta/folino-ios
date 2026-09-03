#!/usr/bin/env python3
"""Fourth bisect: separate the archive rectangle from the PDF /Rect, and test synthesis on its own.

Round three: changing the points and the protobuf bbox was accepted, but every variant that moved the ink's
*rectangle* was rejected — and each of those changed the archive's `rectangle` AND the annotation's /Rect
together, so the two are still confounded. A third possibility is that neither value matters and the harness is
at fault: setting `PDFAnnotation.bounds` on an annotation Apple created may itself damage it, which production
code would never do because it creates its own annotations.

  1  archive rectangle only    /Rect untouched, points untouched
  2  /Rect only                archive rectangle untouched, points untouched
  3  fully synthesized payload, both rectangles left exactly as they were

Variant 3 is the one that matters most. If the payload can be replaced wholesale while the rectangles stay put,
then folino can generate the drawing, and placing it correctly is a separate problem it controls anyway — it
creates its annotations rather than editing Apple's.

  python3 mkbisect4.py <samples-dir> <outdir>
"""
import glob
import struct
import sys

sys.path.insert(0, __file__.rsplit("/", 1)[0])
import mkbisect  # noqa: E402
import mkbisect3  # noqa: E402
import pbcodec  # noqa: E402

SHIFT = 40.0  # page points


def archive_rect(archive):
    objs = archive["$objects"]
    for o in objs:
        if isinstance(o, dict) and "NS.keys" in o:
            keys = [objs[u.data] for u in o["NS.keys"]]
            if "X" in keys and "Y" in keys:
                vals = dict(zip(keys, o["NS.objects"]))
                return {k: (vals[k].data, objs[vals[k].data]) for k in ("X", "Y", "Width", "Height")}
    raise SystemExit("no rectangle in archive")


def main():
    samples, outdir = sys.argv[1], sys.argv[2]

    def src(page):
        return glob.glob(f"{samples}/ppk-p{page}-*.bin")[0]

    specs = []

    # 1 — archive rectangle only
    a, i, raw = mkbisect.load(src(1))
    r = archive_rect(a)
    a["$objects"][r["X"][0]] = r["X"][1] + SHIFT
    out = f"{outdir}/v4-p1-archive-rect-only.archive"
    mkbisect.save(a, i, raw, out)
    specs.append(f"1:{out}")
    print(f"page 1  archive rectangle only   X {r['X'][1]:.2f} -> {r['X'][1] + SHIFT:.2f}, /Rect untouched")

    # 2 — /Rect only. The archive is written back unchanged, so any difference is the annotation's own bounds.
    a, i, raw = mkbisect.load(src(2))
    r = archive_rect(a)
    out = f"{outdir}/v4-p2-pdf-rect-only.archive"
    mkbisect.save(a, i, raw, out)
    x, y, w, h = r["X"][1], r["Y"][1], r["Width"][1], r["Height"][1]
    specs.append(f"2:{out}:{x + SHIFT:.2f},{y:.2f},{w:.2f},{h:.2f}")
    print(f"page 2  /Rect only               X {x:.2f} -> {x + SHIFT:.2f}, archive untouched")

    # 3 — synthesized payload, both rectangles untouched
    a, i, raw = mkbisect.load(src(3))
    synth = mkbisect3.synthesize(raw)
    out = f"{outdir}/v4-p3-synth-rects-untouched.archive"
    mkbisect.save(a, i, synth, out)
    specs.append(f"3:{out}")
    n = sum(len(mkbisect.records(b)) for _, b in pbcodec.strokes_of(synth))
    before = sum(len(mkbisect.records(b)) for _, b in pbcodec.strokes_of(raw))
    print(f"page 3  synthesized              points {before} -> {n}, both rectangles untouched")

    print("\nspecs:")
    print(" ".join(f'"{s}"' for s in specs))


if __name__ == "__main__":
    main()
