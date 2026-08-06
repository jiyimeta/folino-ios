# Note Editing on Android — Design

- Date: 2026-08-06
- Folino branch: `worktree-android-note-editing` (off local `main` `b50a95aa`)
- swift-sheet-music branch: `android-note-editing` (off `origin/main` `75befe54` = ssm 1.8.0, the version Folino pins today)
- Status: design approved, implementation plan pending

## 1. Goal

Bring the iOS note-editing feature — Approach A "Caret & Pad", shipped 2026-07-27,
spec `docs/superpowers/specs/2026-07-16-note-editing-design.md` — to Folino for
Android, under the project's two parity rules: **behavior and logic are shared
Swift called from both platforms**, **UI placement follows Android idioms**.

v1 ships an MVP of the feature surface (§10); the remaining keys follow in a
second pass. The v1 *architecture*, however, is the final one — the seams below
are designed for the whole feature, not for the MVP subset, so the second pass
adds intents and Compose keys and nothing structural.

### Non-goals

- Changing iOS behavior. Every iOS-visible change in this design is a refactor
  whose observable output is identical; the existing Editor tests gate that.
- A new editing capability on either platform. Nothing here adds an edit the
  iOS Editor cannot already make.
- PDF-backed scores. A PDF item has no editable `Score`; edit mode stays
  unavailable there, exactly as on iOS.
- Annotation ↔ editing interplay beyond what iOS already does (mutually
  exclusive; ink dims while editing).

## 2. What already exists (verified 2026-08-06)

| Layer | State |
| --- | --- |
| iOS Editor | `Packages/Features/Editor/` — 4,212 lines. ~2,800 of logic (`EditorViewModel` + 5 op extensions + 9 planners), ~1,400 of SwiftUI under `Screens/` and `Views/`. |
| Editing engine | `SheetMusicCore/Editing/` — `ScoreEditor`, `EditCommand` (+ inverse-returning `apply`), and 18 concrete commands. Foundation-only, cross-compiles for Android today. |
| Android score | Held as an opaque `Long` handle owned by ssm's own library `libSheetMusicAndroidJNI.so` (`scoreTable` in `SheetMusicAndroidJNI/JNISymbols.swift`). Layout, page breaks, tap→cursor, MIDI render, cursor rects all key off it. |
| Folino's Android Swift | Ships as **separate** dynamic libraries (`libFolinoReaderJNI.so` etc., `Packages/Features/Reader/Package.swift`). `Domain` depends on `SheetMusicCore`, so `SheetMusicCore` is statically linked into **both** ssm's `.so` and Folino's. |
| Android Reader UI | Compose, 13.4k lines under `Android/FolinoReaderAndroid/`. Renders a draw program decoded from ssm bytes; draws the playback cursor as an overlay from a rect returned by `nativeCursorFrame`. |
| Selection rendering | Exists only in `SheetMusicUI` (Apple/SwiftUI): `Selection/ScoreSelection.swift`, `Selection/SelectionRenderState.swift`, `ScoreHitTester`. Android has none. |
| Bridge idiom | swift-wirelet `@WireletObservable` / `@WireletProvided` + `@WireFormat` TLV, jextract for plain functions. Proven in Library, Settings, Reader (annotation). |

## 3. The constraint everything follows from

Two copies of `SheetMusicCore` live in one Android process — one linked into
ssm's `.so`, one into Folino's. They are the same source at the same version,
but they are different images with different type metadata. **A `Score` cannot
be passed between them; only bytes can.**

Meanwhile the thing that must see every edit — layout, and through it render,
hit-testing and playback — lives behind ssm's handle. So an Android edit session
has an authoritative score on the Folino side and a rendering score on the ssm
side, and the design question is what crosses the gap.

## 4. Chosen design — cross the intent, not the command

**Both sides run the same score-mutating code; only a small scalar "intent"
crosses the boundary.**

A new `ScoreEditSession` in `SheetMusicCore` owns the whole mutate-a-score half
of the feature: an intent vocabulary, the planners that turn an intent into
`EditCommand`s, the accidental renotation that rides along with every apply, and
the undo/redo stacks. Both platforms drive it:

- **iOS** holds one `ScoreEditSession` and calls it directly.
- **Android** holds *two*: the authoritative one inside Folino's `.so`
  (driven by the shared `EditorSessionCore`), and a mirror inside ssm's `.so`
  behind the score handle. Every applied intent is relayed to the mirror as
  bytes, so the mirror's score stays byte-identical and only the layout needs
  recomputing.

