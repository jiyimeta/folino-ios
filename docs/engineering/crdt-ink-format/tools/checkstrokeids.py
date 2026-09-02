#!/usr/bin/env python3
"""What are the stroke's two `.2` fields, actually?

The notes call them "two distinct 16-byte identifiers", and an encoder was written on that reading. This
prints both, per sample, so the claim can be checked rather than repeated.

  python3 checkstrokeids.py <samples-dir>
"""
import glob
import sys

sys.path.insert(0, __file__.rsplit("/", 1)[0])
import mkbisect  # noqa: E402
import pbcodec  # noqa: E402


def main():
    first_seen, second_seen = set(), set()
    for path in sorted(glob.glob(f"{sys.argv[1]}/ppk-p*.bin")):
        raw = mkbisect.load(path)[2]
        for drawing in pbcodec.get(pbcodec.parse(raw), 2):
            for stroke in pbcodec.get(pbcodec.parse(drawing), 3):
                twos = pbcodec.get(pbcodec.parse(stroke), 2)
                name = path.rsplit("/", 1)[-1]
                print(f"{name:20s} " + "  ".join(
                    f"#{i + 1} {v.hex()}" + (" (all zero)" if v == bytes(16) else "")
                    for i, v in enumerate(twos)))
                if twos:
                    first_seen.add(twos[0])
                if len(twos) > 1:
                    second_seen.add(twos[1])

    print(f"\ndistinct first values:  {len(first_seen)}")
    print(f"distinct second values: {len(second_seen)}")
    if len(first_seen) == 1:
        print("-> the first `.2` is the SAME on every sample, so it is not per-stroke identity")


if __name__ == "__main__":
    main()
