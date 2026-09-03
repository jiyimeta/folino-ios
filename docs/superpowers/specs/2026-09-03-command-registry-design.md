# Sub-project Ⅳb — the command registry, the search sheet, and the iPad menu bar

Ⅳa built the Mac's editing vocabulary as a table (`App/Mac/MacEditingCommands.swift`) and generated the menu bar
from it. Ⅳb generalizes that table into **one registry that is the single declaration of every command folino has**,
and installs it on three surfaces: the menu bar (macOS, and iPadOS 26+), bare-key delivery (macOS, and iPad with a
hardware keyboard), and a searchable command sheet (`Z`).

Umbrella §2.3 is the reason this is a required component rather than a convenience:

> Capability is constrained by neither platform nor window size. Only placement varies.

The menu bar is the complete index; command search is what carries that guarantee to a device that has no menu bar.

## 1. Scope

In:

1. **The registry** — `MacEditingCommand` becomes platform-neutral `AppCommand`, and the three hand-written rows in
   `MacCommands` (Show Library, Import, Display Mode) join the same table.
2. **The menu bar, from the table** — one `Commands` implementation shared by macOS and iPadOS 26+.
3. **Bare-key delivery on iPad** — the shape Ⅳa measured on the Mac, extended to iOS, live only during an edit
   session.
4. **The command search sheet** — `Z` on macOS and on iPad with a hardware keyboard.

Out (decided 2026-09-03 with the user):

- **No on-screen entry point on iPhone.** Search is reached by hardware keyboard only, so the iPhone gets no new
  chrome in this slice. The umbrella's "iPhone search floor" is deferred; it needs its own placement design.
- **No symbols in the search sheet.** Symbol insertion is ssm sub-project Ⅰ's, consumed in Ⅳd. The sheet searches
  commands only.
- **No jump-to-object results** (rehearsal marks, measure numbers). A second result kind would need its own ranking
  and its own UI section; the registry is not blocked by leaving it out.
- Panels of any kind (`⌘0`–`⌘4`, `O`, `P`) and the tuplet/panel key collision they force. **Ⅳc**, which states the
  final key map.
- **No Playback rows.** Play / Pause is the transport bar's own `Space`, a view-level button shortcut Ⅳa measured
  (`MacTransportBar.playPauseButton`), and there is no Playback menu for it to join. Putting it in the table would
  mean a second owner of the same key. It becomes a row when Ⅳc gives playback a menu of its own.

## 2. Where the registry lives, and why

**`App/Shared/Commands/`.**

The registry is composition. One table holds Editor operations (`EditorViewModel`), the Reader's editing host, and
app-level actions (Show Library, Import, Display Mode) — and App is the only layer permitted to wire across
features (`docs/engineering/module-architecture.md`). `project.yml` compiles `App/Shared` into **both** the `Folino`
(iOS) and `FolinoMac` targets, and both share `App/Resources/Localizable.xcstrings`, so a shared home already
exists with no new package and no layer change.

Two alternatives were considered and rejected:

- **Generic machinery in `UtilityUI`, rows in `Editor`.** `Editor` may not depend on `Reader` or `Library`
  (Feature → Feature is forbidden), so the table would split in two and App would have to recompose it anyway. The
  generic half is ~100 lines of value types with no consumer outside folino.
- **The whole registry in the `Editor` package.** Same objection, and the app-level rows have nowhere to go.

The cost is that no package test target can reach the table. It is verified from `FolinoTests` (iOS) and
`FolinoMacTests` (macOS) instead, which is where `MacEditingCommandsTests` already lives.

## 3. The model

```swift
struct AppCommand: Identifiable {
    let id: String                       // stable English name: "notes.tuplet.triplet"
    let titleKey: String                 // key in App/Resources/Localizable.xcstrings
    let menu: AppCommandMenu             // file | edit | notes | measures | score | view
    let submenu: AppCommandSubmenu?
    let platforms: Set<AppCommandPlatform>   // default [.mac, .pad]
    let key: KeyEquivalent?
    let alternateKeys: [KeyEquivalent]
    let modifiers: EventModifiers
    let isMutating: Bool                 // inert while the transport runs (Ⅳa §6.2)
    let isEnabled: @MainActor @Sendable (AppCommandContext) -> Bool
    let perform: @MainActor @Sendable (AppCommandContext) -> Void
}
```

`AppCommandCatalog.all` is the single table. Everything else — menus, key map, search — is a projection of it.

### 3.1 The context

`MacEditingTarget` becomes `AppCommandContext`, a `@MainActor` class published as a `focusedSceneValue` by every
screen that can host commands:

