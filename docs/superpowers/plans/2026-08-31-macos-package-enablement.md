# macOS Package Enablement (Sub-project Ⅲa) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every folino package below `Reader` compile for macOS, so the Mac app shell (Ⅲb) has a foundation to build on.

**Architecture:** The dependency graph is `Utility → ScoreUI → {Library, Infrastructure, ImportExport, Settings, Editor} → Reader`. Work up that ladder. Where a type or modifier is genuinely iOS-only, **keep the public signature on both platforms and gate the implementation**, giving macOS a neutral no-op — call sites in shared code then keep compiling unchanged. Where the concept has no macOS meaning at all (a share sheet, a navigation pop gesture), gate the type and gate its call sites. Every gap this creates is recorded in the parity ledger, which this plan first teaches about macOS.

**Reader is deliberately out of scope.** Its 14 UIKit and 11 PencilKit files are the `ScoreScrollHost` / annotation-canvas stack, whose macOS counterpart is an AppKit `NSScrollView` host — new UI, not a gate. That belongs to Ⅲb.

**Tech Stack:** Swift 6.3, SwiftPM, SwiftUI, UIKit/AppKit, `swift build` on a macOS host.

**Spec:** `docs/superpowers/specs/2026-08-31-macos-app-design.md` (sub-project Ⅲa in §9)

## Global Constraints

- **Deployment floor: iOS 18.0.** iOS-26-only API stays behind the compat helpers in `Packages/Utility/Sources/UtilityUI/GlassEffectCompat.swift`, in the same `if #available(iOS 26, *)` shape.
- **macOS floor: `.macOS(.v15)`** — every package this plan touches, including the three that already shipped `.macOS(.v14)` (`Utility`, `Domain`, `ScoreUI`). **v14 cannot work**: 81 ssm source files carry `@available(macOS 15.0, *)`, among them `PDFExporter` (`SheetMusicPDF/PDFExporter.swift:33`), which `Infrastructure/ScoreFiles/CoreGraphicsPDFRenderer.swift:11` calls unconditionally; `Editor/EditorViewModel+HitTest.swift:59` is the same shape. There are no macOS users to exclude — the app has never shipped.
- **iOS-only SwiftUI API needs no import, and is the larger surface than UIKit.** `EditMode` / `EditButton` / `\.editMode`, `.topBarLeading`, `.topBarTrailing`, `.navigationBarTitleDisplayMode`, `.textInputAutocapitalization`, `ToolbarSpacer`, and `Color(.secondarySystemBackground)` / `Color(uiColor:)` are all unavailable on macOS. Never conclude a package is portable from an import count.
- **The house pattern for those sites is a compat helper in `UtilityUI`**, shaped exactly like `GlassEffectCompat`: iOS keeps its call byte-for-byte, macOS gets a neutral substitute. **Do not migrate call sites to semantic toolbar placements** (`.cancellationAction` / `.confirmationAction`) in this plan — that is the better end state but it changes iOS appearance per site, so it is sequenced into Ⅲb one screen at a time.
- **`if #available(iOS 26, *)` does not guard macOS.** The `*` wildcard is satisfied on every platform not named, so an iOS-26-only API inside such a block fails to compile on macOS at any floor below 26. Write `if #available(iOS 26, macOS 26, *)`.
- **`swift build --package-path Packages/<X>` is the macOS gate** and works today on a macOS host. (`swift test` remains unusable for iOS-destination package tests — the SwiftLint plugin needs an iOS Simulator destination via `xcodebuild`. That restriction is unchanged and unaffected.)
- **No iOS regression.** Every task verifies that the iOS build still passes before committing.
- **Access control:** new symbols get no access modifier; promote to `public` only when something outside the module references it.
- **Comment style:** reflow `//` / `///` paragraphs at 120 columns.
- **`PARITY(macos):` markers have a grammar.** `Scripts/parity-report.py:50` requires a continuation line to be indented **two or more** spaces past the comment token (`//   like this`); a single space silently ends the entry and the ledger row is truncated mid-sentence with no diagnostic. Write continuations as `//   text`. Place the marker **outside** any `#if os(iOS)` guard — a note about what macOS needs, buried in a block macOS never compiles, is in the one place its reader will not look.
- **Do not use partial staging** (`git add -p`). Stage whole files.
- **`public` is a decision:** the macOS no-op branches keep exactly the access level their iOS counterparts have — no wider.

---

## File Structure

| File | Responsibility | Change |
| --- | --- | --- |
| `Scripts/parity-report.py` | Collects `PARITY(...)` markers into the ledger | Accept `macos` as a third platform |
| `docs/engineering/ios-android-parity.md` | The generated ledger | Regenerated with a macOS section |
| `Packages/Utility/Sources/UtilityUI/ActivityViewControllerRepresentable.swift` | UIKit share sheet bridge | Gate the type to iOS |
| `Packages/Utility/Sources/UtilityUI/HostingAppearance.swift` | Per-screen light/dark override via hosting VC traits | Gate impl; macOS no-op |
| `Packages/Utility/Sources/UtilityUI/WindowSafeAreaReader.swift` | Top safe-area probe | Gate impl; macOS no-op |
| `Packages/Utility/Sources/UtilityUI/WindowFrameReader.swift` | Frame in window coordinates | Gate impl; macOS no-op |
| `Packages/Utility/Sources/UtilityUI/InteractivePopGestureEnabler.swift` | Restores the iOS back-swipe | Gate type; macOS no-op modifier |
| `Packages/ScoreUI/Package.swift` | ScoreUI manifest | Add `.macOS(.v15)` |
| `Packages/Utility/Sources/UtilityUI/PlatformToolbarCompat.swift` | Compat helpers for iOS-only toolbar / title / text-input modifiers | Create |
| `Packages/{Utility,Domain,ScoreUI}/Package.swift` | Manifests that already shipped `.macOS(.v14)` | Raise to `.macOS(.v15)` |
| `Packages/Features/Library/Package.swift` | Library manifest | **Keeps** its `.macOS` declaration — an Android-JNI-host build floor, not macOS product support; the package itself is deferred to Ⅲb |
| `Packages/Infrastructure/Package.swift` | Infrastructure manifest | Add `.macOS(.v15)` |
| `Packages/Infrastructure/Sources/Audio/` — `LivePlaybackController.swift` + its `+LoopBounds` / `+Preview` / `+Reload` / `+Transpose` extensions, `LiveScoreAudioExporter.swift`, `OutputRouteDisconnectWatcher.swift` (**seven files**) | AVAudioSession / MPMediaItemArtwork / route watching | Gate to iOS; record the macOS gap |
| `Packages/Features/ImportExport/Package.swift` + `Sources/ImportExportShareUI/{ShareSession,ShareRootView,PlaylistPickerSection}.swift` | Share flow | Add `.macOS(.v15)`; drop a dead `import UIKit`; compat helpers |
| `Packages/Features/Settings/Package.swift` + `Sources/Settings/{Screens/ReaderModeSettingRows,Screens/AboutSettingsSection,Screens/SettingsSheet,Views/FeedbackMailView,VersionHistory/VersionHistoryScreen}.swift` | Settings rows, mail composer, version history | Add `.macOS(.v15)`; gate `MessageUI` and the `UIImage` / `Color(.system…)` uses; compat helpers |
| `Packages/Features/Editor/Package.swift` + `Sources/Editor/Views/{EditorPadButtons,EditorInstrumentsSheet,EditorDrumLayoutSheet,EditorRehearsalMarkSheet,EditorSignatureSheet,EditorPadTuckHandle}.swift` | Pad glyphs, sheets | Add `.macOS(.v15)`; gate the raster glyph, the two `EditMode` sites and `Color(uiColor:)`; compat helpers |
| `Scripts/build-macos-packages.sh` | One command that builds every macOS-enabled package | Create |

