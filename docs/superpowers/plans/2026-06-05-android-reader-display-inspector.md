# Android Reader — Display Inspector Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring the iOS Reader's display inspector (staff size, layout breaks, multi-measure-rest collapse, invisible-element visibility, per-staff hide, per-staff clef override, and all three layout modes) to the Android Reader as a dense `ModalBottomSheet`, with all layout logic shared through swift-sheet-music.

**Architecture:** Layout/transform logic lives in swift-sheet-music and is consumed by both iOS (Swift) and Android (via a JNI bridge). Display settings cross the JNI boundary as a single `@WireFormat` blob (`LayoutOptionsWire`); the Swift bridge decodes it, applies clef-override + hidden-staff transforms to the `Score`, builds mode-specific `ScoreViewOptions`, paginates for page mode, and returns a multi-page draw program. Android holds the settings as session-transient `StateFlow`s and re-runs the layout on change.

**Tech Stack:** Swift 6 / SwiftPM (swift-sheet-music), swift-java (jextract JNI), Wirelet `@WireFormat` codegen (Swift + Kotlin), Kotlin / Jetpack Compose / Material 3 (Android).

**Reference spec:** `docs/superpowers/specs/2026-06-05-android-reader-display-inspector-design.md`

**Repos & worktrees (set up before starting):**
- **Repo A — swift-sheet-music**: clone at `~/Developer/Personal/swift-packages/swift-sheet-music`. Create a worktree (do NOT edit the shared checkout's branch in place). Phases 1–2.
- **Repo B — Folino**: `~/Developer/Personal/ios-apps/Folino-iOS`. Create a Folino worktree; symlink `Config/Local.xcconfig` from main. Phase 3+.
- The two repos are coupled: finish Repo A (build the `.so` + regenerate bindings/codecs), then re-pin from Repo B.

**Build toolchain reminder (Android cross-compile):** swiftly shim is broken — host uses `xcrun swift`; cross-compile uses the `/Library` `swift-6.3.2-RELEASE` toolchain prepended to `PATH`. A fresh worktree needs `Scripts/android-build-libs.sh` to generate jextract bindings before `SwiftData`/JNI resolve. See memory `project_android_build_toolchain` and `project_android_library_wirelet_resolved_drift`.

---

## File Structure

**Repo A — swift-sheet-music**

| File | Responsibility | Action |
| --- | --- | --- |
| `Sources/SheetMusicCore/Score/Score+DisplayTransforms.swift` | Shared `filtered(hidingStaves:)` + `applying(clefOverrides:)` | Create (lift) |
| `Tests/SheetMusicTests/Score/ScoreDisplayTransformsTests.swift` | Tests for the lifted transforms | Create (lift) |
| `Sources/SheetMusicLayout/Layout/LayoutPaginator.swift` | Shared `paginate(systems:pageHeight:policy:)` | Create (lift) |
| `Tests/SheetMusicTests/Layout/LayoutPaginatorTests.swift` | Paginator tests | Create |
| `Sources/SheetMusicAndroidJNI/Layout/LayoutOptionsWire.swift` | `@WireFormat` options blob + decode helpers | Create |
| `Sources/SheetMusicAndroidJNI/Metadata/PartsStavesWire.swift` | `@WireFormat` parts/staves descriptor | Create |
| `Sources/SheetMusicAndroidJNI/LayoutBridge+Document.swift` | Build options per mode, transform, paginate, encode | Modify |
| `Sources/SheetMusicAndroidJNI/JNISymbols.swift` | `nativeComputeLayout` (+ options), `nativePartsStaves` | Modify |
| `Tests/SheetMusicTests/AndroidJNI/LayoutOptionsWireTests.swift` | Round-trip codec test | Create |
| `Android/SheetMusicAndroid/.../SheetMusicJNI.kt` | Kotlin façade: new param + new accessor | Modify |

**Repo A — iOS callers (in swift-sheet-music? No — these are in Folino)**: see Phase 2.

**Repo B — Folino (iOS side, same repo as Android)**

| File | Responsibility | Action |
| --- | --- | --- |
| `Packages/Features/Reader/Sources/Reader/Score+Filtered.swift` | iOS private copy of transform | Delete |
| `Packages/Features/Reader/Sources/Reader/Score+ApplyingClefOverrides.swift` | iOS private copy | Delete |
| `Packages/Features/Reader/Sources/Reader/Screens/Paged/PagedScoreContainer.swift` | Use shared paginator | Modify |
| Reader test files referencing the deleted transforms | Update imports / delete moved tests | Modify |

**Repo B — Folino Android**

| File | Responsibility | Action |
| --- | --- | --- |
| `Android/FolinoReaderAndroid/.../reader/ReaderLayoutMode.kt` | Kotlin layout-mode enum + `StaffAddress` value type | Create |
| `Android/FolinoReaderAndroid/.../reader/LayoutOptions.kt` | Kotlin options holder + blob encoder call | Create |
| `Android/FolinoReaderAndroid/.../reader/ReaderViewModel.kt` | Display StateFlows + recompute + parts/staves load | Modify |
| `Android/FolinoReaderAndroid/.../reader/DisplayInspectorSheet.kt` | The inspector UI (General + Parts + clef picker) | Create |
| `Android/FolinoReaderAndroid/.../reader/ClefChoice.kt` | Kotlin mirror of iOS `ClefMenuChoice` (codepoints) | Create |
| `Android/FolinoReaderAndroid/.../reader/ReaderScreen.kt` | TopAppBar trigger + 3 render modes | Modify |
| `Android/FolinoReaderAndroid/src/main/res/values*/strings.xml` | Localized strings (en/ja/ko/zh-Hans/zh-Hant) | Modify |
| `Packages/Features/Reader/Package.swift` + `project.yml` | swift-sheet-music pin bump | Modify |

---

# PHASE 1 — swift-sheet-music: shared logic + codecs

## Task 1: Lift `Score.filtered` / `Score.applying` into SheetMusicCore

**Files:**
- Create: `Sources/SheetMusicCore/Score/Score+DisplayTransforms.swift`
- Create: `Tests/SheetMusicTests/Score/ScoreDisplayTransformsTests.swift`
- (Folino, Phase 2) Delete the iOS copies.

- [ ] **Step 1: Move both transform functions verbatim into a public extension**

Create `Sources/SheetMusicCore/Score/Score+DisplayTransforms.swift`. Copy the bodies **verbatim** from the two Folino files below, change `func` → `public func`, and drop the `import SheetMusicCore` line (they now live in that module):
- `~/Developer/Personal/ios-apps/Folino-iOS/Packages/Features/Reader/Sources/Reader/Score+Filtered.swift` → `public func filtered(hidingStaves addresses: Set<StaffAddress>) -> Score`
- `~/Developer/Personal/ios-apps/Folino-iOS/Packages/Features/Reader/Sources/Reader/Score+ApplyingClefOverrides.swift` → `public func applying(clefOverrides: [StaffAddress: String]) -> Score`

Both bodies reference only `SheetMusicCore` types (`Score`, `Part`, `Staff`, `Clef`, `BracketItem`, `StaffAddress`), so they compile unchanged inside the module. Keep the existing doc comments.

- [ ] **Step 2: Write the failing tests (move the existing Reader tests)**

Find the existing iOS tests for these transforms (search Folino `Packages/Features/Reader/Tests` for `filtered(hidingStaves` and `applying(clefOverrides`). Move those test cases into `Tests/SheetMusicTests/Score/ScoreDisplayTransformsTests.swift`, adapting imports to `@testable import SheetMusicCore` (or `import SheetMusicCore` if the API is public). If no tests exist, write these:

```swift
import Testing
import SheetMusicCore

@Suite struct ScoreDisplayTransformsTests {
    @Test func filteringEmptyAddressesReturnsSameScore() {
        let score = TestScores.twoPartPiano()   // existing test fixture; pick the nearest one
        #expect(score.filtered(hidingStaves: []).parts.count == score.parts.count)
    }

    @Test func hidingAllStavesOfAPartDropsThePart() {
        let score = TestScores.twoPartPiano()
        let addr = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        let addr2 = StaffAddress(partIndex: 0, staffIndexInPart: 1)
        let filtered = score.filtered(hidingStaves: [addr, addr2])
        #expect(filtered.parts.count == score.parts.count - 1)
    }

    @Test func clefOverrideRewritesDefaultClefWhenNoExplicitClef() {
        let score = TestScores.twoPartPiano()
        let addr = StaffAddress(partIndex: 0, staffIndexInPart: 0)
        let out = score.applying(clefOverrides: [addr: "F"])
        // Either the measure-0 clef element or defaultClefType now reads "F".
        let staff = out.parts[0].staves[0]
        let firstClef: String? = {
            if case let .clef(c)? = staff.measures.first?.voices.first?.elements.first { return c.concertClefType }
            return staff.defaultClefType
        }()
        #expect(firstClef == "F")
    }
}
```

> Use the test fixtures that already exist in `Tests/SheetMusicTests` — replace `TestScores.twoPartPiano()` with whatever fixture builder the suite uses. Check a neighboring test file for the fixture API before writing.

- [ ] **Step 3: Run the tests — expect FAIL (or compile error) first if API not yet public**

Run from `~/Developer/Personal/swift-packages/swift-sheet-music` (host toolchain):
```
xcrun swift test --filter ScoreDisplayTransformsTests
```
Expected: FAIL/compile error until Step 1's file is `public`.

> Note: per memory `project_sheet_music_dev_clone_and_test_block`, the full `SheetMusicTests` target may not build locally because of Android JNI (jextract) deps. If `swift test` can't build the whole target, build just the source module to typecheck: `xcrun swift build --target SheetMusicCore`. Treat a green `SheetMusicCore` build as the gate and note the test-runner limitation in the commit.

- [ ] **Step 4: Make it pass** — confirm `public` modifiers from Step 1; re-run Step 3. Expected: PASS (or green `SheetMusicCore` build).

- [ ] **Step 5: Commit**

```
git add Sources/SheetMusicCore/Score/Score+DisplayTransforms.swift Tests/SheetMusicTests/Score/ScoreDisplayTransformsTests.swift
git commit -m "feat(core): lift Score.filtered/applying display transforms into SheetMusicCore"
```

## Task 2: Lift the page paginator into SheetMusicLayout

**Files:**
- Create: `Sources/SheetMusicLayout/Layout/LayoutPaginator.swift`
- Create: `Tests/SheetMusicTests/Layout/LayoutPaginatorTests.swift`

- [ ] **Step 1: Move the paginator verbatim into a public enum**

Open `~/Developer/Personal/ios-apps/Folino-iOS/Packages/Features/Reader/Sources/Reader/Screens/Paged/PagedScoreContainer.swift` and locate the private `static func paginate(systems:pageHeight:policy:) -> [Range<Int>]` (and any private helper it calls). Copy it **verbatim** into:

```swift
import Foundation
import SheetMusicCore   // for LayoutSystem / LayoutBreakPolicy if referenced

/// Splits a laid-out document's flat `systems` array into page ranges for page-mode
/// rendering. Lifted from the iOS PagedScoreContainer so iOS and the Android JNI
/// bridge produce identical page boundaries.
public enum LayoutPaginator {
    public static func paginate(
        systems: [LayoutSystem],
        pageHeight: CGFloat,
        policy: LayoutBreakPolicy,
    ) -> [Range<Int>] {
        // <verbatim body from PagedScoreContainer.paginate>
    }
}
```

Match the parameter names/types to the source exactly. If `LayoutSystem` / `LayoutBreakPolicy` live in `SheetMusicLayout` rather than `SheetMusicCore`, adjust the import (they are used by `LayoutEngine`, which is in `SheetMusicLayout`, so no extra import is likely needed).

- [ ] **Step 2: Write the failing test**

```swift
import Testing
import SheetMusicLayout
import SheetMusicCore

@Suite struct LayoutPaginatorTests {
    @Test func singleShortSystemYieldsOnePage() {
        let score = TestScores.twoPartPiano()
        let doc = LayoutEngine.layout(
            score: score,
            options: ScoreViewOptions(wrapToViewWidth: true, includeTitleFrame: true),
            availableWidth: 595,   // A4 width in pt
        )
        let pages = LayoutPaginator.paginate(systems: doc.systems, pageHeight: 842, policy: .honor)
        #expect(pages.count >= 1)
        #expect(pages.first?.lowerBound == 0)
    }

    @Test func pagesCoverAllSystemsContiguously() {
        let score = TestScores.manySystems()   // a fixture tall enough to paginate
        let doc = LayoutEngine.layout(
            score: score,
            options: ScoreViewOptions(wrapToViewWidth: true, includeTitleFrame: true),
            availableWidth: 595,
        )
        let pages = LayoutPaginator.paginate(systems: doc.systems, pageHeight: 300, policy: .honor)
        // Ranges are contiguous and cover [0, systems.count).
        var next = 0
        for r in pages { #expect(r.lowerBound == next); next = r.upperBound }
        #expect(next == doc.systems.count)
    }
}
```

- [ ] **Step 3: Run — expect FAIL first**
```
xcrun swift test --filter LayoutPaginatorTests
```
(Same test-runner caveat as Task 1 Step 3 — fall back to `xcrun swift build --target SheetMusicLayout`.)

- [ ] **Step 4: Make it pass** — adjust until green / module builds.

- [ ] **Step 5: Commit**
```
git add Sources/SheetMusicLayout/Layout/LayoutPaginator.swift Tests/SheetMusicTests/Layout/LayoutPaginatorTests.swift
git commit -m "feat(layout): lift page paginator into SheetMusicLayout.LayoutPaginator"
```

## Task 3: `LayoutOptionsWire` codec

**Files:**
- Create: `Sources/SheetMusicAndroidJNI/Layout/LayoutOptionsWire.swift`
- Create: `Tests/SheetMusicTests/AndroidJNI/LayoutOptionsWireTests.swift`

- [ ] **Step 1: Declare the `@WireFormat` options blob**

Mirror the `StaffAddressWire` / `ScoreMetadataWire` pattern (`@WireFormat` synthesizes encode/decode; the Wirelet Kotlin codegen produces the matching `LayoutOptionsWireCodec.kt`). Create:

```swift
import Foundation
import SheetMusicCore
import SheetMusicLayout
import Wirelet

/// Display settings passed from the Android Reader to the layout bridge across JNI.
///
/// Wire layout (derived from `@WireFormat`):
/// ```
/// u8  layoutMode            (0 = vertical, 1 = horizontal, 2 = page)
/// f64 staffSize
/// u8  honorLayoutBreaks     (0/1)
/// u8  collapseMultiMeasureRests (0/1)
/// u8  showsInvisibleElements (0/1)
/// [StaffAddressWire] hiddenStaves
/// [ClefOverrideWire]  clefOverrides
/// ```
@WireFormat
public struct LayoutOptionsWire {
    public var layoutMode: UInt8
    public var staffSize: Double
    public var honorLayoutBreaks: UInt8
    public var collapseMultiMeasureRests: UInt8
    public var showsInvisibleElements: UInt8
    public var hiddenStaves: [StaffAddressWire]
    public var clefOverrides: [ClefOverrideWire]
}

@WireFormat
public struct ClefOverrideWire {
    public var address: StaffAddressWire
    public var rawType: String
}
```

`StaffAddressWire` is `internal` today (`Sources/SheetMusicAndroidJNI/Audio/StaffAddressCodec.swift`). Make it `public` (and its `init(from:)` / `decoded()`), or reuse it as-is if same-module. Both new types are in the same module (`SheetMusicAndroidJNI`), so no access bump is needed for cross-module use — keep them `public` for the Kotlin codegen surface.

- [ ] **Step 2: Add decode helpers that map the wire to engine types**

In the same file:

```swift
public extension LayoutOptionsWire {
    var hiddenStaffAddresses: Set<StaffAddress> {
        Set(hiddenStaves.map { $0.decoded() })
    }
    var clefOverrideMap: [StaffAddress: String] {
        Dictionary(uniqueKeysWithValues: clefOverrides.map { ($0.address.decoded(), $0.rawType) })
    }
    /// Maps the wire enum byte to `ReaderLayoutMode`-equivalent behavior. swift-sheet-music
    /// has no ReaderLayoutMode (that's Domain), so use a local enum.
    enum Mode: UInt8 { case vertical = 0, horizontal = 1, page = 2 }
    var mode: Mode { Mode(rawValue: layoutMode) ?? .vertical }
}

public enum LayoutOptionsCodec {
    public static func decode(_ data: Data) throws -> LayoutOptionsWire {
        try LayoutOptionsWire(decoding: data)
    }
}
```

- [ ] **Step 3: Write the round-trip test**

```swift
import Testing
import Foundation
@testable import SheetMusicAndroidJNI
import SheetMusicCore

@Suite struct LayoutOptionsWireTests {
    @Test func roundTripsAllFields() throws {
        let wire = LayoutOptionsWire(
            layoutMode: 2,
            staffSize: 18.5,
            honorLayoutBreaks: 1,
            collapseMultiMeasureRests: 0,
            showsInvisibleElements: 1,
            hiddenStaves: [StaffAddressWire(from: StaffAddress(partIndex: 1, staffIndexInPart: 0))],
            clefOverrides: [ClefOverrideWire(
                address: StaffAddressWire(from: StaffAddress(partIndex: 0, staffIndexInPart: 1)),
                rawType: "F8va",
            )],
        )
        let decoded = try LayoutOptionsCodec.decode(wire.encodeToData())
        #expect(decoded.staffSize == 18.5)
        #expect(decoded.mode == .page)
        #expect(decoded.showsInvisibleElements == 1)
        #expect(decoded.hiddenStaffAddresses == [StaffAddress(partIndex: 1, staffIndexInPart: 0)])
        #expect(decoded.clefOverrideMap == [StaffAddress(partIndex: 0, staffIndexInPart: 1): "F8va"])
    }
}
```

- [ ] **Step 4: Run — expect FAIL then PASS**
```
xcrun swift test --filter LayoutOptionsWireTests
```
(If the AndroidJNI target can't host-build because of jextract, build it for the Android triple per the toolchain note, or assert the codec compiles via `xcrun swift build --target SheetMusicAndroidJNI`. Capture which gate was used.)

- [ ] **Step 5: Commit**
```
git add Sources/SheetMusicAndroidJNI/Layout/LayoutOptionsWire.swift Tests/SheetMusicTests/AndroidJNI/LayoutOptionsWireTests.swift Sources/SheetMusicAndroidJNI/Audio/StaffAddressCodec.swift
git commit -m "feat(jni): LayoutOptionsWire codec for display-inspector settings"
```

## Task 4: Parts/staves metadata accessor

**Files:**
- Create: `Sources/SheetMusicAndroidJNI/Metadata/PartsStavesWire.swift`
- Modify: `Sources/SheetMusicAndroidJNI/JNISymbols.swift`

- [ ] **Step 1: Declare the descriptor wire**

```swift
import Foundation
import SheetMusicCore
import Wirelet

/// Per-part / per-staff descriptor the Android inspector uses to enumerate staves
/// for the Parts section (visibility + clef-override controls). Returned by
/// `nativePartsStaves`.
@WireFormat
public struct PartsStavesWire {
    public var parts: [PartWire]
}

@WireFormat
public struct PartWire {
    public var name: String
    public var staves: [StaffWire]
}

@WireFormat
public struct StaffWire {
    /// The staff's authored/default clef rawType (e.g. "G", "F"), or "" when none.
    public var defaultClefRawType: String
}

public extension PartsStavesWire {
    init(score: Score) {
        parts = score.parts.map { part in
            PartWire(
                name: part.partName ?? "",   // match Part's display-name property; verify field name
                staves: part.staves.map { StaffWire(defaultClefRawType: $0.defaultClefType ?? "") },
            )
        }
    }
}
```

> Verify the `Part` display-name property name and `Staff.defaultClefType` optionality against `SheetMusicCore` before writing — adjust `part.partName` / `$0.defaultClefType` to the real API. (Open `Sources/SheetMusicCore/Score/Part.swift` and `Staff.swift`.)

- [ ] **Step 2: Add the JNI entry point**

In `Sources/SheetMusicAndroidJNI/JNISymbols.swift`, after `nativeOpeningQuarterBpm`:

```swift
/// JNI entry point for `SheetMusicJNI.nativePartsStaves(...)`. Returns the parts/staves
/// descriptor (names + staff counts + default clef) for building the inspector's Parts
/// section. Empty `Data` when the handle is unknown.
public func nativePartsStaves(scoreHandle: Int64) -> Data {
    guard let score = scoreTable.value(for: scoreHandle) else { return Data() }
    return PartsStavesWire(score: score).encodeToData()
}
```

- [ ] **Step 3: Add the Kotlin façade method**

In `Android/SheetMusicAndroid/.../SheetMusicJNI.kt`, mirror `nativeScoreMetadata`:

```kotlin
/**
 * Parts/staves descriptor for the Reader display inspector's Parts section:
 * per part a name and the staff count (+ each staff's default clef rawType).
 * Empty array for an unknown handle. Decode via the generated PartsStavesWireCodec.
 */
fun nativePartsStaves(handle: Long): ByteArray {
    val arena = SwiftMemoryManagement.DEFAULT_SWIFT_JAVA_AUTO_ARENA
    return SwiftJavaJNI.nativePartsStaves(handle, arena).toByteArray()
}
```

- [ ] **Step 4: Build the JNI module (host typecheck)**
```
xcrun swift build --target SheetMusicAndroidJNI
```
Expected: builds clean. (Kotlin side compiles after Task 7 regen.)

- [ ] **Step 5: Commit**
```
git add Sources/SheetMusicAndroidJNI/Metadata/PartsStavesWire.swift Sources/SheetMusicAndroidJNI/JNISymbols.swift Android/SheetMusicAndroid/src/main/kotlin/io/github/jiyimeta/sheetmusic/SheetMusicJNI.kt
git commit -m "feat(jni): nativePartsStaves accessor for inspector Parts section"
```

## Task 5: Extend `nativeComputeLayout` with options + mode-specific layout

**Files:**
- Modify: `Sources/SheetMusicAndroidJNI/LayoutBridge+Document.swift`
- Modify: `Sources/SheetMusicAndroidJNI/JNISymbols.swift`
- Modify: `Android/SheetMusicAndroid/.../SheetMusicJNI.kt`

- [ ] **Step 1: Rewrite `computeWithDocument` to take options and branch per mode**

Replace the body of `Sources/SheetMusicAndroidJNI/LayoutBridge+Document.swift`:

```swift
import Foundation
import SheetMusicCore
import SheetMusicLayout

extension LayoutBridge {
    /// Lay out `score` under the supplied display `options` and return the
    /// `LayoutDocument` (cursor-frame lookups reuse it) plus the encoded multi-page
    /// draw program. Vertical/horizontal emit one page; page mode emits N pages.
    public static func computeWithDocument(
        score: Score,
        pageWidthMM: Double,
        pageHeightMM: Double,
        options optionsWire: LayoutOptionsWire,
    ) -> (document: LayoutDocument, encoded: Data) {
        let mmToPt = 72.0 / 25.4
        let ptToMM = 25.4 / 72.0
        let pageWidthPt = pageWidthMM * mmToPt
        let pageHeightPt = pageHeightMM * mmToPt

        // Apply clef overrides BEFORE hiding staves (the override map is keyed on the
        // pre-filter staff address — see Score+DisplayTransforms doc comment).
        let prepared = score
            .applying(clefOverrides: optionsWire.clefOverrideMap)
            .filtered(hidingStaves: optionsWire.hiddenStaffAddresses)

        let staffSize = CGFloat(optionsWire.staffSize)
        let breakPolicy: LayoutBreakPolicy = optionsWire.honorLayoutBreaks == 1 ? .honor : .ignoreAll
        let mmrPolicy: MultiMeasureRestPolicy = optionsWire.collapseMultiMeasureRests == 1
            ? .collapse(minimumMeasures: 2)
            : .disabled
        let showInvisible = optionsWire.showsInvisibleElements == 1

        switch optionsWire.mode {
        case .vertical:
            let opts = ScoreViewOptions(
                staffSize: staffSize, systemGap: staffSize * 1.25,
                wrapToViewWidth: true, includeTitleFrame: true,
                breakPolicy: breakPolicy, breakIndicatorVisibility: .none,
                multiMeasureRest: mmrPolicy, showsInvisibleElements: showInvisible,
            )
            let layout = LayoutEngine.layout(score: prepared, options: opts, availableWidth: pageWidthPt)
            let page = EncodablePage(
                widthMM: layout.size.width * ptToMM,
                heightMM: layout.size.height * ptToMM,
                commands: buildCommands(layout: layout),
            )
            return (layout, DrawProgramCodec.encode(pages: [page]))

        case .horizontal:
            let opts = ScoreViewOptions(
                staffSize: staffSize, systemGap: staffSize * 1.25,
                wrapToViewWidth: false, includeTitleFrame: false,
                breakPolicy: breakPolicy, breakIndicatorVisibility: .none,
                multiMeasureRest: mmrPolicy, showsInvisibleElements: showInvisible,
            )
            let natural = LayoutEngine.naturalContentWidth(score: prepared, options: opts)
            let layout = LayoutEngine.layout(score: prepared, options: opts, availableWidth: natural)
            let page = EncodablePage(
                widthMM: layout.size.width * ptToMM,
                heightMM: layout.size.height * ptToMM,
                commands: buildCommands(layout: layout),
            )
            return (layout, DrawProgramCodec.encode(pages: [page]))

        case .page:
            let opts = ScoreViewOptions(
                staffSize: staffSize, systemGap: staffSize * 1.25,
                wrapToViewWidth: true, includeTitleFrame: true,
                breakPolicy: breakPolicy, breakIndicatorVisibility: .none,
                multiMeasureRest: mmrPolicy, showsInvisibleElements: showInvisible,
            )
            let layout = LayoutEngine.layout(score: prepared, options: opts, availableWidth: pageWidthPt)
            let ranges = LayoutPaginator.paginate(
                systems: layout.systems, pageHeight: pageHeightPt, policy: breakPolicy,
            )
            let pages: [EncodablePage] = ranges.map { range in
                // Y offset so each page's first system sits at the page top: clip at the
                // previous page's last-system bottom (0 for the first page).
                let pageTop = range.lowerBound == 0
                    ? 0
                    : layout.systems[range.lowerBound - 1].origin.y
                        + layout.systems[range.lowerBound - 1].size.height
                let sub = layout.subdocument(systems: range, yOffset: -pageTop)
                return EncodablePage(
                    widthMM: pageWidthMM,
                    heightMM: pageHeightMM,
                    commands: buildCommands(layout: sub),
                )
            }
            return (layout, DrawProgramCodec.encode(pages: pages))
        }
    }
}
```

> Two API points to verify/implement against `SheetMusicLayout`:
> 1. `LayoutEngine.naturalContentWidth(score:options:)` — confirmed used by the iOS `HorizontalScoreContainer`; confirm the exact label.
> 2. `layout.subdocument(systems:yOffset:)` — a `LayoutDocument` slice that selects `systems[range]` and shifts their origins by `yOffset`. If this helper does not exist, add it to `LayoutDocument` (in `SheetMusicLayout`) as a small public method and unit-test it; the iOS Paged container does the equivalent slice (`doc.systems[pageRange]` + `.offset(y: -pageStartY)`) at render time — lift that slicing into the shared helper so both platforms share it.

- [ ] **Step 1b: If needed, add `LayoutDocument.subdocument`**

If Step 1's `subdocument` helper is missing, add to `Sources/SheetMusicLayout/.../LayoutDocument.swift`:

```swift
public extension LayoutDocument {
    /// A document containing only `systems[range]`, with each system's origin shifted by
    /// `yOffset` (use a negative value to lift a page's first system to y = 0). `size` is
    /// recomputed to the shifted content bounds.
    func subdocument(systems range: Range<Int>, yOffset: CGFloat) -> LayoutDocument {
        let slice = systems[range].map { sys -> LayoutSystem in
            var s = sys
            s.origin = CGPoint(x: s.origin.x, y: s.origin.y + yOffset)
            return s
        }
        let height = slice.map { $0.origin.y + $0.size.height }.max() ?? 0
        return LayoutDocument(size: CGSize(width: size.width, height: height),
                              systems: slice, metrics: metrics, titleFrame: nil)
    }
}
```

> Verify `LayoutSystem.origin` is settable and `LayoutDocument`'s memberwise init is accessible; adjust to the real initializer. Add a small `LayoutDocumentTests.subdocumentShiftsOrigins` test.

- [ ] **Step 2: Update the JNI entry point signature**

In `JNISymbols.swift`, replace `nativeComputeLayout`:

```swift
public func nativeComputeLayout(
    scoreHandle: Int64,
    pageWidthMM: Double,
    pageHeightMM: Double,
    optionsBlob: Data,
) -> Data {
    guard let score = scoreTable.value(for: scoreHandle) else { return Data() }
    let optionsWire: LayoutOptionsWire
    do { optionsWire = try LayoutOptionsCodec.decode(optionsBlob) } catch { return Data() }
    let result = LayoutBridge.computeWithDocument(
        score: score, pageWidthMM: pageWidthMM, pageHeightMM: pageHeightMM, options: optionsWire,
    )
    LayoutDocumentCache.store(handle: scoreHandle, document: result.document)
    return result.encoded
}
```

- [ ] **Step 3: Update the Kotlin façade signature**

In `SheetMusicJNI.kt`, change `nativeComputeLayout`:

```kotlin
/** Returns an empty array on failure (invalid handle or undecodable options). */
fun nativeComputeLayout(
    scoreHandle: Long,
    pageWidthMM: Double,
    pageHeightMM: Double,
    optionsBlob: ByteArray,
): ByteArray {
    val arena = SwiftMemoryManagement.DEFAULT_SWIFT_JAVA_AUTO_ARENA
    return SwiftJavaJNI.nativeComputeLayout(
        scoreHandle, pageWidthMM, pageHeightMM,
        SwiftData.fromByteArray(optionsBlob, arena),
        arena,
    ).toByteArray()
}
```

- [ ] **Step 4: Build the Swift side (host typecheck)**
```
xcrun swift build --target SheetMusicAndroidJNI
```
Expected: builds clean.

- [ ] **Step 5: Commit**
```
git add Sources/SheetMusicAndroidJNI/LayoutBridge+Document.swift Sources/SheetMusicAndroidJNI/JNISymbols.swift Sources/SheetMusicLayout Android/SheetMusicAndroid/src/main/kotlin/io/github/jiyimeta/sheetmusic/SheetMusicJNI.kt
git commit -m "feat(jni): nativeComputeLayout honors display options + page-mode pagination"
```

## Task 6: Build `.so` + regenerate jextract bindings & Wirelet Kotlin codecs

**Files:** generated artifacts only (gitignored where applicable).

- [ ] **Step 1: Regenerate jextract bindings + Wirelet Kotlin codecs**

The `nativeComputeLayout` signature changed and `LayoutOptionsWire` / `PartsStavesWire` are new `@WireFormat` types — the jextract bindings and `*Codec.kt` must regenerate. From the swift-sheet-music worktree, run the project's Android build/codegen entry point (per `project_android_build_toolchain`): prepend the `/Library` `swift-6.3.2-RELEASE` toolchain to `PATH`, then run the Gradle codegen + the cross-compile that produces `libSheetMusicAndroidJNI.so`.

Run (adjust to the repo's actual script — check `Scripts/` and the Gradle `wirelet`/`jextract` tasks):
```
~/Developer/Personal/swift-packages/swift-sheet-music/Scripts/android-build-libs.sh
```

- [ ] **Step 2: Verify generated surface**

Confirm these exist and have the new shapes:
- `Android/SheetMusicAndroid/build/generated/wirelet/.../LayoutOptionsWireCodec.kt` (with `encode`) and `PartsStavesWireCodec.kt` (with `decode`).
- The generated `SheetMusicAndroidJNI.java` `nativeComputeLayout` now takes the extra `Data optionsBlob` param and `nativePartsStaves` exists.

Run:
```
ls ~/Developer/Personal/swift-packages/swift-sheet-music/Android/SheetMusicAndroid/build/generated/wirelet/main/kotlin/io/github/jiyimeta/sheetmusic/ | grep -i 'LayoutOptions\|PartsStaves'
```
Expected: both codec files listed.

- [ ] **Step 3: Commit (only the tracked artifacts; generated dirs are gitignored)**
```
git add -A
git commit -m "chore(android): regenerate jextract bindings + Wirelet codecs for display options"
```
(If `git status` shows nothing tracked changed because all generated output is gitignored, skip the commit and note it.)

- [ ] **Step 4: Push swift-sheet-music branch / capture the revision**

Record the resulting commit SHA — Phase 3 re-pins Folino to it. (Do not `push` without confirmation per ground rules; capture the local SHA for the pin.)

---

# PHASE 2 — Folino iOS: adopt shared transforms (parity, no behavior change)

## Task 7: Point the iOS Reader at the shared transforms + paginator

**Files:**
- Delete: `Packages/Features/Reader/Sources/Reader/Score+Filtered.swift`
- Delete: `Packages/Features/Reader/Sources/Reader/Score+ApplyingClefOverrides.swift`
- Modify: `Packages/Features/Reader/Sources/Reader/Screens/Paged/PagedScoreContainer.swift`
- Modify/Delete: the moved transform tests in the Reader test target

> Do this only after Task 6 captured the swift-sheet-music revision and Task 8 re-pins (or pin first, then this task — see Task 8). Order: Task 8 (pin) → Task 7 (delete + adopt), so the shared symbols resolve.

- [ ] **Step 1: Delete the two iOS transform files**
```
git rm Packages/Features/Reader/Sources/Reader/Score+Filtered.swift Packages/Features/Reader/Sources/Reader/Score+ApplyingClefOverrides.swift
```
The call sites (e.g. `ReaderRootScreen.swift`'s `score.applying(clefOverrides:).filtered(hidingStaves:)`) now resolve to the `SheetMusicCore` versions — the Reader already imports `SheetMusicCore` (via Domain's re-export or directly). Add `import SheetMusicCore` to any file that fails to resolve.

- [ ] **Step 2: Replace the iOS paginator with the shared one**

In `PagedScoreContainer.swift`, delete the private `paginate(...)` and its helpers; call `LayoutPaginator.paginate(systems:pageHeight:policy:)` (add `import SheetMusicLayout` if missing). Keep the render-time page slicing, or switch it to `LayoutDocument.subdocument(systems:yOffset:)` for parity with Android.

- [ ] **Step 3: Move/adjust the transform tests**

Any Reader test exercising `filtered`/`applying` now belongs to swift-sheet-music (moved in Task 1). Delete the duplicates from the Reader test target; keep any Reader-specific integration test that still compiles.

- [ ] **Step 4: Build the Folino app + Reader tests**

Per memory `project_package_test_command` (use iPhone 17 sim, `swift test` is broken by the SwiftLint plugin):
```
xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 16' -skipPackagePluginValidation build
```
Expected: build succeeds; the Paged/Visual inspector behavior is unchanged.

- [ ] **Step 5: Commit**
```
git add -A
git commit -m "refactor(reader-ios): use shared SheetMusicCore transforms + LayoutPaginator"
```

## Task 8: Re-pin swift-sheet-music

**Files:**
- Modify: `Packages/Features/Reader/Package.swift`
- Modify: `project.yml`

- [ ] **Step 1: Bump the pin to the Task 6 revision**

Update the swift-sheet-music dependency revision/`from:` in both `Packages/Features/Reader/Package.swift` and the `packages:` entry in `project.yml` to the SHA captured in Task 6 Step 4. (For a local-only revision, use `.package(url:, revision: "<sha>")` consistently, or a local path pin if the team flow uses one. Follow the existing pin style in those files.)

- [ ] **Step 2: Resolve + regenerate the Xcode project**
```
xcodegen generate
```
- [ ] **Step 3: Verify resolution** — open `Package.resolved` and confirm the new revision. (Per memory `project_android_library_wirelet_resolved_drift`, stale `Package.resolved`/`.so` is a known drift trap; ensure the resolve actually moved.)

- [ ] **Step 4: Commit**
```
git add Packages/Features/Reader/Package.swift project.yml Packages/Features/Reader/Package.resolved
git commit -m "build: re-pin swift-sheet-music to display-options revision"
```

---

# PHASE 3 — Folino Android: state, UI, rendering

## Task 9: Kotlin layout-mode enum + StaffAddress value type

**Files:**
- Create: `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderLayoutMode.kt`

- [ ] **Step 1: Create the enum + value type**

```kotlin
package com.keynumber.folino.reader

/** Mirrors Domain `ReaderLayoutMode`. Wire byte: vertical=0, horizontal=1, page=2. */
enum class ReaderLayoutMode(val wire: Int) {
    VERTICAL(0), HORIZONTAL(1), PAGE(2),
}

/** Positional staff address: parts[partIndex].staves[staffIndexInPart]. Mirrors Swift StaffAddress. */
data class StaffAddress(val partIndex: Int, val staffIndexInPart: Int)
```

- [ ] **Step 2: Build the Android module** (sanity compile — full build happens in Task 14)

No standalone test here; covered by Task 14's build.

- [ ] **Step 3: Commit**
```
git add Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderLayoutMode.kt
git commit -m "feat(reader-android): layout-mode enum + StaffAddress value type"
```

## Task 10: Kotlin options holder + blob encoder

**Files:**
- Create: `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/LayoutOptions.kt`

- [ ] **Step 1: Create the holder + encoder**

Uses the generated `LayoutOptionsWireCodec` / `StaffAddressWireCodec` / `ClefOverrideWireCodec` from Task 6 (package `io.github.jiyimeta.sheetmusic`). Verify the generated codec/class names and constructor shapes, then:

```kotlin
package com.keynumber.folino.reader

import io.github.jiyimeta.sheetmusic.LayoutOptionsWire
import io.github.jiyimeta.sheetmusic.LayoutOptionsWireCodec
import io.github.jiyimeta.sheetmusic.StaffAddressWire
import io.github.jiyimeta.sheetmusic.ClefOverrideWire

/** Immutable snapshot of the display settings, encodable to the JNI options blob. */
data class LayoutOptions(
    val mode: ReaderLayoutMode = ReaderLayoutMode.VERTICAL,
    val staffSize: Double = 28.0,
    val honorLayoutBreaks: Boolean = true,
    val collapseMultiMeasureRests: Boolean = false,
    val showInvisibleElements: Boolean = false,
    val hiddenStaves: Set<StaffAddress> = emptySet(),
    val clefOverrides: Map<StaffAddress, String> = emptyMap(),
) {
    fun encode(): ByteArray = LayoutOptionsWireCodec.encode(
        LayoutOptionsWire(
            layoutMode = mode.wire.toUByte(),     // match generated field type (UByte/Int)
            staffSize = staffSize,
            honorLayoutBreaks = if (honorLayoutBreaks) 1u else 0u,
            collapseMultiMeasureRests = if (collapseMultiMeasureRests) 1u else 0u,
            showsInvisibleElements = if (showInvisibleElements) 1u else 0u,
            hiddenStaves = hiddenStaves.map { StaffAddressWire(it.partIndex, it.staffIndexInPart) },
            clefOverrides = clefOverrides.map { (addr, raw) ->
                ClefOverrideWire(StaffAddressWire(addr.partIndex, addr.staffIndexInPart), raw)
            },
        ),
    )
}
```

> The generated Kotlin field types (UByte vs Int, list element constructors) must match exactly — adjust `.toUByte()`/`1u` and constructor args after reading the generated `LayoutOptionsWireCodec.kt`.

- [ ] **Step 2: Commit**
```
git add Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/LayoutOptions.kt
git commit -m "feat(reader-android): LayoutOptions holder + JNI blob encoder"
```

## Task 11: Display state + recompute in `ReaderViewModel`

**Files:**
- Modify: `Android/FolinoReaderAndroid/.../reader/ReaderViewModel.kt`

- [ ] **Step 1: Add display StateFlows, the parts/staves descriptor, and a debounced recompute**

Add to `ReaderViewModel`:

```kotlin
// ── Display settings (session-transient) ───────────────────────────
private val _layoutOptions = MutableStateFlow(LayoutOptions())
val layoutOptions: StateFlow<LayoutOptions> = _layoutOptions.asStateFlow()

// Parts/staves descriptor for the inspector's Parts section.
private val _parts = MutableStateFlow<List<PartDescriptor>>(emptyList())
val parts: StateFlow<List<PartDescriptor>> = _parts.asStateFlow()

private var pageWidthMM = PAGE_WIDTH_MM
private var pageHeightMM = PAGE_HEIGHT_MM
private var recomputeJob: Job? = null

fun update(transform: (LayoutOptions) -> LayoutOptions) {
    _layoutOptions.value = transform(_layoutOptions.value)
    scheduleRecompute()
}

/** Page mode needs the live viewport; ReaderScreen pushes it on size change. */
fun setViewport(widthMM: Double, heightMM: Double) {
    if (widthMM == pageWidthMM && heightMM == pageHeightMM) return
    pageWidthMM = widthMM; pageHeightMM = heightMM
    scheduleRecompute()
}

private fun scheduleRecompute() {
    val h = handle ?: return
    recomputeJob?.cancel()
    recomputeJob = viewModelScope.launch {
        delay(120)   // debounce rapid slider drags
        val blob = _layoutOptions.value.encode()
        val bytes = withContext(Dispatchers.Default) {
            SheetMusicJNI.nativeComputeLayout(h.raw, pageWidthMM, pageHeightMM, blob)
        }
        if (bytes.isEmpty()) return@launch
        val program = try { DrawProgramReader.decode(bytes) } catch (e: Exception) { return@launch }
        _state.value = ReaderState.Ready(program)
    }
}
```

Add a `PartDescriptor` type (top of file or in `ReaderLayoutMode.kt`):
```kotlin
data class StaffDescriptor(val address: StaffAddress, val defaultClefRawType: String)
data class PartDescriptor(val name: String, val staves: List<StaffDescriptor>)
```

- [ ] **Step 2: Load the initial layout via the blob + populate `parts`**

In `load(...)`, replace the hardcoded `nativeComputeLayout(h.raw, PAGE_WIDTH_MM, PAGE_HEIGHT_MM)` call:

```kotlin
val blob = _layoutOptions.value.encode()
val programBytes = withContext(Dispatchers.Default) {
    SheetMusicJNI.nativeComputeLayout(h.raw, pageWidthMM, pageHeightMM, blob)
}
// ... existing empty/decoded handling ...

// Parts descriptor for the inspector.
_parts.value = withContext(Dispatchers.Default) {
    val pb = SheetMusicJNI.nativePartsStaves(h.raw)
    if (pb.isEmpty()) emptyList()
    else PartsStavesWireCodec.decode(pb).parts.mapIndexed { pi, part ->
        PartDescriptor(
            name = part.name,
            staves = part.staves.mapIndexed { si, st ->
                StaffDescriptor(StaffAddress(pi, si), st.defaultClefRawType)
            },
        )
    }
}
```

Add imports: `kotlinx.coroutines.Job`, `kotlinx.coroutines.delay`, `io.github.jiyimeta.sheetmusic.PartsStavesWireCodec`.

- [ ] **Step 3: Commit**
```
git add Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderViewModel.kt Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderLayoutMode.kt
git commit -m "feat(reader-android): display StateFlows + debounced re-layout + parts descriptor"
```

## Task 12: Clef choice mirror + clef glyph picker

**Files:**
- Create: `Android/FolinoReaderAndroid/.../reader/ClefChoice.kt`

- [ ] **Step 1: Mirror iOS `ClefMenuChoice` (rawType, codepoint, families)**

```kotlin
package com.keynumber.folino.reader

/** Kotlin mirror of iOS ClefMenuChoice. Glyph is a SMuFL Bravura PUA codepoint. */
enum class ClefChoice(val rawType: String, val glyph: Int, val labelKey: Int) {
    TREBLE_G("G", 0xE050, R.string.reader_clef_treble),
    TREBLE_G8VA("G8va", 0xE053, R.string.reader_clef_treble8va),
    TREBLE_G8VB("G8vb", 0xE052, R.string.reader_clef_treble8vb),
    TREBLE_G15MA("G15ma", 0xE054, R.string.reader_clef_treble15ma),
    TREBLE_G15MB("G15mb", 0xE051, R.string.reader_clef_treble15mb),
    BASS_F("F", 0xE062, R.string.reader_clef_bass),
    BASS_F8VA("F8va", 0xE065, R.string.reader_clef_bass8va),
    BASS_F8VB("F8vb", 0xE064, R.string.reader_clef_bass8vb),
    SOPRANO_C1("C1", 0xE05C, R.string.reader_clef_soprano),
    ALTO_C3("C3", 0xE05C, R.string.reader_clef_alto),
    TENOR_C4("C4", 0xE05C, R.string.reader_clef_tenor),
    BARITONE_C5("C5", 0xE05C, R.string.reader_clef_baritone),
    PERCUSSION("PERC", 0xE069, R.string.reader_clef_percussion),
    PERCUSSION2("PERC2", 0xE06A, R.string.reader_clef_percussion2);

    val isPercussion get() = this == PERCUSSION || this == PERCUSSION2

    companion object {
        fun fromRawType(raw: String): ClefChoice? = entries.firstOrNull { it.rawType == raw }
        val trebleFamily = listOf(TREBLE_G, TREBLE_G8VA, TREBLE_G8VB, TREBLE_G15MA, TREBLE_G15MB)
        val bassFamily = listOf(BASS_F, BASS_F8VA, BASS_F8VB)
        val cFamily = listOf(SOPRANO_C1, ALTO_C3, TENOR_C4, BARITONE_C5)
        val percussionFamily = listOf(PERCUSSION, PERCUSSION2)
    }
}
```

- [ ] **Step 2: Commit** (strings added in Task 15; this compiles after Task 15 or stub the R.string first)
```
git add Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ClefChoice.kt
git commit -m "feat(reader-android): clef-choice mirror with SMuFL codepoints"
```

## Task 13: `DisplayInspectorSheet` Compose

**Files:**
- Create: `Android/FolinoReaderAndroid/.../reader/DisplayInspectorSheet.kt`

- [ ] **Step 1: Build the sheet (General + Parts), mirroring PlaybackInspectorSheet density**

Render the music-font glyphs with the bundled SMuFL typeface. Get a Compose `FontFamily` from the existing `bundledFontProvider`/Bravura asset (the renderer already loads Bravura — reuse the same asset path; check `bundledFontProvider`'s font file).

```kotlin
package com.keynumber.folino.reader

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.clickable
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import kotlin.math.roundToInt

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DisplayInspectorSheet(
    readerVm: ReaderViewModel,
    sheetState: SheetState,
    onDismiss: () -> Unit,
) {
    val options by readerVm.layoutOptions.collectAsStateWithLifecycle()
    val parts by readerVm.parts.collectAsStateWithLifecycle()
    var generalExpanded by rememberSaveable { mutableStateOf(true) }
    var partsExpanded by rememberSaveable { mutableStateOf(true) }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState) {
        LazyColumn(Modifier.fillMaxWidth().padding(horizontal = 16.dp).padding(bottom = 24.dp)) {
            // ── General ──────────────────────────────────────────────
            item {
                CollapsibleHeader(stringResource(R.string.reader_inspector_general), generalExpanded) {
                    generalExpanded = !generalExpanded
                }
            }
            if (generalExpanded) {
                item { LayoutModeSegmented(options.mode) { m -> readerVm.update { it.copy(mode = m) } } }
                item {
                    StaffSizeRow(options.staffSize) { v -> readerVm.update { it.copy(staffSize = v) } }
                }
                item {
                    SwitchRow(stringResource(R.string.reader_pref_honor_breaks), options.honorLayoutBreaks) { on ->
                        readerVm.update { it.copy(honorLayoutBreaks = on) }
                    }
                }
                item {
                    SwitchRow(stringResource(R.string.reader_pref_collapse_rests), options.collapseMultiMeasureRests) { on ->
                        readerVm.update { it.copy(collapseMultiMeasureRests = on) }
                    }
                }
                item {
                    SwitchRow(stringResource(R.string.reader_pref_show_invisible), options.showInvisibleElements) { on ->
                        readerVm.update { it.copy(showInvisibleElements = on) }
                    }
                }
            }

            item { HorizontalDivider(Modifier.padding(vertical = 4.dp)) }

            // ── Parts ────────────────────────────────────────────────
            item {
                CollapsibleHeader(stringResource(R.string.reader_inspector_parts), partsExpanded) {
                    partsExpanded = !partsExpanded
                }
            }
            if (partsExpanded) {
                parts.forEach { part ->
                    item { Text(part.name.ifEmpty { stringResource(R.string.reader_part_untitled) },
                        style = MaterialTheme.typography.labelLarge, modifier = Modifier.padding(top = 6.dp)) }
                    items(part.staves, key = { "${it.address.partIndex}-${it.address.staffIndexInPart}" }) { staff ->
                        StaffRow(
                            staff = staff,
                            hidden = options.hiddenStaves.contains(staff.address),
                            effectiveClefRaw = options.clefOverrides[staff.address] ?: staff.defaultClefRawType,
                            onToggleHidden = {
                                readerVm.update {
                                    val next = it.hiddenStaves.toMutableSet()
                                    if (!next.add(staff.address)) next.remove(staff.address)
                                    it.copy(hiddenStaves = next)
                                }
                            },
                            onClef = { raw ->
                                readerVm.update {
                                    val next = it.clefOverrides.toMutableMap()
                                    if (raw == null) next.remove(staff.address) else next[staff.address] = raw
                                    it.copy(clefOverrides = next)
                                }
                            },
                        )
                    }
                }
            }
        }
    }
}
```

- [ ] **Step 2: Add the row sub-composables**

`CollapsibleHeader` is identical to PlaybackInspectorSheet's — extract a shared one or copy it. Then:

```kotlin
@Composable
private fun LayoutModeSegmented(mode: ReaderLayoutMode, onSelect: (ReaderLayoutMode) -> Unit) {
    val modes = ReaderLayoutMode.entries
    SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth().padding(vertical = 4.dp)) {
        modes.forEachIndexed { i, m ->
            SegmentedButton(
                selected = m == mode,
                onClick = { onSelect(m) },
                shape = SegmentedButtonDefaults.itemShape(index = i, count = modes.size),
            ) { Text(stringResource(when (m) {
                ReaderLayoutMode.VERTICAL -> R.string.reader_layout_vertical
                ReaderLayoutMode.HORIZONTAL -> R.string.reader_layout_horizontal
                ReaderLayoutMode.PAGE -> R.string.reader_layout_page
            })) }
        }
    }
}

