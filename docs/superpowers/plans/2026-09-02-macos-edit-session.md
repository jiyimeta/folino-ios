# Mac Editing Ⅳa — the always-editable score window — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A Mac score window is editable from the moment it opens — click selects, the keyboard writes notes, every
existing edit command has a menu item, undo / redo / Revert To are in the menus — with the Editor's session spanning
the window's lifetime and the same score never open in two windows.

**Architecture:** The iOS `ReaderEditingHost` seam is reused unchanged; a Mac sibling of `EditableReaderScreen`
(`App/Mac/MacEditableReaderScreen.swift`) wires it to an `EditorViewModel` through a shared
`App/Shared/ReaderEditingWiring.swift`, and `MacReaderRootScreen` opens the session when the score loads and closes
it when the window closes. The three Mac score surfaces gain the same three editing additions the iOS
`VerticalZoomedSurface` has (selection tint, tap routing, caret overlay). Menu items are generated from one command
table (`App/Mac/MacEditingCommands.swift`) that Ⅳb will generalize; bare-key delivery is decided by a bench (Task 1).

**Tech Stack:** Swift 6.3, SwiftUI on macOS 15, AppKit for the termination hook, Swift Testing, `xcodegen`,
`xcodebuild`. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-09-02-macos-edit-session-design.md`. Read it first; every task below cites
the section it implements.

## Global Constraints

- Deployment floors: iOS 18.0, macOS 15.0 (`project.yml`, every `Package.swift`). `if #available(iOS 26, *)` does
  NOT guard macOS — write `if #available(iOS 26, macOS 26, *)`.
- Feature → Feature imports are forbidden. Reader never sees Editor types; the App composition root connects them.
- No `#if` inside a SwiftUI modifier chain (SwiftFormat `--ifdef no-indent` fights it); gate a whole modifier through
  a compat helper, or gate the file.
- Every `PARITY(macos):` marker's continuation lines are indented **two or more** spaces; markers sit OUTSIDE any
  `#if os(iOS)` block. Implementing a gap deletes its marker. The `parity-ledger` pre-commit hook regenerates
  `docs/engineering/ios-android-parity.md` — never hand-edit it.
- User-facing brand is lowercase `folino`; internal feature names (`Reader`, `Editor`) never appear in user copy.
- New tests use Swift Testing (`import Testing`, `@Test`, `#expect`).
- `swift test` does not work in this repo. Package tests: `xcodebuild test -scheme <Pkg>-Package -destination
  'platform=iOS Simulator,id=513F3B9E-891E-44CB-9DD3-BFCF5EEE3394' -skipPackagePluginValidation` **run from the
  package directory** (`cd` in its own Bash call first — `env -C … xcodebuild -scheme` is refused by the harness).
- Mac gates: `Scripts/build-macos-packages.sh` (9 packages) and `Scripts/build-macos-app.sh`. iOS gate:
  `xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS
  Simulator,id=513F3B9E-891E-44CB-9DD3-BFCF5EEE3394' -skipPackagePluginValidation build`.
- Whole-file staging only (no `git add -p`). The pre-commit hook runs SwiftFormat + SwiftLint and may rewrite files;
  re-stage and commit again when it does.
- Commit messages end with the Co-Authored-By / Claude-Session trailers the session was given.
- Worktree: `/Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/macos-editing-ui` — every path
  below is relative to it, and every `git` command uses `git -C <that absolute path>`. Before each task, `git -C
  <worktree> merge main` and resolve conflicts (the user merges to `main` in parallel).
- Reference line numbers in this plan were taken at commit `1920c283`; re-locate by symbol if they have drifted.

---

## File structure

**Created**

| File | Responsibility |
| --- | --- |
| `docs/superpowers/plans/2026-09-02-macos-edit-session-bench.md` | Task 1's measured answer: how bare keys are delivered (§6.1). |
| `Tests/FolinoMacTests/*.swift` + `project.yml` target `FolinoMacTests` | The Mac app's unit tests (there were none). |
| `Packages/Features/Reader/Sources/Reader/Screens/Shared/ReaderEditingDisplay.swift` | The edited-score derivation and version key, shared by both platforms' screens (§4.1). |
| `Packages/Features/Reader/Sources/Reader/ReaderEditingHost+ReaderWiring.swift` | Revert-reload and part-remap wiring as `ReaderViewModel` methods, platform-neutral (replaces two `#if os(iOS)` files). |
| `Packages/Features/Editor/Sources/Editor/Views/EditorSheets.swift` | `editorSheets(viewModel:)` — the five Editor sheets installed from one public modifier, so a menu command can raise them (§5.1). |
| `App/Shared/ReaderEditingWiring.swift` | `wireEditingSeam(host:viewModel:repository:analytics:)`, lifted out of `EditableReaderScreen` (§2). |
| `App/Mac/MacEditableReaderScreen.swift` | The Mac composition of host + editor + reader; sheets and Revert To confirmations (§2, §5.3). |
| `App/Mac/MacEditorRegistry.swift` | Per-process registry of live editors keyed by score id (§3.1). |
| `App/Mac/MacAppDelegate.swift` | `applicationShouldTerminate` → flush every editor (§2.1). |
| `App/Mac/MacEditingCommands.swift` | The command table: one declaration per command (§5). |
| `App/Mac/MacEditingMenus.swift` | `Commands` generated from the table, plus the focused-value plumbing (§5, §6). |
| `App/Mac/MacEditingKeyMap.swift` | Bare-key delivery — the shape Task 1 selects (§6.1). |
| `docs/superpowers/plans/2026-09-02-macos-edit-session-qa.md` | The human QA sheet (§8). |

**Modified**

| File | Change |
| --- | --- |
| `App/Mac/FolinoMacApp.swift` | `MacWindowScore` loses `tabInstance`; delegate adaptor; `MacEditingMenus`; browser loses `onOpenScoreInNewWindow`. |
| `App/Mac/MacCommands.swift` | Open in New Window removed. |
| `App/Mac/MacShellView.swift` | Builds `MacEditableReaderScreen` instead of `MacReaderRootScreen` directly. |
| `App/iOS/EditableReaderScreen.swift` | `wireOnce` calls the shared `wireEditingSeam`. |
| `App/Resources/Localizable.xcstrings` | `mac.menu.openInNewWindow` removed; `mac.menu.edit.*` keys added. |
| `Packages/Features/Library/…` (12 files) | `onOpenInNewWindow` / `onOpenScoreInNewWindow` and the row-menu item removed. |
| `Packages/Features/Reader/Sources/Reader/Screens/ReaderRootScreen.swift` | `editingScore` / `editingScoreVersion` forward to `ReaderEditingDisplay`; wiring calls go through `viewModel.`. |
| `Packages/Features/Reader/Sources/Reader/Screens/ReaderRootScreen+RevertWiring.swift`, `+PartRemapWiring.swift` | Deleted (moved). |
| `Packages/Features/Reader/Sources/Reader/Screens/Mac/MacScoreEngraving.swift` | `MacScoreLayoutKey.editingScoreVersion`. |
| `Packages/Features/Reader/Sources/Reader/Screens/Mac/MacVerticalScoreContainer.swift`, `MacHorizontalScoreContainer.swift`, `MacHorizontalScoreStrip.swift`, `MacPagedScoreContainer.swift`, `MacPageDeck.swift` | Editing host threaded in; selection, tap routing, caret overlay, document publication. |
| `Packages/Features/Reader/Sources/Reader/Screens/Mac/MacReaderRootScreen.swift` | `editingHost:` parameter; session begins on load, ends on close; provider wiring; `isPlaying` mirror. |
| `Packages/Features/Editor/Sources/Editor/EditorViewModel.swift` | `isAddMeasuresSheetPresented` / `isRehearsalMarkSheetPresented` become `public`; `revertConfirmationMessage(hasMusicalAnnotations:)`. |
| `Packages/Features/Editor/Sources/Editor/Views/EditorSessionEndButtons.swift` | Uses `revertConfirmationMessage`. |
| `docs/superpowers/specs/2026-09-01-macos-library-window-redesign-design.md`, `2026-08-31-macos-app-design.md` | Revision notes (spec §10). |

---

### Task 1: Bench — how a bare letter reaches a command without stealing from a text field (spec §6.1)

**Files:**
- Create: `~/Developer/_test/MacTest/MacTest/KeyBench.swift` (outside the repo — the bench project)
- Modify: `~/Developer/_test/MacTest/MacTest/MacTestApp.swift`
- Create: `docs/superpowers/plans/2026-09-02-macos-edit-session-bench.md`

**Interfaces:**
- Produces: a written decision, **A** or **B**, that Task 12 implements:
  - **A** — menu items carry the bare key equivalent only while the score surface publishes a `focusedValue`.
  - **B** — bare keys are view-level `Button.keyboardShortcut`s inside the score window; menu items for those
    commands carry no key equivalent.