---

## Task 1: Teach the parity ledger about macOS

Ⅲa's entire output is a set of deliberate one-platform gaps. The repo already has machinery for recording those, but `Scripts/parity-report.py` hard-codes `PLATFORMS = ("android", "ios")` and its regex matches only `android|ios` — so a `PARITY(macos):` marker would be **silently ignored**, which is worse than no marker at all. Fix that first, so every gap the later tasks create is actually tracked.

**Files:**
- Modify: `Scripts/parity-report.py:45` (`PLATFORMS`), `:47` (`MARKER`), `:119` (`other`), `:136` (section heading)
- Modify (generated): `docs/engineering/ios-android-parity.md`

**Interfaces:**
- Consumes: nothing.
- Produces: a working `PARITY(macos): <title> — <what macOS still needs>` marker convention, used by Tasks 2 and 5–8.

- [ ] **Step 1: Read the script end to end**

Run: `sed -n '1,150p' Scripts/parity-report.py`

Understand `Entry`, `table(entries, platform)`, and how `main()` writes the ledger. The docstring at the top explains the marker format; it must be updated too.

- [ ] **Step 2: Write the failing test — a macOS marker must appear in the ledger**

Add a temporary marker to a file the script scans, so the run has something to find:

```bash
printf '\n// PARITY(macos): probe — temporary marker for the ledger test\n' >> Packages/Utility/Sources/UtilityUI/Placeholder.swift
```

- [ ] **Step 3: Run the report and verify the marker is ignored**

Run: `python3 Scripts/parity-report.py --check`

`--check` rewrites the generated block on disk and exits **non-zero if it changed** — that is what the pre-commit hook runs.

Expected: **exit 0**, i.e. the ledger did not change, proving the `PARITY(macos)` marker was silently **not** picked up. That silence is the bug this task fixes.

- [ ] **Step 4: Extend the script to three platforms**

```python
PLATFORMS = ("android", "ios", "macos")

MARKER = re.compile(r"PARITY\((?P<platform>android|ios|macos)\):\s*(?P<body>.*?)\s*$")
```

Replace the two-way conditionals with a lookup. At `table()`:

```python
PLATFORM_LABEL = {"android": "Android", "ios": "iOS", "macos": "macOS"}


def table(entries: list[Entry], platform: str) -> list[str]:
    rows = sorted((e for e in entries if e.platform == platform), key=lambda e: e.sort_key)
    other = PLATFORM_LABEL[platform]
```

and at the section heading in `main()`:

```python
    for platform in PLATFORMS:
        out.append(f"### Owed to {PLATFORM_LABEL[platform]}")
```

Read the surrounding lines before editing — `other` is used in the table's prose and its meaning ("the platform still owed the work") must survive the rewrite unchanged.

Update the module docstring's format line to `PARITY(<android|ios|macos>): <title> — <what the other platform still needs>`.

- [ ] **Step 5: Run the report and verify the marker now appears**

Run: `python3 Scripts/parity-report.py`
Then: `grep -n "probe — temporary marker" docs/engineering/ios-android-parity.md`
Expected: one hit, under an `### Owed to macOS` heading.

- [ ] **Step 6: Rename the pre-commit hook so it stops claiming to be two-platform**

In `.pre-commit-config.yaml:22`, change the hook's display name:

```yaml
        name: platform parity ledger
```

Leave the hook `id`, the `entry`, and the `files:` pattern alone, and **leave the ledger's filename as `docs/engineering/ios-android-parity.md`**. Renaming the file would touch CLAUDE.md, the hook's `files:` regex, and every memory and spec that cites the path, for no functional gain; the heading inside the document now carries the truth.

- [ ] **Step 7: Remove the probe marker and regenerate**

```bash
git checkout -- Packages/Utility/Sources/UtilityUI/Placeholder.swift
python3 Scripts/parity-report.py
```

Expected: the ledger keeps an empty `### Owed to macOS` section and the probe row is gone.

- [ ] **Step 8: Commit**

```bash
git add Scripts/parity-report.py .pre-commit-config.yaml docs/engineering/ios-android-parity.md
git commit -m "chore(parity): track macOS gaps in the parity ledger"
```

---

## Task 2: Utility compiles for macOS

`Utility` already declares `.macOS(.v14)` but does not build: five `UtilityUI` files import UIKit with no guard. Two of them are types with no macOS meaning; three are `View` modifiers whose signatures must survive so shared call sites keep compiling.

**Files:**
- Modify: `Packages/Utility/Sources/UtilityUI/ActivityViewControllerRepresentable.swift`
- Modify: `Packages/Utility/Sources/UtilityUI/InteractivePopGestureEnabler.swift`
- Modify: `Packages/Utility/Sources/UtilityUI/HostingAppearance.swift`
- Modify: `Packages/Utility/Sources/UtilityUI/WindowSafeAreaReader.swift`
- Modify: `Packages/Utility/Sources/UtilityUI/WindowFrameReader.swift`

