# Command Registry (Ⅳb) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make one table in `App/Shared/Commands/` the single declaration of every folino command, and generate the
menu bar (macOS + iPadOS 26+), bare-key delivery, and a searchable command sheet (`Z`) from it.

**Architecture:** `MacEditingCommand` becomes platform-neutral `AppCommand`; `MacCommands`'s three hand-written rows
join the table; `MacEditingTarget` becomes `AppCommandContext`, published as a `focusedSceneValue` by every screen
that can host commands. Menus, key map and search are projections of `AppCommandCatalog.all` — no surface holds a
list of its own. A row's presence is decided by `platforms`, its state by `isEnabled`; state never removes a row.

**Tech Stack:** Swift 6.3, SwiftUI (`Commands`, `CommandMenu`, `@FocusedValue`, `.keyboardShortcut`), Swift Testing,
XcodeGen, xcodebuild.

**Spec:** `docs/superpowers/specs/2026-09-03-command-registry-design.md`

## Global Constraints

- Deployment floor **iOS 18.0** / **macOS 15.0**. iOS 26-only API goes behind `if #available(iOS 26, macOS 26, *)`
  — never a bare `if #available(iOS 26, *)`, which the `*` satisfies on macOS at any floor.
- **`App/Shared` is compiled into three targets**: `Folino` (iOS), `FolinoMac`, and `FolinoScreenshot`. Anything
  added there must compile on both platforms and must not assume `FolinoApp.swift` exists (`FolinoScreenshot`
  excludes it).
- **String-catalog keys stay `mac.menu.*`.** They are identifiers, not user-visible copy; renaming ~60 keys risks
  the stale-key regeneration trap for no user benefit. New rows follow the same prefix.
- **User-facing app name is lowercase `folino`.** Internal feature names (Reader, Editor, Library) never appear in
  copy.
- Access modifiers: no `public` unless something outside the module needs it. Everything in `App/Shared` is
  internal.
- Comments reflow at 120 columns.
- The worktree has **no generated project**: run `xcodegen generate` once before the first build.
- Simulator destinations **must pin `OS=26.5`** — `name=iPhone 17 Pro Max` alone resolves to a 27.0 runtime.
- New tests use Swift Testing (`@Test`, `#expect`).
- Every task commits. No pushing.

## Commands

```sh
# once, in the worktree root
xcodegen generate

# Mac app build
Scripts/build-macos-app.sh

# Mac tests
xcodebuild test -project Folino.xcodeproj -scheme FolinoMac -destination 'platform=macOS' \
  -skipPackagePluginValidation -only-testing:FolinoMacTests

# iOS app build + tests
xcodebuild -project Folino.xcodeproj -scheme Folino \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max,OS=26.5' -skipPackagePluginValidation build
xcodebuild test -project Folino.xcodeproj -scheme Folino \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max,OS=26.5' -skipPackagePluginValidation \
  -only-testing:FolinoTests

# packages (cheap check that nothing leaked out of App/)
Scripts/build-macos-packages.sh
```

**Mac hosted tests hang while the screen is locked** ("hung before establishing connection"), and re-running does
not fix it. If that appears, say so and wait for the screen to be unlocked rather than retrying.

## File Structure

| File | Responsibility |
| --- | --- |
| `App/Shared/Commands/AppCommand.swift` | the row type, `AppCommandMenu`, `AppCommandSubmenu`, `AppCommandPlatform` |
| `App/Shared/Commands/AppCommandContext.swift` | what commands act on + the `FocusedValues` key |
| `App/Shared/Commands/AppCommandCatalog.swift` | **the table** — every row, declared once |
| `App/Shared/Commands/AppCommandMenus.swift` | `Commands`, generated from the table (macOS + iPadOS 26+) |
| `App/Shared/Commands/AppCommandKeyMap.swift` | bare-key delivery inside a score's view tree |
| `App/Shared/Commands/AppCommandSearch.swift` | pure matching + ranking |
| `App/Shared/Commands/CommandSearchSheet.swift` | the `Z` sheet |
| `App/Mac/MacCommandContextWiring.swift` | the AppKit half (`NSOpenPanel` import), macOS only |
| `Tests/FolinoMacTests/AppCommandCatalogTests.swift` | table invariants, macOS side (replaces `MacEditingCommandsTests`) |
| `Tests/FolinoTests/AppCommandCatalogTests.swift` | table invariants, iOS side + the `isEditing` gate |
| `Tests/FolinoMacTests/AppCommandSearchTests.swift` | matching and ranking |

Deleted by the end: `App/Mac/MacEditingCommand.swift`, `App/Mac/MacEditingCommands.swift`,
`App/Mac/MacEditingMenus.swift`, `App/Mac/MacEditingKeyMap.swift`, `App/Mac/MacCommands.swift`.

---

### Task 1: Bench — does the iPadOS 26 menu bar carry SwiftUI `Commands`?

The spec's §8 assumption. Measured before anything moves, so a false answer changes the plan and not the code.

**Files:**
- Modify (temporarily, reverted in Step 7): `App/iOS/FolinoApp.swift`
- Create: `docs/superpowers/plans/2026-09-03-command-registry-bench.md`

**Interfaces:**
- Consumes: nothing.
- Produces: the bench document, and the answer to "iPad menu bar: SwiftUI `Commands`, or `UIMainMenuSystem`?" that
  Task 6 reads.

- [ ] **Step 1: Generate the project and create a bench iPad**

