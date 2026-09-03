#!/usr/bin/env python3
"""Measure the padding between a payload's point extent and its stored bbox, against the width field.

  python3 padding.py <archive.bin>...
"""
import struct
import sys

TOOLS = "/Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/crdt-ink-format/docs/engineering/crdt-ink-format/tools"
sys.path.insert(0, TOOLS)
import mkbisect  # noqa: E402
import mkbisect5  # noqa: E402
import pbcodec  # noqa: E402


def main():
    for path in sys.argv[1:]:
        archive, _, raw = mkbisect.load(path)
        canvas_w, canvas_h = mkbisect5.canvas_size(archive)
        print(f"{path.rsplit('/', 1)[-1]}  canvas {canvas_w:.4f} x {canvas_h:.4f}")
        for drawing in pbcodec.get(pbcodec.parse(raw), 2):
            for stroke in pbcodec.get(pbcodec.parse(drawing), 3):
                fields = pbcodec.parse(stroke)
                tool = ""
                for ink in pbcodec.get(fields, 4):
                    t = [v for f, _, v in pbcodec.parse(ink) if f == 2]
                    if t:
                        tool = t[0].decode(errors="replace")
                for body in pbcodec.get(fields, 5):
                    points = pbcodec.parse(body)
                    bbox = pbcodec.get(points, 6)
                    b = [struct.unpack("<f", v)[0] for _, _, v in pbcodec.parse(bbox[0])] if bbox else None
                    blob = pbcodec.get(points, 5)
                    if not blob:
                        continue
                    recs = [blob[0][i:i + 24] for i in range(0, len(blob[0]), 24)]
                    xs = [struct.unpack("<f", r[4:8])[0] for r in recs]
                    ys = [struct.unpack("<f", r[8:12])[0] for r in recs]
                    ws = [struct.unpack("<H", r[12:14])[0] for r in recs]
                    fs = [struct.unpack("<H", r[18:20])[0] for r in recs]
                    print(f"  tool={tool} n={len(recs)} width min/max={min(ws)}/{max(ws)} force min/max={min(fs)}/{max(fs)}")
                    print(f"  points x [{min(xs):.4f}, {max(xs):.4f}]  y [{min(ys):.4f}, {max(ys):.4f}]")
                    if b:
                        print(f"  bbox   x [{b[0]:.4f}, {b[0] + b[2]:.4f}]  y [{b[1]:.4f}, {b[1] + b[3]:.4f}]")
                        print(f"  padding left={min(xs) - b[0]:.4f} right={b[0] + b[2] - max(xs):.4f}"
                              f" top={min(ys) - b[1]:.4f} bottom={b[1] + b[3] - max(ys):.4f}"
                              f"   width/10={max(ws) / 10:.2f} half={max(ws) / 20:.2f}")


if __name__ == "__main__":
    main()
