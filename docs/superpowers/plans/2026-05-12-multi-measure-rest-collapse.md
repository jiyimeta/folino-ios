# Multi-measure rest collapse toggle — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a global on/off preference that toggles
`swift-sheet-music`'s multi-measure-rest collapse (min=2), surfaced from
both the Settings sheet and the Reader's Visual Inspector, and honored
by the on-screen score and the PiP renderer.

**Architecture:** New `ReaderGlobalSettingsKey.collapseMultiMeasureRests`
String constant in `Domain`. Two `@AppStorage` Toggle bindings (one in
`SettingsSheet`, one in `VisualInspectorScreen`) targeting that key.
`ReaderRootScreen` reads the value and forwards a `Bool` into both
`HorizontalScoreContainer` and `VerticalScoreContainer`, which set
`ScoreViewOptions.multiMeasureRest` and re-trigger `rebuildLayout` via
their existing `TaskKey`. The PiP renderer takes the same flag through
`ReaderViewModel` → `ScorePiPCoordinator.arm` → `ScorePiPFrameRenderer`.

**Tech Stack:** Swift 6.3, SwiftUI, Swift Testing, swift-sheet-music
(modules `SheetMusicCore`, `SheetMusicLayout`, `SheetMusicUI`),
`Localizable.xcstrings`, XcodeBuildMCP for build/preview verification.

**Spec:** `docs/superpowers/specs/2026-05-12-multi-measure-rest-collapse-design.md`

---

## File Map

**Modified:**
- `Packages/Domain/Sources/Domain/Models/ReaderLayoutMode.swift` — add new key constant
- `Packages/Domain/Sources/Domain/Models/ReaderPreferences.swift` — add `multiMeasureRestThreshold` constant
- `Packages/Domain/Tests/DomainTests/Models/ReaderLayoutModeTests.swift` — assert new key raw value
- `Packages/Features/Settings/Sources/Settings/Resources/Localizable.xcstrings` — Settings label en/ja
- `Packages/Features/Settings/Sources/Settings/Screens/SettingsSheet.swift` — `@AppStorage` + Toggle row
- `Packages/Features/Reader/Sources/Reader/Resources/Localizable.xcstrings` — Inspector label en/ja
- `Packages/Features/Reader/Sources/Reader/Screens/VisualInspectorScreen.swift` — `@AppStorage` + Toggle row
- `Packages/Features/Reader/Sources/Reader/Screens/HorizontalScoreContainer.swift` — new init field + `scoreOptions` + `TaskKey`
- `Packages/Features/Reader/Sources/Reader/Screens/VerticalScoreContainer.swift` — new init field + `scoreOptions` + `TaskKey`
- `Packages/Features/Reader/Sources/Reader/Screens/VerticalScoreContainerPreviews.swift` — preview-site init updates
- `Packages/Features/Reader/Sources/Reader/PreviewSupport.swift` — preview-site init updates
- `Packages/Features/Reader/Sources/Reader/Screens/ReaderRootScreen.swift` — `@AppStorage` + forward to both containers + forward to ViewModel for PiP
- `Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift` — store flag + apply to PiP arm path
- `Packages/Features/Reader/Sources/Reader/PiP/ScorePiPCoordinator.swift` — extend `arm(...)` with new param
- `Packages/Features/Reader/Sources/Reader/PiP/ScorePiPFrameRenderer.swift` — extend `init(...)` with new param, apply to `ScoreViewOptions`

**Not modified:** `LayoutSettingsModel`, `ReaderPreferences` record / DB layer
(setting is global, not per-score).

---

## Task 1: Add `collapseMultiMeasureRests` key to `ReaderGlobalSettingsKey`

**Files:**
- Modify: `Packages/Domain/Sources/Domain/Models/ReaderLayoutMode.swift`
- Test: `Packages/Domain/Tests/DomainTests/Models/ReaderLayoutModeTests.swift`

- [ ] **Step 1: Write the failing test**

Add this test method to the existing `ReaderGlobalSettingsKeyTests`
suite in `Packages/Domain/Tests/DomainTests/Models/ReaderLayoutModeTests.swift`,
right after the existing `pictureInPictureEnabled` assertion (around line 26):

