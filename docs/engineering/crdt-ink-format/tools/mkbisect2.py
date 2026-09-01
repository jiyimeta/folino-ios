#!/usr/bin/env python3
"""Second bisect attempt, with each variant built from the page it will be written back to.

The first attempt derived every variant from page 1's archive and wrote them onto pages 1-6. Each PDF
annotation carries its own /Rect, and pages 2-6 kept their original /Rect while receiving page 1's drawing —
so those five pages disagreed with their own annotation before any of the intended edits mattered. Page 1 was
the only one whose /Rect matched its payload, and it was the only one accepted. That invalidates the earlier
conclusion; nothing was learned about timestamps or UUIDs.

Here variant N is derived from page N's own archive and written back to page N, so /Rect always agrees and the
only difference is the single field under test.

  python3 mkbisect2.py <samples-dir> <outdir>
"""
import glob
import gzip
import plistlib
import sys

sys.path.insert(0, __file__.rsplit("/", 1)[0])
import mkbisect  # noqa: E402


def sample_for(samples_dir, page):
    hits = glob.glob(f"{samples_dir}/ppk-p{page}-*.bin")
    if not hits:
        raise SystemExit(f"no sample archive for page {page}")
    return hits[0]


def main():
    samples_dir, outdir = sys.argv[1], sys.argv[2]
    for page, (name, fn, dx_page) in enumerate(mkbisect.VARIANTS, start=1):
        src = sample_for(samples_dir, page)
        archive, index, raw = mkbisect.load(src)
        edited = fn(raw)
        mkbisect.shift_rect(archive, dx_page)
        out = f"{outdir}/p{page}-{name}.archive"
        mkbisect.save(archive, index, edited, out)

        before = sum(len(mkbisect.records(b)) for _, b in
                     __import__("pbcodec").strokes_of(raw))
        after = sum(len(mkbisect.records(b)) for _, b in
                    __import__("pbcodec").strokes_of(edited))
        changed = sum(1 for a, b in zip(raw, edited) if a != b) + abs(len(raw) - len(edited))
        print(f"page {page}  {name:22s} src={src.rsplit('/', 1)[1]}  "
              f"points {before}->{after}  changed bytes {changed}")


if __name__ == "__main__":
    main()