```sh
xcodegen generate
xcrun simctl create "iPad-Bench-26" \
  com.apple.CoreSimulator.SimDeviceType.iPad-Pro-11-inch-M4-8GB \
  com.apple.CoreSimulator.SimRuntime.iOS-26-5
xcrun simctl boot "iPad-Bench-26"
```

Only `FolinoShot-iPad2` (iOS 27.0) exists otherwise, and it belongs to the screenshot workflow — do not use it.

- [ ] **Step 2: Add the temporary probe to `FolinoApp`**

Add to the `WindowGroup` in `App/iOS/FolinoApp.swift`, immediately after `.onOpenURL { … }`:

```swift
        .commands {
            CommandMenu(Text(verbatim: "Bench")) {
                Button {
                    NSLog("[BENCH] modified fired")
                } label: {
                    Text(verbatim: "Modified ⌘⌥B")
                }
                .keyboardShortcut("b", modifiers: [.command, .option])
                Button {
                    NSLog("[BENCH] bare fired")
                } label: {
                    Text(verbatim: "Bare Z")
                }
                .keyboardShortcut("z", modifiers: [])
            }
        }
```

`import Foundation` is already implied by SwiftUI; add it explicitly if the build complains about `NSLog`.

- [ ] **Step 3: Build, install, launch on the bench iPad**

```sh
xcodebuild -project Folino.xcodeproj -scheme Folino \
  -destination 'platform=iOS Simulator,name=iPad-Bench-26,OS=26.5' \
  -skipPackagePluginValidation -derivedDataPath /tmp/BenchDD build
xcrun simctl install "iPad-Bench-26" /tmp/BenchDD/Build/Products/Debug-iphonesimulator/folino.app
xcrun simctl launch "iPad-Bench-26" com.KeyNumber.Folino
```

- [ ] **Step 4: Arm the log reader**

```sh
xcrun simctl spawn "iPad-Bench-26" log stream --style compact --predicate 'eventMessage CONTAINS "[BENCH]"'
```

Run it in the background and read its output file; it is how Steps 5–6 are measured rather than guessed.

- [ ] **Step 5: Hand these three questions to the user**

This is the one part no tool can do — the menu bar is revealed by a pointer or a swipe, and this repo forbids
driving the simulator with UI automation. Ask exactly this, and wait:

1. In the simulator, enable **I/O ▸ Keyboard ▸ Connect Hardware Keyboard**. Then move the pointer to the top of
   the iPad screen (or swipe down from the very top edge). **Does a menu bar appear, and is there a "Bench" menu
   in it with two items?**
2. With the library on screen and no text field focused, **press `Z`.** (The `[BENCH] bare fired` line in the log
   is the answer; the user only has to press the key.)
3. Tap the library's search field, type **`zzz`**. **Do the three letters appear in the field?** (If `[BENCH] bare
   fired` appears in the log instead, a bare key equivalent is stealing typing on iOS and §5's iPad half is off.)

- [ ] **Step 6: Write the bench document**

Create `docs/superpowers/plans/2026-09-03-command-registry-bench.md` recording, for each of the three questions:
the exact question, what was observed (menu present / absent; log line present / absent; letters typed / stolen),
and the consequence for the plan:

- Q1 false → Task 6 installs the iPad menu bar through `UIMainMenuSystem` in a `UIApplicationDelegateAdaptor`
  instead of `.commands`; the table and every other task are unaffected.
- Q3 false → Task 7 drops bare-key delivery on iOS; the iPad keeps modifier-bearing shortcuts and `Z` only, and
  the spec's §5 gets a revision note.

- [ ] **Step 7: Revert the probe and commit the bench**

```sh
git checkout App/iOS/FolinoApp.swift
git add docs/superpowers/plans/2026-09-03-command-registry-bench.md
git commit -m "docs(commands): bench the iPadOS 26 menu bar before moving the table"
```

---

### Task 2: Move the table to `App/Shared` as `AppCommand`

Pure move and rename. **No behavior change on the Mac** — this task is green exactly when the Mac menu bar and key
map behave as they did before it.

**Files:**
- Create: `App/Shared/Commands/AppCommand.swift`, `App/Shared/Commands/AppCommandContext.swift`,
  `App/Shared/Commands/AppCommandCatalog.swift`, `App/Shared/Commands/AppCommandMenus.swift`,
  `App/Shared/Commands/AppCommandKeyMap.swift`
- Delete: `App/Mac/MacEditingCommand.swift`, `App/Mac/MacEditingCommands.swift`, `App/Mac/MacEditingMenus.swift`,
  `App/Mac/MacEditingKeyMap.swift`
- Modify: `App/Mac/MacEditableReaderScreen.swift`, `App/Mac/FolinoMacApp.swift`
- Test: `Tests/FolinoMacTests/AppCommandCatalogTests.swift` (renamed from `MacEditingCommandsTests.swift`)

**Interfaces:**
- Consumes: nothing.
- Produces: `AppCommand`, `AppCommandMenu`, `AppCommandSubmenu`, `AppCommandPlatform`, `AppCommandContext`,
  `AppCommandCatalog.all` / `.commands(in:)` / `.topLevelCommands(in:)` / `.submenus(in:)`, `AppCommandMenus`,
  `AppCommandKeyMap`, `FocusedValues.appCommandContext`.

The rename table, applied verbatim:

| Old | New |
| --- | --- |
| `MacEditingCommand` | `AppCommand` |
| `MacEditingMenu` | `AppCommandMenu` |
| `MacEditingSubmenu` | `AppCommandSubmenu` |
| `MacEditingCommands` | `AppCommandCatalog` |
| `MacEditingTarget` | `AppCommandContext` |
| `MacEditingMenus` | `AppCommandMenus` |
| `MacEditingKeyMap` | `AppCommandKeyMap` |
| `MacEditingKeyDelivery` | `AppCommandKeyDelivery` |
| `FocusedValues.macEditingTarget` | `FocusedValues.appCommandContext` |

- [ ] **Step 1: Rename the test file first, so the move is measured**

```sh
git mv Tests/FolinoMacTests/MacEditingCommandsTests.swift Tests/FolinoMacTests/AppCommandCatalogTests.swift
```

Apply the rename table inside it (`struct MacEditingCommandsTests` → `struct AppCommandCatalogTests`,
`MacEditingCommands.all` → `AppCommandCatalog.all`, `MacEditingTarget(editor:host:)` →
`AppCommandContext(editor:host:)`, `MacEditingMenu.allCases` → `AppCommandMenu.allCases`).

- [ ] **Step 2: Run the tests to verify they fail**

Run: the Mac test command from **Commands**.
Expected: FAIL to compile — "cannot find 'AppCommandCatalog' in scope".

- [ ] **Step 3: Move the four files, applying the rename table**

`git mv` each file to its new home and rename inside; the bodies are otherwise unchanged, doc comments included.

```sh
git mv App/Mac/MacEditingCommand.swift App/Shared/Commands/AppCommand.swift
git mv App/Mac/MacEditingCommands.swift App/Shared/Commands/AppCommandCatalog.swift
git mv App/Mac/MacEditingMenus.swift App/Shared/Commands/AppCommandMenus.swift
git mv App/Mac/MacEditingKeyMap.swift App/Shared/Commands/AppCommandKeyMap.swift
```

Three edits beyond the rename:

1. `AppCommand` gains `platforms`, defaulting to both, and the catalog is filtered by the platform this build is:

```swift
enum AppCommandPlatform: CaseIterable {
    case mac, pad