```swift
@Test
func collapseMultiMeasureRestsRawValueIsStable() {
    #expect(
        ReaderGlobalSettingsKey.collapseMultiMeasureRests
            == "readerCollapseMultiMeasureRests",
    )
}
```

(If the existing suite is a single `@Test` function that asserts all
keys at once rather than per-key methods, append an `#expect` line to
that function instead — match whichever style is already there.)

- [ ] **Step 2: Run test to verify it fails**

```bash
cd /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/Packages/Domain
swift test --filter ReaderLayoutModeTests
```

Expected: build failure or test failure referencing
`collapseMultiMeasureRests` (member missing on
`ReaderGlobalSettingsKey`).

- [ ] **Step 3: Add the constant**

In `Packages/Domain/Sources/Domain/Models/ReaderLayoutMode.swift`,
inside the `public enum ReaderGlobalSettingsKey` block (after the
existing `pictureInPictureEnabled` constant on line 28), append:

```swift
    /// Bool. When true, runs of two or more consecutive empty-rest
    /// measures render as a single H-bar with a count, using
    /// `MultiMeasureRestPolicy.collapse`. When false, measures
    /// render individually.
    public static let collapseMultiMeasureRests = "readerCollapseMultiMeasureRests"
```

- [ ] **Step 4: Run test to verify it passes**

```bash
cd /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/Packages/Domain
swift test --filter ReaderLayoutModeTests
```

Expected: all assertions pass.

- [ ] **Step 5: Commit**

```bash
cd /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS
git add Packages/Domain/Sources/Domain/Models/ReaderLayoutMode.swift \
        Packages/Domain/Tests/DomainTests/Models/ReaderLayoutModeTests.swift
git commit -m "Add collapseMultiMeasureRests global settings key"
```

---

## Task 2: Add `multiMeasureRestThreshold` constant to `ReaderPreferences`

**Files:**
- Modify: `Packages/Domain/Sources/Domain/Models/ReaderPreferences.swift`

- [ ] **Step 1: Add the constant**

In `Packages/Domain/Sources/Domain/Models/ReaderPreferences.swift`,
locate the existing `public static let minStaffSize` /
`maxStaffSize` block (around lines 10-11). Add immediately after
`maxTempoMultiplier`:

```swift
    /// Minimum run length (in measures) at which the Reader collapses
    /// consecutive empty-rest measures into a single H-bar. Fixed —
    /// not user-tunable in this iteration.
    public static let multiMeasureRestThreshold = 2
```

- [ ] **Step 2: Build Domain package to verify**

```bash
cd /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/Packages/Domain
swift build
```

Expected: clean build, no warnings.

- [ ] **Step 3: Commit**

```bash
cd /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS
git add Packages/Domain/Sources/Domain/Models/ReaderPreferences.swift
git commit -m "Add multiMeasureRestThreshold constant"
```

---

## Task 3: Settings sheet UI (xcstring + Toggle)

**Files:**
- Modify: `Packages/Features/Settings/Sources/Settings/Resources/Localizable.xcstrings`
- Modify: `Packages/Features/Settings/Sources/Settings/Screens/SettingsSheet.swift`

- [ ] **Step 1: Add the localized string**

Open `Packages/Features/Settings/Sources/Settings/Resources/Localizable.xcstrings`
and add this entry alphabetically near the existing
`settings.reader.pictureInPicture` block (mirror its exact shape):

```json
"settings.reader.collapseMultiMeasureRests" : {
  "localizations" : {
    "en" : {
      "stringUnit" : {
        "state" : "translated",
        "value" : "Collapse multi-measure rests"
      }
    },
    "ja" : {
      "stringUnit" : {
        "state" : "translated",
        "value" : "複数小節休符をまとめる"
      }
    }
  }
}
```

Make sure trailing commas remain syntactically valid for the JSON
object (i.e. there is a comma between this entry and the next sibling
unless it is the last entry).

- [ ] **Step 2: Add the `@AppStorage` property**