**Interfaces:**
- Consumes: Task 1's `PARITY(macos)` convention.
- Produces, unchanged on both platforms:
  - `View.hostingAppearance(_ scheme: ColorScheme) -> some View`
  - `View.onWindowTopSafeAreaChange(_ action: @escaping (CGFloat) -> Void) -> some View`
  - `View.onWindowFrameChange(_ action: @escaping @MainActor (CGRect) -> Void) -> some View`
  - `View.restoresInteractivePopGesture() -> some View`
- Produces, iOS-only: `ActivityViewControllerRepresentable`, `InteractivePopGestureEnabler`.

- [ ] **Step 1: Run the build to see it fail**

Run: `swift build --package-path Packages/Utility`
Expected: FAIL, `error: no such module 'UIKit'` in `ActivityViewControllerRepresentable.swift`, `HostingAppearance.swift`, `InteractivePopGestureEnabler.swift`, `WindowFrameReader.swift`, `WindowSafeAreaReader.swift`.

- [ ] **Step 2: Gate the two iOS-only types**

In `ActivityViewControllerRepresentable.swift`, wrap the whole file body:

```swift
#if os(iOS)
    import SwiftUI
    import UIKit

    // PARITY(macos): system share sheet — macOS needs an NSSharingServicePicker equivalent, wired into
    //   ScoreShareTarget's call sites.

    /// Bridges `UIActivityViewController` (the system share sheet) into SwiftUI. Use via `.sheet {
    /// ActivityViewControllerRepresentable(items: [...]) }`.
    public struct ActivityViewControllerRepresentable: UIViewControllerRepresentable {
        // ... existing body, indented one level ...
    }
#endif
```

Do the same for `InteractivePopGestureEnabler`'s `public struct InteractivePopGestureEnabler` (lines 13–140), but **leave `restoresInteractivePopGesture()` outside the guard** — see Step 3. Its marker:

```swift
// PARITY(macos): interactive pop gesture — no macOS analogue; the modifier is a no-op there. Revisit only if the
//   Mac shell ever adopts a navigation stack with a swipe-back affordance.
```

- [ ] **Step 3: Give the three modifiers a macOS no-op that keeps the signature**

The pattern, applied identically in all four places. `HostingAppearance.swift`:

```swift
import SwiftUI

#if os(iOS)
    import UIKit
#endif

extension View {
    /// Pins this subtree to `scheme` regardless of the system setting, by overriding the trait on the hosting
    /// controller rather than with `.preferredColorScheme` (which leaks to the whole scene).
    ///
    /// On macOS this is a no-op: the Mac shell has no per-screen appearance scoping yet.
    @ViewBuilder
    public func hostingAppearance(_ scheme: ColorScheme) -> some View {
        #if os(iOS)
            modifier(HostingAppearanceModifier(scheme: scheme))
        #else
            self
        #endif
    }
}

// PARITY(macos): per-screen light/dark scoping — macOS would set NSAppearance on the hosting view instead of
//   UITraitOverrides.

#if os(iOS)
    // ... the existing private modifier and hosting-controller machinery, indented one level ...
#endif
```

`WindowSafeAreaReader.swift` — keep the `@Entry public var windowTopSafeAreaInsetOverride: CGFloat?` **outside** any guard (it is platform-neutral environment plumbing), and gate only the probe:

```swift
extension View {
    /// Reports the host window's top safe-area inset whenever it changes.
    ///
    /// On macOS this is a no-op — a Mac window has no top safe-area inset to report.
    @ViewBuilder
    public func onWindowTopSafeAreaChange(_ action: @escaping (CGFloat) -> Void) -> some View {
        #if os(iOS)
            modifier(WindowTopSafeAreaModifier(action: action))
        #else
            self
        #endif
    }
}
```

`WindowFrameReader.swift`:

```swift
extension View {
    /// Reports this view's frame in the host WINDOW's coordinate space, whenever it changes.
    ///
    /// (Existing doc comment retained verbatim.)
    ///
    /// On macOS this is a no-op. The AppKit port is mechanical — an `NSView` probe using
    /// `convert(bounds, to: nil)` and `viewDidMoveToWindow` — but nothing on macOS calls this yet.
    @ViewBuilder
    public func onWindowFrameChange(_ action: @escaping @MainActor (CGRect) -> Void) -> some View {
        #if os(iOS)
            modifier(WindowFrameChangeModifier(action: action))
        #else
            self
        #endif
    }
}

// PARITY(macos): window-coordinate frame probe — macOS needs the NSView equivalent before any Mac code can measure
//   across view trees.
```

`InteractivePopGestureEnabler.swift`, the modifier at line 142:

```swift
extension View {
    /// Restores the interactive pop gesture that a hidden navigation bar suppresses.
    ///
    /// On macOS this is a no-op.
    @ViewBuilder
    public func restoresInteractivePopGesture() -> some View {
        #if os(iOS)
            background(InteractivePopGestureEnabler())
        #else
            self
        #endif
    }
}
```

Read the existing body of `restoresInteractivePopGesture()` before editing and preserve whatever it actually does on iOS — the `background(...)` shown here is the expected shape, not a licence to replace different logic.

- [ ] **Step 4: Check the `@ViewBuilder` fallout**

Each modifier gains `@ViewBuilder`. **The reason is not that two branches return different types** — `#if os(iOS)` is resolved by the parser, so only one branch exists in any given compile and `some View` would infer fine without a builder. It is kept because it is harmless (`buildBlock` over a single expression is the identity) and it survives someone later converting the `#if` into a runtime condition, which is exactly the shape `GlassEffectCompat` already has. If a call site breaks because it relied on the concrete return type, fix the call site to use `some View`; do not remove `@ViewBuilder`.

Run: `grep -rn "hostingAppearance\|onWindowTopSafeAreaChange\|onWindowFrameChange\|restoresInteractivePopGesture" Packages App --include='*.swift'`
Expected: every hit is a modifier application in a `View` body — none stores the result in a typed property or passes it to a generic constrained to a concrete view type.

- [ ] **Step 5: Run the macOS build to verify it passes**

Run: `swift build --package-path Packages/Utility`
Expected: `Build complete!`

- [ ] **Step 6: Verify iOS is not regressed**

Run:
```
xcodebuild -project Folino.xcodeproj -scheme Folino \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max,OS=26.5' \
  -skipPackagePluginValidation build
```
Expected: `BUILD SUCCEEDED`. (Run `xcodegen generate` from inside the worktree first if `Folino.xcodeproj` is absent — it is gitignored and per-worktree. Do not pass `--spec` / `--project` from another directory. The `OS=26.5` pin is required; a bare device name resolves to an absent OS 27.0 runtime.)

- [ ] **Step 7: Regenerate the parity ledger**

Run: `python3 Scripts/parity-report.py`
Expected: four new rows under `### Owed to macOS`.

- [ ] **Step 8: Commit**

```bash
git add Packages/Utility/Sources/UtilityUI docs/engineering/ios-android-parity.md
git commit -m "feat(utility): compile UtilityUI for macOS behind iOS gates"
```

---

## Task 3: ScoreUI declares macOS

`ScoreUI` imports UIKit in **zero** files, so this is a manifest change. It is also load-bearing: without it, `Library` fails resolution with `the library 'ScoreUI' requires macos 10.13, but depends on the product 'Domain' which requires macos 14.0`, because an undeclared platform defaults to macOS 10.13.

**Files:**
- Modify: `Packages/ScoreUI/Package.swift:11`

**Interfaces:**
- Consumes: Task 2 (ScoreUI depends on `UtilityUI`, which must build for macOS first).
- Produces: `ScoreUI` resolvable on macOS, unblocking Task 4.

- [ ] **Step 1: Run the build to see it fail**

Run: `swift build --package-path Packages/ScoreUI`
Expected: FAIL with the `requires macos 10.13` resolution errors quoted above.

- [ ] **Step 2: Add the platform**

```swift
    platforms: [.iOS(.v18), .macOS(.v15)],
```

- [ ] **Step 3: Run the build to verify it passes**

Run: `swift build --package-path Packages/ScoreUI`
Expected: `Build complete!`

- [ ] **Step 4: Commit**

```bash
git add Packages/ScoreUI/Package.swift
git commit -m "build(scoreui): declare macOS 14 support"
```

---

## Task 4: Raise the floor to macOS 15, add the toolbar compat helpers, and defer Library

> **This task replaced the original Task 4 ("Library compiles for macOS") after measurement.** `Library` needs 33 fixes across 15 files, and `EditMode` appears in view *signatures* — `ScoreListScreen.swift:14` as `@State`, `ScoreListView.swift:41` as `@Binding`, crossing a screen/view boundary. There is no public signature to preserve, so the plan's method does not apply. Library moves to Ⅲb alongside Reader. See "Out of scope" at the end.

Three things that every remaining task depends on, in one commit each.

**Files:**
- Modify: `Packages/Utility/Package.swift`, `Packages/Domain/Package.swift`, `Packages/ScoreUI/Package.swift` (`.v14` → `.v15`)
- Modify: `Packages/Features/Library/Package.swift` (keep the `.macOS` declaration — it is an Android-JNI-host build
  floor, not macOS product support; see Step 3)
- Create: `Packages/Utility/Sources/UtilityUI/PlatformToolbarCompat.swift`

**Interfaces:**
- Consumes: Tasks 2 and 3.
- Produces, for Tasks 5–8:
  - `ToolbarItemPlacement.topBarLeadingCompat` / `.topBarTrailingCompat`
  - `View.inlineNavigationTitleCompat() -> some View`
  - `View.wordCapitalizationCompat() -> some View`

- [ ] **Step 1: Raise the three landed manifests to `.macOS(.v15)`**

In each of `Packages/Utility/Package.swift`, `Packages/Domain/Package.swift`, `Packages/ScoreUI/Package.swift`:

```swift
    platforms: [.iOS(.v18), .macOS(.v15)],
```

- [ ] **Step 2: Verify all three still build**

Run each of:
```
swift build --package-path Packages/Utility
swift build --package-path Packages/Domain
swift build --package-path Packages/ScoreUI
```
Expected: `Build complete!` for all three. (`Domain` declares `.macOS(.v14)` today with `.iOS(.v18)`; keep its `.iOS` value as it is.)

- [ ] **Step 3: Leave Library's macOS declaration alone**

**A controller ruling on an earlier draft of this step removed `.macOS` from `Packages/Features/Library/Package.swift`
on the theory that a manifest declaring a platform it cannot build is rot. That was wrong, and it broke
`FOLINO_ANDROID=1 swift build --package-path Packages/Features/Library`:** `FolinoLibraryJNI`, the Android
cross-compile target in this same manifest, depends on `Domain` and `UtilityCore`, both of which declare
`.macOS(.v15)` (Task 4 Step 1 above raises them to that floor), and that Android graph's host tests build for
macOS. Without a `.macOS` floor at or above that on `Library` itself, the manifest fails to resolve on the Android
path with "the library 'FolinoLibraryJNI' requires macos 10.13, but depends on the product 'Domain' which requires
macos 15.0" — Utility's `platforms:` comment documents the identical reasoning for the identical shape.

So `Packages/Features/Library/Package.swift` keeps:

```swift
    platforms: [.iOS(.v18), .macOS(.v15)],
```

with a comment explaining that this is a build floor for the Android JNI host tests, not macOS product support,
and that `Library` is still absent from `Scripts/build-macos-packages.sh` (Task 9) and still deferred to Ⅲb — the
declaration being present does not mean the package compiles as a macOS SwiftUI product.

- [ ] **Step 4: Write the compat helpers**

Create `Packages/Utility/Sources/UtilityUI/PlatformToolbarCompat.swift`. Read `GlassEffectCompat.swift` first and match its shape and doc-comment density.

```swift
import SwiftUI

// PARITY(macos): toolbar placement and title display mode — these substitute neutral macOS behavior so shared
//   screens compile. Ⅲb migrates each call site to a semantic placement (.cancellationAction /
//   .confirmationAction), which is what actually earns Esc / Return key equivalents on a Mac sheet.

extension ToolbarItemPlacement {
    /// `.topBarLeading` on iOS; `.navigation` on macOS, which is the leading edge of a Mac toolbar.
    public static var topBarLeadingCompat: ToolbarItemPlacement {
        #if os(iOS)
            .topBarLeading
        #else
            .navigation
        #endif
    }

    /// `.topBarTrailing` on iOS; `.primaryAction` on macOS, which is the trailing edge of a Mac toolbar.
    public static var topBarTrailingCompat: ToolbarItemPlacement {
        #if os(iOS)
            .topBarTrailing
        #else
            .primaryAction
        #endif
    }
}

extension View {
    /// `.navigationBarTitleDisplayMode(.inline)` on iOS; a no-op on macOS, which has no large-title collapse.
    @ViewBuilder
    public func inlineNavigationTitleCompat() -> some View {
        #if os(iOS)
            navigationBarTitleDisplayMode(.inline)
        #else
            self
        #endif
    }

    /// `.textInputAutocapitalization(.words)` on iOS; a no-op on macOS, which has no software keyboard to steer.
    @ViewBuilder
    public func wordCapitalizationCompat() -> some View {
        #if os(iOS)
            textInputAutocapitalization(.words)
        #else
            self
        #endif
    }
}
```

- [ ] **Step 5: Verify Utility still builds on both platforms**

Run: `swift build --package-path Packages/Utility`
Expected: `Build complete!`

Then the `xcodebuild` command from Task 2 Step 6.
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 6: Regenerate the ledger and commit, as three commits**

```bash
python3 Scripts/parity-report.py
git add Packages/Utility/Package.swift Packages/Domain/Package.swift Packages/ScoreUI/Package.swift
git commit -m "build: raise the macOS floor to 15 to match ssm's API availability"

git add Packages/Features/Library/Package.swift
git commit -m "build(library): drop the macOS declaration until IIIb makes it true"

git add Packages/Utility/Sources/UtilityUI/PlatformToolbarCompat.swift docs/engineering/ios-android-parity.md
git commit -m "feat(utility): add toolbar and title compat helpers for macOS"
```

---

## Task 5: Infrastructure compiles for macOS

Persistence, CloudSync, Soundfonts, CrashReporting, and Analytics build unmodified. **ScoreFiles builds too — but only at the `.macOS(.v15)` floor**, because `CoreGraphicsPDFRenderer.swift:11` calls `PDFExporter`, which ssm marks `@available(macOS 15.0, *)` (`SheetMusicPDF/PDFExporter.swift:33`).

The non-portable surface is **seven files** under `Audio/`, which use `AVAudioSession` (iOS-only), `MPMediaItemArtwork` built from `UIImage`, and route-change notifications. **Their macOS replacements belong to Ⅲb**, and the route-following work itself is Ⅱ's ssm change — so here they are gated, not ported.

**Files:**
- Modify: `Packages/Infrastructure/Package.swift:144`
- Modify: `Packages/Infrastructure/Sources/Audio/LivePlaybackController.swift`
- Modify: `Packages/Infrastructure/Sources/Audio/LivePlaybackController+LoopBounds.swift`
- Modify: `Packages/Infrastructure/Sources/Audio/LivePlaybackController+Preview.swift`
- Modify: `Packages/Infrastructure/Sources/Audio/LivePlaybackController+Reload.swift`
- Modify: `Packages/Infrastructure/Sources/Audio/LivePlaybackController+Transpose.swift`
- Modify: `Packages/Infrastructure/Sources/Audio/LiveScoreAudioExporter.swift`
- Modify: `Packages/Infrastructure/Sources/Audio/OutputRouteDisconnectWatcher.swift`

The four `LivePlaybackController+…` files extend the gated type, so they must be gated in the same commit or the build fails on them instead.

**Interfaces:**
- Consumes: Tasks 2 and 3.
- Produces: `Infrastructure` building on macOS with the `Audio` target's live types absent there.

- [ ] **Step 1: Add the platform and run the build to see it fail**

```swift
    platforms: [.iOS(.v18), .macOS(.v15)],
```

Run: `swift build --package-path Packages/Infrastructure`
Expected: FAIL — `no such module 'UIKit'` and/or `cannot find 'AVAudioSession' in scope` in the three `Audio/` files.

- [ ] **Step 2: Gate each of the seven files at file scope**

Wrap each file's entire contents in `#if os(iOS) … #endif`, indenting the body one level (the repo's existing convention — see `PlaybackEngine+AudioSession.swift` in ssm for the shape). Put one marker above each guard, for example:

```swift
// PARITY(macos): live playback controller — macOS needs the AVAudioSession-free equivalent (no session category,
//   NSImage-backed now-playing artwork, and CoreAudio default-device observation in place of route notifications).
#if os(iOS)
    // ... existing file contents, indented one level ...
#endif
```

- [ ] **Step 3: Run the build and fix any cross-target references it surfaces**

Run: `swift build --package-path Packages/Infrastructure`

If another target in the package names one of these types, the error will be `cannot find '<Type>' in scope` with the file and line. Gate that reference the same way. **Do not** introduce a macOS stub implementation of the type — an empty stand-in that silently plays nothing is worse than a compile error at the Ⅲb call site that has to confront it.

Expected once resolved: `Build complete!`

- [ ] **Step 4: Verify iOS is not regressed**

Run the `xcodebuild` command from Task 2 Step 5.
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 5: Regenerate the ledger and commit**

```bash
python3 Scripts/parity-report.py
git add Packages/Infrastructure docs/engineering/ios-android-parity.md
git commit -m "feat(infrastructure): compile for macOS with the Audio adapters gated"
```

---

## Task 6: ImportExport compiles for macOS

**`ShareSession.swift`'s `import UIKit` is dead** — measured: the file uses no UIKit symbol (`NSItemProvider` is Foundation). Deleting the import is the whole of that file's change; there is nothing to gate and nothing to split. The real work is five iOS-only SwiftUI modifier sites.

