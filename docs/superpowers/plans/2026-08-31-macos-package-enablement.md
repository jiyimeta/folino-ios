# macOS Package Enablement (Sub-project Ⅲa) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every folino package below `Reader` compile for macOS, so the Mac app shell (Ⅲb) has a foundation to build on.

**Architecture:** The dependency graph is `Utility → ScoreUI → {Library, Infrastructure, ImportExport, Settings, Editor} → Reader`. Work up that ladder. Where a type or modifier is genuinely iOS-only, **keep the public signature on both platforms and gate the implementation**, giving macOS a neutral no-op — call sites in shared code then keep compiling unchanged. Where the concept has no macOS meaning at all (a share sheet, a navigation pop gesture), gate the type and gate its call sites. Every gap this creates is recorded in the parity ledger, which this plan first teaches about macOS.

**Reader is deliberately out of scope.** Its 14 UIKit and 11 PencilKit files are the `ScoreScrollHost` / annotation-canvas stack, whose macOS counterpart is an AppKit `NSScrollView` host — new UI, not a gate. That belongs to Ⅲb.

**Tech Stack:** Swift 6.3, SwiftPM, SwiftUI, UIKit/AppKit, `swift build` on a macOS host.

**Spec:** `docs/superpowers/specs/2026-08-31-macos-app-design.md` (sub-project Ⅲa in §9)

## Global Constraints

- **Deployment floor: iOS 18.0.** iOS-26-only API stays behind the compat helpers in `Packages/Utility/Sources/UtilityUI/GlassEffectCompat.swift`, in the same `if #available(iOS 26, *)` shape.
- **macOS floor: `.macOS(.v14)`** — the value `Utility`, `Domain`, and `Library` already declare. Every package this plan touches uses exactly `.macOS(.v14)`.
- **`swift build --package-path Packages/<X>` is the macOS gate** and works today on a macOS host. (`swift test` remains unusable for iOS-destination package tests — the SwiftLint plugin needs an iOS Simulator destination via `xcodebuild`. That restriction is unchanged and unaffected.)
- **No iOS regression.** Every task verifies that the iOS build still passes before committing.
- **Access control:** new symbols get no access modifier; promote to `public` only when something outside the module references it.
- **Comment style:** reflow `//` / `///` paragraphs at 120 columns.
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
| `Packages/ScoreUI/Package.swift` | ScoreUI manifest | Add `.macOS(.v14)` |
| `Packages/Features/Library/Sources/Library/Screens/LibraryRootPresentations.swift:187` | Share-sheet presentation | Gate the call site |
| `Packages/Infrastructure/Package.swift` | Infrastructure manifest | Add `.macOS(.v14)` |
| `Packages/Infrastructure/Sources/Audio/{LivePlaybackController,LiveScoreAudioExporter,OutputRouteDisconnectWatcher}.swift` | AVAudioSession / MPMediaItemArtwork / route watching | Gate to iOS; record the macOS gap |
| `Packages/Features/ImportExport/Package.swift` + `Sources/ImportExportShareUI/ShareSession.swift` | Share flow | Add `.macOS(.v14)`; gate |
| `Packages/Features/Settings/Package.swift` + `Sources/Settings/Screens/ReaderModeSettingRows.swift` | Settings rows with a raster glyph | Add `.macOS(.v14)`; gate the `UIImage` helper |
| `Packages/Features/Editor/Package.swift` + `Sources/Editor/Views/EditorPadButtons.swift` | Pad glyphs built from `UIImage`/`UIFont` | Add `.macOS(.v14)`; gate |
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
    // ScoreShareTarget's call sites.

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
// Mac shell ever adopts a navigation stack with a swipe-back affordance.
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
// UITraitOverrides.

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
// across view trees.
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

Each modifier gains `@ViewBuilder` because its two branches return different types. If a call site breaks because it relied on the concrete return type, fix the call site to use `some View`; do not remove `@ViewBuilder`.

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
    platforms: [.iOS(.v18), .macOS(.v14)],
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

## Task 4: Library compiles for macOS

`Library` already declares `.macOS(.v14)` and imports no UIKit itself, but it presents the iOS-only share sheet at one call site.