In `Packages/Features/Settings/Sources/Settings/Screens/SettingsSheet.swift`,
immediately after the existing `isPiPEnabled` property (line 24-25),
add:

```swift
    @AppStorage(ReaderGlobalSettingsKey.collapseMultiMeasureRests)
    private var collapseMultiMeasureRests = false
```

- [ ] **Step 3: Add the Toggle in `readerSection`**

In the same file, locate the `readerSection` body. Insert this Toggle
block immediately after the PiP `Toggle(isOn: $isPiPEnabled) { ... }`
block (currently ends around line 97) and before the layout-mode
`HStack`:

```swift
            Toggle(isOn: $collapseMultiMeasureRests) {
                Label {
                    Text("settings.reader.collapseMultiMeasureRests", bundle: .module)
                } icon: {
                    Image(systemName: "rectangle.compress.vertical")
                }
            }
```

- [ ] **Step 4: Build the Settings package**

```bash
cd /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/Packages/Features/Settings
swift build
```

Expected: clean build. SwiftLint plugin may run; treat warnings/errors
on the lines you added as actionable.

- [ ] **Step 5: Render Settings preview to confirm the toggle appears**

Using XcodeBuildMCP-style verification (Xcode must already be running
with the project open — see global CLAUDE.md):

```
mcp__xcode__RenderPreview on SettingsSheet's existing #Preview "Without resolver"
```

Read the resulting PNG and confirm: the reader section shows
Metronome → Picture in Picture → **Collapse multi-measure rests** →
Layout, in that order, with a `rectangle.compress.vertical` icon.

If the preview build fails, fix the cause and stay on the preview path
(do not switch to simulator) per global rules.

- [ ] **Step 6: Commit**

```bash
cd /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS
git add Packages/Features/Settings/Sources/Settings/Resources/Localizable.xcstrings \
        Packages/Features/Settings/Sources/Settings/Screens/SettingsSheet.swift
git commit -m "Add collapse multi-measure rests toggle to Settings sheet"
```

---

## Task 4: Visual Inspector UI (xcstring + Toggle)

**Files:**
- Modify: `Packages/Features/Reader/Sources/Reader/Resources/Localizable.xcstrings`
- Modify: `Packages/Features/Reader/Sources/Reader/Screens/VisualInspectorScreen.swift`

- [ ] **Step 1: Add the localized string**

Open `Packages/Features/Reader/Sources/Reader/Resources/Localizable.xcstrings`
and add this entry near the existing `reader.preferences.honorBreaks`
block:

```json
"reader.preferences.collapseMultiMeasureRests" : {
  "localizations" : {
    "en" : {
      "stringUnit" : {
        "state" : "translated",
        "value" : "Collapse multi-measure rests"
      }
    },
    "ja" : {
      "stringUnit" : {
        "state" : "translated",
        "value" : "複数小節休符をまとめる"
      }
    }
  }
}
```

(Same JSON-comma discipline as Task 3 Step 1.)

- [ ] **Step 2: Add the `@AppStorage` property**

In `Packages/Features/Reader/Sources/Reader/Screens/VisualInspectorScreen.swift`,
immediately after the existing `layoutModeRaw` property (line 10-11),
add:

```swift
    @AppStorage(ReaderGlobalSettingsKey.collapseMultiMeasureRests)
    private var collapseMultiMeasureRests = false
```

- [ ] **Step 3: Add the row to the body**

In the same file's `body`, locate the `List` content. Replace this
block (currently lines 18-20):

```swift
            layoutRow
            staffSizeRow
            breakPolicyRow
```

with:

```swift
            layoutRow
            staffSizeRow
            breakPolicyRow
            collapseRow
```

Then add this private computed view right after `breakPolicyRow`
(after the `}` closing `breakPolicyRow`, around line 76):

```swift
    @ViewBuilder
    private var collapseRow: some View {
        Toggle(isOn: $collapseMultiMeasureRests) {
            Text("reader.preferences.collapseMultiMeasureRests", bundle: .module)
        }
    }
```

- [ ] **Step 4: Build the Reader package**

