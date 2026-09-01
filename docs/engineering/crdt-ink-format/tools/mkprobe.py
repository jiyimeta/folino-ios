#!/usr/bin/env python3
"""Can the payload be BUILT rather than edited? And does it work in a document Apple never touched?

Every round so far synthesized geometry inside scaffolding copied from the sample being edited. That is enough
to show the geometry is free; it is not enough to show an encoder can emit the format, because the fields whose
meaning is still unknown rode along untouched from the very sample they were written into.

`constfields.py` shows only `.2.3.1` is invariant across the eight strokes. The rest of the undecoded
scaffolding takes two to five distinct values, so "copy it" is not obviously the same thing as "any fixed value
works". This round asks whether ONE fixed set works everywhere.

  1  fixed scaffolding, taken from sample 1, written over sample 1     -- our writer, same-sample scaffolding
  2  fixed scaffolding, taken from sample 1, written over sample 2     -- does one constant set travel?
  3  scaffolding fields OMITTED entirely                               -- are they required at all?
  4  untouched                                                         -- control

Every point record is assembled here from named quantities rather than copied, so a pass means an encoder can
write this format from an InkStroke and nothing else.

  python3 mkprobe.py <samples-dir> <outdir>
"""
import glob
import struct
import sys

sys.path.insert(0, __file__.rsplit("/", 1)[0])
import mkbisect  # noqa: E402
import mkbisect5  # noqa: E402
import pbcodec  # noqa: E402

# Field numbers whose meaning is still unknown. They are carried as one fixed set, or dropped, per variant.
STROKE_SCAFFOLD = (1, 3, 10)
POINTS_SCAFFOLD = (1, 2, 3, 9)


def constants_from(path):
    """The undecoded scaffolding of one sample, as the fixed set every variant will use."""
    _, _, raw = mkbisect.load(path)
    stroke = pbcodec.parse(pbcodec.get(pbcodec.parse(pbcodec.get(pbcodec.parse(raw), 2)[0]), 3)[0])
    points = pbcodec.parse(pbcodec.get(stroke, 5)[0])
    return (
        [(f, wt, v) for f, wt, v in stroke if f in STROKE_SCAFFOLD],
        [(f, wt, v) for f, wt, v in points if f in POINTS_SCAFFOLD],
    )


def record(t, x, y, width, force):
    """One 24-byte point record, assembled from named quantities.

    [0:4] f32 time, [4:8] f32 x, [8:12] f32 y, [12:14] u16 width, [14:16] u16 1000, [16:18] u16 0,
    [18:20] u16 force, [20:22] 0xAAAA, [22:24] 0xFE54. The last two are the same on every sample and every
    stroke; the two zero-ish slots likewise. Nothing here is copied from a sample.
    """
    return (struct.pack("<fff", t, x, y)
            + struct.pack("<HHHH", width, 1000, 0, force)
            + b"\xaa\xaa\xfe\x54")


def zigzag(box, n=48, width=26, force=340):
    """Points and their bounding box, in canvas units. The box is the caller's, padded like Apple pads."""
    bx, by, bw, bh = box
    pad = 1.4
    recs = []
    for i in range(n):
        x = bx + pad + (bw - 2 * pad) * i / (n - 1)
        y = by + pad + (0 if i % 2 else max(bh - 2 * pad, 0.0))
        recs.append(record(i * 0.008, x, y, width, force))
    return b"".join(recs)


def bbox_field(box):
    x, y, w, h = box
    return pbcodec.serialize([(i + 1, 5, struct.pack("<f", v)) for i, v in enumerate((x, y, w, h))])


def rgba_field(r, g, b, a):
    return pbcodec.serialize([(i + 1, 5, struct.pack("<f", v)) for i, v in enumerate((r, g, b, a))])


def build(scaffold, box, rgba, when):
    """A complete drawing payload. `scaffold` is (stroke_fields, points_fields) or None to omit them."""
    stroke_extra, points_extra = scaffold if scaffold else ([], [])
    points = sorted(points_extra + [
        (4, 0, 48),
        (5, 2, zigzag(box)),
        (6, 2, bbox_field(box)),
        (11, 1, struct.pack("<d", when)),
        (13, 2, b"\x11" * 16),
        (14, 2, b"\x22" * 16),
    ], key=lambda f: f[0])
    ink = pbcodec.serialize([
        (1, 2, rgba_field(*rgba)),
        (2, 2, b"com.apple.ink.pen"),
        (3, 0, 3),
    ])
    stroke = sorted(stroke_extra + [
        (2, 2, b"\x33" * 16),
        (4, 2, ink),
        (5, 2, pbcodec.serialize(points)),
        (9, 2, b"\x44" * 16),
    ], key=lambda f: f[0])
    drawing = pbcodec.serialize([(1, 0, 10), (2, 0, 10), (3, 2, pbcodec.serialize(stroke))])
    return pbcodec.serialize([(1, 0, 0), (2, 2, drawing)])


BOX = (120.0, 200.0, 300.0, 90.0)  # canvas units, well inside every sample's canvas


def main():
    samples, outdir = sys.argv[1], sys.argv[2]
    # A page size may be given to target a FOREIGN document — one Apple never touched. The rect must be computed
    # against that document's real MediaBox, so this is the same rule the encoder will follow, exercised early.
    foreign = len(sys.argv) > 4
    if foreign:
        mkbisect5.PAGE_W, mkbisect5.PAGE_H = float(sys.argv[3]), float(sys.argv[4])
        print(f"targeting a foreign page of {mkbisect5.PAGE_W} x {mkbisect5.PAGE_H}")

    def src(page):
        return glob.glob(f"{samples}/ppk-p{page}-*.bin")[0]

    scaffold = constants_from(src(1))
    print(f"fixed scaffolding from sample 1: stroke {[f for f, _, _ in scaffold[0]]}, "
          f"points {[f for f, _, _ in scaffold[1]]}")

    specs = []

    def emit(page, name, payload):
        archive, index, _ = mkbisect.load(src(1 if foreign else page))
        rect = mkbisect5.to_page(archive, mkbisect5.stored_bbox(payload))
        mkbisect5.set_archive_rect(archive, rect)
        out = f"{outdir}/probe-p{page}-{name}.archive"
        mkbisect.save(archive, index, payload, out)
        ar = mkbisect5.annotation_rect(rect)
        specs.append(f"{page}:{out}:{ar[0]:.6f},{ar[1]:.6f},{ar[2]:.6f},{ar[3]:.6f}")
        print(f"page {page}  {name:24s} rect=({rect[0]:.1f},{rect[1]:.1f},{rect[2]:.1f},{rect[3]:.1f})")

    built = build(scaffold, BOX, (1.0, 0.1, 0.1, 1.0), 810_000_000.0)
    if foreign:
        # One variable each: page 2 carries Apple's own payload into our document, page 3 carries ours. If 2
        # passes and 3 fails the writer is at fault; if both fail the document is.
        emit(2, "apple-payload-our-doc", pbcodec.serialize(pbcodec.parse(mkbisect.load(src(1))[2])))
        emit(3, "our-payload-our-doc", built)
    else:
        emit(1, "built-scaffold-same", built)
        emit(2, "built-scaffold-travelled", built)
        emit(3, "built-no-scaffold", build(None, BOX, (1.0, 0.1, 0.1, 1.0), 810_000_000.0))
        print("\npages 4+ are left untouched as controls")

    print("\nspecs:")
    print(" ".join(f'"{s}"' for s in specs))


if __name__ == "__main__":
    main()
