# Reader Self-Drawn Top Bar Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Take the Reader's top chrome — and the editing chrome that shares it — out of the system navigation bar and into a view we draw, so a control can report where it is and the bar can occupy the status bar's space while editing.

**Architecture:** The strip has two tiers. A **cutout tier** is drawn inside the top safe area, flanking the display cutout, and contributes nothing to the score's inset because the system reserves that band regardless — it exists only where a 44pt control fits, which is a notched or Dynamic Island iPhone in portrait. A **control tier**, attached with `safeAreaInset(edge: .top)`, is the only thing that adds inset, and its height never varies. So the inset the strip contributes is constant and a paged score's page breaks cannot move. The system navigation bar is hidden throughout, and every control is then in the Reader's own view tree, so coach marks anchor to real window frames instead of counting items in a UIKit hierarchy.

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

## Known transitional states

Two things are broken *between* tasks, by design. Neither is a regression to chase.

- **Bar coach marks are dead from Task 2 until Task 4.** Task 2 hides the navigation bar, so `ReaderBarItemLocator` finds nothing to measure; Task 4 is what replaces it. The build is fine throughout.
- **The editing chrome is unusable from Task 2 until Task 5.** Task 2 hides the bar that `EditorChromeView`'s `.toolbar` was filling, so the editing controls — 完了 included — have nowhere to draw. Task 5 gives them the strip. If you open an edit session on a build from Tasks 2-4 you will not be able to leave it.

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
- Produces: `enum ReaderTopBarLayout` with `static let controlTierHeight: CGFloat`, `static let minimumCutoutTierHeight: CGFloat`, `static func hasCutoutTier(topSafeAreaInset:) -> Bool`, and `static func contributedInset(topSafeAreaInset:isEditing:) -> CGFloat`.

This is the invariant the whole design turns on, and nothing tests it today. It is a pure function precisely so it can be tested without a device.

**Read the spec's "The strip" section before writing this.** The contract is *not* that some total height stays constant — it is that **the inset this strip contributes is the control tier's height and nothing else**, independent of the device's own safe area, of whether a cutout tier is drawn, and of whether an edit session is running. The cutout tier lives inside the safe area the system already reserves, so it contributes nothing by construction.

- [ ] **Step 1: Write the failing test**

Create `Packages/Features/Reader/Tests/ReaderTests/ReaderTopBarLayoutTests.swift`:

