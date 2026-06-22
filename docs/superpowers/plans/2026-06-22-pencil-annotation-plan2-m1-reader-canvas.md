# Pencil Annotation — Plan 2 / Milestone 1: Reader Canvas (Vertical) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Get a hands-on, manually-verifiable build: draw with Apple Pencil on the score in the Reader's **Vertical** mode, with finger scroll/zoom coexisting, ink persisting across reopen — using a degenerate whole-canvas persistence (NO musical anchoring yet; that is Milestone 2).

**Architecture:** Milestone 1 of Plan 2 (see `docs/superpowers/specs/2026-06-22-ipad-pencil-annotation-design.md`). Realizes canvas-hosting decision **A1**: a non-scrolling `PKCanvasView` is a SwiftUI child of the Vertical surface's already-transformed `scoreSurface` `ZStack`, so it rides the existing scroll/zoom transform — no second implementation of the pinch/scroll/zoom math. Persistence reuses Plan 1's `AnnotationStore` with a single sentinel-anchored `DrawingAnchor` carrying the whole canvas `PKDrawing` in document coordinates. M2 replaces that with per-stroke musical anchoring (needs upstream swift-sheet-music primitives) and adds Horizontal/Paged.

**Tech Stack:** Swift 6.3, SwiftUI + UIKit `UIViewRepresentable`, PencilKit (`PKCanvasView`, `PKToolPicker`, `PKCanvasViewDelegate`), Swift Testing, the Plan 1 `AnnotationStore` / `LiveAnnotationStore`.

## Global Constraints

- **Platform:** Swift 6.3, iOS 26+. Apple Pencil is iPad-only; the rest works on iPhone (best-effort QA for M1; primary target is iPad).
- **A1, not A2:** the canvas MUST be a child of `scoreSurface(document:)`'s `ZStack` (beneath the ancestor `.scaleEffect`/`.offset`/`.frame` chain) so it inherits the transform. NEVER re-derive zoom/scroll/offset in the canvas layer.
- **Layer boundaries:** all PencilKit code lives in `Packages/Features/Reader` (a Feature may import UIKit/PencilKit). The Reader reaches persistence ONLY through the Domain `AnnotationStore` protocol — never `import Persistence` in the Reader. The App composition root wires the concrete `LiveAnnotationStore`.
- **Degenerate persistence (M1 only):** one `AnnotationLayer` per score holding ONE `DrawingAnchor` whose `anchor` is an all-zero sentinel `MusicalAnchor` and whose `encodedDrawing` is `canvas.drawing.dataRepresentation()` (document coordinates). No per-stroke anchoring, no reflow in M1. Dev-only data, so M2's switch to per-stroke anchoring needs no migration.
- **Persistence cadence:** load on score open; save debounced ~0.5 s after `canvasViewDrawingDidChange`; delete the layer when the drawing becomes empty; flush pending save before an in-place score swap (`advance`) and on Reader teardown.
- **Package build gate:** `xcodebuild build -scheme Reader -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation`, run from the worktree's `Packages/Features/Reader` dir. `swift build`/`swift test` do NOT work here.
- **Manual verification is the user's job:** Claude does not launch the simulator for end-to-end Pencil verification. Claude's gate is a green package build; the user runs the clean `Folino` app build on iPad and checks the §Manual Verification checklist. On-device outcomes drive the documented fallbacks.
- **Whole-file staging only.** Pre-commit hook (SwiftFormat + `swiftlint --fix`) may rewrite staged files and fail the commit; re-stage and re-commit until clean.
- **Comments reflow at 120 cols.** Every commit message ends with: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>` (second `-m`).
- **Worktree:** `/Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/pencil-annotation-plan1`, branch `worktree-pencil-annotation-plan1` (continues Plan 1). All git via `git -C <worktree>`; all edits under the worktree path.

---

### Task 1: DI — thread `annotationStore` from the composition root into the Reader view model

Wire the Plan 1 `LiveAnnotationStore` through the existing DI chain so the Reader view model holds an `any AnnotationStore`. No behavior yet — this task only makes the dependency available and keeps the app building.

**Files:**
- Modify: `App/AppBootstrap.swift` (construct + expose `LiveAnnotationStore`)
- Modify: `App/AppShellView.swift` (guard `bootstrap.annotationStore`; `ReadyShell` stored prop + init param; `makeReader` forwards it)
- Modify: `Packages/Features/Reader/Sources/Reader/ReaderRootScreen.swift` (init param → forward to VM)
- Modify: `Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift` (init param + stored property)

**Interfaces:**
- Consumes: `LiveAnnotationStore(database:)` (Persistence, Plan 1); `any AnnotationStore` (Domain, Plan 1).
- Produces: `ReaderViewModel` holds `@ObservationIgnored private let annotationStore: any AnnotationStore`.

- [ ] **Step 1: AppBootstrap — construct and expose the store**

In `App/AppBootstrap.swift`, add a stored property next to `private(set) var repository: LiveScoreLibraryRepository?` (~line 27):

```swift
    private(set) var annotationStore: LiveAnnotationStore?
