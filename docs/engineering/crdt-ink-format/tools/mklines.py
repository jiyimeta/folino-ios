#!/usr/bin/env python3
"""Write one CSV per size: a straight horizontal red pen stroke, for calibrating PencilKit's size -> width curve.

  python3 mklines.py <outdir> <size>...
"""
import sys

outdir = sys.argv[1]
for s in sys.argv[2:]:
    size = float(s)
    lines = ["com.apple.ink.pen,1.0,0.0,0.0,1.0"]
    for i in range(0, 201):
        lines.append(f"{100 + i},100,{i * 0.005},{size},0")
    path = f"{outdir}/line-{s}.csv"
    open(path, "w").write("\n".join(lines) + "\n")
    print(path)
