#!/usr/bin/env python3
"""Regenerate the iOS/Android parity ledger from the markers left in the source.

A feature that ships on one platform ahead of the other is recorded where it
diverges, not in a hand-maintained list — a list nobody has a reason to open
goes stale, while a comment sits in the diff of whoever touches that code next,
and deleting it is the natural last step of implementing the other half.

    // PARITY(android): measure-number policy — add the interval to
    //   LayoutOptionsWire and a Compose toggle

Format: `PARITY(<platform>): <title> — <what the other platform still needs>`.
The separator is an em dash; ` -- ` works too. A continuation line repeats the
comment marker and indents (`//   …` / `///   …`), and is joined onto the
previous one. `<platform>` is the platform the work is still OWED to, so an
iOS-only feature is `PARITY(android)`.

Usage:
    Scripts/parity-report.py            # rewrite the generated block
    Scripts/parity-report.py --check    # rewrite, and fail if it changed

`--check` is what the pre-commit hook runs: it writes the fix to disk and exits
non-zero, the same shape as the SwiftFormat hook, so a commit that adds or
removes a marker cannot land without the ledger moving with it.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LEDGER = ROOT / "docs/engineering/ios-android-parity.md"

# Only source files carry markers. Keeping Markdown out of the scan is also what
# lets this script, CLAUDE.md and the ledger itself spell the marker out.
SUFFIXES = {".swift", ".kt", ".kts"}
SCAN_ROOTS = ("Packages", "App", "Android")
EXCLUDED_DIRS = {
    ".build", "build", "DerivedData", ".git", "Pods", ".claude",
    "generated", "java-generated", "xcuserdata",
}

PLATFORMS = ("android", "ios")

MARKER = re.compile(r"PARITY\((?P<platform>android|ios)\):\s*(?P<body>.*?)\s*$")
# A continuation is a comment line with no marker of its own, indented past the
# comment token: `//   …`. Anything else ends the entry.
CONTINUATION = re.compile(r"^\s*(?://+|///|\*)\s{2,}(?P<body>\S.*?)\s*$")
SEPARATOR = re.compile(r"\s+(?:—|--)\s+")

BEGIN = "<!-- generated:parity — written by Scripts/parity-report.py; do not edit by hand -->"
END = "<!-- /generated:parity -->"


class Entry:
    def __init__(self, platform: str, path: Path, line: int, body: str) -> None:
        self.platform = platform
        self.path = path.relative_to(ROOT).as_posix()
        self.line = line
        self.body = body

    def split(self) -> tuple[str, str]:
        parts = SEPARATOR.split(self.body, maxsplit=1)
        if len(parts) == 2:
            return parts[0], parts[1]
        return self.body, "—"

    @property
    def sort_key(self) -> tuple[str, int]:
        return (self.path, self.line)


def source_files() -> list[Path]:
    files: list[Path] = []
    for name in SCAN_ROOTS:
        root = ROOT / name
        if not root.is_dir():
            continue
        for path in root.rglob("*"):
            if path.suffix not in SUFFIXES:
                continue
            if EXCLUDED_DIRS & set(path.relative_to(ROOT).parts):
                continue
            files.append(path)
    return files


def scan() -> list[Entry]:
    entries: list[Entry] = []
    for path in source_files():
        try:
            lines = path.read_text(encoding="utf-8").splitlines()
        except UnicodeDecodeError:
            continue
        current: Entry | None = None
        for number, text in enumerate(lines, start=1):
            match = MARKER.search(text)
            if match:
                current = Entry(match["platform"], path, number, match["body"])
                entries.append(current)
                continue
            if current is not None:
                continuation = CONTINUATION.match(text)
                if continuation:
                    current.body = f"{current.body} {continuation['body']}"
                    continue
                current = None
    return entries


def escape(text: str) -> str:
    return text.replace("|", "\\|")


def table(entries: list[Entry], platform: str) -> list[str]:
    rows = sorted((e for e in entries if e.platform == platform), key=lambda e: e.sort_key)
    other = "iOS" if platform == "ios" else "Android"
    if not rows:
        return [f"Nothing is currently owed to {other}.", ""]
    out = [
        f"| Item | Where it diverges | What {other} still needs |",
        "| --- | --- | --- |",
    ]
    for row in rows:
        title, work = row.split()
        out.append(f"| {escape(title)} | `{row.path}:{row.line}` | {escape(work)} |")
    out.append("")
    return out


def block(entries: list[Entry]) -> str:
    out = [BEGIN, ""]
    for platform in PLATFORMS:
        out.append(f"### Owed to {'Android' if platform == 'android' else 'iOS'}")
        out.append("")
        out.extend(table(entries, platform))
    out.append(END)
    return "\n".join(out)


def main() -> int:
    check = "--check" in sys.argv[1:]
    if not LEDGER.exists():
        print(f"missing ledger: {LEDGER.relative_to(ROOT)}", file=sys.stderr)
        return 2

    original = LEDGER.read_text(encoding="utf-8")
    pattern = re.compile(
        re.escape(BEGIN) + r".*?" + re.escape(END), re.DOTALL
    )
    if not pattern.search(original):
        print(
            f"{LEDGER.relative_to(ROOT)} has no generated block "
            f"({BEGIN} … {END})",
            file=sys.stderr,
        )
        return 2

    updated = pattern.sub(lambda _: block(scan()), original, count=1)
    if updated == original:
        return 0

    LEDGER.write_text(updated, encoding="utf-8")
    if check:
        print(
            f"{LEDGER.relative_to(ROOT)} was out of date and has been rewritten "
            "— stage it and commit again.",
            file=sys.stderr,
        )
        return 1
    print(f"rewrote {LEDGER.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
