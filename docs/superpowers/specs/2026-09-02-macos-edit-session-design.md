# Mac Editing, Part 1: the always-editable score (Sub-project Ⅳa) — Design

**Date:** 2026-09-02
**Status:** approved in conversation (2026-09-02); this document is the written form
**Parent:** `2026-08-31-macos-app-design.md` (umbrella, §2.2 keyboard, §2.3 command spine, §5.2 selection vs.
playback, §9 sub-project Ⅳ)
**Revises:** `2026-09-01-macos-library-window-redesign-design.md` §2.3 / §2.4 (one window per score — §3 below)

Sub-project Ⅳ ("Mac editing UI") is too large for one plan. This document is the first of four slices:

| | Slice | What it delivers |
| --- | --- | --- |
| **Ⅳa** | **this document** | The Mac score window is editable from the moment it opens: click selects, the keyboard writes notes, every existing edit command has a menu item, undo / redo / revert are in the menus. No panels. |
| Ⅳb | command registry and search | One command table drives menus, key equivalents and the searchable command sheet (`Z`); the iPad menu bar (`UIMainMenuSystem`, iOS 26+) and the iPhone search floor. |
| Ⅳc | panels | Mixer (`⌘3`), properties (`⌘2`), drum pad overlay (`O`), piano (`P`), palette (`⌘1`). |
| Ⅳd | consuming ssm sub-project Ⅰ | Each landed group of new edit commands becomes registry rows, menu items and palette entries. |

Ⅳa stands on its own: after it, a Mac can open a score from the library, edit it, and have the edit saved and
undoable — with no panel, no search and none of Ⅰ's new commands. It merges to `main` on its own.

---

## 1. The decision: no edit mode on the Mac

iOS has an explicit edit session — 音符入力 enters, 完了 leaves, and the pad, the callout and the top strip exist
only inside it. That is the right shape for a touch reader: most of the time a phone or an iPad is a music stand,
and the editing chrome would be in the way.

**The Mac is Keynote, not Preview.** A score window is editable from the moment it opens, with no mode to enter
and no button to leave. This is also MuseScore's shape, so a user arriving from MuseScore finds nothing to unlearn.
Concretely:

- There is no 編集 / 完了 pair anywhere in the Mac UI.
- Clicking a note selects it. Typing a letter writes a note. `⌘Z` undoes it. Nothing has to be armed first.
- The score is saved automatically as it changes, exactly as iOS already does inside a session (2 s debounce,
  `EditorViewModel+Persistence`). **Autosave is not a departure from Keynote; it is Keynote.** macOS Auto Save has
  been the document model since Lion: the title bar shows "Edited", the file is written without a save command, and
  File ▸ Revert To is how you go back. folino's library-based identity (umbrella §1) removes even the one
  Keynote state that isn't autosaved — there is no untitled document to discard on close, because every score the
  window can show already lives in the library. Collaboration (Ⅵ) needs autosave regardless.

### 1.1 What this does to the Editor: nothing

The whole session machinery in `Packages/Features/Editor` — `beginSession` / `endSession`, the retained undo history
(`ScoreEditHistoryStore`), the autosave debounce, `discardSessionEdits`, `revertToOriginal`, the part-index migration
and its hold on the Reader's preference writes — is keyed on a *session*, and none of it cares how long a session is
or what starts it. On iOS a session is 音符入力 → 完了. **On the Mac a session is the window's lifetime**: it begins when
the score has loaded and ends when the window closes. Every mechanism above carries over unchanged, including:

- **Undo across closes.** `endSession` retains the session's history (`shouldRetain`), and `beginSession` adopts it
  when the same score is opened again with the same content hash. Closing a score window and reopening it later
  resumes `⌘Z` where it left off, for as long as the process lives — the same behavior the iOS cross-session undo
  work built (`2026-08-19-cross-session-undo-design.md`), now visible as "close the window, open it again, undo".
- **Discard.** `discardSessionEdits` — unwind to the session's opening score — becomes exactly Keynote's
  File ▸ Revert To ▸ Last Opened (§5.3).