@Composable
private fun StaffSizeRow(value: Double, onChange: (Double) -> Unit) {
    Row(Modifier.fillMaxWidth().padding(vertical = 2.dp), verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(stringResource(R.string.reader_pref_staff_size), Modifier.width(96.dp),
            style = MaterialTheme.typography.bodyMedium)
        Slider(
            value = value.toFloat(), onValueChange = { onChange(it.toDouble()) },
            valueRange = 8f..28f, modifier = Modifier.weight(1f).height(24.dp),
        )
        Text("${value.roundToInt()} pt", Modifier.width(48.dp), style = MaterialTheme.typography.bodySmall)
    }
}

@Composable
private fun SwitchRow(label: String, checked: Boolean, onChange: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth().padding(vertical = 2.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(label, Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium)
        Switch(checked = checked, onCheckedChange = onChange)
    }
}
```

- [ ] **Step 3: Add the staff row with eye toggle + clef glyph picker**

```kotlin
@Composable
private fun StaffRow(
    staff: StaffDescriptor,
    hidden: Boolean,
    effectiveClefRaw: String,
    onToggleHidden: () -> Unit,
    onClef: (String?) -> Unit,
) {
    Row(Modifier.fillMaxWidth().padding(vertical = 2.dp), verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        ClefGlyphPicker(
            currentRaw = effectiveClefRaw,
            defaultRaw = staff.defaultClefRawType,
            modifier = Modifier.weight(1f),
            onSelect = onClef,
        )
        IconButton(onClick = onToggleHidden) {
            Icon(
                if (hidden) Icons.Default.VisibilityOff else Icons.Default.Visibility,
                contentDescription = if (hidden) "Show staff" else "Hide staff",
            )
        }
    }
}

