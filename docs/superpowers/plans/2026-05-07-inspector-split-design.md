# InspectorView Playback/Visual Split Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rename Reader's `MixerView` to `InspectorView` and split its contents into a Playback area (existing tempo / metronome / per-staff controls) and a Visual area (Layout picker, staff-size Stepper), with size-class-aware presentation.

**Architecture:** One file (`InspectorView.swift`) with private `@ViewBuilder` properties for `playbackContent` and `visualContent`. On compact horizontal size class, a top segmented `Picker` switches between two `List`s. On regular horizontal size class, a single `List` shows both as stacked `Section`s. The toolbar's `+/-` magnifying-glass buttons move into Visual as a `Stepper`. `ReaderViewModel` API is unchanged.

**Tech Stack:** Swift 6.3, SwiftUI, iOS 26+, Swift Testing for any new tests (none expected here). Reader feature lives in `Packages/Features/Reader/`. `xcodegen` does not need to regenerate the project — `project.yml` is unaffected because Swift Package source files are auto-discovered.

---

## File Structure

| File | Change |
| --- | --- |
| `Packages/Features/Reader/Sources/Reader/MixerView.swift` | Renamed to `InspectorView.swift`; `struct MixerView` → `struct InspectorView`; body restructured into compact/regular branches with `playbackContent` / `visualContent` view-builders. |
| `Packages/Features/Reader/Sources/Reader/ReaderView.swift` | `MixerView(...)` call site → `InspectorView(...)`; doc-comment references in `#Preview` helpers updated. |
| `Packages/Features/Reader/Sources/Reader/ReaderToolbar.swift` | Remove `minus.magnifyingglass` and `plus.magnifyingglass` buttons. Keep play/pause and inspector toggle. |
| `Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift` | Doc-comment update only — replace "MixerView" reference at line 360 with "InspectorView". No API change. |