- **The iOS edit mode is untouched.** `ReaderRootScreen` and `EditableReaderScreen` are not modified. The
  `ReaderEditingHost` seam is reused as-is; only what the Mac writes into it differs (§2).

---

## 2. Composition: the Mac sibling of `EditableReaderScreen`

`App/iOS/EditableReaderScreen.swift` is the one place the Reader and Editor features meet on iOS: it owns one
`ReaderEditingHost` and one `EditorViewModel`, wires the two by closure, and hands the host into
`ReaderRootScreen`. The Mac gets a sibling, `App/Mac/MacEditableReaderScreen.swift`, that does the same for
`MacReaderRootScreen`. The rule from the shell spec (§2.4, "divergence is expressed as paired files") applies.

**Shared, not copied.** The closure wiring in `EditableReaderScreen.wireOnce()` / `wirePartEditSeams` is ~120
lines of seam plumbing that is platform-neutral and must not drift between the two shells. It moves to
`App/Shared/ReaderEditingWiring.swift` as a free function `wireEditingSeam(host:viewModel:repository:analytics:)`,
called by both screens. `EditableReaderScreen` keeps its chrome builders (pad, top strip, cutout tier); the Mac
screen builds none of them.

**What the Mac writes into the host that iOS does not:**

| Host property | iOS | Mac |
| --- | --- | --- |
| `isEditing` | toggled by 音符入力 / 完了 | set `true` once the score has loaded; never `false` while the window lives |
| `onBeginEditing(score)` | on 音符入力 | on load (`MacReaderRootScreen.task`, after `viewModel.load()`) |
| `onEndEditing()` | on 完了 | on window close (`onDisappear`), after the annotation flush the screen already does |
| `editingChromeTopInset` / `BottomInset` | measured from the chrome | `0` — there is no chrome |
| `noteInputPadFrame` / handle frame / pad-use counters | from the pad | never written; the coach marks that read them are iOS-only |
| `onSelectionAnchorChanged` | drives the floating callout | wired to the view model but nothing draws a callout (§4.4) |

`MacReaderRootScreen` gains one parameter, `editingHost: ReaderEditingHost? = nil`. `nil` keeps today's read-only
reader, which is what previews and the existing 508 Reader tests get. `MacShellView` always passes a host.

**The view model is built from the same adapters the iOS shell passes**, including `bootstrap.editHistoryStore`
(the process-wide `ProcessScoreEditHistoryStore`) and the annotation store for ink migration.

### 2.1 Process termination

`endSession` flushes the 2 s autosave debounce. A window close reaches it through `onDisappear`; quitting the app
does not reliably, and an edit made within two seconds of `⌘Q` would be lost. The Mac app adopts an
`NSApplicationDelegateAdaptor` whose `applicationShouldTerminate` returns `.terminateLater`, flushes every open
editor, then `reply(toApplicationShouldTerminate: true)`. The open editors are reached through the same registry
the window dedup needs (§3.1). This is the one piece of AppKit lifecycle the shell has to own; it is small and it
is not optional.

---

## 3. One window per score

The library-window spec (§2.3 / §2.4) let the same score open in several windows: `MacWindowScore.tabInstance` was
added purely to defeat `WindowGroup(for:)`'s deduplication, and File ▸ Open in New Window plus a row-menu item and
⌥-double-click were built on it. **Always-editable reverses that decision**, and this document revises those two
sections.

**Why.** With an explicit edit mode, two windows on one score were two readers and at most one editor. Without one,
they are two editors of one file. Keeping that coherent means one shared `EditorViewModel` per score with windows
attaching and detaching, a selection and an undo stack that span windows (undo in window A changes window B), and
two windows contending for the one playback position. None of that buys anything the user asked for: the only
real use of a second window on the same score is seeing two distant places at once, and that is better served by
a split view inside one window (MuseScore 3's Documents Side by Side, Dorico's split), which draws one view model
twice and never raises the ownership questions. That is recorded as Ⅳ polish, after Ⅳc.

