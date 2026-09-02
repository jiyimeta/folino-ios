#!/usr/bin/env python3
"""Recursive protobuf structure dumper for Apple's `crdt` ink container.

No schema: fields are identified by number and wire type, and length-delimited payloads are probed to see
whether they parse cleanly as a nested message. Output is a stable, diffable tree so two samples that differ
by one drawing variable can be compared field path by field path.

usage:
  pbdump.py <file.bin> [--offset N] [--max-depth D] [--summary]

`--summary` prints one line per field path (path, occurrences, total bytes) instead of the full tree, which is
what you want when diffing two samples.
"""
import sys
import collections

MAX_STR = 60


def varint(b, i):
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
            return None, i
    return None, i


def parse(b, start=0, end=None):
    """Yield (field, wire_type, value_bytes_or_int, next_offset) or raise ValueError on malformed input."""
    if end is None:
        end = len(b)
    i = start
    out = []
    while i < end:
        tag, j = varint(b, i)
        if tag is None:
            raise ValueError("bad tag varint")
        field, wt = tag >> 3, tag & 7
        if field == 0:
            raise ValueError("field 0")
        if wt == 0:
            v, j = varint(b, j)
            if v is None:
                raise ValueError("bad varint")
            out.append((field, wt, v))
            i = j
        elif wt == 1:
            if j + 8 > end:
                raise ValueError("fixed64 overrun")
            out.append((field, wt, b[j:j + 8]))
            i = j + 8
        elif wt == 2:
            ln, j = varint(b, j)
            if ln is None or j + ln > end:
                raise ValueError("len overrun")
            out.append((field, wt, b[j:j + ln]))
            i = j + ln
        elif wt == 5:
            if j + 4 > end:
                raise ValueError("fixed32 overrun")
            out.append((field, wt, b[j:j + 4]))
            i = j + 4
        else:
            raise ValueError(f"wire type {wt}")
    return out


def looks_like_message(payload):
    if len(payload) < 2:
        return False
    try:
        fields = parse(payload)
    except ValueError:
        return False
    return len(fields) > 0


def printable(payload):
    try:
        s = payload.decode("utf-8")
    except UnicodeDecodeError:
        return None
    return s if s.isprintable() and len(s) > 0 else None


def describe(payload):
    s = printable(payload)
    if s is not None:
        return f'"{s[:MAX_STR]}"' + ("…" if len(s) > MAX_STR else "")
    head = payload[:16].hex(" ")
    return f"bytes({len(payload)}) {head}" + ("…" if len(payload) > 16 else "")


def walk(payload, depth, max_depth, path, lines, summary):
    try:
        fields = parse(payload)
    except ValueError:
        return False
    for field, wt, val in fields:
        p = f"{path}.{field}"
        if wt == 0:
            summary[p + ":varint"][0] += 1
            lines.append(f"{'  ' * depth}{p} varint = {val}")
        elif wt in (1, 5):
            kind = "fixed64" if wt == 1 else "fixed32"
            summary[f"{p}:{kind}"][0] += 1
            summary[f"{p}:{kind}"][1] += len(val)
            lines.append(f"{'  ' * depth}{p} {kind} = {val.hex(' ')}")
        else:
            summary[p + ":bytes"][0] += 1
            summary[p + ":bytes"][1] += len(val)
            if depth < max_depth and looks_like_message(val):
                lines.append(f"{'  ' * depth}{p} message ({len(val)} bytes)")
                if not walk(val, depth + 1, max_depth, p, lines, summary):
                    lines.append(f"{'  ' * (depth + 1)}(unparsable, {describe(val)})")
            else:
                lines.append(f"{'  ' * depth}{p} = {describe(val)}")
    return True


def main():
    args = [a for a in sys.argv[1:]]
    path = args[0]
    offset = 8
    max_depth = 6
    summary_only = "--summary" in args
    if "--offset" in args:
        offset = int(args[args.index("--offset") + 1])
    if "--max-depth" in args:
        max_depth = int(args[args.index("--max-depth") + 1])

    data = open(path, "rb").read()
    print(f"# {path}  size={len(data)}  magic={data[:4]!r}  header={data[4:offset].hex(' ')}")

    lines = []
    summary = collections.defaultdict(lambda: [0, 0])
    if not walk(data[offset:], 0, max_depth, "", lines, summary):
        print("payload did not parse as protobuf at that offset")
        return
    if summary_only:
        for k in sorted(summary):
            n, size = summary[k]
            print(f"{k:50s} n={n:<6d} bytes={size}")
    else:
        print("\n".join(lines))


if __name__ == "__main__":
    main()