    /// The platform this build runs on. iPhone is `pad` too — it reaches the same rows through the search sheet,
    /// and no row is iPhone-specific.
    static var current: AppCommandPlatform {
        #if os(macOS)
        .mac
        #else
        .pad
        #endif
    }
}
```

```swift
    let platforms: Set<AppCommandPlatform>
```

with `platforms: Set<AppCommandPlatform> = Set(AppCommandPlatform.allCases)` in the initializer, stored before
`isEnabled`.

2. `AppCommandCatalog.all` stays the unfiltered table; every projection reads a filtered view:

```swift
    /// The rows this platform has. `all` stays unfiltered so the tests can assert about the whole table.
    static var current: [AppCommand] {
        all.filter { $0.platforms.contains(AppCommandPlatform.current) }
    }

    static func commands(in menu: AppCommandMenu) -> [AppCommand] {
        current.filter { $0.menu == menu }
    }
```

3. `AppCommandContext` moves out of `MacEditableReaderScreen.swift` into
   `App/Shared/Commands/AppCommandContext.swift`, with `editor` and `host` becoming optional and the app-level
   actions added:

```swift
@MainActor
final class AppCommandContext {
    /// `nil` when no score is on screen — the library window on the Mac, the library screen on iOS.
    let editor: EditorViewModel?
    let host: ReaderEditingHost?
    /// File ▸ Revert To ▸ Last Opened; the screen owns the confirmation this arms.
    var confirmDiscard: () -> Void = {}
    /// File ▸ Revert To ▸ Original.
    var confirmRevert: () -> Void = {}
    /// Filled by the Mac's shell only — iOS has no library window and no reachable importer (spec §3.2).
    var showLibrary: (() -> Void)?
    var importScore: (() -> Void)?
    /// Raises the command search sheet. Filled by whichever screen owns the sheet's presentation state.
    var presentSearch: () -> Void = {}

    init(editor: EditorViewModel?, host: ReaderEditingHost?) {
        self.editor = editor
        self.host = host
    }
}
```

The initializer's playback guard becomes optional-aware in the same edit — `context.editor?.isPlaybackActive !=
true` in place of `!target.editor.isPlaybackActive`, so a context with no editor is not treated as playing.

Every `isEnabled` / `perform` closure in the catalog that reads `target.editor` now unwraps it. Use one helper at
the top of `AppCommandCatalog` so the ~50 rows stay one-liners:

```swift
    /// Most rows need an editor and do nothing without one. `requiringEditor` wraps the pair so a row still reads
    /// as a single declaration.
    private static func editorRow(
        _ id: String, _ titleKey: String, menu: AppCommandMenu, submenu: AppCommandSubmenu? = nil,
        key: KeyEquivalent? = nil, alternateKeys: [KeyEquivalent] = [], modifiers: EventModifiers = [],
        mutating: Bool = true,
        isEnabled: @escaping @MainActor @Sendable (EditorViewModel) -> Bool = { _ in true },
        perform: @escaping @MainActor @Sendable (EditorViewModel) -> Void,
    ) -> AppCommand {
        AppCommand(
            id, titleKey, menu: menu, submenu: submenu, key: key, alternateKeys: alternateKeys,
            modifiers: modifiers, mutating: mutating,
            isEnabled: { context in context.editor.map(isEnabled) ?? false },
            perform: { context in context.editor.map(perform) },
        )
    }
