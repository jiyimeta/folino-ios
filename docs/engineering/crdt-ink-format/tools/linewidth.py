#!/usr/bin/env python3
"""Vertical run length of red pixels in the middle third of a rendered horizontal line: the line's thickness.

  python3 linewidth.py <px_per_unit> <png>...
"""
import sys

from PIL import Image

scale = float(sys.argv[1])
for path in sys.argv[2:]:
    im = Image.open(path).convert("RGB")
    w, h = im.size
    px = im.load()
    runs = []
    for x in range(w // 3, 2 * w // 3):
        best = cur = 0
        for y in range(h):
            r, g, b = px[x, y]
            if r > 170 and g < 120 and b < 110:
                cur += 1; best = max(best, cur)
            else:
                cur = 0
        runs.append(best / scale)
    runs.sort()
    print(f"{path.rsplit('/', 1)[-1]}: thickness min {runs[0]:.3f} median {runs[len(runs) // 2]:.3f} max {runs[-1]:.3f}")