```bash
cd /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/Packages/Features/Reader
swift build
```

Expected: clean build.

- [ ] **Step 5: Render Inspector preview to confirm the toggle appears**

If `VisualInspectorScreen.swift` does not already have a `#Preview`
block, add a minimal one at the bottom of the file (gate it on
`#if DEBUG`) using whatever stub-construction helper neighboring
inspector files use — search the file for existing previews first.
If a preview already exists, skip the addition.

Then:

```
mcp__xcode__RenderPreview on VisualInspectorScreen #Preview
```

Read the PNG and confirm: under the top-of-list controls,
`Layout direction` → `Staff size` → `Honor authored breaks` →
**Collapse multi-measure rests** is the order, with the Toggle in
the on/off control style.

- [ ] **Step 6: Commit**

```bash
cd /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS
git add Packages/Features/Reader/Sources/Reader/Resources/Localizable.xcstrings \
        Packages/Features/Reader/Sources/Reader/Screens/VisualInspectorScreen.swift
git commit -m "Add collapse multi-measure rests toggle to Visual Inspector"
```

---

## Task 5: Thread the flag through `HorizontalScoreContainer`

**Files:**
- Modify: `Packages/Features/Reader/Sources/Reader/Screens/HorizontalScoreContainer.swift`

- [ ] **Step 1: Add the stored input**

In `HorizontalScoreContainer.swift`, immediately after the existing
`let honorLayoutBreaks: Bool` field (around line 20), add:

```swift
    let collapseMultiMeasureRests: Bool
```

- [ ] **Step 2: Wire it into `scoreOptions`**

Replace the `scoreOptions` computed property (currently lines 106-113)
with this full version:

```swift
    private var scoreOptions: ScoreViewOptions {
        ScoreViewOptions(
            staffSize: staffSize, systemGap: staffSize * 1.25,
            wrapToViewWidth: false, includeTitleFrame: false,
            breakPolicy: honorLayoutBreaks ? .honor : .ignoreAll,
            showBreakIndicators: false,
            multiMeasureRest: collapseMultiMeasureRests
                ? .collapse(minimumMeasures: ReaderPreferences.multiMeasureRestThreshold)
                : .disabled,
        )
    }
```

(`ReaderPreferences` is already in scope via the existing
`import Domain`.)

- [ ] **Step 3: Update `TaskKey` so toggling re-triggers layout**

In the same file, locate the private `TaskKey` struct (around
lines 158-176). It is `Hashable` and computes a `scoreSignature: Int`
from the score's structural shape — preserve that math exactly and
add the new field alongside:

```swift
    private struct TaskKey: Hashable {
        let scoreSignature: Int
        let size: CGFloat
        let honorLayoutBreaks: Bool
        let collapseMultiMeasureRests: Bool

        init(
            score: Score,
            size: CGFloat,
            honorLayoutBreaks: Bool,
            collapseMultiMeasureRests: Bool,
        ) {
            // Structural shape + opening clefs. The opening-clef hash is
            // what makes a clef override (a field-level edit that leaves
            // parts.count / staff count unchanged) re-trigger this
            // `.task(id:)`. See `VerticalScoreContainer.TaskKey` for the
            // matching rationale.
            scoreSignature = score.parts.count
                ^ (score.totalStaffCount << 8)
                ^ (score.division << 16)
                ^ score.openingClefSignature
            self.size = size
            self.honorLayoutBreaks = honorLayoutBreaks
            self.collapseMultiMeasureRests = collapseMultiMeasureRests
        }
    }
```

Then update the `.task(id:)` call site (currently around lines 45-48):

```swift
            .task(id: TaskKey(
                score: score, size: staffSize,
                honorLayoutBreaks: honorLayoutBreaks,
                collapseMultiMeasureRests: collapseMultiMeasureRests,
            )) {
                rebuildLayout()
            }
```

- [ ] **Step 4: Build the Reader package**

```bash
cd /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/Packages/Features/Reader
swift build
```

Expected: build fails — all call sites that construct
`HorizontalScoreContainer` (in `ReaderRootScreen` and any preview /
support file) now need the new argument. **Do not fix those yet** —
Task 7 wires them. Leave the package in its broken state and move on
to Task 6.

