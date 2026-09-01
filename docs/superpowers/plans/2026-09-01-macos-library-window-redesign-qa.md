# QA: the macOS library window redesign

## Why this document exists, and how to read it

The machine's screen was locked for the entire implementation of this branch (Tasks 5–8). No app built during
that work ever created a window — every runtime claim below rests on static reading, build output, and `nm`
symbol checks, never on a human watching the app run. **You are the first real observation of any of it.**

For every item: do the thing, and compare what actually happens against both the "pass" and the "fail"
descriptions — a failure here is useful data, not a problem to hide. Where a failure has a place to be
recorded, record it there before moving on; several items point at a specific file and table.

Work top to bottom. Section A is one continuous session launched from a terminal — it deliberately front-loads
everything that needs the terminal-launched, log-capturing run so you don't have to relaunch for each item.
Sections B–F can be done in any order, each in a normal (Dock/Finder-launched) run unless noted.

**Setup, once, before Section A:**

```sh
xcodebuild build -project Folino.xcodeproj -scheme FolinoMac -destination 'platform=macOS' -skipPackagePluginValidation
```

Then find the built app (`Debug` config under DerivedData, e.g.
`~/Library/Developer/Xcode/DerivedData/Folino-*/Build/Products/Debug/folino.app`) — you'll launch it from the
terminal for Section A and normally (Finder/Dock, or `open`) for the rest.

---

## Section A — one terminal-launched session (covers items 1–9)

Quit any already-running copy of the app first (so this is a clean launch, and so stderr capture below actually
belongs to this run). Then, from Terminal:

```sh
"/path/to/folino.app/Contents/MacOS/folino" > /tmp/folino-qa.log 2>&1 &
```

Use the *binary's* path directly, not `open` — a redirected **stdout is fully buffered**, so `print` output
would never reach the file and an empty log would look exactly like "nothing happened." The direct-binary launch
avoids that trap. Leave this running for the rest of Section A; you'll grep `/tmp/folino-qa.log` at the end.

### 1. Launch window shape

**What to do:** Watch what appears in the first few seconds after launch.

**Pass:** The library browser window presents. No separate, empty score window appears beside it.

**Fail / what it means:** An empty score window appears (alone, or alongside the browser). This is a named,
expected risk: `FolinoMacApp.body`'s first scene is `WindowGroup(for: MacWindowScore.self)`, and nothing
suppresses it — only the library `Window` scene carries `.defaultLaunchBehavior(.presented)`. If a stray empty
score window appears, the fix has a name already: add `.defaultLaunchBehavior(.suppressed)` to the score
`WindowGroup`. Record what you saw (which window(s), in which order) — this decides whether that fix is needed.

### 2. Every source renders

**What to do:** In the browser sidebar, click through all six kinds of row: Recently Opened, All Scores,
Favorites, each playlist, each tag, Recently Deleted.

**Pass:** Every source shows its rows in the content pane — none is blank. Recently Opened shows **only** scores
that have actually been opened at least once (not every score), and its row count matches the sidebar's badge
number next to "Recently Opened."

**Fail:** Any source shows a blank content pane, or Recently Opened includes a never-opened score, or its count
disagrees with the badge. Note which source and what you saw.

### 3. Click only selects

**What to do:** Single-click a row in any source.

**Pass:** The row highlights. Nothing opens. If you click a different row shortly after (e.g. one you clicked
earlier, whose `lastOpenedAt` you have *not* changed by opening it), the list order does not jump — clicking
alone must never reorder the list under your pointer.

**Fail:** A single click opens a score window, or the list visibly re-sorts after a plain click. This was a real
reported bug in the previous design: opening a score restamps `lastOpenedAt`, which reorders whatever list is
sorted by it (notably Recently Opened) — but only *opening* should trigger that, never a plain click.

### 4. Double-click opens a score

**What to do:** In **All Scores or Favorites** (the plain score list), double-click a row.

**Pass:** A score window opens for that score.

**Fail:** Nothing happens. This is a real, anticipated possibility, not a bug to panic about —
`contextMenu(forSelectionType:menu:primaryAction:)` (what `double-click` is wired through) is documented API but
**unmeasured in this repo**: nothing else uses it, and the measurement table in
`Packages/Features/Library/Sources/Library/Views/RowOpenAffordance.swift` (the comment block above
`macScoreOpenAffordance`) predates it — every row in that table before it is a measured `NO`.