Because both sessions run the *same* planning code from the *same* scalar
inputs against the *same* starting score, there is no second implementation to
drift. The only divergence source left is a version mismatch between the two
images, which §8.1 catches at session start.

"The same starting score" is an invariant worth stating: the mirror is seeded
from the score already behind the handle, and the authoritative session is
parsed from the same file bytes by the same parser. That holds because the
Reader's display transforms are *layout options*, not score mutations — the
stored score is untouched by any of them.

Which of those transforms may stay on during a session is settled iOS behavior
and carries over unchanged. **Clef overrides** survive (they replace elements
without inserting or deleting, so positional IDs hold). **Hidden staves**
survive by rendering a filtered score while the session edits and saves the full
one, with items re-stamped across the two addressings — on Android that
re-stamping belongs inside `nativeEditingHitTest` and the caret-frame call,
which already model it for `nativeNearestCursor`. **Notation transpose** and
**multi-measure-rest collapse** do not: they move element numbering in a way no
staff remap can undo, so the session renders with both off, exactly as iOS does
(`ReaderEditingHost.editedScore`).

```
                    Folino .so                    Kotlin                 ssm .so
 pad key ─▶ EditorSessionCore
              │ (caret / selection / arming)
              ├─▶ ScoreEditSession.apply(intent) ── authoritative Score
              └─▶ returns intent bytes ─────▶ applyEdit() ─▶ nativeApplyEditIntent(handle, bytes)
                                                    │                    └─▶ mirror Score
                                                    └─▶ recompute layout ─▶ draw program ─▶ Compose
```

### 4.1 The intent vocabulary

One `@WireFormat` case per score-mutating operation the Editor performs. All
scalar — IDs are four small integers, durations an enum plus dot count:

```
inputNote(at: RestID, pitch: Int, tpc: Int, duration: NoteDuration)
setRestDuration(at: VoiceElementID, duration: NoteDuration)
setChordDuration(at: VoiceElementID, duration: NoteDuration)
delete(at: VoiceElementID)
setNotePitch(at: NoteID, pitch: Int, tpc: Int, accidental: Accidental?)
setAccidental(at: NoteID, accidental: Accidental?)
addNoteToChord(at: VoiceElementID, pitch: Int, tpc: Int, accidental: Accidental?)
removeNoteFromChord(at: NoteID)
setTie(from: NoteID, to: NoteID, sourceTieForward: Int?, targetTieBack: Int?)
createTuplet(at: VoiceElementID, actualNotes: Int, normalNotes: Int)
removeTuplet(at: VoiceElementID)
composite([EditIntent])
```

`composite` exists because several ops are already composites of these
(`delete + retime`, `setChordDuration + setNotePitch`, the tie-chain write).

### 4.2 Why not serialize the commands

The obvious design — relay the `EditCommand` that was applied — forces a wire
codec for **`ReplaceVoiceElements`**, which carries `[VoiceElement] + [Tuplet]`:
a 12-case enum whose `chord` case reaches grace notes, articulations, tremolo,
lyrics and chord lines. Three Folino paths emit it, and one of them is on
*every* edit:

- `MeasureAccidentals.renotationCommands` — bundled onto any edit that changes
  what glyphs the bar needs (`EditorViewModel.applyCommand` → `renotatingAccidentals`)
- `FullMeasureRestCollapse` — a delete that empties a measure
- `CrossBarInputPlanner` — a note written across a barline

Hand-writing that codec is exactly where a silently dropped field would corrupt
the mirror; synthesizing it (`Codable` over ~50 model types) works but puts
round-trip fidelity of the whole score model on the critical path of every
keystroke. Crossing the intent instead deletes the problem: those three planners
run on *both* sides from scalars, and `ReplaceVoiceElements` never leaves the
image that built it.

It also removes the *inverse* command from the wire. `DeleteVoiceElement`'s
inverse necessarily carries the deleted elements — the heaviest payload of all.
With a stateful mirror, `undo` is `nativeEditUndo(handle)`: the mirror's own
`ScoreEditor` holds an identical stack because it was fed identical intents.

### 4.3 Alternatives rejected

