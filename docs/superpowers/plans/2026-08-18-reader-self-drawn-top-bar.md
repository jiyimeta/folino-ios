# Reader Self-Drawn Top Bar Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Take the Reader's top chrome — and the editing chrome that shares it — out of the system navigation bar and into a view we draw, so a control can report where it is and the bar can occupy the status bar's space while editing.

**Architecture:** One `ReaderTopBar` view, attached with `safeAreaInset(edge: .top)`, owns the strip. It always occupies *status-bar height + control-row height*; while editing the status bar hides and the control row grows by exactly that height, so the total top inset never changes and a paged score's page breaks cannot move. The system navigation bar is hidden throughout. Every control is then in the Reader's own view tree, so coach marks anchor to real window frames instead of counting items in a UIKit hierarchy.

**Tech Stack:** Swift 6.3, SwiftUI, iOS 18 deployment target.

**Spec:** `docs/superpowers/specs/2026-08-18-reader-self-drawn-top-bar-design.md`

## Global Constraints

- Deployment target is **iOS 18.0**. Anything newer needs `if #available`.
- Strict layered SPM modules. Features never import Infrastructure, another Feature, or `swift-sheet-music`. The Reader and the Editor stay mutually unaware; the App composition root connects them by closure. See `docs/engineering/module-architecture.md`.
- Dependency injection is constructor-only.
- The user-facing brand name is lowercase `folino`. Localization keys follow `module.feature.thing`. The string catalogs carry exactly five locales — `en`, `ja`, `ko`, `zh-Hans`, `zh-Hant`. **There is no `es`.**
- New tests use Swift Testing (`@Suite`, `@Test`, `#expect`) — never XCTest.
- **`swift test` does not work in this repo.** Tests run only via `xcodebuild test -scheme <Name> -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation -parallel-testing-enabled NO`, from the package directory. Multi-product packages take a `-Package` suffix (`Infrastructure-Package`). The app builds from the repo root with `-scheme Folino`, and **`-scheme FolinoScreenshot` must also build.**
- **Always pass `-parallel-testing-enabled NO`** — this environment's test runner crashes under parallel testing and reports random unrelated failures. Re-run serially before believing any failure.
- **Run every `xcodebuild` in the foreground** with a raised tool-call timeout. Never background it.
- SwiftLint caps files at 400 lines. Comment paragraphs reflow at 120 columns. American English in prose, except where an Apple API spells it otherwise.
- A pre-commit hook runs SwiftFormat and `swiftlint --fix` over staged Swift files. **Never use `git add -p`** — stage whole files.

## Prior art you are expected to read

The Reader drew this chrome itself until `f3cdbd94` (2026-08-02). Read the old implementation before Task 2:

```bash
git show f3cdbd94^:Packages/Features/Reader/Sources/Reader/Screens/ReaderTopOverlay.swift
```

**Reuse its shapes:** the `ViewThatFits(in: .horizontal)` ladder of candidate rows, its `overlayButton(systemImage:label:action:)` helper, `.interactiveGlassCompat()`, the `PDFBadge`, and the leading affordance for the iPad split-view detail. It also documents one non-obvious rule that this plan keeps: **presentation modifiers (`.sheet`, `.popover`) are attached outside `ViewThatFits`**, because a candidate swap on rotation or a split-view resize would otherwise tear down an open sheet.

**Do not copy its height handling.** It exposed `nonisolated static let height: CGFloat = 52` and call sites subtracted it from the safe area; every one of them broke when the standard bar arrived, and `f3cdbd94`'s message records removing it. Task 1 replaces that constant with a contract.

---

## File Structure

**Reader — `Packages/Features/Reader/Sources/Reader/`**

