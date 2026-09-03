#!/usr/bin/env python3
"""Write the gunzipped protobuf drawing payload out of an AKAnnotationV2 archive.

  python3 extractraw.py <archive.bin> <out.raw>
"""
import sys

TOOLS = "/Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/crdt-ink-format/docs/engineering/crdt-ink-format/tools"
sys.path.insert(0, TOOLS)
import mkbisect  # noqa: E402

archive, index, raw = mkbisect.load(sys.argv[1])
open(sys.argv[2], "wb").write(raw)
print(f"wrote {len(raw)} bytes (object index {index})")
