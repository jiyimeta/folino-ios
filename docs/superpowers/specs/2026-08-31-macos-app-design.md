# folino for macOS — Umbrella Design

**Date:** 2026-08-31
**Status:** Approved direction. Sub-project specs and implementation plans to follow.
**Scope:** What folino for macOS *is* — how it relates to the iOS/Android apps, what it takes from MuseScore and what it deliberately changes, how far editing goes at launch, how annotations travel as files, and how the work decomposes.

This is an umbrella spec. It records the framing decisions and the sub-project breakdown; every sub-project below gets its own spec (where the design is non-trivial) and its own implementation plan before code is written.

**Reference implementation: MuseScore.** Behavior and UX only — MuseScore is GPL and no code may be ported or translated from it (repo hard constraint: no GPL dependencies). Every factual claim about MuseScore in this document was verified against the local clone at `~/Developer/musescore/MuseScore` (MuseScore 4 at `master`, MuseScore 3 at tag `v3.6.2`); the file and line citations are the evidence.

---

## 1. Product identity — one folino, one library

macOS is **not** a separate product. Mac, iPad, iPhone, and Android are faces of the same product: one library, one file identity, one account, one annotation model, one collaboration fabric. Only the *feature surface* and the *placement* differ per platform.

This revises `docs/product/vision.md`, which still states three things that are no longer true: "folino does not write notes", "no collaboration", "no new-score wizards". All three were overtaken by the note-editing, scratch-creation, and collaboration work. The vision document moves from "the tool on the music stand" to "the score box, the music stand, and the desk."

### The library is the truth; macOS wears a document-shaped face

folino for macOS is **not** a document-based app in the `NSDocument` sense. Scores live in the folino library, which owns the bytes. Opening a file from Finder imports it; a subsequent open of the same file resolves to the same library item.

**Why not document-based**, given that MuseScore is:

- MuseScore's local-document model is a consequence of having had no cloud for twenty years, not a design advantage. MuseScore 4 bolted musescore.com onto it and now carries a permanent split between "local file" and "cloud score" (Save / Save online / Save to cloud). A later entrant can avoid that split by having one place from the start.
- Every axis on which folino can beat MuseScore — collaboration, annotations, cross-device sync — presupposes that **a score has a stable identity**. A document-only model delegates identity to the filesystem path, which is to say it has none.
- The "opens in a new window instead of a tab" complaint (§5.3) is **independent** of this choice. It is solved by adopting standard `NSWindow` tabbing, which a library app gets exactly as easily as a document app.

**The cost, and how it is paid.** The one workflow that gets longer is "receive an `.mscz` over Drive/AirDrop, edit it, send it back": open → edit → export, rather than open → edit → ⌘S. This is absorbed **as a per-score attribute, not as a second mode**: an imported score remembers its *origin* (a security-scoped bookmark) and mirrors saves back to it. On by default, switchable per score. The library stays the single truth; the origin is only a write target. This respects the standing "never split the experience into two modes" rule (`feedback_no_experience_divergence`).

**Consequence that must be stated plainly:** deciding that the library is shared makes **personal cloud sync (collaboration SP2) a hard prerequisite for macOS**. A Mac whose library cannot show the scores already on the user's iPad is an island, which contradicts the reason this decision was made. See §9.

---

## 2. The shape of the window

### 2.1 Panels are summoned, not resident

The panel model is taken from MuseScore largely as-is: palette, inspector/properties, mixer, piano keyboard, and drum pad are toggled, not docked permanently. This is also standard pro-app behavior on macOS (Logic: X mixer, Y library, B browser, P piano roll).

Two departures:

**Function keys are not the default binding.** MuseScore binds `F9` palettes, `F8` inspector, `F10` mixer, `F7` instruments, `F12` timeline (`src/app/configs/data/shortcuts_mac.xml`). On Mac laptops these collide with the media keys (F7–F9 = previous/play/next, F10–F12 = mute/volume), so they only work with `fn` held or after changing a system setting. Designing around a system setting the user must change is not acceptable for a Mac app; Logic deliberately avoids F-keys for the same reason.

**folino starts with every panel closed.** MuseScore 4 opens with palettes and properties visible. folino opens with the score filling the window — the Mac reading of "Open it on stage. Hear it."