What is already measured (`MacTransportBar.playPauseButton`'s doc comment): an `NSMenuItem` with an unmodified Space
steals the key from a focused text field; a view-level `.keyboardShortcut(.space)` does not. Letters behave the same
way. What is NOT measured is whether removing a menu item's key equivalent *conditionally* (A) tracks focus fast
enough, and whether a zero-size, transparent Button (B) still fires. The bench answers both.

- [ ] **Step 1: Write the bench**

`~/Developer/_test/MacTest/MacTest/KeyBench.swift`:

```swift
import SwiftUI

/// What the "score" publishes while it has focus. A class so the Commands body can call it.
@MainActor
final class BenchTarget {
    let log: (String) -> Void
    init(log: @escaping (String) -> Void) { self.log = log }
}

private struct BenchTargetKey: FocusedValueKey {
    typealias Value = BenchTarget
}

extension FocusedValues {
    var benchTarget: BenchTarget? {
        get { self[BenchTargetKey.self] }
        set { self[BenchTargetKey.self] = newValue }
    }
}

/// Variant A: a menu item whose bare key equivalent exists only while the score publishes a target.
struct BenchCommandsA: Commands {
    @FocusedValue(\.benchTarget) private var target

    var body: some Commands {
        CommandMenu("Bench A") {
            Button("Pitch A") { target?.log("A: menu a fired") }
                .disabled(target == nil)
                .modifier(BareKeyIf(target != nil, key: "a"))
            Button("Undo-ish") { target?.log("A: cmd-z fired") }
                .keyboardShortcut("z", modifiers: .command)
        }
    }
}

struct BareKeyIf: ViewModifier {
    let on: Bool
    let key: KeyEquivalent
    init(_ on: Bool, key: KeyEquivalent) { self.on = on; self.key = key }
    func body(content: Content) -> some View {
        if on { content.keyboardShortcut(key, modifiers: []) } else { content }
    }
}

@MainActor
@Observable
final class BenchLog {
    var lines: [String] = []
    func add(_ s: String) { lines.append("\(lines.count + 1). \(s)") }
}

struct KeyBenchView: View {
    @State private var log = BenchLog()
    @State private var scoreFocused = false
    @FocusState private var scoreHasFocus: Bool
    @State private var sheetShown = false
    @State private var sheetText = ""
    @State private var inlineText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Click the gray box to focus the score. Type a. Open the sheet, type a in the field. ⌘Z in both.")
            // The "score": focusable, publishes the target while focused.
            Rectangle()
                .fill(scoreHasFocus ? Color.blue.opacity(0.25) : Color.gray.opacity(0.25))
                .frame(height: 120)
                .overlay(Text(scoreHasFocus ? "score (focused)" : "score (click me)"))
                .contentShape(Rectangle())
                .focusable()
                .focused($scoreHasFocus)
                .onTapGesture { scoreHasFocus = true }
                .focusedValue(\.benchTarget, scoreHasFocus ? BenchTarget(log: { log.add($0) }) : nil)
                // Variant B: bare keys as view-level shortcuts on invisible buttons.
                .background(
                    Group {
                        Button("") { log.add("B: view a fired") }
                            .keyboardShortcut("a", modifiers: [])
                        Button("") { log.add("B: view up fired") }
                            .keyboardShortcut(.upArrow, modifiers: [])
                        Button("") { log.add("B: view esc fired") }
                            .keyboardShortcut(.escape, modifiers: [])
                    }
                    .opacity(0)
                    .frame(width: 0, height: 0)
                    .accessibilityHidden(true),
                )
            TextField("inline field", text: $inlineText)
            Button("Open sheet with a text field") { sheetShown = true }
            List(log.lines, id: \.self) { Text($0) }
        }
        .padding()
        .frame(minWidth: 520, minHeight: 480)
        .sheet(isPresented: $sheetShown) {
            VStack {
                TextField("sheet field", text: $sheetText)
                Button("Close") { sheetShown = false }.keyboardShortcut(.cancelAction)
            }
            .padding()
            .frame(width: 320)
        }
    }
}
```

`~/Developer/_test/MacTest/MacTest/MacTestApp.swift` — replace the body:

```swift
import SwiftUI

@main
struct MacTestApp: App {
    var body: some Scene {
        WindowGroup {
            KeyBenchView()
        }
        .commands { BenchCommandsA() }
    }
}
```

- [ ] **Step 2: Build and launch the bench**

Run (two Bash calls, the second after the first succeeds):

```bash
xcodebuild -project ~/Developer/_test/MacTest/MacTest.xcodeproj -scheme MacTest -destination 'platform=macOS' -derivedDataPath /private/tmp/claude-501/-Users-kiichi-Developer-Personal-ios-apps-Folino-iOS/4d010087-c052-4bc7-be76-3bc372469b96/scratchpad/MacTestDD build
```

```bash
open /private/tmp/claude-501/-Users-kiichi-Developer-Personal-ios-apps-Folino-iOS/4d010087-c052-4bc7-be76-3bc372469b96/scratchpad/MacTestDD/Build/Products/Debug/MacTest.app
```

Expected: BUILD SUCCEEDED, the window appears. **This repo forbids driving UI with automation; the keystrokes are the
user's.** Ask the user to perform exactly this, and to paste the log list back:

1. Click the gray box. Press `a`. Press `↑`. Press `⌘Z`.
2. Click the inline field. Type `a`. Press `⌘Z`.
3. Click "Open sheet…". Type `a` in the sheet field. Press `⌘Z`. Press Esc.
4. Click the gray box again. Press `a`.

- [ ] **Step 3: Read the result against the pass table**

| Step | A passes if | B passes if |
| --- | --- | --- |
| 1 | log has `A: menu a fired` and `A: cmd-z fired` | log has `B: view a fired`, `B: view up fired` |
| 2 | the inline field shows `a`; **no** `A: menu a fired` line was added | the inline field shows `a`; **no** `B: view a fired` line |
| 3 | the sheet field shows `a`; no `A:` line; Esc closed the sheet | the sheet field shows `a`; no `B:` line |
| 4 | `A: menu a fired` again (the value came back after the sheet) | `B: view a fired` again |

If both pass, choose **A** (shortcuts appear in the menus natively). If only B passes, choose **B**. If a bare key
beeps in step 2 or 3, that variant fails (the disabled item consumed the key).

- [ ] **Step 4: Record the decision**

`docs/superpowers/plans/2026-09-02-macos-edit-session-bench.md`:

```markdown
# Bench: bare-key delivery on macOS (2026-09-02)

Bench: `~/Developer/_test/MacTest/MacTest/KeyBench.swift`. Procedure and pass table: Task 1 of
`2026-09-02-macos-edit-session.md`.

## Result

| Step | A | B |
| --- | --- | --- |
| 1 | <pass/fail + the log lines> | <…> |
| 2 | <…> | <…> |
| 3 | <…> | <…> |
| 4 | <…> | <…> |

## Decision

**<A or B>.** <one sentence on why, quoting the failing step if any>

## What Task 12 must do with it

<A: menu items carry `.keyboardShortcut` conditioned on `@FocusedValue(\.macEditingTarget) != nil`.>
<B: `MacEditingKeyMap` installs one invisible Button per bare key inside `MacEditableReaderScreen`; menu items for
bare-key commands carry no key equivalent.>
```

Fill every `<…>` with what the user reported. No placeholders may remain.

- [ ] **Step 5: Commit**

```bash
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/macos-editing-ui add docs/superpowers/plans/2026-09-02-macos-edit-session-bench.md
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/macos-editing-ui commit -m "docs(macos): bench result for bare-key delivery in the Mac editor"
```

---

### Task 2: One window per score, and the Mac test target (spec §3)

**Files:**
- Modify: `App/Mac/FolinoMacApp.swift:16-19` (`MacWindowScore`), `:213-223` (browser closures)
- Modify: `App/Mac/MacCommands.swift:58-77` (Open in New Window item), `:13-19` (`currentScoreID` doc)
- Modify: `App/Mac/MacShellView.swift:34-37` (doc comment mentioning `tabInstance`)
- Modify: `App/Resources/Localizable.xcstrings` (remove `mac.menu.openInNewWindow`)
- Modify (Library): `Views/RowOpenAffordance.swift`, `Views/ScoreListView.swift`, `Views/PlaylistDetailView.swift`,
  `Views/RecentlyDeletedView.swift`, `Screens/ScoreListScreen.swift`, `Screens/FavoritesScreen.swift`,
  `Screens/AllScoresScreen.swift`, `Screens/TagDetailScreen.swift`, `Screens/RecentlyDeletedScreen.swift`,
  `Screens/PlaylistDetailScreen.swift`, `Screens/LibraryRootDestinations.swift`, `Screens/Mac/MacLibraryBrowser.swift`
  (all under `Packages/Features/Library/Sources/Library/`)
- Modify: `project.yml` (new `FolinoMacTests` target; `FolinoMac` scheme test action)
- Create: `Tests/FolinoMacTests/MacWindowScoreTests.swift`
- Modify: `docs/superpowers/specs/2026-09-01-macos-library-window-redesign-design.md` §2.3 / §2.4

**Interfaces:**
- Produces: `MacWindowScore(scoreID:)` with value equality on `scoreID` alone; a `FolinoMacTests` target every later
  App task adds tests to; `MacLibraryBrowser.init` without `onOpenScoreInNewWindow`;
  `macScoreOpenAffordance(_:in:onOpen:)` (three parameters).

- [ ] **Step 1: Add the Mac test target and write the failing test**

`project.yml` — after the `FolinoTests` target block (ends at the `TEST_HOST` line, ~line 245), add:

```yaml
  FolinoMacTests:
    type: bundle.unit-test
    platform: macOS
    deploymentTarget: "15.0"
    sources:
      - path: Tests/FolinoMacTests
    dependencies:
      - target: FolinoMac
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.KeyNumber.Folino.macTests
        GENERATE_INFOPLIST_FILE: YES
        BUNDLE_LOADER: $(TEST_HOST)
        TEST_HOST: $(BUILT_PRODUCTS_DIR)/folino.app/Contents/MacOS/folino
```

and in the `FolinoMac` scheme (the block starting `  FolinoMac:` under `schemes:`, ~line 378) make it:

```yaml
  FolinoMac:
    build:
      targets:
        FolinoMac: all
        FolinoMacTests: [test]
    run:
      config: Debug
    test:
      config: Debug
      targets:
        - FolinoMacTests
    profile:
      config: Release
    analyze:
      config: Debug
    archive:
      config: Release
```

`Tests/FolinoMacTests/MacWindowScoreTests.swift`:

```swift
import Domain
@testable import folino
import Testing

/// Spec §3: the same score can never open in two windows. `WindowGroup(for:)` dedupes on value equality, so the
/// window value must be the score id and nothing else.
struct MacWindowScoreTests {
    @Test func `two window values for one score are equal`() {
        let id = ScoreItemID()
        #expect(MacWindowScore(scoreID: id) == MacWindowScore(scoreID: id))
    }

    @Test func `window values for different scores differ`() {
        #expect(MacWindowScore(scoreID: ScoreItemID()) != MacWindowScore(scoreID: ScoreItemID()))
    }
}
```

- [ ] **Step 2: Regenerate the project and run the test to see it fail**

```bash
xcodegen generate
```

```bash
xcodebuild test -project Folino.xcodeproj -scheme FolinoMac -destination 'platform=macOS' -skipPackagePluginValidation -only-testing:FolinoMacTests
```

Expected: `two window values for one score are equal` FAILS (two `UUID()`s in `tabInstance` differ). If the target
itself fails to link, fix the `TEST_HOST` path before continuing — it must point at the built `folino.app`.

- [ ] **Step 3: Drop `tabInstance`**

`App/Mac/FolinoMacApp.swift` — replace lines 9–19 (the doc comment and struct) with:

```swift
/// The value that identifies one of `FolinoMacApp`'s score windows, and what `WindowGroup(for:)` dedupes on.
///
/// **The score id, and nothing else — deliberately.** `WindowGroup(for:)` refocuses an existing window whose
/// presented value equals the one passed to `openWindow(value:)`, so opening a score that is already open brings its
/// window (or tab) forward instead of minting a second one. That is MuseScore 4's rule (`ProjectActionsController::
/// openProject` step 3, `activateWindowWithProject`) and the design's (`2026-09-02-macos-edit-session-design.md` §3):
/// with the score always editable, a second window on the same score would be a second editor of one file.
struct MacWindowScore: Hashable, Codable {
    var scoreID: ScoreItem.ID
}
```

- [ ] **Step 4: Remove Open in New Window from the File menu**

`App/Mac/MacCommands.swift` — delete the third `Button` in `CommandGroup(after: .newItem)` (lines 58–77, the one
whose label is `Text("mac.menu.openInNewWindow")`) and delete the `@FocusedValue(\.macCurrentScoreID)` property
(line 18) plus its `CurrentScoreIDKey` / `macCurrentScoreID` entries in the `FocusedValues` extension (lines 118–121
and 128–131). Replace the struct's doc comment (lines 8–19) with:

```swift
/// The menu-bar skeleton the shell itself needs — Show Library, Import, and the display-mode picker. The editing
/// menus live in `MacEditingMenus`.
///
/// `macLibraryImportAction` is published via `focusedSceneValue` by `MacShellView` and by the library browser's window
/// content both, since `@FocusedValue` follows *scene* focus and one window's publication is invisible from another.
```

`App/Mac/MacShellView.swift` — remove `.focusedCurrentScoreID(scoreID)` from `body` (line 88) and delete the
`focusedCurrentScoreID` extension at the bottom of the file (the `extension View { … }` block, lines 176–187). Fix
the `window` property's doc comment (lines 34–37) to end after "…nothing here ever writes it back."

`App/Resources/Localizable.xcstrings` — delete the `"mac.menu.openInNewWindow"` entry (the object from line 794 to its
closing `},` — five localizations). Keep the JSON valid: the previous entry's trailing comma is now the last, so check
the file with `python3 -c "import json;json.load(open('App/Resources/Localizable.xcstrings'))"`.

- [ ] **Step 5: Remove the Library's Open in New Window plumbing**

In each file, delete the property / parameter / argument / doc lines listed; nothing else in these files changes.

- `Views/RowOpenAffordance.swift`: in `macScoreOpenAffordance`, delete the `onOpenInNewWindow: @escaping (ScoreItem) -> Void,` parameter (line 90). Delete the doc paragraph that begins `**\`onOpenInNewWindow\` is not called from this helper…` (lines 66–77) and, in the paragraph above it, change "`onOpen` / `onOpenInNewWindow` directly" to "`onOpen` directly".
- `Views/ScoreListView.swift`: delete `let onOpenInNewWindow: (ScoreItem) -> Void` (line 37); drop `, onOpenInNewWindow: onOpenInNewWindow` from the `.macScoreOpenAffordance(…)` call (line 74); delete the `Button { onOpenInNewWindow(item) } label: { … }` block in the row menu (lines 132–136); drop the `onOpenInNewWindow: { _ in },` arguments in the two previews (lines 255, 302).
- `Views/PlaylistDetailView.swift`: same four edits at lines 9–10 (doc + property), 75, 187–191, 238.
- `Views/RecentlyDeletedView.swift`: same at lines 16–17, 43, 167–171.
- `Screens/ScoreListScreen.swift`: delete lines 10–13 (doc + `let onOpenInNewWindow`), the init parameter and assignment, and the argument at line 69.
- `Screens/FavoritesScreen.swift`: lines 7–8, 17, 23, 38.
- `Screens/AllScoresScreen.swift`: lines 7–8, 17, 23, 38.
- `Screens/TagDetailScreen.swift`: lines 9–10, 21, 29, 50.
- `Screens/RecentlyDeletedScreen.swift`: lines 10–11, 22, 26, 88.
- `Screens/PlaylistDetailScreen.swift`: the `onOpenInNewWindow: openScore,` argument (line 45) and the doc sentence at line 116 that mentions it.
- `Screens/LibraryRootDestinations.swift`: the `onOpenInNewWindow: onOpenScore` arguments at lines 24, 32, 49, 70.
- `Screens/Mac/MacLibraryBrowser.swift`: delete `let onOpenScoreInNewWindow: (ScoreItem) -> Void` (line 20), the init parameter (line 46) and assignment (line 51), the `onOpenInNewWindow: onOpenScoreInNewWindow` arguments (lines 209, 218, 226, 248, 258), the preview arguments (lines 293, 309), and reword the doc at line 195 to drop "(passing them the `onOpenInNewWindow` closure this window needs)".

`App/Mac/FolinoMacApp.swift` — in `MacLibraryWindowContent`, delete the `onOpenScoreInNewWindow:` argument and the
six-line comment above `onOpenScore:` (lines 215–220), leaving:

```swift
        MacLibraryBrowser(
            viewModel: viewModel,
            onOpenScore: { item in openWindow(value: MacWindowScore(scoreID: item.id)) },
```

- [ ] **Step 6: Build both platforms and run the gates**

```bash
Scripts/build-macos-packages.sh
```

```bash
xcodebuild test -project Folino.xcodeproj -scheme FolinoMac -destination 'platform=macOS' -skipPackagePluginValidation -only-testing:FolinoMacTests
```

```bash
xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,id=513F3B9E-891E-44CB-9DD3-BFCF5EEE3394' -skipPackagePluginValidation build
```

Then the Library suite (first `cd Packages/Features/Library` in its own call):

```bash
xcodebuild test -scheme Library-Package -destination 'platform=iOS Simulator,id=513F3B9E-891E-44CB-9DD3-BFCF5EEE3394' -skipPackagePluginValidation
```

Expected: all green; `MacWindowScoreTests` 2 passed; the Library suite reports its existing count (129 at `1920c283`)
with no failures.

- [ ] **Step 7: Revise the library-window spec**

`docs/superpowers/specs/2026-09-01-macos-library-window-redesign-design.md` — insert directly under the `### 2.3`
heading:

```markdown
> **Revised 2026-09-02** by `2026-09-02-macos-edit-session-design.md` §3. Open in New Window and ⌥-double-click are
> withdrawn: with the score always editable, a second window on the same score would be a second editor of one
> file. `MacWindowScore` is the score id alone, and opening an already-open score brings its window forward
> (MuseScore 4's rule). The default open path — a tab of the frontmost score window — is unchanged.
```

and under `### 2.4`:

```markdown
> **Revised 2026-09-02:** "several scores at once" still holds; "the same score several times" does not — see
> §2.3's note. A split view of one score inside one window is the replacement, scheduled after Ⅳc.
```

- [ ] **Step 8: Commit**

```bash
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/macos-editing-ui add project.yml Tests/FolinoMacTests App/Mac App/Resources/Localizable.xcstrings Packages/Features/Library/Sources docs/superpowers/specs/2026-09-01-macos-library-window-redesign-design.md
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/macos-editing-ui commit -m "feat(macos): one window per score; drop Open in New Window; add FolinoMacTests"
```

---

### Task 3: `ReaderEditingDisplay` — the edited-score derivation shared by both screens (spec §4.1)

**Files:**
- Create: `Packages/Features/Reader/Sources/Reader/Screens/Shared/ReaderEditingDisplay.swift`
- Modify: `Packages/Features/Reader/Sources/Reader/Screens/ReaderRootScreen.swift:747-770`
- Create: `Packages/Features/Reader/Tests/ReaderTests/ReaderEditingDisplayTests.swift`

**Interfaces:**
- Produces:
  ```swift
  enum ReaderEditingDisplay {
      static func score(host: ReaderEditingHost?, clefOverrides: [StaffAddress: String], hiddenStaves: Set<StaffAddress>) -> Score?
      static func version(host: ReaderEditingHost?) -> Int
  }
  ```

- [ ] **Step 1: Write the failing tests**

`Packages/Features/Reader/Tests/ReaderTests/ReaderEditingDisplayTests.swift`:

```swift
import Domain
@testable import Reader
import SheetMusicCore
import Testing

@MainActor
struct ReaderEditingDisplayTests {
    private func score() -> Score {
        let staff = Staff(measures: [Measure(voices: [Voice(elements: [.rest(Rest(duration: .whole))])])])
        return Score(division: 480, parts: [Part(name: "P", staves: [staff])])
    }

    @Test func `nil host or a host that is not editing yields nil and version 0`() {
        #expect(ReaderEditingDisplay.score(host: nil, clefOverrides: [:], hiddenStaves: []) == nil)
        #expect(ReaderEditingDisplay.version(host: nil) == 0)
        let host = ReaderEditingHost()
        host.editedScore = score()
        host.editGeneration = 7
        #expect(ReaderEditingDisplay.score(host: host, clefOverrides: [:], hiddenStaves: []) == nil)
        #expect(ReaderEditingDisplay.version(host: host) == 0)
    }

    @Test func `an editing host yields the display-transformed edited score and its generation`() {
        let host = ReaderEditingHost()
        host.isEditing = true
        host.editedScore = score()
        host.editGeneration = 3
        let expected = ReaderDisplayTransforms.display(
            score(), clefOverrides: [:], transposeSemitones: 0, hiddenStaves: [],
        )
        #expect(ReaderEditingDisplay.score(host: host, clefOverrides: [:], hiddenStaves: []) == expected)
        #expect(ReaderEditingDisplay.version(host: host) == 3)
    }
}
```

If `Staff` / `Measure` / `Voice` / `Rest` initializers differ from the above, copy the construction used by
`Packages/Features/Reader/Tests/ReaderTests/ReaderAdvanceTests.swift` — any one-measure score will do.

- [ ] **Step 2: Run to see it fail**

`cd Packages/Features/Reader` (own call), then:

```bash
xcodebuild test -scheme Reader-Package -destination 'platform=iOS Simulator,id=513F3B9E-891E-44CB-9DD3-BFCF5EEE3394' -skipPackagePluginValidation -only-testing:ReaderTests/ReaderEditingDisplayTests
```

Expected: compile error, `ReaderEditingDisplay` not found.

- [ ] **Step 3: Implement**

`Packages/Features/Reader/Sources/Reader/Screens/Shared/ReaderEditingDisplay.swift`:

```swift
import SheetMusicCore

/// The score a screen ENGRAVES while note editing, and the key that says which edit it is — shared by
/// `ReaderRootScreen` (iOS) and `MacScoreContentView` (macOS) so the two can never disagree about it.
///
/// Three display transforms survive into an edit session — clef overrides, the written-pitch view, and the hidden-
/// staves filter — because each is one a `StaffAddress` remap can undo (`ReaderEditingHost` re-stamps IDs across the
/// filter). The two that renumber ELEMENTS within a staff — the global transpose and multi-measure-rest collapse — do
/// not: they would invalidate every positional ID the editor holds. So the transpose is pinned to 0 here, and the
/// caller passes `collapseMultiMeasureRests: false` to the containers while `score(…)` is non-nil.
@MainActor
enum ReaderEditingDisplay {
    /// The edited score with the survivable transforms applied, or `nil` when there is no editing session.
    static func score(
        host: ReaderEditingHost?,
        clefOverrides: [StaffAddress: String],
        hiddenStaves: Set<StaffAddress>,
    ) -> Score? {
        guard let host, host.isEditing, let edited = host.editedScore else { return nil }
        return ReaderDisplayTransforms.display(
            edited,
            clefOverrides: clefOverrides,
            transposeSemitones: 0,
            hiddenStaves: hiddenStaves,
        )
    }

    /// Which edit `score(…)` is — the containers' relayout key. Read HERE, beside the score, so the two always travel
    /// together: a container that read `editGeneration` itself advanced its key before the new score arrived and
    /// quietly re-engraved the previous edit (see the doc on `ReaderRootScreen.editingScoreVersion`'s history).
    static func version(host: ReaderEditingHost?) -> Int {
        guard let host, host.isEditing else { return 0 }
        return host.editGeneration
    }
}
```

`ReaderRootScreen.swift` — replace the bodies of the two private properties (keep every doc comment as it is):

```swift
    private var editingScore: Score? {
        ReaderEditingDisplay.score(
            host: editingHost,
            clefOverrides: viewModel.layoutModel.staffClefOverrides,
            hiddenStaves: viewModel.layoutModel.hiddenStaves,
        )
    }

    private var editingScoreVersion: Int {
        ReaderEditingDisplay.version(host: editingHost)
    }
```

- [ ] **Step 4: Run the Reader suite**

Same `cd`, then:

```bash
xcodebuild test -scheme Reader-Package -destination 'platform=iOS Simulator,id=513F3B9E-891E-44CB-9DD3-BFCF5EEE3394' -skipPackagePluginValidation
```

Expected: the two new tests pass; total = previous count + 2, zero failures. Then `Scripts/build-macos-packages.sh`
must still be green (the new file has no `#if` and compiles on both).

- [ ] **Step 5: Commit**

```bash
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/macos-editing-ui add Packages/Features/Reader/Sources/Reader/Screens/Shared/ReaderEditingDisplay.swift Packages/Features/Reader/Sources/Reader/Screens/ReaderRootScreen.swift Packages/Features/Reader/Tests/ReaderTests/ReaderEditingDisplayTests.swift
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/macos-editing-ui commit -m "refactor(reader): share the edited-score derivation between the iOS and Mac screens"
```

---

### Task 4: Lift the revert-reload and part-remap wiring off the iOS screen (spec §2)

The two `#if os(iOS)` extension files carry `PARITY(macos)` markers that say exactly this: "the Mac screen should
LIFT it into its own `.task`, not re-author it". They become `ReaderViewModel` methods with no platform gate.

**Files:**
- Create: `Packages/Features/Reader/Sources/Reader/ReaderEditingHost+ReaderWiring.swift`
- Delete: `Packages/Features/Reader/Sources/Reader/Screens/ReaderRootScreen+RevertWiring.swift`,
  `Packages/Features/Reader/Sources/Reader/Screens/ReaderRootScreen+PartRemapWiring.swift`
- Modify: `Packages/Features/Reader/Sources/Reader/Screens/ReaderRootScreen.swift:416-419`

**Interfaces:**
- Produces:
  ```swift
  extension ReaderViewModel {
      func wireRevertReload(host: ReaderEditingHost)
      func wirePartRemapReload(host: ReaderEditingHost)
  }
  ```

- [ ] **Step 1: Create the shared file**

`Packages/Features/Reader/Sources/Reader/ReaderEditingHost+ReaderWiring.swift` — the bodies are the two deleted
files' bodies verbatim, with `viewModel` replaced by `self` and the captures adjusted. Copy the doc comments too
(they explain the ordering constraints; do not shorten them):

```swift
import Domain

// The two halves of the editing seam that the READER owns and every platform's screen installs from its `.task`:
// the revert reload and the part-remap hold / drain / release. Both were `ReaderRootScreen` extensions gated to iOS;
// they are `ReaderViewModel` methods now because the orchestration was always platform-neutral and the Mac screen
// installs the same two.

extension ReaderViewModel {
    /// Wires the revert half of the editing seam onto `host`.
    ///
    /// (Copy the full doc comment from the deleted `ReaderRootScreen+RevertWiring.swift` here.)
    func wireRevertReload(host: ReaderEditingHost) {
        host.hasMusicalAnnotationsProvider = { [weak self] in
            self?.annotationDrawings.contains { drawing in
                if case .musical = drawing.kind { true } else { false }
            } ?? false
        }
        host.requestReloadAfterRevert = { [weak self, weak host] item in
            guard let self else { return }
            Task {
                await self.playbackSession.releaseEngine()
                self.scoreItem = item
                host?.editedScore = nil
                host?.requestExit()
                if item.originalPDFFileName != nil {
                    self.pdfPlayback = .idle
                }
                await self.load()
            }
        }
    }

    /// Wires the part-remap half of the editing seam onto `host`.
    ///
    /// (Copy the full doc comment from the deleted `ReaderRootScreen+PartRemapWiring.swift` here, including the
    /// inline comments on each closure.)
    func wirePartRemapReload(host: ReaderEditingHost) {
        setPartMigrationPendingProvider { [weak host] in
            host?.isPartMappingPending ?? false
        }
        host.prepareForPartMigration = { [weak self] in
            await self?.flushPendingAnnotationSave()
        }
        host.requestReloadAfterPartRemap = { [weak self, weak host] in
            guard let self, let score = host?.editedScore else {
                if host?.releasePartMappingHoldIfSettled() == true {
                    self?.discardDeferredPreferenceWrites()
                }
                return
            }
            Task {
                await self.reloadPreferencesAfterPartRemap(
                    authoredHiddenStaves: score.authoredHiddenStaffAddresses,
                    liftHold: { [weak host] in host?.releasePartMappingHoldIfSettled() ?? false },
                )
            }
        }
        host.releasePartMappingHoldIfSettled()
    }
}
```

Delete the two old files (`git rm`). Their `PARITY(macos)` markers go with them — the Mac screen installs both in
Task 9, which is what closes the gap.

- [ ] **Step 2: Update the iOS call site**

`ReaderRootScreen.swift` lines 416–419 become:

```swift
            if let editingHost {
                viewModel.wireRevertReload(host: editingHost)
                viewModel.wirePartRemapReload(host: editingHost)
            }
```

- [ ] **Step 3: Build and test**

`Scripts/build-macos-packages.sh`, then the Reader suite (from `Packages/Features/Reader`):

```bash
xcodebuild test -scheme Reader-Package -destination 'platform=iOS Simulator,id=513F3B9E-891E-44CB-9DD3-BFCF5EEE3394' -skipPackagePluginValidation
```

Expected: green on both, same test count as after Task 3. The parity-ledger hook will regenerate the ledger at
commit time; stage `docs/engineering/ios-android-parity.md` when it does.

- [ ] **Step 4: Commit**

```bash
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/macos-editing-ui add Packages/Features/Reader/Sources/Reader docs/engineering/ios-android-parity.md
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/macos-editing-ui commit -m "refactor(reader): revert and part-remap wiring become platform-neutral view-model methods"
```

---

### Task 5: The layout key and the vertical surface take the editing host (spec §4.1)

**Files:**
- Modify: `Packages/Features/Reader/Sources/Reader/Screens/Mac/MacScoreEngraving.swift:76-113` (`MacScoreLayoutKey`)
- Modify: `Packages/Features/Reader/Sources/Reader/Screens/Mac/MacVerticalScoreContainer.swift`

**Interfaces:**
- Consumes: `ReaderEditingHost.wantsScoreTaps`, `.onTap`, `.displaySelection`, `.document` (all exist).
- Produces: `MacScoreLayoutKey(…, editingScoreVersion:)`; `MacVerticalScoreContainer(…, editingScoreVersion:
  Int, editingHost: ReaderEditingHost?)`.

- [ ] **Step 1: Extend the key**

`MacScoreEngraving.swift` — in `MacScoreLayoutKey`, add a stored property and an init parameter with a default, and
update the type's doc comment ("Mirrors the iOS containers' `TaskKey` minus the editing generation — the Mac reader
has no edit session yet" → "Mirrors the iOS containers' `TaskKey`, editing generation included"):

```swift
    let transposeSemitones: Int
    /// Which edit the score is while note editing, 0 otherwise. Comes from `ReaderEditingDisplay.version`, beside the
    /// score, never from the host directly — see that function's doc.
    let editingScoreVersion: Int

    init(
        score: Score,
        size: CGFloat,
        width: CGFloat? = nil,
        honorLayoutBreaks: Bool,
        collapseMultiMeasureRests: Bool,
        showInvisibleElements: Bool,
        showAllMeasureNumbers: Bool,
        transposeSemitones: Int,
        editingScoreVersion: Int = 0,
    ) {
        …existing assignments…
        self.editingScoreVersion = editingScoreVersion
    }
```

- [ ] **Step 2: Thread the host through the vertical container**

`MacVerticalScoreContainer.swift`:

1. Replace the file's `PARITY(macos)` header with:
   ```swift
   // PARITY(macos): vertical mode's live annotation canvas — the Mac container renders, scrolls, magnifies and edits
   //   the score; what it still lacks against the iOS `VerticalScoreContainer` is the live PencilKit canvas, and
   //   PencilKit ships no `PKCanvasView` on macOS at all (Ⅴ).
   ```
2. After `let transposeSemitones: Int` add:
   ```swift
    /// Which edit `score` is while note editing, 0 otherwise. Keyed on INSTEAD of `editingHost.editGeneration` — see
    /// `ReaderEditingDisplay.version`.
    let editingScoreVersion: Int
   ```
   and after `let viewModel: ReaderViewModel` add:
   ```swift
    /// The note-editing seam. `nil` keeps this container byte-identical to the read-only reader (previews, tests).
    /// With a host, clicks route to `editingHost.onTap`, the rebuilt `LayoutDocument` is published to
    /// `editingHost.document` for hit-testing, and the surface tints the selection and draws the caret.
    var editingHost: ReaderEditingHost?
   ```
3. In `layoutKey(width:)` pass `editingScoreVersion: editingScoreVersion,` as the last argument.
4. In `rebuildLayout(width:)`, after `layoutState.document = newDoc` add `editingHost?.document = newDoc`.
5. In `scoreScroll(viewport:)`, pass `editingHost: editingHost,` to `MacVerticalScoreSurface` (after `viewModel:`).
6. In `MacVerticalScoreSurface` add `let editingHost: ReaderEditingHost?` after `let viewModel`, and in `body`
   append `.background(editingDeselectCatcher(host: editingHost))` directly after the `.frame(width:height:alignment:)`
   modifier (before the existing `.background(MacScrollViewAppearance…)`).
7. Replace `scoreSurface(document:)`'s `ScoreView(…)` and the gesture, and add the overlay as the last `ZStack`
   child:
   ```swift
            ScoreView(
                document: doc, score: score, options: scoreOptions,
                // `displaySelection`, not `selection`: the editor addresses the unfiltered score, this document is
                // laid out from the staff-filtered one. See `ReaderEditingHost.displayItem(for:)`.
                selection: editingHost?.isEditing == true ? (editingHost?.displaySelection ?? .none) : .none,
                voiceColors: ReaderEditingPresentation.voiceColors,
                playbackCursor: playbackCursor, playbackCursorColor: .accentColor.opacity(0.6),
            )
            .gesture(tapSeekGesture(document: doc))
            …ink overlay and loop overlays unchanged…
            // Last in the stack — over `ScoreView`, which paints itself opaque white. The caret blends
            // (`EditingSelectionOverlay`), it does not sit on top by z-order.
            if let host = editingHost, host.isEditing {
                EditingSelectionOverlay(host: host, score: score, document: doc)
            }
   ```
   and the gesture:
   ```swift
    /// Click: a selection while editing, a seek otherwise — the same rule as the iOS `VerticalZoomedSurface`.
    /// `wantsScoreTaps` hands the click back to the transport while it is running, so a click during playback seeks.
    private func tapSeekGesture(document: LayoutDocument) -> some Gesture {
        SpatialTapGesture(coordinateSpace: .named(Self.coordinateSpace))
            .onEnded { value in
                if let host = editingHost, host.wantsScoreTaps {
                    host.onTap(value.location)
                    return
                }
                guard let cursor = nearestCursor(at: value.location, in: document) else { return }
                viewModel.playbackSession.setManualCursor(cursor)
                editingHost?.rememberTappedItem(cursor)
            }
    }
   ```

`MacScoreContentView` does not compile yet (it does not pass the new arguments) — that is Task 8. To keep this task
independently green, give both new container properties defaults for now: `let editingScoreVersion: Int` → `var
editingScoreVersion = 0`, and `var editingHost: ReaderEditingHost? = nil`. Task 8 passes real values.

- [ ] **Step 3: Build**

```bash
Scripts/build-macos-packages.sh
```

Expected: green. `ReaderEditingPresentation`, `EditingSelectionOverlay`, `editingDeselectCatcher` and
`rememberTappedItem` all compile on macOS already (no `#if` in their files).

- [ ] **Step 4: Commit**

```bash
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/macos-editing-ui add Packages/Features/Reader/Sources/Reader/Screens/Mac/MacScoreEngraving.swift Packages/Features/Reader/Sources/Reader/Screens/Mac/MacVerticalScoreContainer.swift docs/engineering/ios-android-parity.md
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/macos-editing-ui commit -m "feat(reader/macos): vertical mode selects, routes clicks to the editor and draws the caret"
```

---

### Task 6: The horizontal strip takes the editing host (spec §4.1)

**Files:**
- Modify: `Packages/Features/Reader/Sources/Reader/Screens/Mac/MacHorizontalScoreContainer.swift`
- Modify: `Packages/Features/Reader/Sources/Reader/Screens/Mac/MacHorizontalScoreStrip.swift`
- Modify: `Packages/Features/Reader/Sources/Reader/Screens/Mac/MacHorizontalScoreState.swift` (header marker only)

**Interfaces:**
- Produces: `MacHorizontalScoreContainer(…, editingScoreVersion: Int = 0, editingHost: ReaderEditingHost? = nil)`.