**Files:**
- Modify: `Packages/Features/ImportExport/Package.swift:10`
- Modify: `Packages/Features/ImportExport/Sources/ImportExportShareUI/ShareSession.swift` — delete `import UIKit`
- Modify: `Packages/Features/ImportExport/Sources/ImportExportShareUI/ShareRootView.swift:45,47,56,237,239,244`
- Modify: `Packages/Features/ImportExport/Sources/ImportExportShareUI/PlaylistPickerSection.swift:48`

**Interfaces:**
- Consumes: Tasks 2, 3, and **Task 4's compat helpers** (`ToolbarItemPlacement.topBarLeadingCompat` / `.topBarTrailingCompat`, `View.inlineNavigationTitleCompat()`, `View.wordCapitalizationCompat()`).
- Produces: `ImportExport` building on macOS.

- [ ] **Step 1: Add the platform and run the build to see it fail**

```swift
    platforms: [.iOS(.v18), .macOS(.v15)],
```

Run: `swift build --package-path Packages/Features/ImportExport`
Expected: FAIL — `no such module 'UIKit'` at `ShareSession.swift:5`, then (once that clears) `'topBarLeading' is unavailable in macOS` and siblings in `ShareRootView.swift` and `PlaylistPickerSection.swift`.

- [ ] **Step 2: Delete the dead import, then apply the compat helpers**

