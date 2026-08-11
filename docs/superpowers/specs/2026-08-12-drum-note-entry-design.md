# Drum note entry — design

**Date:** 2026-08-12
**Status:** design approved, not yet planned
**Depends on:** `2026-08-06-android-note-editing-design.md` (SP2 in particular — see §9)

## 1. Problem

The note-entry pad is built for pitched staves. Its second row is the seven letter keys C–B, which mean
nothing on a percussion staff, so a drum part cannot be edited at all today. Making it editable runs
straight into a width problem: MuseScore's stock drumset has close to forty entries, and an iPhone pad row
fits eight 44 pt keys.

The width problem is the visible one. The harder one is voices. A drum part is conventionally written
across two voices — hands stems-up in voice 1, feet and floor tom stems-down in voice 2 — and MuseScore's
own drum input, which assigns the voice automatically from the drumset entry, is awkward precisely because
its caret lives *inside* a voice: switching voices means re-navigating, because voice 2 carries its own
rhythm and its "beat 3" is not at the same element index as voice 1's.

## 2. Governing principle

**pitched and drums are used by the same person, so their experience must not diverge except where a
drum-specific problem forces it.** Every deviation below is justified against that rule; the ones that
failed it were dropped during design and are recorded in §11.

The rule cuts both ways. Multi-voice editing is *not* drum-specific — piano, SATB-on-one-staff and divisi
all have it, and the pitched pad has the same navigation pain today. What *is* drum-specific is that a drum
key can carry its own voice: an instrument and its voice are 1:1 (a bass drum is always the feet voice), so
the voice can be an attribute of the key. A pitched C–B key cannot carry a voice — pressing "C" does not
say which voice it belongs to — so pitched keeps an explicit `activeVoice`.

That distinction is what lets one caret model serve both (§5.4).

## 3. Scope

**In:**

- Entering, toggling off and re-instrumenting notes on a percussion staff (`Instrument.useDrumset`).
- A configurable drum key layout: which instruments, in what order, on how many rows, in which voice.
- A column caret shared by pitched and drum staves.
- The swift-sheet-music work that makes the above representable and savable.

**Out, with reasons:**

- **Accents, ghost notes, flams.** The Editor has no articulation or grace-note support at all; this is an
  Editor-wide theme, not a drum one.
- **Where ← / → live.** Stepping the caret is equally awkward on pitched staves; the cause is that the
  pills sit away from the pad, which is the same problem `project_reader_pad_between_pills` records. Fixing
  it for drums only would be exactly the divergence §2 forbids.
- **Creating a drum part from scratch.** A separate near-term theme. This design only guarantees that the
  pad and the caret work in an empty measure, so that theme can build on it without rework.
- **Android UI.** The logic is shared by construction (§8); the Compose pad is a later, Android-idiomatic
  piece of work.

## 4. What exists today

Established by reading the code, not assumed:

**swift-sheet-music**

- `Instrument` carries `useDrumset: Bool` and `drumLineMap: [Int: Int]` (MIDI pitch → MuseScore line).
- `MSCXDecoder+Instrument` reads only `<line>` out of each `<Drum>` element. `name`, `head`, `voice` and
  `stem` are parsed past and discarded.
- `MSCXEncoder+Instrument` nevertheless *writes* all of them, from three private functions —
  `gmDrumName`, `gmDrumHead`, `gmDrumVoiceIndex`. They exist because MuseScore Studio silently ignores a
  `<Drum>` entry that lacks `<head>` / `<voice>` / `<stem>` and collapses every drum onto one line. **So a
  complete GM drumset table is already in the repo; it is just private, encoder-side, and not consulted on
  the way in.**
- `LayoutEngine+Placement` already renders drum staves correctly: it takes the staff line from
  `drumLineMap` (`step = 4 - line`) and forces stem direction by voice on any staff that has one.
- `Note.headType` round-trips through MSCX (`<head>` on both the decoder and encoder side). MusicXML is
  import-only — there is no MusicXML encoder — so there is no second export path to keep in step.
- `ReplaceVoiceElements` requires the target voice to already exist; it throws otherwise. Nothing in the
  package creates a voice.