The strip is the root of a hand-built `NSHostingView` that is only rebuilt when `layoutGeneration` bumps, so the
host must be read INSIDE the strip's body — `ReaderEditingHost` is `@Observable`, and a body read is what registers
the dependency that redraws the strip when the selection moves. Passing `displaySelection` down as a value would
freeze it at the last engraving.

- [ ] **Step 1: Container**

`MacHorizontalScoreContainer.swift`:

1. Header marker → 
   ```swift
   // PARITY(macos): horizontal mode's live annotation canvas — the Mac strip renders, scrolls, edits the score and
   //   carries the sticky pane; the live PencilKit canvas the iOS `HorizontalScoreContainer` hands its host has no
   //   Mac form because PencilKit ships no `PKCanvasView` on macOS (Ⅴ).
   ```
2. Add after `let transposeSemitones: Int`: `var editingScoreVersion = 0` (doc: as in Task 5) and after
   `let viewModel`: `var editingHost: ReaderEditingHost?` (doc: as in Task 5).
3. `layoutKey` passes `editingScoreVersion: editingScoreVersion`.
4. `rebuildLayout()` — after `state.document = newDocument` add `editingHost?.document = newDocument`.
5. Pass `editingHost: editingHost,` into `MacHorizontalScoreStrip(…)`.

- [ ] **Step 2: Strip**

`MacHorizontalScoreStrip.swift`:

1. Header marker →
   ```swift
   // PARITY(macos): horizontal mode's live annotation canvas — the strip draws the staves, the committed ink, the
   //   selection and the caret; the live canvas the iOS `HorizontalZoomedSurface` mounts here is Ⅴ's.
   ```
2. Add `let editingHost: ReaderEditingHost?` after `let viewportState`.
3. `ScoreView(…)` gains `selection:` / `voiceColors:` exactly as in Task 5 step 2.7; the overlay
   `if let host = editingHost, host.isEditing { EditingSelectionOverlay(host: host, score: score, document: document) }`
   becomes the last `ZStack` child; after `.padding(MacHorizontalMetrics.contentInset)` insert
   `.background(editingDeselectCatcher(host: editingHost))`.
4. `tapSeekGesture(document:)`:
   ```swift
            .onEnded { value in
                guard !isUnderStickyPane(documentX: value.location.x, document: document) else { return }
                if let host = editingHost, host.wantsScoreTaps {
                    host.onTap(value.location)
                    return
                }
                guard let cursor = nearestCursor(at: value.location, in: document) else { return }
                viewModel.playbackSession.setManualCursor(cursor)
                editingHost?.rememberTappedItem(cursor)
            }
   ```
   Keep the doc comment's sticky-pane paragraph; add one sentence: "While editing, a click that clears the pane is
   a selection, not a seek."

`MacHorizontalScoreState.swift` header marker → drop "and note-editing seam" so it reads "The annotation canvas
that horizontal mode still lacks would add state here".

- [ ] **Step 3: Build and commit**

```bash
Scripts/build-macos-packages.sh
```

```bash
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/macos-editing-ui add Packages/Features/Reader/Sources/Reader/Screens/Mac docs/engineering/ios-android-parity.md
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/macos-editing-ui commit -m "feat(reader/macos): horizontal mode selects, routes clicks to the editor and draws the caret"
```

---

### Task 7: The page deck takes the editing host (spec §4.1)

**Files:**
- Modify: `Packages/Features/Reader/Sources/Reader/Screens/Mac/MacPagedScoreContainer.swift`
- Modify: `Packages/Features/Reader/Sources/Reader/Screens/Mac/MacPageDeck.swift`

**Interfaces:**
- Produces: `MacPagedScoreContainer(…, editingScoreVersion: Int = 0, editingHost: ReaderEditingHost? = nil)`.

- [ ] **Step 1: Container**

`MacPagedScoreContainer.swift`:

1. Header marker → replace "no live annotation canvas, and no note-editing seam" with "and no live annotation canvas
   (Ⅴ)"; the page-turn sentence stays.
2. Add `var editingScoreVersion = 0` and `var editingHost: ReaderEditingHost?` (docs as in Task 5).
3. `layoutKey` passes `editingScoreVersion: editingScoreVersion`.
4. `rebuildLayout()` — after `layoutState.pages = newPages` add `editingHost?.document = newDoc`.
5. Pass `editingHost: editingHost,` into `MacPageDeck(…)`.

- [ ] **Step 2: Deck, page and layer**

`MacPageDeck.swift`:

1. `MacPageDeck` gains `let editingHost: ReaderEditingHost?` and passes it to `MacScorePage(…)`.
2. `MacScorePage` gains `let editingHost: ReaderEditingHost?`, passes it to `MacPageScoreLayer(…)`, and adds
   `.background(editingDeselectCatcher(host: editingHost))` to `card` right after `.background(MacReaderGround.paper)`
   — the paper margin around the engraving is the "outside the score" click.
3. `MacPageScoreLayer` gains `let editingHost: ReaderEditingHost?`; its `ScoreView(…)` gains `selection:` /
   `voiceColors:` as in Task 5; `EditingSelectionOverlay(host: host, score: score, document: pageDocument)` is the
   last `ZStack` child when `host.isEditing`; the gesture:
   ```swift
            .onEnded { value in
                let pageEndY = pageStartY + contentSize.height
                guard value.location.y >= pageStartY, value.location.y <= pageEndY else { return }
                if let host = editingHost, host.wantsScoreTaps {
                    host.onTap(value.location)
                    return
                }
                guard let cursor = nearestCursor(at: value.location, in: pageDocument) else { return }
                viewModel.playbackSession.setManualCursor(cursor)
                editingHost?.rememberTappedItem(cursor)
            }
   ```
   `pageDocument` keeps the full document's `size` and the systems' document-space origins (see
   `MacPageDeck.pageDocument(forPage:in:)`), so `onTap`'s point is already in the space `editingHitTest` expects.

- [ ] **Step 3: Build and commit**

```bash
Scripts/build-macos-packages.sh
```

```bash
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/macos-editing-ui add Packages/Features/Reader/Sources/Reader/Screens/Mac docs/engineering/ios-android-parity.md
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/macos-editing-ui commit -m "feat(reader/macos): page mode selects, routes clicks to the editor and draws the caret"
```

---

### Task 8: `MacScoreContentView` renders the edited score (spec §4.1)

**Files:**
- Modify: `Packages/Features/Reader/Sources/Reader/Screens/Mac/MacReaderRootScreen.swift:180-290`
  (`MacScoreContentView` only — the root screen changes in Task 9)

**Interfaces:**
- Consumes: `ReaderEditingDisplay` (Task 3), the three containers' new parameters (Tasks 5–7).
- Produces: `MacScoreContentView(…, editingHost: ReaderEditingHost?)`.

- [ ] **Step 1: Add the editing inputs**

In `MacScoreContentView`, after `let autoFollowEnabled: Bool` add:

```swift
    /// The note-editing seam, or `nil` for a read-only reader. Mirrors the iOS `ScoreContentView`: whether the
    /// reader is editing changes only the containers' INPUTS — which score, and whether the element-renumbering
    /// display transforms apply — never which container is mounted, so the laid-out document survives an edit.
    let editingHost: ReaderEditingHost?

    /// Non-nil while editing: the edited score with the survivable transforms applied (`ReaderEditingDisplay`).
    private var editingScore: Score? {
        ReaderEditingDisplay.score(
            host: editingHost,
            clefOverrides: viewModel.layoutModel.staffClefOverrides,
            hiddenStaves: viewModel.layoutModel.hiddenStaves,
        )
    }

    private var editingScoreVersion: Int {
        ReaderEditingDisplay.version(host: editingHost)
    }

    /// The score the containers render: the editing score while editing, the display-transformed one otherwise.
    private var renderedScore: Score? {
        editingScore ?? viewModel.visibleScore
    }

    private var isEditing: Bool {
        editingScore != nil
    }

    /// Multi-measure-rest collapse renumbers elements within a staff, which no staff remap can undo — off while
    /// editing, exactly as on iOS.
    private var effectiveCollapseMultiMeasureRests: Bool {
        isEditing ? false : collapseMultiMeasureRests
    }

    private var effectiveTransposeSemitones: Int {
        isEditing ? 0 : viewModel.transposeModel.effectiveSemitones
    }
```

- [ ] **Step 2: Use them**

In `loadStateContent`'s `.loaded` case replace `if let score = viewModel.visibleScore` with
`if let score = renderedScore`. In `scoreContainer(score:)`, for all three containers replace
`collapseMultiMeasureRests: collapseMultiMeasureRests` with `collapseMultiMeasureRests:
effectiveCollapseMultiMeasureRests`, `transposeSemitones: viewModel.transposeModel.effectiveSemitones` with
`transposeSemitones: effectiveTransposeSemitones`, and add `editingScoreVersion: editingScoreVersion,
editingHost: editingHost,` after `viewModel: viewModel,`.

In `MacReaderRootScreen.body`, pass `editingHost: nil,` to `MacScoreContentView` for now (Task 9 wires the real one).

- [ ] **Step 3: Build and commit**

```bash
Scripts/build-macos-packages.sh
```

```bash
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/macos-editing-ui add Packages/Features/Reader/Sources/Reader/Screens/Mac/MacReaderRootScreen.swift
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/macos-editing-ui commit -m "feat(reader/macos): the content view engraves the edited score while editing"
```

---

### Task 9: `MacReaderRootScreen` opens the session on load and closes it with the window (spec §1.1, §2, §4.2, §6.2)

**Files:**
- Modify: `Packages/Features/Reader/Sources/Reader/Screens/Mac/MacReaderRootScreen.swift:1-180`

**Interfaces:**
- Consumes: `ReaderViewModel.wireRevertReload(host:)` / `wirePartRemapReload(host:)` (Task 4).
- Produces: `MacReaderRootScreen.init(…, editingHost: ReaderEditingHost? = nil, …)` — the App passes one.

- [ ] **Step 1: Parameter and storage**

Add to the `init` signature, after `pdfPlaybackParser:` and before `analytics:`:

```swift
        editingHost: ReaderEditingHost? = nil,
```

