#!/usr/bin/env python3
"""Calibrate the point record's width and force slots against the marks that produced them.

Acceptance does not depend on these: a payload with a wrong width is still adopted, erased and moved. What
depends on them is how Apple's markup REDRAWS the mark once someone edits it, so an encoder that gets them
wrong ships ink that changes thickness the first time it is touched.

The samples were drawn deliberately: page 1 a thin line, page 4 the thickest pen, page 7 a single dot. So the
values here are a calibration, not just an inventory.

  python3 widths.py <samples-dir>
"""
import glob
import struct
import sys

sys.path.insert(0, __file__.rsplit("/", 1)[0])
import mkbisect  # noqa: E402
import mkbisect5  # noqa: E402
import pbcodec  # noqa: E402


def main():
    for path in sorted(glob.glob(f"{sys.argv[1]}/ppk-p*.bin")):
        archive, _, raw = mkbisect.load(path)
        cw, ch = mkbisect5.canvas_size(archive)
        widths, forces, slot14, slot16 = set(), set(), set(), set()
        count = 0
        for _, body in pbcodec.strokes_of(raw):
            data = pbcodec.get(body, 5)
            if not data:
                continue
            for i in range(0, len(data[0]), 24):
                r = data[0][i:i + 24]
                w, s14, s16, f = struct.unpack("<HHHH", r[12:20])
                widths.add(w)
                forces.add(f)
                slot14.add(s14)
                slot16.add(s16)
                count += 1
        name = path.rsplit("/", 1)[-1]
        span = f"{min(widths)}-{max(widths)}" if len(widths) > 1 else str(next(iter(widths)))
        print(f"{name:20s} canvas {cw:.0f}x{ch:.0f}  n={count:4d}  width {span:9s}"
              f"  force {min(forces)}-{max(forces)}  [14:16]={sorted(slot14)}  [16:18]={sorted(slot16)}")


if __name__ == "__main__":
    main()