**What MuseScore does.** MuseScore 4 refuses to open a project twice: `ProjectActionsController::openProject`
step 3 checks `isProjectAlreadyOpened` and calls `activateWindowWithProject` on the existing window
(`src/project/internal/projectactionscontroller.cpp:251-254`); there is no New Window command. MuseScore 3 had one
tab per score and switched to the existing tab. Keynote, Pages and Preview are one window per document. Dorico and
Sibelius offer Window ▸ New Window, and that is the split-view use case above.

**The change.**

- `MacWindowScore` loses `tabInstance` and becomes `scoreID` alone. `WindowGroup(for:)` then does the MuseScore 4
  thing natively: opening a score that is already open brings its window (or tab) forward.
- File ▸ Open in New Window is removed from `MacCommands`. The row-menu **Open in New Window** item and the
  `onOpenInNewWindow` parameter it feeds are removed from the Library package (12 files carry the parameter — the
  seven screens, `LibraryRootDestinations`, `MacLibraryBrowser`, `RowOpenAffordance`, `ScoreListView`,
  `PlaylistDetailView`, `RecentlyDeletedView`). ⌥-double-click, which was never built, is no longer owed.
- Everything else in §2.3–§2.5 of the library-window spec stands: a *different* score still opens as a tab of the
  frontmost score window, the browser recedes, playback takes over across windows, display mode stays global.

### 3.1 The per-process editor registry

Even with one window per score, the app needs to find every live editor at quit time (§2.1), and a window that is
closed and reopened must not race its predecessor's `endSession` flush. A small `@MainActor` registry in
`App/Mac`, keyed by `ScoreItem.ID`, holds each open window's `EditorViewModel` from `onBeginEditing` to the end of
`endSession`. `MacEditableReaderScreen` registers and unregisters; `applicationShouldTerminate` iterates. It is
bookkeeping, not a shared-editor scheme: with dedup in place there is never more than one entry per score.

---

## 4. Selection, caret and the playhead

### 4.1 Click selects

All three Mac surfaces — `MacVerticalScoreSurface`, `MacHorizontalScoreStrip`, `MacScorePage` in the page deck —
already draw a `ScoreView` and carry a click-to-seek `SpatialTapGesture`. Each gets the same three additions the
iOS `VerticalZoomedSurface` has:

1. `ScoreView(selection: host.displaySelection, voiceColors: ReaderEditingPresentation.voiceColors, …)`.
2. The gesture routes to `host.onTap(point)` when `host.wantsScoreTaps`, and to `setManualCursor` otherwise
   (the existing rule: editing owns the click except while the transport is running).
3. `EditingSelectionOverlay(host:score:document:)` as the last `ZStack` child, and `editingDeselectCatcher(host:)`
   behind the padded surface so a click on empty paper deselects.

Hit-testing needs nothing from ssm sub-project Ⅱ: `LayoutDocument.editingHitTest(at:activeVoice:)` is the shared
resolver the iOS and Android hosts already use, and the Mac surfaces hand it document-space points already.

**The edited score is what gets engraved.** `ReaderRootScreen.editingScore` derives the rendered score from
`host.editedScore` (clef overrides and hidden staves applied, transpose pinned to 0, multi-measure-rest collapse
off — the transforms a `StaffAddress` remap can undo) and `editingScoreVersion` keys the relayout on
`host.editGeneration`. Both are private to the iOS screen. They move to a shared `ReaderEditingDisplay` helper in
the Reader package (Feature-internal, platform-neutral) that `MacScoreContentView` calls too; the iOS screen keeps
its two computed properties as one-line forwarders. The Mac layout keys (`MacScoreLayoutKey`) gain the version, the
same way the iOS containers' keys carry it — the doc comment on `editingScoreVersion` records the bug that
follows from reading `editGeneration` in the container instead.

### 4.2 Selection is the playback start position