In `ShareSession.swift`, delete the `import UIKit` line. Confirm first that nothing in the file references a UIKit symbol:

Run: `grep -n "UI[A-Z]" Packages/Features/ImportExport/Sources/ImportExportShareUI/ShareSession.swift`
Expected: no hits. If there are hits, stop and report — the measurement this task rests on was wrong.

Then, in `ShareRootView.swift` and `PlaylistPickerSection.swift`, replace each iOS-only modifier with its Task 4 compat helper:

| Was | Becomes |
| --- | --- |
| `.navigationBarTitleDisplayMode(.inline)` | `.inlineNavigationTitleCompat()` |
| `ToolbarItem(placement: .topBarLeading)` | `ToolbarItem(placement: .topBarLeadingCompat)` |
| `ToolbarItem(placement: .topBarTrailing)` | `ToolbarItem(placement: .topBarTrailingCompat)` |
| `.textInputAutocapitalization(.words)` | `.wordCapitalizationCompat()` |

No `PARITY(macos)` marker is needed at these call sites — Task 4's helper file carries the one marker for the whole class. Do not add per-site markers; they would multiply one gap into twenty ledger rows.

- [ ] **Step 3: Run the build to verify it passes**

Run: `swift build --package-path Packages/Features/ImportExport`
Expected: `Build complete!`

- [ ] **Step 4: Verify iOS is not regressed**

Run the `xcodebuild` command from Task 2 Step 5.
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 5: Regenerate the ledger and commit**

```bash
python3 Scripts/parity-report.py
git add Packages/Features/ImportExport docs/engineering/ios-android-parity.md
git commit -m "feat(importexport): compile for macOS"
```

---

## Task 7: Settings compiles for macOS

Four distinct problems, not one. `ReaderModeSettingRows.swift` builds a raster glyph (`UIImage(named: "repeat_a_b", in: .module, with: nil)` at line 47, `extension UIImage { func resized(to:) }` at 155–160). `FeedbackMailView.swift` **imports `MessageUI`** and wraps `MFMailComposeViewController` — a framework macOS does not have at all. `VersionHistoryScreen.swift:95` uses the UIColor shorthand `Color(.secondarySystemBackground)`. And four toolbar/title sites need Task 4's helpers.

**Files:**
- Modify: `Packages/Features/Settings/Package.swift:111`
- Modify: `Packages/Features/Settings/Sources/Settings/Screens/ReaderModeSettingRows.swift`
- Modify: `Packages/Features/Settings/Sources/Settings/Views/FeedbackMailView.swift`
- Modify: `Packages/Features/Settings/Sources/Settings/Screens/AboutSettingsSection.swift:21,33,51`
- Modify: `Packages/Features/Settings/Sources/Settings/Screens/SettingsSheet.swift:50,58`
- Modify: `Packages/Features/Settings/Sources/Settings/VersionHistory/VersionHistoryScreen.swift:95`

**Interfaces:**
- Consumes: Tasks 2, 3, and **Task 4's compat helpers**.
- Produces: `Settings` building on macOS.

- [ ] **Step 1: Add the platform and run the build to see it fail**

```swift
    platforms: [.iOS(.v18), .macOS(.v15)],
```

Run: `swift build --package-path Packages/Features/Settings`
Expected: FAIL — `no such module 'UIKit'` at `ReaderModeSettingRows.swift:3` and `no such module 'MessageUI'` at `FeedbackMailView.swift`.

- [ ] **Step 1a: Gate the mail composer**

`FeedbackMailView.swift` wraps `MFMailComposeViewController`. Gate the whole file with the file-scope `#if os(iOS)` pattern, and give macOS a stub that keeps the two call sites compiling — `AboutSettingsSection.swift:51` reads `FeedbackMailView.canSendMail`, and `FeedbackMailPresentation.swift:21` presents the view.

Read both call sites first. The macOS stub must make `canSendMail` return `false`, which rides the **existing** iOS behavior for a device with no mail account: the row disables itself. That is why a stub is right here and wrong for `Infrastructure.Audio` — this one has a real, already-implemented "unavailable" state to fall into.

```swift
// PARITY(macos): feedback mail composer — macOS has no MessageUI. The Mac path is an `NSWorkspace.open` of a
//   `mailto:` URL built from the same subject and body; until then `canSendMail` is false and the row disables
//   itself, exactly as on an iPhone with no mail account configured.
```

- [ ] **Step 2: Replace the raster path with a cross-platform one where possible**

`Image(_:bundle:)` is cross-platform, so prefer removing the UIKit dependency outright over gating it. Read lines 40–60 and 150–165 first, then:

```swift
import SwiftUI

// The glyph is a bundled asset scaled to the row's text size. `Image(_:bundle:)` + `.resizable()` does this on
// both platforms; the old path went through `UIImage.resized(to:)` only because the row needed a fixed pixel size.
    Image("repeat_a_b", bundle: .module)
        .resizable()
        .aspectRatio(contentMode: .fit)
        .frame(width: glyphSize.width, height: glyphSize.height)
```

Delete `extension UIImage { func resized(to:) }` and the `import UIKit` once nothing references them.

**If the row genuinely needs a rasterized `UIImage`** (for example it feeds a `Menu` row, where custom `View` row icons are not drawn and only `Image(uiImage:)` works — see `reference_note_editing_durable`), do **not** do the above. Gate the raster path with `#if os(iOS)` and give macOS the `Image("repeat_a_b", bundle: .module)` branch, with this marker:

```swift
// PARITY(macos): A–B repeat row glyph — iOS rasterizes because a Menu row will not draw a custom View; the Mac
//   menu has no such restriction, so the two branches are expected to stay different.
```