- **Re-encode and reload per edit** (Folino authoritative, `nativeLoadScore`
  after every edit; no ssm engine change). Rejected on two counts. Cost: a whole
  score MSCX encode + zip + parse serialized ahead of every relayout — the
  repo's own fixture `testMidiPort.mscx` is 1.03 MB. Worse, `_scoreHandle` is a
  `StateFlow` that MIDI render, timeline summary, metronome, rehearsal marks and
  parts/staves all key off (`ReaderViewModel.kt`), so a new handle per keystroke
  re-fires the entire pipeline and makes iOS's "edit while playing" behavior
  unimplementable. **Kept as the recovery path** (§8.3) — where it is exactly
  right, because it is a full resync.
- **Relay serialized commands** (§4.2). Rejected: same runtime shape as the
  chosen design but with a model-wide codec as a permanent fidelity risk.
- **Move planners to ssm *and* expose only high-level ops, keeping no Folino
  session** (Folino queries score facts through JNI reads). Rejected: the caret /
  selection / arming state machine reads the score constantly
  (`armFromSelectionIfNeeded`, `canTie`, `isCaretInTuplet`, the callout's length
  readout), and each read becomes a JNI round trip. A local authoritative
  session makes all of them free.
- **Compute the edit-session layout inside Folino's `.so`** (link
  `SheetMusicLayout` there; no mirror at all). Genuinely tempting — it deletes
  the wire entirely — but it forks the score-handle concept in two for the
  duration of a session, so every Kotlin path that keys off `_scoreHandle`
  (render, hit test, page breaks, transport) needs a branch, and it duplicates
  megabytes of layout code and SMuFL tables into a second `.so`.
- **Merge the two `.so`s into one library.** Probably the right end state — it
  dissolves the two-copy problem and the latent duplicate-symbol hazard the app
  already lives with — but it is a cross-repo build project (per-library
  jextract/wirelet codegen, the ssm example app's own `.so`, the `JNI_OnLoad`
  ordering traps) and a CLAUDE.md-level architecture change. Not a gate on this
  feature. Noted so it isn't rediscovered.

## 5. Changes in swift-sheet-music

Landed first, on its own, and tagged; Folino then re-pins (both `Package.swift`
and `project.yml`). Nothing here is Folino-specific.

### 5.1 `ScoreEditSession` (new, in `SheetMusicCore/Editing/`)

Wraps `ScoreEditor` and becomes the single entry point for mutating a score
under edit:

```
public final class ScoreEditSession {
    public init(score: Score)
    public var score: Score { get }
    public private(set) var lastAffectedLocation: VoiceElementID?
    @discardableResult public func apply(_ intent: EditIntent) -> Bool
    public func undo() -> Bool
    public func redo() -> Bool
    public var canUndo / canRedo: Bool
}
```

`apply` does what `EditorViewModel.applyCommand` does today: plan the intent
into command(s), bundle the accidental repairs `MeasureAccidentals` says the
post-edit bar needs into one `CompositeEditCommand` (one undo step), apply, and
swallow `SheetMusicError.invalidEdit` as a no-op. This is the choke point both
platforms share.

The planning nuances move with it, and each is load-bearing: a note written
inside a tuplet must **not** carry its duration change into the composite (the
engine refuses the length change and the refusal takes the note write down with
it); a rest that fills its bar is `.measure`, not `.whole`, on both the delete
side and the write side; and `SetRestDuration` early-returns without writing
when source and destination ticks match, so `.whole` → `.measure` cannot be
expressed as a duration change alone.

Moved from Folino into `SheetMusicCore` with their tests, unchanged apart from
`import`s (all seven import only `Foundation` + `SheetMusicCore`, verified):
`MeasureAccidentals`, `CrossBarInputPlanner`, `FullMeasureRestCollapse`,
`NoteInputPlanner`, `TiePlanner`, `IntervalPlanner`, `StaffStepPitch`.

Not moved — these read the score for the UI rather than mutate it, and Folino's
side has a local score to read: `SelectionRederivation`, `ElementNavigator`,
`NoteNameFormatter`, `EditorFileFacts`.

### 5.2 Selection and editing geometry → platform-neutral

`Selection/` moves out of `SheetMusicUI` into `SheetMusicLayout`
(`ScoreSelection`, `ScoreHitTester` + marquee, and the ID-expansion half of
`SelectionRenderState`; `CGColor` resolution stays Apple-side). This is not
optional: the Editor imports `SheetMusicUI` today solely for these types, and
that import is what stops the shared core from compiling for Android at all.

Two behaviors currently living in Folino move down with them, so iOS and Android
run one implementation:

- **`LayoutDocument.editingHitTest(atMm:activeVoice:)`** — the ladder plus
  Folino's policy from `EditorViewModel+HitTest.swift`: reduce stem/flag/beam to
  their first notehead, drop `.clef`, prefer the active voice within a 44-point
  slop box, rescue a near miss **only when the point is on a staff band**, and
  otherwise answer "nothing" so a tap on paper deselects.
