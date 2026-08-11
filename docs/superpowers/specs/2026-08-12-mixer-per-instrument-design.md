# Mixer per-instrument strips — design

2026-08-12. Moves folino's playback mixer off the staff and onto the mixer
strip, which is what the audio engine has always actually addressed.

## The problem

folino's mixer is addressed per staff: `PlaybackController.setStaffVolume(staff:)`
takes a flattened staff index, `PlaybackPreferences.perStaff` is a list keyed by
that index, `ReaderPreferences.staffVolumeOverrides` / `staffProgramOverrides` are
keyed by `StaffAddress`, and `PlaybackInspectorScreen` draws one row per staff.

The engine has never been able to honour that. In swift-sheet-music 1.9.0,
`MidiRenderer.staffChannels(score:)` handed **every staff of a part the same MIDI
channel**:

```swift
let primary = perPart[partIndex].first?.channel ?? partIndex
for _ in 0 ..< part.staves.count {
    result.append(primary)
}
```

and `applyStaffGain(at:)` sent CC 7 on that channel. A grand staff therefore drew
two sliders that wrote to one channel: whichever moved last won, and the other
row kept displaying a value that no longer described any sound. `applyPreferences`
replays `perStaff` in flattened-staff order on every load, so after a relaunch the
part sounded at its LAST staff's stored volume regardless of what the first row
showed.

1.10.0 made the engine's real unit explicit — `MixerChannel.Kind.staff(Int)` was
replaced by `.instrument(partIndex:ordinal:)` — and folino currently absorbs that
in one adapter (`LivePlaybackController.channel(forStaff:)`) which maps every
staff onto its part's tick-0 strip. That keeps the old surface compiling and
leaves two problems standing:

1. the mixer still draws rows that do not correspond to anything the engine can
   address separately;
2. a part that changes instrument mid-score has more than one strip, and folino
   can only ever reach `ordinal: 0`. In a real score in the user's library
   (an a cappella arrangement whose S / A / T-A parts alternate between piano and
   accordion across 17 instrument changes), that is **8 strips reachable as 5
   rows** — every accordion passage is uncontrollable.

## What a strip is

A strip is one independently controllable sound: one fader, one mute, one solo,
one program. swift-sheet-music defines it as a **(part × distinct instrument)**
pair, deduped within a part, ordered by first appearance. `LiveChannelPlan.Strip`
carries `partIndex`, `ordinal`, `instrument` and `liveChannel`.

Dedup is within-part only, so two parts never merge even when they declare the
identical instrument — an a cappella score whose ten parts all use `voice` keeps
ten independent strips. What collapses is the other direction: a part's staves.

| score | parts | staves | rows today | strips |
| --- | --- | --- | --- | --- |
| ten-part a cappella, all `voice` | 10 | 10 | 10 | 10 |
| six-part a cappella + drumset | 6 | 6 | 6 | 6 |
| five-part a cappella, 3 parts alternate piano/accordion | 5 | 5 | 5 | **8** |
| piano grand staff | 1 | 2 | 2 | **1** |

## Goal

Make the mixer address strips. Rows correspond one-to-one with what the engine
can control, and the instrument-change strips become reachable.

**Explicit non-goal:** per-hand control of a grand staff. It has never worked, and
restoring it would mean allocating a channel per staff in swift-sheet-music — the
opposite of the direction that package just took. If it is wanted later it is its
own project, starting on the ssm side.

## Design

### 1. The engine owns the strip list

`swift-sheet-music`'s `PlaybackEngine` already publishes exactly what the mixer
needs, as `public private(set) var mixerChannels: [MixerChannel]`, rebuilt inside
`prepare(score:)` from the same `LiveChannelPlan` the renderer used. Each entry
carries the strip id, a display name (`"S"` / `"S (Accordion)"`, produced by ssm's
own `stripName` disambiguation), the score's authored CC 7 as the initial volume,
and the program (`nil` for a drum strip).

folino consumes that list and **never derives strips itself**. The dedup rule —
two instruments merge iff their `InstrumentChannel`s agree on six sounding fields
— stays in one place. Re-deriving it in folino would be a second implementation to
keep in sync, and a third once Android follows.

Domain gains a value type and one protocol method:

```swift
public struct MixerStripID: Hashable, Sendable, Codable {
    public let partIndex: Int
    public let instrumentOrdinal: Int
}

public struct MixerStrip: Hashable, Sendable {
    public let id: MixerStripID
    public let displayName: String
    /// The score's authored level for this strip, before any user override.
    public let defaultVolume: Double
    /// `nil` for a drum strip, whose program is fixed.
    public let defaultProgram: Int?
}

// PlaybackController
func mixerStrips() async -> [MixerStrip]
```

