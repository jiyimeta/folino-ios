#!/usr/bin/env python3
"""Thickness of the red pen stroke in a screenshot or render: per-column max vertical run of red pixels.

The red mark is a closed loop, so columns through its middle cross the top and bottom arcs where the run
length is about the stroke thickness; the minimum / low percentiles across columns estimate it.

  python3 redwidth.py <png> <px_per_pt>
"""
import sys

from PIL import Image

path, scale = sys.argv[1], float(sys.argv[2])
im = Image.open(path).convert("RGB")
w, h = im.size
px = im.load()


def red(x, y):
    r, g, b = px[x, y]
    return r > 170 and g < 120 and b < 110 and (r - g) > 90


runs = []
for x in range(0, w):
    best = cur = 0
    any_red = False
    for y in range(0, h):
        if red(x, y):
            cur += 1; best = max(best, cur); any_red = True
        else:
            cur = 0
    if any_red:
        runs.append(best / scale)
runs.sort()
n = len(runs)
print(f"{path.rsplit('/', 1)[-1]}: {n} columns with red;"
      f" run pt min {runs[0]:.2f} p5 {runs[n // 20]:.2f} p10 {runs[n // 10]:.2f} p25 {runs[n // 4]:.2f} median {runs[n // 2]:.2f}")