### 2.2 Keyboard: inherit MuseScore's fingers, fix what Mac broke

MuseScore consumes **22 of 26 bare letters** in its desktop Mac config; the free ones are `L`, `U`, `Y`, `Z`.

```
A–G pitch   H pitch B   I instruments   J enharmonic   K fret-9   M note-input-by-duration
N note-input-by-name    O percussion panel   P piano   Q halve   R repeat-selection
S slur      T tie       V toggle-visible     W double  X flip           free: L U Y Z
```

Therefore:

- **Where MuseScore already binds a bare letter to a panel, folino keeps that letter** — `I` instruments, `P` piano, `O` drum pad. Easy to press, and the fingers already know it.
- **Only the panels MuseScore exiled to F-keys move**, and they move to `⌘`+digit — one modifier, top row, no collision (durations are *bare* digits, so `⌘1`–`⌘9` is entirely free). This is Xcode's idiom for panel toggles, with tab switching on `⌘⇧[` / `⌘⇧]`.

  ```
  ⌘0 library sidebar   ⌘1 palette   ⌘2 properties   ⌘3 mixer   ⌘4 piano
  ⌘I properties (mnemonic alias)   F7–F12 kept as aliases for MuseScore muscle memory
  ```

- **`Z` opens the searchable symbol browser.** MuseScore 3 bound `Z` to `symbols` — the Master Palette (`v3.6.2:mscore/data/shortcuts-Mac.xml:785-786`); MuseScore 4's desktop config dropped it. folino's symbol/command search *is* the Master Palette's successor, so `Z` lands on the right thing for anyone arriving from MuseScore 3.
- `L`, `U`, `Y` stay unbound, reserved for future editing commands. Bare letters are worth more to editing commands than to panels.
- Note entry, selection, and musical vocabulary follow MuseScore exactly: `N`, `A`–`G`, `1`–`9`, `.`, `0`, `↑↓`, `Ctrl+↑↓`, `Shift+A–G`, `+`, `Ctrl+3`; click to select, `Shift`-click to range, `Ctrl`-click to add. There is no reason to invent here. UI *part* names (palette, inspector) follow Mac vocabulary; *musical* terms (part, staff, voice, measure, rehearsal mark) follow MuseScore.

### 2.3 The four-layer command spine

> **Capability is constrained by neither platform nor window size. Only placement varies.**

- **Menu bar — the complete index.** Every command has a home here. This is what makes the design extensible: adding symbols toward MuseScore parity costs no screen real estate, unlike a resident palette.
- **Command/symbol search — reachable anywhere.** One searchable sheet, `Z`. This is the layer that makes the guarantee above true on devices without a menu bar.
- **Panels — shortcuts.** Closing a panel or shrinking a window removes a shortcut, never a capability.
- **Keyboard — the fast path.**

On Mac the menu bar exists independently of window size, so a quarter-size window still reaches everything. `UIMainMenuSystem` is `API_AVAILABLE(ios(26.0))`, so iPadOS 26+ gets the same guarantee behind an availability check in the `GlassEffectCompat` style (the deployment floor stays iOS 18). Below iOS 26, and on iPhone and Android, command search carries the guarantee alone.

This is the reason the searchable browser is promoted from "a nicer palette" to a required component.

---

## 3. Display modes

Three modes, all present on Mac. **Page is the default** — the artifact being edited is a printed score, and page breaks are part of what is being edited.

| Mode | Design | Status |
| --- | --- | --- |
| **Page** | All pages on one magnifiable scroll canvas, laid out **horizontally** (default), vertically by preference. | ssm's `MagnifyingPDFScrollView` already does exactly this: `PDFPageLayerView` vector `CAShapeLayer` pages in an `HStack`, on a gray ground with page shadows, inside an `NSScrollView.allowsMagnification`, with `BreakIndicatorOverlay` badges already drawn. MuseScore 4's own default is horizontal (`notationconfiguration.cpp:291` sets `IS_CANVAS_ORIENTATION_VERTICAL_KEY` to `false`), so the existing code already matches the reference. |
| **Horizontal** | `MagnifyingScoreScrollView` plus a sticky leading pane that takes over part labels and the bracket once the score scrolls past them. AppKit re-rasterizes the layer tree during magnification, so it stays vector-sharp at any zoom. | Adopt ssm's macOS example design unchanged. |
| **Vertical** | **Fixed layout width**, independent of the window. Toggling a panel or resizing the window must not re-break systems. | MuseScore's continuous-vertical mode (`LayoutMode::SYSTEM`) sets the page bbox width to `ctx.conf().loWidth()` = `styleD(Sid::pageWidth) * DPI` (`pagelayout.cpp:392`, `layoutcontext.h:131`) — page width, fixed, with free zoom absorbing the margin. ssm currently reflows on viewport width (`ScoreView`'s `wrapToViewWidth: true`; the macOS example rebuilds `verticalDoc` from `geo.size.width`). **Fixed width ships as an option on the existing mode, not as a fork of it.** |

