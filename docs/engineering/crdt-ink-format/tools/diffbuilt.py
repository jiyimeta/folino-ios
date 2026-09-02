#!/usr/bin/env python3
"""Compare a payload we built against one Apple wrote, field by field.

The probe round isolated the fault to the payload: an Apple payload we placed ourselves, in a document Apple
never touched, at a rect we computed, was accepted -- and the same placement carrying our own bytes was not. So
the annotation, the document and the geometry are all cleared, and whatever is wrong is inside `mkprobe.build`.

This prints structure before values: field order and wire types first, because a hand-written parser can care
about those in ways protobuf does not, then the point record layout byte by byte, then the values themselves
split into the ones that are meant to differ and the ones that are not.

  python3 diffbuilt.py <sample.bin> <built.archive>
"""
import struct
import sys

sys.path.insert(0, __file__.rsplit("/", 1)[0])
import mkbisect  # noqa: E402
import pbcodec  # noqa: E402


def levels(payload):
    top = pbcodec.parse(payload)
    drawing = pbcodec.parse(pbcodec.get(top, 2)[0])
    stroke = pbcodec.parse(pbcodec.get(drawing, 3)[0])
    points = pbcodec.parse(pbcodec.get(stroke, 5)[0])
    return {"top": top, "drawing": drawing, "stroke": stroke, "points": points}


def shape(fields):
    return [(f, wt) for f, wt, _ in fields]


def records(points):
    data = pbcodec.get(points, 5)[0]
    return [data[i:i + 24] for i in range(0, len(data), 24)]


def main():
    sample = mkbisect.load(sys.argv[1])[2]
    built = mkbisect.load(sys.argv[2])[2]
    a, b = levels(sample), levels(built)

    print("field order and wire types  (apple -> ours)")
    for name in ("top", "drawing", "stroke", "points"):
        sa, sb = shape(a[name]), shape(b[name])
        mark = "same" if sa == sb else "DIFFERENT"
        print(f"  {name:8s} {mark}")
        if sa != sb:
            print(f"      apple {sa}")
            print(f"      ours  {sb}")

    print("\nfirst point record  (24 bytes)")
    ra, rb = records(a["points"])[0], records(b["points"])[0]
    print(f"  apple {ra.hex(' ')}")
    print(f"  ours  {rb.hex(' ')}")
    slots = [("time", 0, 4, "f"), ("x", 4, 8, "f"), ("y", 8, 12, "f"),
             ("width", 12, 14, "H"), ("[14:16]", 14, 16, "H"), ("[16:18]", 16, 18, "H"),
             ("force", 18, 20, "H"), ("[20:22]", 20, 22, "H"), ("[22:24]", 22, 24, "H")]
    for label, lo, hi, fmt in slots:
        va = struct.unpack("<" + fmt, ra[lo:hi])[0]
        vb = struct.unpack("<" + fmt, rb[lo:hi])[0]
        tail = "" if lo < 12 else f"   raw {ra[lo:hi].hex()} vs {rb[lo:hi].hex()}"
        print(f"  {label:8s} apple {va:<12g} ours {vb:<12g}{tail}")

    print("\nfields whose bytes differ")
    for name in ("top", "drawing", "stroke", "points"):
        # Keyed by (field, occurrence): a field can repeat, and pairing the two lists positionally makes one
        # missing entry look like every field after it changed -- which is how a single defect read as three.
        def keyed(fields):
            seen, out = {}, {}
            for f, _, v in fields:
                seen[f] = seen.get(f, 0) + 1
                out[(f, seen[f])] = v
            return out

        ka, kb = keyed(a[name]), keyed(b[name])
        for key in sorted(set(ka) | set(kb)):
            va, vb = ka.get(key), kb.get(key)
            if va == vb:
                continue
            kind = ("MISSING" if vb is None else "EXTRA" if va is None
                    else "expected" if (name, key[0]) in EXPECTED else "UNEXPECTED")
            def size(v):
                return "-" if v is None else v if isinstance(v, int) else f"{len(v)}B"
            occurrence = f"#{key[1]}" if max(k[1] for k in ka | kb if k[0] == key[0]) > 1 else ""
            print(f"  {kind:10s} {name}.{key[0]}{occurrence:<4} apple {size(va)} / ours {size(vb)}")


# Differences the probe intends: geometry, colour, identity and time.
EXPECTED = {("stroke", 2), ("stroke", 4), ("stroke", 5), ("stroke", 9),
            ("points", 4), ("points", 5), ("points", 6), ("points", 11),
            ("points", 13), ("points", 14)}

if __name__ == "__main__":
    main()