with a stored `private let editingHost: ReaderEditingHost?` assigned in `init`, and this doc on the parameter (in the
init's doc comment):

```swift
    /// `editingHost` is the note-editing seam the composition root fills (`MacEditableReaderScreen`). **The Mac has
    /// no edit mode**: with a host, the session opens the moment the score has loaded and closes when the window
    /// does (design §1). `nil` is a read-only reader, which is what previews and tests get.
```

Update the file's header marker to:

```swift
// PARITY(macos): the Mac reading surface's chrome — this screen renders the score in all three display modes, shows
//   an imported PDF and committed ink, plays them from a transport bar, and edits them from the menu bar and the
//   keyboard. The inspectors, the share / annotate controls, and the score ⇄ original-PDF switch are still iOS-only;
//   see `ReaderRootScreen` for the surface being caught up to.
```

and the type's doc paragraph "What it deliberately does NOT do yet…" to: "What it deliberately does NOT do yet, each
owned by a later slice: the inspectors and panels (Ⅳc) and the score ⇄ original-PDF switch."

- [ ] **Step 2: Pass the host and mirror playback**

In `body`, `MacScoreContentView(…, editingHost: editingHost)`. Add these modifiers after the existing
`.onChange(of: layoutMode)`:

```swift
        // Mirror playback state into the seam so the App can put the editing keys to sleep while the cursor runs.
        // Reads `isPlaying`, not the cursor — re-renders on play / pause only, never per tick (same as iOS).
        .onChange(of: viewModel.playbackSession.isPlaying, initial: true) { _, isPlaying in
            editingHost?.isPlaying = isPlaying
        }
```

- [ ] **Step 3: Wire the providers and open the session in `.task`**

Replace the `.task { … }` body with:

```swift
        .task {
            viewModel.currentLayoutMode = layoutMode
            viewModel.playbackSession.startObservingCursor()
            viewModel.playbackSession.startObservingSoundfontDownload()
            if let host = editingHost {
                wireEditingSeam(host)
            }
            await viewModel.load()
            await viewModel.playbackSession.prepareForPlayback()
            await viewModel.tempoModel.setMetronomeEnabled(isMetronomeEnabled)
            // Design §1: the Mac has no edit mode. The session opens as soon as there is a score to edit, and stays
            // open for the window's lifetime — `endEditing()` in `onDisappear` is the other end.
            beginEditingIfLoaded()
        }
```

and add these private methods to `MacReaderRootScreen`:

```swift
    /// The Reader-owned half of the editing seam, identical in content to what `ReaderRootScreen.task` installs on
    /// iOS: the addressing providers, the visibility flip, play-from-selection, the edited score for the engine, and
    /// the revert / part-remap reloads.
    private func wireEditingSeam(_ host: ReaderEditingHost) {
        // Design §4.2: the selection IS the playhead while stopped. Selecting puts the displayed cursor away, and
        // `startCursorProvider` below makes Space start from the selected note — the same pairing iOS uses.
        host.onSelectionMade = { [weak viewModel] in
            viewModel?.playbackSession.hideDisplayedCursor()
        }
        host.sourceScoreProvider = { [weak viewModel, weak host] in
            host?.editedScore ?? viewModel?.loadState.score
        }
        host.hiddenStavesProvider = { [weak viewModel] in
            viewModel?.layoutModel.hiddenStaves ?? []
        }
        host.onToggleStaffVisibility = { [weak viewModel] address in
            Task { await viewModel?.layoutModel.toggleStaff(address) }
        }
        viewModel.wireRevertReload(host: host)
        viewModel.wirePartRemapReload(host: host)
        viewModel.playbackSession.startCursorProvider = { [weak host] in
            guard let host, host.isEditing, case let .single(item) = host.selection else { return nil }
            return .item(item)
        }
        viewModel.editedScoreProvider = { [weak host] in
            guard let host, host.isEditing else { return nil }
            return host.editedScore
        }
    }

    /// Opens the editing session on the loaded score. A no-op for a PDF-only item or a failed load — there is nothing
    /// to edit — and for a reader built without a host.
    private func beginEditingIfLoaded() {
        guard let host = editingHost, !host.isEditing, case let .loaded(score) = viewModel.loadState else { return }
        host.editedScore = score
        host.editGeneration += 1
        host.isEditing = true
        host.onBeginEditing(score)
    }

    /// Closes the session with the window: the App flushes the autosave and tears the session down. Unlike the iOS
    /// `finishEditing()`, nothing is adopted back into the reader — the window is going away.
    private func endEditing() {
        guard let host = editingHost, host.isEditing else { return }
        host.onEndEditing()
        host.isEditing = false
        host.selection = .none
        host.caretItem = nil
    }
```

`host.isEditing` is `public internal(set)` and this screen is inside the Reader module, so the writes compile.

- [ ] **Step 4: Close it on disappear**

Replace the `.onDisappear { … }` body with:

```swift
        .onDisappear {
            let viewModel = viewModel
            endEditing()
            viewModel.endAnnotationSessionIfNeeded()
            Task {
                await viewModel.flushPendingAnnotationSave()
                await viewModel.playbackSession.releaseEngine()
            }
        }
```

`endEditing()` first: `onEndEditing` starts the Editor's flush, and the engine release must not race a save that is
still reading the score.

- [ ] **Step 5: A revert must reopen the session**

`wireRevertReload` calls `host.requestExit()` after clearing `editedScore`, then `load()`s. On iOS that exit tears the
session down through `finishEditing()`; on the Mac the window is still open, so the session must come back on the
reloaded score. Add after the `.onChange(of: viewModel.playbackSession.isPlaying…)` modifier:

```swift
        // A revert (`wireRevertReload`) clears the edited score, asks the session to exit, and reloads the file. On
        // iOS that exit ends edit mode; here there is no mode to end, so the session is closed and reopened on the
        // reloaded score. `loadState` is what says the reload landed.
        .onChange(of: editingHost?.isExitRequested ?? false) { _, requested in
            guard requested, let host = editingHost else { return }
            endEditing()
            host.resetExitRequest()
        }
        .onChange(of: viewModel.loadState.isLoaded) { _, loaded in
            if loaded { beginEditingIfLoaded() }
        }
```

If `ReaderLoadState` has no `isLoaded`, add it to that enum in the Reader package:

```swift
    var isLoaded: Bool {
        if case .loaded = self { true } else { false }
    }
```

- [ ] **Step 6: Build**

```bash
Scripts/build-macos-packages.sh
```

Expected: green. Also run the Reader suite (from `Packages/Features/Reader`) — the count must not change.

- [ ] **Step 7: Commit**

```bash
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/macos-editing-ui add Packages/Features/Reader/Sources/Reader docs/engineering/ios-android-parity.md
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/macos-editing-ui commit -m "feat(reader/macos): the reader opens the editing session on load and closes it with the window"
```

---

### Task 10: Editor package — public sheets modifier and the revert message (spec §5.1, §5.3)

**Files:**
- Create: `Packages/Features/Editor/Sources/Editor/Views/EditorSheets.swift`
- Modify: `Packages/Features/Editor/Sources/Editor/EditorViewModel.swift:179-186` (two flags → `public`),
  `:144` (add `revertConfirmationMessage`)
- Modify: `Packages/Features/Editor/Sources/Editor/Views/EditorSessionEndButtons.swift:152-163`
- Create: `Packages/Features/Editor/Tests/EditorTests/EditorRevertMessageTests.swift`

**Interfaces:**
- Produces:
  ```swift
  extension View { public func editorSheets(viewModel: EditorViewModel) -> some View }
  extension EditorViewModel {
      public var isAddMeasuresSheetPresented: Bool   // was internal
      public var isRehearsalMarkSheetPresented: Bool // was internal
      public func revertConfirmationMessage(hasMusicalAnnotations: Bool) -> String
  }
  ```

- [ ] **Step 1: Failing test for the message**

`Packages/Features/Editor/Tests/EditorTests/EditorRevertMessageTests.swift`:

```swift
@testable import Editor
import Testing

@MainActor
struct EditorRevertMessageTests {
    @Test func `the message starts with the body and appends one paragraph per warning`() {
        let vm = PreviewEditorFactory.makeViewModel()
        let plain = vm.revertConfirmationMessage(hasMusicalAnnotations: false)
        let withInk = vm.revertConfirmationMessage(hasMusicalAnnotations: true)
        #expect(withInk.hasPrefix(plain))
        #expect(withInk.components(separatedBy: "\n\n").count == plain.components(separatedBy: "\n\n").count + 1)
    }
}
```

`PreviewEditorFactory` is used by the Editor previews (`EditorInstrumentsSheet.swift:327`); if it is `#if DEBUG`
only, the test target builds Debug, so it is reachable.

- [ ] **Step 2: Run to see it fail**

`cd Packages/Features/Editor` (own call), then:

```bash
xcodebuild test -scheme Editor-Package -destination 'platform=iOS Simulator,id=513F3B9E-891E-44CB-9DD3-BFCF5EEE3394' -skipPackagePluginValidation -only-testing:EditorTests/EditorRevertMessageTests
```

Expected: compile error, no `revertConfirmationMessage`.

- [ ] **Step 3: Move the message onto the view model**

`EditorViewModel.swift` — after `revertWarnings(hasMusicalAnnotations:)` add:

```swift
    /// The confirmation a revert shows: the base wording plus whichever caveats this score earns (`RevertPolicy`).
    /// On the view model rather than in a button because two hosts present it — the iOS session-end button as a
    /// popover, the Mac's File ▸ Revert To ▸ Original as an alert — and the composition must not fork.
    public func revertConfirmationMessage(hasMusicalAnnotations: Bool) -> String {
        let warnings = revertWarnings(hasMusicalAnnotations: hasMusicalAnnotations)
        var lines = [String(localized: "editor.revert.confirm.body", bundle: .module)]
        if warnings.contains(.musicalAnnotationsMayShift) {
            lines.append(String(localized: "editor.revert.confirm.inkMayShift", bundle: .module))
        }
        if warnings.contains(.originalMayNotBeImportTime) {
            lines.append(String(localized: "editor.revert.confirm.mayNotBeImport", bundle: .module))
        }
        return lines.joined(separator: "\n\n")
    }
```

`EditorSessionEndButtons.swift` — replace the `revertMessage` computed property's body with
`viewModel.revertConfirmationMessage(hasMusicalAnnotations: hasMusicalAnnotations)` (keep the doc comment).

`EditorViewModel.swift` — change `var isAddMeasuresSheetPresented = false` and `var isRehearsalMarkSheetPresented =
false` to `public var …`. Also add, beside them, the discard message the Mac alert needs:

```swift
    /// The confirmation a discard shows. Same reason as `revertConfirmationMessage`: two hosts, one wording.
    public var discardConfirmationMessage: String {
        String(localized: "editor.discard.confirm.message", bundle: .module)
    }
```

- [ ] **Step 4: The sheets modifier**

`Packages/Features/Editor/Sources/Editor/Views/EditorSheets.swift`:

```swift
import SwiftUI

extension View {
    /// Installs every sheet the Editor can raise — instruments, key signature, time signature, rehearsal mark, add
    /// measures, drum layout — driven by the view model's presentation flags.
    ///
    /// Public so a host that has no `EditorTopBarView` (the Mac, whose entry points are menu commands) can present
    /// the same sheets from the same flags. Apply it ONCE, to a view that lives as long as the editor does: a sheet
    /// attached to a control that can disappear goes with it, which is the rule every iOS presentation here already
    /// follows (`EditorTopBarView+MeasureMenu.measureMenuSheets`).
    public func editorSheets(viewModel: EditorViewModel) -> some View {
        modifier(EditorSheetsModifier(viewModel: viewModel))
    }
}

private struct EditorSheetsModifier: ViewModifier {
    @Bindable var viewModel: EditorViewModel

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $viewModel.isInstrumentsSheetPresented) {
                EditorInstrumentsSheet(viewModel: viewModel)
            }
            .sheet(isPresented: $viewModel.isKeySignatureSheetPresented) {
                EditorKeySignatureSheet(viewModel: viewModel)
            }
            .sheet(isPresented: $viewModel.isTimeSignatureSheetPresented) {
                EditorTimeSignatureSheet(viewModel: viewModel)
            }
            .sheet(isPresented: $viewModel.isRehearsalMarkSheetPresented) {
                EditorRehearsalMarkSheet(viewModel: viewModel)
            }
            .sheet(isPresented: $viewModel.isAddMeasuresSheetPresented) {
                EditorAddMeasuresSheet(viewModel: viewModel)
            }
            .sheet(isPresented: $viewModel.isDrumLayoutSheetPresented) {
                EditorDrumLayoutSheet(initial: viewModel.drumPadLayout) { layout in
                    viewModel.setDrumPadLayout(layout)
                    DrumPadLayoutStore.save(layout)
                }
            }
    }
}
```

The iOS top bar keeps its own three presentation helpers untouched (its behavior is not in scope); this modifier
composes the same six sheets for a second host. No toolbar-placement change is needed: every sheet already uses
`.cancellationAction` / `.confirmationAction` (`EditorAddMeasuresSheet.swift:86-91`, `EditorDrumLayoutSheet.swift:150-161`,
`EditorInstrumentsSheet.swift:263`, `EditorRehearsalMarkSheet.swift:104-115`, `EditorSignatureSheet.swift:105-110`),
which is what gives Esc and Return their meaning in a macOS sheet.

- [ ] **Step 5: Test and build**

Same `cd`, full Editor suite:

```bash
xcodebuild test -scheme Editor-Package -destination 'platform=iOS Simulator,id=513F3B9E-891E-44CB-9DD3-BFCF5EEE3394' -skipPackagePluginValidation
```

Expected: previous count + 1, zero failures. Then `Scripts/build-macos-packages.sh` green.

- [ ] **Step 6: Commit**

```bash
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/macos-editing-ui add Packages/Features/Editor
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/macos-editing-ui commit -m "feat(editor): public sheets modifier and confirmation messages for a menu-driven host"
```

---

### Task 11: Share the seam wiring between the iOS and Mac composition roots (spec §2)

**Files:**
- Create: `App/Shared/ReaderEditingWiring.swift`
- Modify: `App/iOS/EditableReaderScreen.swift:145-260` (`wireOnce` / `wirePartEditSeams`)

**Interfaces:**
- Produces:
  ```swift
  @MainActor
  func wireEditingSeam(
      host: ReaderEditingHost, viewModel: EditorViewModel,
      repository: any ScoreLibraryRepository, analytics: any Analytics,
  )
  ```

- [ ] **Step 1: Create the shared function**

`App/Shared/ReaderEditingWiring.swift` — the body is `EditableReaderScreen.wireOnce()` from `let host = editingHost`
onward, plus `wirePartEditSeams`, verbatim, with `vm` / `host` / `repository` / `analytics` as parameters. Keep every
comment: they are the record of why each closure exists.

```swift
import Domain
import Editor
import Reader

/// Connects a `ReaderEditingHost` (Reader → App) to an `EditorViewModel` (App → Editor). The ONLY place the two
/// features meet, shared by the iOS `EditableReaderScreen` and the Mac `MacEditableReaderScreen` so the closures can
/// never drift between the two shells. Call it exactly once per host / view-model pair.
@MainActor
func wireEditingSeam(
    host: ReaderEditingHost,
    viewModel vm: EditorViewModel,
    repository: any ScoreLibraryRepository,
    analytics: any Analytics,
) {
    host.onBeginEditing = { [weak vm, weak host, repository] score in
        guard let vm else { return }
        if let freshRow = repository.scoreItems.first(where: { $0.id == vm.scoreItemID }) {
            vm.refreshRow(freshRow)
        }
        vm.beginSession(score: score)
        vm.selectItem(host?.pendingSelection)
    }
    host.onEndEditing = { [weak vm] in
        guard let vm else { return }
        Task { await vm.endSession() }
    }
    host.onTap = { [weak vm] point in
        vm?.handleTap(at: point)
    }
    host.onTapOutsideScore = { [weak vm] in
        vm?.deselect()
    }
    vm.onRevertCompleted = { [weak host] item in
        host?.requestReloadAfterRevert(item)
    }
    wirePartEditSeams(host: host, viewModel: vm, analytics: analytics)
    host.onSelectionAnchorChanged = { [weak vm] anchor in
        vm?.selectionAnchor = anchor
    }
    vm.documentProvider = { [weak host] in
        host?.document
    }
    vm.displayToSourceItem = { [weak host] item in
        guard let host else { return item }
        return host.sourceItem(for: item)
    }
    vm.isStaffVisible = { [weak host] address in
        host?.isStaffVisible(address) ?? true
    }
    vm.onToggleStaffVisibility = { [weak host] address in
        host?.onToggleStaffVisibility(address)
    }
    vm.onScoreChanged = { [weak host] score in
        guard let host else { return }
        host.editedScore = score
        host.editGeneration += 1
    }
    vm.onSelectionChanged = { [weak host] selection, caret in
        guard let host else { return }
        host.selection = selection
        host.caretItem = caret
    }
}

@MainActor
private func wirePartEditSeams(host: ReaderEditingHost, viewModel vm: EditorViewModel, analytics: any Analytics) {
    vm.onPartEditApplied = { [weak host] in
        host?.raisePartMappingHold()
    }
    vm.onPartMigrationWillRun = { [weak host] in
        await host?.prepareForPartMigration()
    }
    vm.onPartsEdited = { [analytics] action in
        analytics.log(.scorePartsEdited(action: action.rawValue))
    }
    vm.onSignatureChanged = { [analytics] kind, action in
        analytics.log(.scoreSignatureChanged(kind: kind, action: action))
    }
    vm.onRehearsalMarkEdited = { [analytics] action in
        analytics.log(.scoreRehearsalMarkEdited(action: action))
    }
    host.isPartMappingSettled = { [weak vm] in
        vm?.hasUnsettledPartEdits != true
    }
    vm.onPartIndicesRemapped = { [weak host] _ in
        host?.requestReloadAfterPartRemap()
    }
}
```

Copy the original inline comments onto each closure from `EditableReaderScreen.swift` before deleting them there.

- [ ] **Step 2: Make the iOS screen call it**

`App/iOS/EditableReaderScreen.swift` — `wireOnce()` becomes:

```swift
    private func wireOnce() {
        guard !isWired else { return }
        isWired = true
        wireEditingSeam(host: editingHost, viewModel: editorViewModel, repository: repository, analytics: analytics)
    }
```

Delete `wirePartEditSeams` from the file.

- [ ] **Step 3: Build iOS and run the app tests**

```bash
xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,id=513F3B9E-891E-44CB-9DD3-BFCF5EEE3394' -skipPackagePluginValidation build
```

```bash
xcodebuild test -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,id=513F3B9E-891E-44CB-9DD3-BFCF5EEE3394' -skipPackagePluginValidation -only-testing:FolinoTests
```

Then `Scripts/build-macos-app.sh` (the Mac target compiles `App/Shared`, so it must see `Editor` — add
`- package: Editor` to `FolinoMac`'s `dependencies:` in `project.yml`, then `xcodegen generate`).

Expected: all green.

- [ ] **Step 4: Commit**

```bash
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/macos-editing-ui add App/Shared/ReaderEditingWiring.swift App/iOS/EditableReaderScreen.swift project.yml
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/macos-editing-ui commit -m "refactor(app): the Reader/Editor seam wiring is shared by both composition roots"
```

---

### Task 12: Editor registry and the quit-time flush (spec §2.1, §3.1)

**Files:**
- Create: `App/Mac/MacEditorRegistry.swift`, `App/Mac/MacAppDelegate.swift`
- Create: `Tests/FolinoMacTests/MacEditorRegistryTests.swift`
- Modify: `App/Mac/FolinoMacApp.swift` (adaptor)

**Interfaces:**
- Produces:
  ```swift
  @MainActor final class MacEditorRegistry {
      static let shared: MacEditorRegistry
      func register(_ editor: EditorViewModel, for id: ScoreItem.ID)
      func unregister(for id: ScoreItem.ID)
      var editors: [EditorViewModel]
      func flushAll(timeout: Duration) async
  }
  ```

- [ ] **Step 1: Failing tests**

`Tests/FolinoMacTests/MacEditorRegistryTests.swift`:

```swift
import Domain
import Editor
@testable import folino
import Testing

@MainActor
struct MacEditorRegistryTests {
    private func makeEditor() -> EditorViewModel {
        // The registry only holds references; an editor with no session is enough.
        PreviewEditorFactory.makeViewModel()
    }

    @Test func `register then unregister leaves nothing`() {
        let registry = MacEditorRegistry()
        let id = ScoreItemID()
        registry.register(makeEditor(), for: id)
        #expect(registry.editors.count == 1)
        registry.unregister(for: id)
        #expect(registry.editors.isEmpty)
    }

    @Test func `one entry per score, the latest wins`() {
        let registry = MacEditorRegistry()
        let id = ScoreItemID()
        let second = makeEditor()
        registry.register(makeEditor(), for: id)
        registry.register(second, for: id)
        #expect(registry.editors.count == 1)
        #expect(registry.editors.first === second)
    }

    @Test func `flushAll returns even when an editor never finishes`() async {
        let registry = MacEditorRegistry()
        registry.register(makeEditor(), for: ScoreItemID())
        let clock = ContinuousClock()
        let start = clock.now
        await registry.flushAll(timeout: .milliseconds(200))
        #expect(clock.now - start < .seconds(2))
    }
}
```

`PreviewEditorFactory` must be reachable from the App tests: if it is `internal` to Editor, add a `public static func
makeViewModel()` alongside it under `#if DEBUG` (the test target builds Debug).

- [ ] **Step 2: Run to see them fail**

```bash
xcodebuild test -project Folino.xcodeproj -scheme FolinoMac -destination 'platform=macOS' -skipPackagePluginValidation -only-testing:FolinoMacTests/MacEditorRegistryTests
```

Expected: compile error, `MacEditorRegistry` not found.

- [ ] **Step 3: Implement**

`App/Mac/MacEditorRegistry.swift`:

```swift
import Domain
import Editor
import Foundation

/// The live editors of this process, keyed by score. Bookkeeping, not a shared-editor scheme: with one window per
/// score (design §3) there is never more than one entry per id. It exists for two things — `MacAppDelegate`'s
/// quit-time flush, which has to find every open editor, and the register / unregister pair that keeps a window
/// closed and reopened from racing its predecessor's `endSession`.
@MainActor
final class MacEditorRegistry {
    static let shared = MacEditorRegistry()

    private var byScore: [ScoreItem.ID: EditorViewModel] = [:]

    var editors: [EditorViewModel] {
        Array(byScore.values)
    }

    func register(_ editor: EditorViewModel, for id: ScoreItem.ID) {
        byScore[id] = editor
    }

    func unregister(for id: ScoreItem.ID) {
        byScore[id] = nil
    }

    /// Flushes every editor's pending autosave, bounded: a flush that never returns must not hang quit (design §9).
    func flushAll(timeout: Duration) async {
        let editors = editors
        let flush = Task { @MainActor in
            for editor in editors {
                await editor.flushPendingSave()
            }
        }
        let timer = Task {
            try? await Task.sleep(for: timeout)
            flush.cancel()
        }
        await flush.value
        timer.cancel()
    }
}
```

`App/Mac/MacAppDelegate.swift`:

```swift
import AppKit

/// The one piece of AppKit lifecycle the Mac shell owns: an edit made within the autosave debounce of ⌘Q must reach
/// the disk. Every window's `onDisappear` flushes on close; quitting the app does not reliably reach those, so
/// termination is deferred until every live editor has flushed (design §2.1).
final class MacAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task { @MainActor in
            await MacEditorRegistry.shared.flushAll(timeout: .seconds(5))
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
```

`App/Mac/FolinoMacApp.swift` — add to `FolinoMacApp`:

```swift
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var appDelegate
```

- [ ] **Step 4: Test, build, commit**

```bash
xcodebuild test -project Folino.xcodeproj -scheme FolinoMac -destination 'platform=macOS' -skipPackagePluginValidation -only-testing:FolinoMacTests
```

Expected: 5 tests, 5 passed (2 from Task 2 + 3).

```bash
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/macos-editing-ui add App/Mac Tests/FolinoMacTests Packages/Features/Editor
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/macos-editing-ui commit -m "feat(macos): editor registry and a quit-time autosave flush"
```

---

### Task 13: `MacEditableReaderScreen` — the Mac composition root for editing (spec §2, §5.3)

**Files:**
- Create: `App/Mac/MacEditableReaderScreen.swift`
- Modify: `App/Mac/MacShellView.swift:100-115` (`content`)
- Modify: `App/Resources/Localizable.xcstrings` (confirmation strings)

**Interfaces:**
- Consumes: `wireEditingSeam` (Task 11), `MacEditorRegistry` (Task 12), `editorSheets(viewModel:)` and the two
  messages (Task 10), `MacReaderRootScreen(editingHost:)` (Task 9).
- Produces: `MacEditableReaderScreen(item:bootstrap:libraryVM:)`; the focused value `\.macEditingTarget` of type
  `MacEditingTarget` (declared here, read by Task 14's menus).

- [ ] **Step 1: The screen**

`App/Mac/MacEditableReaderScreen.swift`:

```swift
import Domain
import Editor
import Reader
import SwiftUI
import UtilityCore

/// What the menus act on: the editor behind the key score window, and the presentation flags the File menu's
/// confirmations flip. Published as a `focusedValue` by the score surface's window so `MacEditingMenus` reads the
/// right editor when several score windows are open — and reads `nil` when none is key.
@MainActor
final class MacEditingTarget {
    let editor: EditorViewModel
    let host: ReaderEditingHost
    /// Flipped by File ▸ Revert To ▸ Last Opened / Original; the screen presents the confirmation.
    var isConfirmingDiscard: () -> Void
    var isConfirmingRevert: () -> Void

    init(
        editor: EditorViewModel, host: ReaderEditingHost,
        confirmDiscard: @escaping () -> Void, confirmRevert: @escaping () -> Void,
    ) {
        self.editor = editor
        self.host = host
        isConfirmingDiscard = confirmDiscard
        isConfirmingRevert = confirmRevert
    }
}

private struct MacEditingTargetKey: FocusedValueKey {
    typealias Value = MacEditingTarget
}

extension FocusedValues {
    var macEditingTarget: MacEditingTarget? {
        get { self[MacEditingTargetKey.self] }
        set { self[MacEditingTargetKey.self] = newValue }
    }
}

/// The Mac sibling of `App/iOS/EditableReaderScreen.swift`: one `ReaderEditingHost` + one `EditorViewModel` per
/// score window, wired by the shared `wireEditingSeam`, handed into `MacReaderRootScreen`. No chrome builders — the
/// Mac has no pad, no top strip and no cutout tier; its editing controls are the menu bar and the keyboard.
@MainActor
struct MacEditableReaderScreen: View {
    let item: ScoreItem
    let bootstrap: AppBootstrap
    let libraryVM: LibraryViewModel

    @State private var editingHost = ReaderEditingHost()
    @State private var editorViewModel: EditorViewModel
    @State private var isWired = false
    @State private var isConfirmingDiscard = false
    @State private var isConfirmingRevert = false
    @Environment(\.undoManager) private var undoManager

    private let repository: any ScoreLibraryRepository
    private let analytics: any Analytics

    init(item: ScoreItem, bootstrap: AppBootstrap, libraryVM: LibraryViewModel) {
        self.item = item
        self.bootstrap = bootstrap
        self.libraryVM = libraryVM
        guard let repository = bootstrap.repository,
              let gateway = bootstrap.gateway,
              let originalStore = bootstrap.originalStore
        else {
            fatalError("MacEditableReaderScreen built before AppBootstrap finished starting")
        }
        self.repository = repository
        analytics = bootstrap.analytics ?? NoopAnalytics()
        _editorViewModel = State(wrappedValue: EditorViewModel(
            scoreItem: item,
            scoresDirectory: AppPaths.scoresDirectory,
            gateway: gateway,
            repository: repository,
            originalStore: originalStore,
            historyStore: bootstrap.editHistoryStore,
            playback: bootstrap.playbackController,
            annotationStore: bootstrap.annotationStore,
        ))
    }

    var body: some View {
        MacReaderRootScreen(
            scoreItem: item,
            repository: repository,
            originalStore: bootstrap.originalStore!,
            gateway: bootstrap.gateway!,
            shareService: bootstrap.shareService!,
            metadataReader: bootstrap.metadataReader!,
            annotationCoordinator: bootstrap.annotationCoordinator!,
            scoresDirectory: AppPaths.scoresDirectory,
            playbackController: bootstrap.playbackController,
            pdfPlaybackParser: bootstrap.pdfPlaybackParser,
            editingHost: editingHost,
            analytics: analytics,
        )
        .editorSheets(viewModel: editorViewModel)
        .focusedSceneValue(\.macEditingTarget, target)
        .confirmationDialog(
            Text("mac.revert.lastOpened.title"),
            isPresented: $isConfirmingDiscard,
            titleVisibility: .visible,
        ) {
            Button(role: .destructive) {
                Task { await editorViewModel.discardSessionEdits() }
            } label: {
                Text("mac.revert.lastOpened.action")
            }
        } message: {
            Text(editorViewModel.discardConfirmationMessage)
        }
        .confirmationDialog(
            Text("mac.revert.original.title"),
            isPresented: $isConfirmingRevert,
            titleVisibility: .visible,
        ) {
            Button(role: .destructive) {
                Task { await editorViewModel.revertToOriginal() }
            } label: {
                Text("mac.revert.original.action")
            }
        } message: {
            Text(editorViewModel.revertConfirmationMessage(
                hasMusicalAnnotations: editingHost.hasMusicalAnnotationsProvider(),
            ))
        }
        .onAppear { wireOnce() }
        .onChange(of: editingHost.isPlaying, initial: true) { _, isPlaying in
            editorViewModel.isPlaybackActive = isPlaying
        }
        // The system Undo / Redo items drive the session through the same trampolines the iOS chrome registers,
        // re-registered only on a genuinely NEW edit — see `EditorViewModel.appliedEditCount`.
        .onChange(of: editorViewModel.appliedEditCount) { _, _ in
            editorViewModel.registerSystemUndo(with: undoManager)
        }
        .onDisappear {
            MacEditorRegistry.shared.unregister(for: item.id)
        }
    }

    private var target: MacEditingTarget {
        MacEditingTarget(
            editor: editorViewModel, host: editingHost,
            confirmDiscard: { isConfirmingDiscard = true },
            confirmRevert: { isConfirmingRevert = true },
        )
    }

    private func wireOnce() {
        guard !isWired else { return }
        isWired = true
        wireEditingSeam(host: editingHost, viewModel: editorViewModel, repository: repository, analytics: analytics)
        MacEditorRegistry.shared.register(editorViewModel, for: item.id)
    }
}
```

`registerSystemUndo(with:)` is `internal` to Editor: make it `public` (one-word change in
`EditorViewModel+Session.swift`). The force-unwraps in `body` mirror `MacShellView.init`'s guarantee (every adapter is
non-nil once `bootstrap.isReady`); keep them next to that comment or copy the guard into `init` as `MacShellView`
does.

A `focusedSceneValue` (scene-scoped) is used for `macEditingTarget`, deliberately: menu commands must find the key
window's editor whether or not the score surface holds view focus. Bare-key delivery is a separate question (Task 1's
answer), applied in Task 14.

- [ ] **Step 2: Strings**

`App/Resources/Localizable.xcstrings` — add five keys with all five localizations (`en`, `ja`, `ko`, `zh-Hans`,
`zh-Hant`; state `translated`):

| key | en | ja |
| --- | --- | --- |
| `mac.revert.lastOpened.title` | Revert to Last Opened? | 開いた時点に戻しますか？ |
| `mac.revert.lastOpened.action` | Revert | 戻す |
| `mac.revert.original.title` | Revert to Original? | 元の楽譜に戻しますか？ |
| `mac.revert.original.action` | Revert | 戻す |
| `mac.menu.revertTo` | Revert To | 復帰 |

Provide `ko`, `zh-Hans`, `zh-Hant` values (ko: "마지막으로 연 상태로 되돌리겠습니까?", "되돌리기", "원본으로
되돌리겠습니까?", "되돌리기", "되돌리기"; zh-Hans: "恢复到上次打开时？", "恢复", "恢复为原始乐谱？", "恢复", "恢复到";
zh-Hant: "回復到上次開啟時？", "回復", "回復為原始樂譜？", "回復", "回復到").

- [ ] **Step 3: Mount it**

`App/Mac/MacShellView.swift` — in `content`, replace the `MacReaderRootScreen(…)` construction (through
`.id(item.id)`) with:

```swift
            MacEditableReaderScreen(item: item, bootstrap: bootstrap, libraryVM: libraryVM)
                .id(item.id)
```

The six adapter properties `MacShellView` unwrapped only to pass into the reader can stay (the import action still
needs `libraryVM`); delete the ones no longer read (`repository` is still read by `openScoreItem`).

- [ ] **Step 4: Build and launch**

```bash
Scripts/build-macos-app.sh
```

Expected: BUILD SUCCEEDED. Then find the app and launch it for a smoke check:

```bash
find ~/Library/Developer/Xcode/DerivedData -path '*Build/Products/Debug/folino.app' -maxdepth 6
```

```bash
open <that path>
```

Ask the user: open a score, click a note (it tints), press ⌘Z (nothing yet to undo — the menu item is disabled),
close the window, quit. No crash. Menus and keys come in Task 14; this step only proves the session opens and closes.

- [ ] **Step 5: Commit**

```bash
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/macos-editing-ui add App/Mac App/Resources/Localizable.xcstrings Packages/Features/Editor/Sources/Editor/EditorViewModel+Session.swift
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/macos-editing-ui commit -m "feat(macos): the score window composes the editor; File ▸ Revert To confirmations"
```

---

### Task 14: The command table, the menus and the key map (spec §5, §6)

**Files:**
- Create: `App/Mac/MacEditingCommands.swift`, `App/Mac/MacEditingMenus.swift`, `App/Mac/MacEditingKeyMap.swift`
- Create: `Tests/FolinoMacTests/MacEditingCommandsTests.swift`
- Modify: `App/Mac/FolinoMacApp.swift` (`.commands { MacCommands(); MacEditingMenus() }`)
- Modify: `App/Mac/MacEditableReaderScreen.swift` (mount `MacEditingKeyMap` if Task 1 chose B)
- Modify: `App/Resources/Localizable.xcstrings` (menu titles)

**Interfaces:**
- Consumes: `MacEditingTarget` via `@FocusedValue(\.macEditingTarget)`; the bench decision.
- Produces:
  ```swift
  enum MacEditingMenu: CaseIterable { case file, edit, notes, measures, score }
  struct MacEditingCommand: Identifiable {
      let id: String; let title: LocalizedStringKey; let menu: MacEditingMenu
      let key: KeyEquivalent?; let modifiers: EventModifiers; let isBareKey: Bool
      let isMutating: Bool
      let isEnabled: @MainActor (MacEditingTarget) -> Bool
      let perform: @MainActor (MacEditingTarget) -> Void
  }
  enum MacEditingCommands { static let all: [MacEditingCommand]; static func commands(in menu: MacEditingMenu) -> [MacEditingCommand] }
  ```

- [ ] **Step 1: Failing tests**

`Tests/FolinoMacTests/MacEditingCommandsTests.swift`:

```swift
@testable import folino
import Testing

struct MacEditingCommandsTests {
    @Test func `every command id is unique`() {
        let ids = MacEditingCommands.all.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func `every bare key is bound at most once and never with modifiers`() {
        let bare = MacEditingCommands.all.filter(\.isBareKey)
        #expect(bare.allSatisfy { $0.modifiers.isEmpty })
        let keys = bare.compactMap { $0.key.map(\.character) }
        #expect(Set(keys).count == keys.count)
    }

    @Test func `every menu has at least one command and every command is in a menu`() {
        for menu in MacEditingMenu.allCases {
            #expect(!MacEditingCommands.commands(in: menu).isEmpty, "\(menu)")
        }
        let placed = MacEditingMenu.allCases.flatMap { MacEditingCommands.commands(in: $0) }.count
        #expect(placed == MacEditingCommands.all.count)
    }

    @Test func `the MuseScore letters and digits are bound as the spec's table says`() {
        func key(_ id: String) -> Character? { MacEditingCommands.all.first { $0.id == id }?.key?.character }
        #expect(key("notes.pitch.a") == "a")
        #expect(key("notes.pitch.g") == "g")
        #expect(key("notes.duration.quarter") == "5")
        #expect(key("notes.rest") == "0")
        #expect(key("notes.dot") == ".")
        #expect(key("notes.tie") == "+")
        #expect(key("notes.tuplet.3") == "3")
    }
}
```

The "disabled during playback" property is exercised in `MacEditingCommands` by construction (every mutating row's
`isEnabled` starts with `!target.editor.isPlaybackActive`); it is not unit-tested here because building a
`MacEditingTarget` needs a `ReaderEditingHost`, which the App tests can construct — add this fourth test if
`PreviewEditorFactory.makeViewModel()` is public after Task 12:

```swift
    @Test @MainActor func `every mutating command is disabled while playback runs`() {
        let editor = PreviewEditorFactory.makeViewModel()
        editor.isPlaybackActive = true
        let target = MacEditingTarget(editor: editor, host: ReaderEditingHost(), confirmDiscard: {}, confirmRevert: {})
        for command in MacEditingCommands.all where command.isMutating {
            #expect(!command.isEnabled(target), command.id)
        }
    }