---

## 4. What is taken from MuseScore, and what is not

**Taken:** note-entry key bindings, selection grammar, musical vocabulary, the summoned-panel model, page view as the editing surface, horizontal page order.

**Not taken:** resident palette/properties on launch, F-key panel bindings, one-window-per-score, selection-scoped playback, the drum panel's dimensions.

**Added, with no MuseScore equivalent:** musically-anchored annotations, group collaboration, per-staff mute/solo as a first-class rehearsal tool, a single cross-device library.

---

## 5. The four complaints, and their resolutions

### 5.1 The drum input pad is too large and hard to read

Verified quantitatively:

| | Cell | Panel height | Content |
| --- | --- | --- | --- |
| MuseScore 3 (`mscore/drumtools.cpp:52,76`) | `setGrid(28, 60)` = **28×60** | `setMaximumHeight(100 * guiMag())` — **100 px cap** | Notehead glyph on its staff line |
| MuseScore 4 (`PercussionPanel.qml:243-244`, `percussionpanelpadlistmodel.h:95`) | `100 + spacing(12)` = **112×112**, 8 columns default | `min(numRows,2)*112 + 2*label` ≈ **250 px** | Notation preview **or** name (`useNotationPreview` toggle) |

**~7.5× the area per drum** (12544 px² vs 1680 px²), a default width of 896 px, and 2.5× the dock height.

**folino's answer.** iOS already reached the MuseScore-3-shaped conclusion in M6: a compact 15-key default layout that fits every device without shrinking. macOS keeps that and adds back what MuseScore 3 had and MuseScore 4 made an either/or — **notation preview, short label, and the shortcut letter together in one cell**, at roughly 56–64 px square.

**The pad is not the primary input path.** The fast path is the keyboard shortcut letter, and ssm already carries `DrumsetEntry.shortcut` (M6). The pad is where you look when you have forgotten. It therefore toggles on `O` and **overlays the score rather than displacing it**.

### 5.2 Starting playback with measures selected plays only that staff

Verified in MuseScore 4 (`src/playback/internal/playbackcontroller.cpp:1518-1519`):

```cpp
InstrumentTrackIdSet allowed = instrumentTrackIdSetForRangePlayback();
bool isRangePlaybackMode = !m_isExportingAudio && selection()->isRange() && !allowed.empty();
```

`instrumentTrackIdSetForRangePlayback()` (`:822`) collects only `selectionRange()->selectedParts()`; everything else is force-muted. This is deliberate design in MuseScore 4, not a bug.

MuseScore 3 did not do this. `getPlayStartUtick()` (`v3.6.2:mscore/seq.cpp:1187-1195`) returns `cs->playPos()` on the normal path and never consults the selection. `setLoopSelection()` runs only (a) when loop mode is already on and `PREF_APP_PLAYBACK_LOOPTOSELECTIONONPLAY` is set, or (b) at the moment the user *turns loop on* (`v3.6.2:mscore/musescore.cpp:6463`).

**folino's answer — the MuseScore 3 separation:**

- **Selection sets the playback start position. Nothing else. All staves always sound.**
- **Range practice** is A–B repeat, which folino already has as a distinct concept.
- **Hearing one part** is per-staff solo, which folino already has.
- A command sets A–B repeat from the current selection — MuseScore 3's `setLoopSelection`, promoted from an implicit side effect to an explicit action.

The defect in MuseScore 4 is that "selection" (an editing concept) was made to carry "playback scope" (a rehearsal concept). folino has separate tools for both and keeps them separate. **No preference restores the MuseScore 4 behavior** — implicit solo is replaced by explicit solo.

