# Drum pad: instrument icons, 14-key layout, hidden-instrument menu

**Date:** 2026-08-30
**Branch:** `worktree-drum-pad-icons`
**Scope:** iOS only. Android keeps the existing `PARITY(android)` marker on `EditorDrumPadRows`.

## Goal

Replace the drum pad's "notehead glyph + short name" key face with drawn instrument
pictograms, shrink the default layout from 15 keys to 14 (7 x 2), and give the pad a
rest key and a menu for the GM drums that are not on the pad.

The key faces come from a design session on pen.dev (`~/.pencil/documents/…/pencil-new.pen`,
frame "B Detail — SMuFL pictograms" → "Proposal v3" → "Pad final"). SMuFL's percussion
pictograms were evaluated first and rejected: they are notation symbols, not UI icons
(a tom-tom is a plain square, a suspended cymbal is a horizontal line).

## Decisions taken during design

- **Outline pictograms, not silhouettes.** Each instrument is drawn with its real
  structure — counterhoop, head, lugs, legs, stand, pedal, cymbal bell — as one stroke
  path plus, where hardware needs weight, one fill path.
- **Hi-hat is drawn from the side**, every other instrument from a 3/4 view. Closed /
  open / pedal differ only in the plate gap and the presence of a footboard, so the three
  states read as one instrument.
- **Ride vs crash: size and tilt.** Ride is flat and large; the two crashes are tilted
  (mirror images of each other) and drawn ~82% of the ride's diameter. **No labels on
  cymbals** — the mirror pair carries "which side of the kit".
- **Toms: four, labelled on the shell.** H / M / L on the rack toms at a uniform icon
  size, and the floor tom unlabelled because its legs already separate it. The shell band
  is the only area of the drawing wide enough to hold a legible glyph at 44 pt.
- **No auto-added keys.** `DrumPadLayout` stays global and is not extended from the open
  score. An instrument that sounds in the caret's column but is not on the pad shows up
  through the ellipsis menu, whose button lights with the same accent capsule the keys use.

## Layout

Row 1 (7 instruments + rest): closed hi-hat 42, open hi-hat 46, pedal hi-hat 44,
crash 1 49, crash 2 57, ride 51, cowbell 56, **rest**.

Row 2 (7 instruments + menu): snare 38, side stick 37, tom H 50, tom M 47, tom L 45,
floor tom 43, kick 36, **ellipsis**.

Dropped from the current default: hi-mid tom 48 and low floor tom 41. Added: crash 2 57.

## Tasks

### 1. `DrumInstrumentIcon.swift` (new, `Sources/Editor/Views/`)

A `Shape` that parses the design-space path data and scales it through the icon's own
view box, plus a `View` that stacks the fill and stroke layers. One `case` per instrument
(`hiHatClosed`, `hiHatOpen`, `hiHatPedal`, `crashLeft`, `crashRight`, `ride`, `cowbell`,
`snare`, `sideStick`, `tom`, `floorTom`, `kick`), and a mapping from GM pitch to case.

**Pass:** a `#Preview` renders all twelve at 96 pt and at the real 44 pt key size.

### 2. `DrumPadLayout.default` (`Sources/EditorCore/`)

Fourteen keys in the order above, `rowCount: 2`.

**Pass:** `DrumPadLayoutTests` green after updating the expectations.

### 3. `EditorDrumPadRows` (`Sources/Editor/Views/`)

- Key face = `DrumInstrumentIcon` for the pitch, with the shell letter overlaid for the
  three rack toms. A pitch with no icon falls back to today's notehead + short name, so a
  user-edited layout can hold any GM drum.
- Rest key moves to the end of **row 1**; the ellipsis menu closes **row 2**.

**Pass:** the existing drum previews render; the lit state still draws the accent capsule.

### 4. Hidden-instrument menu

A `Menu` listing every `GMDrumset` pitch not in the current layout (13 with the default),
each row a `Label` whose icon is `checkmark` when that pitch sounds in the caret's column.
Selecting a row calls the same `pressDrumKey` path as a pad key, so it toggles the
instrument in the column — it does **not** add the key to the pad. The menu also opens
`EditorDrumLayoutSheet`, which keeps its existing job: choosing what the pad shows.

The ellipsis button itself wears the armed capsule whenever any hidden pitch is lit.

**Pass:** with a chart that uses a splash cymbal, the button lights and the row is checked.

### 5. Localization

All 27 `GMDrumset` pitches already have `editor.drum.name.*` entries, so the menu needs no
new strings. Add `editor.pad.drum.more` for the ellipsis button's accessibility label.

### 6. Verification

`xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation build`
then the Editor package tests. Previews for the pad rendered via `mcp__xcode__RenderPreview`.
