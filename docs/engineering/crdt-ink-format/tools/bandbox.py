#!/usr/bin/env python3
"""Locate the yellow highlighter band in each screenshot, relative to the first staff.

Prints the band bbox in pixels, the first five staff-line rows (their spacing calibrates the zoom), and the
band's position in staff-space units so screenshots at different scroll offsets and zooms can be compared.

  python3 bandbox.py <png>...
"""
import sys

from PIL import Image


def main():
    for path in sys.argv[1:]:
        im = Image.open(path).convert("RGB")
        w, h = im.size
        px = im.load()

        xs, ys = [], []
        for y in range(0, h, 2):
            for x in range(0, w, 2):
                r, g, b = px[x, y]
                if r > 235 and 205 < g < 240 and 90 < b < 160 and 15 <= (r - g) <= 45:
                    xs.append(x); ys.append(y)
        if not xs:
            print(f"{path}: no yellow"); continue
        bx0, bx1, by0, by1 = min(xs), max(xs), min(ys), max(ys)

        # staff lines: rows with a run of >= 600 dark px; keep the first five distinct ones
        rows = []
        last = -10
        y = int(h * 0.05)
        while y < h and len(rows) < 5:
            run = 0; best = 0
            for x in range(w):
                r, g, b = px[x, y]
                if r + g + b < 200:
                    run += 1; best = max(best, run)
                else:
                    run = 0
            if best >= 600 and y - last > 3:
                rows.append(y); last = y
            y += 1
        anchor_y = rows[0]
        anchor_x = max(x for x in range(w) if sum(px[x, anchor_y]) < 200)
        spacing = (rows[2] - rows[0]) / 2 if len(rows) > 2 else 1
        print(f"{path.rsplit('/', 1)[-1]}  size {w}x{h}  staff rows {rows}  spacing {spacing:.2f}px  x0={anchor_x}")
        print(f"   band px  x [{bx0}, {bx1}]  y [{by0}, {by1}]   center ({(bx0 + bx1) / 2:.0f}, {(by0 + by1) / 2:.0f})")
        print(f"   band in staff-spacings from (x0, line1): x [{(bx0 - anchor_x) / spacing:.2f}, {(bx1 - anchor_x) / spacing:.2f}]"
              f"  y [{(by0 - anchor_y) / spacing:.2f}, {(by1 - anchor_y) / spacing:.2f}]"
              f"  size {(bx1 - bx0) / spacing:.2f} x {(by1 - by0) / spacing:.2f}")


if __name__ == "__main__":
    main()
