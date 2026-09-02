#!/usr/bin/env python3
"""Set originalModelBaseScaleFactor in an AKAnnotationV2 archive.

  python3 setscale.py <in.bin> <out.bin> <value>
"""
import plistlib
import sys

src, out, value = sys.argv[1], sys.argv[2], float(sys.argv[3])
archive = plistlib.load(open(src, "rb"))
root = archive["$objects"][1]
print(f"originalModelBaseScaleFactor {root['originalModelBaseScaleFactor']} -> {value}")
root["originalModelBaseScaleFactor"] = value
open(out, "wb").write(plistlib.dumps(archive, fmt=plistlib.FMT_BINARY))
print(f"wrote {out}")
