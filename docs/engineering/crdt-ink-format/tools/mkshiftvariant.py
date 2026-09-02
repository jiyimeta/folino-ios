#!/usr/bin/env python3
"""Shift the stored bbox and the archive rectangle together by dx canvas units, leaving the points alone.

If Apple's markup places a drawing by aligning ITS OWN recomputed bounds onto the archive rectangle, the ink
follows the rectangle. If it draws the points in absolute canvas coordinates, the ink stays put.

  python3 mkshiftvariant.py <archive.bin> <out.bin> <dx_canvas> <dy_canvas>
Prints the new /Rect (page space, y up) to pass to applyone.
"""
import plistlib
import struct
import sys

TOOLS = "/Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/crdt-ink-format/docs/engineering/crdt-ink-format/tools"
sys.path.insert(0, TOOLS)
import mkbisect  # noqa: E402
import mkbisect5  # noqa: E402
import pbcodec  # noqa: E402

PAGE_W, PAGE_H = 595.2756, 841.8898


def shift_bbox(stroke_fields, dx, dy):
    out = []
    for f, wt, v in stroke_fields:
        if f != 5:
            out.append((f, wt, v)); continue
        body = pbcodec.parse(v)
        box = pbcodec.parse(pbcodec.get(body, 6)[0])
        vals = [struct.unpack("<f", bv)[0] for _, _, bv in box]
        vals[0] += dx; vals[1] += dy
        new_box = pbcodec.serialize([(i + 1, 5, struct.pack("<f", c)) for i, c in enumerate(vals)])
        out.append((f, wt, pbcodec.serialize(pbcodec.replace(body, 6, 0, new_box))))
        print(f"bbox canvas -> x={vals[0]:.4f} y={vals[1]:.4f} w={vals[2]:.4f} h={vals[3]:.4f}")
    return out


def main():
    src, out, dx, dy = sys.argv[1], sys.argv[2], float(sys.argv[3]), float(sys.argv[4])
    archive, index, raw = mkbisect.load(src)
    canvas_w, canvas_h = mkbisect5.canvas_size(archive)
    sx, sy = PAGE_W / canvas_w, PAGE_H / canvas_h
    raw = mkbisect.map_strokes(raw, lambda s: shift_bbox(s, dx, dy))

    objs = archive["$objects"]
    for o in objs:
        if isinstance(o, dict) and "NS.keys" in o:
            keys = [objs[u.data] for u in o["NS.keys"]]
            if "X" in keys and "Y" in keys and "Width" in keys:
                v = dict(zip(keys, o["NS.objects"]))
                # the drawingSize dict has no X; the rectangle dict does
                objs[v["X"].data] += dx * sx
                objs[v["Y"].data] -= dy * sy  # page y is up, canvas y is down
                rect = tuple(objs[v[k].data] for k in ("X", "Y", "Width", "Height"))
                print(f"archive rectangle -> X={rect[0]:.4f} Y={rect[1]:.4f} W={rect[2]:.4f} H={rect[3]:.4f}")
                print(f"/Rect -> {rect[0] - 1:.4f},{rect[1] - 1:.4f},{rect[2] + 2:.4f},{rect[3] + 2:.4f}")
    mkbisect.save(archive, index, raw, out)
    print(f"wrote {out}")


if __name__ == "__main__":
    main()