- **`LayoutDocument.editingCaretRect(for:)`** — the insertion bar's rect,
  narrowed to the staff band via `system.staffOrigins`, today in
  `Reader/Views/EditingSelectionOverlay.swift`.

### 5.3 JNI surface (`SheetMusicAndroidJNI`)

| Entry point | Purpose |
| --- | --- |
| `nativeBeginEditSession(scoreHandle) -> Bool` | Attach a mirror `ScoreEditSession` to the handle's score. |
| `nativeApplyEditIntent(scoreHandle, intentBytes) -> Bool` | Apply one intent to the mirror. |
| `nativeEditUndo(scoreHandle) -> Bool` / `nativeEditRedo(...)` | Drive the mirror's own stacks. |
| `nativeEndEditSession(scoreHandle)` | Drop the mirror. |
| `nativeScoreFingerprint(scoreHandle) -> Int64` | Divergence check (§8.3). |
| `nativeEngineVersionStamp() -> Int64` | Version-skew gate (§8.1). |
| `nativeEditingHitTest(scoreHandle, xMm, yMm, activeVoice, optionsBytes) -> Data` | Tap → `ScoreItemID`, re-addressed past hidden staves the way `nativeNearestCursor` already models. |
| `nativeEditingCaretFrame(scoreHandle, itemBytes) -> Data` | Caret rect, and the anchor rect the callout is positioned from. |
| `nativeEncodeDrawProgram(scoreHandle, selectionBytes) -> Data` | Re-encode the cached layout's draw program with the selected IDs recolored — **no relayout**, so selecting a note doesn't re-engrave the score. |

`Score.stableFingerprint: Int64` (new, `SheetMusicCore`) is a deterministic
FNV-1a walk of the value tree. Deliberately **not** `Hashable`/`Hasher`: that is
seeded per process, which is meaningless across two runtime images.

## 6. Changes in Folino

### 6.1 `EditorSessionCore` — the shared half of the view model

`EditorViewModel` splits. The platform-neutral part becomes `EditorSessionCore`
in a new target `Packages/Features/Editor/Sources/EditorCore/` (Foundation +
`SheetMusicCore` + `Domain` only, no SwiftLint build-tool plugin — it is
cross-compiled, mirroring `ReaderAnnotationCore`):

- the `ScoreEditSession` and its lifecycle (`beginSession` / `endSession`)
- caret and selection, and the split between them that makes a run of input work
  (`place(selection:caret:)`, `rederiveSelection`, `SelectionRederivation`)
- arming state (duration, dots, tuplet size, add-to-chord), active voice
- the op vocabulary the UI calls (`inputNote(letter:)`, `armDuration(_:)`,
  `deleteSelection()`, `stepPitch(_:)`, …), each returning the intent it applied
  so the Android relay can forward it
- autosave scheduling and the save-destination policy

The iOS `EditorViewModel` becomes a thin `@Observable @MainActor` adapter over
it, keeping the Apple-only concerns: the `generation` /
`appliedEditCount` dependency bumps, the `UndoManager` trampoline, the
`selectionAnchor: CGRect` mirror, `documentProvider` / `displayToSourceItem`,
and the `onScoreChanged` / `onSelectionChanged` closures the composition root
wires.

What does not lift, and what happens to it:

| Blocker | Resolution |
| --- | --- |
| `import SheetMusicUI` (`EditorViewModel`, `+HitTest`) | Gone with §5.2. |
| `@Observable` / `@MainActor` / `UndoManager` | Stay in the iOS adapter. Android drives `undo()` / `redo()` from toolbar buttons and projects state via `@WireletObservable`. |
| `selectionAnchor: CGRect` | iOS presentation plumbing. Android derives the anchor from `nativeEditingCaretFrame` plus its own viewport transform. |
| `EditorFileFacts` uses CryptoKit | Absent on Android. Route hashing through a Kotlin-supplied callback, as `LibraryAndroidStore` already does for import. |
| `NoteNameFormatter` uses `String(localized:bundle:.module)` | An xcstrings bundle does not ship inside a `.so`. Split: the spelling math (letter / octave / glyph from tpc) stays shared and returns structured parts; Android assembles the readout from its string resources under the existing localization key scheme. |
| `PadDurationGlyph` SMuFL composition | The codepoint tables and the metronome-glyph trick (`metNoteWhole` + `metAugmentationDot` in one run, because engraving glyphs carry only notehead advance) move into the shared core; drawing stays per-platform. Compose renders the same Bravura face. |
| Audition | The *decision* to audition stays in the core; `PlaybackController` is already a Domain protocol, so Android supplies an implementation over its existing synth path. |
| Saving | `saveDestination` is pure and lifts as-is (`.mscx`/`.mscz` in place, everything else as a sibling `.mscz`). The write itself becomes shared Swift — MSCZ encode plus a POSIX write to a path Kotlin supplies — with the Room row refreshed through a wirelet callback. |