```

- [ ] **Step 4: Update the two Mac call sites**

`MacEditableReaderScreen.swift`: delete the `MacEditingTarget` class and its `FocusedValueKey` (they moved),
construct `AppCommandContext(editor: editorViewModel, host: editingHost)`, publish
`.focusedSceneValue(\.appCommandContext, editingTarget)`, and mount `AppCommandKeyMap(context:)`.
`FolinoMacApp.swift`: `MacEditingMenus()` → `AppCommandMenus()`.

- [ ] **Step 5: Regenerate and run the tests**

```sh
xcodegen generate
```

Run: the Mac test command.
Expected: PASS, the same count as before the move (33 at `0e690c4a`).

- [ ] **Step 6: Build both apps**

Run: `Scripts/build-macos-app.sh`, then the iOS build command. Both must succeed — the iOS one is what proves the
moved table compiles on a platform it has never been compiled on.

- [ ] **Step 7: Commit**

```sh
git add -A App/Shared/Commands App/Mac Tests/FolinoMacTests
git commit -m "refactor(commands): lift the editing table into App/Shared as AppCommand"
```

---

### Task 3: Absorb `MacCommands` into the table

Show Library, Import and Display Mode become rows, and one `AppCommandMenus` generates the whole menu bar.

**Files:**
- Modify: `App/Shared/Commands/AppCommandCatalog.swift`, `App/Shared/Commands/AppCommand.swift`,
  `App/Shared/Commands/AppCommandMenus.swift`, `App/Mac/FolinoMacApp.swift`, `App/Mac/MacShellView.swift`
- Create: `App/Mac/MacCommandContextWiring.swift`
- Delete: `App/Mac/MacCommands.swift`
- Test: `Tests/FolinoMacTests/AppCommandCatalogTests.swift`

**Interfaces:**
- Consumes: everything Task 2 produced.
- Produces: `AppCommandMenu.view`, rows `file.showLibrary`, `file.import`, `view.displayMode.page` /
  `.vertical` / `.horizontal`; `MacCommandContextWiring.presentImportPanel(_:)`.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/FolinoMacTests/AppCommandCatalogTests.swift`:

```swift
    @Test func `the app level rows are in the table`() {
        let ids = Set(AppCommandCatalog.all.map(\.id))
        #expect(ids.contains("file.showLibrary"))
        #expect(ids.contains("file.import"))
        #expect(ids.contains("view.displayMode.page"))
    }

    /// Spec §3.2: a row is filtered out only where the concept does not exist. Show Library and Import are the
    /// only two, and Display Mode is deliberately NOT one of them — it writes the same preference key the iOS
    /// reader's visual inspector writes.
    @Test func `only the two library rows are Mac only`() {
        let macOnly = AppCommandCatalog.all.filter { $0.platforms == [.mac] }.map(\.id)
        #expect(Set(macOnly) == ["file.showLibrary", "file.import"])
    }

    @Test @MainActor func `the app level rows are disabled when the context cannot serve them`() {
        let context = AppCommandContext(editor: nil, host: nil)
        let showLibrary = AppCommandCatalog.all.first { $0.id == "file.showLibrary" }
        #expect(showLibrary?.isEnabled(context) == false)
        context.showLibrary = {}
        #expect(showLibrary?.isEnabled(context) == true)
    }
```

- [ ] **Step 2: Run to verify they fail**

Run: the Mac test command.
Expected: FAIL — the ids are absent.

- [ ] **Step 3: Add `view` to the menu enum and the three rows to the table**

```swift
enum AppCommandMenu: CaseIterable {
    case file, edit, notes, measures, score, view
}
```

```swift
    // MARK: File — the shell's own rows (was `MacCommands`)

    private static let shell: [AppCommand] = [
        .init(
            "file.showLibrary", "mac.menu.showLibrary", menu: .file, platforms: [.mac],
            key: "o", modifiers: .command, mutating: false,
            isEnabled: { $0.showLibrary != nil },
            perform: { $0.showLibrary?() },
        ),
        .init(
            "file.import", "mac.menu.import", menu: .file, platforms: [.mac],
            key: "i", modifiers: [.command, .shift], mutating: false,
            isEnabled: { $0.importScore != nil },
            perform: { $0.importScore?() },
        ),
    ]
```

Display Mode is three rows in the `.view` menu, in a new `displayMode` submenu — `.view` also holds the search row
(Task 5) at its top level, so the modes must not be the whole menu:

```swift
enum AppCommandSubmenu: String, CaseIterable {
    case pitch, duration, accidental, chord, tuplet, voice, displayMode
}
```

`AppCommandSubmenu.titleKey` interpolates `mac.menu.notes.\(rawValue)`, which is wrong for a View submenu. Give the
enum an explicit key instead:

```swift
    var titleKey: String {
        switch self {
        case .displayMode: "mac.menu.displayMode"
        case .revertTo: "mac.menu.revertTo"
        default: "mac.menu.notes.\(rawValue)"
        }
    }
```

(`revertTo` is added in Step 4; both cases exist by the end of this task.)

Each row writes `ReaderGlobalSettingsKey.layoutMode`. `@AppStorage` is a property wrapper for a `View`, not for a
table of static rows, so the read and write are plain `UserDefaults` — the same key and the same resolution
function `MacCommands` used, so the checkmark still names the mode actually on screen:

```swift
    private static var storedLayoutMode: ReaderLayoutMode {
        get {
            ReaderLayoutMode.macDisplayMode(
                storedRawValue: UserDefaults.standard.string(forKey: ReaderGlobalSettingsKey.layoutMode)
                    ?? ReaderLayoutMode.page.rawValue,
            )
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: ReaderGlobalSettingsKey.layoutMode) }
    }

    private static func displayModeRow(_ mode: ReaderLayoutMode, _ titleKey: String) -> AppCommand {
        AppCommand(
            "view.displayMode.\(mode.rawValue)", titleKey, menu: .view, submenu: .displayMode, mutating: false,
            isEnabled: { _ in true },
            perform: { _ in storedLayoutMode = mode },
        )
    }

    /// Drives the checkmark in the View ▸ Display Mode submenu.
    static func isDisplayModeCurrent(_ command: AppCommand) -> Bool {
        command.id == "view.displayMode.\(storedLayoutMode.rawValue)"
    }
```

`@AppStorage`'s binding in `MacCommands` existed to drive a `Picker`'s checkmark. `AppCommandMenus` shows the
three rows with a checkmark on the current one instead (Step 4), which is the same affordance without a second
source of truth.

- [ ] **Step 4: Generate the whole menu bar from the table**

The File menu now holds two kinds of row, so the Revert To pair moves into its own submenu rather than being
identified by id. Add `revertTo` to `AppCommandSubmenu` (titleKey `mac.menu.revertTo`), mark the two existing
revert rows `submenu: .revertTo`, and let the generation split them:

```swift
        CommandGroup(after: .saveItem) {
            Menu {
                items(in: .file, submenu: .revertTo)
            } label: {
                Text(AppCommandSubmenu.revertTo.title)
            }
            .disabled(context == nil)
        }
        CommandGroup(after: .newItem) {
            // Top-level `.file` rows only — Show Library and Import. The revert rows are in the submenu above.
            ForEach(AppCommandCatalog.topLevelCommands(in: .file)) { command in
                AppCommandMenuItem(command: command, context: context)
            }
        }
        CommandGroup(before: .toolbar) {
            items(in: .view)
            Divider()
        }
```

`items(in:)` already emits top-level rows first and then one `Menu` per submenu, so the search row (Task 5) sits at
the top of the group and the three modes sit inside a Display Mode submenu. No new generation shape is needed.

The checkmark is drawn by `AppCommandMenuItem`: when `AppCommandCatalog.isDisplayModeCurrent(command)` is true the
label becomes `Label { Text(command.title) } icon: { Image(systemName: "checkmark") }`.

- [ ] **Step 5: Move the `NSOpenPanel` half to `MacCommandContextWiring`**

Create `App/Mac/MacCommandContextWiring.swift` holding `presentImportPanel(_ action: ((URL) async -> Void)?)`,
copied verbatim from `MacCommands.presentImportPanel` — **including its doc comment about snapshotting the
focused value before the panel becomes key window**, which is a measured hazard and not incidental. `MacShellView`
and the library window fill `context.importScore` with a closure that calls it, and `context.showLibrary` with
`openWindow(id: MacWindowID.library)`.

- [ ] **Step 6: Delete `MacCommands.swift` and drop it from `FolinoMacApp`**

`FolinoMacApp`'s `.commands { MacCommands(); MacEditingMenus() }` becomes `.commands { AppCommandMenus() }`.

- [ ] **Step 7: Run the tests and build**

Run: the Mac test command, then `Scripts/build-macos-app.sh`.
Expected: PASS; the new tests included.

- [ ] **Step 8: Verify the menus by eye**

Launch the built Mac app and confirm: File carries Show Library / Import / Revert To; View carries Display Mode
with a checkmark on the current mode; Notes / Measures / Score are unchanged from before this task. Report what
was seen — this is the only check that catches a row generated into the wrong group.

- [ ] **Step 9: Commit**

```sh
git add -A App Tests
git commit -m "feat(commands): the whole Mac menu bar is generated from one table"
```

---

### Task 4: `AppCommandSearch` — matching and ranking

A pure function, tested without a UI.

**Files:**
- Create: `App/Shared/Commands/AppCommandSearch.swift`
- Test: `Tests/FolinoMacTests/AppCommandSearchTests.swift`

**Interfaces:**
- Consumes: `AppCommand`, `AppCommandCatalog`.
- Produces: `AppCommandSearch.results(matching:in:)` returning `[AppCommand]`, and
  `AppCommandSearch.menuPath(of:)` returning a `LocalizedStringKey` list for the row's subtitle.

- [ ] **Step 1: Write the failing tests**

```swift
@testable import folino
import SwiftUI
import Testing

struct AppCommandSearchTests {
    private let table = AppCommandCatalog.current

    @Test func `an empty query returns the whole table in table order`() {
        #expect(AppCommandSearch.results(matching: "", in: table).map(\.id) == table.map(\.id))
    }

    /// The id is the stable English name, so MuseScore's vocabulary keeps working in a Japanese UI without a
    /// second, hand-maintained alias list (spec §6).
    @Test func `a command is found by its English id when the title is localized`() {
        let ids = AppCommandSearch.results(matching: "triplet", in: table).map(\.id)
        #expect(ids.contains("notes.tuplet.3"))
    }

    @Test func `a prefix match outranks a substring match`() {
        let rows = [
            AppCommand("b.deleted", "mac.menu.notes", menu: .notes, perform: { _ in }),
            AppCommand("delete.row", "mac.menu.notes", menu: .notes, perform: { _ in }),
        ]
        #expect(AppCommandSearch.results(matching: "delete", in: rows).map(\.id) == ["delete.row", "b.deleted"])
    }

    @Test func `matching ignores case`() {
        #expect(!AppCommandSearch.results(matching: "TRIPLET", in: table).isEmpty)
    }

    @Test func `a query that matches nothing returns nothing`() {
        #expect(AppCommandSearch.results(matching: "zzzznothing", in: table).isEmpty)
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `… -only-testing:FolinoMacTests/AppCommandSearchTests`
Expected: FAIL — "cannot find 'AppCommandSearch' in scope".

- [ ] **Step 3: Implement**

```swift
/// Matching and ranking for the command sheet, kept out of the view so it can be tested without one.
enum AppCommandSearch {
    /// Rows whose localized title or stable id contains `query`, prefix matches first and table order within a
    /// tier. An empty query is the whole table — that is what makes the sheet a readable index of the app on a
    /// device with no menu bar (spec §6).
    static func results(matching query: String, in commands: [AppCommand]) -> [AppCommand] {
        let needle = normalized(query)
        guard !needle.isEmpty else { return commands }
        var prefix: [AppCommand] = []
        var substring: [AppCommand] = []
        for command in commands {
            let haystacks = [normalized(command.localizedTitle), normalized(command.id)]
            if haystacks.contains(where: { $0.hasPrefix(needle) }) {
                prefix.append(command)
            } else if haystacks.contains(where: { $0.contains(needle) }) {
                substring.append(command)
            }
        }
        return prefix + substring
    }