`MixerStripID` encodes as a two-element array `[partIndex, instrumentOrdinal]`,
matching `StaffAddress+Codable` — so the persisted JSON columns keep their shape
and the migration below stays a filter rather than a rewrite.

`mixerStrips()` is a method rather than a stored published property because the
list only changes at `load(...)` / `reloadSoundfont()`; the Reader refreshes its
copy at those two points. Before a score is loaded the list is empty and the
mixer's parts section is not drawn — the mixer describes a prepared engine, and
drawing rows for a score the engine has not accepted is the failure this whole
change is removing.

`mixerChannels` also carries a `.metronome` entry, which has no `MixerStripID`
and is not a part of the score. The adapter drops it: the metronome keeps its own
toggle in the inspector's general section and its own
`PlaybackController.setMetronomeEnabled(_:)` path, exactly as today.

**This needs nothing from swift-sheet-music.** `mixerChannels`, the `.instrument`
kind, the per-channel setters and the composed name all ship in 1.10.1, which
folino is already pinned to. (1.11.0 adds `MixerChannel.partName` /
`instrumentName` for hosts that group their strips; the flat list in §4 does not
use them, so this work does not wait on that release.)

### 2. `MixerStripID` replaces the flat staff index

| before | after |
| --- | --- |
| `setStaffVolume(staff: Int, volume:)` | `setStripVolume(strip: MixerStripID, volume:)` |
| `setStaffMute(staff: Int, isMuted:)` | `setStripMute(strip: MixerStripID, isMuted:)` |
| `setStaffSolo(staff: Int, isSolo:)` | `setStripSolo(strip: MixerStripID, isSolo:)` |
| `setStaffInstrument(staff: Int, bank:, program:)` | `setStripInstrument(strip: MixerStripID, bank:, program:)` |
| `PlaybackPreferences.perStaff: [StaffMixerState]` | `perStrip: [StripMixerState]` |
| `StaffMixerState.staffIndex: Int` | `StripMixerState.strip: MixerStripID` |
| `ReaderPreferences.staffVolumeOverrides: [StaffAddress: Double]` | `stripVolumeOverrides: [MixerStripID: Double]` |
| `ReaderPreferences.staffProgramOverrides: [StaffAddress: Int]` | `stripProgramOverrides: [MixerStripID: Int]` |

`LivePlaybackController.channel(forStaff:)` and every mixer-path use of
`Score.flattenedStaffIndex(of:)` go away with it.

### 3. Staff-keyed notation settings stay staff-keyed

`hiddenStaves`, `authoredHiddenStaves` and `staffClefOverrides` describe how the
music is written down, not how it sounds. They keep their `StaffAddress` keys and
this change does not touch them. Holding that line is what keeps the change
reviewable: every renamed field is one whose value was about audio.

One consequence for `hasStaffBoundOverrides` / `clearingStaffBoundOverrides`,
which a PDF re-read consults to decide whether the user's settings still mean
what they meant. Their subject is "settings addressed by an index the score
supplies, which a re-parse can renumber" — a strip id is exactly that, so the
strip-keyed overrides stay in both. Only the reasoning changes from "staff index"
to "score-derived index", so the two members and the comments naming staves are
renamed to `hasScoreBoundOverrides` / `clearingScoreBoundOverrides`, along with
their one caller in `ReaderViewModel+PDFReread.swift`. Leaving the old names would
mean a member called *staff*-bound whose largest contributors are no longer keyed
by staff.

### 4. The Reader draws a flat list, one row per strip

`PlaybackMixerModel`'s dictionaries re-key from `StaffAddress` to `MixerStripID`,
and it holds the strip list refreshed from the controller.
`PlaybackInspectorScreen` draws the list in the order the engine reports it — by
part, then by ordinal within the part — with **no part header**. Each row carries
the strip's `displayName`, the slider, mute / solo and the program picker.

Dropping the header is a decision against the obvious alternative, and the reason
is in the data. A grouped layout would need a group title and a row label that
differ, and swift-sheet-music derives them from the same place: the part title
from `Score.staffDisplayName` (instrument `longName`, then part `trackName`) and
the instrument label from the instrument's `longName`, then `trackName`, then id.
In real scores those collide. Measured on three of the user's own a cappella
arrangements, every single-instrument part reported an instrument name **equal to
its part name** — the arranger names the instrument after the voice, so a grouped
mixer would read "Soprano 1" under a header "Soprano 1", ten times over. One
score goes further: its part-level instrument carries
`<longName>S</longName><trackName>ピアノ</trackName>`, so the *instrument* name
resolves to the *part* label.

`displayName` already solves this, because it is defined as the shortest label
that distinguishes a strip: the part alone when the part has one strip, the part
plus the instrument in parentheses when it has several. A flat list of those is
unambiguous with no header to stutter against, and it is the same string the
Android mixer shows, so the two platforms agree by construction rather than by
convention.

