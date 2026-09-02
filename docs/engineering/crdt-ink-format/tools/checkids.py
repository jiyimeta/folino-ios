#!/usr/bin/env python3
"""No two variants in a round may share an identifier.

AnnotationKit names a drawing by the identifiers inside its payload, so two annotations carrying the same ones
are one drawing: an edit to either lands on whichever the markup resolves first, across pages and across
subtypes. That makes a shared identifier not a small blemish on a test but a guarantee it will answer the wrong
question -- one round put three of four variants on the same drawing and measured nothing at all.

It is also the production rule. folino writes many marks per page, and every one of them needs its own.

  python3 checkids.py <dir-of-archives>
"""
import glob
import sys

sys.path.insert(0, __file__.rsplit("/", 1)[0])
import mkbisect  # noqa: E402
import pbcodec  # noqa: E402


def identifiers(payload):
    """The five 16-byte identifiers: two on the stroke, one beside it, two in the points container."""
    drawing = pbcodec.parse(pbcodec.get(pbcodec.parse(payload), 2)[0])
    stroke = pbcodec.parse(pbcodec.get(drawing, 3)[0])
    points = pbcodec.parse(pbcodec.get(stroke, 5)[0])
    return ([v for f, _, v in stroke if f in (2, 9) and len(v) == 16]
            + [v for f, _, v in points if f in (13, 14) and len(v) == 16])


def main():
    paths = sorted(glob.glob(f"{sys.argv[1]}/*.archive"))
    owners = {}
    clashes = []
    for path in paths:
        name = path.rsplit("/", 1)[-1]
        ids = identifiers(mkbisect.load(path)[2])
        print(f"  {name:40s} {len(ids)} identifiers")
        for i in ids:
            if i in owners and owners[i] != name:
                clashes.append((owners[i], name, i.hex()[:12]))
            owners[i] = name

    print()
    if clashes:
        for a, b, h in clashes:
            print(f"  CLASH  {a}  and  {b}  share {h}...")
        print(f"\n{len(clashes)} shared identifier(s): these variants are ONE drawing to the markup.")
        sys.exit(1)
    print(f"OK: {len(owners)} identifiers across {len(paths)} variants, all distinct.")


if __name__ == "__main__":
    main()