No new files. No tests added or removed (Reader has no view-level snapshot/inspector tests, and `ReaderViewModel`'s public surface is unchanged).

---

## Task 1: Rename `MixerView.swift` → `InspectorView.swift` (file + struct)

This is purely a rename so that subsequent tasks edit the new file. Functional behavior must be unchanged after this task.

**Files:**
- Rename: `Packages/Features/Reader/Sources/Reader/MixerView.swift` → `Packages/Features/Reader/Sources/Reader/InspectorView.swift`
- Modify: `Packages/Features/Reader/Sources/Reader/InspectorView.swift` (rename type)
- Modify: `Packages/Features/Reader/Sources/Reader/ReaderView.swift:48` (update call site)
- Modify: `Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift:360` (doc comment)

- [ ] **Step 1: Move the file**

```bash
git mv Packages/Features/Reader/Sources/Reader/MixerView.swift \
       Packages/Features/Reader/Sources/Reader/InspectorView.swift
```

- [ ] **Step 2: Rename the struct and the preview reference inside the new file**

Open `Packages/Features/Reader/Sources/Reader/InspectorView.swift` and change:

- Line 5 `struct MixerView: View {` → `struct InspectorView: View {`
- The `#Preview` block at the bottom (currently around line 254) — change `MixerView(viewModel: vm, score: score)` → `InspectorView(viewModel: vm, score: score)`.

(No other lines in this file currently reference the old name.)

- [ ] **Step 3: Update the call site in `ReaderView.swift`**

`Packages/Features/Reader/Sources/Reader/ReaderView.swift:48` currently:

```swift
                    MixerView(viewModel: viewModel, score: score)
                        .presentationDetents([.medium, .large])
```

Change to:

```swift
                    InspectorView(viewModel: viewModel, score: score)
                        .presentationDetents([.medium, .large])
```

- [ ] **Step 4: Update the doc comments in `ReaderView.swift`**

`Packages/Features/Reader/Sources/Reader/ReaderView.swift` has two doc-comment references:

- Line 125: `/// `MixerView` for a productive Score-shaped preview.` → `/// `InspectorView` for a productive Score-shaped preview.`
- Line 143: ``// `MixerView`'s preview.`` → ``// `InspectorView`'s preview.``

- [ ] **Step 5: Update doc comment in `ReaderViewModel.swift`**

`Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift:360` currently:

```swift
    /// Effective playback rate multiplier — falls back to 1.0 when no
    /// override is set. The MixerView slider uses this to seed its
    /// local edit state.
```

Change "The MixerView slider" → "The InspectorView slider".

- [ ] **Step 6: Build the Reader package to confirm the rename compiles**

Run: `cd Packages/Features/Reader && swift build`

Expected: build succeeds with no errors. If any error references `MixerView`, grep for the leftover and fix.

- [ ] **Step 7: Commit**

```bash
git add Packages/Features/Reader/Sources/Reader/InspectorView.swift \
        Packages/Features/Reader/Sources/Reader/ReaderView.swift \
        Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift
git commit -m "refactor(reader): rename MixerView to InspectorView"
```

---

## Task 2: Restructure `InspectorView` body into Playback + Visual content builders

Extract the existing `List` body into a `@ViewBuilder private var playbackContent` (everything except the layout `Picker`) and add a stub `@ViewBuilder private var visualContent` that for now contains only the layout `Picker` moved out of playback. The body still renders a single `List` so behavior is preserved on both size classes — branching by size class is added in the next task. This intermediate state keeps each commit independently buildable and reviewable.

**Files:**
- Modify: `Packages/Features/Reader/Sources/Reader/InspectorView.swift`

- [ ] **Step 1: Replace the body and add the two content builders**

Open `Packages/Features/Reader/Sources/Reader/InspectorView.swift`. Replace the entire body of the `InspectorView` struct (the `var body` plus the existing `tempoRow` / `tempoControls` / `staffRow` / `programPicker` / `visibilityButton` builders stay) so the struct now reads as below. Keep the existing `tempoRow`, `tempoControls`, `staffRow`, `programPicker`, `visibilityButton` definitions — they are unchanged.

```swift
struct InspectorView: View {
    @Bindable var viewModel: ReaderViewModel
    let score: Score

    @AppStorage("readerMetronomeEnabled") private var isMetronomeEnabled: Bool = false
    /// Slider's local edit value. Syncs from `viewModel.effectiveTempoMultiplier`
    /// when the user is not dragging — keeps the UI consistent after a reset
    /// from outside the slider (e.g. the % label tap).
    @State private var sliderValue: Double = 1.0
    @State private var isEditingTempo: Bool = false

    var body: some View {
        List {
            playbackContent
            visualContent
        }
        .listStyle(.plain)
        .buttonStyle(.plain)
        .padding(.top, 16)
        .environment(\.defaultMinListRowHeight, 28)
        .task(id: viewModel.effectiveTempoMultiplier) {
            if !isEditingTempo {
                sliderValue = viewModel.effectiveTempoMultiplier
            }
        }
        .task {
            await viewModel.setMetronomeEnabled(isMetronomeEnabled)
        }
    }

    @ViewBuilder
    private var playbackContent: some View {
        tempoRow
        ForEach(score.parts.indices, id: \.self) { partIndex in
            let part = score.parts[partIndex]
            Section {
                ForEach(part.staves.indices, id: \.self) { staffIndex in
                    staffRow(address: StaffAddress(partIndex: partIndex, staffIndexInPart: staffIndex))
                }
            } header: {
                Text(part.instrument.longName ?? part.trackName ?? "-")
                    .font(.headline)
                    .padding(.bottom, -8)
            }
            .headerProminence(.increased)
            .padding(.bottom, -8)
        }
    }

    @ViewBuilder
    private var visualContent: some View {
        Section {
            Picker("Layout", selection: $viewModel.layoutMode) {
                Text("Vertical").tag(ReaderViewModel.LayoutMode.vertical)
                Text("Horizontal").tag(ReaderViewModel.LayoutMode.horizontal)
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
    }
```

(Leave the closing `}` of the struct, then `tempoRow`, `tempoControls`, `staffRow`, `programPicker`, `visibilityButton`, and `#Preview` exactly as they are.)

- [ ] **Step 2: Build to confirm the refactor compiles**

Run: `cd Packages/Features/Reader && swift build`

Expected: build succeeds. Visual rendering should be identical to before (layout picker still appears in the middle of the list, same tempo + per-staff sections).

- [ ] **Step 3: Commit**

```bash
git add Packages/Features/Reader/Sources/Reader/InspectorView.swift
git commit -m "refactor(reader): extract playback/visual content builders in InspectorView"
```

---

## Task 3: Add size-class-aware branching in `InspectorView` body

Now branch on `@Environment(\.horizontalSizeClass)`: compact gets a top `Picker` over two separate `List`s, regular gets a single `List` with two stacked `Section`s. The `.task` modifiers must apply regardless of which branch renders, so they attach to the outermost container (a `VStack` that wraps the size-class switch).

**Files:**
- Modify: `Packages/Features/Reader/Sources/Reader/InspectorView.swift`

- [ ] **Step 1: Add the tab enum and `selectedTab` / `hsc` properties**

At the top of the `InspectorView` struct (right after `@State private var isEditingTempo: Bool = false`), add:

```swift
    @Environment(\.horizontalSizeClass) private var hsc
    @State private var selectedTab: InspectorTab = .playback
```

And below the struct (or above it inside the same file, but outside the struct) add the enum:

```swift
private enum InspectorTab: Hashable {
    case playback
    case visual
}
```

- [ ] **Step 2: Replace the body with the size-class branch**

Replace the current `var body` with:

```swift
    var body: some View {
        Group {
            if hsc == .compact {
                VStack(spacing: 0) {
                    Picker("", selection: $selectedTab) {
                        Text("Playback").tag(InspectorTab.playback)
                        Text("Visual").tag(InspectorTab.visual)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                    .padding(.top, 16)

                    switch selectedTab {
                    case .playback:
                        List { playbackContent }
                            .listStyle(.plain)
                            .buttonStyle(.plain)
                            .environment(\.defaultMinListRowHeight, 28)
                    case .visual:
                        List { visualContent }
                            .listStyle(.plain)
                            .buttonStyle(.plain)
                            .environment(\.defaultMinListRowHeight, 28)
                    }
                }
            } else {
                List {
                    Section("Playback") { playbackContent }
                    Section("Visual") { visualContent }
                }
                .listStyle(.plain)
                .buttonStyle(.plain)
                .padding(.top, 16)
                .environment(\.defaultMinListRowHeight, 28)
            }
        }
        .task(id: viewModel.effectiveTempoMultiplier) {
            if !isEditingTempo {
                sliderValue = viewModel.effectiveTempoMultiplier
            }
        }
        .task {
            await viewModel.setMetronomeEnabled(isMetronomeEnabled)
        }
    }
```

Notes:

- The `.task` modifiers are attached to the outer `Group`, so they run regardless of which tab is currently visible (per spec line 49).
- The compact branch uses two separate `List`s (one per tab) so each `List` carries its own row-height environment; the regular branch uses a single combined `List` with two `Section`s.
- The regular branch wraps `playbackContent` in `Section("Playback")` so the spec's two-section visual rhythm shows up; the original tempo `Section` and per-part `Section`s become nested sections within "Playback". SwiftUI's `.plain` list renders nested sections fine — verify in step 3 below.

- [ ] **Step 3: Build and render the preview**

Run: `cd Packages/Features/Reader && swift build`

Expected: build succeeds.

Then render the existing preview (which targets compact size class because `.sheet` on iPhone reads as compact):

Use `mcp__xcode__RenderPreview` against `Packages/Features/Reader/Sources/Reader/InspectorView.swift`'s `#Preview`. Read the resulting PNG. Confirm the segmented "Playback | Visual" picker appears at the top of the sheet, "Playback" is selected by default, and switching to "Visual" reveals the layout picker.

If the preview won't switch tabs (preview interaction isn't available), set `@State private var selectedTab: InspectorTab = .visual` temporarily to render the visual side, then revert.

