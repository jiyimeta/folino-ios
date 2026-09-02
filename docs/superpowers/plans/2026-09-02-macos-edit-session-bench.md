# Bench: bare-key delivery on macOS (2026-09-02)

Bench: `~/Developer/_test/MacTest/MacTest/KeyBench.swift`. Procedure and pass table: Task 1 of
`2026-09-02-macos-edit-session.md`, reproduced below so this file stands on its own.

The question the bench answers is spec §6.1's: an unmodified letter must reach the score when the score has focus,
and must reach a `TextField` when the field has focus. Two mechanisms can deliver it, and only one of them can be
right:

- **A — menu items gated by `@FocusedValue`.** The score surface is `.focusable()` and publishes an editing target
  through a *view-scoped* `focusedValue`; a bare key equivalent is attached to the menu item only while that value
  is non-`nil`. A sheet's text field is not a descendant of the surface, so the value reads `nil` there, the item
  disables, and its key equivalent is not consumed.
- **B — view-level `Button.keyboardShortcut` inside the score window.** Bare keys are delivered by invisible
  buttons in the window's own view tree; the menu items for those commands carry no key equivalent at all.
  Modifier-bearing shortcuts stay on the menu items either way.

## Procedure

Build and launch the bench, then perform exactly this and read the log list back:

1. Click the gray box. Press `a`. Press `↑`. Press `⌘Z`.
2. Click the inline field. Type `a`. Press `⌘Z`.
3. Click "Open sheet…". Type `a` in the sheet field. Press `⌘Z`. Press Esc.
4. Click the gray box again. Press `a`.

## Pass table

| Step | A passes if | B passes if |
| --- | --- | --- |
| 1 | log has `A: menu a fired` and `A: cmd-z fired` | log has `B: view a fired`, `B: view up fired` |
| 2 | the inline field shows `a`; **no** `A: menu a fired` line was added | the inline field shows `a`; **no** `B: view a fired` line |
| 3 | the sheet field shows `a`; no `A:` line; Esc closed the sheet | the sheet field shows `a`; no `B:` line |
| 4 | `A: menu a fired` again (the value came back after the sheet) | `B: view a fired` again |

If both pass, choose **A** (shortcuts appear in the menus natively). If only B passes, choose **B**. If a bare key
beeps in step 2 or 3, that variant fails (the disabled item consumed the key).

## Result

| Step | A | B |
| --- | --- | --- |
| 1 | not yet performed — the user has not run the keystrokes | not yet performed — the user has not run the keystrokes |
| 2 | not yet performed — the user has not run the keystrokes | not yet performed — the user has not run the keystrokes |
| 3 | not yet performed — the user has not run the keystrokes | not yet performed — the user has not run the keystrokes |
| 4 | not yet performed — the user has not run the keystrokes | not yet performed — the user has not run the keystrokes |

The bench harness exists and builds; the four steps are keystrokes only the user can make (this repo forbids driving
the UI with automation), and they have not been made. Nothing in the table above is a measurement.

## Decision

**B, provisional.** B is the mechanism `MacTransportBar.playPauseButton`'s doc comment already measured for Space —
a view-level `.keyboardShortcut` is focus-aware, where an `NSMenuItem` key equivalent steals the key from a focused
text field. A is unmeasured. Flipping to A later = set `MacEditingKeyDelivery.current = .menuWhileFocused` and add
the view-scoped `focusedValue` publication (see below); nothing else in the command table changes, because the
table is the single declaration and only the delivery differs.

The provisional status is what makes the bench worth running anyway: if A passes every step, the menus show their
bare-key shortcuts natively, which B cannot do.

## What Task 14 must do with it

Task 14 built **both** paths and switched between them with one constant:

- `MacEditingKeyDelivery.current` (in `App/Mac/MacEditingMenus.swift`) is `.viewLevel` — **B**.
- **B:** `MacEditingKeyMap` (`App/Mac/MacEditingKeyMap.swift`) installs one invisible, zero-size `Button` per
  bare-key command, each carrying that command's `.keyboardShortcut(key, modifiers: [])` and `.disabled` exactly
  when the command is. It is mounted as `.background(MacEditingKeyMap(target: editingTarget))` in
  `MacEditableReaderScreen.body`, so it lives in the score window's own view tree and follows its focus. Menu items
  for bare-key commands carry no key equivalent (`MacEditingShortcut` attaches none in this mode).
- **A (built, not active):** `MacEditingShortcut` attaches `.keyboardShortcut(key, modifiers: [])` to the menu item
  while `@FocusedValue(\.macEditingTarget)` is non-`nil`. Switching to A additionally requires the view-scoped
  publication spec §6.1 describes: `MacEditableReaderScreen` must publish `.focusedValue(\.macEditingTarget, …)` on
  the score surface after `.focusable()` (so it goes `nil` when a sheet's text field takes focus) **and** keep a
  second, scene-scoped publication under a sibling key for the modifier-bearing items and the File menu, which must
  work regardless of view focus. That sibling key was deliberately NOT added in Ⅳa — it only lands if A is
  confirmed.

Modifier-bearing shortcuts (`⌘↑`, `⇧A`–`⇧G`, `⌘3`–`⌘9`, `⌘⌥1`–`⌘⌥4`, `⌥.`, `⇧⌫`) sit on the menu items in both
modes and are not affected by the decision.