```swift
@MainActor
final class AppCommandContext {
    let editor: EditorViewModel?          // nil when no score is on screen
    let host: ReaderEditingHost?
    var confirmDiscard: () -> Void        // File ▸ Revert To ▸ Last Opened
    var confirmRevert: () -> Void         // File ▸ Revert To ▸ Original
    var showLibrary: (() -> Void)?        // macOS only today
    var importScore: (() -> Void)?        // macOS only today
    var presentSearch: () -> Void
}
```

It stays one instance per screen, held in `@State` and filled by `wireOnce()` — the rule `MacEditingTarget`'s doc
comment already records (a new instance per body pass republishes the focused value and rebuilds the menus for
nothing).

### 3.2 Enablement — rows never disappear because of state

**A row's presence is decided by `platforms`; its state is decided by `isEnabled`.** A command is filtered out of a
platform's table only when the concept does not exist there, never because the moment is wrong. This is the
mechanized form of the decision taken for the iPad menu bar: with no edit session, Notes / Measures / Score are
still there, greyed. What a folino can do is legible from the menu bar at all times, and the answer does not change
as the user navigates.

Three enablement rules, in order:

1. `isMutating` and the transport is running → disabled (Ⅳa §6.2, unchanged).
2. **macOS** — the editing rows need `context.editor != nil`. The Mac is always editable inside a score window
   (Ⅳa: no edit mode), so a key score window is the whole condition.
3. **iOS** — the editing rows additionally need `host.isEditing`. Editing is a mode on iOS and the registry must
   respect it: the rows exist in the iPad menu bar while reading, greyed, and come alive when the session opens.

Rows that are Mac-only today, with `platforms: [.mac]`:

- **File ▸ Show Library** — iOS has no library window; the library is a screen the navigation stack already owns.
- **File ▸ Import** — `LibraryRootScreen` owns a non-public `.fileImporter` on iOS, so there is no seam for a menu
  row to drive. Recorded as `PARITY(ios): File ▸ Import — the iPad menu bar has no import row; Library's
  fileImporter is not reachable from the composition root`.

View ▸ Display Mode is **not** Mac-only: the picker writes `ReaderGlobalSettingsKey.layoutMode`, the same key the
iOS reader's visual inspector writes, so the same row is correct on both.

## 4. Surface 1 — the menu bar

`AppCommandMenus: Commands` replaces `MacEditingMenus` and absorbs `MacCommands`, generating rows from the table
filtered by the current platform. It is attached to the iOS `WindowGroup` as well as the Mac scenes.

- **macOS** — unchanged behavior: `CommandGroup(after: .saveItem)` for Revert To, `CommandGroup(after: .undoRedo)`
  for the Edit additions, `CommandMenu` for Notes / Measures / Score, `CommandGroup(before: .toolbar)` for Display
  Mode, `CommandGroup(after: .newItem)` for Show Library / Import.
- **iPadOS 26+** — the same `Commands` body surfaces in the system menu bar. Below iOS 26 there is no menu bar and
  the modifier-bearing shortcuts remain reachable as key commands; nothing is conditionally compiled, because
  `Commands` is available on iOS at the deployment floor. **This is the spec's one unverified assumption — see §8.**

`MacCommands.presentImportPanel` (its `NSOpenPanel` driving, and the reason the focused value is snapshotted before
the panel opens) moves into the Mac's context wiring unchanged. It is AppKit code and stays behind `#if os(macOS)`
in the composition, not in the table.

## 5. Surface 2 — key delivery

Ⅳa measured delivery **B** and this slice keeps it: modifier-bearing shortcuts sit on the menu item; **bare keys
are delivered by a view-level `.keyboardShortcut`** inside the score's view tree, because a view-level shortcut is
focus-aware and an `NSMenuItem` key equivalent is not (a focused `TextField` keeps the letter).

`MacEditingKeyMap` becomes `AppCommandKeyMap`, mounted by both `MacEditableReaderScreen` and the iOS reader's
editing seam. On iOS it is mounted **only while `host.isEditing`**, so a bare `A` cannot fire while reading.

`Z` (open search) is non-mutating and is mounted whenever a score is on screen — reading included, on both
platforms.

## 6. Surface 3 — the command search sheet

`CommandSearchSheet` is a `.sheet` on both platforms: a search field at the top, the results below, one row per
command showing its title, its menu path (`Notes ▸ Tuplet`), and its key equivalent right-aligned. A plain sheet,
not a floating `NSPanel` — a Spotlight-style panel means hand-building an `NSPanel` and its focus behavior, which
buys nothing this slice needs.

