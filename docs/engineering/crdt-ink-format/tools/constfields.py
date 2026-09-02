#!/usr/bin/env python3
"""Which fields of the AKAnnotationV2 payload are constant across every sample?

A field that is byte-identical on all eight samples is structural scaffolding an encoder can hardcode. A field
that varies is data the encoder has to derive, and every one of those has to be accounted for before the
encoder can claim to *synthesize* the format rather than to edit a captured copy of it.

This is the cheap half of the question. It says which fields are candidates for hardcoding; it cannot say that
a constant is genuinely constant rather than merely the same on eight files written by one person on one
device in one sitting. Fields whose meaning is still unknown stay flagged as such.

  python3 constfields.py <samples-dir>
"""
import glob
import struct
import sys

sys.path.insert(0, __file__.rsplit("/", 1)[0])
import mkbisect  # noqa: E402
import pbcodec  # noqa: E402

# Descend into these length-delimited paths; anything else is compared as opaque bytes.
NESTED = {"2", "2.3", "2.3.4", "2.3.5"}


def walk(fields, prefix, out):
    for f, wt, v in fields:
        path = f"{prefix}.{f}" if prefix else str(f)
        if wt == 2 and path in NESTED:
            walk(pbcodec.parse(v), path, out)
        else:
            out.setdefault(path, []).append(v if isinstance(v, bytes) else str(v).encode())


def show(v):
    if len(v) == 4:
        return f"f32 {struct.unpack('<f', v)[0]:g} / u32 {struct.unpack('<I', v)[0]}"
    if len(v) == 8:
        return f"f64 {struct.unpack('<d', v)[0]:g}"
    if len(v) == 16:
        return "16 bytes (uuid-shaped)"
    if 0 < len(v) < 40 and all(32 <= c < 127 for c in v):
        return repr(v.decode())
    return f"{len(v)} bytes {v[:12].hex()}{'...' if len(v) > 12 else ''}"


def main():
    paths = sorted(glob.glob(f"{sys.argv[1]}/ppk-p*.bin"))
    # One unit of comparison per STROKE, not per file: a sample holding two strokes would otherwise differ
    # from a one-stroke sample in every repeated field, which says nothing about whether the field is constant.
    per_sample = []
    for p in paths:
        _, _, raw = mkbisect.load(p)
        # `pbcodec.strokes_of` descends one level further than we want (it yields `.2.3.5`, the points
        # container); the stroke itself is `.2.3`, which is where the colour and the tool identifier live.
        for drawing in pbcodec.get(pbcodec.parse(raw), 2):
            for stroke in pbcodec.get(pbcodec.parse(drawing), 3):
                d = {}
                walk(pbcodec.parse(stroke), "2.3", d)
                per_sample.append(d)
    print(f"{len(paths)} samples, {len(per_sample)} strokes\n")

    every = sorted({k for d in per_sample for k in d}, key=lambda s: [int(x) for x in s.split(".")])
    const, varies, partial = [], [], []
    for k in every:
        present = [d.get(k) for d in per_sample]
        if any(v is None for v in present):
            partial.append((k, sum(v is not None for v in present)))
            continue
        vals = {tuple(v) for v in present}
        (const if len(vals) == 1 else varies).append((k, present[0]))

    print("CONSTANT across all samples -- hardcodable:")
    for k, v in const:
        print(f"  .{k:<10} {show(v[0]) if len(v) == 1 else f'{len(v)}x ' + show(v[0])}")
    print("\nVARIES -- the encoder must derive:")
    for k, v in varies:
        # How MANY distinct values matter: a field taking two values across eight strokes is scaffolding with a
        # flag in it, not free-form data, and is worth separating from one that is different every time.
        distinct = {bytes(x) for d in per_sample for x in d[k]}
        listing = ""
        if len(distinct) <= 3 and all(len(x) <= 24 for x in distinct):
            listing = "  = " + " | ".join(sorted(show(x) for x in distinct))
        print(f"  .{k:<10} {len(distinct)} distinct / {len(per_sample)} strokes{listing}")
    if partial:
        print("\nNOT PRESENT IN EVERY SAMPLE -- optional, or conditional:")
        for k, n in partial:
            print(f"  .{k:<10} in {n}/{len(paths)}")


if __name__ == "__main__":
    main()
