#!/usr/bin/env python3
"""Horizontal red bands in an image, top to bottom: centre y and thickness (in points at the given scale).

Scans the middle third of the width; a row belongs to a band when at least half of its sampled pixels are red.
  python3 bands.py <png> <px_per_pt>
"""
import sys

from PIL import Image

path, scale = sys.argv[1], float(sys.argv[2])
im = Image.open(path).convert("RGBA")
w, h = im.size
px = im.load()
import os
xs = list(range(int(os.environ.get("X0", w // 3)), int(os.environ.get("X1", 2 * w // 3)), 4))
bands = []
start = None
for y in range(h):
    red = 0
    for x in xs:
        r, g, b, a = px[x, y]
        if a > 30 and r > 150 and g < 200 and b < 200 and (r - g) > 40:
            red += 1
    on = red >= len(xs) // 2
    if on and start is None:
        start = y
    if not on and start is not None:
        bands.append((start, y))
        start = None
if start is not None:
    bands.append((start, h))
print(f"{path.rsplit('/', 1)[-1]}: {w}x{h}, {len(bands)} bands")
for s, e in bands:
    print(f"  centre y {((s + e) / 2) / scale:7.2f} pt  thickness {(e - s) / scale:6.2f} pt")