- [ ] **Step 4: Commit**

```bash
git add Packages/Features/Reader/Sources/Reader/InspectorView.swift
git commit -m "feat(reader): split inspector into Playback/Visual by size class"
```

---

## Task 4: Add the staff-size `Stepper` to the Visual area

The Visual area currently contains only the layout picker. Add a `Stepper` bound to a derived `Binding<CGFloat>` that delegates to `viewModel.incrementStaffSize()` / `decrementStaffSize()` and disables at min/max via `value:in:step:`.

**Files:**
- Modify: `Packages/Features/Reader/Sources/Reader/InspectorView.swift` (extend `visualContent`)

- [ ] **Step 1: Add `Domain` to the imports if it isn't already present**

The first lines of `InspectorView.swift` currently are:

```swift
import SheetMusicAudio
import SheetMusicCore
import SwiftUI
```

`ReaderPreferences` lives in `Domain`. Check if `Domain` is imported — if not, add `import Domain` so `ReaderPreferences.minStaffSize` / `.maxStaffSize` resolve. (The existing file uses `StaffAddress`, which comes from `SheetMusicCore`, so `Domain` likely is not yet imported in this file.)

- [ ] **Step 2: Extend `visualContent` with the `Stepper` row**

Replace the current `visualContent`:

```swift
    @ViewBuilder
    private var visualContent: some View {
        Section {
            Picker("Layout", selection: $viewModel.layoutMode) {
                Text("Vertical").tag(ReaderViewModel.LayoutMode.vertical)
                Text("Horizontal").tag(ReaderViewModel.LayoutMode.horizontal)
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
        }
    }
```