- `InputNote` takes `pitch` and `tpc` only. There is no way to write a note carrying a notehead override.

**Folino**

- `EditorPadView` lays out two rows. Row 1 is five duration keys (whole, half, quarter, eighth, sixteenth)
  plus the tuplet key, the tie key and the dot key — **eight keys, exactly full**. Row 2 is C–B plus the
  rest key. A wide iPad collapses both into one row via `ViewThatFits`.
- The last key of row 2 is a **rest key**, not a backspace: it writes a rest of the armed length over the
  selection. (Several source comments still call it "⌫" from an older design. They are stale.)
- `EditorViewModel.activeVoice` exists but only biases hit-testing; writes go to whatever voice the caret's
  own slot is in.
- The `Editor` package is a single iOS-only target that imports `SheetMusicUI` and `UtilityUI`.

## 5. Design

### 5.1 Entering drum mode

When the staff holding the caret has `Instrument.useDrumset == true`, the pad's lower rows switch to the
drum layout. There is no manual mode switch — the score already says which kind of staff it is, and an
extra toggle would be a second source of truth the user has to keep in sync.

Row 1 is untouched: same five durations, tuplet, tie and dot keys, same behavior. The rest key keeps its
pitched meaning (write a rest of the armed length over the selection).

### 5.2 The key model

One key is a `DrumPadKey`:

| field | source |
| --- | --- |
| `pitch` | MIDI drum pitch (35…81) |
| `name` | display label, shortened for the key face |
| `headType` | notehead override written with the note (`cross`, `slashed1`, `normal`, …) |
| `line` | staff line, for the key's own preview glyph |
| `voiceIndex` | which voice this instrument is written into |

Defaults come from `GMDrumset` (§6). A score's own `Instrument.drumset` overrides the default for pitches
it defines — an imported chart that puts the ride on a non-standard line must keep that line.

`DrumPadLayout` is the ordered list of keys plus the row count. It is **global, not per-score**: the user
asked for a fixed core they can learn, and a layout that reshuffles itself per file defeats that.

Two voice presets ship, selectable in one tap and then editable per key:

- **Single voice** — every key in voice 1.
- **Hands and feet** — bass drum, pedal hi-hat and low floor tom in voice 2, everything else in voice 1
  (this is `gmDrumVoiceIndex`'s split, i.e. MuseScore's).

When a score is opened, the preset is pre-selected from what the file actually does: if any measure of the
drum staff uses two voices, "hands and feet" is chosen, otherwise "single voice".

### 5.3 Pad layout

Three rows on a phone:

1. durations / tuplet / tie / dot — unchanged
2. eight instrument keys
3. seven instrument keys plus the rest key

Fifteen instrument keys by default, which covers a realistic kit with room to spare. The row count is
configurable from 1 to 3; on a wide iPad `ViewThatFits` collapses as it does today.

A key shows its notehead glyph over a short name, and wears a **voice badge** when it is not in voice 1. A
key is **lit when its instrument sounds in the caret's column** — that is what makes the pad readable while
correcting an imported chart, and it is the property that lets the keys be toggles at all.

Long-pressing an instrument key opens a **menu**, matching how the tuplet and dot keys already behave
(`Menu` with `primaryAction:`). It offers: fill this measure with this instrument at the armed duration
(and un-fill, when it is already filled), swap the key to a different instrument, and move it between
voices.

### 5.4 The caret becomes a column

The caret becomes `(staff, measureIndex, tick)` — a vertical column across the staff, with no voice of its
own. Which voice a write lands in is decided separately:

- **pitched** — `activeVoice`, i.e. the voice picker that already exists.
- **drums** — the key's `voiceIndex`.

← / → move the column to the next or previous **onset in any voice**, falling back to a step of the armed
duration when there is no onset ahead (which is what makes an empty measure enterable). On a single-voice
staff — most scores — that is the same position the caret lands on today.

The caret is **drawn at the write destination**, so a pitched single-voice staff looks exactly as it does
now. On a drum staff the destination spans voices, so the caret naturally draws as a column line across the
five staff lines. That is a consequence of one rule, not a per-platform branch.