### 5.3 Scores open in a new window instead of a tab

Verified: MuseScore 4 hard-codes one score per window. `ProjectActionsController::openProject` step 4 (`src/project/internal/projectactionscontroller.cpp:257-267`) calls `multiwindowsProvider()->openNewWindow(args)` whenever the current window already holds a project. There is no preference. MuseScore 3 had a tab bar (`v3.6.2:mscore/scoretab.cpp`).

**folino's answer:** standard macOS window tabbing. One window = library sidebar (collapsible) + score tabs. `⌘T`, tab-drag-out, and the merge/move-tab commands all come from the system for free.

### 5.4 The audio engine does not follow a system output-route change

**The premise that "MuseScore 4 solved this" is only partly true.** `osxaudiodriver.mm:465` registers a listener for `kAudioHardwarePropertyDevices` — the device *list* — only. `kAudioHardwarePropertyDefaultOutputDevice` appears solely as a query (`:401`). MuseScore 4 therefore follows devices being plugged and unplugged; switching the system default between two already-connected devices is not covered by that listener.

folino's own state:

- `SheetMusicAudioApple/PlaybackEngine+AudioSession.swift` gates every body on `#if os(iOS) || os(tvOS) || os(watchOS)` — there is no macOS path.
- **`AVAudioEngineConfigurationChange` is never observed anywhere in ssm** (zero hits repo-wide). `AVAudioEngine` stops itself when its I/O configuration changes; without observing this and reconnecting, playback simply goes silent.

**folino's answer:** add the macOS path in ssm and observe `AVAudioEngineConfigurationChange`, reconnecting and restarting the graph. Watch both `kAudioHardwarePropertyDefaultOutputDevice` and `kAudioHardwarePropertyDevices` where the lower-level hook is needed. **This is shared code and improves iOS at the same time** — iOS currently only observes `AVAudioSession` interruptions. Implementation must consult `reference_audio_engine_pitfalls` (teardown races, clock divergence, sample-rate sticking) — a device switch during playback is exactly where those recur.

---

## 6. How far editing goes at launch

> **The v1 target: everything the ssm model can express, folino can edit.**

A verifiable line rather than an arbitrary one. Deferred only where the *model* must grow.

**`Docs/edit-commands.md` §C ("Out of scope for the current data model") is stale** and must be corrected as part of this work. Verified present in `SheetMusicCore/Score/` today, and rendered:

| Listed as needing model work | Reality |
| --- | --- |
| Articulations | `Chord.articulations: [ChordArticulation]` + `ArticulationRenderer` / `ArticulationGlyph` |
| Grace notes | `Chord.graceNotesBefore` / `graceNotesAfter: [GraceChord]` + `GraceChordRenderer` |
| Tremolo | `Chord.tremolo: Tremolo?` + `TremoloRenderer` |
| Note color / visibility, beam mode, stem visibility | `Chord.elementProperties`, `.visible`, `.stemVisible`, `.beamVisible` |
| Chord symbols | `Harmony.swift` |
| System / page break | `Measure`'s line / page / section break flags + `BreakIndicatorOverlay` |

Also in the model with no command yet: `Dynamic`, `Fermata`, `StaffText`, `Tempo`, `BarLine`, `MeasureRepeat`, `Jump`, `Marker`, `Breath`, `Arpeggio`, `ChordLine`, `NoteParentheses`, `GuitarBend`, `Swing`, and **all eleven `Spanner` kinds** (volta, slur, hairpin, pedal, ottava, textLine, glissando, vibrato, trill, palmMute, letRing).

**Genuinely absent from the model, and therefore deferred:** ornaments (turn, mordent — trill exists as a spanner), manual stem-direction override (round-tripped only as a `<Beam>` payload), cue notes, slash notation, figured bass. *This list is the remaining distance to MuseScore parity.*

**Scope: ~38 new edit commands**, most of them sugar over `ReplaceVoiceElement` + `CompositeEditCommand`:

| Group | Commands |
| --- | --- |
| Structural | `MoveToVoice` `SetBarLineSubtype` `SetMeasureRepeat` `SetLayoutBreak` (line/page/section) |
| Marks | `SetClef` (at position, incl. mid-measure) `SetTempo` `SetDynamic` `SetStaffText` `SetFermata` `SetBreath` `SetJump` `SetMarker` |
| Note/chord | `SetArticulation` `SetGraceNotes` `SetTremolo` `SetArpeggio` `SetGlissando` `SetDots` `SetChordLine` `SetNoteParentheses` |
| Visibility | `SetElementVisible` `SetStemVisible` `SetBeamVisible` |
| Range | `TransposeRange` `AddIntervalToSelection` `DeleteRange` `SetAccidentalsInRange` `SetDurationInRange` `RespellRange` |
| Spanners | `SetSlur` `SetHairpin` `SetPedal` `SetVolta` `SetOttava` `SetTextLine` `SetTrill` `SetVibrato` `SetPalmMute` `SetLetRing` |
| Harmony | `SetChordSymbol` |

Each consumes a wire intent for Android (25–28 are spent; this claims roughly 29–66) plus replay goldens.

### 6.1 The stable-ID constraint this creates

`EditIntent.swift` states that **case order is part of the committed wire format — append, never renumber**. ssm's element addressing is entirely positional (`VoiceElementID` = staff + measureIndex + voiceIndex + elementIndex; no UUIDs anywhere in the core model). The collaboration spec calls SP0 (stable-ID retrofit) "the single hard prerequisite" and warns that retrofitting stable IDs after an op log exists is not possible.

Landing 38 commands roughly doubles the surface a future SP0 must retrofit, and bakes positional addressing permanently into the wire format.

**Decision:** SP0's body is **not** pulled ahead of macOS — it gates R3 (note editing on group scores), not the Mac release. Instead, **the edit-command sub-project carries a binding design constraint: every new intent must funnel element references through a single codec seam**, so the later retrofit is mechanical rather than 60–100 individual rewrites. This constraint is a required section of that sub-project's spec, and SP0's body is scheduled immediately before SP6.

---

## 7. Annotations and the file format

### 7.1 The model is already settled by the collaboration spec

`2026-08-03-cloud-sync-and-group-collaboration-design.md` (on branch `worktree-group-sharing-collab`) already decides ownership and visibility, and needs no change:

- D11 — every stroke carries an author and lives in either the shared or the private path. `DrawingAnchor` gains `authorUID: String?` and `isPrivate: Bool` under the append-only extension contract, so existing data reads back unchanged.
- Privacy is enforced **by path, not by a field** (`/strokes/{id}` vs `/private/{uid}/strokes/{id}`), because rules are not filters.
- A shared/private segmented control appears whenever a group score is open, with no silent default.
- Per-member visibility toggles plus "my notes", device-local and unsynced.
- The eraser targets only your own strokes by default.

### 7.2 `.folino` — a superset of `.mscz`

```
score.folino  (zip)
├── META-INF/container.xml   ← MuseScore reads this
├── score.mscx               ← MuseScore reads this
└── folino/
    ├── annotations.json     ← AnnotationLayer (the existing Codable, unchanged)
    ├── prefs.json           ← per-score playback preferences
    └── ink/<id>.pkdrawing   ← raw PKDrawing bytes, kept out of the JSON
```

**Renaming the extension to `.mscz` makes it open in MuseScore.** `MscReader` addresses entries by name — `readScoreFile()` looks up `mainFileName()` and falls back to any root-level `.mscx` (`mscreader.cpp:154-170`). There is no code path that enumerates and rejects. MuseScore itself already treats the container as "score plus sidecars" (`audiosettings.json`, `viewsettings.json`, `automation.json`, thumbnails, `Pictures/`, `Excerpts/`).

**But it must not claim to be `.mscz`.** `MscWriter` writes a fixed set of names with no pass-through (`mscwriter.cpp:123-208`), so **saving in MuseScore silently drops the sidecar**. Under the `.mscz` extension the annotations would vanish with the filename unchanged — the worst way to lose data. A distinct extension is the warning.

**Three export targets:**

1. **`.folino`** — for folino users; annotations stay editable.
2. **`.mscz`** — for MuseScore; sidecar deliberately dropped, stated in the UI.
3. **PDF with annotations flattened** — for people without folino. Expected to be the most-used of the three; folino already exports PDF, so this is the annotation layer composited on top.