with:

```swift
    @ViewBuilder
    private var visualContent: some View {
        Section {
            Picker("Layout", selection: $viewModel.layoutMode) {
                Text("Vertical").tag(ReaderViewModel.LayoutMode.vertical)
                Text("Horizontal").tag(ReaderViewModel.LayoutMode.horizontal)
            }
            .pickerStyle(.segmented)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)

            staffSizeRow
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
    }

    @ViewBuilder
    private var staffSizeRow: some View {
        let staffSize = Binding<CGFloat>(
            get: { viewModel.preferences.staffSize },
            set: { newValue in
                let current = viewModel.preferences.staffSize
                if newValue > current {
                    Task { await viewModel.incrementStaffSize() }
                } else if newValue < current {
                    Task { await viewModel.decrementStaffSize() }
                }
            }
        )
        Stepper(
            "Staff size \(Int(viewModel.preferences.staffSize))",
            value: staffSize,
            in: ReaderPreferences.minStaffSize ... ReaderPreferences.maxStaffSize,
            step: 1
        )
    }
```

- [ ] **Step 3: Build the Reader package**

Run: `cd Packages/Features/Reader && swift build`

Expected: build succeeds. If the compiler complains that `ReaderPreferences` is unresolved, the `import Domain` at the top of the file is missing — add it.

- [ ] **Step 4: Render the preview to confirm the Stepper appears in Visual**

Use `mcp__xcode__RenderPreview` on `InspectorView.swift`. To see the Visual tab in the compact preview, temporarily set `@State private var selectedTab: InspectorTab = .visual`, render, then revert to `.playback`.

