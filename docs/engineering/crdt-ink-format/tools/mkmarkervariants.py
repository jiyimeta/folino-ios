#!/usr/bin/env python3
"""One-variable variants of folino's own exported archives, for a device round.

  python3 mkmarkervariants.py <highlighter.bin> <pen.bin> <outdir>

  A  highlighter: tool id com.apple.ink.pen -> com.apple.ink.marker, nothing else
  B  highlighter: A + the extra ink fields Files writes for a marker ("linear", color x0.15, color x0.85, -0.5)
  C  pen:         per-point force 0 -> 500, nothing else
  D  highlighter: per-point width 303 -> 70, nothing else
"""
import struct
import sys

TOOLS = "/Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/crdt-ink-format/docs/engineering/crdt-ink-format/tools"
sys.path.insert(0, TOOLS)
import mkbisect  # noqa: E402
import pbcodec  # noqa: E402

MARKER = b"com.apple.ink.marker"


def map_ink(stroke_fields, fn):
    return [(f, wt, pbcodec.serialize(fn(pbcodec.parse(v))) if f == 4 else v) for f, wt, v in stroke_fields]


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


def rgba_of(ink_fields):
    return [struct.unpack("<f", v)[0] for _, _, v in pbcodec.parse(pbcodec.get(ink_fields, 1)[0])]


def color_message(r, g, b, a):
    return pbcodec.serialize([(i + 1, 5, struct.pack("<f", c)) for i, c in enumerate((r, g, b, a))])


def variant_a(ink):
    return pbcodec.replace(ink, 2, 0, MARKER)


def variant_b(ink):
    ink = variant_a(ink)
    r, g, b, _ = rgba_of(ink)
    extra = [
        (4, 2, b"linear"),
        (5, 2, color_message(r * 0.15, g * 0.15, b * 0.15, 1.0)),
        (6, 2, color_message(r * 0.85, g * 0.85, b * 0.85, 1.0)),
        (8, 1, struct.pack("<d", -0.5)),
    ]
    return ink + extra


def force_500(rec):
    return rec[:18] + struct.pack("<H", 500) + rec[20:]


def width_70(rec):
    return rec[:12] + struct.pack("<H", 70) + rec[14:]


def build(src, out, stroke_fn):
    archive, index, raw = mkbisect.load(src)
    mkbisect.save(archive, index, mkbisect.map_strokes(raw, stroke_fn), out)
    print(f"wrote {out}")


def main():
    hl, pen, outdir = sys.argv[1:4]
    build(hl, f"{outdir}/A-marker-id.bin", lambda s: map_ink(s, variant_a))
    build(hl, f"{outdir}/B-marker-full.bin", lambda s: map_ink(s, variant_b))
    build(pen, f"{outdir}/C-pen-force500.bin", lambda s: map_records(s, force_500))
    build(hl, f"{outdir}/D-hl-width70.bin", lambda s: map_records(s, width_70))


if __name__ == "__main__":
    main()
