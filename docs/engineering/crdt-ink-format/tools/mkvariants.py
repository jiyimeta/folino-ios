#!/usr/bin/env python3
"""Build three test variants of an AKAnnotationV2 archive, to separate three different failure modes.

Given one real archive extracted from a Books-annotated PDF, writes:

  A  round-trip   parsed and re-serialized with nothing changed. Isolates "does our read/write path damage it".
  B  translated   the same ink, every point moved in x. Isolates "may we change geometry".
  C  synthesized  our own geometry, fresh UUIDs and timestamp, with only the still-undecoded scaffolding
                  fields copied from the sample. This is the shape production code would emit.

If A erases on device and B does not, the coordinate handling is wrong. If B erases and C does not, one of the
values we generate is being validated. If C erases, folino can write these.

  python3 mkvariants.py <sample.archive> <outdir>
"""
import gzip
import plistlib
import struct
import sys
import uuid

sys.path.insert(0, __file__.rsplit("/", 1)[0])
import pbcodec  # noqa: E402

POINT = 24
# canvas space -> page space, derived from the samples: page = canvas * SCALE, y flipped about the page height.
SCALE = 0.7504


def drawing_bytes(archive):
    objs = archive["$objects"]
    for i, o in enumerate(objs):
        if isinstance(o, bytes) and o[:3] == b"\x1f\x8b\x08":
            return i, gzip.decompress(o)
    raise SystemExit("no gzipped drawing found in the archive")


def put_drawing(archive, index, raw):
    # mtime 0 so repeated runs are reproducible and diffs stay meaningful.
    archive["$objects"][index] = gzip.compress(raw, mtime=0)


def edit_strokes(payload, fn):
    """Rebuild the payload, passing each stroke's field list through `fn`."""
    top = pbcodec.parse(payload)
    out_top = []
    for f, wt, v in top:
        if f != 2:
            out_top.append((f, wt, v))
            continue
        drawing = pbcodec.parse(v)
        out_drawing = []
        for df, dwt, dv in drawing:
            if df != 3:
                out_drawing.append((df, dwt, dv))
                continue
            out_drawing.append((df, dwt, pbcodec.serialize(fn(pbcodec.parse(dv)))))
        out_top.append((f, wt, pbcodec.serialize(out_drawing)))
    return pbcodec.serialize(out_top)


def edit_body(stroke_fields, fn):
    """Pass the stroke's body (field 5) through `fn`."""
    out = []
    for f, wt, v in stroke_fields:
        if f == 5:
            out.append((f, wt, pbcodec.serialize(fn(pbcodec.parse(v)))))
        else:
            out.append((f, wt, v))
    return out


def points_of(body):
    data = pbcodec.get(body, 5)
    if not data:
        return []
    b = data[0]
    return [b[i:i + POINT] for i in range(0, len(b), POINT)]


def set_points(body, records):
    joined = b"".join(records)
    out = []
    for f, wt, v in body:
        if f == 4:
            out.append((f, wt, len(records)))
        elif f == 5:
            out.append((f, wt, joined))
        elif f == 6:
            xs = [struct.unpack("<f", r[4:8])[0] for r in records]
            ys = [struct.unpack("<f", r[8:12])[0] for r in records]
            bbox = [
                (1, 5, struct.pack("<f", min(xs))),
                (2, 5, struct.pack("<f", min(ys))),
                (3, 5, struct.pack("<f", max(xs) - min(xs))),
                (4, 5, struct.pack("<f", max(ys) - min(ys))),
            ]
            out.append((f, wt, pbcodec.serialize(bbox)))
        elif f == 11:
            # CFAbsoluteTime, seconds since 2001-01-01. Kept current so it looks like a fresh drawing.
            import time
            out.append((f, wt, struct.pack("<d", time.time() - 978307200.0)))
        elif f in (13, 14):
            out.append((f, wt, uuid.uuid4().bytes))
        else:
            out.append((f, wt, v))
    return out