If double-click does nothing, **first confirm the fallbacks still work** before concluding anything is broken:

- Select the row, press **Return** — must open the score.
- Right-click the row, choose **Open** from the context menu — must open the score.
- (Where present) the toolbar's Open affordance — must open the score.

If all three fallbacks work, this is the measured failure the file's own doc comment anticipates, not a
mystery. **Record the result as a new row in `RowOpenAffordance.swift`'s measurement table** — edit the
`unmeasured` row (`contextMenu(forSelectionType:menu:primaryAction:)`) to `YES`/`NO` for each of its three
columns, matching what you observed.

**Now repeat inside a playlist** (open any playlist from the sidebar, double-click a score row inside it).
**This is not optional and does not follow from the All Scores result above.** `PlaylistDetailView` attaches the
open affordance at a different point in its view tree than `ScoreListView` does (its `List` also carries
`.onMove` for drag-reorder and a differently-built row context menu) — "it worked in All Scores" does not imply
it works in a playlist. Check double-click, Return, and the row's Open / Open in New Window menu items
separately here, and record the result the same way if it differs from the plain list.

### 5. ⌘-click / ⇧-click multi-select, bulk actions, ⌫

**What to do:** In any plain score list (not Recently Deleted), ⌘-click two or three rows, then ⇧-click to extend
a range. Right-click the selection.