```

(with `import Editor` and `import Reader` at the top).

- [ ] **Step 2: Run to see them fail**

```bash
xcodebuild test -project Folino.xcodeproj -scheme FolinoMac -destination 'platform=macOS' -skipPackagePluginValidation -only-testing:FolinoMacTests/MacEditingCommandsTests
```

Expected: compile error.

- [ ] **Step 3: The table**

`App/Mac/MacEditingCommands.swift`:

```swift
import Editor
import Reader
import SheetMusicCore
import SwiftUI

/// Where a command lives in the menu bar (design §5.1).
enum MacEditingMenu: CaseIterable {
    case file, edit, notes, measures, score
}

/// One editing command, declared exactly once. `MacEditingMenus` turns the table into menu items and
/// `MacEditingKeyMap` (when the bench chose view-level delivery) into key equivalents; Ⅳb turns the same rows into
/// search results. Titles are keys in the App's `Localizable.xcstrings`.
struct MacEditingCommand: Identifiable {
    let id: String
    let title: LocalizedStringKey
    let menu: MacEditingMenu
    /// The key equivalent, if any. `isBareKey` says it carries no modifier — the case the bench (Task 1) decides the
    /// delivery of; modifier-bearing shortcuts always sit on the menu item.
    let key: KeyEquivalent?
    let modifiers: EventModifiers
    var isBareKey: Bool { key != nil && modifiers.isEmpty }
    /// Whether the command changes the score. Every mutating command is inert while the transport runs (§6.2).
    let isMutating: Bool
    let isEnabled: @MainActor (MacEditingTarget) -> Bool
    let perform: @MainActor (MacEditingTarget) -> Void