- **Matching** — case- and diacritic-insensitive substring, against **both the localized title and the command
  `id`**. The id is the stable English name, so a Japanese UI still finds `notes.tuplet.3` — whose title there is
  「3連符」— by typing "tuplet". MuseScore's vocabulary keeps working without a second, hand-maintained alias list.

  > **Corrected 2026-09-03 during implementation:** this paragraph first claimed the same row was reachable by
  > typing "triplet". It is not, in a Japanese UI: the id is `notes.tuplet.3` and the Japanese title is 「3連符」,
  > so neither field contains "triplet" — only the English title does. The guarantee the id buys is that the
  > **English MuseScore term in the id** keeps working in any language, and the id's term here is "tuplet". A test
  > written against the wrong example passes through the title and proves nothing about the id path.
- **Ranking** — prefix matches before substring matches; within a tier, table order. No recency, no frecency: a
  history would add persisted state for a list of about sixty rows.
- **Disabled rows are shown, greyed, and not selectable** — the same principle as the menu bar. A user who cannot
  find "Add Dot" because playback is running has learned nothing; one who sees it greyed has.
- **Interaction** — `Return` runs the top result, a click runs its row, `Esc` closes, and running a command closes
  the sheet. The empty query lists the whole table in menu order, which makes the sheet a readable index of the
  app on a device with no menu bar.

Matching and ranking are a pure function, `AppCommandSearch.results(matching:in:)`, so they are unit-testable
without a UI.

## 7. What each site installs

| Site | Installs |
| --- | --- |
| `FolinoMacApp` | `AppCommandMenus()` on the score `WindowGroup` and the library `Window` (as `MacCommands` is attached today) |
| `FolinoApp` (iOS) | `AppCommandMenus()` on the `WindowGroup` |
| `MacEditableReaderScreen` | publishes `AppCommandContext`; mounts `AppCommandKeyMap`; presents `CommandSearchSheet` |
| `EditableReaderScreen` (iOS) | the same three, with the key map gated on `host.isEditing` |
| `MacShellView` / library window | publishes a context with `editor: nil` and the app-level actions filled |

## 8. Risks, and the bench that goes first

**The iPadOS 26 menu bar is unverified.** Whether SwiftUI's `.commands` surfaces in the iPadOS 26 menu bar — and
whether a `CommandMenu` with no system-menu counterpart appears at all — is an assumption, not a measurement. Ⅳa
began with a bench for exactly this class of question and Ⅳb does the same. **Task 1 is a bench on the iPad 26
simulator** answering three questions, before any table is moved:

1. Does a SwiftUI `CommandMenu` appear in the iPadOS 26 menu bar, with its key equivalents live?
2. Does a bare-letter `.keyboardShortcut` on a focused view reach the view, and does a focused `TextField` still
   keep the letter (the iOS counterpart of Ⅳa's measurement)?
3. Does `Z` arrive from a hardware keyboard while a sheet is not open?

If (1) is false, §4's iPad half becomes a `UIMainMenuSystem` / `UIMenuBuilder` implementation in the app delegate
and the rest of the design is unaffected — the table still declares everything once. If (2) is false, iPad keeps
modifier-bearing shortcuts only, and the bare-key half is dropped from the slice.

**A second, smaller risk:** the iOS `WindowGroup` gaining `.commands` changes what a hardware keyboard does on
existing iPad builds below iOS 26 (key commands appear in the ⌘-hold HUD). That is an improvement, but it is
user-visible on a shipped app and belongs in the QA sheet.

## 9. Testing

Table properties, run from both hosts (`FolinoTests`, `FolinoMacTests`) — `MacEditingCommandsTests` moves here and
grows:

- ids are unique; every `titleKey` exists in `Localizable.xcstrings`.
- no two rows in the same menu share a key equivalent; no bare key is claimed twice across the whole table.
- every menu has at least one row after the platform filter, on both platforms.
- every mutating row is disabled by a context whose editor reports playback active.
- iOS: every editing row is disabled by a context whose `host.isEditing` is false.

`AppCommandSearch` gets its own unit tests: prefix beats substring, the id matches when the title does not
(the "triplet" case, asserted against a Japanese localization), disabled rows are present in the results and
carry their disabled state.

Gate (App-only change; no package is touched): iOS app build, Mac app build, `FolinoTests`, `FolinoMacTests`.
`Scripts/build-macos-packages.sh` is run anyway, as the cheap check that nothing leaked into a package.

## 10. Documents this revises

- `docs/superpowers/specs/2026-09-02-macos-edit-session-design.md` §5 — "Ⅳb generalizes the table" is now this
  document; §7's "command search, the iPad menu bar, the iPhone search floor" loses the iPhone half.
- `docs/superpowers/specs/2026-08-31-macos-app-design.md` §2.3 — the iPhone floor is deferred, so on iPhone the
  guarantee is currently carried by neither a menu bar nor search. Recorded rather than quietly dropped.
- `docs/engineering/ios-android-parity.md` — one new `PARITY(ios)` row (File ▸ Import).
