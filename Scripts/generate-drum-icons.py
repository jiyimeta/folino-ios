#!/usr/bin/env python3
"""Regenerate the drum pad's icon data from Scripts/drum-icons.json.

The drawings are authored visually in pen.dev. `drum-icons.json` is the plain-text copy of what that file holds —
one view box and one or two SVG paths per instrument — and this script turns it into the generated half of
`Packages/Features/Editor/Sources/Editor/Views/DrumInstrumentIcon.swift`, between its DRUM-ICON-DATA markers. The
hand-written half of that file (the view, the path parser) is left alone.

Arcs are converted to cubic Béziers here rather than in Swift: the app then needs no arc maths, and the conversion
is checked once, offline, instead of on every launch.

    Scripts/generate-drum-icons.py            # rewrite the Swift file in place
    Scripts/generate-drum-icons.py --check    # exit 1 if the Swift file is out of date
"""
import argparse
import json
import math
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
SOURCE = ROOT / "Scripts" / "drum-icons.json"
TARGET = ROOT / "Packages/Features/Editor/Sources/Editor/Views/DrumInstrumentIcon.swift"
BEGIN = "// DRUM-ICON-DATA:BEGIN"
END = "// DRUM-ICON-DATA:END"

TOKEN = re.compile(r"([MmLlHhVvCcSsQqTtAaZz])|(-?\d*\.?\d+(?:[eE][-+]?\d+)?)")


# MARK: - SVG normalization