    init(
        _ id: String, _ title: LocalizedStringKey, menu: MacEditingMenu,
        key: KeyEquivalent? = nil, modifiers: EventModifiers = [],
        mutating: Bool = true,
        isEnabled: @escaping @MainActor (MacEditingTarget) -> Bool = { _ in true },
        perform: @escaping @MainActor (MacEditingTarget) -> Void,
    ) {
        self.id = id
        self.title = title
        self.menu = menu
        self.key = key
        self.modifiers = modifiers
        isMutating = mutating
        // A mutating command is disabled during playback before its own rule is consulted.
        self.isEnabled = mutating
            ? { target in !target.editor.isPlaybackActive && isEnabled(target) }
            : isEnabled
        self.perform = perform
    }
}

enum MacEditingCommands {
    static func commands(in menu: MacEditingMenu) -> [MacEditingCommand] {
        all.filter { $0.menu == menu }
    }

    static let all: [MacEditingCommand] = file + edit + notes + measures + score

    // MARK: File (design §5.3)

    private static let file: [MacEditingCommand] = [
        .init("file.revert.lastOpened", "mac.menu.revert.lastOpened", menu: .file, mutating: false,
              isEnabled: { $0.editor.sessionHasEdits }) { $0.isConfirmingDiscard() },
        .init("file.revert.original", "mac.menu.revert.original", menu: .file, mutating: false,
              isEnabled: { $0.editor.canRevertToOriginal }) { $0.isConfirmingRevert() },
    ]

    // MARK: Edit

    private static let edit: [MacEditingCommand] = [
        .init("edit.deselect", "mac.menu.edit.deselect", menu: .edit, key: .escape, mutating: false,
              isEnabled: { $0.editor.selectedItem != nil }) { $0.editor.deselect() },
        .init("edit.previous", "mac.menu.edit.previousElement", menu: .edit, key: .leftArrow, mutating: false,
              isEnabled: { $0.editor.hasEditTarget }) { $0.editor.selectPreviousElement() },
        .init("edit.next", "mac.menu.edit.nextElement", menu: .edit, key: .rightArrow, mutating: false,
              isEnabled: { $0.editor.hasEditTarget }) { $0.editor.selectNextElement() },
    ]

    // MARK: Notes (design §6 key map)

    private static let pitchLetters: [(Character, LocalizedStringKey)] = [
        ("a", "mac.menu.notes.pitch.a"), ("b", "mac.menu.notes.pitch.b"), ("c", "mac.menu.notes.pitch.c"),
        ("d", "mac.menu.notes.pitch.d"), ("e", "mac.menu.notes.pitch.e"), ("f", "mac.menu.notes.pitch.f"),
        ("g", "mac.menu.notes.pitch.g"),
    ]

    /// MuseScore's digit table: 1 = 64th … 7 = whole. Same one ssm's macOS example binds.
    private static let durations: [(Character, NoteDuration, LocalizedStringKey)] = [
        ("1", .sixtyFourth, "mac.menu.notes.duration.64th"), ("2", .thirtySecond, "mac.menu.notes.duration.32nd"),
        ("3", .sixteenth, "mac.menu.notes.duration.16th"), ("4", .eighth, "mac.menu.notes.duration.8th"),
        ("5", .quarter, "mac.menu.notes.duration.quarter"), ("6", .half, "mac.menu.notes.duration.half"),
        ("7", .whole, "mac.menu.notes.duration.whole"),
    ]

    private static let accidentals: [(Accidental?, LocalizedStringKey)] = [
        (.doubleFlat, "mac.menu.notes.accidental.doubleFlat"), (.flat, "mac.menu.notes.accidental.flat"),
        (.natural, "mac.menu.notes.accidental.natural"), (.sharp, "mac.menu.notes.accidental.sharp"),
        (.doubleSharp, "mac.menu.notes.accidental.doubleSharp"), (nil, "mac.menu.notes.accidental.none"),
    ]

    private static let notes: [MacEditingCommand] = pitchCommands + durationCommands + [
        .init("notes.rest", "mac.menu.notes.rest", menu: .notes, key: "0",
              isEnabled: { $0.editor.hasEditTarget }) { $0.editor.writeRest() },
        .init("notes.dot", "mac.menu.notes.dot", menu: .notes, key: ".",
              isEnabled: { $0.editor.hasEditTarget }) { $0.editor.toggleSelectionDot() },
        .init("notes.dot.double", "mac.menu.notes.dot.double", menu: .notes, key: ".", modifiers: .option,
              isEnabled: { $0.editor.hasEditTarget }) { $0.editor.setSelectionDots(2) },
        .init("notes.pitch.up", "mac.menu.notes.pitch.up", menu: .notes, key: .upArrow,
              isEnabled: { $0.editor.isNoteSelected }) { $0.editor.shiftPitch(bySemitones: 1) },
        .init("notes.pitch.down", "mac.menu.notes.pitch.down", menu: .notes, key: .downArrow,
              isEnabled: { $0.editor.isNoteSelected }) { $0.editor.shiftPitch(bySemitones: -1) },
        .init("notes.octave.up", "mac.menu.notes.octave.up", menu: .notes, key: .upArrow, modifiers: .command,
              isEnabled: { $0.editor.isNoteSelected }) { $0.editor.shiftOctave(by: 1) },
        .init("notes.octave.down", "mac.menu.notes.octave.down", menu: .notes, key: .downArrow, modifiers: .command,
              isEnabled: { $0.editor.isNoteSelected }) { $0.editor.shiftOctave(by: -1) },
        .init("notes.chord.remove", "mac.menu.notes.chord.removeNote", menu: .notes, key: .delete, modifiers: .shift,
              isEnabled: { $0.editor.isNoteSelected }) { $0.editor.removeSelectedNoteFromChord() },
        .init("notes.tie", "mac.menu.notes.tie", menu: .notes, key: "+",
              isEnabled: { $0.editor.canTie }) { $0.editor.toggleTie() },
        .init("notes.tie.append", "mac.menu.notes.tiedNote", menu: .notes,
              isEnabled: { $0.editor.isNoteSelected }) { $0.editor.appendTiedNote() },
        .init("notes.tuplet.remove", "mac.menu.notes.tuplet.remove", menu: .notes,
              isEnabled: { $0.editor.isCaretInTuplet }) { $0.editor.removeTuplet() },
        .init("notes.delete", "mac.menu.notes.delete", menu: .notes, key: .delete,
              isEnabled: { $0.editor.selectedItem != nil }) { $0.editor.deleteSelection() },
    ] + accidentalCommands + chordCommands + tupletCommands + voiceCommands

    private static var pitchCommands: [MacEditingCommand] {
        pitchLetters.map { letter, title in
            .init("notes.pitch.\(letter)", title, menu: .notes, key: KeyEquivalent(letter),
                  isEnabled: { $0.editor.hasEditTarget }) { target in
                // On a drum staff the letters are the kit's own shortcuts (`DrumsetEntry.shortcut`), not pitches.
                if target.editor.isDrumStaffActive {
                    if let key = target.editor.drumPadLayout.keys.first(where: { $0.shortcut == letter }) {
                        target.editor.pressDrumKey(key)
                    }
                } else {
                    target.editor.inputPitch(letter: letter)
                }
            }
        }
    }

    private static var durationCommands: [MacEditingCommand] {
        durations.map { digit, duration, title in
            .init("notes.duration.\(durationID(duration))", title, menu: .notes, key: KeyEquivalent(digit)) { target in
                if target.editor.selectedItem != nil {
                    target.editor.setSelectionDuration(duration)
                } else {
                    target.editor.setDuration(duration)
                }
            }
        }
    }

    private static func durationID(_ d: NoteDuration) -> String {
        switch d {
        case .whole: "whole"
        case .half: "half"
        case .quarter: "quarter"
        case .eighth: "8th"
        case .sixteenth: "16th"
        case .thirtySecond: "32nd"
        default: "64th"
        }
    }

    private static var accidentalCommands: [MacEditingCommand] {
        accidentals.map { accidental, title in
            .init("notes.accidental.\(accidental.map { "\($0)" } ?? "none")", title, menu: .notes,
                  isEnabled: { $0.editor.isNoteSelected }) { $0.editor.setAccidental(accidental) }
        }
    }

    /// ⇧A–⇧G add that pitch to the selected chord: arm add-to-chord, write the letter, disarm.
    private static var chordCommands: [MacEditingCommand] {
        pitchLetters.map { letter, _ in
            .init("notes.chord.add.\(letter)", "mac.menu.notes.chord.add.\(letter)", menu: .notes,
                  key: KeyEquivalent(letter), modifiers: .shift,
                  isEnabled: { $0.editor.isNoteSelected }) { target in
                if !target.editor.isAddToChordArmed { target.editor.toggleAddToChord() }
                target.editor.inputPitch(letter: letter)
                if target.editor.isAddToChordArmed { target.editor.toggleAddToChord() }
            }
        } + (2 ... 9).map { interval in
            .init("notes.chord.interval.\(interval)", "mac.menu.notes.chord.interval.\(interval)", menu: .notes,
                  isEnabled: { $0.editor.isNoteSelected }) { target in
                if let value = DiatonicInterval(rawValue: interval) { target.editor.addIntervalNote(value) }
            }
        }
    }

    /// ⌘3–⌘9: MuseScore's tuplet keys. Ⅳc re-homes ⌘3 / ⌘4 to panels (design §6).
    private static var tupletCommands: [MacEditingCommand] {
        (3 ... 9).map { count in
            .init("notes.tuplet.\(count)", "mac.menu.notes.tuplet.\(count)", menu: .notes,
                  key: KeyEquivalent(Character("\(count)")), modifiers: .command,
                  isEnabled: { $0.editor.hasEditTarget }) { target in
                if target.editor.isCaretInTuplet {
                    target.editor.removeTuplet()
                } else {
                    target.editor.createTuplet(actualNotes: count)
                }
            }
        }
    }

    private static var voiceCommands: [MacEditingCommand] {
        (1 ... 4).map { voice in
            .init("notes.voice.\(voice)", "mac.menu.notes.voice.\(voice)", menu: .notes,
                  key: KeyEquivalent(Character("\(voice)")), modifiers: [.command, .option],
                  mutating: false) { $0.editor.activeVoice = voice - 1 }
        }
    }

    // MARK: Measures

    private static let measures: [MacEditingCommand] = [
        .init("measures.append", "mac.menu.measures.append", menu: .measures) { $0.editor.appendMeasure() },
        .init("measures.append.many", "mac.menu.measures.appendMany", menu: .measures) {
            $0.editor.isAddMeasuresSheetPresented = true
        },
        .init("measures.insertBefore", "mac.menu.measures.insertBefore", menu: .measures,
              isEnabled: { $0.editor.targetMeasureIndex != nil }) { $0.editor.insertMeasureBeforeTarget() },
        .init("measures.delete", "mac.menu.measures.delete", menu: .measures,
              isEnabled: { $0.editor.targetMeasureIndex != nil }) { $0.editor.deleteTargetMeasure() },
        .init("measures.keySignature", "mac.menu.measures.keySignature", menu: .measures,
              isEnabled: { $0.editor.targetMeasureIndex != nil && $0.editor.targetConcertKey != nil }) {
            $0.editor.isKeySignatureSheetPresented = true
        },
        .init("measures.timeSignature", "mac.menu.measures.timeSignature", menu: .measures,
              isEnabled: { $0.editor.targetMeasureIndex != nil }) { $0.editor.isTimeSignatureSheetPresented = true },
        .init("measures.rehearsalMark", "mac.menu.measures.rehearsalMark", menu: .measures,
              isEnabled: { $0.editor.targetMeasureIndex != nil }) { $0.editor.isRehearsalMarkSheetPresented = true },
    ]