The program picker moves from the part to the strip. That is what makes an
instrument-change strip selectable at all, and it loses nothing: the program has
always been chosen per part in practice (`setPartProgram` fans one value out to
every staff of the part and `effectiveProgram(forPartIndex:)` reads the first
staff back).

Mute and solo remain session-only, exactly as today — they are not fields of
`ReaderPreferences` and this change does not make them persistent.

**Expect more rows, not fewer, on scores with instrument changes.** The five-part
arrangement above reports eleven strips: three of its parts alternate piano and
accordion, and each part's tick-0 piano is a *different* strip from the piano it
returns to, because the part-level channel authors `<controller ctrl="10"
value="63"/>` while the instrument-change channel omits it and defaults to 64.
Both strips own real measures, so this is faithful rather than wrong — but it
means a row can appear twice under names that differ only by a suffix. Left as
is; narrowing the engine's dedup to ignore inaudible differences is an ssm
judgement that one score is too thin a basis for.

### 5. Migration

Both affected columns are JSON text holding an array of `[key…, value]` rows with
a two-integer key, and `MixerStripID` encodes with the same shape. The v17
migration therefore reduces to: **keep rows whose second integer is `0`, drop the
rest.**

- `staff_program_overrides` — lossless. The Reader has only ever written program
  overrides for every staff of a part at once, so the dropped rows are duplicates
  of the kept one.
- `staff_volume_overrides` — a multi-staff part keeps its `staffIndexInPart == 0`
  value. Where the two disagreed, the sound followed the *last* staff, so a
  grand staff whose hands were set differently may play at a different level after
  the migration than before it. That is accepted: the pre-migration level was the
  product of the bug, and there is no honest value to preserve.

The migration goes in `Migrations+V17.swift`, following `Migrations+V16.swift` —
the pattern for keeping `Migrations.swift` under SwiftLint's 400-line budget
already exists, so no preparatory split is needed. v17 rewrites column contents
only; the table is not rebuilt.

### 6. Android stays where it is

Android's mixer is not migrated here; it is marked `PARITY(android)` at the point
of divergence and reaches the ledger through `Scripts/parity-report.py`.

The constraint that shapes the iOS work: `ReaderPreferencesReducer` /
`ReaderPreferencesBridge` are Swift inside folino's Library package and are what
the Kotlin mixer calls. Renaming a `ReaderPreferences` field changes them, and
changing their signatures breaks the Kotlin build. So **the bridge keeps its
`(part, staff)` signature**, translating to `MixerStripID(partIndex: part,
instrumentOrdinal: 0)` internally. Kotlin keeps compiling and Android keeps its
present behaviour — its per-staff rows all resolve to the part's tick-0 strip,
which is what the engine did with them anyway.

When Android follows, it must **read its strip list from its own engine** rather
than re-deriving it, and must not reimplement the dedup rule in Kotlin.

## Testing

- **Domain** — `MixerStripID` Codable round-trip and its two-element-array
  encoding; `ReaderPreferences` encode/decode with strip-keyed overrides;
  `hasScoreBoundOverrides` reports true for a strip-keyed override alone, and
  `clearingScoreBoundOverrides` empties both strip dictionaries while leaving the
  sound-only settings (tempo, A4, master volume, repeat, staff size) intact.
- **Persistence** — `MigrationV17Tests`: a pre-v17 row carrying overrides for
  `[0,0]`, `[0,1]` and `[1,0]` comes out holding `[0,0]` and `[1,0]`; a row with
  no multi-staff entries is byte-identical across the migration.
- **Reader** — `PlaybackMixerModel` against a fake controller recording
  `setStrip*` calls and returning a fixed strip list: a one-strip part and a
  two-strip part each address the right id; a program override set on
  `ordinal: 1` does not touch `ordinal: 0`.
- **Infrastructure** — the gap this change should close: there is currently **no
  test that crosses the ssm boundary**, because `setStaff*` is only ever exercised
  against fakes. Add a `LivePlaybackController` test asserting that a
  `MixerStripID` reaches the engine as the matching `MixerChannel.Kind`, and that
  `mixerStrips()` reflects a prepared score's `mixerChannels`.

## Risks

- **A saved override outliving its strip.** `ordinal` is derived from the score,
  so re-importing an edited score can renumber strips and leave an override
  pointing at a strip that no longer exists. Same class of problem as the existing
  `StaffAddress`-keyed overrides under staff renumbering; the overlay is read with
  a fallback to the score's authored value, so a stale key is inert rather than
  harmful. No extra reconciliation in this change.
- **The mixer disappearing when preparation fails.** Rows are drawn from the
  engine's list, so a score the engine rejected shows no mixer rather than
  inert rows. This is intended, but it is a visible behaviour change for a
  failure path that previously still rendered.