Umbrella §5.2 decides it: *selection sets the playback start position, nothing else, and all staves always sound.*
On iOS the two marks are kept apart — selecting a note puts the playhead away (`onSelectionMade`), because a
playhead and a selection on the same note read as one confused mark. On the Mac the resolution is the opposite
one: **the selection *is* the playhead while the transport is stopped.**

- The mechanism is the one iOS already has, installed by the Mac screen's `.task` exactly as `ReaderRootScreen`
  installs it: `onSelectionMade` puts the displayed cursor away (`playbackSession.hideDisplayedCursor()`), and
  `playbackSession.startCursorProvider` answers the selected item, so Space plays from the selected note. This is
  the MuseScore 3 / 4 behavior a user expects on a keyboard.
- While stopped, the surfaces therefore draw the selection tint and the caret only. While playing or scrubbing, the
  playback cursor is drawn as today and the selection tint stays (editing keys are inert during playback anyway,
  per `EditorViewModel.isPlaybackActive`).
- Esc deselects (MuseScore). A click on paper deselects (§4.1). Deselecting does not move the playhead.

### 4.3 The caret

The insertion caret (`caretItem`) is drawn by `EditingSelectionOverlay` exactly as on iOS. `←` / `→` move the
selection to the previous / next element (`selectPreviousElement` / `selectNextElement`), which is also what
carries the caret along a run of input.

### 4.4 What the keyboard replaces

The iOS floating callout (pitch steps, next duration) and the pad exist because a touch surface has no keys. On the
Mac they are not drawn: pitch is `↑` / `↓`, duration is a digit, and the drum pad returns as a panel in Ⅳc. The
`SelectionCalloutLayer` and `EditorChromeView` are not mounted; `onSelectionAnchorChanged` is still wired so the
view model's `selectionAnchor` is correct for anything later (a properties popover, say) that wants it.

---

## 5. The menu bar is the complete index

Umbrella §2.3: every command has a home in the menu bar, and the menu bar is what makes the design extensible. Ⅳa
lays down the menus for the commands that exist today; Ⅳb turns the same content into a data table and Ⅳd appends
Ⅰ's commands to it. Because Ⅳb will consume what Ⅳa builds, **Ⅳa already declares each command once**, as a value
in a small enum-backed table in `App/Mac/MacEditingCommands.swift` — `(id, title key, key equivalent, group,
isEnabled(context), perform(context))` — and the menu is generated from the table. Ⅳb generalizes the table, it
does not replace it.

### 5.1 Menus and what goes in them

| Menu | Items (existing `EditorViewModel` operations) |
| --- | --- |
| **File** | Revert To ▸ Last Opened (§5.3), Revert To ▸ Original (§5.3). Import / Show Library are unchanged; Open in New Window is removed (§3). |
| **Edit** | Undo, Redo (§5.2). Deselect (Esc). |
| **Notes** | Pitch: A–G (`inputPitch`); Up / Down a semitone (`shiftPitch`), Up / Down an octave (`shiftOctave`); Accidental ▸ ♭♭ ♭ ♮ ♯ 𝄪 / None (`setAccidental`). Duration ▸ whole … 64th (`setSelectionDuration` when something is selected, `setDuration` to arm otherwise), Dot / Double dot (`setSelectionDots` / `setArmedDots`), Rest (`writeRest`). Chord ▸ Add note above A–G (`toggleAddToChord` + letter), Add interval ▸ 2nd–9th (`addIntervalNote`), Remove note from chord (`removeSelectedNoteFromChord`). Tie (`toggleTie`), Tied note (`appendTiedNote`). Tuplet ▸ Triplet … Nonuplet (`createTuplet`), Remove tuplet (`removeTuplet`). Delete (`deleteSelection`). Previous / Next element. Voice ▸ 1–4 (`activeVoice`). |
| **Measures** | Add measure at end / Add measures… (`appendMeasure(s)`, the existing `EditorAddMeasuresSheet`), Insert measure before / Insert measures before… (`insertMeasure(s)BeforeTarget`), Delete measure (`deleteTargetMeasure`). Key signature… / Time signature… / Rehearsal mark… (the existing sheets). |
| **Score** | Instruments… (`EditorInstrumentsSheet`: parts add / remove / reorder / rename, staff visibility). |
| **View** | Display Mode (existing). |
| **Playback** | Play / Pause is the transport's own Space (measured in `MacTransportBar` — see its doc comment for why it is a button shortcut and not a menu item). Ⅳa adds nothing here. |