**Open items this sub-project must settle** (the collaboration spec predates `.folino` and does not cover export):

- `authorUID` is a Firebase UID and is meaningless outside the group. `.folino` must carry an **author display-name snapshot** alongside it.
- **Which strokes are included.** Private strokes are never exported. Which *shared* authors are included is a user choice at export time.
- **Three candidate homes for the same annotation** — library DB, Firestore, `.folino` container. The container is a projection; the reconciliation rules must be written down explicitly.

### 7.3 Annotation input on macOS

macOS PencilKit has **no `PKCanvasView` and no `PKToolPicker`**. It does have the whole model, with public initializers:

| API | macOS |
| --- | --- |
| `PKStrokePath(controlPoints:creationDate:)` | 11.0+ |
| `PKStroke(ink:strokePath:transform:mask:)` (`NSBezierPath` overload) | 11.0+ |
| `PKDrawing(strokes:)`, `drawingByAppendingStrokes:` | 11.0+ |
| `PKDrawing(data:)`, `dataRepresentation` | 10.15+ |
| `imageFromRect:scale:` → `NSImage` | 10.15+ |

So a hand-rolled canvas on Mac can collect points and build **byte-identical** `PKDrawing` data. **The annotation format does not fork per platform**, and the `StaticInkLayer` technique ports directly.

Realistically, freehand with a mouse is not a serious input method. The Mac annotation surface is **text notes, highlights, and shapes**, plus reading/erasing/exporting ink authored on iPad, plus Apple Pencil over Sidecar.

---

## 8. The platform contract

**Capability does not vary by platform or by window size. Only placement does.**

- **Placement varies by window size** — a panel becomes an overlay, pad rows fold, an inspector becomes a sheet. This is the existing `ViewThatFits` judgement (size classes are not enough; iPad mini stays `regular` while being 400 pt narrower), applied to editing surfaces.
- **Placement varies by platform** — panels on Mac, sheets and popovers on iPad and iPhone, Android idioms on Android.
- **The floor everywhere is command search.** Nothing authored on one device can be un-editable on another. In particular, a slur written on Mac is always removable on an iPhone.

Not building 38 dedicated command UIs for iPhone in v1 is a **scheduling** decision, not a principle. It is recorded with `PARITY(ios)` / `PARITY(android)` markers so the ledger tracks it (`Scripts/parity-report.py`, `docs/engineering/ios-android-parity.md`).

---

## 9. Sub-projects

