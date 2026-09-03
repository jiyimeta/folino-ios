# QA: the command registry, the search sheet, and the iPad menu bar (Ⅳb)

Plan: [`2026-09-03-command-registry.md`](2026-09-03-command-registry.md). Spec:
[`2026-09-03-command-registry-design.md`](../specs/2026-09-03-command-registry-design.md). Bench:
[`2026-09-03-command-registry-bench.md`](2026-09-03-command-registry-bench.md).

One item per acceptance condition. Each records **Observed** or **Not observed**; no item is marked Observed
without the evidence that earned it. Items marked ★ are the ones no build gate can check; all macOS/iPadOS items
in this sheet are ★, since the gate (below) is table-property tests and app/package builds, not UI.

> **All 12 items were run by the user on 2026-09-04**, on both apps freshly built from `2cf02198` (process start
> time checked against the binary's mtime first — an earlier pass had been run against a three-hour-old build, and
> that is the only way to catch it). **Eleven passed on the first run. Item 2 failed** — the score's layout changed
> correctly but the Display Mode checkmark never moved, on macOS and iPadOS alike — and was fixed in `2cf02198`
> (the menu now observes the stored value through `@AppStorage`; a plain `UserDefaults` read is invisible to
> SwiftUI, so nothing re-evaluated the menu). **Item 2 was then re-run and passed.** The two tests added with that
> fix pin which raw value maps to which row; they cannot pin that SwiftUI re-evaluates the menu, which is why this
> item stays ★.

**What the built thing actually is, so the steps below match it and not the plan's first sketch:**

- `MacCommands.swift` no longer exists. The whole Mac menu bar is generated from one table
  (`AppCommandCatalog`) by `AppCommandMenus` (`App/Shared/Commands/AppCommandMenus.swift`). File carries a
  "Revert To" submenu plus top-level Show Library / Import rows; View carries a Display Mode **submenu** (not
  a flat picker) with a checkmark, and a top-level "Find Command…" row (`Z`) above it.
- On iOS the session rule is per-row, keyed off `AppCommand.requiresEditor` (set for every row `editorRow`
  builds, and by hand on the two Revert To rows) — not off `context.editor` nilness. Display Mode and the
  search row (`requiresEditor` left at its default `false`) stay live while merely reading a score; only rows
  that need an editor grey out outside an edit session.
- There is **one** `AppCommandKeyMap`, mounted unconditionally on both platforms (no `isEditing`-gated second
  mount) — each row's own `isEnabled` already carries the session gate, so a duplicate mount would just repeat
  a check the catalog makes.
- There is **no iPhone entry point**. The search sheet is reached by hardware keyboard (`Z`) only — no on-screen
  affordance exists or is expected on iPhone.

## macOS

| # | Steps and what to look for | Status |
| --- | --- | --- |
| 1 | Open a score window. **File**: after Save, a "Revert To" submenu (Last Opened / Original); after New, top-level "Show Library" (⌘O) and "Import…" (⇧⌘I) rows. **Edit**: after Undo/Redo, a divider then the note-editing rows. **Notes / Measures / Score**: each its own menu, with the same `▸`-grouped rows (Pitch, Duration, Accidental, Chord, Tuplet, Voice, …) as before Ⅳb. **View**: before the system's Toolbar item, a "Display Mode" **submenu** (Page / Vertical / Horizontal) then a divider then a top-level "Find Command…" row. Nothing that was reachable before Ⅳb is missing or silently moved to a different menu. | Observed ✓ |
| 2 | View ▸ Display Mode ▸ Page, then Vertical, then Horizontal. After each pick, reopen View ▸ Display Mode: the row matching the mode actually on screen shows a checkmark and the other two don't. | Observed ✓ |
| 3 | File ▸ Show Library opens (or raises) the library window. File ▸ Import opens the native `NSOpenPanel`; importing a file through it succeeds the same way it did before Ⅳb. | Observed ✓ |
| 4 | With a score window key, press `Z` (no modifier): the command search sheet appears (a plain `.sheet`, not a floating panel). Type to filter; press `Return`: the top result runs and the sheet closes. Reopen with `Z`; press `Esc`: the sheet closes with nothing run. A click on a row also runs it. | Observed ✓ |
| 5 | Start playback (`Space`). Open Notes / Measures / Edit: every mutating row is greyed (Display Mode and Find Command stay enabled — both are non-mutating). Open the sheet (`Z`): the same mutating rows appear greyed in the list and a click on one does nothing. Stop playback: the rows re-enable in both the menu bar and the sheet. | Observed ✓ |
| 6 | Open a rehearsal-mark text field (Measures ▸ Rehearsal Mark…). With the field focused, type a bare letter that collides with a Notes bare-key command (e.g. `c`, a pitch letter). The letter lands in the field as text; no note is written and no command fires. | Observed ✓ |