```swift
@testable import Reader
import SwiftUI
import Testing

/// What the strip contributes to the score's top inset is the one thing this design exists to keep constant: if it
/// changes when an edit session starts, a paged score re-paginates under the user mid-edit.
///
/// Note what is asserted and what is not. These test the inset the strip CONTRIBUTES, never a total that includes the
/// system's own safe area. An earlier draft of this design asserted the total and would have passed while the real
/// inset moved, because it assumed hiding the status bar shrinks the safe area — which it does not do on any device
/// with a display cutout.
@Suite("Reader top bar layout")
struct ReaderTopBarLayoutTests {
    /// Every top safe-area inset that ships: landscape, an SE, an iPad, and the cutout devices.
    private static let safeAreaInsets: [CGFloat] = [0, 20, 24, 44, 47, 54, 59]

    @Test func `the contributed inset is the control tier and nothing else`() {
        for inset in Self.safeAreaInsets {
            for isEditing in [false, true] {
                #expect(
                    ReaderTopBarLayout.contributedInset(topSafeAreaInset: inset, isEditing: isEditing)
                        == ReaderTopBarLayout.controlTierHeight,
                )
            }
        }
    }

    @Test func `the contributed inset does not move when an edit session starts`() {
        for inset in Self.safeAreaInsets {
            #expect(
                ReaderTopBarLayout.contributedInset(topSafeAreaInset: inset, isEditing: false)
                    == ReaderTopBarLayout.contributedInset(topSafeAreaInset: inset, isEditing: true),
            )
        }
    }

    @Test func `a cutout tier exists only where a control fits in the reserved band`() {
        #expect(ReaderTopBarLayout.hasCutoutTier(topSafeAreaInset: 0) == false)
        #expect(ReaderTopBarLayout.hasCutoutTier(topSafeAreaInset: 20) == false)
        #expect(ReaderTopBarLayout.hasCutoutTier(topSafeAreaInset: 24) == false)
        #expect(ReaderTopBarLayout.hasCutoutTier(topSafeAreaInset: 47))
        #expect(ReaderTopBarLayout.hasCutoutTier(topSafeAreaInset: 59))
    }

    @Test func `the cutout tier boundary is the minimum tappable height`() {
        let boundary = ReaderTopBarLayout.minimumCutoutTierHeight
        #expect(ReaderTopBarLayout.hasCutoutTier(topSafeAreaInset: boundary))
        #expect(ReaderTopBarLayout.hasCutoutTier(topSafeAreaInset: boundary - 0.5) == false)
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

/// How the Reader's top strip divides into tiers, and what it costs the score.
///
/// The strip has two tiers and only one of them is paid for:
///
/// * the **cutout tier** is drawn inside the top safe area, flanking the display cutout, and adds nothing to the
///   score's inset — the system reserves that band whether or not anything is in it. It exists only where a tappable
///   control fits, which means a notched or Dynamic Island iPhone in portrait;
/// * the **control tier** sits below the safe area and is the only thing that adds inset.
///
/// The contract, and the reason this is a type rather than a few expressions inside a view: **the inset this strip
/// contributes is the control tier's height and nothing else** — independent of the device's safe area, of whether a
/// cutout tier is drawn, and of whether an edit session is running. That is what stops a paged score from
/// re-paginating when the user starts editing.
///
/// The contract is deliberately NOT "some total height stays constant". An earlier draft said that, on the premise
/// that hiding the status bar reclaims its height and the control tier can absorb it. It does not: on a device with a
/// display cutout the top inset belongs to the cutout, and the system keeps reserving it whether the status bar is
/// showing or not. That identity would have held only on an SE.
///
/// The Reader used to draw this chrome itself and exposed a flat `height: CGFloat = 52` that call sites subtracted
/// from the safe area. Every one of those broke when the standard toolbar replaced it. Callers ask here rather than
/// knowing a number.
enum ReaderTopBarLayout {
    /// The control tier's height: one row of 44pt controls plus the breathing room the old overlay used around them.
    static let controlTierHeight: CGFloat = 52

    /// The least top safe-area inset that can host a control. Below this the reserved band is a sliver — an SE's
    /// 20pt, an iPad's 24pt, nothing at all in landscape — and no cutout tier is drawn.
    static let minimumCutoutTierHeight: CGFloat = 44

    /// Whether this device, in this orientation, reserves enough at the top to put controls there.
    static func hasCutoutTier(topSafeAreaInset: CGFloat) -> Bool {
        topSafeAreaInset >= minimumCutoutTierHeight
    }

    /// What the strip adds to the score's top inset. Constant by construction: the cutout tier is drawn inside space
    /// the system already reserved, so it is not part of this.
    ///
    /// The parameters are here because callers naturally have them and because the test asserts the result ignores
    /// them — a signature that took nothing would make the invariant unfalsifiable.
    static func contributedInset(topSafeAreaInset _: CGFloat, isEditing _: Bool) -> CGFloat {
        controlTierHeight
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
- Delete: `Packages/Features/Reader/Sources/Reader/Screens/ReaderToolbar+PDF.swift`
- Delete: `Packages/Features/Reader/Sources/Reader/Screens/ReaderToolbarCollapse.swift`
- Delete: `Packages/Features/Reader/Tests/ReaderTests/ReaderToolbarCollapseTests.swift`
- Modify: `Packages/Features/Reader/Sources/Reader/Screens/ReaderRootScreen.swift`

**`ReaderToolbar+PDF.swift` is easy to miss and will break the build if you do.** It is an `extension ReaderToolbar` holding the PDF badge's menu — "show the score" and "read the PDF again" — plus the `displaySource == .originalPDF` branch that renders a reduced row. None of it exists in the old overlay, which had a PDF badge that only opened a notice, so **port it forward from the current file rather than looking for it in the prior art.** `PDFBadge` itself lives in `ReaderToolbar.swift` and also needs moving.

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
/// The control tier is attached with `safeAreaInset(edge: .top)`, so the score's safe area accounts for it without
/// any call site subtracting a constant. **It carries no `padding(.top:)` and no `ignoresSafeArea`.** The system's
/// own top inset is already below the strip's content; adding the safe-area height back as padding would count it
/// twice, and `ignoresSafeArea` on a fixed-height child shifts it rather than extending it.
struct ReaderTopBar<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(.horizontal)
            .frame(maxWidth: .infinity)
            .frame(height: ReaderTopBarLayout.controlTierHeight)
    }
}
```