| File | Responsibility |
| --- | --- |
| `Screens/ReaderTopBarLayout.swift` | Create. Pure height arithmetic — the contract, and the only thing tested about it. |
| `Screens/ReaderTopBar.swift` | Create. The strip: hosts either the Reader's controls or the injected editing row, applies the height contract and the glass. |
| `Screens/ReaderTopBarControls.swift` | Create. The Reader's own controls and the `ViewThatFits` ladder. |
| `Screens/ReaderToolbar.swift` | **Delete.** |
| `Screens/ReaderToolbarCollapse.swift` | **Delete.** |
| `Screens/ReaderRootScreen.swift` | Modify. Attach the strip, hide the nav bar, hide the status bar while editing, take the two new closures. |
| `Hints/ReaderBarItemLocator.swift` | **Delete.** |
| `Hints/ReaderFeatureHint.swift` | Modify. `ReaderBarSlot` and `barSlot` deleted. |
| `Hints/ReaderHintCoordinator.swift` | Modify. Bar-matching machinery deleted. |
| `Hints/ReaderHintBubble.swift` | Modify. `readerHintBarAnchor` deleted. |
| `Hints/ReaderHintWiring.swift` | Modify. The seam `onChange` carries a frame. |
| `ReaderEditingHost.swift` | Modify. `noteInputBarLeadingOrder` becomes `noteInputAnchorFrame`. |

**Editor — `Packages/Features/Editor/Sources/Editor/`**

| File | Responsibility |
| --- | --- |
| `Screens/EditorTopBarView.swift` | Create. The editing row as a view, with revert promoted out of the overflow. |
| `Screens/EditorChromeView+Toolbar.swift` | **Delete.** |
| `Screens/EditorChromeView+Revert.swift` | Modify. `overflowMenu` removed; the confirmation and alert stay. |

**Utility — `Packages/Utility/Sources/UtilityUI/`**

| File | Responsibility |
| --- | --- |
| `InteractivePopGestureEnabler.swift` | Create. Restores edge-swipe back when the navigation bar is hidden. |

**App**

| File | Responsibility |
| --- | --- |
| `AppShellView.swift` | Modify. Supplies `onToggleSidebar` and the editing-top-bar builder. |
| `EditableReaderScreen.swift` | Modify. Builds the editing row and reports the pad toggle's frame. |
| `FolinoScreenshot/Scenes/*.swift` | Modify as the compiler requires. |

---

## Task 1: The height contract

**Files:**
- Create: `Packages/Features/Reader/Sources/Reader/Screens/ReaderTopBarLayout.swift`
- Test: `Packages/Features/Reader/Tests/ReaderTests/ReaderTopBarLayoutTests.swift`

**Interfaces:**
- Produces: `enum ReaderTopBarLayout` with `static let baseControlRowHeight: CGFloat`, `static func controlRowHeight(statusBarHeight:isEditing:) -> CGFloat`, and `static func stripHeight(statusBarHeight:isEditing:) -> CGFloat`.

This is the invariant the whole design turns on, and nothing tests it today. It is a pure function precisely so it can be tested without a device.

- [ ] **Step 1: Write the failing test**

Create `Packages/Features/Reader/Tests/ReaderTests/ReaderTopBarLayoutTests.swift`:

```swift
@testable import Reader
import SwiftUI
import Testing

/// The strip's height is the one thing this whole design exists to keep constant: if the top inset changes when an
/// edit session starts, a paged score re-paginates under the user mid-edit.
@Suite("Reader top bar layout")
struct ReaderTopBarLayoutTests {
    /// Status-bar heights that actually ship: a pre-notch device, a notched device, and a Dynamic Island device.
    private static let statusBarHeights: [CGFloat] = [20, 44, 54, 59]

    @Test func `the strip is the same height whether or not an edit session is running`() {
        for height in Self.statusBarHeights {
            #expect(
                ReaderTopBarLayout.stripHeight(statusBarHeight: height, isEditing: false)
                    == ReaderTopBarLayout.stripHeight(statusBarHeight: height, isEditing: true),
            )
        }
    }

    @Test func `the control row absorbs exactly the status bar while editing`() {
        for height in Self.statusBarHeights {
            let resting = ReaderTopBarLayout.controlRowHeight(statusBarHeight: height, isEditing: false)
            let editing = ReaderTopBarLayout.controlRowHeight(statusBarHeight: height, isEditing: true)
            #expect(editing - resting == height)
        }
    }

    @Test func `the resting control row does not depend on the status bar`() {
        let heights = Self.statusBarHeights.map {
            ReaderTopBarLayout.controlRowHeight(statusBarHeight: $0, isEditing: false)
        }
        #expect(Set(heights).count == 1)
        #expect(heights[0] == ReaderTopBarLayout.baseControlRowHeight)
    }

    /// A device that reports no status bar at all (an iPad in some configurations) must not produce a negative or
    /// zero-height strip.
    @Test func `a zero status bar still leaves a full control row`() {
        #expect(ReaderTopBarLayout.stripHeight(statusBarHeight: 0, isEditing: false)
            == ReaderTopBarLayout.baseControlRowHeight)
        #expect(ReaderTopBarLayout.stripHeight(statusBarHeight: 0, isEditing: true)
            == ReaderTopBarLayout.baseControlRowHeight)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

From `Packages/Features/Reader`:

```
xcodebuild test -scheme Reader -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation -parallel-testing-enabled NO -only-testing:ReaderTests/ReaderTopBarLayoutTests
```

Expected: FAIL — `cannot find 'ReaderTopBarLayout' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Packages/Features/Reader/Sources/Reader/Screens/ReaderTopBarLayout.swift`:

```swift
import CoreGraphics