    private static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }
}
```

`localizedTitle` is a new computed property on `AppCommand` — `Bundle.main.localizedString(forKey: titleKey,
value: titleKey, table: nil)` — because `LocalizedStringKey` cannot be read back as a string.

- [ ] **Step 4: Run to verify they pass**

Run: the same command.
Expected: PASS, 5 tests.

- [ ] **Step 5: Commit**

```sh
git add App/Shared/Commands/AppCommandSearch.swift App/Shared/Commands/AppCommand.swift \
  Tests/FolinoMacTests/AppCommandSearchTests.swift
git commit -m "feat(commands): match commands by localized title and English id"
```

---

### Task 5: The search sheet, and `Z` on the Mac

**Files:**
- Create: `App/Shared/Commands/CommandSearchSheet.swift`
- Modify: `App/Shared/Commands/AppCommandCatalog.swift` (the `Z` row),
  `App/Mac/MacEditableReaderScreen.swift`, `App/Mac/MacShellView.swift`
- Test: `Tests/FolinoMacTests/AppCommandCatalogTests.swift`

**Interfaces:**
- Consumes: `AppCommandSearch`, `AppCommandContext`.
- Produces: `CommandSearchSheet(context:isPresented:)`, catalog row `app.search`.

- [ ] **Step 1: Write the failing test**

```swift
    /// `Z` is free in MuseScore's Mac map (umbrella §2.2) and is the Master Palette's successor. It is
    /// non-mutating, so it stays live while the transport runs.
    @Test @MainActor func `search is bound to a bare Z and survives playback`() {
        let search = AppCommandCatalog.all.first { $0.id == "app.search" }
        #expect(search?.key?.character == "z")
        #expect(search?.modifiers.isEmpty == true)
        #expect(search?.isMutating == false)
    }
```

- [ ] **Step 2: Run to verify it fails**

Expected: FAIL — no `app.search` row.

- [ ] **Step 3: Add the row**

```swift
        .init(
            "app.search", "mac.menu.commandSearch", menu: .view, key: "z", mutating: false,
            isEnabled: { _ in true },
            perform: { $0.presentSearch() },
        ),
```

Add **two** keys to `App/Resources/Localizable.xcstrings`:

| key | en | ja |
| --- | --- | --- |
| `mac.menu.commandSearch` | `Find Command…` | `コマンドを検索…` |
| `mac.commandSearch.placeholder` | `Search commands` | `コマンドを検索` |

Edit the catalog by hand rather than letting Xcode regenerate it — a missed key is silently recreated as a stale
entry (recorded repo-wide trap).

- [ ] **Step 4: Build the sheet**

```swift
/// The layer that carries umbrella §2.3's guarantee to a device with no menu bar: one searchable list of every
/// command the platform has. A sheet, not a floating panel — an `NSPanel` would mean hand-building focus
/// behavior for nothing this slice needs.
struct CommandSearchSheet: View {
    let context: AppCommandContext
    @Binding var isPresented: Bool
    @State private var query = ""
    @FocusState private var isFieldFocused: Bool

    private var results: [AppCommand] {
        AppCommandSearch.results(matching: query, in: AppCommandCatalog.current)
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("mac.commandSearch.placeholder", text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($isFieldFocused)
                .padding()
                .onSubmit { run(results.first) }
            Divider()
            List(results) { command in
                CommandSearchRow(command: command, isEnabled: command.isEnabled(context))
                    .contentShape(.rect)
                    .onTapGesture { run(command) }
            }
            .listStyle(.plain)
        }
        .frame(minWidth: 420, minHeight: 360)
        .onAppear { isFieldFocused = true }
    }