The cutout tier is **not** part of this view, because anything inside a `safeAreaInset` contributes inset by definition. It is a separate overlay on the Reader's root:

```swift
/// The tier drawn inside the top safe area, flanking the display cutout. An overlay rather than a `safeAreaInset`
/// precisely so it contributes nothing: the band it occupies is reserved by the system either way.
///
/// The two clusters are pinned to their own edges and nothing is placed in the middle — the cutout's width varies by
/// model and is not ours to know.
struct ReaderCutoutTier<Leading: View, Trailing: View>: View {
    let topSafeAreaInset: CGFloat
    @ViewBuilder let leading: Leading
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack {
            leading
            Spacer(minLength: 0)
            trailing
        }
        .padding(.horizontal)
        .frame(height: topSafeAreaInset, alignment: .center)
        .frame(maxWidth: .infinity, alignment: .top)
    }
}
```

Attach it with `.overlay(alignment: .top) { … }.ignoresSafeArea(edges: .top)` **on the overlay only**, and render it only when `ReaderTopBarLayout.hasCutoutTier(topSafeAreaInset:)`.

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

**Two details are what make the fold work at all. Do not change them.** `ViewThatFits` measures each candidate's *ideal* size, so the row's trailing `Spacer` must be `Spacer(minLength: 0)` — a greedy spacer would make every candidate report that it fits, and the fold would silently never trigger. And every button keeps a fixed frame, so what a candidate needs is a function of how many buttons it has. The old overlay's `row(collapsesScoreActions:)` says both in its own comments; carry them across.

Name the shared button helper `topBarButton(systemImage:label:action:)`. Task 3 calls it by that name.

- [ ] **Step 4: Attach the strip and hide the navigation bar**

In `ReaderRootScreen.swift`:

- read the status-bar height once with a `GeometryReader`-free proxy — `Color.clear.ignoresSafeArea()` inside `.background { }` reporting `safeAreaInsets.top` via `onGeometryChange`, which is the same technique the file already uses for chrome measurement;
- attach `.safeAreaInset(edge: .top) { ReaderTopBar(statusBarHeight:isEditing:) { … } }`;
- replace `.toolbar { readerToolbar }` with nothing, and add `.toolbarVisibility(.hidden, for: .navigationBar)`;
- delete `.toolbarRole(.editor)`, `.navigationBarBackButtonHidden(isEditing)`, `.toolbarColorScheme(.light, for: .navigationBar)` and `.floatingToolbarBackgroundCompat()` — all four configure a bar that is no longer shown. Leave the `floatingToolbarBackgroundCompat` *definition* in `UtilityUI`; other screens use it;
- delete the window-width measurement that fed `ReaderToolbar.collapse(availableWidth:…)` and the `collapse` state it wrote.