**Pass:** All selected rows stay highlighted (⌘-click doesn't collapse to one row). The context menu on the
selection offers bulk actions (e.g. bulk favorite/tag/delete, whatever the row menu shows for a multi-selection).
Pressing **⌫** with the selection active deletes the selected scores (with whatever confirmation the app already
shows).

**Fail:** ⌘/⇧-click doesn't extend the selection, the context menu shows only single-row actions, or ⌫ does
nothing / crashes. This exact path was silently unreachable for two whole tasks earlier in this project's
history (a selection-based open affordance made single-row selection indistinguishable from "open"), so give it
real attention rather than a glance.

### 6. Opening a second score — tab or standalone

**What to do:** From the browser, open one score (double-click or Return). Then go back to the browser (⌘O or
the score window's toolbar button — see item 9) and open a **second, different** score.

**Pass condition A — tabs:** The second score joins the first score's window as a tab (one window, a tab bar
with two tabs).

**Pass condition B — the named fallback, also a pass:** The second score opens as its **own standalone window**
instead. This is expected and not a bug: tab-joining depends on the System Settings preference "Prefer tabs when
opening documents," whose **default is "In Full Screen Only"** — most machines will show fallback B unless that
preference has been changed. If you see B, **check two more things before calling it done:**

- **Window ▸ Merge All Windows** (the standard macOS Window menu item) must still group the two score windows
  into one tabbed window.
- Dragging one tab out of a merged group must tear it off into its own standalone window again.

**Fail:** Neither A nor B's fallback checks work — e.g. Merge All Windows does nothing, or a torn-off tab won't
detach. Record which of A/B you got and, if B, whether both fallback checks passed.

### 7. ⌘O and the toolbar button summon the browser

**What to do:** From a score window (one you opened above), press **⌘O**. Separately, click the toolbar button
in the score window's toolbar (leftmost item, `square.grid.2x2` icon, in the `.navigation` placement).

**Pass:** Both bring the library browser window to the front (focusing it if already open, creating it if not).

**Fail:** Either does nothing, opens something else, or the toolbar button is missing/disabled. Note which of
the two failed.

### 8. The import seam — all four paths

Do all four, in this session (each needs a file to import — use any valid score file, and a second copy of one
you've already imported for the duplicate case):

1. **From the browser, with no score window open.** File ▸ Import (⇧⌘I) or drag a file onto the browser.
2. **From a score window, with the browser window closed.** Close the browser first, then File ▸ Import from the
   score window's menu bar.
3. **With both the browser and a score window open.** Import from either.
4. **Duplicate import** — import the same file a second time (any of the above routes). A prompt should appear
   with choices along the lines of "Open" (opens the existing score) / "Import as duplicate" (imports a second
   copy and opens it) / Cancel (does neither). Try "Open" specifically — it is the path that most exercises the
   arbitration below.

**Pass, every time:** Exactly one score window opens, exactly once, for the imported (or duplicate-resolved)
score. No double windows, no missed opens, no window left showing an empty/blank state.

**Fail:** Zero windows open, two windows open for the same import, or the wrong score opens. This exercises
`MacImportedScoreClaim`, a new single-owner guard arbitrating between every open window's import watcher — cross
-scene `onChange` ordering for one shared `@Observable` object is an unmeasured claim in this branch. Note
exactly which path (1–4 above) misbehaved.

### 9. The `+` toolbar menu and the failing-import alert

**What to do:** In the browser toolbar, click the **`+`** menu (leftmost toolbar item). It should offer three
items: **New score**, **New playlist**, **New tag**. Try each:

- New score → the new-score wizard sheet appears; completing it should open the created score in a score window.
- New playlist → an alert to name the new playlist appears; confirming creates a new row in the sidebar.
- New tag → same, for a tag.

Then, separately, **trigger a failing import** — pick a corrupt or unsupported file (e.g. rename any non-score
file to look importable, or use a deliberately truncated file) and import it via File ▸ Import.

**Pass:** All three `+` items work as described. The failing import raises a visible error alert (not silence).

**Fail:** Any `+` item does nothing (sheet/alert never appears), or a failing import is silently swallowed
(nothing happens, no error shown). All four of these presentations are newly reachable on macOS in this branch
and have never been opened before now.

### 10. End of Section A — check the log

Quit the app (or leave it running if you're continuing into Section D/E immediately — either is fine). Now:

```sh
grep -n 'NavigationRequestObserver' /tmp/folino-qa.log
```

**Pass:** No output, **and** you're confident the check would have caught a real fault (see "positive control"
below).

**Fail:** Any line containing `NavigationRequestObserver tried to update multiple times per frame`. This is a
regression — the exact fault a prior sub-project (Ⅲb) measured and eliminated by keeping to "at most one state
write per SwiftUI update" in the import-open handler (see the doc comment on `openImportedScore` in
`App/Mac/FolinoMacApp.swift`). If it fires, note which action in Section A was running at the time (the click,
double-click, ⌘-click, ⌫, or import step) as closely as you can reconstruct it.

**The positive control — why an empty grep result means something.** This detector is only trustworthy if it is
known to produce a positive when the bug is present, not just silence when nothing ran. It is: Ⅲb's own
measurement recorded this exact log line firing in 2 of 7 launches when the underlying handler performed two
state writes in one update pass (documented in `App/Mac/FolinoMacApp.swift`'s doc comment on
`openImportedScore` and in `App/Mac/MacWindowTabAssist.swift`). So the detector has a known-working history on
this exact class of bug — an empty log here is evidence of "no fault occurred," not "the check never fires."
If you want to see it fire for yourself as a sanity check, that would require deliberately reintroducing a
second write into the handler, which is not expected as part of this pass — skip it unless you're specifically
investigating a suspected regression.

Also skim the rest of `/tmp/folino-qa.log` for anything else that looks like a crash, an uncaught exception, or
a SwiftUI fault-level log — not just the one string above.

---

## Section B — the presence of two engines, one plays (characterization, not pass/fail)

**What to do:** Open two different scores in two separate score windows (standalone, or as two tabs — either
is fine here). Start playback in the first. While it's playing, start playback in the second.

**This item is deliberately not a pass/fail check.** `MacScorePlayback.takeOver(from:)` exists in
`App/Mac/MacWindowTabAssist.swift` but **nothing calls it** — this is a known, recorded gap
(`PARITY(macos): one score plays at a time`, in that same file, reflected in
`docs/engineering/ios-android-parity.md`). What's unverified is not "does it work" but "what actually happens" —
that observation is what decides how the gap gets closed. `bootstrap.playbackController` is one shared
`LivePlaybackController` instance handed to every score window, so at the audio-engine level the second
`load`/`play` already displaces whatever the first was playing — but neither window's own transport UI
necessarily knows about it.

**What to record** (there is no right answer to check against — just describe it accurately):

- Does the first window's audio actually stop when the second starts playing, or do they overlap?
- Does the first window's transport UI (play/pause button, playhead) update to reflect that it stopped, or does
  it keep showing "playing" even though the audio has stopped?
- Any glitch, stutter, or error at the moment of handoff.

---

## Section C — Recently Deleted's open affordance

Not covered by item 4 above on purpose — Recently Deleted never had an "Open" action before this branch and its
row menu differs from the plain list's.

**What to do:** Go to Recently Deleted. Try double-click, Return, and the row's context menu on a deleted item.

**Pass:** Whatever "open" means for a deleted item in this screen (e.g. preview, or restore-and-open, per
whatever the row's Open menu item is wired to) behaves consistently across all three trigger paths, without
double-clicking a row causing a crash or silent no-op that differs from the other two paths.

**Fail:** One path works and another silently does nothing, or it crashes. Note which path.

---

## Section D — playlist reorder

**What to do:** Open a playlist with at least 3 scores. Drag a score row to a different position in the list.

**Pass:** The row moves to the new position and the new order persists (leave the playlist and come back, or
quit and relaunch, to confirm it stuck).

**Fail:** Dragging does nothing, the row snaps back, or the order doesn't persist. This interaction was never
reachable by any prior test harness in either the old or new design — this is its first real exercise.

---

## Section E — dark mode

**What to do:** Switch the Mac to Dark Mode (System Settings ▸ Appearance, or ⌃⌘Q-adjacent toggle / whatever
your setup uses). With the app already open, check both window kinds:

- The library browser (sidebar, content pane, toolbar, the `+` menu, any open sheet/alert).
- A score window (reader chrome, transport bar, toolbar).

**Pass:** Both render correctly in dark mode — no unreadable text (dark-on-dark or light-on-light), no stray
white/light panels that should be dark, no glass/material surfaces rendering as flat or wrongly tinted.

**Fail:** Note which window and which specific control looks wrong, ideally with a screenshot.

---

## Section F — the browser at minimum width

**What to do:** Resize the library browser window down to its smallest allowed width (drag the edge until it
stops shrinking — `minWidth` is set to 820pt).

**Pass:** The toolbar's three controls (`+` menu, sort control, search field) plus the sidebar toggle all remain
usable — nothing overlaps, nothing gets clipped off-window, and if SwiftUI collapses something into an overflow
menu, that overflow menu is itself reachable and functional.

**Fail:** Any toolbar control overlaps another, is clipped, or becomes unreachable. This toolbar previously
carried two controls (sort + search); this branch adds a third (`+`), and the only prior render of it was a
preview at 1000pt wide — wider than the real minimum.

---

## Summary — where each item traces back to

| Item(s) | Source |
| --- | --- |
| 1 (launch window shape) | Task 6 report §6, item 1 |
| 2 (every source renders, Recents count) | Task 4 report (Fix round 1); Task 6 report §6, item 2 |
| 3 (click only selects, no re-sort) | Task 2 report (design rationale in `RowOpenAffordance.swift`) |
| 4 (double-click, incl. playlist-separately) | Task 2 report, "What could not be verified" 1–4; `RowOpenAffordance.swift` measurement table |
| 5 (⌘/⇧-click, bulk actions, ⌫) | Task 2 report design rationale (selection-as-open era defect) |
| 6 (tab vs. standalone, Merge All Windows, tear-off) | Task 5 report, "What remains unverified"; design doc §2.3/line 88 |
| 7 (⌘O, toolbar button) | Task 7 report, "What remains unverified" |
| 8 (import seam, all 4 paths) | Task 6 report, Fix round 1 "New concerns" 1 |
| 9 (`+` menu, failing-import alert) | Task 6 report, Fix round 2 "What remains for QA" 1–3 |
| 10 (`NavigationRequestObserver`, positive control) | Task 6 report §6 item 3; Fix round 1 "New concerns" 4 |
| B (two windows, one plays) | Task 5 report "What remains unverified"; Task 8 report `PARITY(macos)` marker |
| C (Recently Deleted open affordance) | Task 2 report, Wrinkle 2 |
| D (playlist reorder) | Task 8 brief / original plan item; never reached by any harness |
| E (dark mode) | Plan requirement, both window kinds |
| F (browser minimum width) | Task 6 report, Fix round 2 "What remains for QA" 4 |