> **Revised 2026-09-02 during implementation:** the Notes row's "Add interval ▸ 2nd–9th" describes an engine command
> that does not exist — `DiatonicInterval` (`SheetMusicCore`) offers only `.third` and `.octave`, so the Chord ▸ Add
> interval submenu has two rows (`MacEditingCommands.swift`'s `intervalCommands`) until sub-project Ⅰ / Ⅳd adds more.
>
> **Revised 2026-09-02 during implementation:** the Score menu's item is titled "Drum Keys…"
> (`MacEditingCommands.swift`'s `score.drumLayout`), matching the Editor package's `editor.drum.layout.title`, not
> "Drum Pad Layout…".

Drum staves: when the caret is on a drum staff, the letters bound in the current `DrumPadLayout`
(`DrumsetEntry.shortcut`) go to `pressDrumKey` instead of `inputPitch`. The table's `perform` reads the view model's
`caretColumn` to decide; the Notes menu shows the pitch commands disabled on a drum staff. The pad itself, with its
notation previews and the layout editor, is Ⅳc.

> **Revised 2026-09-02 during implementation:** routing letters to `pressDrumKey` is deferred to Ⅳc — `DrumPadKey`
> carries no shortcut and no `GMDrumset` entry defines one, so there is nothing to resolve a letter to today. Ⅳa
> implements only the second half of this paragraph: on a drum staff the Notes ▸ Pitch rows are disabled
> (`MacEditingCommands.swift`'s `pitchCommands`).

**Sheets are still sheets.** The signature, rehearsal-mark, add-measures, drum-layout and instruments sheets compile
on macOS today and are presented from the menu command through the view model's presentation flags, installed once
by a public `editorSheets(viewModel:)` modifier the Editor package gains. All of them already place their buttons
with the semantic `cancellationAction` / `confirmationAction` placements (measured: every `ToolbarItem` in
`Packages/Features/Editor/Sources/Editor/Views/*Sheet.swift`), so Esc and Return work on the Mac without the
per-screen migration the shell spec deferred to "M6".

### 5.2 Undo / redo

`EditorViewModel` already bridges its session stacks to a system `UndoManager` with trampolines
(`registerSystemUndo(with:)`), re-registered per mutation by the iOS chrome. The Mac screen does the same
registration against the window's `undoManager` (from `@Environment(\.undoManager)`), and the standard Edit ▸ Undo /
Redo items — which SwiftUI supplies for a window with an undo manager — drive it. No custom Undo item is added; the
titles come from the system.

### 5.3 File ▸ Revert To

Keynote's Revert To submenu, mapped onto what the Editor already has:

| Item | Editor operation | Semantics |
| --- | --- | --- |
| **Last Opened** | `discardSessionEdits()` | Unwind every edit made since this window opened the score (the session's opening snapshot), and write that. The retained history for the score is dropped, as on iOS. |
| **Original** | `revertToOriginal()` | Restore the file as it was before folino's first edit ever touched it. Same confirmation copy and the same "annotations may move" warning as iOS (`revertWarnings(hasMusicalAnnotations:)`). |

Both are disabled when they would do nothing (`sessionHasEdits` / `hasCapturedOriginal`). Both confirm with the
existing `EditorDestructivePopover` content presented as a macOS alert — not a popover anchored to a toolbar button,
because there is no toolbar button.

---

## 6. The key map

Umbrella §2.2 fixes the vocabulary: note entry, selection and musical terms follow MuseScore exactly. Ⅳa binds the
subset the existing commands can serve.

| Key | Command |
| --- | --- |
| `A`–`G` | write pitch at the caret (`inputPitch`) — or the drum key on a drum staff |
| `⇧A`–`⇧G` | add that pitch to the selected chord |
| `1`–`7` | duration (64th … whole), the same digit table ssm's macOS example uses |
| `.` | dot; `⌥.` double dot |
| `0` | rest |
| `↑` / `↓` | semitone; `⌘↑` / `⌘↓` octave |
| `←` / `→` | previous / next element |
| `+` | tie |
| `⌫` / `⌦` | delete selection |
| `⌘3`…`⌘9` | tuplet of that count on the selection; on a tuplet member, remove |
| `⌘⌥1`–`⌘⌥4` | voice |
| `Esc` | deselect |
| `I` | Instruments… |
| `⌘Z` / `⇧⌘Z` | undo / redo (system) |
| Space | play / pause (existing) |

Not bound in Ⅳa, and why:

- **`N` (MuseScore's note-input mode toggle).** folino's editing model is caret & pad (`2026-07-16-note-editing-design.md`
  §5): letters always write at the caret and there is no mode to toggle. `N` stays unbound rather than bound to
  something that is not what a MuseScore hand expects. Recorded as a decision, not an omission.
- `⌘1` / `⌘2` / `⌘3` / `⌘4` / `⌘0`, `O`, `P`, `Z` — panels and search, Ⅳb / Ⅳc. Note `⌘3`–`⌘9` are tuplets in
  MuseScore and this table keeps that; the umbrella's panel bindings are `⌘0`–`⌘4` and only `⌘3` / `⌘4` collide.
  **Ⅳc resolves the collision in the umbrella's favour for `⌘3` (mixer) and `⌘4` (piano)** and moves triplet /
  quadruplet to `⌘⇧3` / `⌘⇧4`; Ⅳa binds `⌘3`–`⌘9` to tuplets as MuseScore does so nothing has to be unlearned
  twice, and Ⅳc's spec states the final map. (Flagged here so it is decided once, there.)
- Range selection (⇧-click, `⇧←/→`) — needs `VoiceElementRange` and the Range group from ssm sub-project Ⅰ
  (intents 35–40, second group to land). Ⅳd.
- Lyrics (`⌘L`) — no folino command yet.

### 6.1 Where keys are handled, and the one thing to measure first

**Unmodified letters as menu key equivalents steal typing.** AppKit offers a key event to the main menu's key
equivalents before the first responder's `keyDown`, so a menu item bound to a bare `A` would fire while the user is
typing a rehearsal mark into a sheet's text field. Two mechanisms are available, and the plan's first task is a
bench on `~/Developer/_test/MacTest` (the shell's own harness) that decides between them:

1. **Menu items gated by `@FocusedValue`.** The score surface is `.focusable()` and publishes an editing target
   through `focusedValue` (view-scoped, *not* `focusedSceneValue` — a sheet's text field is not a descendant of the
   surface, so the value reads `nil` there and the items disable). A disabled item's key equivalent is not consumed
   and the key reaches the field. If measured true, every command lives in the table once and the menu shows its
   shortcut natively.
2. **`onKeyPress` on the focused surface for unmodified keys**, with the menu items for those commands carrying no
   key equivalent (the shortcut shown as text in the title). Modifier-bearing shortcuts stay on the menu items.

Either way the table in §5 is the single declaration; only the delivery differs. The bench measures (a) that a bare
letter reaches a `TextField` in a sheet while a same-letter menu item exists, (b) that the same letter fires the
command when the score has focus, (c) that `⌘Z` reaches the window's undo manager from both states.

> **Revised 2026-09-02 during implementation:** delivery **B** (`onKeyPress` / `MacEditingKeyMap`) is the provisional
> choice — the bench above is unmeasured. See `docs/superpowers/plans/2026-09-02-macos-edit-session-bench.md` for
> what was actually built and what flipping to A would require.

### 6.2 Playback makes editing inert

Every mutating command is disabled while the transport runs — the table's `isEnabled` reads
`EditorViewModel.isPlaybackActive`, which the Mac screen mirrors from `host.isPlaying` exactly as the iOS screen
does. `MacReaderRootScreen` sets `host.isPlaying` from the playback session, the counterpart of
`ReaderRootScreen.swift:510`. Selection and navigation stay live during playback; a click seeks (§4.1).

---

## 7. Out of scope for Ⅳa

- Panels of any kind: palette, properties, mixer, piano, drum pad. **Ⅳc.**
- Command search (`Z`), the iPad menu bar, the iPhone search floor. **Ⅳb.**
- Range selection and every command from ssm sub-project Ⅰ. **Ⅳd.**
- A split view of one score inside one window (the replacement for same-score windows). Ⅳ polish, after Ⅳc.
- The "Edited" title-bar indicator. The debounce is two seconds; the indicator would flicker. Revisit with Ⅴ.
- Annotation input on the Mac. **Ⅴ.**
- Per-window display mode. Still global (library-window spec §2.5).

---

## 8. Testing

- **Editor package: no new tests.** The session lifecycle is unchanged and already covered; Ⅳa changes when it is
  called, not what it does.
- **Reader package (Swift Testing):** `ReaderEditingDisplay` — the edited-score derivation and version key give
  the same answers the iOS screen's private properties gave (one test each, against the existing fixtures);
  the Mac surfaces' cursor choice (`nil` while stopped with a selection, the cursor while playing).
- **App target (`FolinoTests`, Swift Testing):** the command table — every row has a unique id, a title key that
  resolves, and `isEnabled` false during playback for every mutating row; the editor registry — register on begin,
  unregister after end, and `applicationShouldTerminate` flushes and replies; `MacWindowScore` equality is by
  `scoreID` alone.
- **Build gates:** `Scripts/build-macos-packages.sh`, `Scripts/build-macos-app.sh`, the iOS app build, and the
  Library / Reader / Editor package suites. The Library change (removing `onOpenInNewWindow`) is compile-checked
  on both platforms.
- **Human QA (a sheet in the plan, as Ⅲc had):** the §6.1 bench outcomes reproduced in the real app; a note
  written, undone, redone, autosaved (relaunch shows it), reverted; Space plays from the selected note; a
  rehearsal-mark sheet accepts letters that are also note commands; closing and reopening the window resumes undo;
  `⌘Q` within two seconds of an edit keeps the edit.

---

## 9. Risks this design commits to handling

- **Focus.** Everything in §6 hangs on the score surface actually holding key focus when the user expects it to —
  after a click on the score, after a sheet closes, after the window regains key. `.focusable()` plus an explicit
  `@FocusState` reset at those moments is the plan; the QA sheet checks each.
- **The two-second flush at quit** (§2.1). `.terminateLater` with a flush that never replies would hang quit; the
  flush is bounded by a timeout that replies `true` regardless and logs.
- **Reader-package refactor.** Moving `editingScore` / `editingScoreVersion` out of `ReaderRootScreen` touches the
  iOS screen. The forwarders keep the iOS body byte-equivalent in behavior; the 508 Reader tests and the iOS app
  build are the gate.
- **Library-package removal.** Deleting `onOpenInNewWindow` from 12 files is mechanical but wide; the Library suite
  (129) and both platform builds gate it.
- **Menu shortcut collision with `⌘3` / `⌘4`** is deferred to Ⅳc deliberately (§6); nothing in Ⅳa binds a panel.

---

## 10. Documents this revises

- `2026-09-01-macos-library-window-redesign-design.md` §2.3 / §2.4 — one window per score; Open in New Window and
  ⌥-double-click removed. A short "Revised 2026-09-02" note is added there pointing here, the way §5.3 of the
  umbrella was annotated.
- `2026-08-31-macos-app-design.md` §9 — sub-project Ⅳ is now four slices (the table at the top of this document);
  the row is updated to say so and to point here.
- `docs/engineering/ios-android-parity.md` — regenerated as `PARITY(macos)` markers on the pad / callout /
  edit-mode chrome are reworded from "not yet" to "not on this platform, by design" where §4.4 applies.