/// How tall the Reader's top strip is, and how that height is divided between the status bar and the control row.
///
/// The contract, and the reason this is a type of its own rather than three expressions inside a view: **the strip
/// occupies the same total height whether or not an edit session is running.** While editing, the status bar is
/// hidden and the control row grows by exactly the height the status bar gave up. The score's top inset therefore
/// never moves, which is what stops a paged score from re-paginating the moment the user starts editing.
///
/// The Reader used to draw this chrome itself and exposed a flat `height: CGFloat = 52` that call sites subtracted
/// from the safe area. Every one of those broke when the standard toolbar replaced it. This is the replacement:
/// callers ask for a height rather than knowing one.
enum ReaderTopBarLayout {
    /// The control row's own height, ignoring the status bar. One row of 44pt controls plus the breathing room the
    /// old overlay used above and below them.
    static let baseControlRowHeight: CGFloat = 52

    /// How tall the row of controls is drawn. While editing it also covers the space the status bar vacated, so the
    /// controls sit where the clock was — the shape Photos uses for its editing chrome.
    static func controlRowHeight(statusBarHeight: CGFloat, isEditing: Bool) -> CGFloat {
        baseControlRowHeight + (isEditing ? statusBarHeight : 0)
    }

    /// The whole strip, status bar included when it is showing. Constant across `isEditing` by construction — the two
    /// terms trade against each other.
    static func stripHeight(statusBarHeight: CGFloat, isEditing: Bool) -> CGFloat {
        let visibleStatusBar = isEditing ? 0 : statusBarHeight
        return visibleStatusBar + controlRowHeight(statusBarHeight: statusBarHeight, isEditing: isEditing)
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Same command as Step 2. Expected: PASS, 4 tests.

- [ ] **Step 5: Commit**

```bash
git add Packages/Features/Reader
git commit -m "feat(reader): state the top strip's height contract"
```

---

## Task 2: The strip, the Reader's controls, and the fold

**Files:**
- Create: `Packages/Features/Reader/Sources/Reader/Screens/ReaderTopBar.swift`
- Create: `Packages/Features/Reader/Sources/Reader/Screens/ReaderTopBarControls.swift`
- Delete: `Packages/Features/Reader/Sources/Reader/Screens/ReaderToolbar.swift`
- Delete: `Packages/Features/Reader/Sources/Reader/Screens/ReaderToolbarCollapse.swift`
- Delete: the `ReaderToolbarCollapse` breakpoint tests (find them with `grep -rln "ReaderToolbar" Packages/Features/Reader/Tests`)
- Modify: `Packages/Features/Reader/Sources/Reader/Screens/ReaderRootScreen.swift`

**Interfaces:**
- Consumes: `ReaderTopBarLayout` from Task 1.
- Produces: `struct ReaderTopBar<Content: View>: View` with `init(statusBarHeight: CGFloat, isEditing: Bool, @ViewBuilder content: () -> Content)`, and `struct ReaderTopBarControls: View` carrying the Reader's own buttons.

- [ ] **Step 1: Read the old implementation**

```bash
git show f3cdbd94^:Packages/Features/Reader/Sources/Reader/Screens/ReaderTopOverlay.swift
```

You are porting its `body`, its `row(collapsesScoreActions:)`, its `overlayButton` helper, its `loadedActions` / `pdfActions` split, and its `PDFBadge` usage. The buttons themselves — their glyphs, labels, actions, hint anchors, and the inspector popovers — come from the **current** `ReaderToolbar.swift`, which is the version that has been maintained since. Take behaviour from `ReaderToolbar`, layout from `ReaderTopOverlay`.

- [ ] **Step 2: Write the strip**

Create `Packages/Features/Reader/Sources/Reader/Screens/ReaderTopBar.swift`:

```swift
import SwiftUI
import UtilityUI

/// The Reader's top strip. Hosts whatever controls belong on screen right now — the Reader's own, or the editing row
/// the App injects — and owns the height both cases have to agree on.
///
/// The strip is attached with `safeAreaInset(edge: .top)` rather than floated in a `ZStack`, so the score's own safe
/// area accounts for it without any call site subtracting a constant.
struct ReaderTopBar<Content: View>: View {
    let statusBarHeight: CGFloat
    let isEditing: Bool
    @ViewBuilder let content: Content

    var body: some View {
        content
            .frame(
                height: ReaderTopBarLayout.controlRowHeight(
                    statusBarHeight: statusBarHeight,
                    isEditing: isEditing,
                ),
                alignment: .bottom,
            )
            .padding(.horizontal)
            // While editing the row reaches up into the space the status bar vacated; at rest it starts below it.
            .padding(.top, isEditing ? 0 : statusBarHeight)
            .frame(maxWidth: .infinity)
            .background(alignment: .top) { Color.clear }
            .ignoresSafeArea(edges: .top)
    }
}
```

- [ ] **Step 3: Write the Reader's controls with a four-rung fold**

Create `Packages/Features/Reader/Sources/Reader/Screens/ReaderTopBarControls.swift`. Port the buttons from `ReaderToolbar.swift` verbatim — same glyphs, same localization keys, same actions, same `readerHintBarAnchor` calls (Task 4 renames those) — and arrange them with `ViewThatFits`:

```swift
ViewThatFits(in: .horizontal) {
    row(collapse: .expanded)
    row(collapse: .scoreActions)
    row(collapse: .noteEditing)
    row(collapse: .annotation)
}
```

Keep the four rungs and their order — score info and share fold first, then note editing, then annotation, and the two inspectors never fold. That order is the priority statement `ReaderToolbarCollapse` made in arithmetic; it survives as the order of the candidates. Move the `Collapse` enum into this file, keeping only the enum: **delete `Metrics`, `collapse(availableWidth:hasLeadingAffordance:hasNoteEditing:)` and `trailingWidth(collapse:hasNoteEditing:)`.** `ViewThatFits` measures what the arithmetic was estimating.

**Attach `.sheet` and `.popover` outside the `ViewThatFits`**, as `ReaderTopOverlay` did — a candidate swap on rotation or a split-view resize must not tear down an open presentation.

- [ ] **Step 4: Attach the strip and hide the navigation bar**

In `ReaderRootScreen.swift`:

- read the status-bar height once with a `GeometryReader`-free proxy — `Color.clear.ignoresSafeArea()` inside `.background { }` reporting `safeAreaInsets.top` via `onGeometryChange`, which is the same technique the file already uses for chrome measurement;
- attach `.safeAreaInset(edge: .top) { ReaderTopBar(statusBarHeight:isEditing:) { … } }`;
- replace `.toolbar { readerToolbar }` with nothing, and add `.toolbarVisibility(.hidden, for: .navigationBar)`;
- delete `.toolbarRole(.editor)`, `.navigationBarBackButtonHidden(isEditing)` and `.toolbarColorScheme(.light, for: .navigationBar)` — all three configure a bar that is no longer shown;
- delete the window-width measurement that fed `ReaderToolbar.collapse(availableWidth:…)` and the `collapse` state it wrote.

Leave the `isCaptureMode` branch behaving as it does today: capture mode draws no chrome, so it renders no strip.

- [ ] **Step 5: Build and run the Reader suite**

From `Packages/Features/Reader`:

```
xcodebuild test -scheme Reader -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation -parallel-testing-enabled NO
```

Expected: PASS. Tests referencing `ReaderToolbar` must have been deleted in this task, not left failing.

- [ ] **Step 6: Commit**

```bash
git add Packages/Features/Reader
git commit -m "refactor(reader): draw the top chrome again instead of filling a toolbar"
```

---

## Task 3: Leading affordances — chevron, edge swipe, sidebar toggle

**Files:**
- Create: `Packages/Utility/Sources/UtilityUI/InteractivePopGestureEnabler.swift`
- Modify: `Packages/Features/Reader/Sources/Reader/Screens/ReaderTopBarControls.swift`
- Modify: `Packages/Features/Reader/Sources/Reader/Screens/ReaderRootScreen.swift`
- Modify: `App/AppShellView.swift`

**Interfaces:**
- Produces: `View.restoresInteractivePopGesture()` in `UtilityUI`; `ReaderRootScreen.init(…, onToggleSidebar: (@MainActor () -> Void)?)`.

- [ ] **Step 1: Write the gesture enabler**

Create `Packages/Utility/Sources/UtilityUI/InteractivePopGestureEnabler.swift`:

```swift
import SwiftUI
import UIKit

/// Restores the edge-swipe-back gesture on a screen that hides the navigation bar.
///
/// UIKit disables `interactivePopGestureRecognizer` when a view controller has no back button — reasonable, since
/// without one there would be no visible affordance for what the swipe does. A screen that draws its own back
/// control has the affordance and wants the gesture, so this reinstates it by supplying a delegate that allows the
/// gesture whenever there is something to pop.
///
/// No private API: it walks up from a hosted controller to its `navigationController` and sets a delegate. The
/// delegate is retained by this coordinator, because `UIGestureRecognizer.delegate` is weak.
public struct InteractivePopGestureEnabler: UIViewControllerRepresentable {
    public init() {}

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public func makeUIViewController(context: Context) -> UIViewController {
        let controller = UIViewController()
        controller.view.isUserInteractionEnabled = false
        context.coordinator.install(from: controller)
        return controller
    }

    public func updateUIViewController(_ controller: UIViewController, context: Context) {
        context.coordinator.install(from: controller)
    }

    public final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        private weak var navigationController: UINavigationController?

        func install(from controller: UIViewController) {
            // Deferred: the controller has no parent chain on the first layout pass.
            DispatchQueue.main.async { [weak self, weak controller] in
                guard let self, let navigation = controller?.navigationController else { return }
                navigationController = navigation
                navigation.interactivePopGestureRecognizer?.delegate = self
                navigation.interactivePopGestureRecognizer?.isEnabled = true
            }
        }

        public func gestureRecognizerShouldBegin(_: UIGestureRecognizer) -> Bool {
            (navigationController?.viewControllers.count ?? 0) > 1
        }

        /// Lets the swipe coexist with the score's own pan/zoom gestures rather than cancelling them outright.
        public func gestureRecognizer(
            _: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith _: UIGestureRecognizer,
        ) -> Bool {
            false
        }
    }
}

extension View {
    /// Attach to a screen that hides the navigation bar but still wants edge-swipe back.
    public func restoresInteractivePopGesture() -> some View {
        background(InteractivePopGestureEnabler().frame(width: 0, height: 0))
    }
}
```

- [ ] **Step 2: Draw the leading affordance**

In `ReaderTopBarControls.swift`, port the old overlay's leading button, with one change the spec requires: **the iPad sidebar toggle is shown whenever a toggle action was supplied, and flips the sidebar in both directions.** The old overlay showed it only while the sidebar was hidden, which is why removing the system toggle once left no way to collapse an open sidebar.

```swift
if let onToggleSidebar {
    topBarButton(
        systemImage: "sidebar.leading",
        label: Text("reader.toolbar.toggleSidebar", bundle: .module),
        action: onToggleSidebar,
    )
} else if let onBack {
    topBarButton(
        systemImage: "chevron.backward",
        label: Text("reader.toolbar.back", bundle: .module),
        action: onBack,
    )
}
```

The old `reader.toolbar.showSidebar` key names one direction only. Add `reader.toolbar.toggleSidebar` in all five locales — English `Show or Hide Sidebar`, Japanese `サイドバーの表示切り替え` — and supply `ko` / `zh-Hans` / `zh-Hant` matching the register of the neighbouring strings. Remove `reader.toolbar.showSidebar` if nothing else uses it.

- [ ] **Step 3: Wire the closures**

Add `onToggleSidebar: (@MainActor () -> Void)?` to `ReaderRootScreen.init`, defaulting to `nil`, and pass it into `ReaderTopBarControls`. Attach `.restoresInteractivePopGesture()` to the Reader's root.

In `AppShellView.swift`, supply it only in the regular layout, flipping `columnVisibility`:

```swift
onToggleSidebar: {
    columnVisibility = columnVisibility == .detailOnly ? .doubleColumn : .detailOnly
}
```

Leave it `nil` in the compact stack, where the chevron belongs instead.

- [ ] **Step 4: Build both app targets**

From the repo root:

```
xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation build
```

```
xcodebuild -project Folino.xcodeproj -scheme FolinoScreenshot -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation build
```

Both must succeed. `FolinoScreenshot` is a separate target that also constructs Reader screens; the `Folino` scheme does not build it, and a previous change left it broken for days because only the app scheme was checked.

- [ ] **Step 5: Commit**

```bash
git add Packages App
git commit -m "feat(reader): draw the back and sidebar affordances, keep edge-swipe back"
```

---

## Task 4: Coach marks anchor to frames

**Files:**
- Delete: `Packages/Features/Reader/Sources/Reader/Hints/ReaderBarItemLocator.swift`
- Delete: its tests (`grep -rln "ReaderBarItemLocator" Packages/Features/Reader/Tests`)
- Modify: `Hints/ReaderFeatureHint.swift`, `Hints/ReaderHintCoordinator.swift`, `Hints/ReaderHintBubble.swift`, `Hints/ReaderHintWiring.swift`
- Modify: `ReaderEditingHost.swift`
- Modify: `Screens/ReaderTopBarControls.swift`

**Interfaces:**
- Produces: `ReaderEditingHost.noteInputAnchorFrame: CGRect?` replacing `noteInputBarLeadingOrder: Int?`.

- [ ] **Step 1: Replace the bar anchors with real ones**

In `ReaderTopBarControls.swift`, change every `.readerHintBarAnchor(.someTarget)` to `.readerHintAnchor(.someTarget)`. The controls are now in the Reader's own view tree, so the existing modifier — which reports a window frame through `UtilityUI.onWindowFrameChange` — works for them exactly as it already does for the transport.

- [ ] **Step 2: Delete the ordinal machinery**

- `Hints/ReaderBarItemLocator.swift` and its tests: delete outright.
- `Hints/ReaderFeatureHint.swift`: delete `enum ReaderBarSlot` and `ReaderHintTarget.barSlot`.
- `Hints/ReaderHintCoordinator.swift`: delete `barTargets`, `registerBarTarget`, `refreshBarAnchors`, `assign`, `setReaderRegion`, `readerRegion`, and `scheduleBarRefresh` with its 0/120/320/700/1400 ms resampling. Keep `anchors`, `setAnchor`, `clearAnchor` and everything that reads them.
- `Hints/ReaderHintBubble.swift`: delete `readerHintBarAnchor` and `ReaderHintBarAnchorModifier`.
- Anywhere `setReaderRegion` was called, delete the call.

- [ ] **Step 3: Change the seam to carry a frame**

In `ReaderEditingHost.swift`, replace the `noteInputBarLeadingOrder` declaration:

```swift
    /// Where the chrome's note-input (pad open/close) button is on screen, in WINDOW coordinates, or `nil` when the
    /// chrome isn't up. Written by the App from the Editor's chrome, read by the Reader's coach-mark overlay — which
    /// has to point at a control it does not draw.
    ///
    /// A frame rather than a position in a sequence: the chrome is rendered inside the Reader's own view tree now, so
    /// both sides share a window coordinate space and the button can simply say where it is. It could not, while the
    /// button was hosted by the navigation bar.
    public var noteInputAnchorFrame: CGRect?
```

In `Hints/ReaderHintWiring.swift`, replace the ordinal `onChange`:

```swift
            .onChange(of: editingHost?.noteInputAnchorFrame, initial: true) { _, frame in
                if let frame {
                    hints.setAnchor(frame, for: .noteInputToggle)
                } else {
                    hints.clearAnchor(for: .noteInputToggle)
                }
            }
```

- [ ] **Step 4: Run the Reader suite**

From `Packages/Features/Reader`:

```
xcodebuild test -scheme Reader -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation -parallel-testing-enabled NO
```

Expected: PASS. The deleted locator tests must be gone, not failing.

- [ ] **Step 5: Commit**

```bash
git add Packages/Features/Reader
git commit -m "refactor(reader): anchor coach marks to frames instead of counting bar items"
```

---

## Task 5: The editing strip

**Files:**
- Create: `Packages/Features/Editor/Sources/Editor/Screens/EditorTopBarView.swift`
- Delete: `Packages/Features/Editor/Sources/Editor/Screens/EditorChromeView+Toolbar.swift`
- Modify: `Packages/Features/Editor/Sources/Editor/Screens/EditorChromeView+Revert.swift`
- Modify: `Packages/Features/Editor/Sources/Editor/Resources/Localizable.xcstrings`
- Modify: `Packages/Features/Reader/Sources/Reader/Screens/ReaderRootScreen.swift`
- Modify: `App/EditableReaderScreen.swift`, `App/AppShellView.swift`

**Interfaces:**
- Consumes: `ReaderTopBar` from Task 2, `noteInputAnchorFrame` from Task 4.
- Produces: `ReaderRootScreen.init(…, editingTopBar: ((ReaderEditingChromeContext) -> AnyView)?)`.

- [ ] **Step 1: Turn the editing toolbar into a view**

Create `EditorTopBarView.swift`, porting `EditorChromeView+Toolbar.swift`'s `voiceMenu`, `padToggleButton` and the undo / redo / 完了 buttons into a plain `HStack`. Two changes:

- **Revert is a top-level trailing button, and the `⋯` menu is gone.** It held exactly one item and existed only because a sixth item risked the standard bar folding undo, redo and 完了 into a system menu of its own choosing. `ViewThatFits` removes that risk. Keep the confirmation dialog and the failure alert from `EditorChromeView+Revert.swift` exactly as they are; only the control that raises the dialog moves.
- **The pad toggle reports its frame.** Replace `onNoteInputBarOrderChange(1)` / `onNoteInputBarOrderChange(nil)` with `.onWindowFrameChange { onNoteInputAnchorFrameChange($0) }` on the button, and `nil` it on disappear.

Delete the now-unused `editor.chrome.more` key from the catalog, and delete `overflowMenu` from `EditorChromeView+Revert.swift`.

Delete `EditorChromeView+Toolbar.swift` and the `.toolbar { editingToolbar }` attachment that referenced it.

- [ ] **Step 2: Give the Reader a slot for the editing row**

Add to `ReaderRootScreen.init`:

```swift
    /// The editing row the App injects into the top strip while a session runs. `nil` in a Reader with no editing seam.
    let editingTopBar: ((ReaderEditingChromeContext) -> AnyView)?
```

In the `safeAreaInset` added in Task 2, render the injected row instead of `ReaderTopBarControls` while `editingHost?.isEditing == true` and a builder was supplied.

- [ ] **Step 3: Hide the status bar while editing**

On the Reader's root: `.statusBarHidden(editingHost?.isEditing == true)`.

`statusBarHidden(_:)` is the iOS API and is current on iOS 18; the `ToolbarPlacement.statusBar` visibility form is iOS 27 only and is not used here.

- [ ] **Step 4: Wire it in the App**

In `EditableReaderScreen.swift`, supply `editingTopBar` returning `AnyView(EditorTopBarView(viewModel: editorViewModel, hasMusicalAnnotations: …, onDone: …))`, and wire the frame callback to `editingHost.noteInputAnchorFrame`. Pass the builder through `AppShellView` to `ReaderRootScreen`.

- [ ] **Step 5: Run the suites and build both targets**

From `Packages/Features/Editor` and `Packages/Features/Reader` respectively:

```
xcodebuild test -scheme Editor -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation -parallel-testing-enabled NO
```

```
xcodebuild test -scheme Reader -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation -parallel-testing-enabled NO
```

Then both builds from the repo root, `-scheme Folino` and `-scheme FolinoScreenshot`.

- [ ] **Step 6: Commit**

```bash
git add Packages App
git commit -m "feat(editor): put the editing row in the reader's strip, revert at the top"
```

---

## Task 6: Full verification and the device checklist

**Files:**
- Modify: `docs/superpowers/specs/2026-08-18-reader-self-drawn-top-bar-design.md` if anything drifted.

- [ ] **Step 1: Run every suite**

Each in the foreground, `-parallel-testing-enabled NO`, from its package directory: `-scheme Domain`, `-scheme Infrastructure-Package`, `-scheme Editor`, `-scheme Reader`, `-scheme Library`, `-scheme ScoreUI`. Then `-scheme Folino` and `-scheme FolinoScreenshot` builds from the repo root. Report the actual numbers.

- [ ] **Step 2: Reconcile the spec**

If the implementation diverged from the spec anywhere, correct the spec — a document that describes code that does not exist is worse than none. Do not rewrite its history; add to it.

- [ ] **Step 3: Write the device checklist**

Compile, into your report, a checklist a human runs on a physical device. It must cover at minimum:

1. **The invariant.** Open a paged score, note where a page breaks, enter note editing, confirm the break is in the same place, leave editing, confirm it again. This is the whole point of the design and no automated test reaches it.
2. **Edge-swipe back** from the Reader on an iPhone, and that the chevron works too.
3. **iPad sidebar toggle in both directions** — collapse an open sidebar and reopen it.
4. **The fold** at 375pt, 393pt, 402pt and 440pt widths, plus iPad Slide Over: which buttons give way, in the documented order, with nothing overflowing off-screen.
5. **Coach marks** point at their buttons — every bar hint, plus the note-input pad hint during editing.
6. **The editing strip** occupies the status bar's space, with revert visible at the trailing end and no `⋯`.
7. **Rotation and Dynamic Island** — the strip's height stays correct across a rotation on a notched device and on one with an island.

- [ ] **Step 4: Commit**

```bash
git add docs
git commit -m "docs: reconcile the top-bar spec with the implementation"
```

---

## Self-review notes

- **Spec coverage.** The strip and its height contract → Tasks 1, 2. The fold via `ViewThatFits` → Task 2. Navigation bar hidden and appearance ours → Task 2. Leading affordances and edge swipe → Task 3. Anchoring, deletions and the seam → Task 4. The editing strip, status-bar absorption, revert promoted → Task 5. Testing → Tasks 1, 2 and 6. Prior-art reuse → Task 2 Step 1. The 52pt warning → Task 1's implementation comment.
- **The one spec line with no task** is the "Risks" section, which is narrative rather than work; its three items are covered by Task 6's checklist.
- **Naming consistency:** `ReaderTopBarLayout.baseControlRowHeight` / `.controlRowHeight(statusBarHeight:isEditing:)` / `.stripHeight(statusBarHeight:isEditing:)`, `ReaderTopBar`, `ReaderTopBarControls`, `restoresInteractivePopGesture()`, `noteInputAnchorFrame`, `editingTopBar`, `onToggleSidebar`.
- **Deliberately not planned:** an Android parity marker. The Android app draws its own Compose chrome and shares no code with this.