Fix the stale comments that now describe a world that no longer exists: `ReaderInspectorDestinations.swift:10` (references `ReaderToolbar.Metrics` / `.Collapse`), `ScoreContentView.swift:13`, and `ReaderHintBubble.swift`'s opening paragraph about toolbar items. `ReaderToolbar.Collapse` has no users outside this package — the apparent hits in `ReaderHintCopy` / `ReaderFeatureHint` / `ReaderHintWiring` are the unrelated `transportCollapse` case.

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

    public static func dismantleUIViewController(_: UIViewController, coordinator: Coordinator) {
        coordinator.restore()
    }

    public final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        private weak var navigationController: UINavigationController?
        /// The navigation controller's own delegate, which enforces the standard guards (no pop mid-transition, none
        /// at the root). Put back on teardown — leaving ours installed after this screen is gone would strip those
        /// guards from every other screen in the same stack.
        private weak var previousDelegate: UIGestureRecognizerDelegate?

        func install(from controller: UIViewController) {
            // Deferred: the controller has no parent chain on the first layout pass.
            DispatchQueue.main.async { [weak self, weak controller] in
                guard let self, let navigation = controller?.navigationController else { return }
                navigationController = navigation
                guard let recognizer = navigation.interactivePopGestureRecognizer else { return }
                if recognizer.delegate !== self { previousDelegate = recognizer.delegate }
                recognizer.delegate = self
                recognizer.isEnabled = true
            }
        }

        func restore() {
            guard let recognizer = navigationController?.interactivePopGestureRecognizer,
                  recognizer.delegate === self
            else { return }
            recognizer.delegate = previousDelegate
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

**Both closures have to be added — neither exists today.** `f3cdbd94` removed the overlay's `onBack` / `leadingIsSidebarToggle` when the system took the leading edge over. Add to `ReaderRootScreen.init`, both defaulting to `nil` so the six `FolinoScreenshot` scenes that construct a Reader keep compiling:

```swift
    /// Pops back to the library. Supplied only by the compact stack; `nil` elsewhere, which hides the chevron.
    let onBack: (@MainActor () -> Void)?
    /// Reveals or collapses the library sidebar. Supplied only in the regular split view; `nil` elsewhere.
    let onToggleSidebar: (@MainActor () -> Void)?
```

Do **not** call `@Environment(\.dismiss)` directly from the Reader instead: the `FolinoScreenshot` scenes host the Reader as a stack root, and a chevron would appear there with nothing to pop. `AppShellView.makeReader` serves both layouts from one function, so it decides which of the two to pass.

**Both localization keys are gone and must be re-added.** `reader.toolbar.back` and `reader.toolbar.showSidebar` were deleted along with the overlay in `f3cdbd94`; the current catalog has neither. Add `reader.toolbar.back` (English `Back`, Japanese `戻る`) and `reader.toolbar.toggleSidebar` (English `Show or Hide Sidebar`, Japanese `サイドバーの表示切り替え`), each in all five locales, supplying `ko` / `zh-Hans` / `zh-Hant` in the register of their neighbours. There is nothing to remove.

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
- Delete: `Packages/Features/Reader/Tests/ReaderTests/ReaderBarItemLocatorTests.swift`
- Modify: `Hints/ReaderFeatureHint.swift`, `Hints/ReaderHintCoordinator.swift`, `Hints/ReaderHintBubble.swift`, `Hints/ReaderHintWiring.swift`
- Modify: `ReaderEditingHost.swift`
- Modify: `Screens/ReaderTopBarControls.swift`
- Modify: `App/EditableReaderScreen.swift`

**Interfaces:**
- Produces: `ReaderEditingHost.noteInputAnchorFrame: CGRect?` replacing `noteInputBarLeadingOrder: Int?`.

- [ ] **Step 1: Replace the bar anchors with real ones**

In `ReaderTopBarControls.swift`, change every `.readerHintBarAnchor(.someTarget)` to `.readerHintAnchor(.someTarget)`. The controls are now in the Reader's own view tree, so the existing modifier — which reports a window frame through `UtilityUI.onWindowFrameChange` — works for them exactly as it already does for the transport.

- [ ] **Step 2: Delete the ordinal machinery**

- `Hints/ReaderBarItemLocator.swift` and its tests: delete outright.
- `Hints/ReaderFeatureHint.swift`: delete `enum ReaderBarSlot` and `ReaderHintTarget.barSlot`.
- `Hints/ReaderHintCoordinator.swift`: delete `barTargets`, `registerBarTarget`, `refreshBarAnchors`, `assign`, `setReaderRegion`, `readerRegion`, `barRefreshTask`, and `scheduleBarRefresh` with its 0/120/320/700/1400 ms resampling. Keep `anchors`, `setAnchor`, `clearAnchor` and everything that reads them.
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

- [ ] **Step 4: Keep the App compiling**

Renaming the seam breaks `App/EditableReaderScreen.swift`, which writes `editingHost.noteInputBarLeadingOrder` from the chrome's `onNoteInputBarOrderChange` callback. The Reader package alone still builds, so its test scheme will not catch this — the App target goes red at this commit unless you fix it here.

The Editor's chrome does not report a frame until Task 5, so stub the App side for now: pass `onNoteInputBarOrderChange: { _ in }` and leave `noteInputAnchorFrame` unwritten. Task 5 replaces the callback and wires the frame.

- [ ] **Step 5: Run the Reader suite and build the app**

From `Packages/Features/Reader`:

```
xcodebuild test -scheme Reader -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation -parallel-testing-enabled NO
```

Then from the repo root:

```
xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation build
```

Expected: PASS / BUILD SUCCEEDED. The deleted locator tests must be gone, not failing.

- [ ] **Step 6: Commit**

```bash
git add Packages/Features/Reader App
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

- **Two tiers, matching the Reader's.** Where `ReaderTopBarLayout.hasCutoutTier(topSafeAreaInset:)` is true, 完了 goes to the cutout tier's leading end and revert to its trailing end — the two controls that end the session, in the two spots Photos uses. The voice picker and pad toggle lead the control tier; undo and redo trail it. Where there is no cutout tier, 完了 and revert join the control tier, making it five controls wide.
- **The control tier folds.** Give it the same `ViewThatFits` ladder as the Reader's row, with the same `Spacer(minLength: 0)` and fixed button frames. Five controls in an iPad Slide Over or a 320pt column will not fit, and nothing about being the editing row exempts it. Fold order: revert first, then 完了, into an overflow menu — they are the two that have a home in the cutout tier on other devices.
- **Revert is a top-level control and the `⋯` menu is gone** on any width that fits it. It held exactly one item and existed only because a sixth item risked the standard bar folding undo, redo and 完了 into a system menu of its own choosing.
- **The confirmation dialog and the failure alert move with the button.** They cannot stay in `EditorChromeView+Revert.swift`: `isConfirmingRevert` is `@State` on `EditorChromeView`, and the revert button now lives in a different view in a different part of the tree. Move `isConfirmingRevert`, the `.confirmationDialog`, the `.alert` bound to `revertError`, and the `revertMessage` composition into `EditorTopBarView`. Anchoring the dialog to the button that raises it is also what makes it read correctly as a popover on iPad.
- **The pad toggle reports its frame.** Replace `onNoteInputBarOrderChange(1)` / `onNoteInputBarOrderChange(nil)` with `.onWindowFrameChange { onNoteInputAnchorFrameChange($0) }` on the button, and `nil` it on disappear. Remove the `onNoteInputBarOrderChange` parameter from `EditorChromeView.init` and its argument at the `EditableReaderScreen` call site.

Delete the now-unused `editor.chrome.more` key from the catalog, and delete `overflowMenu` from `EditorChromeView+Revert.swift`.

Delete `EditorChromeView+Toolbar.swift` and the `.toolbar { editingToolbar }` attachment that referenced it.

- [ ] **Step 2: Give the Reader a slot for the editing row**

Add to `ReaderRootScreen.init`:

```swift
    /// The editing row the App injects into the top strip while a session runs. `nil` in a Reader with no editing seam.
    let editingTopBar: ((ReaderEditingChromeContext) -> AnyView)?
```

In the `safeAreaInset` added in Task 2, render the injected row instead of `ReaderTopBarControls` while `editingHost?.isEditing == true` and a builder was supplied.

- [ ] **Step 3: Hide the status bar while the cutout tier is in use**

On the Reader's root:

```swift
.statusBarHidden(editingHost?.isEditing == true && ReaderTopBarLayout.hasCutoutTier(topSafeAreaInset: topSafeAreaInset))
```

Only then — the clock and the battery sit in exactly the two spots the tier wants, and on a device with no tier there is nothing to clear and no reason to take the clock away.

**Hiding it changes no height.** It does not shrink the safe area on a cutout device; the inset is the cutout's. Do not add or subtract anything on the strength of this call.

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

1. **The invariant, on a cutout device.** Open a paged score, note where a page breaks, enter note editing, confirm the break is in the same place, leave editing, confirm it again. This is the whole point of the design and no automated test reaches it.
2. **The invariant, on a device with no cutout tier** — an SE or an iPad, where the layout is one tier and the status bar never hides. Same walk.
3. **Rotate mid-session on a cutout device.** Landscape has no cutout tier, so the layout changes tiers underneath an open edit session. The page break may move (the width changed), but the chrome must not end up doubled, clipped, or behind the clock.
4. **Edge-swipe back** from the Reader on an iPhone, and that the chevron works too. Then push and pop another screen in the same stack to confirm the standard guards came back — the gesture delegate is restored on teardown, and a regression here is silent.
5. **iPad sidebar toggle in both directions** — collapse an open sidebar and reopen it.
6. **The fold** at 375pt, 393pt, 402pt and 440pt widths, plus iPad Slide Over: which buttons give way, in the documented order, with nothing overflowing off-screen. **Do the editing row too**, which is the one carrying five controls where there is no cutout tier.
7. **Coach marks** point at their buttons — every bar hint, plus the note-input pad hint during editing.
8. **The cutout tier** shows 完了 and revert flanking the island, with the clock and battery gone, and nothing colliding with the cutout on the widest and narrowest models you have.
9. **Screenshots.** Re-run `Scripts/capture-screenshots.sh --devices iphone --locales en --scenes NoteEditing` and look at the result — that scene draws the editing chrome, and the screenshot harness reports a zero safe area, so it exercises the no-cutout-tier branch.

- [ ] **Step 4: Commit**

```bash
git add docs
git commit -m "docs: reconcile the top-bar spec with the implementation"
```

---

## Self-review notes

- **Spec coverage.** The strip and its height contract → Tasks 1, 2. The fold via `ViewThatFits` → Task 2. Navigation bar hidden and appearance ours → Task 2. Leading affordances and edge swipe → Task 3. Anchoring, deletions and the seam → Task 4. The editing strip, status-bar absorption, revert promoted → Task 5. Testing → Tasks 1, 2 and 6. Prior-art reuse → Task 2 Step 1. The 52pt warning → Task 1's implementation comment.
- **The one spec line with no task** is the "Risks" section, which is narrative rather than work; its three items are covered by Task 6's checklist.
- **Naming consistency:** `ReaderTopBarLayout.controlTierHeight` / `.minimumCutoutTierHeight` / `.hasCutoutTier(topSafeAreaInset:)` / `.contributedInset(topSafeAreaInset:isEditing:)`, `ReaderTopBar`, `ReaderCutoutTier`, `ReaderTopBarControls`, `topBarButton(systemImage:label:action:)`, `restoresInteractivePopGesture()`, `noteInputAnchorFrame`, `editingTopBar`, `onBack`, `onToggleSidebar`.
- **Deliberately not planned:** an Android parity marker. The Android app draws its own Compose chrome and shares no code with this.