**Files:**
- Modify: `Packages/Features/Library/Sources/Library/Screens/LibraryRootPresentations.swift:187`

**Interfaces:**
- Consumes: Task 2's iOS-gated `ActivityViewControllerRepresentable`, Task 3's macOS-capable `ScoreUI`.
- Produces: `Library` building on macOS.

- [ ] **Step 1: Run the build to see it fail**

Run: `swift build --package-path Packages/Features/Library`
Expected: FAIL — `cannot find 'ActivityViewControllerRepresentable' in scope` at `LibraryRootPresentations.swift:187`.

- [ ] **Step 2: Gate the call site**

Read the surrounding presentation closure first, then wrap only the presented content:

```swift
                #if os(iOS)
                    ActivityViewControllerRepresentable(items: target.urls)
                #else
                    // PARITY(macos): library share sheet — presents nothing until the Mac shell has an
                    // NSSharingServicePicker path.
                    EmptyView()
                #endif
```

If the enclosing modifier is a `.sheet(item:)` whose content closure is not a `@ViewBuilder`, add `@ViewBuilder` to the helper that produces it rather than restructuring the presentation.

- [ ] **Step 3: Run the build to verify it passes**

Run: `swift build --package-path Packages/Features/Library`
Expected: `Build complete!`

- [ ] **Step 4: Verify iOS is not regressed**

Run the `xcodebuild` command from Task 2 Step 5.
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 5: Regenerate the ledger and commit**

```bash
python3 Scripts/parity-report.py
git add Packages/Features/Library docs/engineering/ios-android-parity.md
git commit -m "feat(library): compile for macOS with the share sheet gated"
```

---

## Task 5: Infrastructure compiles for macOS

Persistence, Soundfonts, and ScoreFiles are portable. The non-portable surface is exactly three files under `Audio/`, which use `AVAudioSession` (iOS-only), `MPMediaItemArtwork` built from `UIImage`, and route-change notifications. **Their macOS replacements belong to Ⅲb**, and the route-following work itself is Ⅱ's ssm change — so here they are gated, not ported.

**Files:**
- Modify: `Packages/Infrastructure/Package.swift:144`
- Modify: `Packages/Infrastructure/Sources/Audio/LivePlaybackController.swift`
- Modify: `Packages/Infrastructure/Sources/Audio/LiveScoreAudioExporter.swift`
- Modify: `Packages/Infrastructure/Sources/Audio/OutputRouteDisconnectWatcher.swift`

**Interfaces:**
- Consumes: Tasks 2 and 3.
- Produces: `Infrastructure` building on macOS with the `Audio` target's live types absent there.

- [ ] **Step 1: Add the platform and run the build to see it fail**

```swift
    platforms: [.iOS(.v18), .macOS(.v14)],
```

Run: `swift build --package-path Packages/Infrastructure`
Expected: FAIL — `no such module 'UIKit'` and/or `cannot find 'AVAudioSession' in scope` in the three `Audio/` files.

- [ ] **Step 2: Gate each of the three files at file scope**

Wrap each file's entire contents in `#if os(iOS) … #endif`, indenting the body one level (the repo's existing convention — see `PlaybackEngine+AudioSession.swift` in ssm for the shape). Put one marker above each guard, for example:

```swift
// PARITY(macos): live playback controller — macOS needs the AVAudioSession-free equivalent (no session category,
// NSImage-backed now-playing artwork, and CoreAudio default-device observation in place of route notifications).
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

One file, `ImportExportShareUI/ShareSession.swift`, imports UIKit.

**Files:**
- Modify: `Packages/Features/ImportExport/Package.swift:10`
- Modify: `Packages/Features/ImportExport/Sources/ImportExportShareUI/ShareSession.swift`

**Interfaces:**
- Consumes: Tasks 2 and 3.
- Produces: `ImportExport` building on macOS.

- [ ] **Step 1: Add the platform and run the build to see it fail**

```swift
    platforms: [.iOS(.v18), .macOS(.v14)],