### 6.2 `FolinoEditorJNI` — the Android bridge

A new Android-gated dynamic library target in the Editor package, following the
`FolinoReaderJNI` shape exactly:

- `@WireletObservable EditorBridge` holding one `EditorSessionCore`, exposing
  the op vocabulary and projecting the state Compose needs (caret item,
  selected item, armed duration and dots, active voice, `canUndo` / `canRedo`,
  `hasEditTarget`, `isNoteSelected`, the callout's length summary).
- `@WireletProvided` for the two things only Kotlin can do: SHA-256 of a file,
  and the score file's bytes / destination path.
- `@WireFormat EditIntentWire` — the §4.1 vocabulary, and the `ScoreItemID` /
  `VoiceElementID` / `NoteDuration` / `Accidental` scalars it is built from.

Two traps already recorded in project memory and designed around here:
`Task { @MainActor in … }` never runs in a Swift-on-Android JNI process (no
main runloop is pumped), so anything an op must complete synchronously uses the
`DispatchSemaphore` idiom rather than a `MainActor` hop; and wire arrays come in
two incompatible framings (`[T](decoding:)` = length-prefixed bytes,
`WireletList` = varint count), so `WireArray.kt` is the only encoder used for
JNI byte arrays.

## 7. Android UI

Contextual app bar plus an inline bottom pad — Android's own idiom for a
persistent input surface, and the reason a `ModalBottomSheet` was rejected: its
scrim hides the very score you are writing into.

- **Entering edit mode** swaps the Reader's `TopAppBar` actions for the editing
  set: undo, redo, and a ✓ that ends the session. Back / system-back also ends
  it (flushing the pending save first).
- **A fixed bottom bar** carries the voice selector and the pad toggle. The pad
  opens inline above it — no scrim, the score is inset upward rather than
  covered. Default closed, exactly as on iOS.
- **The pad** targets the iOS content: a durations row (5 values + tuplet + tie
  + dot) and a pitch row (C–B + rest). v1 ships the durations (with the dot) and
  the pitch row; the tuplet and tie keys arrive with the second pass in the slots
  already reserved for them. Two rows on a phone; the row split adapts to
  available width rather than to a size class, mirroring the iOS `ViewThatFits`
  fix (an iPad mini stayed "regular" while being 400pt narrower, and the one-row
  layout clipped).
- **The callout** stays: a small surface pinned to the selected note showing the
  length summary and the pitch chevrons, positioned from
  `nativeEditingCaretFrame`. Its conditional tie key follows in the second pass.
- **← / →** sit next to the existing transport row, not in the pad.
- **Selection tint** is drawn by the draw program (§5.3), so a selected notehead
  recolors exactly as it does on iOS. **The caret** is a Compose overlay bar,
  drawn like the existing playback cursor, using `BlendMode.Multiply` so it
  reads as behind the notation rather than on top of it.

Everything a user can read stays at iOS content parity; only placement moves.

## 8. Error handling

### 8.1 Version skew — refuse rather than diverge

Folino's linked `SheetMusicCore` and the `.so` behind the handle must be the
same build. A stale `.so` has bricked this app before
(`project_android_sheetmusic_aar_version_skew`). At session start Folino
compares its compiled-in stamp with `nativeEngineVersionStamp()`; on mismatch
edit mode does not open and the Reader stays read-only with a message. This is
the one check that must run before any intent is applied.

### 8.2 A refused edit

`ScoreEditSession.apply` returns `false` and leaves the score untouched (the
engine's contract). The op returns no intent, so nothing is relayed and the two
sides stay in step. No user-facing error, matching iOS.

### 8.3 Divergence — detect, then resync

After each applied intent (sampled — every Nth edit, with N fixed in SP3 against
the measured walk cost, plus on undo/redo and always before a save) Folino
compares `session.score.stableFingerprint` with
`nativeScoreFingerprint(handle)`. On mismatch: log an analytics event, then
resync by encoding the authoritative score, calling `nativeLoadScore`, and
swapping the handle. Divergence becomes a logged hiccup rather than a corrupt
session.

The property that makes this safe to ship: **the mirror never feeds
persistence.** Saves always encode Folino's authoritative copy, on the same path
iOS uses. Undetected drift can mis-render or mis-play; it cannot corrupt a file.

### 8.4 Save failure

Unchanged from iOS: `isDirty` stays true so the next debounce tick or the
session-end flush retries. Android additionally flushes on `onPause`, the way
the annotation save coordinator already does.

## 9. Testing

- **Shared logic, host tests.** The seven planners keep their existing tests,
  moved to ssm. `ScoreEditSession` gets the apply-choke-point tests currently
  written against `EditorViewModel` (accidental renotation bundling, refused
  edits, `.measure` vs `.whole` rests). Folino's `EditorCore` keeps the
  caret/selection, arming, navigation and rederivation suites — that is most of
  the 20 existing Editor test files, and they are the gate on the §6.1 split.
- **Wire round-trip, ssm.** Per intent case: encode → decode → apply equals
  direct apply.
- **Replay determinism, on device.** The SP0 acceptance test: drive a scripted
  sequence of ~100 intents (including undo/redo and a cross-bar input) through
  both sessions and assert `stableFingerprint` equality after every step. This
  is what proves the whole design, and it is why SP0 comes first.
- **Android instrumented smoke.** Enter edit mode, write a bar, delete a note,
  undo twice, redo, leave, reopen — assert the file round-trips.
- **Device verification.** Editing is a gesture- and latency-sensitive feature;
  the final gate is the user on the physical Pixel, as with annotation Phase 2.

## 10. Scope

**v1 (MVP).** Selection and caret; tap to select; arming a duration (with dots);
writing notes and rests; delete; pitch step up/down; voice switching; undo/redo;
autosave including the sibling-`.mscz` policy; the contextual app bar, the pad
and the callout.

Note that `setAccidental` is in the v1 *wire* even though the ♯/♭ keys are not
in the v1 *UI*: `apply` bundles accidental repairs onto every edit, so the
intent must exist from the start or the glyphs go wrong.

**Second pass.** Chords (add / remove tone), ties including the cross-bar
chain, tuplets, the explicit ♯/♭/♮ keys, audition on input, and the
`hoverItem` pre-highlight (stylus-dependent; may stay iOS-only).

**Out of scope, tracked elsewhere.** `project_android_transpose_folino_wiring_pending`
— the transpose wiring is still missing on the Folino side. It is not part of
this feature, but the session lifecycle built here is the natural place to
finally wire it, and SP3 should at minimum not make it harder.

## 11. Decomposition

Each of these is its own plan; the riskiest unknown is first, and the two ssm
sub-plans land and tag before Folino consumes them.

- **SP0 — determinism spike (ssm, lands alone).** `EditIntent` + `@WireFormat`
  wire for a vertical slice (input, duration, delete), `ScoreEditSession`,
  `stableFingerprint`, the version stamp, and the four session JNI entry points.
  Acceptance: the on-device replay test of §9. This retires the three real
  unknowns — replay determinism across two static copies, the wire shape, and
  the mirror's undo stack — before any Folino code moves.
- **SP1 — ssm: planners, selection, geometry.** Move the seven planners in;
  relocate `Selection/` to `SheetMusicLayout`; add `editingHitTest`,
  `editingCaretRect`, the remaining intents, and the draw-program tint +
  `nativeEncodeDrawProgram`. iOS is refactored onto the relocated types in the
  same pass and must stay behavior-identical. Tag at the end.
- **SP2 — Folino: extract `EditorCore`.** iOS-only, pure refactor, gated by the
  existing Editor tests. Cuts the hashing, localization and audition seams.
  Re-pin to the SP1 tag.
- **SP3 — Android session plumbing.** `FolinoEditorJNI`, the Kotlin relay as
  *one* function (local apply → `nativeApplyEditIntent` → fingerprint sample →
  trigger relayout) so it cannot be half-called, plus the §8 gates and recovery.
- **SP4 — Compose UI.** Contextual app bar, bottom bar, pad, callout, caret
  overlay, selection tint wiring.
- **SP5 — persistence and verification.** Shared save path, Room row refresh,
  autosave debounce and `onPause` flush, sibling-`.mscz` parity, instrumented
  smoke, device pass.
