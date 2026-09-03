#!/usr/bin/env python3
"""Swap a folino archive's gzip drawing for a PKDrawing (`wrd`) blob and set the rectangle from its bounds.

  python3 mkwrdarchive.py <archive.bin> <drawing.wrd> <bx> <by> <bw> <bh> <out.bin>
Bounds are canvas units (y down). Prints the archive rectangle and the /Rect for applyone.
"""
import plistlib
import sys

TOOLS = "/Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/crdt-ink-format/docs/engineering/crdt-ink-format/tools"
sys.path.insert(0, TOOLS)
import mkbisect  # noqa: E402
import mkbisect5  # noqa: E402

PAGE_W, PAGE_H = 595.2756, 841.8898

src, wrd, bx, by, bw, bh, out = sys.argv[1], sys.argv[2], *map(float, sys.argv[3:7]), sys.argv[7]
archive = plistlib.load(open(src, "rb"))
index = mkbisect.drawing_index(archive)
archive["$objects"][index] = open(wrd, "rb").read()
canvas_w, canvas_h = mkbisect5.canvas_size(archive)
sx, sy = PAGE_W / canvas_w, PAGE_H / canvas_h

objs = archive["$objects"]
for o in objs:
    if isinstance(o, dict) and "NS.keys" in o:
        keys = [objs[u.data] for u in o["NS.keys"]]
        if "X" in keys and "Y" in keys and "Width" in keys:
            v = dict(zip(keys, o["NS.objects"]))
            objs[v["X"].data] = bx * sx
            objs[v["Y"].data] = PAGE_H - (by + bh) * sy
            objs[v["Width"].data] = bw * sx
            objs[v["Height"].data] = bh * sy
            rect = tuple(objs[v[k].data] for k in ("X", "Y", "Width", "Height"))
            print(f"archive rectangle -> X={rect[0]:.4f} Y={rect[1]:.4f} W={rect[2]:.4f} H={rect[3]:.4f}")
            print(f"/Rect -> {rect[0] - 1:.4f},{rect[1] - 1:.4f},{rect[2] + 2:.4f},{rect[3] + 2:.4f}")
open(out, "wb").write(plistlib.dumps(archive, fmt=plistlib.FMT_BINARY))
print(f"wrote {out}")