    private func run(_ command: AppCommand?) {
        guard let command, command.isEnabled(context) else { return }
        isPresented = false
        command.perform(context)
    }
}
```

`CommandSearchRow` shows the title, the menu path as a caption, and the key equivalent right-aligned; a disabled
row renders at `.secondary` and ignores the tap (spec §6 — disabled rows are shown, greyed, not selectable).

- [ ] **Step 5: Present it from the Mac's screens**

`MacEditableReaderScreen` and `MacShellView` each hold `@State private var isSearching = false`, fill
`context.presentSearch = { isSearching = true }` in `wireOnce()`, and attach
`.sheet(isPresented: $isSearching) { CommandSearchSheet(context: context, isPresented: $isSearching) }`.

**Do not attach the sheet to a `Section`** — a presentation modifier on a `Section` closes the moment it opens
(recorded repo-wide trap).

- [ ] **Step 6: Run the tests and build**

Run: the Mac test command, then `Scripts/build-macos-app.sh`.
Expected: PASS.

- [ ] **Step 7: Verify by eye**

Launch the Mac app, open a score, press `Z`. Confirm: the sheet opens focused, typing `trip` narrows to the
triplet rows, `Return` runs the top one and closes the sheet, `Esc` closes it, and starting playback then
reopening the sheet shows the mutating rows greyed. Report what was seen.

- [ ] **Step 8: Commit**

```sh
git add -A App Tests
git commit -m "feat(commands): add the searchable command sheet, on Z"
```

---

### Task 6: The iPad menu bar

**Files:**
- Modify: `App/iOS/FolinoApp.swift`, `App/iOS/EditableReaderScreen.swift`,
  `App/Shared/Commands/AppCommandCatalog.swift`
- Test: `Tests/FolinoTests/AppCommandCatalogTests.swift` (new)

**Interfaces:**
- Consumes: `AppCommandMenus`, `AppCommandContext`.
- Produces: the iOS publication of `FocusedValues.appCommandContext`; the `host.isEditing` enablement rule.

Read Task 1's bench document first. If Q1 was false, install the menu bar through `UIMainMenuSystem` in a
`UIApplicationDelegateAdaptor` instead of Step 3's `.commands`, building the same rows from the same table.

- [ ] **Step 1: Write the failing tests**

Create `Tests/FolinoTests/AppCommandCatalogTests.swift`:

```swift
@testable import Editor
@testable import folino
import Reader
import SwiftUI
import Testing

/// The iOS half of the table's invariants. Editing is a mode here, unlike the Mac (Ⅳa: no edit mode), so the
/// rows exist while reading and come alive with the session.
struct AppCommandCatalogTests {
    @Test func `the Mac only rows are absent on iOS`() {
        let ids = Set(AppCommandCatalog.current.map(\.id))
        #expect(!ids.contains("file.showLibrary"))
        #expect(!ids.contains("file.import"))
    }

    @Test func `display mode and search are present on iOS`() {
        let ids = Set(AppCommandCatalog.current.map(\.id))
        #expect(ids.contains("view.displayMode.page"))
        #expect(ids.contains("app.search"))
    }

    @Test @MainActor func `editing rows are disabled while not in an edit session`() {
        let host = ReaderEditingHost()
        let context = AppCommandContext(editor: PreviewEditorFactory.makeViewModel(), host: host)
        let tie = AppCommandCatalog.all.first { $0.id == "notes.tie" }
        #expect(tie?.isEnabled(context) == false, "editing rows must be inert while reading")
    }