- [ ] **Step 3: Run the build to verify it passes**

Run: `swift build --package-path Packages/Features/Settings`
Expected: `Build complete!`

- [ ] **Step 4: Verify iOS is not regressed, and check the row visually**

Run the `xcodebuild` command from Task 2 Step 5. Expected: `BUILD SUCCEEDED`.

Then add or update a `#Preview` in `ReaderModeSettingRows.swift` covering the row that carries this glyph, render it with `mcp__xcode__RenderPreview`, and `Read` the PNG. Expected: the A–B repeat glyph is present, vertically centered, and the same size as before the change. **This step is not optional** — Step 2's first branch changes how the glyph is drawn.

- [ ] **Step 5: Regenerate the ledger and commit**

```bash
python3 Scripts/parity-report.py
git add Packages/Features/Settings docs/engineering/ios-android-parity.md
git commit -m "feat(settings): compile for macOS"
```

---

## Task 8: Editor compiles for macOS

`EditorPadButtons.swift` imports UIKit for `dotsImage(count:) -> UIImage` (line 157) and its `imageCache` (line 174). Per `reference_note_editing_durable`, the raster path exists because **`Menu` rows draw only text and images — a custom `View` row icon is not drawn, and a custom font does not apply**. That constraint is real on iOS and must not be optimized away.

Three more things beyond the rasterizer, measured: two `EditMode` sites, one UIColor shorthand, and the usual toolbar/title modifiers.

**Files:**
- Modify: `Packages/Features/Editor/Package.swift:139`
- Modify: `Packages/Features/Editor/Sources/Editor/Views/EditorPadButtons.swift` — the `UIImage` rasterizer
- Modify: `Packages/Features/Editor/Sources/Editor/Views/EditorInstrumentsSheet.swift:56,126,127,129,154` — `EditButton()` plus toolbar/title
- Modify: `Packages/Features/Editor/Sources/Editor/Views/EditorDrumLayoutSheet.swift:28,30,185` — `.environment(\.editMode, .constant(.active))` plus title
- Modify: `Packages/Features/Editor/Sources/Editor/Views/EditorRehearsalMarkSheet.swift:64` and `EditorSignatureSheet.swift:61` — title only
- Modify: `Packages/Features/Editor/Sources/Editor/Views/EditorPadTuckHandle.swift:68` — `Color(uiColor: .systemGroupedBackground)`

**Interfaces:**
- Consumes: Tasks 2, 3, and **Task 4's compat helpers**.
- Produces: `Editor` building on macOS. `EditorCore` is already platform-neutral and needs no change.

- [ ] **Step 1: Add the platform and run the build to see it fail**

```swift
    platforms: [.iOS(.v18), .macOS(.v15)],
```

Run: `swift build --package-path Packages/Features/Editor`
Expected: FAIL — `no such module 'UIKit'` at `EditorPadButtons.swift:3`, then `EditButton`/`editMode`/`topBarLeading`/`navigationBarTitleDisplayMode` unavailability, then `EditorViewModel+HitTest.swift:59` if the floor is not `.v15` (`editingHitTest(at:activeVoice:)` is `@available(macOS 15.0, *)` in ssm).

- [ ] **Step 1a: Gate the two `EditMode` sites**

Both are **affordance-level, not screen-level** — this is why `Editor` stays in Ⅲa while `Library` does not. Neither holds `EditMode` in a property or a binding; both are local to a view body.

- `EditorInstrumentsSheet.swift:127` — `EditButton()` exists only to open `.onMove` reordering. Deletion goes through swipe + `confirmationDialog` and does not depend on edit mode. Gate the `ToolbarItem` containing it; staff-visibility toggles, the add-instrument button, and Done all still work on macOS.
- `EditorDrumLayoutSheet.swift:28` — `.environment(\.editMode, .constant(.active))` keeps reorder handles and delete minuses permanently visible. Gate the modifier; row tap-to-reinstrument, the voice badge, the row-count Stepper, the preset Picker, and Cancel/Done all still work.

One marker covers both:

```swift
// PARITY(macos): instrument and drum-row reordering — the iOS sheets open reordering through EditButton and an
//   always-active edit mode, neither of which exists on macOS. A Mac list reorders by drag without an edit mode,
//   so the fix is an affordance, not a port. Deleting a drum row is unavailable on macOS until then.
```

Runtime behavior of `.onMove` / `.onDelete` on a macOS `List` without a selection is **unverified**; Ⅲb confirms it on a real Mac before writing the affordance.

- [ ] **Step 2: Gate only the raster helpers**

`PadDurationGlyph.swiftUIFont(size:)` is SwiftUI and stays. Gate `dotsImage(count:)` and `imageCache`, plus any `Image(uiImage:)` call site that consumes them:

```swift
import SwiftUI

#if os(iOS)
    import UIKit
#endif

// PARITY(macos): dotted-duration menu glyph — iOS rasterizes because a UIKit `Menu` row will not draw a custom
//   View or apply a custom font. AppKit menus have no such restriction, so the Mac pad should draw the glyph as a
//   View rather than port the rasterizer.
```

Wrap the two members and their call sites in `#if os(iOS)`. Where a `View` body branches on them, use the `@ViewBuilder` + `#if` pattern from Task 2 Step 3 so the macOS branch renders the glyph as text with `PadDurationGlyph.swiftUIFont(size:)`.

- [ ] **Step 3: Run the build to verify it passes**

Run: `swift build --package-path Packages/Features/Editor`
Expected: `Build complete!`

- [ ] **Step 4: Verify iOS is not regressed, and check the pad visually**

Run the `xcodebuild` command from Task 2 Step 5. Expected: `BUILD SUCCEEDED`.

Then render the existing `#Preview` covering the duration pad row with `mcp__xcode__RenderPreview` and `Read` the PNG. Expected: dotted-duration glyphs are unchanged from before this task — the dot sits at the correct offset from the notehead (SMuFL `metAugmentationDot` advance behavior; see `reference_note_editing_durable`).

- [ ] **Step 5: Regenerate the ledger and commit**

```bash
python3 Scripts/parity-report.py
git add Packages/Features/Editor docs/engineering/ios-android-parity.md
git commit -m "feat(editor): compile for macOS with the menu-glyph rasterizer gated"
```

---

