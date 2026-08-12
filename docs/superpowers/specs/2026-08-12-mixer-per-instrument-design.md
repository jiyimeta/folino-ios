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
   accordion across 17 instrument changes), that is **11 strips reachable as 5
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
| five-part a cappella, 3 parts alternate piano/accordion | 5 | 5 | 5 | **11** |
| piano grand staff | 1 | 2 | 2 | **1** |

Measured, not estimated: the counts come from running `LiveChannelPlan.build`
over the actual files. The eleven is worth reading twice — three parts contribute
three strips each, because a part's opening piano and the piano it returns to
after the accordion are separate strips. Their `InstrumentChannel`s differ only
in pan (63, authored on the part channel, against 64, the default the
instrument-change channel inherits by omitting `<controller ctrl="10">`), and pan
is one of the six sounding fields the dedup compares. Both own real measures, so
this is the engine being faithful. MuseScore itself splits further still — one
strip per instrument-change instance, six for that part — which a live synth
cannot reproduce: those five parts total 22 instances against the 16 channels a
single port has, so collapsing repeats of one instrument is what makes live
control possible at all.

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
    /// The part this strip belongs to — the group's title.
    public let partName: String
    /// The instrument driving it — the row's label under that title.
    public let instrumentName: String
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

**The defaults must be snapshotted, not read late.** `mixerChannels` is engine
state, not a description of the score: `setVolume` / `setProgram` mutate the
entries in place, and `LivePlaybackController.load` runs `applyPreferences`
immediately after `prepare(score:)`. Read afterwards, `volume` and `program`
report the user's saved overrides, and every "reset to the score's level" and
"does this strip have an override" answer built on them would be a tautology. The
adapter therefore captures `engine.mixerChannels` **between `prepare` and
`applyPreferences`**, in both `load` and `reloadSoundfont`, and `mixerStrips()`
serves that snapshot.

