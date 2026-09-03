#!/usr/bin/env python3
"""Dump the first stroke of a folino gzip-protobuf archive as CSV: header line 'tool,r,g,b,a' then x,y,t,w,force.

  python3 exportpoints.py <archive.bin> <out.csv>
"""
import struct
import sys

TOOLS = "/Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/crdt-ink-format/docs/engineering/crdt-ink-format/tools"
sys.path.insert(0, TOOLS)
import mkbisect  # noqa: E402
import pbcodec  # noqa: E402

archive, _, raw = mkbisect.load(sys.argv[1])
lines = []
for drawing in pbcodec.get(pbcodec.parse(raw), 2):
    for stroke in pbcodec.get(pbcodec.parse(drawing), 3):
        fields = pbcodec.parse(stroke)
        ink = pbcodec.parse(pbcodec.get(fields, 4)[0])
        tool = pbcodec.get(ink, 2)[0].decode()
        rgba = [struct.unpack("<f", v)[0] for _, _, v in pbcodec.parse(pbcodec.get(ink, 1)[0])]
        lines.append(f"{tool},{rgba[0]},{rgba[1]},{rgba[2]},{rgba[3]}")
        body = pbcodec.parse(pbcodec.get(fields, 5)[0])
        pts = pbcodec.get(body, 5)[0]
        for i in range(0, len(pts), 24):
            r = pts[i:i + 24]
            t, x, y = struct.unpack("<fff", r[0:12])
            w, _, _, force = struct.unpack("<HHHH", r[12:20])
            lines.append(f"{x},{y},{t},{w / 10},{force / 1000}")
        break
    break
open(sys.argv[2], "w").write("\n".join(lines) + "\n")
print(f"wrote {len(lines) - 1} points to {sys.argv[2]}")