## Task 9: A single command that proves the ladder still builds

Without one command, the macOS build silently rots the first time someone adds an ungated `import UIKit` — exactly how `Utility` came to declare `.macOS(.v14)` while not building for it.

**Files:**
- Create: `Scripts/build-macos-packages.sh`
- Modify: `CLAUDE.md` (the "Day-to-Day Commands" table)

**Interfaces:**
- Consumes: Tasks 2–8.
- Produces: `Scripts/build-macos-packages.sh`, exit 0 iff every macOS-enabled package builds.

- [ ] **Step 1: Write the script**

```bash
#!/usr/bin/env bash
# Builds every folino package that is expected to compile for macOS, in dependency order.
#
# Reader and Features/Library are both deliberately absent, for the same reason: neither compiles
# as a macOS product yet, and both are deferred to sub-project IIIb of
# docs/superpowers/specs/2026-08-31-macos-app-design.md. Reader's UIKit scroll host and PencilKit
# canvas have no macOS implementation. Library's EditMode-driven selection is woven into view
# signatures rather than call sites, so there is no signature to gate behind.
#
# Library DOES declare a `.macOS(.v15)` platform in its manifest — but only as a build floor for
# FolinoLibraryJNI's Android cross-compile graph, whose host tests build on macOS. That declaration
# is not evidence the package belongs in this gate.
set -euo pipefail

cd "$(dirname "$0")/.."

PACKAGES=(
  Packages/Utility
  Packages/Domain
  Packages/ScoreUI
  Packages/Infrastructure
  Packages/Features/ImportExport
  Packages/Features/Settings
  Packages/Features/Editor
)

failed=()
for pkg in "${PACKAGES[@]}"; do
  echo "==> $pkg"
  if ! swift build --package-path "$pkg"; then
    failed+=("$pkg")
  fi
done

if [ ${#failed[@]} -ne 0 ]; then
  echo "macOS build FAILED for: ${failed[*]}" >&2
  exit 1
fi
echo "All macOS packages built."
```

- [ ] **Step 2: Make it executable and run it**

```bash
chmod +x Scripts/build-macos-packages.sh
Scripts/build-macos-packages.sh
```

Expected: every package prints, then `All macOS packages built.`, exit 0.

- [ ] **Step 3: Verify it actually fails when it should**

```bash
printf '\nimport UIKit\n' >> Packages/ScoreUI/Sources/ScoreUI/ScoreShareTarget.swift
Scripts/build-macos-packages.sh; echo "exit=$?"
```

Expected: `macOS build FAILED for: Packages/ScoreUI`, `exit=1`.

Then: `git checkout -- Packages/ScoreUI/Sources/ScoreUI/ScoreShareTarget.swift` and re-run to confirm exit 0.

- [ ] **Step 4: Document it**

Add one row to the "Day-to-Day Commands" table in `CLAUDE.md`:

```markdown
| Verify every macOS-enabled package still builds | `Scripts/build-macos-packages.sh` |
```

- [ ] **Step 5: Commit**

```bash
git add Scripts/build-macos-packages.sh CLAUDE.md
git commit -m "chore(macos): add a build gate for the macOS-enabled packages"
```

---

## Out of scope, and why

**The criterion.** Ⅲa is a package whose implementation can be gated behind a **preserved public signature**. Ⅲb is a package where an iOS-only type is **woven into a signature or into stored state**, so the macOS form is new design rather than a gate.

- **`Reader`** — 14 UIKit and 11 PencilKit files. Gating them would leave the package compiling but empty of every reading surface, which is not a useful state. Its macOS form is an AppKit `NSScrollView` host modeled on ssm's `MagnifyingScoreScrollView`; that is Ⅲb/Ⅳ work.
- **`Features/Library`** — moved here after measurement: 33 errors across 15 files, and `EditMode` is not a call-site detail but part of view *signatures* — `ScoreListScreen.swift:14` (`@State private var editMode: EditMode`) binds to `ScoreListView.swift:41` (`@Binding var editMode: EditMode`), crossing a screen/view boundary, with `PlaylistDetailView`, `RecentlyDeletedScreen`, and `RecentlyDeletedView` in the same shape. There is no signature to preserve, so this plan's method does not apply; macOS multi-select is `List(selection:)` with a different interaction model, which is design work. Its `.macOS` platform declaration **stays** — it predates this plan (commit `08be80c1`) as a build floor for `FolinoLibraryJNI`'s Android host tests, the same reason `Utility` and `Domain` declare one, and removing it breaks `FOLINO_ANDROID=1 swift build --package-path Packages/Features/Library`. The declaration is not evidence the package is macOS-enabled: `Library` is still absent from `Scripts/build-macos-packages.sh`, and it still does not compile as a macOS SwiftUI product. Ⅲb also owes it `ScoreListView.swift:118`'s `if #available(iOS 26, *)` → `if #available(iOS 26, macOS 26, *)`.
- **Migrating toolbar sites to semantic placements** (`.cancellationAction` / `.confirmationAction`). The better end state, and it earns real Esc / Return key equivalents on Mac sheets — but it changes iOS appearance per site and needs per-site preview verification. Ⅲa uses neutral compat helpers; Ⅲb migrates one screen at a time.
- **AppKit implementations of anything gated here.** Ⅲa's deliverable is "it compiles". Each gap is recorded as a `PARITY(macos)` row, and Ⅲb consumes that list as its own to-do.
- **The Mac app target, `project.yml`, window/tab/menu bar.** All Ⅲb.
- **`App/AppBootstrap.swift`.** It constructs `LivePlaybackController` and `LiveScoreAudioExporter` as concrete types at `:45`, `:198`, and `:216` with no platform guard. That is correct today: `App` is an Xcode target outside every `swift build --package-path` graph, and the macOS composition root does not exist until Ⅲb creates it. Ⅲb owns replacing these with whatever the Mac shell injects; Ⅲa deliberately leaves them alone rather than guarding a composition root that has no macOS half yet.
- **Test targets.** `swift build` does not build them, so `Packages/Infrastructure/Tests/InfrastructureTests/Audio/*` still names gated types unconditionally. Making the package *tests* run on macOS is Ⅲb's problem, and a different one — it needs the gated types to have macOS behavior worth testing.
- **`AVAudioEngineConfigurationChange` route following.** That is Ⅱ, in ssm.