```

In `start()`, immediately after `let database = try AppDatabase(databaseURL: AppPaths.databaseURL)` (~line 61), add:

```swift
        let annotationStore = LiveAnnotationStore(database: database)
```

And where the bootstrap assigns its stored services (next to `self.database = database`, ~line 83), add:

```swift
        self.annotationStore = annotationStore
```

(`import Domain` and `import Persistence` are already present.)

- [ ] **Step 2: AppShellView — guard, thread through `ReadyShell`, forward in `makeReader`**

In `App/AppShellView.swift`, the `body` guard that unwraps bootstrap services (~lines 25-30) adds `annotationStore`:

```swift
        guard
            let repository = bootstrap.repository,
            // …existing unwraps…
            let annotationStore = bootstrap.annotationStore
        else { /* existing not-ready branch */ }
```

Pass it into the `ReadyShell(...)` construction (~lines 32-41): add `annotationStore: annotationStore`.

In `ReadyShell`, add a stored property next to `let repository: any ScoreLibraryRepository` (~line 102):

```swift
        let annotationStore: any AnnotationStore
```

Add the matching init parameter `annotationStore: any AnnotationStore` to `ReadyShell.init` (~lines 129-168) and assign `self.annotationStore = annotationStore`.

In `makeReader` (~lines 368-387), forward it into the `ReaderRootScreen(...)` call:

```swift
            annotationStore: annotationStore,
```

(`import Domain` already present.)

- [ ] **Step 3: ReaderRootScreen — accept and forward to the VM**

In `Packages/Features/Reader/Sources/Reader/ReaderRootScreen.swift`, add to `init` (~lines 64-96) the parameter `annotationStore: any AnnotationStore` (place it after `metadataReader`, before `scoresDirectory`, to mirror the App call site). Forward it into the `ReaderViewModel(...)` seed (~lines 80-93):

```swift
                annotationStore: annotationStore,
```

(`import Domain` already present.)

- [ ] **Step 4: ReaderViewModel — accept and store**

In `Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift`, add to `init` (~lines 85-124) the parameter `annotationStore: any AnnotationStore` (after `metadataReader`, before `scoresDirectory`). Add the stored property next to the existing `@ObservationIgnored private let repository` (~line 74):

```swift
    @ObservationIgnored private let annotationStore: any AnnotationStore
```

Assign it in the init body: `self.annotationStore = annotationStore`. (`import Domain` already present.)

- [ ] **Step 5: Build the app-level graph**

Because this spans App + Reader, build the Reader package (the unit the change is largest in) and confirm it compiles:

Run (from `Packages/Features/Reader/`):
```
xcodebuild build -scheme Reader -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation
```
Expected: BUILD SUCCEEDED. (The App target itself is built by the user's clean app build; the package build proves the Reader-side signatures compile.)

- [ ] **Step 6: Commit**

```
git -C <worktree> add App/AppBootstrap.swift App/AppShellView.swift Packages/Features/Reader/Sources/Reader/ReaderRootScreen.swift Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift
git -C <worktree> commit -m "feat(reader): inject AnnotationStore through the Reader DI chain" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: View model — degenerate annotation load/save (debounced), unit-tested