def arc_to_cubics(x1, y1, rx, ry, phi_deg, fa, fs, x2, y2):
    """An endpoint-parameterized elliptical arc as a list of cubic segments, ≤90° each."""
    if rx == 0 or ry == 0 or (x1 == x2 and y1 == y2):
        return [((x1, y1), (x2, y2), (x2, y2))]
    phi = math.radians(phi_deg)
    cos_phi, sin_phi = math.cos(phi), math.sin(phi)
    dx, dy = (x1 - x2) / 2, (y1 - y2) / 2
    x1p, y1p = cos_phi * dx + sin_phi * dy, -sin_phi * dx + cos_phi * dy
    rx, ry = abs(rx), abs(ry)
    oversize = x1p**2 / rx**2 + y1p**2 / ry**2
    if oversize > 1:
        scale = math.sqrt(oversize)
        rx, ry = rx * scale, ry * scale
    numerator = rx**2 * ry**2 - rx**2 * y1p**2 - ry**2 * x1p**2
    denominator = rx**2 * y1p**2 + ry**2 * x1p**2
    factor = math.sqrt(max(0.0, numerator / denominator))
    if fa == fs:
        factor = -factor
    cxp, cyp = factor * rx * y1p / ry, -factor * ry * x1p / rx
    cx = cos_phi * cxp - sin_phi * cyp + (x1 + x2) / 2
    cy = sin_phi * cxp + cos_phi * cyp + (y1 + y2) / 2

    def angle(ux, uy, vx, vy):
        sign = -1.0 if ux * vy - uy * vx < 0 else 1.0
        cosine = (ux * vx + uy * vy) / (math.hypot(ux, uy) * math.hypot(vx, vy))
        return sign * math.acos(max(-1.0, min(1.0, cosine)))

    start = angle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
    sweep = angle((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry)
    if not fs and sweep > 0:
        sweep -= 2 * math.pi
    if fs and sweep < 0:
        sweep += 2 * math.pi

    count = max(1, math.ceil(abs(sweep) / (math.pi / 2)))
    step = sweep / count
    alpha = 4 / 3 * math.tan(step / 4)
    segments = []
    theta, px, py = start, x1, y1
    for _ in range(count):
        nxt = theta + step

        def at(angle_):
            cos_a, sin_a = math.cos(angle_), math.sin(angle_)
            return (cx + rx * cos_phi * cos_a - ry * sin_phi * sin_a,
                    cy + rx * sin_phi * cos_a + ry * cos_phi * sin_a)

        def slope(angle_):
            cos_a, sin_a = math.cos(angle_), math.sin(angle_)
            return (-rx * cos_phi * sin_a - ry * sin_phi * cos_a,
                    -rx * sin_phi * sin_a + ry * cos_phi * cos_a)

        ex, ey = at(nxt)
        d1x, d1y = slope(theta)
        d2x, d2y = slope(nxt)
        segments.append(((px + alpha * d1x, py + alpha * d1y), (ex - alpha * d2x, ey - alpha * d2y), (ex, ey)))
        px, py, theta = ex, ey, nxt
    return segments


def normalize(data):
    """One SVG path as absolute M / L / C / Z only."""
    tokens = [match.group(0) for match in TOKEN.finditer(data)]
    index = 0
    cx = cy = sx = sy = 0.0
    command = ""
    previous_control = None
    out = []

    def number():
        nonlocal index
        value = float(tokens[index])
        index += 1
        return value

    def fmt(value):
        return f"{round(value, 2):g}"

    while index < len(tokens):
        if tokens[index][0].isalpha():
            command = tokens[index]
            index += 1
        relative = command.islower()
        kind = command.upper()

        if kind == "Z":
            out.append("Z")
            cx, cy, previous_control = sx, sy, None
            continue
        if kind == "M":
            x, y = number(), number()
            if relative:
                x, y = x + cx, y + cy
            cx, cy, sx, sy, previous_control = x, y, x, y, None
            out.append(f"M{fmt(x)} {fmt(y)}")
            command = "l" if relative else "L"
            continue
        if kind == "L":
            x, y = number(), number()
            if relative:
                x, y = x + cx, y + cy
        elif kind == "H":
            x, y = number() + (cx if relative else 0), cy
        elif kind == "V":
            x, y = cx, number() + (cy if relative else 0)
        elif kind in ("C", "S"):
            if kind == "C":
                c1x, c1y = number(), number()
                if relative:
                    c1x, c1y = c1x + cx, c1y + cy
            else:
                c1x, c1y = (2 * cx - previous_control[0], 2 * cy - previous_control[1]) if previous_control else (cx, cy)
            c2x, c2y = number(), number()
            x, y = number(), number()
            if relative:
                c2x, c2y, x, y = c2x + cx, c2y + cy, x + cx, y + cy
            out.append(f"C{fmt(c1x)} {fmt(c1y)} {fmt(c2x)} {fmt(c2y)} {fmt(x)} {fmt(y)}")
            cx, cy, previous_control = x, y, (c2x, c2y)
            continue
        elif kind == "A":
            rx, ry, phi, fa, fs = (number() for _ in range(5))
            x, y = number(), number()
            if relative:
                x, y = x + cx, y + cy
            for (c1x, c1y), (c2x, c2y), (ex, ey) in arc_to_cubics(cx, cy, rx, ry, phi, int(fa), int(fs), x, y):
                out.append(f"C{fmt(c1x)} {fmt(c1y)} {fmt(c2x)} {fmt(c2y)} {fmt(ex)} {fmt(ey)}")
            cx, cy, previous_control = x, y, None
            continue
        else:
            raise SystemExit(f"unsupported path command {command!r}")
        out.append(f"L{fmt(x)} {fmt(y)}")
        cx, cy, previous_control = x, y, None
    return "".join(out)


# MARK: - Swift emission


def swift(icons):
    order = [name for name in icons if not name.startswith("_")]
    lines = [
        BEGIN + " — everything to the END marker is generated by Scripts/generate-drum-icons.py from",
        "// Scripts/drum-icons.json. Edit the drawings there (or in pen.dev and then there), never here.",
        "//",
        "// The path data is normalized to absolute move / line / cubic / close, so nothing below has to do arc maths.",
        "",
        "/// One drum-kit instrument drawn the way the instrument actually looks, for the note-entry pad's key faces.",
        "///",
        "/// Deliberately not SMuFL: the percussion pictograms in Bravura are notation symbols meant to sit above a staff",
        "/// beside a written instrument name — a tom-tom is a plain square, a suspended cymbal a horizontal line — and at a",
        "/// 44 pt key they carry no information. These are drawn from the hardware instead: counterhoop, head, lugs, legs,",
        "/// stand, pedal, cymbal bell.",
        "///",
        "/// Cymbals are told apart by size and tilt rather than by a label: the ride is flat and largest, and the two",
        "/// crashes are mirror images so the tilt says which side of the kit the cymbal is on. Toms are told apart by the",
        "/// letter on the shell, which `EditorDrumPadRows` supplies only when the pad actually holds more than one of that",
        "/// kind (`labelAnchor`).",
        "enum DrumInstrumentIcon: CaseIterable, Sendable {",
    ]
    lines += [f"    case {name}" for name in order]

    lines += [
        "",
        "    /// The icon for a GM drum pitch, or `nil` for one nothing is drawn for — the pad falls back to the notehead",
        "    /// glyph and short name there, which is what a user-edited layout holding a tambourine or a bongo gets.",
        "    static func forPitch(_ pitch: Int) -> DrumInstrumentIcon? {",
        "        switch pitch {",
    ]
    pitches = sorted((pitch, name) for name in order for pitch in icons[name].get("pitches", []))
    lines += [f"        case {pitch}: .{name}" for pitch, name in pitches]
    lines += ["        default: nil", "        }", "    }", ""]

    lines += [
        "    /// The design-space rectangle the path data is drawn in. Each icon has its own, chosen so the drawing sits",
        "    /// centred and fills its key by the amount its real-world size deserves — the ride fills 96% of the frame, a",
        "    /// crash 82% of that, a rack tom 71%.",
        "    var viewBox: CGRect {",
        "        switch self {",
    ]
    for name in order:
        x, y, w, h = icons[name]["viewBox"]
        lines.append(f"        case .{name}: CGRect(x: {x:g}, y: {y:g}, width: {w:g}, height: {h:g})")
    lines += ["        }", "    }", ""]

    lines += [
        "    // The path data below is generated and each drawing is one literal. Wrapping it would not make it readable,",
        "    // only harder to replace wholesale the next time a drawing changes.",
        "    // swiftlint:disable line_length",
        "",
        "    /// The outline — the instrument itself.",
        "    var strokePath: String {",
        "        switch self {",
    ]
    lines += [f'        case .{name}: "{normalize(icons[name]["stroke"])}"' for name in order]
    lines += ["        }", "    }", ""]

    lines += [
        "    /// The solid hardware drawn under the outline: lugs, the kick's beater, the hi-hat's footboard.",
        "    var fillPath: String? {",
        "        switch self {",
    ]
    for name in order:
        fill = icons[name].get("fill")
        lines.append(f'        case .{name}: {chr(34) + normalize(fill) + chr(34) if fill else "nil"}')
    lines += ["        }", "    }", "", "    // swiftlint:enable line_length", ""]

    lines += [
        "    /// Where a one- or two-letter label sits on the drawing, in design space — the middle of the shell band, the",
        "    /// only part of a drum wide enough to hold a glyph at 44 pt. `nil` for everything that never carries one.",
        "    var labelAnchor: CGPoint? {",
        "        switch self {",
    ]
    for name in order:
        anchor = icons[name].get("labelAnchor")
        lines.append(f"        case .{name}: {f'CGPoint(x: {anchor[0]:g}, y: {anchor[1]:g})' if anchor else 'nil'}")
    lines += ["        }", "    }", "}", "", END]
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="exit 1 if the Swift file is out of date")
    args = parser.parse_args()

    icons = json.loads(SOURCE.read_text())
    generated = swift(icons)

    existing = TARGET.read_text()
    head, _, rest = existing.partition(BEGIN)
    body, marker, tail = rest.partition(END)
    if not marker:
        raise SystemExit(f"{TARGET} has no {BEGIN}/{END} markers")
    updated = head + generated + tail

    if args.check:
        if updated != existing:
            print(f"{TARGET.relative_to(ROOT)} is out of date — run Scripts/generate-drum-icons.py", file=sys.stderr)
            return 1
        print(f"{TARGET.relative_to(ROOT)} is up to date")
        return 0

    TARGET.write_text(updated)
    print(f"wrote {TARGET.relative_to(ROOT)} — {len(icons)} icons")
    return 0


if __name__ == "__main__":
    sys.exit(main())
