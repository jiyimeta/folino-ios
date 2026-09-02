#!/usr/bin/env python3
"""Walk a `crdt` container's stroke bodies (.4[*].4.10.1.2) and print their point layout in full.

  python3 crdtpoints.py <ppk.bin>
"""
import struct
import sys

TOOLS = "/Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/crdt-ink-format/docs/engineering/crdt-ink-format/tools"
sys.path.insert(0, TOOLS)
import pbcodec  # noqa: E402


def hexs(b):
    return " ".join(f"{x:02x}" for x in b)


def main():
    raw = open(sys.argv[1], "rb").read()[8:]
    top = pbcodec.parse(raw)
    n = 0
    for f4 in pbcodec.get(top, 4):
        for f44 in pbcodec.get(pbcodec.parse(f4), 4):
            for f10 in pbcodec.get(pbcodec.parse(f44), 10):
                for f1 in pbcodec.get(pbcodec.parse(f10), 1):
                    for body in pbcodec.get(pbcodec.parse(f1), 2):
                        n += 1
                        fields = pbcodec.parse(body)
                        d = {}
                        for fld, _, v in fields:
                            d.setdefault(fld, []).append(v)
                        count = d.get(3, [None])[0]
                        f4v = d.get(4, [None])[0]
                        f5v = d.get(5, [None])[0]
                        const = d.get(6, [b""])[0]
                        pts = d.get(7, [b""])[0]
                        f8 = d.get(8, [None])[0]
                        f9 = d.get(9, [None])[0]
                        ts = struct.unpack("<d", d[2][0])[0] if 2 in d else None
                        rec = len(pts) // count if count else 0
                        print(f"stroke {n}: count={count} .4={f4v} (0x{f4v:x}) .5={f5v} (0x{f5v:x}) .8={f8} .9={f9} ts={ts}")
                        print(f"  .6 const ({len(const)} bytes): {hexs(const)}")
                        if len(const) >= 4:
                            print(f"     as float32 head: {struct.unpack('<f', const[:4])[0]:.4f}"
                                  f"  then u16s: {[struct.unpack('<H', const[i:i+2])[0] for i in range(4, len(const) - 1, 2)]}")
                        print(f"  .7 points {len(pts)} bytes, {rec} bytes/record")
                        for i in list(range(0, min(4, count))) + list(range(max(4, count - 2), count)):
                            r = pts[i * rec:(i + 1) * rec]
                            floats = [struct.unpack("<f", r[j:j+4])[0] for j in range(0, (rec // 4) * 4, 4)]
                            tail = r[(rec // 4) * 4:]
                            print(f"     [{i:3d}] {hexs(r)}   floats={['%.4f' % x for x in floats]}"
                                  f" tail_u16={[struct.unpack('<H', tail[j:j+2])[0] for j in range(0, len(tail) - 1, 2)]}")


if __name__ == "__main__":
    main()