Add the VM-side persistence: an observable property holding the current drawing's `Data`, a load on score open, a debounced save on change, delete-when-empty, and a flush before in-place score swaps / teardown. This logic is unit-testable with a fake `AnnotationStore`; the canvas (Task 3) is its UI counterpart.

**Files:**
- Modify: `Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift`
- Test: `Packages/Features/Reader/Tests/ReaderTests/AnnotationPersistenceTests.swift` (create; confirm the exact test dir name from an existing Reader test file's location)

**Interfaces:**
- Consumes: `annotationStore` (Task 1); `Domain.AnnotationLayer`, `DrawingAnchor`, `MusicalAnchor`, `ScoreItemID`.
- Produces on `ReaderViewModel`:
  - `private(set) var annotationDrawingData: Data?` — observable; the canvas seeds itself from this on load.
  - `func annotationDrawingDidChange(_ data: Data, isEmpty: Bool)` — called by the canvas coordinator; debounced-persists.
  - `func loadAnnotations() async` — called from `load()`.
  - `func flushPendingAnnotationSave() async` — called before `advance` swaps the score and on teardown.
  - sentinel: `static func makeSentinelAnchor() -> MusicalAnchor` returning all-zero.

- [ ] **Step 1: Write the failing persistence test**

First confirm the Reader test target path/name (look for an existing file, e.g. `Packages/Features/Reader/Tests/ReaderTests/*.swift`; use that directory and `@testable import Reader`). Create `Packages/Features/Reader/Tests/ReaderTests/AnnotationPersistenceTests.swift`:

```swift
import Domain
import Foundation
@testable import Reader
import Testing

private actor FakeAnnotationStore: AnnotationStore {
    private(set) var layers: [ScoreItemID: AnnotationLayer] = [:]
    private(set) var saveCount = 0
    private(set) var deleteCount = 0

    func annotationLayer(forScoreItem id: ScoreItemID) async throws -> AnnotationLayer? { layers[id] }
    func saveAnnotationLayer(_ layer: AnnotationLayer) async throws {
        saveCount += 1
        layers[layer.scoreItemID] = layer
    }
    func deleteAnnotationLayer(forScoreItem id: ScoreItemID) async throws {
        deleteCount += 1
        layers.removeValue(forKey: id)
    }
}

@MainActor
struct AnnotationPersistenceTests {
    @Test func `loads persisted drawing data into the observable property`() async throws {
        let store = FakeAnnotationStore()
        let scoreID = ScoreItemID()
        let data = Data([0x01, 0x02, 0x03])
        try await store.saveAnnotationLayer(
            AnnotationLayer(
                scoreItemID: scoreID,
                drawings: [DrawingAnchor(anchor: ReaderViewModel.makeSentinelAnchor(), encodedDrawing: data)],
                textBoxes: [],
                updatedAt: Date(timeIntervalSince1970: 0),
            ),
        )
        let vm = ReaderViewModel.makeForAnnotationTest(scoreID: scoreID, annotationStore: store)
        await vm.loadAnnotations()
        #expect(vm.annotationDrawingData == data)
    }

    @Test func `debounced change persists one layer with the drawing data`() async throws {
        let store = FakeAnnotationStore()
        let scoreID = ScoreItemID()
        let vm = ReaderViewModel.makeForAnnotationTest(scoreID: scoreID, annotationStore: store)
        let data = Data([0xAA, 0xBB])
        vm.annotationDrawingDidChange(data, isEmpty: false)
        await vm.flushPendingAnnotationSave()
        let saved = try await store.annotationLayer(forScoreItem: scoreID)
        #expect(saved?.drawings.first?.encodedDrawing == data)
        #expect(await store.saveCount == 1)
    }

    @Test func `empty drawing deletes the layer`() async throws {
        let store = FakeAnnotationStore()
        let scoreID = ScoreItemID()
        try await store.saveAnnotationLayer(
            AnnotationLayer(
                scoreItemID: scoreID,
                drawings: [DrawingAnchor(anchor: ReaderViewModel.makeSentinelAnchor(), encodedDrawing: Data([0x01]))],
                textBoxes: [],
                updatedAt: Date(timeIntervalSince1970: 0),
            ),
        )
        let vm = ReaderViewModel.makeForAnnotationTest(scoreID: scoreID, annotationStore: store)
        vm.annotationDrawingDidChange(Data(), isEmpty: true)
        await vm.flushPendingAnnotationSave()
        let after = try await store.annotationLayer(forScoreItem: scoreID)
        #expect(after == nil)
        #expect(await store.deleteCount == 1)
    }
}
```

NOTE: `ReaderViewModel.makeForAnnotationTest(scoreID:annotationStore:)` is a test-only factory you add in Step 3 (the production `init` needs many collaborators; a minimal factory keeps the test focused). If the Reader test target already has fakes/factories for `ReaderViewModel`, reuse those instead and adapt the test.

- [ ] **Step 2: Run the test — verify it fails**

Run (from `Packages/Features/Reader/`):
```
xcodebuild test -scheme Reader -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation -only-testing:ReaderTests/AnnotationPersistenceTests
```
Expected: BUILD FAILURE — `annotationDrawingData`, `annotationDrawingDidChange`, `flushPendingAnnotationSave`, `loadAnnotations`, `makeSentinelAnchor`, `makeForAnnotationTest` are undefined. (If the `-only-testing` filter runs 0 tests in this scheme, the missing symbols still fail the build — that is the RED.)

- [ ] **Step 3: Implement the VM persistence**

In `ReaderViewModel.swift`:

Add observable + scratch state (near the other stored properties):

```swift
    /// The persisted annotation drawing for the current score, in document coordinates (M1 degenerate storage — the
    /// whole canvas as one blob; M2 replaces this with per-stroke musical anchoring). The canvas seeds itself from this.
    private(set) var annotationDrawingData: Data?

    @ObservationIgnored private var annotationSaveTask: Task<Void, Never>?
    @ObservationIgnored private var pendingAnnotationData: Data?
    @ObservationIgnored private var pendingAnnotationIsEmpty = false
```

Add the sentinel + load + change + flush:

```swift
    /// All-zero anchor used for M1's whole-canvas blob. Carries no musical meaning; M2 anchors per stroke.
    static func makeSentinelAnchor() -> MusicalAnchor {
        MusicalAnchor(
            measureIndex: 0, tickInMeasure: 0, partIndex: 0,
            staffIndexInPart: 0, dxSp: 0, verticalOffsetSp: 0,
        )
    }

    func loadAnnotations() async {
        let layer = try? await annotationStore.annotationLayer(forScoreItem: scoreItem.id)
        annotationDrawingData = layer?.drawings.first?.encodedDrawing
    }

    /// Called by the canvas coordinator on every drawing change. Debounces a save ~0.5 s; an empty drawing deletes the
    /// layer instead of storing an empty blob.
    func annotationDrawingDidChange(_ data: Data, isEmpty: Bool) {
        pendingAnnotationData = data
        pendingAnnotationIsEmpty = isEmpty
        annotationSaveTask?.cancel()
        let scoreID = scoreItem.id
        annotationSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.5))
            if Task.isCancelled { return }
            await self?.persistPendingAnnotation(scoreID: scoreID)
        }
    }

    /// Writes (or deletes) the pending drawing immediately. Safe to call when nothing is pending.
    func flushPendingAnnotationSave() async {
        annotationSaveTask?.cancel()
        annotationSaveTask = nil
        await persistPendingAnnotation(scoreID: scoreItem.id)
    }

    private func persistPendingAnnotation(scoreID: ScoreItemID) async {
        guard let data = pendingAnnotationData else { return }
        pendingAnnotationData = nil
        if pendingAnnotationIsEmpty {
            try? await annotationStore.deleteAnnotationLayer(forScoreItem: scoreID)
            return
        }
        let layer = AnnotationLayer(
            scoreItemID: scoreID,
            drawings: [DrawingAnchor(anchor: Self.makeSentinelAnchor(), encodedDrawing: data)],
            textBoxes: [],
            updatedAt: Date(),
        )
        try? await annotationStore.saveAnnotationLayer(layer)
    }
```

Call `await loadAnnotations()` inside `load()` right after `loadState = .loaded(score)` (~line 265). In `advance(to:autoPlay:)` (~lines 331-350), call `await flushPendingAnnotationSave()` BEFORE `scoreItem = newItem` (~line 335) so any pending save keys against the old score; after the swap, `load()` re-invokes `loadAnnotations()` for the new score, and reset `annotationDrawingData = nil` before the new load so stale ink does not flash.

Add the test-only factory (guarded so it is obviously test support) producing a VM with Noop collaborators and the given store + a `ScoreItem` whose `id == scoreID`:

```swift
    #if DEBUG
    static func makeForAnnotationTest(scoreID: ScoreItemID, annotationStore: any AnnotationStore) -> ReaderViewModel {
        // Minimal VM for unit-testing annotation persistence in isolation. Uses Noop collaborators.
        let item = ScoreItem(
            id: scoreID, title: "test", composer: nil, instrumentationSummary: nil,
            localFileName: "t.mid", contentHash: "h", sizeBytes: 0, lengthBeats: 0,
            defaultTempoBpm: 120, primaryKey: nil, addedAt: Date(timeIntervalSince1970: 0),
            lastOpenedAt: nil, tagIDs: [], isFavorite: false,
        )
        return ReaderViewModel(
            scoreItem: item,
            repository: <the Reader test suite's existing fake repository>,
            gateway: <the Reader test suite's existing fake gateway>,
            scoresDirectory: URL(fileURLWithPath: "/dev/null"),
            annotationStore: annotationStore,
        )
    }
    #endif
```

NOTE: fill the `<…>` with the Reader test target's existing fakes for `ScoreLibraryRepository` / `ScoreFileGateway` (find them in `Packages/Features/Reader/Tests/ReaderTests/`). If no fakes exist, this factory is the wrong shape — instead construct the VM in the test from the real `init` with the test target's existing helpers, and drop the factory. Confirm the exact `ScoreItem.init` signature against `Packages/Domain/Sources/Domain/Models/ScoreItem.swift` (the `id:` first parameter exists — used by `ScoreItemRecord.toDomain`).

- [ ] **Step 4: Run the test — verify green**

Run (from `Packages/Features/Reader/`):
```
xcodebuild test -scheme Reader -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation -only-testing:ReaderTests/AnnotationPersistenceTests
```
Expected: PASS (3 tests). If the filter runs 0 tests, re-run without `-only-testing` and confirm `AnnotationPersistenceTests` passes in the full Reader suite.

- [ ] **Step 5: Commit**

```
git -C <worktree> add Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift Packages/Features/Reader/Tests/ReaderTests/AnnotationPersistenceTests.swift
git -C <worktree> commit -m "feat(reader): degenerate annotation persistence (load + debounced save) in the view model" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: `AnnotationCanvasView` (PencilKit) + insertion into the Vertical surface

Create the `PKCanvasView` representable (canvas + coordinator + tool picker + input router) and insert it into `VerticalZoomedSurface.scoreSurface` so it rides the existing transform. This is the build-gated, on-device-verified core of M1.

**Files:**
- Create: `Packages/Features/Reader/Sources/Reader/Screens/Vertical/AnnotationCanvasView.swift`
- Modify: `Packages/Features/Reader/Sources/Reader/Screens/Vertical/VerticalZoomedSurface.swift` (insert the canvas child; pass drawing data + change callback)

**Interfaces:**
- Consumes: `ReaderViewModel.annotationDrawingData` (seed) and `annotationDrawingDidChange(_:isEmpty:)` (callback) from Task 2.
- Produces: `struct AnnotationCanvasView: UIViewRepresentable` with `init(documentSize: CGSize, drawingData: Data?, isPencilPreferred: Bool, onChange: @escaping (Data, Bool) -> Void)`.

- [ ] **Step 1: Create the canvas representable**

Create `Packages/Features/Reader/Sources/Reader/Screens/Vertical/AnnotationCanvasView.swift`:

```swift
import PencilKit
import SwiftUI

/// A1 annotation canvas: a non-scrolling `PKCanvasView` sized to the score document, placed as a child of the Reader's
/// already-transformed `scoreSurface` so it rides the existing scroll/zoom transform (it owns NO scroll/zoom of its
/// own). The host `ScoreScrollHost` owns pan/zoom; this canvas's own scroll gestures are disabled so finger touches
/// reach the host. Pencil draws under `.pencilOnly`; with no Pencil, one finger draws under `.anyInput` and two-finger
/// gestures fall through to the host.
struct AnnotationCanvasView: UIViewRepresentable {
    let documentSize: CGSize
    let drawingData: Data?
    /// True when an Apple Pencil is the preferred input (iPad w/ Pencil) → pencil draws, finger navigates.
    let isPencilPreferred: Bool
    /// (drawingData, isEmpty) on every change.
    let onChange: (Data, Bool) -> Void

    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.isScrollEnabled = false
        // The host (ScoreScrollHost) owns scroll/zoom. Disable the canvas's own scroll gestures so finger touches are
        // never swallowed here and instead reach the host's pan/pinch. (Primary arbitration approach; see plan §Manual
        // Verification for the on-device check and fallbacks.)
        canvas.panGestureRecognizer.isEnabled = false
        canvas.pinchGestureRecognizer.isEnabled = false
        canvas.drawingPolicy = isPencilPreferred ? .pencilOnly : .anyInput
        canvas.delegate = context.coordinator
        if let drawingData, let drawing = try? PKDrawing(data: drawingData) {
            canvas.drawing = drawing
            context.coordinator.lastLoadedData = drawingData
        }
        context.coordinator.canvas = canvas
        return canvas
    }

    func updateUIView(_ canvas: PKCanvasView, context: Context) {
        canvas.frame = CGRect(origin: .zero, size: documentSize)
        canvas.drawingPolicy = isPencilPreferred ? .pencilOnly : .anyInput
        // Seed/replace the drawing only when the persisted blob actually changed (e.g. a score swap loaded new ink),
        // never echo our own in-progress edits back onto the canvas.
        if drawingData != context.coordinator.lastLoadedData {
            context.coordinator.lastLoadedData = drawingData
            let drawing = drawingData.flatMap { try? PKDrawing(data: $0) } ?? PKDrawing()
            if canvas.drawing.dataRepresentation() != drawing.dataRepresentation() {
                canvas.drawing = drawing
            }
        }
        context.coordinator.showToolPickerIfPossible()
    }

    func makeCoordinator() -> Coordinator { Coordinator(onChange: onChange) }

    static func dismantleUIView(_ canvas: PKCanvasView, coordinator: Coordinator) {
        coordinator.hideToolPicker()
    }

    final class Coordinator: NSObject, PKCanvasViewDelegate {
        let onChange: (Data, Bool) -> Void
        weak var canvas: PKCanvasView?
        var lastLoadedData: Data?
        private var toolPicker: PKToolPicker?

        init(onChange: @escaping (Data, Bool) -> Void) { self.onChange = onChange }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            let data = canvasView.drawing.dataRepresentation()
            lastLoadedData = data // our own edit is now the source of truth; don't let updateUIView overwrite it
            onChange(data, canvasView.drawing.strokes.isEmpty)
        }

        /// Show the standard tool picker once the canvas is in a window and can become first responder.
        func showToolPickerIfPossible() {
            guard let canvas, canvas.window != nil else { return }
            let picker = toolPicker ?? PKToolPicker()
            toolPicker = picker
            picker.setVisible(true, forFirstResponder: canvas)
            picker.addObserver(canvas)
            canvas.becomeFirstResponder()
        }

        func hideToolPicker() {
            guard let canvas else { return }
            toolPicker?.setVisible(false, forFirstResponder: canvas)
            toolPicker?.removeObserver(canvas)
            toolPicker = nil
        }
    }
}
```

- [ ] **Step 2: Insert the canvas into `VerticalZoomedSurface.scoreSurface`**

In `VerticalZoomedSurface.swift`, inside `scoreSurface(document:)` (the `ZStack`, ~lines 57-74), add the canvas as a sibling AFTER the `ScoreView { … }.coordinateSpace(…).gesture(…).sensoryFeedback(…)` block (after ~line 64) and BEFORE the `if viewModel.repeatModel.mode == .abLoop {` block (~line 66):

```swift
        AnnotationCanvasView(
            documentSize: doc.size,
            drawingData: viewModel.annotationDrawingData,
            isPencilPreferred: UIDevice.current.userInterfaceIdiom == .pad,
            onChange: { data, isEmpty in viewModel.annotationDrawingDidChange(data, isEmpty: isEmpty) },
        )
        .frame(width: doc.size.width, height: doc.size.height, alignment: .topLeading)
        .allowsHitTesting(viewModel.isAnnotating)
```

Add an observable gate on the VM so annotation input is only live when the user wants it (otherwise tap-to-seek / navigation own all touches). In `ReaderViewModel.swift` add:

```swift
    /// When true, the annotation canvas accepts input (Pencil/finger draws). When false, the canvas is inert and all
    /// touches go to navigation + tap-to-seek. Toggled from the Reader toolbar.
    var isAnnotating = false
```

(M1: default `false`. A toolbar toggle to flip it is part of Step 3. `isPencilPreferred` is a coarse idiom check for M1; M2 can refine via real `UIPencilInteraction` pairing state.)

- [ ] **Step 3: Add a minimal toolbar toggle to enter/leave annotation mode**

Add a button to the Reader's existing top overlay/toolbar (find the control cluster in `Packages/Features/Reader/Sources/Reader/Screens/ReaderTopOverlay.swift` and follow its existing button style) that toggles `viewModel.isAnnotating`. Use an SF Symbol (`pencil.tip.crop.circle` when off, `pencil.tip.crop.circle.fill` when on) and a localized accessibility label following the project's `module.feature.thing` key scheme (add the string to the Reader catalog). Keep it minimal — this is the entry point for manual verification.

- [ ] **Step 4: Build the Reader package — verify it compiles**

Run (from `Packages/Features/Reader/`):
```
xcodebuild build -scheme Reader -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation
```
Expected: BUILD SUCCEEDED. (Behavioral correctness — drawing, gesture coexistence, ink fidelity, tool picker — is verified by the user on a clean app build per §Manual Verification, not here.)

- [ ] **Step 5: Run the Reader test suite — confirm no regression**

Run (from `Packages/Features/Reader/`):
```
xcodebuild test -scheme Reader -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation
```
Expected: PASS (existing Reader tests + Task 2's `AnnotationPersistenceTests`).

- [ ] **Step 6: Commit**

```
git -C <worktree> add Packages/Features/Reader/Sources/Reader/Screens/Vertical/AnnotationCanvasView.swift Packages/Features/Reader/Sources/Reader/Screens/Vertical/VerticalZoomedSurface.swift Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift Packages/Features/Reader/Sources/Reader/Screens/ReaderTopOverlay.swift
git -C <worktree> commit -m "feat(reader): A1 PencilKit annotation canvas in the Vertical surface (M1, degenerate persistence)" -m "Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Manual Verification (user, on a clean iPad build)

After the package builds green, the user runs a clean `Folino` app build and checks, in Vertical mode:

1. **Enter annotation mode** (toolbar toggle) → the `PKToolPicker` appears.
2. **Pencil draws** on the score; lifting the pencil keeps the ink. **One finger scrolls** and **two fingers pinch-zoom** while in annotation mode (Pencil path).
3. **No-Pencil device / finger:** one finger draws, two fingers scroll/zoom (Photos/Freeform behavior).
4. **Ink fidelity under zoom:** pinch-zoom in; ink stays crisp (not blurry); a stroke drawn at high zoom sits at the right place when zoomed back out.
5. **Persistence:** close the score, reopen → the ink is back. Erase everything → reopen → no ink (layer deleted).
6. **Leaving annotation mode** → tap-to-seek and navigation work normally; the canvas is inert.

### Fallback playbook (apply per the on-device outcome)

- **Finger touches don't reach the host (no scroll/zoom while drawing enabled):** confirmed primary already disables the canvas's `panGestureRecognizer`/`pinchGestureRecognizer`. If touches are still swallowed, make the Coordinator the delegate of the canvas's drawing gesture and return `true` from `shouldRecognizeSimultaneouslyWith` for the host's recognizers; as a last resort, gate the canvas behind an explicit draw-mode where navigation is paused (spec §6 decision "C").
- **Ink blurry at zoom > 1, or strokes land at the wrong document coordinate:** switch to the §5.3 spec fallback — drive `canvas.zoomScale = effectiveZoom` and lift the canvas OUT of the ancestor `.scaleEffect(zoom,…)` (place it in `VerticalZoomedSurface.body` receiving `zoom` as a parameter), so PencilKit re-rasterizes at its own scale. `effectiveZoom` is `VerticalZoomedSurface.effectiveZoom(for:)`. Keep `commitPinch`/offset single-source.
- **Tool picker doesn't appear:** verify `canvas.becomeFirstResponder()` returns true once in-window; if the hosting-controller responder chain blocks it, move the picker wiring to a `PKCanvasView` subclass's `didMoveToWindow`.

Record outcomes; if a fallback is applied, commit it as a follow-on and re-verify before M1 is considered done.

---

## Self-Review

**Spec coverage (vs M1 scope):** A1 canvas as scoreSurface child (Task 3) ✓; input router pencil/finger (Task 3) ✓; PKToolPicker (Task 3) ✓; degenerate document-coord persistence + debounced save + delete-on-empty (Task 2) ✓; DI wiring (Task 1) ✓; Vertical only ✓; spikes as manual-verification acceptance + documented fallbacks (§Manual Verification) ✓. Out of M1: musical anchoring/reflow, Horizontal/Paged, upstream ssm (all M2).

**Placeholder scan:** the only `<…>` placeholders are in Task 2 Step 3's test-only factory, explicitly conditioned on the Reader test target's existing fakes — the implementer resolves them against real files (and the task says to drop the factory if the fakes don't fit). The gesture/fidelity unknowns are framed as on-device verification with concrete fallbacks, not as unresolved code.

**Type consistency:** `annotationDrawingDidChange(_:isEmpty:)`, `annotationDrawingData`, `flushPendingAnnotationSave()`, `loadAnnotations()`, `makeSentinelAnchor()`, `isAnnotating` are used identically across Tasks 2 and 3. `AnnotationCanvasView.init(documentSize:drawingData:isPencilPreferred:onChange:)` matches its call site in Task 3 Step 2.

## Execution Handoff

Plan complete. Two execution options:
1. **Subagent-Driven (recommended)** — fresh subagent per task, review between tasks. (Tasks 1-2 are specifiable/testable; Task 3 ends at a green build + hands the on-device checklist to the user.)
2. **Inline Execution** — execute in this session with checkpoints.

Because M1's correctness is confirmed on real hardware, the milestone completes when: the package builds green, unit tests pass, AND the user signs off on the §Manual Verification checklist (applying fallbacks as needed).
