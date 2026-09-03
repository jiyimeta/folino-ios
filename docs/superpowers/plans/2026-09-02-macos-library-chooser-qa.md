# macOS library chooser — QA

Spec: `docs/superpowers/specs/2026-09-01-macos-library-window-redesign-design.md` §2.9
Plan: `docs/superpowers/plans/2026-09-02-macos-library-chooser.md`

Build **Debug** for everything here — none of it plays audio. (Playback QA needs Release; see the
`feedback_macos_qa_release_build` memory.)

## Section A — the five rules

| # | Steps | Expected |
| --- | --- | --- |
| 1 | Launch with the library up. Double-click a score. | The score window opens **and the library window closes**, one gesture. |
| 2 | Same, but select a row and press Return. | Same as 1. |
| 3 | Same, but use the row's context-menu Open. | Same as 1. |
| 4 | With a score window up, click the toolbar's library button. | The library appears **in front of the score window, on the same Space**. No Space switch, no bounce. |
| 5 | Same, with ⌘O. | Same as 4. |
| 6 | Put the score window in **full screen**. Press ⌘O. | The library appears **over the full-screen score**, still in full screen. The Mac does **not** animate to another Space. |
| 7 | From 6's library, double-click a second score. | The library closes; the second score is a **new tab of the same full-screen window**, and it is the selected tab. |
| 8 | Not in full screen: with one score open, ⌘O then double-click a second score. | The second score is a **new tab** of the existing window — not a separate window. The tab bar appears. |
| 9 | Open a third score the same way. | Three tabs, one window. |
| 10 | ⌘W the last score window (close every tab). | The **library appears**. The app does not quit and does not sit with no windows. |
| 11 | With the library up and no score window, ⌘W the library. | The library closes. The app stays running with no window (Dock icon still there); clicking the Dock icon or ⌘O brings the library back. |
| 12 | Open a score. In the library (⌘O), permanently delete that same score from Recently Deleted, then look at the score window. | The score window **closes itself** and the library is on screen. No `ContentUnavailableView`, no toolbar-less window. |
| 13 | Open a score, ⌘Q. | The app quits. **No library window flashes up on the way out.** |
| 14 | Open score A. From the library open score B. From the library open A again. | A's existing tab comes forward; there is no second tab or window for A (§2.3 revision — this must not have regressed). |
| 15 | Open score A, then open score B from the library (B becomes a tab). Close **A's** tab. Then close B. | Closing A does **nothing** — a score is still open. Closing B puts the **library** on screen. This is the one unmeasured lifetime dependency in the branch: if the library does not appear, the stored `showLibrary` belonged to a window that has closed. Section D's last entry is the remedy. |
| 16 | With a score already open, File ▸ New Window (⌘N). | The valueless window closes itself. It must **not** flicker in as a tab of the score window, and must not steal its focus — the score window stays key throughout, tab bar unchanged. |
| 17 | Quit with a score open, relaunch. | A score window comes back. The library, if it presents at all, presents **over** it rather than beside it. If a restored window names a score deleted while the app was closed, that window closes itself cleanly — no stray tab, no empty window left behind. |
| 18 | With the library **already** open behind a score window, ⌘W the score window. | The existing library window simply comes forward. No second library window, no visible close-and-reopen. |
| 19 | With two tabs, drag one out into its own window (§2.4's promised tear-off), then ⌘W the torn-off one. | The survivor is still registered: ⌘W on **it** then shows the library. A tear-off must not lose a window's registration. |

## Section B — what this slice deliberately did not change

| # | Steps | Expected |
| --- | --- | --- |
| 20 | With the library up, File ▸ Import (⇧⌘I) a new file. | The score opens in a window. **The library stays open behind it** — import is not one of §2.9.1's three named open paths. Confirm this is the behavior you want; the alternative is a one-line change in `ImportedScoreOpener`. |
| 21 | With the library up, use `+` ▸ New Score. | Same as 20. |
| 22 | With a score window key and the library closed, ⇧⌘I a file already in the library. | The library is summoned and presents the duplicate prompt (`MacShellView.importAction`, unchanged). |

## Section C — the fault check (re-measured, per spec §5.3)

Open Console.app, filter `NavigationRequestObserver`. Then, in one run:

1. Import a file (⇧⌘I).
2. Double-click a row.
3. ⌘-click a second row.
4. ⇧-click a third row.
5. ⌫ on the selection.
6. Open a second score so it tabs.
7. Open a score, then permanently delete it from Recently Deleted so its window closes itself.
8. ⌘W the last score window.

Expected: **no** `Update NavigationRequestObserver tried to update multiple times per frame` lines. One is a
regression. The positive control: the fault is real and observable — if you cannot make it appear at all in any app
state, the filter is wrong, not the app.

## Section D — if a rule fails

- **6 switches Spaces anyway.** The next lever is `window.level = .floating` in
  `MacLibraryWindowProbe`, on top of `.fullScreenAuxiliary`. Failing that, the spec's own fallback is a real
  `NSPanel` (`.nonactivatingPanel`) for the library.
- **7 or 8 opens a separate window.** Log `MacScoreWindowRegistry.shared.windows.count` and the `tabHost` result
  inside `joinExistingScoreWindow`. A `nil` host means registration is racing the open (the deferred `register` runs
  after the newcomer's `tabHost` query); a non-nil host that does not tab means `addTabbedWindow` is being refused,
  and `window.tabGroup` before/after is the thing to print.
- **10 does nothing.** The stored `showLibrary` action is stale — print inside the closure to see whether it is being
  called at all. If it is called and nothing opens, the captured `OpenWindowAction` did not survive its window; the
  fix is to install the action from the library window's own probe too, and from `MacCommands`.
- **13 flashes the library.** `isTerminating` is being set too late; move it into `applicationWillTerminate` as well.
- **A `NavigationRequestObserver` fault appears only on the self-closing empty window (Section C's new step).**
  `MacShellView`'s empty branch defers its `dismiss()` by one main-actor hop already. If it still faults, the
  next thing to try is collapsing the open and the close into ONE deferred `Task { @MainActor in }` — that is
  the "one inline write + two in the single existing hop" arrangement `ImportedScoreOpener`'s doc comment
  records as measured CLEAN.
- **15 fails: closing the last tab leaves nothing on screen.** The stored `showLibrary` is the cause — it held the
  `OpenWindowAction` of a score window that has since closed. The remedy is a third installer: `MacCommands` holds an
  app-scoped `openWindow` that can never belong to a score window.

## Section E — what to decide at merge

1. **Import and the new-score wizard do not close the library** (Section B, 20-21). §2.9.1 names double-click,
   Return and the row's Open item; import routes through `ImportedScoreOpener`, whose handler runs inside a
   SwiftUI update and whose write count is the one measured hazard in that file. Left alone deliberately.
   If you want import to close the library too, it is one deferred write in `openImportedScore` — say so and
   it goes in.
2. **Nothing in Section A has been observed by a machine.** Every §2.9 rule is about windows, Spaces and tabs;
   the gates prove only that nothing regressed. Section A is the acceptance condition.

## Section F — why open-as-tab is built the way it is

**Hand-verified 2026-09-03**: opening a second score into an existing score window keeps that window's position and
size, shows no flash of a separate window, and — with the host in full screen — leaves no empty black full-screen
Space behind. Both windowed and full screen were checked.

It reads as one clean step, but it is two: the join perturbs the new window's geometry and a correction puts it
back. What makes the correction invisible is that **the new tab is not selected until after it lands**. A tab group
renders at its selected tab's geometry, so while the newcomer is unselected the group keeps showing the host at the
host's own frame. **If you move that selection earlier, the window visibly jumps** — that was measured twice before
the current arrangement was found. The selection at the end of `MacWindowTabAssist.restoreHostGeometry` is
load-bearing; treat it as part of the mechanism, not as a tidy-up.

Four alternatives were measured and rejected on the way; do not re-run them (full reasoning is on
`restoreHostGeometry`):

| Attempt | Result |
| --- | --- |
| `setFrame` before `addTabbedWindow` | No trace — the join aligns the newcomer's top-left to the host's and keeps its own size, discarding the write. |
| `.defaultWindowPlacement` on the score `WindowGroup` (macOS 15) | Correct size at birth, but the join then grows the window by the tab bar's height and the position ends up wrong and STAYS wrong — worse, because nothing corrects it. |
| `NSWindowController.shouldCascadeWindows = false` | No effect. The controller is real and per-window, so this is not the single-controller trap `christiantietze.de` documents — its prescribed 1:1 fix is already in place. |
| `NSWindowTabGroup.addWindow` instead of `addTabbedWindow` | Identical behavior. |

**If a future macOS changes the timing and the jump comes back**, the structural fix is to stop letting SwiftUI mint
the window — a hand-built `NSWindowController` + `NSHostingController` for the second and later tabs — which removes
the race instead of hiding it, at the cost of re-implementing `WindowGroup(for:)`'s value dedupe (§2.3's "opening an
already-open score brings its window forward"), scene restoration, and the `focusedSceneValue` menu wiring.
