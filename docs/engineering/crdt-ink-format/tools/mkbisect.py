#!/usr/bin/env python3
"""One-variable-at-a-time bisect of what makes Apple's markup reject an edited ink payload.

The first test round established that a pure round trip is accepted and that changing geometry is not — but the
"geometry" variant also regenerated the timestamp and two UUIDs, so it isolated nothing. Each variant here
changes exactly one thing and leaves everything else byte-identical.

  python3 mkbisect.py <sample.archive> <outdir>

Writes one archive per variant. Feed them to applyvariants.swift on separate pages of a document whose other
pages are left untouched as controls.
"""
import gzip
import plistlib
import struct
import sys
import time
import uuid

sys.path.insert(0, __file__.rsplit("/", 1)[0])
import pbcodec  # noqa: E402

POINT = 24
SCALE = 0.7504


def drawing_index(archive):
    for i, o in enumerate(archive["$objects"]):
        if isinstance(o, bytes) and o[:3] == b"\x1f\x8b\x08":
            return i
    raise SystemExit("no gzipped drawing in the archive")


def load(path):
    a = plistlib.load(open(path, "rb"))
    i = drawing_index(a)
    return a, i, gzip.decompress(a["$objects"][i])


def save(archive, index, raw, path):
    archive["$objects"][index] = gzip.compress(raw, mtime=0)
    open(path, "wb").write(plistlib.dumps(archive, fmt=plistlib.FMT_BINARY))


def map_strokes(payload, fn):
    """Rebuild the payload with `fn` applied to each stroke's field list."""
    top = pbcodec.parse(payload)
    out = []
    for f, wt, v in top:
        if f != 2:
            out.append((f, wt, v))
            continue
        drawing = [
            (df, dwt, pbcodec.serialize(fn(pbcodec.parse(dv))) if df == 3 else dv)
            for df, dwt, dv in pbcodec.parse(v)
        ]
        out.append((f, wt, pbcodec.serialize(drawing)))
    return pbcodec.serialize(out)


def map_body(stroke, fn):
    return [(f, wt, pbcodec.serialize(fn(pbcodec.parse(v))) if f == 5 else v) for f, wt, v in stroke]


def records(body):
    data = pbcodec.get(body, 5)
    return [] if not data else [data[0][i:i + POINT] for i in range(0, len(data[0]), POINT)]


# --- variants -------------------------------------------------------------------------------------------

def v_points_only(payload, dx=80.0):
    """Translate every point. Count, timestamp, UUIDs and the bbox field are all left alone."""
    def stroke(sf):
        def body(b):
            recs = []
            for r in records(b):
                t, x, y = struct.unpack("<fff", r[0:12])
                recs.append(struct.pack("<fff", t, x + dx, y) + r[12:])
            return [(f, wt, b"".join(recs) if f == 5 else v) for f, wt, v in b]
        return map_body(sf, body)
    return map_strokes(payload, stroke)


def v_points_and_bbox(payload, dx=80.0):
    """Translate every point AND move the bbox to match. Still no id or timestamp change."""
    def stroke(sf):
        def body(b):
            recs = []
            for r in records(b):
                t, x, y = struct.unpack("<fff", r[0:12])
                recs.append(struct.pack("<fff", t, x + dx, y) + r[12:])
            out = []
            for f, wt, v in b:
                if f == 5:
                    out.append((f, wt, b"".join(recs)))
                elif f == 6:
                    bb = pbcodec.parse(v)
                    shifted = []
                    for bf, bwt, bv in bb:
                        if bf == 1:
                            shifted.append((bf, bwt, struct.pack("<f", struct.unpack("<f", bv)[0] + dx)))
                        else:
                            shifted.append((bf, bwt, bv))
                    out.append((f, wt, pbcodec.serialize(shifted)))
                else:
                    out.append((f, wt, v))
            return out
        return map_body(sf, body)
    return map_strokes(payload, stroke)


def v_timestamp_only(payload):
    def stroke(sf):
        def body(b):
            return [(f, wt, struct.pack("<d", time.time() - 978307200.0) if f == 11 else v) for f, wt, v in b]
        return map_body(sf, body)
    return map_strokes(payload, stroke)


def v_body_uuids_only(payload):
    def stroke(sf):
        def body(b):
            return [(f, wt, uuid.uuid4().bytes if f in (13, 14) and len(v) == 16 else v) for f, wt, v in b]
        return map_body(sf, body)
    return map_strokes(payload, stroke)


def v_stroke_uuids_only(payload):
    def stroke(sf):
        return [(f, wt, uuid.uuid4().bytes if f in (2, 9) and isinstance(v, bytes) and len(v) == 16 else v)
                for f, wt, v in sf]
    return map_strokes(payload, stroke)


def v_drop_last_point(payload):
    """Shorten the stroke by one point, updating only the count and the payload."""
    def stroke(sf):
        def body(b):
            recs = records(b)[:-1]
            return [(f, wt, len(recs) if f == 4 else (b"".join(recs) if f == 5 else v)) for f, wt, v in b]
        return map_body(sf, body)
    return map_strokes(payload, stroke)


VARIANTS = [
    # Nothing else at all: not the protobuf bbox, not the archive rect. The purest test of whether the point
    # bytes may be touched. The ink will sit outside its own declared bounds, which is the point.
    ("1-points-only", v_points_only, 0.0),
    ("2-points-and-bbox", v_points_and_bbox, 80.0 * SCALE),
    ("3-timestamp-only", v_timestamp_only, 0.0),
    ("4-body-uuids-only", v_body_uuids_only, 0.0),
    ("5-stroke-uuids-only", v_stroke_uuids_only, 0.0),
    ("6-drop-last-point", v_drop_last_point, 0.0),
]


def shift_rect(archive, dx_page):
    if dx_page == 0:
        return
    objs = archive["$objects"]
    for o in objs:
        if isinstance(o, dict) and "NS.keys" in o:
            keys = [objs[u.data] for u in o["NS.keys"]]
            if "X" in keys and "Y" in keys:
                for key, uid in zip(keys, o["NS.objects"]):
                    if key == "X":
                        objs[uid.data] += dx_page
                return


def main():
    src, outdir = sys.argv[1], sys.argv[2]
    for name, fn, dx_page in VARIANTS:
        archive, index, raw = load(src)
        edited = fn(raw)
        shift_rect(archive, dx_page)
        path = f"{outdir}/bisect-{name}.archive"
        save(archive, index, edited, path)
        n = sum(len(records(body)) for _, body in pbcodec.strokes_of(edited))
        print(f"{name}: drawing={len(edited)} points={n} rect_dx={dx_page:.1f}")


if __name__ == "__main__":
    main()