This is deliberately not a drum feature. It repairs multi-voice pitched editing at the same time, and it is
the reason the two staves can share one caret model instead of diverging.

It does change pitched behavior in one place, and that should be stated rather than discovered: writes go
to `activeVoice` instead of to whatever voice the caret's own slot happened to be in, and ← / → cross
voices instead of walking one. On a single-voice staff the two are indistinguishable; on a multi-voice
staff the new behavior is the point. This is why §9 gives the change its own step with its own gate rather
than folding it into SP2's "behavior identical" refactor.

### 5.5 What a key press does

The whole sequence is one `CompositeEditCommand`, so **one tap is one undo step**.

1. Resolve the target voice from the key.
2. If that measure has no such voice, **create it**, filled with rests.
3. If the drumset has no entry for this pitch, **add one** from `GMDrumset`. Skipping this is the subtle
   failure: without a `drumLineMap` entry, layout falls back to the pitched diatonic formula and the note
   is drawn on a completely wrong line — visible only for instruments the imported chart never used.
4. Find the element covering the caret's tick in that voice:
   - **a chord that already contains this pitch** → toggle off (remove the note from the chord, or delete
     the element when it was the chord's only note)
   - **a chord without this pitch** → add the note to the chord
   - **a rest** → replace it with a chord of the armed duration, splitting the rest first when the caret's
     tick falls inside it rather than at its start

The caret does **not** advance. Stepping is explicit, via ← / →.

Auto-advance was considered and rejected: simultaneity is the normal case on a drum staff, so an advancing
caret would mis-fire on every stacked hit and force a step back. That is a drum-specific problem, so the
divergence from the pitched pad is justified under §2 — and note that the *key's meaning* differs too
(toggle vs. write), of which the advance behavior is a consequence rather than a separate decision.

Selection keeps its pitched role: it lands on the note most recently toggled on, so the callout still
covers duration and ties for that note.

### 5.6 Editing the layout

Reached from the `…` key's menu. In edit mode, keys drag to reorder, tapping a key opens the instrument
picker, tapping its voice badge flips 1 ↔ 2, and a stepper sets the row count. The voice presets live in
the same place.

`DrumPadLayout` persists through a Domain value type written to `UserDefaults`. It must **not** be read
through `@AppStorage` into layout directly — that routes through `UserDefaults` and lands outside
`withAnimation`, which previously turned one pad animation into a two-stage bounce
(`project_note_editing`). Drive the view from local state; persist separately.

## 6. swift-sheet-music changes

**6a — drumset decode/encode. No dependency on the in-flight Android work.**

1. Publish `GMDrumset` in `SheetMusicCore`: pitch → (name, head, line, voice, stem). Move
   `MSCXEncoder+Instrument`'s three private functions into it, deleting the duplication.
2. Decode `<Drum>` fully into `Instrument.drumset: [Int: DrumsetEntry]`. `drumLineMap` becomes derived from
   it, so `LayoutEngine+Placement` and every other existing caller is untouched. Encoding reads from
   `drumset`, filling gaps from `GMDrumset` — **existing fixtures must encode byte-identically**, which is
   the gate for this half.

**6b — editing commands. Consumes intent-wire indices, so it must land after the note-editing branch is
tagged (§9).**

3. A command that creates a voice filled with rests (`ReplaceVoiceElements` refuses a voice that does not
   exist, and nothing else creates one).
4. A rest split at a tick, so a column landing mid-rest is writable.
5. Note input carrying a `headType`, plus changing an existing note's head — `InputNote` takes only
   `pitch` / `tpc` today, so a cross-notehead hi-hat cannot be written at all.

Each gets an intent in `SheetMusicEditWire`, appended after the indices the note-editing branch has already
claimed.

## 7. Saving

MSCX carries everything this design writes: `<head>` on the note, and `<Drum>` entries on the instrument.
MusicXML is import-only, so there is no second export path.

The one hazard is §5.5's step 3 — a pitch written without a matching drumset entry saves fine and *renders*
wrongly. It belongs in tests, not in review vigilance.

## 8. Placement, so Android does not have to reimplement this

Per the repo's parity rule, logic is shared and only what can exist on one platform alone is duplicated.
Concretely:

- `DrumPadLayout`, `GMDrumset` resolution, the voice presets, the write resolution of §5.5 and the column
  caret of §5.4 all live in **`EditorCore`** (Foundation + `SheetMusicCore` + `Domain`), the target SP2
  extracts.
- Every drum op returns the intent it applied, exactly as the existing op vocabulary does, so the Android
  relay forwards it rather than re-deriving it.
- Only the SwiftUI pad view is iOS-only. The Compose pad will be a separate, Android-idiomatic layout over
  the same ops.

The failure mode this avoids is writing the toggle resolution as `EditorViewModel` methods, which would
force Android to write a second copy — the thing §2 and the parity rule both exist to prevent.

The deferred Compose pad is a deliberate one-platform-first gap, so it gets a `PARITY(android):` marker at
the point of divergence and a row in `docs/engineering/ios-android-parity.md`. Only the UI is deferred; the
ops behind it ship shared, so implementing the Android half deletes the marker without moving any logic.

## 9. Ordering

The Android note-editing effort is mid-flight and **SP2 extracts `EditorCore`, whose contents include
"caret and selection, and the split between them"** — the exact code §5.4 rewrites. SP2's gate is "pure
refactor, behavior identical, existing Editor tests pass". Changing that behavior immediately before the
extraction would muddy the gate and invalidate a written plan.

| # | step | why here |
| --- | --- | --- |
| 1 | §6a — ssm drumset decode/encode | touches only `Instrument` decode/encode; no `ElementNavigator`, no intent wire. Lands on ssm `main`, and the note-editing branch picks it up on its next re-merge. Can run in parallel with SP2 |
| 2 | SP2 — extract `EditorCore` | already planned; the foundation everything else sits on |
| 3 | §5.4 — column caret, inside `EditorCore` | shared with Android for free. Its own gate, after SP2's |
| 4 | §6b — ssm editing commands + intents | appends wire indices, so it waits for the 1.11.0 tag |
| 5 | §5.1–5.6 — the drum pad | ops in `EditorCore`, SwiftUI as a thin adapter |

The cost is honest: drums are not touchable until SP2 lands. The alternative — build the pad on iOS now and
move the logic into `EditorCore` afterwards — is the rework this ordering exists to prevent.

## 10. Testing

**ssm**

- `<Drum>` round-trip, and byte-identical encoding of existing fixtures (the gate for §6a).
- `GMDrumset` against MuseScore's stock drumset.
- Apply and inverse for each of §6b's three commands, including creating a voice in a measure that has one.

**`EditorCore`, column caret (§5.4)**

- The gate is that the existing `EditorViewModelInputTests` / `ElementNavigatorTests` still pass.
- New: column stepping across a multi-voice staff; armed-duration stepping through an empty measure.

**`EditorCore`, drum input (§5.5)**

- All four branches of step 4, plus mid-rest splitting.
- Writing into a measure whose target voice does not exist.
- Writing a pitch absent from the score's drumset, asserting the entry is added and the note lands on the
  GM line.
- One tap is one undo step.

**View**

- `#Preview` of the three-row pad at compact and regular width, and of the lit state.

**Device**

- Correcting a real imported drum chart, which is the primary use case and the only way to judge whether
  three rows are worth their height.

## 11. Rejected during design

| Idea | Why it was dropped |
| --- | --- |
| Show only the pitches the open score uses | The set would change per file; the user wants a fixed core they can learn |
| Trim row 1 to quarter/eighth/sixteenth to make room | Whole and half notes are ordinary in drum writing |
| Repurpose the rest key as "clear this column" | Writing a rest of the armed length is wanted on drum staves too |
| Move ← / → into the pad | Not drum-specific — pitched has the same problem, so fixing one side only is the divergence §2 forbids |
| Long-press an instrument key to fill directly | Breaks the established "long press opens a menu" rule; fill moved under the menu |
| Column caret on drum staves only | Multi-voice is not drum-specific; a per-staff-kind caret is exactly the divergence §2 forbids |