**This needs swift-sheet-music 1.11.0**, which folino re-pins to as the first step
of the work. `mixerChannels`, the `.instrument` kind and the per-channel setters
ship in 1.10.1, but `partName` / `instrumentName` — which §4's rows are built from
— are 1.11.0 additions, as is the fix that makes `instrumentName` read MuseScore's
`<trackName>` (the instrument) rather than `<longName>` (the part's own label).
Without that fix the instrument name comes back equal to the part name on
real scores and the rows have nothing to say.

### 2. `MixerStripID` replaces the flat staff index

| before | after |
| --- | --- |
| `setStaffVolume(staff: Int, volume:)` | `setStripVolume(strip: MixerStripID, volume:)` |
| `setStaffMute(staff: Int, isMuted:)` | `setStripMute(strip: MixerStripID, isMuted:)` |
| `setStaffSolo(staff: Int, isSolo:)` | `setStripSolo(strip: MixerStripID, isSolo:)` |
| `setStaffInstrument(staff: Int, bank:, program:)` | `setStripInstrument(strip: MixerStripID, program:)` |
| `PlaybackPreferences.perStaff: [StaffMixerState]` | `perStrip: [StripMixerState]` |
| `StaffMixerState.staffIndex: Int` | `StripMixerState.strip: MixerStripID` |
| `ReaderPreferences.staffVolumeOverrides: [StaffAddress: Double]` | `stripVolumeOverrides: [MixerStripID: Double]` |
| `ReaderPreferences.staffProgramOverrides: [StaffAddress: Int]` | `stripProgramOverrides: [MixerStripID: Int]` |

`bank` goes. The adapter already discards it (`bank _: Int`) because the engine's
`setProgram(forChannel:to:)` takes no bank, so it has never done anything;
`StripMixerState` drops `gmBank` for the same reason. A rename is the moment to
stop carrying a parameter that has never been read.

`LivePlaybackController.channel(forStaff:)` and every mixer-path use of
`Score.flattenedStaffIndex(of:)` go away with it. Three fakes implement
`PlaybackController` and follow the signature change:
`Domain/Tests/.../AudioProtocolsTests.swift`,
`Reader/Tests/.../Fakes/FakePlaybackController.swift`, and — easy to miss, since
the Editor is otherwise untouched by this work —
`Editor/Tests/.../Support/FakePlaybackController.swift`.

**`perStrip` carries overrides only.** Today `perStaff` is a resolved list built
from `score.allStaves` before `load(...)` is called, carrying a value for every
staff whether the user set one or not. That is unbuildable now: the Reader cannot
enumerate strips before the engine has prepared the score, which is the whole
point of §1. It is also unnecessary — `rebuildMixerChannels` already seeds every
strip from the score's authored CC 7 and program, so a full list would only
re-send what the engine just did. `PlaybackPreferences.initial` therefore maps the
strip-keyed override dictionaries straight into `perStrip`, needing no score walk
and no strip list, and `applyPreferences` sends only those. `StripMixerState`
loses its `gmBank` / `gmProgram` fallbacks with the walk that computed them.

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

### 4. The Reader groups strips under their part

`PlaybackMixerModel`'s dictionaries re-key from `StaffAddress` to `MixerStripID`,
and it holds the strip list refreshed from the controller.
`PlaybackInspectorScreen` walks the list in the order the engine reports it — by
part, then by ordinal — and draws each part one of two ways:

- **one strip and one staff** — a single row: the part's name, the slider, mute /
  solo, the program picker and the staff's show/hide eye. Identical in shape to
  today's row, and the case every part of every score measured here falls into.
- **anything else** — a header carrying the part's name and one eye per staff of
  the part, then one row per strip beneath it, each labelled with the strip's
  `instrumentName` and carrying slider, mute / solo and program picker.

The collapse is what keeps the header from stuttering. A group title and a row
label have to say different things, and on real scores they often cannot: the
part title comes from `Score.staffDisplayName` and — before the 1.11.0 fix — the
instrument name resolved to the same string, because MuseScore's `<longName>` is
the part's printed label and arrangers set it to the voice. Measured across three
a cappella arrangements, every single-instrument part reported an instrument name
equal to its part name. Those parts now draw one row with the part's name and no
header at all, so there is nothing to repeat.

Where a header does appear, the part genuinely has more than one of something,
and that is exactly when the split labels earn their place: `S` over rows reading
`ピアノ` and `アコーディオン`.

**The eye belongs to the header, because visibility belongs to the staff.**
`StaffVisibilityButton` is keyed by `StaffAddress` and today rides each per-staff
mixer row — which stops working the moment rows are strips: a grand staff is two
staves and one strip, an instrument-change part is one staff and several. The
header is the only place in the new layout that still corresponds to a set of
staves, so it carries them, one per staff of the part. In the collapsed
single-row case there is exactly one staff and one strip, so the eye stays where
it is today. The PDF reader still opts out wholesale
(`showsStaffVisibility == false`), which is unchanged.

The program picker moves from the part to the strip. That is what makes an
instrument-change strip selectable at all, and it loses nothing: the program has
always been chosen per part in practice (`setPartProgram` fans one value out to
every staff of the part and `effectiveProgram(forPartIndex:)` reads the first
staff back). Its per-staff siblings — `setStaffProgram`,
`clearStaffProgramOverride` — have no production caller and are deleted rather
than re-keyed.

Mute and solo remain session-only, exactly as today — they are not fields of
`ReaderPreferences` and this change does not make them persistent.

**Expect more rows, not fewer, on scores with instrument changes** — eleven for
the five-part arrangement, as measured above, where two of a part's three rows are
the same piano at either end of an accordion passage. Both are real, separately
addressable channels; they will read `ピアノ` twice under the same header. Left as
is: merging them means teaching the engine to ignore an authored pan difference,
and a pan of 0 against 64 would be a deliberate placement that must not be
merged. Distinguishing them in the UI would need each strip's bar range, which is
information the mixer does not otherwise carry.

### 5. Migration — two stores, one rule

Both affected columns are JSON text holding rows of `[partIndex, staffIndexInPart,
value]`, and `MixerStripID` encodes with the same two-integer key. The rule is
therefore the same everywhere: **keep rows whose second integer is `0`, drop the
rest.**

- `staff_program_overrides` — lossless. The Reader has only ever written program
  overrides for every staff of a part at once (`setPartProgram` is the sole
  production caller), so the dropped rows duplicate the kept one.
- `staff_volume_overrides` — a multi-staff part keeps its `staffIndexInPart == 0`
  value. There is a defensible alternative: the sound followed the *last* staff,
  so keeping that one instead would make the migration audibly invisible. Staff 0
  wins anyway, because it is the value the mixer *showed* on the part's first row
  and the one a user would recognise, and because "the first entry of the part" is
  a rule that reads the same in SQL and in the Codable path below. A grand staff
  whose hands were set differently may therefore play at a different level after
  the migration than before it.

**The database is only half of it.** Android does not go through GRDB: it persists
the same `ReaderPreferences` through its Codable representation
(`ReaderPreferencesReducer` encode/decode), so a v17 SQL migration never runs
there. Renaming the coding keys alone would silently drop every stored Android
override (`decodeIfPresent … ?? [:]`), and keeping the old key names would
reinterpret a stored `staffIndexInPart: 1` as `instrumentOrdinal: 1` — a real,
different strip, and Android *does* write staff-1 entries because its bridge
setters are per-staff.

So `ReaderPreferences.codableSchemaVersion` goes to **3**, and the decoder applies
the same second-integer-is-zero filter to any blob at version ≤ 2 before building
the strip-keyed dictionaries. The mechanism already exists — version 2 introduced
the "untouched is `nil`" reinterpretation the same way — so this is one more
branch in a decoder that already has one.

The SQL side goes in `Migrations+V17.swift`, following `Migrations+V16.swift`.
v17 rewrites column contents only; the table is not rebuilt. `Migrations.swift`'s
own header asks that the next migration move the `upToVn` test-support migrators
out rather than grow the file further — v17 needs an `upToV16` for its test, so
that move happens here, into `Migrations+TestSupport.swift`.

### 6. Android stays where it is

Android's mixer is not migrated here; it is marked `PARITY(android)` at the point
of divergence and reaches the ledger through `Scripts/parity-report.py`.

The constraint that shapes the iOS work: `ReaderPreferencesReducer` /
`ReaderPreferencesBridge` are Swift inside folino's Library package and are what
the Kotlin mixer calls. Renaming a `ReaderPreferences` field changes them, and
changing their signatures breaks the Kotlin build. So **the bridge keeps its
`(part, staff)` signature**, translating to `MixerStripID(partIndex: part,
instrumentOrdinal: 0)` in both directions — setters map any staff onto the part's
tick-0 strip, and the getters answer every staff of a part with that strip's
value.

That is not quite "no change on Android", and the spec should own the difference:
today a value written on staff 1 comes back at staff 1, so Compose shows it on the
row the user touched. After the translation, both rows of a grand staff read the
same stored value, and a value set on the second row appears on the first as well.
Nothing sounds different — those two rows always drove one channel — but the UI
stops pretending they are independent, which is the same correction iOS is making,
arriving on Android as a side effect rather than as a redesign.

When Android follows properly, it must **read its strip list from its own engine**
rather than re-deriving it, and must not reimplement the dedup rule in Kotlin.

## Testing

- **Domain** — `MixerStripID` Codable round-trip and its two-element-array
  encoding; `ReaderPreferences` encode/decode with strip-keyed overrides;
  a schema-2 blob carrying `[0,0]`, `[0,1]` and `[1,0]` decodes to `[0,0]` and
  `[1,0]`, and a schema-3 blob is left alone; `hasScoreBoundOverrides` reports
  true for a strip-keyed override alone, and `clearingScoreBoundOverrides` empties
  both strip dictionaries while leaving the sound-only settings (tempo, A4, master
  volume, repeat, staff size) intact.
- **Persistence** — `MigrationV17Tests`: a pre-v17 row carrying overrides for
  `[0,0]`, `[0,1]` and `[1,0]` comes out holding `[0,0]` and `[1,0]`; a row with
  no multi-staff entries is byte-identical across the migration; a row whose
  column holds malformed JSON survives the migration without throwing, matching
  the record decoders, which already swallow that case rather than failing the
  read.
- **Reader** — `PlaybackMixerModel` against a fake controller recording
  `setStrip*` calls and returning a fixed strip list: a one-strip part and a
  two-strip part each address the right id; a program override set on
  `ordinal: 1` does not touch `ordinal: 0`; the model refreshes its strips when a
  PDF's background parse completes and prepares playback, not only on the first
  load; `hasScoreBoundOverrides` still gates the PDF re-read confirmation.
- **Infrastructure** — the gap this change should close: there is currently **no
  test that crosses the ssm boundary**, because `setStaff*` is only ever exercised
  against fakes. Add `LivePlaybackController` tests asserting that a
  `MixerStripID` reaches the engine as the matching `MixerChannel.Kind`; that
  `mixerStrips()` reflects a prepared score's `mixerChannels`; and — the snapshot
  ordering from §1 — that loading a score whose preferences carry a volume
  override still reports the score's **authored** level as that strip's
  `defaultVolume`.

**Where the refresh happens.** The strip list is fetched after
`ReaderPlaybackSession.prepareForPlayback` completes — the same background task
the Reader kicks off on open — and again after `reloadSoundfont()`. There is no
existing "load finished" callback on the controller, so the session gains one
rather than the mixer polling. Until it fires the list is empty and the parts
section does not draw, where today rows appear immediately from `score.parts`.

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
  failure path that previously still rendered — and the same emptiness appears
  briefly on every open, between the inspector being reachable and the background
  prepare finishing.
- **Two rows reading the same name.** A part whose piano is interrupted by another
  instrument reports the opening piano and the returned-to piano as separate
  strips, so its header can cover two rows labelled `ピアノ`. They are genuinely
  different channels covering different bars; the mixer gives the user nothing to
  tell them apart. Accepted for now — see §4 for why neither merging them nor
  labelling them with bar ranges is taken here.

## Related follow-up, not in this change

swift-sheet-music 1.11.0 lifted folino's tie-chain walk into
`SheetMusicCore.TiePlanner.tieChain(containing:in:)`, public, so that an Android
host relaying an edit intent gets the same behaviour without a Kotlin
reimplementation. folino's `Editor/TiePlanner.swift` still carries its own copy,
as does its `ElementNavigator`, which moved to `SheetMusicCore` in the same
release. Nothing is broken — the iOS editor builds its own `SetNotePitch`
composite and never goes through the intent path — but the rule now exists twice.
Deleting folino's copies in favour of the package's is a small cleanup that the
1.11.0 re-pin makes possible, and is best landed **before** this work rather than
tangled into it.
