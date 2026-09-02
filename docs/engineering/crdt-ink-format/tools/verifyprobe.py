#!/usr/bin/env python3
"""Check, from the artifacts, that the probe variants differ only where they are meant to.

Three earlier rounds produced confident wrong readings because a variant changed more than it claimed to. The
claim is cheap to check and the trial is not, so it gets checked before the trial is spent.

  1 and 2 must carry byte-identical payloads -- they differ only in which archive envelope they sit in, which is
    what makes "does one scaffolding set travel between samples" a single-variable question.
  3 must equal 1 with the scaffolding fields removed and nothing else.
  None of them may retain the host sample's geometry.

  python3 verifyprobe.py <samples-dir> <probe-dir>
"""
import glob
import sys

sys.path.insert(0, __file__.rsplit("/", 1)[0])
import mkbisect  # noqa: E402
import mkprobe  # noqa: E402
import pbcodec  # noqa: E402


def payload_of(path):
    return mkbisect.load(path)[2]


def stroke_fields(payload):
    drawing = pbcodec.parse(pbcodec.get(pbcodec.parse(payload), 2)[0])
    stroke = pbcodec.parse(pbcodec.get(drawing, 3)[0])
    points = pbcodec.parse(pbcodec.get(stroke, 5)[0])
    return sorted(f for f, _, _ in stroke), sorted(f for f, _, _ in points)


def main():
    samples, probes = sys.argv[1], sys.argv[2]
    p = {n: payload_of(glob.glob(f"{probes}/probe-p{n}-*.archive")[0]) for n in (1, 2, 3)}
    ok = True

    def check(label, condition, detail=""):
        nonlocal ok
        ok = ok and condition
        print(f"  {'PASS' if condition else 'FAIL'}  {label}{'  ' + detail if detail else ''}")

    print("probe variants")
    check("1 and 2 carry identical payloads", p[1] == p[2],
          f"{len(p[1])} vs {len(p[2])} bytes")

    s1, q1 = stroke_fields(p[1])
    s3, q3 = stroke_fields(p[3])
    check("3 drops exactly the stroke scaffolding",
          [f for f in s1 if f not in mkprobe.STROKE_SCAFFOLD] == s3, f"{s1} -> {s3}")
    check("3 drops exactly the points scaffolding",
          [f for f in q1 if f not in mkprobe.POINTS_SCAFFOLD] == q3, f"{q1} -> {q3}")

    print("\nindependence from the host samples")
    for n in (1, 2, 3):
        host = payload_of(glob.glob(f"{samples}/ppk-p{n}-*.bin")[0])
        _, hq = stroke_fields(host)
        hrec = pbcodec.get(pbcodec.parse(pbcodec.get(
            pbcodec.parse(pbcodec.get(pbcodec.parse(host), 2)[0]), 3)[0]), 5)[0]
        prec = pbcodec.get(pbcodec.parse(pbcodec.get(
            pbcodec.parse(pbcodec.get(pbcodec.parse(p[n]), 2)[0]), 3)[0]), 5)[0]
        check(f"page {n} keeps none of the host's point data",
              pbcodec.get(pbcodec.parse(hrec), 5)[0] not in pbcodec.get(pbcodec.parse(prec), 5)[0],
              f"host {len(pbcodec.get(pbcodec.parse(hrec), 5)[0])}B, probe "
              f"{len(pbcodec.get(pbcodec.parse(prec), 5)[0])}B")

    print("\nround trip")
    for n in (1, 2, 3):
        check(f"page {n} re-serializes byte-identically",
              pbcodec.serialize(pbcodec.parse(p[n])) == p[n])

    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