@Composable
private fun ClefGlyphPicker(
    currentRaw: String,
    defaultRaw: String,
    modifier: Modifier = Modifier,
    onSelect: (String?) -> Unit,
) {
    var expanded by remember { mutableStateOf(false) }
    val current = ClefChoice.fromRawType(currentRaw)
    val music = rememberMusicFontFamily()   // SMuFL typeface from bundled Bravura asset
    Box(modifier) {
        TextButton(onClick = { expanded = true }) {
            Text(
                text = current?.glyph?.let { String(Character.toChars(it)) } ?: currentRaw,
                fontFamily = music,
                style = MaterialTheme.typography.titleLarge,
            )
            Icon(Icons.Default.ArrowDropDown, contentDescription = "Choose clef")
        }
        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            // Grouped families like iOS; render each as a glyph tile.
            (ClefChoice.trebleFamily + ClefChoice.bassFamily + ClefChoice.cFamily + ClefChoice.percussionFamily)
                .forEach { choice ->
                    DropdownMenuItem(
                        text = {
                            Row(verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                Text(String(Character.toChars(choice.glyph)), fontFamily = music,
                                    style = MaterialTheme.typography.titleLarge)
                                Text(stringResource(choice.labelKey))
                            }
                        },
                        onClick = { onSelect(choice.rawType); expanded = false },
                    )
                }
            HorizontalDivider()
            DropdownMenuItem(
                text = { Text(stringResource(R.string.reader_clef_reset)) },
                onClick = { onSelect(null); expanded = false },
            )
        }
    }
}
```

- [ ] **Step 4: Add `rememberMusicFontFamily`**

Locate the Bravura font asset the renderer uses (inspect `bundledFontProvider` in `SheetMusicComposeAndroid`). Load it as a Compose `FontFamily`:

```kotlin
@Composable
private fun rememberMusicFontFamily(): FontFamily {
    val context = LocalContext.current
    return remember(context) {
        // Match the asset path bundledFontProvider uses (e.g. "fonts/Bravura.otf").
        FontFamily(Font(path = "fonts/Bravura.otf", assetManager = context.assets))
    }
}
```
> Verify the exact asset path/name from `bundledFontProvider`; if the renderer exposes a typeface accessor, reuse it instead of re-loading.

- [ ] **Step 5: Commit**
```
git add Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/DisplayInspectorSheet.kt
git commit -m "feat(reader-android): display inspector sheet (general + parts + clef picker)"
```

## Task 14: TopAppBar trigger + three render modes in `ReaderScreen`

**Files:**
- Modify: `Android/FolinoReaderAndroid/.../reader/ReaderScreen.kt`

- [ ] **Step 1: Add the TopAppBar action + display-inspector sheet state**

In `ReaderScreen`, add:
```kotlin
var showDisplayInspector by remember { mutableStateOf(false) }
val displaySheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
val layoutOptions by readerVm.layoutOptions.collectAsStateWithLifecycle()
```
Add `actions` to the `TopAppBar`:
```kotlin
actions = {
    IconButton(onClick = { showDisplayInspector = true }) {
        Icon(Icons.Default.Dashboard, contentDescription = "Display settings")  // distinct from bottom-bar Tune
    }
},
```
And after the existing playback sheet block:
```kotlin
if (showDisplayInspector) {
    DisplayInspectorSheet(
        readerVm = readerVm,
        sheetState = displaySheetState,
        onDismiss = { showDisplayInspector = false },
    )
}
```

- [ ] **Step 2: Push viewport size (mm) to the VM for page mode**

In `ReadyScore`, when `viewportSize`/`density` are known, convert px→mm and inform the VM so page mode paginates to the real viewport:
```kotlin
LaunchedEffect(viewportSize, density) {
    if (viewportSize.width > 0 && viewportSize.height > 0) {
        val pxPerMm = with(density) { 1.dp.toPx() } * (160f / 25.4f) / 160f  // device px per mm
        val wMM = viewportSize.width / pxPerMm
        val hMM = viewportSize.height / pxPerMm
        audioVmIgnored  // no-op marker
        readerVm.setViewport(wMM.toDouble(), hMM.toDouble())
    }
}
```
> Compute px-per-mm from `density.density` and `density.densityDpi` properly; the snippet is indicative. Simpler: `val pxPerMm = density.density * 160f / 25.4f` is wrong — use `context.resources.displayMetrics.xdpi / 25.4f`. Pick the displayMetrics route and verify on-device.

- [ ] **Step 3: Branch `ReadyScore` rendering on layout mode**

Refactor `ReadyScore` to take `mode: ReaderLayoutMode` and select a renderer:
- `VERTICAL`: existing fit-width + pinch + vertical-scroll path (unchanged).
- `HORIZONTAL`: render the single wide page; `Modifier.horizontalScroll(hScroll).verticalScroll(vScroll)`; no fit-width (use a fixed `pxPerMM` from density, vertically centered); keep pinch zoom.
- `PAGE`: `HorizontalPager(state = rememberPagerState { program.pages.size })`; each page rendered with `ScorePage(page = program.pages[index], ...)` fit to the viewport; swipe to turn.

```kotlin
when (mode) {
    ReaderLayoutMode.VERTICAL -> VerticalScore(state, scoreHandle, fontProvider, audioVm)
    ReaderLayoutMode.HORIZONTAL -> HorizontalScore(state, scoreHandle, fontProvider, audioVm)
    ReaderLayoutMode.PAGE -> PagedScore(state, scoreHandle, fontProvider, audioVm)
}
```
Extract the current `ReadyScore` body into `VerticalScore` unchanged. Implement `HorizontalScore` and `PagedScore` mirroring it (reuse `ScorePage`, `PlaybackCursorOverlay`, and the `FolinoReaderJNI.nativeScrollOffsetKeepingInView` follow math; for page mode, on cursor change compute which page contains the cursor and `pagerState.animateScrollToPage(idx)`).

> Cursor→page mapping for page mode: the cursor frame's document Y (from `nativeCursorFrame`) no longer maps directly because pages are sliced. Simplest correct approach for v1: drive page-follow off the cursor's measure/tick by asking the bridge — OR keep page-follow manual (user swipes) for v1 and only auto-follow in vertical/horizontal. Decide and `log`/comment the choice; manual page-turn is acceptable for the first cut and avoids a new JNI query. Mark auto-follow-in-page-mode as a follow-up.

- [ ] **Step 4: Cross-compile + assemble + install + launch (per parity rule)**

Per memory `feedback_android_install_launch` (Android changes go all the way to install+launch) and `project_android_build_toolchain`:
1. Copy prebuilt `jniLibs`/`java-generated` from the primary checkout if reusing, else cross-compile with the `/Library` toolchain. The `.so` from Phase 1 Task 6 must be in place (new `nativeComputeLayout` signature) — rebuild Folino's Reader `.so` against the re-pinned swift-sheet-music.
2. `./gradlew :FolinoReaderAndroid:installDebug` (or the app module that hosts the Reader).
3. `adb shell am start` the Reader.

Expected: app launches; opening the display inspector shows General + Parts; toggling re-lays out.

- [ ] **Step 5: Commit**
```
git add Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderScreen.kt
git commit -m "feat(reader-android): TopAppBar display trigger + vertical/horizontal/page rendering"
```

## Task 15: Localization

**Files:**
- Modify: `Android/FolinoReaderAndroid/src/main/res/values/strings.xml` (+ `values-ja`, `values-ko`, `values-zh-rCN`, `values-zh-rTW`)

- [ ] **Step 1: Add the string keys (en)**

Mirror the iOS keys. Add to `values/strings.xml`:
```xml
<string name="reader_inspector_general">General</string>
<string name="reader_inspector_parts">Parts</string>
<string name="reader_part_untitled">Part</string>
<string name="reader_layout_vertical">Vertical</string>
<string name="reader_layout_horizontal">Horizontal</string>
<string name="reader_layout_page">Page</string>
<string name="reader_pref_staff_size">Staff size</string>
<string name="reader_pref_honor_breaks">Follow line and page breaks</string>
<string name="reader_pref_collapse_rests">Collapse multi-measure rests</string>
<string name="reader_pref_show_invisible">Show hidden elements</string>
<string name="reader_clef_reset">Reset to default</string>
<string name="reader_clef_treble">Treble</string>
<string name="reader_clef_treble8va">Treble 8va</string>
<string name="reader_clef_treble8vb">Treble 8vb</string>
<string name="reader_clef_treble15ma">Treble 15ma</string>
<string name="reader_clef_treble15mb">Treble 15mb</string>
<string name="reader_clef_bass">Bass</string>
<string name="reader_clef_bass8va">Bass 8va</string>
<string name="reader_clef_bass8vb">Bass 8vb</string>
<string name="reader_clef_soprano">Soprano</string>
<string name="reader_clef_alto">Alto</string>
<string name="reader_clef_tenor">Tenor</string>
<string name="reader_clef_baritone">Baritone</string>
<string name="reader_clef_percussion">Percussion</string>
<string name="reader_clef_percussion2">Percussion (alt)</string>
```

- [ ] **Step 2: Translate into ja / ko / zh-rCN / zh-rTW**

Copy the iOS translations from `Packages/Features/Reader/Sources/Reader/Resources/Localizable.xcstrings` for the matching `reader.preferences.*` / `reader.inspector.*` / `reader.preferences.clef.choice.*` keys, into the corresponding `values-*/strings.xml`. Keep brand text lowercase `folino` per project constraint (not relevant to these keys).

- [ ] **Step 3: Build + relaunch to confirm strings resolve** (re-run Task 14 Step 4 install/launch). Expected: no missing-resource crash; labels localized when device locale changes.

- [ ] **Step 4: Commit**
```
git add Android/FolinoReaderAndroid/src/main/res
git commit -m "i18n(reader-android): display inspector strings (en/ja/ko/zh-Hans/zh-Hant)"
```

## Task 16: End-to-end manual verification (Pixel)

**Files:** none (verification).

- [ ] **Step 1: Install + launch on a physical Pixel** (per `feedback_android_install_launch`).

- [ ] **Step 2: Verify each setting and capture results**
- Layout mode: switch vertical → horizontal → page; confirm the score re-lays out and the right scroll/paging behavior applies.
- Staff size: drag 8↔28; confirm reflow and "N pt" readout.
- Honor breaks / collapse rests / show invisible: toggle each; confirm visible render change.
- Parts: hide a staff (eye), confirm it disappears and brackets re-anchor; clef override via glyph picker, confirm the opening clef changes; Reset restores default.
- Confirm pinch zoom + scroll still behave per mode; confirm playback cursor follow still works in vertical/horizontal (page-follow per Task 14 Step 3 decision).

- [ ] **Step 3: No commit** — record the verification notes in the PR/branch description.

---

## Self-Review (completed during authoring)

- **Spec coverage:** staff size (T5/T13), honor breaks (T5/T13), collapse rests (T5/T13), show invisible (T5/T13), hidden staves (T1/T5/T13), clef override (T1/T5/T12/T13), 3 layout modes (T2/T5/T14), shared transforms+paginator lift (T1/T2/T7), LayoutOptionsWire (T3), parts/staves accessor (T4), JNI extension (T5), session-transient state (T11), TopAppBar trigger (T14), glyph clef picker (T12/T13), localization (T15), Pixel verification (T16), re-pin (T8). "Show seek bar" intentionally excluded per spec.
- **Type consistency:** `LayoutOptions`/`LayoutOptionsWire` field names align (mode/staffSize/honorLayoutBreaks/collapseMultiMeasureRests/showsInvisibleElements/hiddenStaves/clefOverrides); `StaffAddress` (Kotlin) ↔ `StaffAddressWire` (Swift) ↔ `StaffAddress` (Swift) mapping consistent; `nativeComputeLayout` 4-arg signature consistent across Swift/Kotlin/call sites.
- **Open verifications flagged inline** (do not skip): `Part` display-name + `Staff.defaultClefType` API (T4), `LayoutEngine.naturalContentWidth` label (T5), `LayoutDocument.subdocument` existence/initializer (T5/T1b), generated Kotlin codec field types (T10), Bravura asset path (T13), px-per-mm computation (T14).