```

Run: `swift build --package-path Packages/Features/ImportExport`
Expected: FAIL — `no such module 'UIKit'` at `ShareSession.swift:5`.

- [ ] **Step 2: Read the file and decide gate vs. port**

Run: `cat Packages/Features/ImportExport/Sources/ImportExportShareUI/ShareSession.swift`

If the UIKit use is confined to presenting the share sheet, gate the whole file with the file-scope `#if os(iOS)` pattern from Task 5 and this marker:

```swift
// PARITY(macos): share session — the Mac path needs NSSharingServicePicker; the session's URL preparation is
// portable and should be lifted out of this file when that lands.
```

If the file also contains **portable** logic (temporary-file staging, filename construction), **split it**: move the portable half to a new `ShareSessionFiles.swift` with no guard, and gate only the presentation half. That logic is shared with Android per the parity rule and must not sit behind an iOS guard.

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
git commit -m "feat(importexport): compile for macOS with the share session gated"
```

---

## Task 7: Settings compiles for macOS

`ReaderModeSettingRows.swift` builds a raster glyph: `UIImage(named: "repeat_a_b", in: .module, with: nil)` at line 47 and an `extension UIImage { func resized(to:) }` at lines 155–160.

**Files:**
- Modify: `Packages/Features/Settings/Package.swift:111`
- Modify: `Packages/Features/Settings/Sources/Settings/Screens/ReaderModeSettingRows.swift`

**Interfaces:**
- Consumes: Tasks 2 and 3.
- Produces: `Settings` building on macOS.

- [ ] **Step 1: Add the platform and run the build to see it fail**

```swift
    platforms: [.iOS(.v18), .macOS(.v14)],
```

Run: `swift build --package-path Packages/Features/Settings`
Expected: FAIL — `no such module 'UIKit'` at `ReaderModeSettingRows.swift:3`.

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
// menu has no such restriction, so the two branches are expected to stay different.
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

**Files:**
- Modify: `Packages/Features/Editor/Package.swift:139`
- Modify: `Packages/Features/Editor/Sources/Editor/Views/EditorPadButtons.swift`

**Interfaces:**
- Consumes: Tasks 2 and 3.
- Produces: `Editor` building on macOS. `EditorCore` is already platform-neutral and needs no change.

- [ ] **Step 1: Add the platform and run the build to see it fail**

```swift
    platforms: [.iOS(.v18), .macOS(.v14)],
```

Run: `swift build --package-path Packages/Features/Editor`
Expected: FAIL — `no such module 'UIKit'` at `EditorPadButtons.swift:3`.

- [ ] **Step 2: Gate only the raster helpers**

`PadDurationGlyph.swiftUIFont(size:)` is SwiftUI and stays. Gate `dotsImage(count:)` and `imageCache`, plus any `Image(uiImage:)` call site that consumes them:

```swift
import SwiftUI

#if os(iOS)
    import UIKit
#endif

// PARITY(macos): dotted-duration menu glyph — iOS rasterizes because a UIKit `Menu` row will not draw a custom
// View or apply a custom font. AppKit menus have no such restriction, so the Mac pad should draw the glyph as a
// View rather than port the rasterizer.
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
# Reader is deliberately absent: its UIKit scroll host and PencilKit canvas have no macOS
# implementation yet (sub-project IIIb of docs/superpowers/specs/2026-08-31-macos-app-design.md).
set -euo pipefail

cd "$(dirname "$0")/.."

PACKAGES=(
  Packages/Utility
  Packages/Domain
  Packages/ScoreUI
  Packages/Infrastructure
  Packages/Features/Library
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

- **`Reader`** — 14 UIKit and 11 PencilKit files. Gating them would leave the package compiling but empty of every reading surface, which is not a useful state. Its macOS form is an AppKit `NSScrollView` host modeled on ssm's `MagnifyingScoreScrollView`; that is Ⅲb/Ⅳ work.
- **AppKit implementations of anything gated here.** Ⅲa's deliverable is "it compiles". Each gap is recorded as a `PARITY(macos)` row, and Ⅲb consumes that list as its own to-do.
- **The Mac app target, `project.yml`, window/tab/menu bar.** All Ⅲb.
- **`AVAudioEngineConfigurationChange` route following.** That is Ⅱ, in ssm.
