#!/usr/bin/env python3
"""Faithful protobuf parse/serialize round trip, plus the AKAnnotationV2 envelope.

The point of this module is the self-check: parsing Apple's payload and writing it back must reproduce the
original bytes exactly. Until that holds there is no basis for changing anything inside it, because any
difference on device would be ambiguous between "our writer is wrong" and "our edit is wrong".

Nothing here interprets the schema. Fields are kept in their original order, and length-delimited payloads are
kept as opaque bytes unless a caller asks to descend into one.

  python3 pbcodec.py selfcheck <file.bin> [...]      round trip each file and report byte equality
  python3 pbcodec.py points <file.bin>               dump the 24-byte point records of every stroke
"""
import sys


def read_varint(b, i):
    r = 0
    s = 0
    while i < len(b):
        x = b[i]
        r |= (x & 0x7F) << s
        i += 1
        s += 7
        if not x & 0x80:
            return r, i
        if s > 70:
            raise ValueError("varint too long")
    raise ValueError("truncated varint")


def write_varint(v):
    out = bytearray()
    while True:
        x = v & 0x7F
        v >>= 7
        if v:
            out.append(x | 0x80)
        else:
            out.append(x)
            return bytes(out)


def parse(b):
    """-> [(field, wire_type, value)] where value is int for varint, bytes otherwise. Order preserved."""
    out = []
    i = 0
    while i < len(b):
        tag, i = read_varint(b, i)
        field, wt = tag >> 3, tag & 7
        if field == 0:
            raise ValueError("field number 0")
        if wt == 0:
            v, i = read_varint(b, i)
            out.append((field, wt, v))
        elif wt == 1:
            out.append((field, wt, b[i:i + 8]))
            i += 8
        elif wt == 2:
            ln, i = read_varint(b, i)
            if i + ln > len(b):
                raise ValueError("length-delimited overrun")
            out.append((field, wt, b[i:i + ln]))
            i += ln
        elif wt == 5:
            out.append((field, wt, b[i:i + 4]))
            i += 4
        else:
            raise ValueError(f"unsupported wire type {wt}")
    return out


def serialize(fields):
    out = bytearray()
    for field, wt, val in fields:
        out += write_varint((field << 3) | wt)
        if wt == 0:
            out += write_varint(val)
        elif wt == 2:
            out += write_varint(len(val))
            out += val
        else:
            out += val
    return bytes(out)


def get(fields, number):
    """All values for a field number, in order."""
    return [v for f, _, v in fields if f == number]


def replace(fields, number, index, new_value):
    """Return a copy with the index-th occurrence of `number` replaced."""
    out = []
    seen = 0
    for f, wt, v in fields:
        if f == number:
            if seen == index:
                out.append((f, wt, new_value))
                seen += 1
                continue
            seen += 1
        out.append((f, wt, v))
    return out


# --- the drawing payload, as far as it has been decoded -------------------------------------------------
# .2 -> .3 (the stroke container) -> .5 (stroke body) -> .4 point count, .5 point records of 24 bytes.

POINT_SIZE = 24


def strokes_of(payload):
    """Yield (path, stroke_body_fields) for each stroke in a drawing payload."""
    top = parse(payload)
    for i, drawing in enumerate(get(top, 2)):
        d = parse(drawing)
        for j, stroke in enumerate(get(d, 3)):
            s = parse(stroke)
            for k, body in enumerate(get(s, 5)):
                yield (i, j, k), parse(body)


def selfcheck(paths):
    ok = True
    for p in paths:
        raw = open(p, "rb").read()
        try:
            again = serialize(parse(raw))
        except ValueError as e:
            print(f"{p}: PARSE FAILED — {e}")
            ok = False
            continue
        same = again == raw
        print(f"{p}: {'identical' if same else 'DIFFERS'} ({len(raw)} bytes)")
        if not same:
            ok = False
            for i, (a, b) in enumerate(zip(raw, again)):
                if a != b:
                    print(f"   first difference at byte {i}: {a:#04x} vs {b:#04x}")
                    break
    return ok


def dump_points(path):
    import struct
    raw = open(path, "rb").read()
    for where, body in strokes_of(raw):
        count = get(body, 4)
        pts = get(body, 5)
        if not pts:
            continue
        data = pts[0]
        n = count[0] if count else len(data) // POINT_SIZE
        print(f"stroke {where}: count={n} payload={len(data)} ({len(data) / POINT_SIZE:.2f} records)")
        for k in range(min(n, 3)):
            r = data[k * POINT_SIZE:(k + 1) * POINT_SIZE]
            t, x, y = struct.unpack("<fff", r[0:12])
            u = struct.unpack("<HHHHHH", r[12:24])
            print(f"   t={t:.4f} x={x:.2f} y={y:.2f} width={u[0]} {u[1]} {u[2]} force={u[3]} {u[4]:#06x} {u[5]:#06x}")


if __name__ == "__main__":
    cmd = sys.argv[1]
    if cmd == "selfcheck":
        sys.exit(0 if selfcheck(sys.argv[2:]) else 1)
    elif cmd == "points":
        dump_points(sys.argv[2])
    else:
        print(__doc__)
        sys.exit(2)