## iPadOS 26

| # | Steps and what to look for | Status |
| --- | --- | --- |
| 7 | With a hardware keyboard connected on the iPadOS 26.5 simulator (or device) and a score on screen, reveal the system menu bar: File, Edit, Notes, Measures, Score and View all appear, populated the same way as the macOS items above. | Observed ✓ — see evidence note below |
| 8 | Open a score for **reading** (no edit session started). The Notes / Measures / Score rows are visible in the menu bar but greyed; Display Mode and Find Command stay live. Enter an edit session: the same rows become enabled without closing and reopening the menu. | Observed ✓ |
| 9 | With a hardware keyboard and a score on screen, press bare `Z` (no modifier): the command search sheet is presented. | Observed ✓ — see evidence note below |
| 10 | In an edit session, with a note selected and a hardware keyboard connected, type MuseScore letters (`c d e f g a b`) and duration digits (`1`–`7`): notes are written the same way they are on the Mac. | Observed ✓ |
| 11 | Focus the library's search field and type a letter that also matches a bare-key command (e.g. `z`, or a duration digit). The letter lands in the search field; no command fires. | Observed ✓ — see evidence note below |
| 12 | Boot an 18.6 iPad simulator (below the iOS 26 menu-bar floor). Launch the app: it launches normally, no crash, and existing hardware-keyboard behavior is unaffected — except that, per spec §8's "second, smaller risk," a connected hardware keyboard's ⌘-hold HUD may now additionally list the app's key commands, which is a new but expected surface, not a regression. | Observed ✓ |

### Evidence already in hand (from Task 1's bench, `iPad-Bench-26`, iOS 26.5 simulator, human-observed 2026-09-03) — items 7, 9, 11 above are graded against it rather than shipped fully blank

The bench used a **temporary probe** `CommandMenu("Bench")` with two rows, not the real `AppCommandMenus` /
`CommandSearchSheet` — so the evidence below confirms the underlying mechanism each item depends on, not the
finished feature's own content. Re-running these three items against the actual build (not the probe) is what
would flip them to fully Observed.

- **Item 7's mechanism — Observed.** With I/O ▸ Keyboard ▸ Connect Hardware Keyboard enabled and the pointer
  moved to the top of the screen, the system menu bar appeared and contained the probe's "Bench" menu with both
  rows visible. Confirms SwiftUI `.commands` reaches the iPadOS 26 menu bar at all. **Not yet observed:** that
  the real six menus (File/Edit/Notes/Measures/Score/View), built from `AppCommandCatalog`, all appear with
  their actual rows.
- **Item 9's mechanism — Observed.** With the library on screen and no text field focused, pressing bare `Z`
  produced `[BENCH] bare fired` in the log twice (`2026-09-03 15:16:14.951` and `15:17:17.771`). Confirms a bare,
  unmodified key equivalent registered via `.keyboardShortcut(_:modifiers:)` is delivered from a hardware
  keyboard on iPadOS. **Not yet observed:** that the real `app.search` row actually raises `CommandSearchSheet`.
- **Item 11's mechanism — Observed, against a substitute field.** The bench iPad's library was empty (no search
  field to test against), so the new-score sheet's title text field stood in. Typing `zzz` into it produced all
  three letters in the field, and the same time window's log shows **zero** `[BENCH] bare fired` hits — checked
  against two controls (the same predicate had already returned real hits for item 9's measurement moments
  earlier; a broader `processImagePath CONTAINS "folino"` predicate confirms the log pipe itself was live)
  before trusting the zero-count as a real negative rather than a broken probe. Confirms a focused text field
  wins over a bare key equivalent on iPadOS. **Not yet observed:** the same result against the library's actual
  search field.

## Parked and deferred — knowingly outstanding, not silently dropped