def fresh_ids(stroke_fields):
    return [(f, wt, uuid.uuid4().bytes if f in (2, 9) and isinstance(v, bytes) and len(v) == 16 else v)
            for f, wt, v in stroke_fields]


def translate(payload, dx):
    def stroke(sf):
        def body(b):
            recs = []
            for r in points_of(b):
                t, x, y = struct.unpack("<fff", r[0:12])
                recs.append(struct.pack("<fff", t, x + dx, y) + r[12:])
            return set_points(b, recs)
        return edit_body(sf, body)
    return edit_strokes(payload, stroke)


def synthesize(payload):
    """Replace the geometry with a zigzag of our own, and regenerate every identifier."""
    def stroke(sf):
        def body(b):
            template = points_of(b)[0]
            recs = []
            n = 48
            for i in range(n):
                t = i * 0.008
                x = 260.0 + i * 6.0
                y = 560.0 + (40.0 if i % 2 else -40.0)
                tail = template[12:]
                recs.append(struct.pack("<fff", t, x, y) + tail)
            return set_points(b, recs)
        return edit_body(fresh_ids(sf), body)
    return edit_strokes(payload, stroke)


def rect_shift(archive, dx_page, dy_page=0.0):
    objs = archive["$objects"]
    for o in objs:
        if isinstance(o, dict) and "NS.keys" in o:
            keys = [objs[u.data] for u in o["NS.keys"]]
            if "X" in keys and "Y" in keys:
                for key, uid in zip(keys, o["NS.objects"]):
                    if key == "X":
                        objs[uid.data] += dx_page
                    elif key == "Y":
                        objs[uid.data] += dy_page
                return


def main():
    src, outdir = sys.argv[1], sys.argv[2]
    base = plistlib.load(open(src, "rb"))

    # A — round trip, nothing changed
    a = plistlib.load(open(src, "rb"))
    i, raw = drawing_bytes(a)
    put_drawing(a, i, pbcodec.serialize(pbcodec.parse(raw)))
    open(f"{outdir}/variant-a-roundtrip.archive", "wb").write(plistlib.dumps(a, fmt=plistlib.FMT_BINARY))

    # B — translated
    b = plistlib.load(open(src, "rb"))
    i, raw = drawing_bytes(b)
    dx_canvas = 80.0
    put_drawing(b, i, translate(raw, dx_canvas))
    rect_shift(b, dx_canvas * SCALE)
    open(f"{outdir}/variant-b-translated.archive", "wb").write(plistlib.dumps(b, fmt=plistlib.FMT_BINARY))

    # C — synthesized geometry and identifiers
    c = plistlib.load(open(src, "rb"))
    i, raw = drawing_bytes(c)
    put_drawing(c, i, synthesize(raw))
    # the zigzag spans canvas x 260..542, y 520..600 -> page space
    objs = c["$objects"]
    for o in objs:
        if isinstance(o, dict) and "NS.keys" in o:
            keys = [objs[u.data] for u in o["NS.keys"]]
            if "X" in keys and "Y" in keys:
                vals = dict(zip(keys, o["NS.objects"]))
                objs[vals["X"].data] = 260.0 * SCALE
                objs[vals["Y"].data] = 842.0 - 600.0 * SCALE
                objs[vals["Width"].data] = (542.0 - 260.0) * SCALE
                objs[vals["Height"].data] = (600.0 - 520.0) * SCALE
                break
    open(f"{outdir}/variant-c-synth.archive", "wb").write(plistlib.dumps(c, fmt=plistlib.FMT_BINARY))

    for name in ("a-roundtrip", "b-translated", "c-synth"):
        path = f"{outdir}/variant-{name}.archive"
        arc = plistlib.load(open(path, "rb"))
        _, r = drawing_bytes(arc)
        n = sum(len(points_of(body)) for _, body in pbcodec.strokes_of(r))
        print(f"{name}: archive={len(open(path,'rb').read())} drawing={len(r)} points={n}")


if __name__ == "__main__":
    main()