If `swift build` produces fix-it suggestions, ignore them for now;
the diagnostic is the signal that the call sites need updating.

- [ ] **Step 5: Stage but do not commit**

```bash
cd /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS
git add Packages/Features/Reader/Sources/Reader/Screens/HorizontalScoreContainer.swift
```

The commit happens after Task 7 once the call sites build clean.

---

## Task 6: Thread the flag through `VerticalScoreContainer`

**Files:**
- Modify: `Packages/Features/Reader/Sources/Reader/Screens/VerticalScoreContainer.swift`

- [ ] **Step 1: Add the stored input**

In `VerticalScoreContainer.swift`, immediately after the existing
`let honorLayoutBreaks: Bool` field, add:

```swift
    let collapseMultiMeasureRests: Bool
```

- [ ] **Step 2: Wire it into `scoreOptions`**

Replace the `scoreOptions` computed property (currently lines 289-296)
with:

```swift
    private var scoreOptions: ScoreViewOptions {
        ScoreViewOptions(
            staffSize: staffSize, systemGap: staffSize * 1.25,
            wrapToViewWidth: true, includeTitleFrame: true,
            breakPolicy: honorLayoutBreaks ? .honor : .ignoreAll,
            showBreakIndicators: false,
            multiMeasureRest: collapseMultiMeasureRests
                ? .collapse(minimumMeasures: ReaderPreferences.multiMeasureRestThreshold)
                : .disabled,
        )
    }
```

- [ ] **Step 3: Update `TaskKey` and its call site**

Locate the private `TaskKey` struct (around lines 372-392). Add a
field and extend the initializer (preserve the existing
`scoreSignature` hash math — do not simplify it):

```swift
        private struct TaskKey: Hashable {
            let scoreSignature: Int
            let size: CGFloat
            let width: CGFloat
            let honorLayoutBreaks: Bool
            let collapseMultiMeasureRests: Bool

            init(
                score: Score,
                size: CGFloat,
                width: CGFloat,
                honorLayoutBreaks: Bool,
                collapseMultiMeasureRests: Bool,
            ) {
                scoreSignature = score.parts.count
                    ^ (score.totalStaffCount << 8)
                    ^ (score.division << 16)
                    ^ score.openingClefSignature
                self.size = size
                self.width = width
                self.honorLayoutBreaks = honorLayoutBreaks
                self.collapseMultiMeasureRests = collapseMultiMeasureRests
            }
        }
```

Then update the `.task(id:)` call site (around line 97):

```swift
                .task(id: TaskKey(
                    score: score,
                    size: staffSize,
                    width: layoutWidth,
                    honorLayoutBreaks: honorLayoutBreaks,
                    collapseMultiMeasureRests: collapseMultiMeasureRests,
                )) {
                    await rebuildLayout(width: layoutWidth)
                }
```

- [ ] **Step 4: Stage but do not commit**

```bash
cd /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS
git add Packages/Features/Reader/Sources/Reader/Screens/VerticalScoreContainer.swift
```

---

## Task 7: Update `ReaderRootScreen` + previews to pass the flag

**Files:**
- Modify: `Packages/Features/Reader/Sources/Reader/Screens/ReaderRootScreen.swift`
- Modify: `Packages/Features/Reader/Sources/Reader/Screens/VerticalScoreContainerPreviews.swift`
- Modify: `Packages/Features/Reader/Sources/Reader/PreviewSupport.swift`

- [ ] **Step 1: Add `@AppStorage` to `ReaderRootScreen`**

In `ReaderRootScreen.swift`, immediately after the existing
`isPiPEnabled` property (line 19-20), add:

```swift
    @AppStorage(ReaderGlobalSettingsKey.collapseMultiMeasureRests)
    private var collapseMultiMeasureRests = false
```

- [ ] **Step 2: Forward to both score containers**

In the same file, locate the `switch layoutMode` block in the
`content` property (lines 139-156). Update both initializer call
sites to pass `collapseMultiMeasureRests`:

```swift
            switch layoutMode {
            case .vertical:
                VerticalScoreContainer(
                    score: visible,
                    staffSize: viewModel.layoutModel.staffSize,
                    honorLayoutBreaks: viewModel.layoutModel.honorLayoutBreaks,
                    collapseMultiMeasureRests: collapseMultiMeasureRests,
                    playbackCursor: viewModel.playbackCursor,
                    viewModel: viewModel,
                )
            case .horizontal:
                HorizontalScoreContainer(
                    score: visible,
                    staffSize: viewModel.layoutModel.staffSize,
                    honorLayoutBreaks: viewModel.layoutModel.honorLayoutBreaks,
                    collapseMultiMeasureRests: collapseMultiMeasureRests,
                    playbackCursor: viewModel.playbackCursor,
                    viewModel: viewModel,
                )
            }
```

- [ ] **Step 3: Update preview call sites**

In `Packages/Features/Reader/Sources/Reader/Screens/VerticalScoreContainerPreviews.swift`,
find every `VerticalScoreContainer(...)` initializer (use `grep` if
unsure) and add `collapseMultiMeasureRests: false,` in the same
position as in Task 7 Step 2.

Likewise in `Packages/Features/Reader/Sources/Reader/PreviewSupport.swift`,
find any `HorizontalScoreContainer(...)` or `VerticalScoreContainer(...)`
initializer and add `collapseMultiMeasureRests: false,`. If
`PreviewSupport.swift` has neither, no change is needed there.

- [ ] **Step 4: Build the Reader package clean**

```bash
cd /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/Packages/Features/Reader
swift build
```

Expected: clean build with no missing-argument diagnostics.

- [ ] **Step 5: Build the full app project**

```bash
cd /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS
xcodebuild -project Folino.xcodeproj -scheme Folino \
    -destination 'platform=iOS Simulator,name=iPhone 16' \
    -skipPackagePluginValidation build
```

Expected: full build succeeds.

- [ ] **Step 6: Commit (rolls in Tasks 5, 6, 7 staged changes)**

```bash
cd /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS
git add Packages/Features/Reader/Sources/Reader/Screens/ReaderRootScreen.swift \
        Packages/Features/Reader/Sources/Reader/Screens/VerticalScoreContainerPreviews.swift \
        Packages/Features/Reader/Sources/Reader/PreviewSupport.swift
git commit -m "Apply multi-measure rest policy to on-screen score"
```

(`HorizontalScoreContainer.swift` and `VerticalScoreContainer.swift`
were `git add`ed in Tasks 5 and 6; they are part of this commit.)

---

## Task 8: Plumb the flag into the PiP renderer

**Files:**
- Modify: `Packages/Features/Reader/Sources/Reader/PiP/ScorePiPFrameRenderer.swift`
- Modify: `Packages/Features/Reader/Sources/Reader/PiP/ScorePiPCoordinator.swift`
- Modify: `Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift`
- Modify: `Packages/Features/Reader/Sources/Reader/Screens/ReaderRootScreen.swift`

- [ ] **Step 1: Extend `ScorePiPFrameRenderer.init`**

In `ScorePiPFrameRenderer.swift`, update the initializer signature
(currently `init(score: Score, staffSize: CGFloat) throws`) and the
`ScoreViewOptions` construction inside (currently lines 37-42):

```swift
    init(score: Score, staffSize: CGFloat, collapseMultiMeasureRests: Bool) throws {
        self.score = score

        let opts = ScoreViewOptions(
            staffSize: staffSize, systemGap: staffSize * 1.25,
            wrapToViewWidth: false, includeTitleFrame: false,
            breakPolicy: .ignoreAll,
            showBreakIndicators: false,
            multiMeasureRest: collapseMultiMeasureRests
                ? .collapse(minimumMeasures: ReaderPreferences.multiMeasureRestThreshold)
                : .disabled,
        )
```

(`ReaderPreferences` is in `Domain`. Add `import Domain` at the top
of the file if it is not already imported — check first.)

- [ ] **Step 2: Extend `ScorePiPCoordinator.arm`**