| | Sub-project | Depends on |
| --- | --- | --- |
| **0** | **SP0 addressing decision** — write the "all element references funnel through one codec seam" constraint into Ⅰ's spec; schedule SP0's body immediately before SP6 (§6.1) | — |
| **Ⅵa** | **Keep the collaboration branch current** — absorb `main` into `worktree-group-sharing-collab` on a schedule. **Do not merge to `main`.** | — |
| **Ⅵb** | **SP2, personal cloud sync** — a hard prerequisite for macOS (§1) | Ⅵa |
| **Ⅵc** | **Revise the collaboration spec for macOS** + SP3–SP5 (groups, sharing, shared/private annotations) | Ⅵb |
| **Ⅰ** | **ssm: ~38 edit commands** + wire intents + replay goldens; correct `edit-commands.md` §C | 0 |
| **Ⅱ** | **ssm: macOS foundations** — hit-testing / selection / caret / playback cursor on the page deck; fixed-width vertical **as an option**; `MSCZWriter` extra entries; `AVAudioEngineConfigurationChange` | — |
| **Ⅲa** | **folino packages on macOS** — platform declarations + UIKit separation | — |
| **Ⅲb** | **Mac app shell** — new target, window/tab/menu bar/panel skeleton, `Infrastructure.Audio` on macOS; revise `module-architecture.md` | Ⅲa |
| **Ⅳ** | **Mac editing UI** — palette / inspector / mixer / piano / drum pad, command registry and search, key map; iPad menu bar and the iPhone search floor; PARITY bookkeeping | Ⅲb, Ⅱ (consumes Ⅰ incrementally) |
| **Ⅴ** | **`.folino` format + Mac annotation canvas** — container spec, UTType declaration, three exports, author snapshot, reconciliation rules | Ⅱ, Ⅲb, Ⅵc |
| **Ⅷ** | **Mac distribution** — App Sandbox + security-scoped bookmark persistence (what §1's origin mirroring actually requires), signing, notarization / App Store submission, a mac release lane, Mac screenshots | Ⅲb |
| **Ⅶ** | **folino Pro (M5 IAP)** — ships with collaboration; iOS↔Mac universal purchase | Ⅵc, Ⅷ |

### Notes on the dependencies

**Ⅲ does not depend on Ⅱ.** ssm declares `.macOS(.v14)` (`Package.swift:662`) and CI runs `swift build` + `swift test` on a `macos-15` runner (`ci.yml`), so `SheetMusicUI` is already gated to compile and run on macOS. A Mac shell that *displays* scores stands today. Ⅱ gates **Ⅳ and Ⅴ**, not Ⅲ.

**Ⅳ does not wait for all of Ⅰ.** 36 edit commands already exist. The registry, search, panels, and key map stand on those, and Ⅰ's output is consumed incrementally.

**Ⅲa is smaller than it looks.** `Utility`, `Domain`, and `Library` already declare `.macOS(.v14)`; six packages are iOS-only. Of 845 source files, 46 import UIKit or PencilKit, and the structural work concentrates in Reader's UIKit scroll hosts and Utility's representables. `ScoreUI` imports UIKit in zero files — a one-line `platforms:` change. Within Infrastructure the non-portable surface is **three files, all under `Audio/`** (`LivePlaybackController.swift`, `LiveScoreAudioExporter.swift`, `OutputRouteDisconnectWatcher.swift` — `AVAudioSession`, `MPMediaItemArtwork`, route-change notifications); Persistence, Soundfonts, and ScoreFiles are portable.

**Ⅵ is not merged to `main` yet.** The branch is **26 ahead / 301 behind** as of 2026-08-31. Merging now would invoke the spec's own release-timing commitment — "do not cut a release from `main` between SP1 and SP2" — and freeze iOS and Android releases until SP2 lands. Instead the branch absorbs `main` on a schedule (Ⅵa), which fixes the drift while leaving `main` releasable, and pays the conflict cost incrementally on the branch, where it belongs. Known collision points: `SettingsSheet.swift`, `Packages/Infrastructure/Package.swift`.

**The merge happens when SP2 is complete** — at that point SP1 and SP2 land together and the release-timing commitment is satisfied by construction. Ⅵc then starts from a fresh worktree branched off `main`, absorbing `main` frequently, per the repo's standing practice. No sub-project in this document is developed on `main` itself.

**The critical path is not Ⅵ alone.** `Ⅵa → Ⅵb → Ⅵc` and `Ⅲa → Ⅲb → Ⅳ` run in parallel, and the longer of the two decides the date. Ⅷ and Ⅶ close it out. Both tracks can start immediately.

---

## 10. Documents this work must revise

- `docs/product/vision.md` — "does not write notes", "no collaboration", "no new-score wizards" (§1).
- `docs/product/roadmap.md` — "Mac Catalyst" under v3+ is superseded; this is a native AppKit/SwiftUI app.
- `docs/engineering/module-architecture.md` — a second composition root ("App/ is the only place …"), and the stale "Features may not import ssm model modules" rule that CLAUDE.md already overrode.
- `docs/product/architecture.md` — the `CloudSync` module description.
- ssm `Docs/edit-commands.md` — §C is stale (§6).
- `2026-08-03-cloud-sync-and-group-collaboration-design.md` — Non-Goals says "iOS/iPadOS and Android clients only"; macOS is unmentioned throughout (§9, Ⅵc).

## 11. Open questions

- **Price points for Pro** remain deliberately undecided (inherited from the scratch-creation spec).
- **Whether Mac ships simultaneously with an iOS/Android release.** Collaboration and Pro are cross-platform, so Ⅵc and Ⅶ landing implies a large release on every platform at once. Sequencing is a separate decision.
- **Which Firebase SDKs support macOS.** Auth and Firestore do; sign-in helper SDKs need individual verification before Ⅵc is planned. *Unverified.*
- **Whether ssm's macOS example target compiles today.** `SheetMusicExampleMac` is not in ssm's CI. *Unverified.*