1. **A projection could still be pointed at the wrong population.** `AppCommandKeyMap.bindings` reads
   `AppCommandCatalog.current` (platform-filtered); the type is named `.allIncludingOtherPlatforms` specifically
   so a call site reading the wrong one is visibly wrong (renamed from a plain `.all` in Task 3 fix round 2 after
   a mutation test proved no existing assertion could tell the two apart). No behavioural test can catch a
   regression here **until the first platform-restricted BARE-KEY row lands** — today's only platform-restricted
   rows (`file.showLibrary`, `file.import`) both carry modifiers, so they never enter the bare-key set and the
   two populations are behaviourally identical for what the key map delivers. Ⅳc's panel keys (or Ⅳd) is the
   trigger that makes this discriminable.
2. **Three of five localizations for the two new catalog keys are machine-written.** `mac.menu.commandSearch`
   and `mac.commandSearch.placeholder` (`App/Resources/Localizable.xcstrings`) carry `en` and `ja` as authored
   text; `ko`, `zh-Hans` and `zh-Hant` are the implementer's own translations from Task 5, verified to carry no
   app name and no internal feature name, but **not yet reviewed by a native speaker** of any of the three.
3. **File ▸ Import has no iPad row**, recorded as a `PARITY(ios)` marker at
   `App/Mac/MacCommandContextWiring.swift:13` and carried into `docs/engineering/ios-android-parity.md`:
   `LibraryRootScreen` owns a non-public `.fileImporter` on iOS, so there is no seam for a menu row to drive —
   Show Library and Display Mode are the only Mac-vs-iPad-identical rows in the File/View menus; Import stays
   Mac-only until Library exposes one.

## The gate — run serially, real numbers

All five run one after another against the same DerivedData (never two `xcodebuild` invocations at once — this
project has already hit "database is locked" from that). Each command's own exit code was captured directly,
not a pipe's terminal stage.

| Step | Command | Exit code | Result |
| --- | --- | --- | --- |
| 1 | `Scripts/build-macos-packages.sh` | 0 | 9 packages built (`Utility`, `Domain`, `ScoreUI`, `Features/Library`, `Infrastructure`, `Features/ImportExport`, `Features/Settings`, `Features/Editor`, `Features/Reader`) — "All macOS packages built." |
| 2 | `Scripts/build-macos-app.sh` | 0 | `** BUILD SUCCEEDED **` |
| 3 | `xcodebuild … -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max,OS=26.5' … build` | 0 | `** BUILD SUCCEEDED **` |
| 4 | `xcodebuild test … -scheme Folino … -only-testing:FolinoTests` | 0 | `** TEST SUCCEEDED **` — Swift Testing run: **41 tests in 8 suites, all passed** (0 failures), no `-testLanguage` / `-testRegion` flag, on this ja-JP host |
| 5 | `xcodebuild test … -scheme FolinoMac -destination 'platform=macOS' … -only-testing:FolinoMacTests` | 0 | `** TEST SUCCEEDED **` — **51 tests in 7 suites, all passed**, no `-testLanguage` / `-testRegion` flag |
| 6 | `xcodebuild … -scheme FolinoScreenshot … build` | 0 | `** BUILD SUCCEEDED **` — added to the gate after the final review found `project.yml` compiles `App/Shared` into this target too |

Both counts match the expectation recorded going into this task (FolinoTests 41/8, FolinoMacTests 51/7,
9 packages, both app builds green) exactly — no divergence to report.

> **Re-run after the final-review fix wave, the `main` merge (swift-sheet-music 2.3.1 → 2.4.0, scanned-PDF
> import) and the folded-top-bar revert fix — head `e5cba108`, run by the controller, 2026-09-03:** all six
> steps exit 0. **FolinoTests 41 tests in 8 suites**, **FolinoMacTests 55 tests in 7 suites** (up from 51: the
> fix wave added four), `FolinoScreenshot` build succeeding, 9 macOS packages, both app builds green. No count
> moved across the `main` merge itself.

One log artifact worth naming rather than skipping past: `xcodebuild`'s XCTest-style summary line for the
iOS run reads `Executed 0 tests, with 0 failures` — that line only counts XCTest-style test methods, and every
test in this suite is Swift Testing. The real count is the Swift Testing runner's own line a few lines below
it, `Test run with 41 tests in 8 suites passed after 0.078 seconds`, which is what this sheet reports above.
