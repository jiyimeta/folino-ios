#!/usr/bin/env python3
"""Print the exact bytes of the scaffolding an encoder has to carry verbatim.

These are the fields whose meaning is still unknown. They are not optional — dropping them produced no ink —
and they are not derivable, so production code hardcodes this one set, which is the set that has been accepted
on device. Printing them here is what lets the implementation quote them instead of re-deriving them.

  python3 dumpconstants.py <sample.bin>
"""
import sys

sys.path.insert(0, __file__.rsplit("/", 1)[0])
import mkbisect  # noqa: E402
import mkprobe  # noqa: E402
import pbcodec  # noqa: E402


def show(prefix, fields):
    for f, wt, v in fields:
        body = v if isinstance(v, int) else "0x" + v.hex()
        kind = "varint" if wt == 0 else f"length-delimited, {len(v)} bytes" if wt == 2 else f"wire {wt}"
        print(f"  {prefix}.{f:<3} {kind:28s} {body}")
        if wt == 2:
            for sf, swt, sv in pbcodec.parse(v):
                inner = sv if isinstance(sv, int) else "0x" + sv.hex()
                print(f"        .{sf} (wire {swt}) = {inner}")


def main():
    stroke, points = mkprobe.constants_from(sys.argv[1])
    print("stroke-level scaffolding (.2.3.N)")
    show("2.3", stroke)
    print("\npoints-container scaffolding (.2.3.5.N)")
    show("2.3.5", points)

    archive = mkbisect.load(sys.argv[1])[0]
    scalars = {}
    for o in archive["$objects"]:
        if isinstance(o, dict) and "$class" in o and "drawing" in o:
            scalars = {k: v for k, v in o.items() if not k.startswith("$") and not hasattr(v, "data")}
    print("\narchive scalars carried verbatim")
    for k, v in sorted(scalars.items()):
        print(f"  {k:34s} {v!r}")


if __name__ == "__main__":
    main()
