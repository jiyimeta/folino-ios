#!/usr/bin/env python3
"""From variant A (marker identifier), change only the two trailing u16 slots of every point record.

The encoder writes [20:22]=0xAAAA and [22:24]=0xFE54, copied from Pencil-drawn pen samples. Files' own
finger-drawn marker carries 0x7FFF in the slot that varies per point for a marker. Which slot turns the chisel?

  python3 mkazimuthvariants.py <A-marker-id.bin> <outdir>

  A1  [20:22] -> 0x7FFF
  A2  [22:24] -> 0x7FFF
  A3  both    -> 0x7FFF
  A4  [20:22] -> 0x0000
"""
import struct
import sys

TOOLS = "/Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/crdt-ink-format/docs/engineering/crdt-ink-format/tools"
sys.path.insert(0, TOOLS)
import mkbisect  # noqa: E402
import pbcodec  # noqa: E402


def map_records(stroke_fields, fn):
    out = []
    for f, wt, v in stroke_fields:
        if f != 5:
            out.append((f, wt, v))
            continue
        body = pbcodec.parse(v)
        pts = pbcodec.get(body, 5)[0]
        recs = b"".join(fn(pts[i:i + 24]) for i in range(0, len(pts), 24))
        out.append((f, wt, pbcodec.serialize(pbcodec.replace(body, 5, 0, recs))))
    return out


def tail(a=None, b=None):
    def fn(rec):
        x = rec[20:22] if a is None else struct.pack("<H", a)
        y = rec[22:24] if b is None else struct.pack("<H", b)
        return rec[:20] + x + y
    return fn


def build(src, out, fn):
    archive, index, raw = mkbisect.load(src)
    mkbisect.save(archive, index, mkbisect.map_strokes(raw, lambda s: map_records(s, fn)), out)
    print(f"wrote {out}")


def main():
    src, outdir = sys.argv[1:3]
    build(src, f"{outdir}/A1-slot20-7fff.bin", tail(a=0x7FFF))
    build(src, f"{outdir}/A2-slot22-7fff.bin", tail(b=0x7FFF))
    build(src, f"{outdir}/A3-both-7fff.bin", tail(a=0x7FFF, b=0x7FFF))
    build(src, f"{outdir}/A4-slot20-0000.bin", tail(a=0x0000))


if __name__ == "__main__":
    main()