In `ScorePiPCoordinator.swift`, locate `arm(score:, playbackCursor:)`
(around line 122). Update to accept the new parameter and forward
it to the renderer:

```swift
    func arm(
        score: Score,
        playbackCursor: ScoreCursor?,
        collapseMultiMeasureRests: Bool,
    ) throws {
        guard displayLayer != nil else {
            throw NSError(
                domain: "ScorePiPCoordinator", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "No display layer attached"],
            )
        }
        renderer = try ScorePiPFrameRenderer(
            score: score,
            staffSize: Self.pipStaffSize,
            collapseMultiMeasureRests: collapseMultiMeasureRests,
        )
        ...  // rest unchanged
```

(Leave every line below the `renderer = …` assignment untouched.)

- [ ] **Step 3: Add stored flag + setter on `ReaderViewModel`**

In `ReaderViewModel.swift`, immediately after the existing
`private var isPiPEnabled = false` (line 89), add:

```swift
    private var collapseMultiMeasureRests = false
```

Then add a setter, placed next to `setPiPEnabled` (around line 94)
for symmetry:

```swift
    func setCollapseMultiMeasureRests(_ enabled: Bool) {
        guard collapseMultiMeasureRests != enabled else { return }
        collapseMultiMeasureRests = enabled
        // Re-arm PiP so the next frame batch picks up the new policy.
        // No effect if PiP is currently disabled / not armed.
        armPiPIfReady()
    }
```

Finally, update `armPiPIfReady` (around line 114) to pass the stored
flag into `arm`:

```swift
    private func armPiPIfReady() {
        guard isPiPEnabled, case let .loaded(score) = loadState else { return }
        do {
            try pipCoordinator.arm(
                score: score,
                playbackCursor: playbackCursor,
                collapseMultiMeasureRests: collapseMultiMeasureRests,
            )
        } catch {
            // Existing error handling kept as-is.
        }
    }
```

(Preserve whatever `catch` body the existing code has — only the
`arm(…)` call changes.)

- [ ] **Step 4: Wire `ReaderRootScreen` → ViewModel for PiP**

In `ReaderRootScreen.swift`, inside the existing `.task { ... }`
block (currently lines 92-100), add a setter call so the engine
starts in sync with `@AppStorage`. Place it next to the existing
`viewModel.setPiPEnabled(isPiPEnabled)`:

```swift
        .task {
            viewModel.startObservingCursor()
            viewModel.setPiPEnabled(isPiPEnabled)
            viewModel.setCollapseMultiMeasureRests(collapseMultiMeasureRests)
            await viewModel.load()
            await viewModel.prepareForPlayback()
            await viewModel.tempoModel.setMetronomeEnabled(isMetronomeEnabled)
        }
```

Then add an `onChange` observer next to the existing
`onChange(of: isPiPEnabled)` (around line 108):

```swift
        .onChange(of: collapseMultiMeasureRests) { _, newValue in
            viewModel.setCollapseMultiMeasureRests(newValue)
        }
```

- [ ] **Step 5: Build the Reader package**

```bash
cd /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/Packages/Features/Reader
swift build
```

Expected: clean build.

- [ ] **Step 6: Run Reader tests**

```bash
cd /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/Packages/Features/Reader
swift test
```

Expected: all tests pass. `ScorePiPCoordinator` is instantiated
directly in `ReaderViewModel` (no protocol seam, no fake) at the time
of writing — confirm that hasn't changed by running `swift test`. If
a fake has been introduced in the meantime, its `arm(...)` signature
must be updated to match the new one before the build is clean.

- [ ] **Step 7: Build the full app**

```bash
cd /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS
xcodebuild -project Folino.xcodeproj -scheme Folino \
    -destination 'platform=iOS Simulator,name=iPhone 16' \
    -skipPackagePluginValidation build
```

Expected: clean build.

- [ ] **Step 8: Commit**

