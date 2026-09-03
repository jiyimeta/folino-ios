#!/usr/bin/env python3
"""Print the NSKeyedArchiver object graph around the drawing, with the drawing itself elided.

The payload is the interesting part of this format and the envelope is the boring part, which is exactly why
the envelope needs writing down: an encoder has to reproduce it exactly, and `plutil -p` drowns it in a
kilobyte of gzipped drawing.

  python3 dumparchive.py <sample.bin>
"""
import plistlib
import sys


def render(objs, index, depth, seen):
    pad = "  " * depth
    if index in seen:
        return f"{pad}<cycle -> #{index}>"
    o = objs[index]
    if isinstance(o, plistlib.UID):
        return render(objs, o.data, depth, seen)
    if isinstance(o, bytes):
        kind = "gzip drawing" if o[:3] == b"\x1f\x8b\x08" else "data"
        return f"{pad}#{index} <{kind}, {len(o)} bytes>"
    if isinstance(o, dict):
        lines = [f"{pad}#{index} dict"]
        seen = seen | {index}
        if "NS.keys" in o:
            keys = [objs[u.data] for u in o["NS.keys"]]
            for key, value in zip(keys, o["NS.objects"]):
                lines.append(f"{pad}  {key}:")
                lines.append(render(objs, value.data, depth + 2, seen))
            if "$class" in o:
                lines.append(render(objs, o["$class"].data, depth + 1, seen))
            return "\n".join(lines)
        for key, value in o.items():
            if isinstance(value, plistlib.UID):
                lines.append(f"{pad}  {key}:")
                lines.append(render(objs, value.data, depth + 2, seen))
            elif isinstance(value, list) and value and isinstance(value[0], plistlib.UID):
                lines.append(f"{pad}  {key}: [{', '.join('#' + str(u.data) for u in value)}]")
            else:
                lines.append(f"{pad}  {key}: {value!r}")
        return "\n".join(lines)
    return f"{pad}#{index} {o!r}"


def main():
    archive = plistlib.load(open(sys.argv[1], "rb"))
    objs = archive["$objects"]
    print(f"$version {archive.get('$version')}  $archiver {archive.get('$archiver')}")
    print(f"$objects: {len(objs)} entries\n")
    print(render(objs, archive["$top"]["root"].data, 0, frozenset()))


if __name__ == "__main__":
    main()
