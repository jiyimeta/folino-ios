# QA: the always-editable Mac score window (Ⅳa)

Build: `Scripts/build-macos-app.sh`, then `open` the `folino.app` under DerivedData. Record each item as pass / fail
with what you saw. Items marked ★ are the ones no build gate can check.

## Section A — one score window

1. Open a score from the library. The window shows it; no edit button exists anywhere. ★
2. Click a note. It tints (accent). Click empty paper. The tint goes. ★
3. Click a note, press `c`. A C is written at the caret; the score re-engraves in place, no flash. ★
4. Press `5`, then `.`. Duration quarter, dotted. Press `↑` twice: two semitones up. `⌘↑`: an octave.
5. `⌘Z` three times, `⇧⌘Z` once. The score follows each step. The Edit menu's Undo / Redo enable / disable correctly.
6. Click a note, press Space. Playback starts FROM that note; the selection stays tinted; the playback cursor moves.
   While playing, press `c`: nothing happens (Notes menu items are disabled). Click elsewhere: the playhead seeks.
   Space stops.
7. Measures ▸ Rehearsal Mark…: type `a` in the field. The letter lands in the field, no note is written. Return
   applies. Esc closes.
8. Close the window (⌘W). Reopen the same score from the library. `⌘Z` undoes the edit made before the close. ★
9. Make an edit, quit within two seconds (⌘Q). Relaunch, open the score: the edit is there. ★
10. File ▸ Revert To ▸ Last Opened: confirmation names what it will do; confirm; the score is as it was when the
    window opened. File ▸ Revert To ▸ Original: same, back to the imported file; the window keeps editing afterwards
    (click a note, type a letter).
11. Open the same score again from the library while its window is open: the existing window comes forward; no
    second window. ★
12. With a note selected, click a row in the library window's list, press ↑ / ↓ / ⌫ — the list moves / nothing is
    deleted in the score; then in the score window press ↑ with the score scroll view focused after a click on empty
    paper — the score scrolls or nothing happens, but no note moves. (Under delivery B, bare arrow keys are
    window-wide; sheets are separate key windows and are not at risk.)
13. Open a score whose retained undo history exists (edit, close the window, reopen): ⌘Z is enabled immediately,
    before any new edit.
14. Press Space, then ⌘Z while playing: nothing is undone; stop; ⌘Z works again.

## Section B — the three display modes

15. View ▸ Display Mode ▸ Vertical / Horizontal / Page: in each, items 2–4 work, and the caret is drawn on the
    correct staff. In Page mode a click on the blank paper below a page's last system deselects rather than
    selecting something on the next page.

## Section C — drums and instruments

16. Open a score with a drum staff; click a note on it. The letters bound in the drum pad layout write drum notes;
    Notes ▸ Pitch items are disabled. Score ▸ Drum Keys… opens.
17. Score ▸ Instruments…: add a part, reorder, toggle a staff's visibility. The score follows; hidden staves stay
    hidden while editing.

## Section D — the bench's premise, in the real app ★

18. With a note selected, focus the library window's search field (⌘O, click the field), type `a`. The letter
    lands in the search field; no note is written in the score window.