    @Test func `every menu still has a row after the iOS platform filter`() {
        for menu in AppCommandMenu.allCases {
            #expect(!AppCommandCatalog.commands(in: menu).isEmpty, "\(menu)")
        }
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: the iOS test command with `-only-testing:FolinoTests/AppCommandCatalogTests`.
Expected: FAIL — the editing rows are enabled, because nothing consults `isEditing` yet.

- [ ] **Step 3: Add the iOS enablement rule**

`AppCommand.isEnabled` is a `let`, so it is composed once rather than reassigned. Replace the initializer's
existing `if mutating { … } else { … }` assignment with a single composition:

```swift
        // Two wrappers, applied outermost-first, so the cheapest refusal wins: a mutating row is dead while the
        // transport runs (§6.2), and on iOS every row that needs an editor is dead outside an edit session —
        // editing is a mode here, unlike the Mac (spec §3.2). A row with no editor at all (Display Mode, search)
        // passes both guards.
        let rule = isEnabled
        let sessionGated: @MainActor @Sendable (AppCommandContext) -> Bool
        #if os(macOS)
        sessionGated = rule
        #else
        sessionGated = { context in
            guard context.editor == nil || context.host?.isEditing == true else { return false }
            return rule(context)
        }
        #endif
        if mutating {
            self.isEnabled = { context in
                guard context.editor?.isPlaybackActive != true else { return false }
                return sessionGated(context)
            }
        } else {
            self.isEnabled = sessionGated
        }
```

Note the playback guard now reads `context.editor?.isPlaybackActive != true` rather than
`!target.editor.isPlaybackActive`, because the editor is optional from Task 2 onward.

Rows with no editor at all (Display Mode, search) are unaffected — the guard passes when `editor` is `nil`.

- [ ] **Step 4: Publish the context and attach the menus**

`EditableReaderScreen`: hold `@State private var commandContext` built as
`AppCommandContext(editor: editorViewModel, host: editingHost)` (one instance, never rebuilt in `body` — the same
rule `AppCommandContext`'s doc comment records), and publish
`.focusedSceneValue(\.appCommandContext, commandContext)`.

`FolinoApp`: add `.commands { AppCommandMenus() }` to the `WindowGroup`.

- [ ] **Step 5: Run the tests and build**

Run: the iOS test command, then the iOS build command, then the Mac test command (the shared enablement change
must not move the Mac).
Expected: PASS on all three.

- [ ] **Step 6: Verify on the bench iPad**

Install and launch on `iPad-Bench-26`, then hand to the user: "Reveal the menu bar with a score open but not in
an edit session — Notes / Measures / Score should be there and greyed. Start editing — they should come alive."
Report what was seen.

- [ ] **Step 7: Commit**

```sh
git add -A App Tests
git commit -m "feat(commands): give the iPad the same menu bar, from the same table"
```

---

### Task 7: Bare keys and the search sheet on iPad

Skip Steps 3–4 if Task 1's Q3 came back false; record that in the QA sheet instead.

**Files:**
- Modify: `App/iOS/EditableReaderScreen.swift`, `docs/engineering/ios-android-parity.md` (regenerated)
- Modify: `App/Mac/MacCommandContextWiring.swift` (the `PARITY(ios)` marker's home)

**Interfaces:**
- Consumes: `AppCommandKeyMap`, `CommandSearchSheet`.
- Produces: nothing new; this is the last wiring site.

- [ ] **Step 1: Mount the key map, gated on the session**

In `EditableReaderScreen`'s body, inside the reader's tree:

```swift
            .background {
                if editingHost.isEditing {
                    AppCommandKeyMap(context: commandContext)
                }
            }
```

The gate is what keeps a bare `A` from firing while reading; on the Mac the same view is mounted unconditionally
because the Mac is always editable inside a score window.

- [ ] **Step 2: Present the sheet**

Same three lines as Task 5 Step 5 — `@State private var isSearching`, `context.presentSearch`, and the
`.sheet`. `Z` is not session-gated, so its key map entry lives outside the `isEditing` branch: mount a second,
one-row `AppCommandKeyMap(context:only: ["app.search"])` unconditionally, and add that `only:` filter to the key
map.

- [ ] **Step 3: Record the parity gap**

Add above `presentImportPanel` in `App/Mac/MacCommandContextWiring.swift`:

```swift
// PARITY(ios): File ▸ Import — the iPad menu bar has no import row. `LibraryRootScreen` owns a non-public
//   `.fileImporter`, so the composition root has no seam to drive; a menu row needs Library to expose one.
```

Then regenerate the ledger:

```sh
Scripts/parity-report.py
```

Continuation lines need **two or more leading spaces** — one space is silently dropped and truncates the row.

- [ ] **Step 4: Run the gates**

Run: the iOS test command, the Mac test command, both app builds, and `Scripts/build-macos-packages.sh`.
Expected: all green; the parity ledger clean (the pre-commit hook fails if it drifted).

- [ ] **Step 5: Verify on the bench iPad**

Hand to the user: with a hardware keyboard connected and an edit session open, `5` sets a quarter note, `A`–`G`
write pitches, `Z` opens the search sheet, and typing in the search field inserts letters rather than firing
commands. Report what was seen.

- [ ] **Step 6: Commit**

```sh
git add -A App docs
git commit -m "feat(commands): deliver bare keys and the search sheet on iPad"
```

---

### Task 8: QA sheet and the full gate

**Files:**
- Create: `docs/superpowers/plans/2026-09-03-command-registry-qa.md`
- Modify: `docs/superpowers/specs/2026-09-03-command-registry-design.md` (revision notes, if the implementation
  diverged)

- [ ] **Step 1: Write the QA sheet**

One numbered item per acceptance condition, each with the exact steps and what to look for. At minimum:

macOS — 1 every menu carries the rows it did before Ⅳb; 2 Display Mode's checkmark follows the mode on screen;
3 Show Library / Import work from the menu; 4 `Z` opens the sheet, `Return` runs, `Esc` closes; 5 mutating rows
grey out during playback, in both the menu bar and the sheet; 6 a bare letter typed into a rehearsal-mark field
reaches the field.

iPadOS 26 — 7 the menu bar carries every menu; 8 the editing menus are greyed while reading and live while
editing; 9 `Z` opens the sheet with a hardware keyboard; 10 the MuseScore letters and digits write notes;
11 typing in the library's search field is not stolen; 12 below iOS 26 (18.6 simulator) nothing regresses and
the app still launches.

Each item records **observed / not observed**, and the sheet ships with everything unobserved.

- [ ] **Step 2: Run the whole gate and record the numbers**

```sh
Scripts/build-macos-packages.sh
Scripts/build-macos-app.sh
xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max,OS=26.5' -skipPackagePluginValidation build
xcodebuild test -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max,OS=26.5' -skipPackagePluginValidation -only-testing:FolinoTests
xcodebuild test -project Folino.xcodeproj -scheme FolinoMac -destination 'platform=macOS' -skipPackagePluginValidation -only-testing:FolinoMacTests
```

State the **counts**, not the conclusion: "FolinoMacTests 38 ran, 38 passed", not "tests pass". A filtered run
that matches nothing also reports success.

- [ ] **Step 3: Commit**

```sh
git add docs
git commit -m "docs(commands): QA sheet for the command registry"
```

---

## Self-Review

**Spec coverage.** §2 (where it lives) → Task 2. §3 model → Tasks 2–3. §3.2 enablement → Tasks 3, 6. §4 menu bar
→ Tasks 3, 6. §5 key delivery → Tasks 2, 7. §6 search → Tasks 4, 5, 7. §7 install sites → Tasks 2, 3, 5, 6, 7.
§8 bench → Task 1. §9 testing → Tasks 2, 3, 4, 6, and the counts in Task 8.

**Type consistency.** `AppCommandCatalog.all` is the unfiltered table (tests) and `.current` is the
platform-filtered one (every projection); `AppCommandContext(editor:host:)` takes optionals throughout;
`AppCommandSearch.results(matching:in:)` takes the array so tests can pass a fixture.

**Known gap, deliberately left:** the search sheet's `only:` filter (Task 7 Step 2) is the only API added outside
a task that defines it — it is defined there, in the same step that uses it.
