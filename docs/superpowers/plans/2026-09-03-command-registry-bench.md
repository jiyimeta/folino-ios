# Bench: does the iPadOS 26 menu bar carry SwiftUI `Commands`?

Task 1 of the [command-registry plan](2026-09-03-command-registry.md). Measured before any code moved, so a
false answer would have changed the plan rather than the code. All three answers came back true.

**Environment:** `iPad-Bench-26` (a fresh iPad Pro 11-inch M4, iOS 26.5 simulator, UDID
`2F1DC3AF-782B-4DC5-8EF2-269EAD4AB2A3`, created for this bench — the only other iPad simulator,
`FolinoShot-iPad2`, is iOS 27.0 and belongs to the screenshot workflow and was not touched). A temporary
probe was added to `App/iOS/FolinoApp.swift` — a `CommandMenu("Bench")` with two rows, "Modified ⌘⌥B"
(`.keyboardShortcut("b", modifiers: [.command, .option])`) and "Bare Z" (`.keyboardShortcut("z", modifiers: [])`)
— each logging `NSLog("[BENCH] … fired")`. A background `log stream --predicate 'eventMessage CONTAINS
"[BENCH]"'` against the booted simulator was the instrument for Q2/Q3; the human's pointer/keyboard/typing
was the instrument for all three, per this repo's standing rule against driving the simulator with
UI-automation.

## Q1 — Does a menu bar appear, with a "Bench" menu holding both items?

**Observed: YES.** With **I/O ▸ Keyboard ▸ Connect Hardware Keyboard** enabled and the pointer moved to the
top of the iPad screen, the system menu bar appeared, and it contained a "Bench" menu with both rows visible
("Modified ⌘⌥B" and "Bare Z").

**Consequence:** SwiftUI `Commands` do reach the iPadOS 26 menu bar as-is. Task 6 uses `.commands`, not the
`UIMainMenuSystem` / `UIApplicationDelegateAdaptor` fallback the plan reserved for a false answer here — that
fallback and its "if Q1 was false" branch in Task 6's opening paragraph are moot.

**A correction the bench surfaced, for the plan text:** getting a compiling probe in place required
discovering that `.commands` is a **`Scene` modifier, not a `View` modifier** — it must be chained onto the
`Scene` `WindowGroup { … }` returns, after that closure's closing brace, not chained onto the `View` inside
the closure (where `.task` / `.onOpenURL` live). Chaining it inside, at the same indent as `.onOpenURL`, fails
to compile:

```
App/iOS/FolinoApp.swift:28:14: error: value of type 'some View' has no member 'commands'
```

The fix that builds:

```swift
    var body: some Scene {
        WindowGroup {
            AppShellView(…)
                .task { … }
                .onOpenURL { … }
        }
        .commands {
            CommandMenu(Text(verbatim: "Bench")) { … }
        }
    }
```

Task 6 Step 4 currently reads "`FolinoApp`: add `.commands { AppCommandMenus() }` to the `WindowGroup`," which
parses the same way this bench's first, broken attempt did. It needs to say: close `WindowGroup { }` first,
then chain `.commands { AppCommandMenus() }` onto the `Scene` outside it — sibling to `WindowGroup`, not
nested inside its trailing closure.

## Q2 — Does a bare, unmodified key equivalent (`Z`) reach the app from an external keyboard?

**Observed: YES.** With the library on screen and no text field focused, pressing `Z` produced
`[BENCH] bare fired` in the log twice, once per press: `2026-09-03 15:16:14.951` and `2026-09-03 15:17:17.771`
(compact log style; process `folino[24754:...]`, subsystem `(Foundation)`).

**Consequence:** a bare key equivalent registered via SwiftUI `.keyboardShortcut(_:modifiers:)` with an empty
modifier set does get delivered on iPadOS from a connected hardware keyboard. Task 7's bare-key delivery on
iOS is unaffected — nothing here narrows it.

## Q3 — Does typing steal from a focused text field?

**Observed: YES, typing wins — the key equivalent is not stolen.** The fresh bench iPad has an empty library
with no search field to test against, so the substitute per the brief's own fallback intent was the closest
equivalent surface: the new-score sheet's title text field. Typing `zzz` into it produced all three letters in
the field, and the same time window's log (`log show --last 6m`, predicate `eventMessage CONTAINS
"[BENCH]"`) shows **zero** `[BENCH] bare fired` lines — none of the three keystrokes, including the `z` that
exactly matches the probe's bare shortcut, triggered the command while the field had focus.

**Probe control (the reason to trust an absence here):** an empty result from a log predicate is exactly as
consistent with "the predicate/instrument is broken" as with "the event never fired," so the zero-count needed
its own check before being read as a real negative. Two checks confirmed the instrument was live and correctly
scoped during this exact window: (1) the same predicate, `eventMessage CONTAINS "[BENCH]"`, had already
returned two real hits minutes earlier for Q2, against the same running process — proving the predicate
matches when the event does fire; (2) `processImagePath CONTAINS "folino"` over the same window returns
folino's own log lines, proving the simulator's unified log is being captured at all and the app process was
alive and logging throughout. With both controls in place, the Q3 zero-count is read as "the command did not
fire," not "the log pipe went quiet."

**Consequence:** the spec's §5 iPad-half assumption holds — a focused text field wins over a bare key
equivalent on iPadOS, the same as the existing macOS behavior the plan already assumes. Task 7 keeps bare-key
delivery on iOS as originally planned; no narrowing to modifier-only shortcuts, no revision note against §5.

## Summary for the plan

| Question | Answer | Effect on plan |
| --- | --- | --- |
| Q1: menu bar carries `Commands` | YES | Task 6 uses `.commands`; the `UIMainMenuSystem` fallback path is unused |
| Q1 side-finding | `.commands` is a `Scene` modifier | Task 6 Step 4's wording ("add `.commands { AppCommandMenus() }` to the `WindowGroup`") needs to say it goes outside `WindowGroup { }`'s closing brace, sibling to it — not nested inside |
| Q2: bare key reaches the app | YES | Task 7's bare-key delivery on iOS proceeds unchanged |
| Q3: focused text field wins over bare key | YES | No narrowing of Task 7; spec §5 needs no revision note |