    // MARK: Score

    private static let score: [MacEditingCommand] = [
        .init("score.instruments", "mac.menu.score.instruments", menu: .score, key: "i") {
            $0.editor.isInstrumentsSheetPresented = true
        },
        .init("score.drumLayout", "mac.menu.score.drumLayout", menu: .score, mutating: false,
              isEnabled: { $0.editor.isDrumStaffActive }) { $0.editor.isDrumLayoutSheetPresented = true },
    ]
}
```

Adjust to the real API where the sketch guessed: `DrumPadLayout.keys` and `DrumPadKey.shortcut` (read
`Packages/Features/Editor/Sources/EditorCore` for the drum pad types — the key's letter may be a `Character` or a
`String`); `DiatonicInterval(rawValue:)` (see `EditorViewModel+Ops.swift:113` for the type it takes);
`KeyEquivalent(Character)` exists; `Accidental` cases are `.doubleFlat, .flat, .natural, .sharp, .doubleSharp`
(check `SheetMusicCore`). Sheets that open (`measures.append.many`, the signature and mark sheets, instruments,
drum layout) are `mutating: true` so they stay closed during playback, matching the iOS strip.

- [ ] **Step 4: The menus**

`App/Mac/MacEditingMenus.swift`:

```swift
import SwiftUI

/// The editing half of the menu bar, generated from `MacEditingCommands`. Every command has a home here (umbrella
/// §2.3, "the menu bar is the complete index"); which ones are enabled is asked of the key window's editor through
/// the focused value.
struct MacEditingMenus: Commands {
    @FocusedValue(\.macEditingTarget) private var target

    var body: some Commands {
        CommandGroup(after: .saveItem) {
            Menu {
                items(in: .file)
            } label: {
                Text("mac.menu.revertTo")
            }
            .disabled(target == nil)
        }
        CommandGroup(after: .undoRedo) {
            Divider()
            items(in: .edit)
        }
        CommandMenu(Text("mac.menu.notes")) {
            items(in: .notes)
        }
        CommandMenu(Text("mac.menu.measures")) {
            items(in: .measures)
        }
        CommandMenu(Text("mac.menu.score")) {
            items(in: .score)
        }
    }

    @ViewBuilder
    private func items(in menu: MacEditingMenu) -> some View {
        ForEach(MacEditingCommands.commands(in: menu)) { command in
            MacEditingMenuItem(command: command, target: target)
        }
    }
}

private struct MacEditingMenuItem: View {
    let command: MacEditingCommand
    let target: MacEditingTarget?

    var body: some View {
        let enabled = target.map(command.isEnabled) ?? false
        Button {
            if let target { command.perform(target) }
        } label: {
            Text(command.title)
        }
        .disabled(!enabled)
        .modifier(MacEditingShortcut(command: command, hasTarget: target != nil))
    }
}

/// Where a command's key equivalent is attached — the bench's answer (see
/// `2026-09-02-macos-edit-session-bench.md`).
///
/// **A:** every shortcut sits on the menu item; a BARE key only while a target is focused, so a text field that has
/// taken focus (the target reads `nil`) gets the letter.
/// **B:** modifier-bearing shortcuts sit on the menu item; bare keys are delivered by `MacEditingKeyMap` and the
/// item shows none.
private struct MacEditingShortcut: ViewModifier {
    let command: MacEditingCommand
    let hasTarget: Bool

    func body(content: Content) -> some View {
        if let key = command.key, !command.isBareKey {
            content.keyboardShortcut(key, modifiers: command.modifiers)
        } else if let key = command.key, MacEditingKeyDelivery.current == .menuWhileFocused, hasTarget {
            content.keyboardShortcut(key, modifiers: [])
        } else {
            content
        }
    }
}

/// The bench decision, as a constant the two delivery sites read. Change ONLY with a re-run of Task 1's bench.
enum MacEditingKeyDelivery {
    case menuWhileFocused // A
    case viewLevel // B
    static let current: MacEditingKeyDelivery = .menuWhileFocused // ← set from the bench result
}
```

For **A**, `MacEditingTarget` must be published by a **view-scoped** `focusedValue` that goes `nil` when a text field
takes focus — change `MacEditableReaderScreen`'s `.focusedSceneValue(\.macEditingTarget, target)` to
`.focusedValue(\.macEditingTarget, target)` placed on the score surface after `.focusable()`, and keep a SECOND,
scene-scoped publication (`.focusedSceneValue(\.macEditingTargetScene, target)`, a sibling key) for the modifier-
bearing items and the File menu, which must work regardless of view focus. For **B**, the scene value alone is enough.

`App/Mac/MacEditingKeyMap.swift` (B only; empty view otherwise):

```swift
import SwiftUI

/// Bare-key delivery, shape B: one invisible `Button` per bare-key command, inside the score window's view tree.
/// SwiftUI's view-level `.keyboardShortcut` is focus-aware — a focused text field keeps the letter — where an
/// `NSMenuItem` key equivalent is not (measured in `MacTransportBar.playPauseButton`).
struct MacEditingKeyMap: View {
    let target: MacEditingTarget

    var body: some View {
        if MacEditingKeyDelivery.current == .viewLevel {
            ForEach(MacEditingCommands.all.filter(\.isBareKey)) { command in
                Button("") {
                    if command.isEnabled(target) { command.perform(target) }
                }
                .keyboardShortcut(command.key!, modifiers: [])
            }
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
    }
}
```

mounted in `MacEditableReaderScreen.body` as `.background(MacEditingKeyMap(target: target))`.

`App/Mac/FolinoMacApp.swift` — `.commands { MacCommands() }` becomes `.commands { MacCommands(); MacEditingMenus() }`.

- [ ] **Step 5: Strings**

Add every `mac.menu.*` key the table references to `App/Resources/Localizable.xcstrings`, five localizations each.
The en / ja pairs (others: translate faithfully):

| key | en | ja |
| --- | --- | --- |
| `mac.menu.notes` | Notes | 音符 |
| `mac.menu.measures` | Measures | 小節 |
| `mac.menu.score` | Score | 楽譜 |
| `mac.menu.revert.lastOpened` | Last Opened | 開いた時点 |
| `mac.menu.revert.original` | Original | 元の楽譜 |
| `mac.menu.edit.deselect` | Deselect | 選択解除 |
| `mac.menu.edit.previousElement` | Previous Note | 前の音符 |
| `mac.menu.edit.nextElement` | Next Note | 次の音符 |
| `mac.menu.notes.pitch.a` … `.g` | Pitch A … Pitch G | 音高 A … 音高 G |
| `mac.menu.notes.duration.64th` … `.whole` | 64th Note, 32nd Note, 16th Note, Eighth Note, Quarter Note, Half Note, Whole Note | 64分音符, 32分音符, 16分音符, 8分音符, 4分音符, 2分音符, 全音符 |
| `mac.menu.notes.rest` | Rest | 休符 |
| `mac.menu.notes.dot` | Dot | 付点 |
| `mac.menu.notes.dot.double` | Double Dot | 複付点 |
| `mac.menu.notes.pitch.up` / `.down` | Up a Semitone / Down a Semitone | 半音上げる / 半音下げる |
| `mac.menu.notes.octave.up` / `.down` | Up an Octave / Down an Octave | オクターブ上げる / オクターブ下げる |
| `mac.menu.notes.accidental.doubleFlat` … `.none` | Double Flat, Flat, Natural, Sharp, Double Sharp, No Accidental | ダブルフラット, フラット, ナチュラル, シャープ, ダブルシャープ, 臨時記号なし |
| `mac.menu.notes.chord.add.a` … `.g` | Add A to Chord … | 和音に A を追加 … |
| `mac.menu.notes.chord.interval.2` … `.9` | Add 2nd Above … Add 9th Above | 上に2度を追加 … 上に9度を追加 |
| `mac.menu.notes.chord.removeNote` | Remove Note from Chord | 和音から音符を削除 |
| `mac.menu.notes.tie` | Tie | タイ |
| `mac.menu.notes.tiedNote` | Add Tied Note | タイでつないだ音符を追加 |
| `mac.menu.notes.tuplet.3` … `.9` | Triplet, Quadruplet, Quintuplet, Sextuplet, Septuplet, Octuplet, Nonuplet | 3連符 … 9連符 |
| `mac.menu.notes.tuplet.remove` | Remove Tuplet | 連符を解除 |
| `mac.menu.notes.delete` | Delete | 削除 |
| `mac.menu.notes.voice.1` … `.4` | Voice 1 … Voice 4 | 声部 1 … 声部 4 |
| `mac.menu.measures.append` | Add Measure | 小節を追加 |
| `mac.menu.measures.appendMany` | Add Measures… | 小節を複数追加… |
| `mac.menu.measures.insertBefore` | Insert Measure Before | 前に小節を挿入 |
| `mac.menu.measures.delete` | Delete Measure | 小節を削除 |
| `mac.menu.measures.keySignature` | Key Signature… | 調号… |
| `mac.menu.measures.timeSignature` | Time Signature… | 拍子… |
| `mac.menu.measures.rehearsalMark` | Rehearsal Mark… | リハーサルマーク… |
| `mac.menu.score.instruments` | Instruments… | 楽器… |
| `mac.menu.score.drumLayout` | Drum Pad Layout… | ドラムパッドの配置… |

Use the Editor package's existing translations (`Packages/Features/Editor/Sources/Editor/Resources/Localizable.xcstrings`
— `editor.duration.*`, `editor.measure.*`, `editor.instruments.title`, `editor.drum.layout.edit`) as the source for
ko / zh-Hans / zh-Hant wording where the same concept exists, so the two surfaces use one vocabulary.

- [ ] **Step 6: Test, build, launch**

```bash
xcodebuild test -project Folino.xcodeproj -scheme FolinoMac -destination 'platform=macOS' -skipPackagePluginValidation -only-testing:FolinoMacTests
```

Expected: 9 or 10 tests (per the optional fourth), all passed.

```bash
Scripts/build-macos-app.sh
```

Launch the built app (`open <path>` as in Task 13) and ask the user to run the QA sheet's Section A (Task 15 writes
it; the items are: click a note, type `c`, `5`, `.`, `↑`, `⌘Z`, `⇧⌘Z`, Space, open Measures ▸ Rehearsal Mark…, type a
letter in it, Esc, close and reopen the window, ⌘Z).

- [ ] **Step 7: Commit**

```bash
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/macos-editing-ui add App/Mac App/Resources/Localizable.xcstrings Tests/FolinoMacTests
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/macos-editing-ui commit -m "feat(macos): editing menus and the MuseScore key map from one command table"
```

---

### Task 15: Parity bookkeeping, spec revisions, the QA sheet (spec §7, §8, §10)

**Files:**
- Modify: `App/Mac/FolinoMacApp.swift:196-205` (the `PARITY(macos)` marker on the wizard's edit session)
- Modify: `Packages/Features/Reader/Sources/Reader/Screens/Vertical/VerticalZoomedSurface.swift:1-3`,
  `Screens/Horizontal/HorizontalZoomedSurface.swift:1`, `Screens/Paged/PagedZoomedSurface.swift:1`,
  `Screens/Vertical/VerticalScoreContainer.swift:5-8` (markers)
- Modify: `docs/superpowers/specs/2026-08-31-macos-app-design.md` §9 (the Ⅳ row)
- Create: `docs/superpowers/plans/2026-09-02-macos-edit-session-qa.md`

- [ ] **Step 1: Close the markers this slice implements, reword the ones it does not**

- `FolinoMacApp.swift` — delete the wizard-edit-session marker (lines 196–205): a score created from the wizard
  opens editable now like every other. In `openImportedScore`, keep consuming `consumePendingOpenInEditSession()`
  and add the comment `// Consumed and dropped: the Mac has no edit mode to start in — every score window is editable.`
- `VerticalZoomedSurface.swift`, `HorizontalZoomedSurface.swift`, `PagedZoomedSurface.swift` — each marker's "Ⅳ is
  where it arrives" / "the Mac's equivalent … without it" becomes: "The Mac sibling (`MacVerticalScoreSurface` /
  `MacHorizontalScoreStrip` / `MacPageScoreLayer`) carries the same selection tint, tap routing and caret. Not on
  the Mac, by design (`2026-09-02-macos-edit-session-design.md` §4.4): the floating pitch callout
  (`SelectionCalloutLayer`) — the keyboard is its replacement." Keep them as markers: the callout is a deliberate
  per-platform gap the ledger should show.
- `VerticalScoreContainer.swift:5-8` — drop "and the note-editing overlay in its zoomed subtree (Ⅳ)".

- [ ] **Step 2: Umbrella spec §9**

In `2026-08-31-macos-app-design.md`, replace the Ⅳ row of the sub-projects table with:

```markdown
| **Ⅳ** | **Mac editing UI** — four slices, see `2026-09-02-macos-edit-session-design.md`: **Ⅳa** the always-editable score window (menu index, MuseScore key map, one window per score); Ⅳb command registry and search, iPad menu bar, iPhone search floor; Ⅳc panels; Ⅳd consuming Ⅰ | Ⅲb; Ⅳc–Ⅳd consume Ⅰ incrementally. **Ⅱ is not a prerequisite for Ⅳa** — the Mac surfaces are `ScoreView`-based and hit-test through the shared `LayoutDocument.editingHitTest`. |
```

- [ ] **Step 3: The QA sheet**

`docs/superpowers/plans/2026-09-02-macos-edit-session-qa.md`:

```markdown
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

## Section B — the three display modes

12. View ▸ Display Mode ▸ Vertical / Horizontal / Page: in each, items 2–4 work, and the caret is drawn on the
    correct staff. In Page mode a click on the blank paper below a page's last system deselects rather than
    selecting something on the next page.

## Section C — drums and instruments

13. Open a score with a drum staff; click a note on it. The letters bound in the drum pad layout write drum notes;
    Notes ▸ Pitch items are disabled. Score ▸ Drum Pad Layout… opens.
14. Score ▸ Instruments…: add a part, reorder, toggle a staff's visibility. The score follows; hidden staves stay
    hidden while editing.

## Section D — the bench's premise, in the real app ★

15. With a note selected, focus the library window's search field (⌘O, click the field), type `a`. The letter
    lands in the search field; no note is written in the score window.
```

- [ ] **Step 4: Gates and commit**

```bash
Scripts/build-macos-packages.sh
```

```bash
Scripts/build-macos-app.sh
```

```bash
xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,id=513F3B9E-891E-44CB-9DD3-BFCF5EEE3394' -skipPackagePluginValidation build
```

```bash
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/macos-editing-ui add App/Mac Packages/Features/Reader/Sources/Reader/Screens docs/engineering/ios-android-parity.md docs/superpowers/specs/2026-08-31-macos-app-design.md docs/superpowers/plans/2026-09-02-macos-edit-session-qa.md
git -C /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/macos-editing-ui commit -m "docs(macos): parity markers, umbrella §9 and the Ⅳa QA sheet"
```

Then hand the QA sheet to the user. Section A items 1–11 are the acceptance of this plan; a failure is recorded in
the sheet next to its item and fixed in a follow-up commit on this branch before merge.