Expected: the Visual tab shows two rows — the Layout segmented picker and below it a system `Stepper` labelled "Staff size 14" (or whatever the preview's seeded staff size is) with `+`/`-` buttons. Confirm the integer label has no trailing `.0`.

- [ ] **Step 5: Commit**

```bash
git add Packages/Features/Reader/Sources/Reader/InspectorView.swift
git commit -m "feat(reader): add staff-size stepper to InspectorView visual area"
```

---

## Task 5: Remove the `+/-` magnifying-glass buttons from the toolbar

With the Stepper in place, the toolbar's two zoom buttons are redundant.

**Files:**
- Modify: `Packages/Features/Reader/Sources/Reader/ReaderToolbar.swift:25-39`

- [ ] **Step 1: Strip the two staff-size buttons from `ReaderToolbar.body`**

Open `Packages/Features/Reader/Sources/Reader/ReaderToolbar.swift`. The `ToolbarItemGroup` body currently is:

```swift
        ToolbarItemGroup(placement: trailingPlacement) {
            Button {
                Task { await viewModel.togglePlayback() }
            } label: {
                Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
            }
            .accessibilityLabel(viewModel.isPlaying ? "Pause" : "Play")

            Button {
                Task { await viewModel.decrementStaffSize() }
            } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .disabled(viewModel.preferences.staffSize <= ReaderPreferences.minStaffSize)

            Button {
                Task { await viewModel.incrementStaffSize() }
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .disabled(viewModel.preferences.staffSize >= ReaderPreferences.maxStaffSize)

            Button {
                viewModel.isInspectorPresented.toggle()
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .accessibilityLabel("Show staves panel")
        }
```

Replace with:

```swift
        ToolbarItemGroup(placement: trailingPlacement) {
            Button {
                Task { await viewModel.togglePlayback() }
            } label: {
                Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
            }
            .accessibilityLabel(viewModel.isPlaying ? "Pause" : "Play")

            Button {
                viewModel.isInspectorPresented.toggle()
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .accessibilityLabel("Show staves panel")
        }
```

`ReaderBottomOverlay` below it is unchanged.

- [ ] **Step 2: Confirm `ReaderPreferences` import is no longer needed if it was only used by the deleted buttons**

Look at the top of `ReaderToolbar.swift`. The `import Domain` line is required for `ReaderPreferences` references. After deletion, `ReaderPreferences` is no longer mentioned in this file — but `Domain` may still be needed for other types in the same file. Run the build in step 3 first; if the build succeeds with `import Domain` still present, leave it (it's harmless). If unused-import lint fires, delete the line.

- [ ] **Step 3: Build the Reader package**

Run: `cd Packages/Features/Reader && swift build`

Expected: build succeeds.

- [ ] **Step 4: Build the full app**

Run: `xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 16' -skipPackagePluginValidation build`

Expected: build succeeds. (This catches any place outside the Reader package that still references `MixerView` or relied on the toolbar buttons — there shouldn't be any, but verifying at app scope is cheap insurance.)

- [ ] **Step 5: Commit**

```bash
git add Packages/Features/Reader/Sources/Reader/ReaderToolbar.swift
git commit -m "feat(reader): remove staff-size buttons from toolbar (moved to inspector)"
```

---

## Task 6: Manual verification on iPhone and iPad simulators

The Reader feature has no view-level snapshot tests, so the spec calls for manual verification across both size classes. The code changes are done; this task only runs the app and confirms behavior.

**Files:** none modified.

- [ ] **Step 1: Boot an iPhone simulator and install the app**

Run:

```bash
xcodebuild -project Folino.xcodeproj -scheme Folino \
    -destination 'platform=iOS Simulator,name=iPhone 16' \
    -skipPackagePluginValidation build
```

Then launch from Xcode (or via `xcrun simctl install` + `xcrun simctl launch` per the project's documented flow).

- [ ] **Step 2: iPhone smoke checks**

In the running iPhone simulator (or via the user — hand control back if interaction is required), open any score, then open the inspector via the `slider.horizontal.3` toolbar button. Verify:

- A segmented `Picker` is present at the top with "Playback" and "Visual" tabs. "Playback" is selected by default.
- Playback tab shows the master tempo + metronome row and per-part sections (volume, solo `s.circle`, mute `m.circle`, eye, instrument menu) — exactly what was in `MixerView` previously.
- Visual tab shows the Layout segmented picker and a "Staff size N" `Stepper`. `+`/`-` buttons disable at the bounds (`N == 8` disables `-`, `N == 28` disables `+`).
- Switching tabs and returning preserves tempo slider position, metronome on/off state, and per-staff overrides (no resets).
- Toolbar shows only play/pause and inspector toggle. The `+/-` magnifying-glass buttons are gone.
- Bottom reset-zoom pill behaves as before — only appears after a pinch zoom.

- [ ] **Step 3: iPad smoke checks**

Repeat on iPad:

```bash
xcodebuild -project Folino.xcodeproj -scheme Folino \
    -destination 'platform=iOS Simulator,name=iPad Pro 11-inch (M4)' \
    -skipPackagePluginValidation build
```

(Pick whatever iPad device name the local Xcode has — `xcrun simctl list devices available` lists them.)

In the inspector on iPad, verify:

- No segmented picker at the top.
- A single scrolling `List` shows "Playback" section (tempo row + per-part sections) stacked above a "Visual" section (layout picker + staff-size Stepper).
- Same per-staff and tempo behavior as iPhone.

- [ ] **Step 4: If issues are found, file them as follow-up commits in the same branch**

The spec's "Risks" section calls out two known concerns to watch for:

- `.listStyle(.plain)` / `defaultMinListRowHeight` rhythm differs across compact and regular branches → if visible, normalize by hoisting these onto each `List` instance (already done in Task 3 step 2).
- `Stepper` styling looks heavier than the toolbar's icon buttons — acceptable per spec, only revisit if user testing flags it.

If neither shows up, no follow-up needed.

- [ ] **Step 5: No commit needed unless follow-up fixes were applied**

If verification was clean, this task ends here.

---

## Self-Review Notes (recorded by plan author)

- **Spec coverage:** rename → Task 1; layout split with size-class branch → Task 3; staff-size Stepper in Visual → Task 4; toolbar diff (remove `+/-` buttons) → Task 5; preview comment update in `PreviewSupport.swift` was checked — that file does not currently mention "MixerView", so no edit needed. Manual verification → Task 6.
- **Type consistency:** `incrementStaffSize` / `decrementStaffSize` (verified at `ReaderViewModel.swift:126,134`), `ReaderPreferences.minStaffSize` / `maxStaffSize` (verified at `ReaderPreferences.swift:10,11`), `viewModel.preferences.staffSize: CGFloat` (verified at `ReaderPreferences.swift:41`).
- **Placeholder scan:** every step shows the actual code or command. No TBDs.
- **No-API-change guarantee:** `ReaderViewModel.swift` is touched only in a doc comment (Task 1 step 5). The existing `ReaderViewModelTests` (which call `incrementStaffSize` / `decrementStaffSize`) are unaffected.