```bash
cd /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS
git add Packages/Features/Reader/Sources/Reader/PiP/ScorePiPFrameRenderer.swift \
        Packages/Features/Reader/Sources/Reader/PiP/ScorePiPCoordinator.swift \
        Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift \
        Packages/Features/Reader/Sources/Reader/Screens/ReaderRootScreen.swift
git commit -m "Honor collapse multi-measure rests in PiP renderer"
```

---

## Task 9: Full-app verification

**Files:** none modified.

- [ ] **Step 1: Run the full test suite via xcodebuild**

```bash
cd /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS
xcodebuild -project Folino.xcodeproj -scheme Folino \
    -destination 'platform=iOS Simulator,name=iPhone 16' \
    -skipPackagePluginValidation test
```

Expected: all tests pass, including the new
`collapseMultiMeasureRestsRawValueIsStable` from Task 1.

- [ ] **Step 2: Manual simulator smoke test**

The toggle's visible effect is rendering, which simulator screenshots
can't reliably distinguish from preview screenshots — but the
*propagation* (Settings ↔ Inspector ↔ score) needs simulator
verification because it spans `@AppStorage` write/read across screens.

Run the app:

```bash
xcrun simctl install booted \
    "$(xcodebuild -project Folino.xcodeproj -scheme Folino \
        -destination 'platform=iOS Simulator,name=iPhone 16' \
        -skipPackagePluginValidation -showBuildSettings build \
        | awk -F' = ' '/^[[:space:]]*BUILT_PRODUCTS_DIR/{p=$2}/^[[:space:]]*FULL_PRODUCT_NAME/{n=$2}END{print p"/"n}')"
xcrun simctl launch booted com.KeyNumber.Folino
```

(If you already have a fresher build in DerivedData, install from
that path directly.)

Then hand control to the user with this verification checklist:

1. Open a score with at least 4 consecutive empty-rest measures (the
   "multi-measure rest" sample score is ideal; otherwise any orchestral
   excerpt with a tacit section).
2. Open Settings → Reader → toggle **Collapse multi-measure rests** ON.
3. Dismiss Settings and confirm the score has re-laid out to show
   the H-bar with count.
4. Open the Visual Inspector. The Inspector's "Collapse
   multi-measure rests" toggle must already be ON (same key).
5. Toggle from Inspector to OFF. Confirm the score expands back to
   one measure per rest.
6. Re-open Settings: its toggle must be OFF too.
7. If PiP is enabled, toggle the collapse setting, then background
   the app. The PiP window must show the new policy on the next
   arm (current armed session is *not* expected to retroactively
   change — re-armed sessions are).

Per global CLAUDE.md, do not drive these gestures via a UI agent;
ask the user to verify.

- [ ] **Step 3: Final state check**

```bash
cd /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS
git status
git log --oneline -8
```

Expected: working tree clean, four new commits on top of `7f83f00`:

1. Add collapseMultiMeasureRests global settings key
2. Add multiMeasureRestThreshold constant
3. Add collapse multi-measure rests toggle to Settings sheet
4. Add collapse multi-measure rests toggle to Visual Inspector
5. Apply multi-measure rest policy to on-screen score
6. Honor collapse multi-measure rests in PiP renderer

(Order may differ slightly; six commits total is the target.)

---

## Notes for the implementing engineer

- **Build-time SwiftLint:** Every `swift build` runs the SwiftLint
  plugin. Treat its warnings as actionable on the lines you wrote —
  don't sprinkle `// swiftlint:disable` directives.
- **Pre-commit hook:** Repo uses a pre-commit hook running SwiftFormat
  and SwiftLint --fix. If commits fail, the hook has rewritten files —
  re-stage with `git add` (the specific files, never `git add .`) and
  re-commit.
- **`@AppStorage` in `#Preview`:** Defaults to false in previews,
  which matches the spec's "default off" requirement. No special
  preview wiring needed.
- **Don't touch `LayoutSettingsModel` or `ReaderPreferences` (the
  record, not the constants struct).** The spec deliberately routes
  this preference through `@AppStorage`, not through the per-score
  model.
- **If a step's line-number reference is off by ±5 lines** — the
  file may have shifted from churn — find the equivalent landmark
  (e.g. "after `isPiPEnabled`") rather than trusting the line number.
