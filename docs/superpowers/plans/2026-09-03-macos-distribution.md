# macOS Sub-project Ⅷ — Distribution Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the macOS build of folino distributable through the Mac App Store — sandboxed, signed, with a release lane and screenshots — and give the Mac the export path that withdrawing origin mirroring depends on.

**Architecture:** Four independent strands that share one target. (a) The app moves into the App Sandbox, which requires one code fix first, because the Mac's SoundFont directory is in a group container rather than in Application Support. (b) A `.fileExporter`-based export presentation lands in `ScoreUI` and is reached from the Library rows and the Mac score window. (c) `fastlane` gains a `platform :mac` block. (d) A separate `FolinoMacScreenshot` target and a `screencapture` script produce App Store screenshots. Nothing here touches `App/Mac`'s window or scene layer.

**Tech Stack:** Swift 6.3, SwiftUI, XcodeGen, GRDB, fastlane, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-09-03-macos-distribution-design.md` (and its parent, `docs/superpowers/specs/2026-08-31-macos-app-design.md`)

## Global Constraints

- **Deployment floors: iOS 18.0, macOS 15.0.** iOS-26-only API goes behind a `UtilityUI` compat helper.
- **`if #available(iOS 26, *)` does not protect macOS** — the `*` wildcard satisfies it. Always write `if #available(iOS 26, macOS 26, *)`.
- **Do not remove any `.macOS(...)` platform declaration** from `Utility`, `Domain`, or `Features/Library`. They are the build floor for the Android JNI host tests; deleting them breaks `FOLINO_ANDROID=1 swift build`. This has been done and reverted twice.
- **Do not modify `App/Mac/FolinoMacApp.swift`, `MacShellView.swift`, `MacWindowTabAssist.swift`, `MacAppDelegate.swift`, `MacCommands.swift`, `MacEditingMenus.swift`, or `MacEditingCommands*.swift`.** A parallel session is rewriting the Mac window/scene layer. `App/Mac/Info.plist`, `App/Mac/SharedContainerTasks.swift`, and `project.yml` are shared — edit them minimally and expect merge conflicts there.
- **Never put `#if` inside a SwiftUI modifier chain.** SwiftFormat's `--ifdef no-indent` fights it on every commit. Put the platform split inside a compat helper (`UtilityUI/PlatformToolbarCompat.swift` is the house example), and gate the *modifier*, not its content.
- **Run `xcodegen generate` after every `project.yml` change**, from inside the worktree with no flags.
- **New tests use Swift Testing** (`@Test`, `#expect`). `FolinoMacTests` uses `@testable import folino` and backtick-quoted test names.
- **`FolinoMacTests` report "hung before establishing connection" whenever the screen is locked.** That is not a failure; unlock and re-run.
- **Simulator destinations must pin `OS=26.5`.** Bare `name=iPhone 17 Pro Max` resolves to a 27.0 runtime that is not installed.
- **`PARITY(macos):` continuation lines need 2+ spaces** after the comment token (`//   …`). One space is silently dropped and truncates the ledger row.
- **Swift access control:** no modifier by default; `public` only when something outside the module references it.
- **Comments reflow at 120 columns**, not 80.
- **User-facing brand is lowercase `folino`.** `Folino` is for type names, schemes, and bundle IDs only.
- **Gates for every task:** `Scripts/build-macos-packages.sh` and `Scripts/build-macos-app.sh` stay green.

---

## File Structure

**Created:**

| File | Responsibility |
| --- | --- |
| `App/Mac/FolinoMac.entitlements` | The Mac target's three sandbox entitlements. Separate from iOS's by design (spec §2). |
| `Scripts/check-macos-entitlements.sh` | Asserts the built `.app` actually carries those entitlements. Guards against `project.yml` regressions. |
| `Packages/ScoreUI/Sources/ScoreUI/ScoreExportPresentation.swift` | The one place the share/export presentation splits by platform. iOS keeps the activity sheet; macOS gets `.fileExporter`. |
| `Packages/ScoreUI/Tests/ScoreUITests/ScoreExportPresentationTests.swift` | Unit coverage for the filename and single-vs-multiple decision, which is pure logic. |
| `App/MacScreenshot/MacScreenshotSetup.swift` | `ScreenshotApplication` — sizes windows to an App Store size, and nothing else. Compiled only into the screenshot target. |
| `App/MacScreenshot/Info.plist` | A copy of the Mac plist plus `NSPrincipalClass`, which is the only hook that runs before `NSApplication` without editing the off-limits `FolinoMacApp.swift`. |
| `Scripts/capture-mac-screenshots.sh` | Launch per locale, wait for the window, capture, flatten, assert dimensions. |
| `Scripts/flatten-screenshot.swift` | Removes the alpha channel the rounded corners leave behind. |
| `Scripts/mac-window-id.swift` | Prints the `CGWindowID` that `screencapture -l` needs; no shell command yields it. |
| `docs/superpowers/plans/2026-09-03-macos-distribution-qa.md` | The by-hand acceptance sheet from spec §9. |

**Modified:**

| File | Change |
| --- | --- |
| `App/Shared/AppPaths.swift` | `sharedContainer` returns `nil` on macOS; the `documentsRoot` PARITY marker is deleted. |
| `App/Mac/Info.plist` | `LSApplicationCategoryType`; possibly `UTImportedTypeDeclarations`. |
| `App/Mac/SharedContainerTasks.swift` | Marker rewritten to separate "not applicable on macOS" from "deferred gap". |
| `App/Shared/AppBootstrap.swift` | Firebase marker updated to note the entitlement now exists. |
| `project.yml` | `CODE_SIGN_ENTITLEMENTS` on `FolinoMac`; the new `FolinoMacScreenshot` target and scheme. |
| `fastlane/Fastfile` | A `platform :mac` block. |
| `Packages/Features/Library/Sources/Library/Views/ScoreRowMenu.swift` | Share submenu reaches macOS; marker narrowed to *Open in VocalTuner*. |
| `Packages/Features/Library/Sources/Library/Views/BulkActionBar.swift` | Bulk share rows reach macOS; marker deleted. |
| `Packages/Features/Library/Sources/Library/Screens/LibraryRootPresentations.swift` | Uses the new presentation modifier. |
| `Packages/Utility/Sources/UtilityUI/ActivityViewControllerRepresentable.swift` | Marker deleted. |
| `Packages/Features/Reader/Sources/Reader/Screens/ReaderRootScreen.swift` | Uses the new presentation modifier. |
| `Packages/Features/Reader/Sources/Reader/Screens/Mac/MacReaderRootScreen.swift` | Gains an Export toolbar item; marker narrowed. |
| `docs/engineering/ios-android-parity.md` | Regenerated by `Scripts/parity-report.py`. |

---

## Task 1: The Mac stops using the App Group container

Sandboxing without this is a failed launch, not a degraded feature: `AppBootstrap.prepareDirectories()` creates the SoundFont directory with `try` (not `try?`), and on macOS that directory currently resolves into `~/Library/Group Containers/group.com.KeyNumber.shared/Soundfonts` — a location the app has no entitlement for. This task must land before Task 2.

**Files:**
- Modify: `App/Shared/AppPaths.swift:6-9` (delete marker), `:44-47` (`sharedContainer`)
- Test: `Tests/FolinoMacTests/AppPathsTests.swift` (create)

**Interfaces:**
- Consumes: nothing.
- Produces: `AppPaths.sharedContainer` is `nil` on macOS, therefore `AppPaths.sharedSoundfontsDirectory` is `nil` and `AppPaths.soundfontsDirectory == AppPaths.legacySoundfontsDirectory`. Signatures are unchanged — `static var sharedContainer: URL?`, `static var soundfontsDirectory: URL`, `static var legacySoundfontsDirectory: URL`. Task 2 depends on this holding.

- [ ] **Step 1: Record the current behavior, so the change is provably a change**

Run:
```
find "$HOME/Library/Group Containers/group.com.KeyNumber.shared" -maxdepth 3
```
Expected: the directory exists and contains `Soundfonts/consumers/com.KeyNumber.Folino`. Paste the output into the task report. If it does *not* exist, say so — the premise held on 2026-09-03 and a change means Apple's behavior differs from what this task assumes.

- [ ] **Step 2: Write the failing test**

Create `Tests/FolinoMacTests/AppPathsTests.swift`:

```swift
@testable import folino
import Testing

/// Ⅷ §2: the Mac does not participate in the cross-app App Group. `SharedContainerTasks` already declines all five
/// launch tasks by construction; this is the other half — the SoundFont path, which is shared code and would
/// otherwise resolve into a group container the sandbox has no entitlement for.
struct AppPathsTests {
    @Test func `the shared App Group container is unavailable on macOS`() {
        #expect(AppPaths.sharedContainer == nil)
    }

    @Test func `the shared SoundFont directory is unavailable on macOS`() {
        #expect(AppPaths.sharedSoundfontsDirectory == nil)
    }

    @Test func `SoundFonts resolve to the private Application Support directory`() {
        #expect(AppPaths.soundfontsDirectory == AppPaths.legacySoundfontsDirectory)
    }
}
```

- [ ] **Step 3: Run the test and watch it fail**

Run:
```
xcodebuild test -project Folino.xcodeproj -scheme FolinoMac -destination 'platform=macOS' -skipPackagePluginValidation -only-testing:FolinoMacTests/AppPathsTests
```
Expected: FAIL — `sharedContainer` returns a URL because macOS hands one back to an unsandboxed app regardless of entitlements.

If it reports "hung before establishing connection", the screen is locked. Unlock it and re-run; do not treat that as the red state.

- [ ] **Step 4: Make it pass**

In `App/Shared/AppPaths.swift`, replace the body of `sharedContainer` with:

```swift
    /// Root of the cross-app shared App Group container, or `nil` when it is unavailable. Callers that write into it
    /// — the incoming-score drain, the capability stamp — degrade to doing nothing.
    ///
    /// **`nil` on macOS, unconditionally.** The Mac does not join the App Group: `App/Mac/SharedContainerTasks.swift`
    /// declines every App Group launch task by construction, and this is the other half of that decision. It has to
    /// be explicit rather than inherited from a missing entitlement, because macOS does not behave like iOS here — an
    /// unsandboxed Mac app gets a real path back from `containerURL(forSecurityApplicationGroupIdentifier:)` whether
    /// or not it holds the entitlement, and creates the directory on demand. That is how the Mac's SoundFonts ended
    /// up in `~/Library/Group Containers/…` (measured 2026-09-03) by way of `AudioStackFactory`, which is shared
    /// code. Under the App Sandbox that path is not writable, and `AppBootstrap.prepareDirectories()` creates the
    /// SoundFont directory with `try` — so leaving this to chance is a failed launch, not a missing SoundFont.
    ///
    /// The sub-project that wires the cross-app tasks removes this gate and adds the entitlement together.
    static var sharedContainer: URL? {
        #if os(macOS)
        nil
        #else
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: sharedAppGroupIdentifier)
        #endif
    }
```

Then delete the `PARITY(macos)` marker at the top of the file (lines 6-9, `// PARITY(macos): document root — …`). Task 2 is what makes its prediction true, and Task 7 regenerates the ledger.

- [ ] **Step 5: Run the test and watch it pass**

Run the same command as Step 3. Expected: 3 tests pass. Then run the whole Mac suite:
```
xcodebuild test -project Folino.xcodeproj -scheme FolinoMac -destination 'platform=macOS' -skipPackagePluginValidation
```
Expected: 22 tests pass (19 existing + 3 new). **State the count in the report, not "tests pass".**

- [ ] **Step 6: Confirm iOS is untouched**

Run:
```
xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max,OS=26.5' -skipPackagePluginValidation build
```
Expected: BUILD SUCCEEDED. The `#else` branch is byte-identical to the old body, so iOS behavior is unchanged by construction — this build only confirms the `#if` compiles on both sides.

- [ ] **Step 7: Commit**

```bash
git add App/Shared/AppPaths.swift Tests/FolinoMacTests/AppPathsTests.swift
git commit -m "fix(macos): the Mac does not join the App Group, so say so explicitly"
```

---

## Task 2: The App Sandbox

**Files:**
- Create: `App/Mac/FolinoMac.entitlements`, `Scripts/check-macos-entitlements.sh`
- Modify: `project.yml:185-194` (`FolinoMac` settings), `App/Mac/Info.plist`

**Interfaces:**
- Consumes: Task 1's guarantee that `AppPaths.soundfontsDirectory` is inside Application Support on macOS.
- Produces: a `FolinoMac` product whose code signature carries `com.apple.security.app-sandbox`, `com.apple.security.files.user-selected.read-write`, and `com.apple.security.network.client`. `Scripts/check-macos-entitlements.sh` exits 0 only when all three are present.

- [ ] **Step 1: Write the failing gate**

Create `Scripts/check-macos-entitlements.sh`:

```bash
#!/usr/bin/env bash
# Asserts that the BUILT Mac app carries the App Sandbox entitlements, not merely that project.yml says it should.
#
# project.yml is regenerated on every xcodegen run and is edited by several parallel sessions, so a dropped
# CODE_SIGN_ENTITLEMENTS is a live risk. Without this gate it would surface at App Store upload — the slowest
# possible place to find it.
#
# Run from anywhere; it locates the repo root relative to itself.
set -euo pipefail

cd "$(dirname "$0")/.."

DERIVED="$(mktemp -d)"
trap 'rm -rf "$DERIVED"' EXIT

xcodebuild \
  -project Folino.xcodeproj \
  -scheme FolinoMac \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED" \
  -skipPackagePluginValidation \
  build >/dev/null

APP="$DERIVED/Build/Products/Debug/folino.app"
[ -d "$APP" ] || { echo "FAIL: $APP was not produced"; exit 1; }

# `--entitlements :-` emits the legacy blob-header format, which is not parseable plist. `--xml` is.
ENTITLEMENTS="$(codesign -d --entitlements - --xml "$APP" 2>/dev/null)"

status=0
for key in \
  com.apple.security.app-sandbox \
  com.apple.security.files.user-selected.read-write \
  com.apple.security.network.client
do
  if printf '%s' "$ENTITLEMENTS" | grep -q "<key>$key</key>"; then
    echo "ok   $key"
  else
    echo "FAIL $key is missing from the built app"
    status=1
  fi
done

exit "$status"
```

Then:
```bash
chmod +x Scripts/check-macos-entitlements.sh
```

- [ ] **Step 2: Run the gate and watch it fail**

Run: `Scripts/check-macos-entitlements.sh`

Expected: three `FAIL` lines, exit 1. The baseline measured on 2026-09-03 is that the built app carries `com.apple.security.get-task-allow` and nothing else. **If it passes here, stop** — something already set the entitlements and this task's premise is wrong.

- [ ] **Step 3: Write the entitlements file**

Create `App/Mac/FolinoMac.entitlements`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <!-- Required for Mac App Store distribution. -->
    <key>com.apple.security.app-sandbox</key>
    <true/>
    <!-- File import via NSOpenPanel (App/Mac/MacCommands.swift) and export via the save panel (ScoreUI's
         ScoreExportPresentation). Under the sandbox both go through Powerbox: only the file the user actually
         picked crosses the boundary, which is why no security-scoped bookmark is needed — LiveScoreFileImporter
         copies the bytes while that scope is open. -->
    <key>com.apple.security.files.user-selected.read-write</key>
    <true/>
    <!-- The high-quality SoundFont download. Settings compiles for macOS with that row intact and
         LiveMuseScoreGeneralProvider backs it with a real URLSessionDownloadTask; without this key the download
         fails silently once sandboxed. Also what CloudKit (Ⅵb) and Firebase (deferred) will need. -->
    <key>com.apple.security.network.client</key>
    <true/>
</dict>
</plist>
```

**Deliberately absent:** the iCloud container and App Group keys. Automatic signing regenerates the App ID capabilities and the provisioning profile when an entitlement is added, so the sub-project that needs one adds it then (spec §2).

- [ ] **Step 4: Point the target at it, and add the App Store category**

In `project.yml`, inside `FolinoMac`'s `settings.base` (after `MACOSX_DEPLOYMENT_TARGET`):

```yaml
        CODE_SIGN_ENTITLEMENTS: App/Mac/FolinoMac.entitlements
```

In `App/Mac/Info.plist`, add before `</dict>`:

```xml
	<key>LSApplicationCategoryType</key>
	<string>public.app-category.music</string>
```

The Mac App Store requires `LSApplicationCategoryType` and rejects uploads without it. Use a tab for indentation — that file is tab-indented.

- [ ] **Step 5: Regenerate and run the gate**

```bash
xcodegen generate
Scripts/check-macos-entitlements.sh
```
Expected: three `ok` lines, exit 0.

- [ ] **Step 6: Confirm the sandboxed app actually launches**

```bash
Scripts/build-macos-app.sh
open ~/Library/Developer/Xcode/DerivedData/Folino-*/Build/Products/Debug/folino.app
```

Expected: the library window opens and is **empty** — the sandbox container is new (spec §3). An empty library is the pass condition, not a failure. A crash or a launch-failure alert means Task 1 did not take: check that `~/Library/Containers/com.KeyNumber.Folino/Data/Library/Application Support/Soundfonts` was created rather than a group container path.

Import one `.mscz` through File ▸ Open to confirm Powerbox works, then quit and relaunch to confirm it persisted. Report what you saw.

- [ ] **Step 7: Run the package and app gates**

```bash
Scripts/build-macos-packages.sh
```
Expected: all packages build.

- [ ] **Step 8: Commit**

```bash
git add App/Mac/FolinoMac.entitlements App/Mac/Info.plist project.yml Scripts/check-macos-entitlements.sh
git commit -m "feat(macos): run inside the App Sandbox, and gate that on the built artifact"
```

---

## Task 3: Export — the presentation, and the Library's entry points

**Files:**
- Create: `Packages/ScoreUI/Sources/ScoreUI/ScoreExportPresentation.swift`, `Packages/ScoreUI/Tests/ScoreUITests/ScoreExportPresentationTests.swift`
- Modify: `Packages/Features/Library/Sources/Library/Screens/LibraryRootPresentations.swift:174-199`, `Packages/Features/Library/Sources/Library/Views/ScoreRowMenu.swift:58-69`, `Packages/Features/Library/Sources/Library/Views/BulkActionBar.swift:70-85`, `Packages/Features/Reader/Sources/Reader/Screens/ReaderRootScreen.swift:351-353`, `Packages/Utility/Sources/UtilityUI/ActivityViewControllerRepresentable.swift:1-2`

**Interfaces:**
- Consumes: `ScoreShareTarget` (`ScoreUI`), which is `public struct ScoreShareTarget: Identifiable, Equatable` with `public let id: UUID` and `public let urls: [URL]`.
- Produces: `public extension View { func scoreExportPresentation(target: Binding<ScoreShareTarget?>) -> some View }` in `ScoreUI`, plus `ScoreExportPlan` (see Step 3) which Task 4 does not need but the tests do.

- [ ] **Step 1: Write the failing test for the pure logic**

The presentation itself is a SwiftUI modifier and not unit-testable, but the decision it makes — one file means a save panel with a default filename, several mean a folder chooser — is pure. Extract that and test it.

Create `Packages/ScoreUI/Tests/ScoreUITests/ScoreExportPresentationTests.swift`:

```swift
import Foundation
import Testing

@testable import ScoreUI

/// Ⅷ §7: on macOS a single exported file gets a save panel seeded with its own name; several files get a folder
/// chooser instead, because a save panel cannot name more than one destination.
struct ScoreExportPlanTests {
    @Test func `one url exports as a single file, keeping its name`() {
        let plan = ScoreExportPlan(urls: [URL(fileURLWithPath: "/tmp/Now is the time.mscz")])
        #expect(plan == .single(
            url: URL(fileURLWithPath: "/tmp/Now is the time.mscz"),
            defaultFilename: "Now is the time",
        ))
    }

    @Test func `several urls export into a chosen folder`() {
        let urls = [
            URL(fileURLWithPath: "/tmp/a.mscz"),
            URL(fileURLWithPath: "/tmp/b.pdf"),
        ]
        #expect(ScoreExportPlan(urls: urls) == .multiple(urls: urls))
    }

    @Test func `an empty target exports nothing`() {
        #expect(ScoreExportPlan(urls: []) == .nothing)
    }

    @Test func `a dotted filename keeps every component but the last`() {
        let plan = ScoreExportPlan(urls: [URL(fileURLWithPath: "/tmp/BWV 1007.no.1.mscz")])
        #expect(plan == .single(
            url: URL(fileURLWithPath: "/tmp/BWV 1007.no.1.mscz"),
            defaultFilename: "BWV 1007.no.1",
        ))
    }
}
```

- [ ] **Step 2: Run it and watch it fail**

```
cd Packages/ScoreUI
```
then, in a separate call:
```
xcodebuild test -scheme ScoreUI-Package -destination 'platform=macOS' -skipPackagePluginValidation -only-testing:ScoreUITests/ScoreExportPlanTests
```
Expected: FAIL to compile — `ScoreExportPlan` does not exist.

(`cd` persists between Bash calls; do not join the two with `&&`, and do not wrap the second in `env -C` — the harness refuses both.)

- [ ] **Step 3: Write the presentation**

Create `Packages/ScoreUI/Sources/ScoreUI/ScoreExportPresentation.swift`:

```swift
import SwiftUI
import UniformTypeIdentifiers
import UtilityUI

/// What a `ScoreShareTarget` becomes on macOS. Pure, so the single-vs-multiple decision and the default filename are
/// testable without a window.
enum ScoreExportPlan: Equatable {
    case nothing
    /// A save panel, seeded with the file's own name minus its extension — the extension comes from `contentTypes`.
    case single(url: URL, defaultFilename: String)
    /// A folder chooser: a save panel names one destination, and several files need a directory.
    case multiple(urls: [URL])

    init(urls: [URL]) {
        switch urls.count {
        case 0:
            self = .nothing
        case 1:
            let url = urls[0]
            self = .single(url: url, defaultFilename: url.deletingPathExtension().lastPathComponent)
        default:
            self = .multiple(urls: urls)
        }
    }
}

/// Presents a `ScoreShareTarget`. The whole platform split lives here, so no call site carries an `#if` in its
/// modifier chain — the house rule from `UtilityUI/PlatformToolbarCompat.swift`, and the thing SwiftFormat's
/// `--ifdef no-indent` fights when it is broken.
///
/// **iOS presents the system share sheet; macOS presents a save panel.** Not a arbitrary difference: on iPhone the
/// share sheet *is* the filesystem — Mail, AirDrop and Messages are how a file leaves. On a Mac "put this where I
/// said" is the primary act and Finder owns everything downstream, so routing a file through a sharing service to
/// reach a folder is the long way round. Umbrella spec §8: capability does not vary by platform, placement does.
struct ScoreExportPresentation: ViewModifier {
    @Binding var target: ScoreShareTarget?

    func body(content: Content) -> some View {
        #if os(iOS)
        content.sheet(item: $target) { target in
            ActivityViewControllerRepresentable(items: target.urls)
        }
        #else
        content
            .fileExporter(
                isPresented: isPresentedBinding,
                item: singleItem,
                contentTypes: contentTypes,
                defaultFilename: defaultFilename,
            ) { _ in target = nil }
            .fileExporter(
                isPresented: isMultipleBinding,
                items: multipleItems,
                contentTypes: contentTypes,
            ) { _ in target = nil }
        #endif
    }

    #if os(macOS)
    private var plan: ScoreExportPlan {
        ScoreExportPlan(urls: target?.urls ?? [])
    }

    /// `.data` rather than a per-file type: a target can mix formats (bulk share of PDF + MSCZ), and the URLs already
    /// carry their own extensions, which is what the exporter writes.
    private var contentTypes: [UTType] { [.data] }

    private var singleItem: URL? {
        if case let .single(url, _) = plan { url } else { nil }
    }

    private var defaultFilename: String? {
        if case let .single(_, name) = plan { name } else { nil }
    }

    private var multipleItems: [URL] {
        if case let .multiple(urls) = plan { urls } else { [] }
    }

    private var isPresentedBinding: Binding<Bool> {
        Binding(
            get: { if case .single = plan { true } else { false } },
            set: { if !$0 { target = nil } },
        )
    }

    private var isMultipleBinding: Binding<Bool> {
        Binding(
            get: { if case .multiple = plan { true } else { false } },
            set: { if !$0 { target = nil } },
        )
    }
    #endif
}

public extension View {
    /// Presents the score files a `ScoreShareTarget` carries: a share sheet on iOS, a save panel or folder chooser on
    /// macOS. Clears the binding when the presentation finishes, cancelled or not.
    func scoreExportPresentation(target: Binding<ScoreShareTarget?>) -> some View {
        modifier(ScoreExportPresentation(target: target))
    }
}
```

- [ ] **Step 4: Run the test and watch it pass**

From `Packages/ScoreUI`:
```
xcodebuild test -scheme ScoreUI-Package -destination 'platform=macOS' -skipPackagePluginValidation -only-testing:ScoreUITests/ScoreExportPlanTests
```
Expected: 4 tests pass. State the count.

- [ ] **Step 5: Route the Library and iOS Reader through it**

In `LibraryRootPresentations.swift`, replace the `.sheet(item: $viewModel.shareTarget) { … }` block (and the comment above it explaining why the macOS branch is unreachable) with:

```swift
            .scoreExportPresentation(target: $viewModel.shareTarget)
```

In `ReaderRootScreen.swift:351-353`, replace:

```swift
        .sheet(item: $viewModel.shareTarget) { target in
            ActivityViewControllerRepresentable(items: target.urls)
        }
```
with:
```swift
        .scoreExportPresentation(target: $viewModel.shareTarget)
```

(That file is `#if os(iOS)` end to end, so this is a no-op refactor there — it exists so one modifier serves both screens.)

- [ ] **Step 6: Let macOS reach the entries, relabelled**

`ShareSubmenu`'s `companionAction` is already `(() -> Void)?` with a `nil` default (`ShareSubmenu.swift:77-85`), so macOS just passes `nil` — no overload needed.

In `ScoreRowMenu.swift`, replace the marker and the `#if` block with:

```swift
    // PARITY(macos): score-row Open in VocalTuner — the companion row is omitted on macOS because the Mac's
    //   `VocalTunerHandoff` is the no-op one: the hand-off rides the cross-app App Group, which the Mac does not
    //   join (`AppPaths.sharedContainer` is nil there, Ⅷ §2). It comes back with the App Group tasks, and only if
    //   VocalTuner ships a Mac app.
    Divider()
    ShareSubmenu(
        loadFormats: loadShareFormats, onShare: onShare, companionAction: companionHandoff,
    )
```

and add, at file scope near the other helpers in that file:

```swift
/// `nil` on macOS — see the marker at the call site. A computed value rather than an `#if` inside the call, because
/// an `#if` in a view builder's argument list is what SwiftFormat's `--ifdef no-indent` fights on every commit.
private func companionHandoffAction(_ action: @escaping () -> Void) -> (() -> Void)? {
    #if os(iOS)
    action
    #else
    nil
    #endif
}
```

…with `companionHandoff` in the call above defined as `companionHandoffAction(onOpenInVocalTuner)`. Match the surrounding file's shape — `scoreRowMenuItems` is a free `@ViewBuilder` function, so this may need to be a `let` at the top of that function rather than a property.

In `BulkActionBar.swift`, delete the `#if os(iOS)` / `#endif` around the format `ForEach` (keeping the `if !availableShareFormats.isEmpty` guard and the `Divider()`), and delete the marker above it outright.

- [ ] **Step 7: Rename the macOS copy to "Export…"**

The label is in exactly one place: `ShareSubmenu.body` renders `L10n.Common.share` (`ShareSubmenu.swift:94-99`). **Do not change `L10n.Common.share`** — it is shared with iOS and with other call sites.

Add a new key to `Packages/ScoreUI`'s string catalog, `scoreUI.share.export.action` → `Export…` / `書き出す…`, and select it inside `ShareSubmenu`:

```swift
        } label: {
            Label {
                menuTitle
            } icon: {
                Image(systemName: "square.and.arrow.up")
            }
        }
    }

    /// macOS opens a save panel rather than a share sheet (Ⅷ §7), and "Share ▸ PDF" opening a save panel is a
    /// mismatch. Umbrella spec §8: capability does not vary by platform, wording and placement do.
    @ViewBuilder
    private var menuTitle: some View {
        #if os(iOS)
        L10n.Common.share
        #else
        Text("scoreUI.share.export.action", bundle: .module)
        #endif
    }
```

Do the same for `bulkShareFormatLabel`'s enclosing menu label in `BulkActionBar.swift` if it carries its own "Share" string; if it renders only the format rows, there is nothing to rename there.

**Do not change any iOS-visible copy.** Verify by diffing a rendered `#Preview` of the row menu on iOS before and after, or by confirming the iOS branch is byte-identical.

- [ ] **Step 8: Delete the retired marker**

Remove lines 1-2 of `Packages/Utility/Sources/UtilityUI/ActivityViewControllerRepresentable.swift` (the `PARITY(macos): system share sheet …` marker). The type stays iOS-only; it simply no longer represents a gap.

- [ ] **Step 9: Run every affected gate**

```
Scripts/build-macos-packages.sh
```
then from `Packages/Features/Library`:
```
xcodebuild test -scheme Library-Package -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max,OS=26.5' -skipPackagePluginValidation
```
then from `Packages/Features/Reader`:
```
xcodebuild test -scheme Reader-Package -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max,OS=26.5' -skipPackagePluginValidation
```
Expected: Library ~136 tests pass, Reader ~510 tests pass. **State both counts.** Then `Scripts/build-macos-app.sh` and the iOS app build.

- [ ] **Step 10: Commit**

```bash
git add Packages/ScoreUI Packages/Features/Library Packages/Features/Reader Packages/Utility
git commit -m "feat(macos): a score can leave the app — save panel export from the library"
```

---

## Task 4: Export from the Mac score window

`ReaderRootScreen` is `#if os(iOS)` from line 15 to the end of the file, so there is no `#else` to fill. The Mac's reader is a sibling, `MacReaderRootScreen`, which already receives a `ScoreShareService` and never offers it.

**Files:**
- Modify: `Packages/Features/Reader/Sources/Reader/Screens/Mac/MacReaderRootScreen.swift:6-9` (marker), `:139-158` (the content `VStack`)

**Interfaces:**
- Consumes: `scoreExportPresentation(target:)` from Task 3; `ReaderViewModel.shareTarget` (`var shareTarget: ScoreShareTarget?`, `ReaderViewModel.swift:195`); the share entry points in `ReaderViewModel+Sharing.swift`.
- Produces: nothing other tasks consume.

- [ ] **Step 1: Add the toolbar item**

The view model already has everything: `availableShareFormats()` is `@Sendable`-compatible `async -> [ScoreShareFormatOption]` and `requestShare(format:)` is `async` (`ReaderViewModel+Sharing.swift:9-25`). Use **`ShareFormatMenuItems`**, not `ShareSubmenu` — the former is menu *content*, which is what a standalone button wants (one click expands the formats); the latter wraps it in a nested "Share" row meant for an ellipsis menu (`ShareSubmenu.swift:8-11`).

Attach to the outer `VStack` in `MacReaderRootScreen`'s body — the one at `:143` holding `MacScoreContentView` and `MacTransportBar`:

```swift
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    ShareFormatMenuItems(
                        loadFormats: { await viewModel.availableShareFormats() },
                        onShare: { format in Task { await viewModel.requestShare(format: format) } },
                    )
                } label: {
                    Label {
                        Text("reader.export.action", bundle: .module)
                    } icon: {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
        }
        .scoreExportPresentation(target: $viewModel.shareTarget)
```

`companionAction` is omitted rather than passed `nil` — it defaults to `nil` (`ShareFormatMenuItems.swift:21-28`), and the Mac has no VocalTuner to hand off to.

Add `reader.export.action` → `Export…` / `書き出す…` to the Reader package's string catalog.

`viewModel` here is a `let` on the screen; `$viewModel.shareTarget` needs `@Bindable`. Check how `MacReaderRootScreen` already declares it and follow that — `SharePreparation` in `LibraryRootPresentations.swift:174-176` is the precedent for adding `@Bindable` for exactly this reason.

**Not `MacTransportBar`**: it renders only when `isTransportAvailable` (`MacTransportBar.swift:19,38-45`), so an export button living there would vanish for a score that is still loading or cannot play — and "cannot play" is not "cannot export".

**Not the menu bar.** File ▸ Export… is the Mac-idiomatic home, but it lives in `App/Mac/MacCommands.swift`, which a parallel session owns. Deferred to a marker in Task 7.

- [ ] **Step 2: Narrow the marker**

Replace the `share /` clause in the `PARITY(macos)` marker at `MacReaderRootScreen.swift:6-9`. The inspectors and the score ⇄ original-PDF switch are still missing, so the marker stays — it just stops claiming share is:

```swift
// PARITY(macos): the Mac reading surface's chrome — this screen renders the score in all three display modes, shows
//   an imported PDF and committed ink, plays them from a transport bar, edits them from the menu bar and the
//   keyboard, and exports through a save panel. The inspectors and the score ⇄ original-PDF switch are still
//   iOS-only; see `ReaderRootScreen` for the surface being caught up to.
```

- [ ] **Step 3: Build and verify by hand**

```
Scripts/build-macos-app.sh
```
Expected: BUILD SUCCEEDED. Then open the app, open a score, and confirm: the toolbar shows the export control; choosing a format opens a save panel seeded with the score's name; the file lands where you chose and opens.

**Repeat for a PDF-backed score** — those take a different path through `ReaderViewModel+Sharing` and are the case most likely to produce an empty file.

- [ ] **Step 4: Run the Reader suite**

From `Packages/Features/Reader`:
```
xcodebuild test -scheme Reader-Package -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max,OS=26.5' -skipPackagePluginValidation
```
Expected: ~510 tests pass. State the count.

- [ ] **Step 5: Commit**

```bash
git add Packages/Features/Reader
git commit -m "feat(macos): export from the score window's toolbar"
```

---

## Task 5: The `platform :mac` fastlane block

**Files:**
- Modify: `fastlane/Fastfile:1-2` (default platform comment), append a `platform :mac` block after `:ios` ends

**Interfaces:**
- Consumes: nothing in this repo.
- Produces: `fastlane mac archive_and_upload version:X.Y.Z build:N`, `fastlane mac wait_for_build …`, `fastlane mac submit …`.

- [ ] **Step 1: Write the block**

Append to `fastlane/Fastfile`, after the `platform :ios do … end` block:

```ruby
platform :mac do
  # `before_all` is scoped to its platform block: the :ios one above does NOT run for these lanes.
  before_all do
    app_store_connect_api_key(
      key_id: ENV.fetch("ASC_KEY_ID"),
      issuer_id: ENV.fetch("ASC_ISSUER_ID"),
      key_filepath: ENV.fetch("ASC_KEY_PATH"),
      duration: 1200,
      in_house: false
    )
  end

  desc "Archive Release build and upload the Mac .pkg to App Store Connect (no submit)"
  lane :archive_and_upload do |options|
    version = options.fetch(:version)
    build = options.fetch(:build)

    gym(
      scheme: "FolinoMac",
      configuration: "Release",
      export_method: "app-store",
      output_directory: "build/fastlane",
      output_name: "Folino-mac-#{version}-#{build}",
      clean: true,
      derived_data_path: "build/DerivedDataMac",
      xcargs: "-skipPackagePluginValidation -skipMacroValidation",
      export_options: {
        method: "app-store",
        signingStyle: "automatic",
        teamID: CredentialsManager::AppfileConfig.try_fetch_value(:team_id)
      },
      export_xcargs: "-allowProvisioningUpdates"
    )

    # No Crashlytics dSYM upload, unlike the iOS lane: the Mac composes the no-op crash reporter because there is
    # no Firebase registration for it yet (see the PARITY(macos) marker in AppBootstrap). Uploading symbols for an
    # app that never reports would only make the absence harder to notice.

    # `platform` defaults to "ios". Without it this uploads a Mac .pkg against the iOS platform of the shared
    # app record — the two platforms live under one record, which is what makes the purchase universal.
    upload_to_app_store(
      app_identifier: "com.KeyNumber.Folino",
      platform: "osx",
      app_version: version,
      pkg: lane_context[SharedValues::PKG_OUTPUT_PATH],
      skip_screenshots: true,
      skip_metadata: true,
      submit_for_review: false,
      force: true,
      precheck_include_in_app_purchases: false,
      run_precheck_before_submit: false
    )
  end

  desc "Poll App Store Connect until the uploaded Mac build finishes processing"
  lane :wait_for_build do |options|
    require "spaceship"

    version = options.fetch(:version)
    build = options.fetch(:build).to_s
    timeout = 1800
    interval = 30

    app = Spaceship::ConnectAPI::App.find("com.KeyNumber.Folino") \
      || UI.user_error!("App not found in App Store Connect")

    started_at = Time.now
    loop do
      builds = Spaceship::ConnectAPI::Build.all(
        app_id: app.id,
        version: version,
        build_number: build,
        includes: "preReleaseVersion"
      )
      # CURRENT_PROJECT_VERSION is project-wide (project.yml:13), so the same version+build string exists on BOTH
      # platforms of this app record. Without the platform filter this lane happily reports the iOS build as ready.
      target = builds.find do |b|
        b.version == build &&
          b.pre_release_version&.version == version &&
          b.pre_release_version&.platform == "MAC_OS"
      end

      state = target&.processing_state
      case state
      when "VALID"
        UI.success("Mac build #{version} (#{build}) is processed and ready to submit.")
        break
      when "INVALID", "FAILED"
        UI.user_error!("Mac build processing failed (state=#{state}).")
      end

      if Time.now - started_at > timeout
        UI.user_error!("Timed out after #{timeout}s waiting for Mac build #{version} (#{build}).")
      end

      UI.message("Waiting for processing... (state=#{state || 'not yet visible'})")
      sleep interval
    end
  end

  desc "Push Mac metadata + release notes (+ optional screenshots), then submit for review."
  lane :submit do |options|
    version = options.fetch(:version)
    build = options.fetch(:build)
    screenshots_path = options[:screenshots_path]   # may be nil

    upload_to_app_store(
      app_identifier: "com.KeyNumber.Folino",
      platform: "osx",
      app_version: version,
      build_number: build.to_s,
      skip_binary_upload: true,
      skip_screenshots: screenshots_path.nil?,
      screenshots_path: screenshots_path,
      overwrite_screenshots: !screenshots_path.nil?,
      # Metadata stays out of this lane until Mac copy exists as its own directory: fastlane/metadata is the iOS
      # tree, and pushing it here would put iOS release notes on the Mac version. Mac metadata is entered by hand
      # in App Store Connect until a Mac release is actually cut.
      skip_metadata: true,
      submit_for_review: true,
      automatic_release: true,
      force: true,
      precheck_include_in_app_purchases: false
    )
  end
end
```

- [ ] **Step 2: Verify the lanes parse and are visible**

Run: `bundle exec fastlane lanes`
(If the repo has no Gemfile, run `fastlane lanes`.)

Expected: a `mac` section listing `archive_and_upload`, `wait_for_build`, `submit`. A Ruby syntax error fails here rather than mid-release. **Do not run any lane** — they upload.

- [ ] **Step 3: Record the two human-gated prerequisites**

Append to the QA sheet (Task 8 creates it; if it does not exist yet, create it with just this section):

```markdown
## Prerequisites only the account holder can do

1. **Enable the macOS platform on the App Store Connect record** (app id `6766994527`, `com.KeyNumber.Folino`).
   The Mac app shares the iOS record by design — that is what makes Ⅶ's purchase universal — but the macOS
   platform has to be added to it before any `.pkg` will upload.
2. **A Mac Installer Distribution certificate.** A Mac App Store `.pkg` is signed with a different certificate
   from the app-signing one. Whether `-allowProvisioningUpdates` mints it automatically is UNVERIFIED; the first
   `fastlane mac archive_and_upload` is what settles it. If it fails, create it in the Developer portal.
```

- [ ] **Step 4: Commit**

```bash
git add fastlane/Fastfile docs/superpowers/plans/2026-09-03-macos-distribution-qa.md
git commit -m "build(macos): a fastlane mac lane, with the four ways it is not the iOS lane"
```

---

## Task 6: Mac App Store screenshots

**Files:**
- Create: `App/MacScreenshot/MacScreenshotSetup.swift`, `Scripts/capture-mac-screenshots.sh`, `Scripts/flatten-screenshot.swift`
- Modify: `project.yml` (new `FolinoMacScreenshot` target + scheme)

**Interfaces:**
- Consumes: the `FolinoMac` sources, compiled a second time under `-D SCREENSHOT_ENABLED`.
- Produces: PNGs at `fastlane/screenshots-mac/<App Store locale>/<order>_<alias>_<scene>.png`, at exactly 2880×1800 (Retina) or 1440×900 (1×), with no alpha channel.

- [ ] **Step 1: Add the screenshot target**

In `project.yml`, add a `FolinoMacScreenshot` target that copies `FolinoMac`'s `sources` and `dependencies` verbatim, plus `- path: App/MacScreenshot`, and this `settings.base`:

```yaml
        # A distinct bundle ID is not cosmetic here: on macOS it means a distinct SANDBOX CONTAINER, so seeding a
        # fixture library cannot touch the real one at ~/Library/Containers/com.KeyNumber.Folino. It also keeps the
        # fixture .mscz and the "replace the library" launch argument out of the shipping binary. Same reasoning as
        # FolinoScreenshot on iOS (see its comment above), with an extra reason macOS supplies.
        PRODUCT_BUNDLE_IDENTIFIER: com.KeyNumber.Folino.macScreenshot
        # No explicit PRODUCT_NAME: defaults to the target name, so this builds FolinoMacScreenshot.app rather than
        # sharing folino.app with FolinoMac.
        # Its OWN plist, not App/Mac/Info.plist: it needs an NSPrincipalClass, which is the only way to run code
        # before NSApplication launches without editing FolinoMacApp.swift (owned by a parallel session).
        INFOPLIST_FILE: App/MacScreenshot/Info.plist
        CODE_SIGN_ENTITLEMENTS: App/Mac/FolinoMac.entitlements
        GENERATE_INFOPLIST_FILE: NO
        ASSETCATALOG_COMPILER_APPICON_NAME: folino
        ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME: AccentColor
        MACOSX_DEPLOYMENT_TARGET: "15.0"
        OTHER_SWIFT_FLAGS:
          - $(inherited)
          - -D SCREENSHOT_ENABLED
```

Also add it to the `FolinoMac` scheme's build targets as `FolinoMacScreenshot: [test]`, mirroring the comment at `project.yml:369-376`: it compiles the same App sources, so it is where a removed Feature API surfaces as a compile error instead of as a broken deliverable at release time.

Run `xcodegen generate`, then `xcodebuild -project Folino.xcodeproj -scheme FolinoMac -destination 'platform=macOS' -skipPackagePluginValidation build` and confirm both targets build.

- [ ] **Step 2: Size the window, and nothing else**

**The library is seeded by hand, once.** The screenshot target has its own bundle ID and therefore its own sandbox container, which persists between runs — so the operator imports the fixture score once and every later capture reuses it. Programmatic seeding would mean reaching into `AppBootstrap`'s composition from a file that must not touch the App scene tree, to save a step a human is already present for (§9's inspection pass). The capture script asserts the library is non-empty and prints the fix if it is not (Step 4).

That leaves one thing that does need code: **the window frame.**

Create `App/MacScreenshot/Info.plist` as a copy of `App/Mac/Info.plist` plus:

```xml
	<key>NSPrincipalClass</key>
	<string>ScreenshotApplication</string>
```

Create `App/MacScreenshot/MacScreenshotSetup.swift`:

```swift
import AppKit

/// Sizes every window to an App Store screenshot size, and does nothing else.
///
/// **Why `NSPrincipalClass` rather than a hook in the app.** `FolinoMacApp.swift` belongs to a parallel session and
/// must not be edited (plan constraints), and nothing else runs before `NSApplication` launches. `NSPrincipalClass`
/// is the supported way in, it lives entirely in this target's own `Info.plist`, and the shipping app never names
/// this class.
///
/// **Why the FRAME and not `defaultSize`.** `screencapture -l` captures a window's frame, title bar included.
/// SwiftUI's `defaultSize` sizes the *content*, so asking for 1440 × 900 there yields roughly 1440 × 928 delivered —
/// off the App Store's accepted list, and rejected hours later at upload rather than here.
final class ScreenshotApplication: NSApplication {
    /// 1440 × 900 points: 2880 × 1800 on a Retina display, 1440 × 900 on a 1× one. Both are accepted Mac App Store
    /// screenshot sizes, so neither needs scaling.
    private static let frameSize = NSSize(width: 1440, height: 900)

    override func run() {
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main,
        ) { note in
            guard let window = note.object as? NSWindow else { return }
            Self.resize(window)
        }
        super.run()
    }

    private static func resize(_ window: NSWindow) {
        guard window.frame.size != frameSize else { return }
        var frame = window.frame
        // Keep the top-left corner put: AppKit frames grow upward, so changing only `size` would move the title bar.
        frame.origin.y += frame.size.height - frameSize.height
        frame.size = frameSize
        window.setFrame(frame, display: true)
    }
}
```

Nothing here is gated on `SCREENSHOT_ENABLED` — the whole file is compiled only into this target, which is a stronger guarantee than a define. Keep the `-D SCREENSHOT_ENABLED` flag anyway: it is what any *shared* file would gate on later.

- [ ] **Step 3: Write the flattener**

`screencapture -o` drops the window shadow, but the window's **rounded corners remain transparent pixels**, and App Store Connect rejects screenshots carrying an alpha channel. This step is not optional.

Create `Scripts/flatten-screenshot.swift` (and `chmod +x` it):

```swift
#!/usr/bin/env swift

// Flattens PNGs onto an opaque white background, in place, preserving pixel dimensions.
//
// `screencapture -o` removes the window shadow but leaves the rounded corners transparent, and App Store Connect
// rejects screenshots with an alpha channel. Every Mac capture ends here.
//
// Usage: Scripts/flatten-screenshot.swift <file.png> [<file.png> …]

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

func flatten(_ path: String) -> Bool {
    let url = URL(fileURLWithPath: path)
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else {
        FileHandle.standardError.write(Data("cannot read \(path)\n".utf8))
        return false
    }

    let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
    // `noneSkipLast` is what drops the alpha channel from the written PNG.
    guard let context = CGContext(
        data: nil,
        width: image.width,
        height: image.height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue,
    ) else {
        FileHandle.standardError.write(Data("cannot create a context for \(path)\n".utf8))
        return false
    }

    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(rect)
    context.draw(image, in: rect)

    guard let flattened = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(
              url as CFURL, UTType.png.identifier as CFString, 1, nil,
          )
    else {
        FileHandle.standardError.write(Data("cannot write \(path)\n".utf8))
        return false
    }
    CGImageDestinationAddImage(destination, flattened, nil)
    guard CGImageDestinationFinalize(destination) else {
        FileHandle.standardError.write(Data("finalize failed for \(path)\n".utf8))
        return false
    }
    return true
}

let paths = Array(CommandLine.arguments.dropFirst())
guard !paths.isEmpty else {
    FileHandle.standardError.write(Data("usage: flatten-screenshot.swift <file.png> …\n".utf8))
    exit(2)
}
exit(paths.allSatisfy(flatten) ? 0 : 1)
```

- [ ] **Step 4: Write the window-id helper and the capture script**

Create `Scripts/mac-window-id.swift` (and `chmod +x` it):

```swift
#!/usr/bin/env swift

// Prints the CGWindowID of the frontmost on-screen window owned by the named process, or exits 1 if there is none.
// `screencapture -l` needs this number and there is no shell command that yields it.
//
// Usage: Scripts/mac-window-id.swift <owner name>

import CoreGraphics
import Foundation

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: mac-window-id.swift <owner name>\n".utf8))
    exit(2)
}
let owner = CommandLine.arguments[1]

let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []

// Layer 0 is a normal window; menus, panels and shadows sit above it.
let match = windows.first {
    $0[kCGWindowOwnerName as String] as? String == owner
        && $0[kCGWindowLayer as String] as? Int == 0
}

guard let id = match?[kCGWindowNumber as String] as? Int else { exit(1) }
print(id)
```

Create `Scripts/capture-mac-screenshots.sh` (and `chmod +x` it):

```bash
#!/usr/bin/env bash
#
# Capture the Mac App Store screenshots.
#
# Unlike the iOS capture, this drives the REAL app: there is no simulator to render into, and ScreenshotKitCapture
# is UIKit-bound. The app is launched once per language, its window is captured with `screencapture`, and the PNG is
# flattened — see docs/superpowers/specs/2026-09-03-macos-distribution-design.md §6.
#
# The screenshot target keeps its own sandbox container, so its library persists between runs. Seed it by hand once:
# launch the app and import a score. This script refuses to run against an empty library rather than shipping shots
# of an empty window.
#
# Requires: an unlocked screen, Screen Recording permission for this terminal, and a display of at least 1440x900pt.
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="FolinoMacScreenshot"
BUNDLE_ID="com.KeyNumber.Folino.macScreenshot"
CONTAINER="$HOME/Library/Containers/$BUNDLE_ID/Data/Library/Application Support/folino"
OUT_ROOT="fastlane/screenshots-mac"

# Same language:region list as Scripts/capture-screenshots.sh, and the same App Store folder names.
LOCALES=("en:en-US" "ja:ja" "ko:ko" "zh-Hans:zh-Hans" "zh-Hant:zh-Hant")

DERIVED="$(mktemp -d)"
trap 'rm -rf "$DERIVED"' EXIT

echo "==> building $APP_NAME"
xcodebuild \
  -project Folino.xcodeproj \
  -scheme FolinoMac \
  -target "$APP_NAME" \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED" \
  -skipPackagePluginValidation \
  build >/dev/null

APP="$DERIVED/Build/Products/Debug/$APP_NAME.app"
[ -d "$APP" ] || { echo "FAIL: $APP was not produced"; exit 1; }

if [ ! -f "$CONTAINER/Folino.sqlite" ]; then
  echo "FAIL: the screenshot app's library is empty."
  echo "      Launch $APP, import a score, quit, then re-run this script."
  echo "      (Its container is $CONTAINER — separate from the real app's, by design.)"
  exit 1
fi

for entry in "${LOCALES[@]}"; do
  lang="${entry%%:*}"
  store_locale="${entry##*:}"
  out_dir="$OUT_ROOT/$store_locale"
  mkdir -p "$out_dir"

  echo "==> $lang"
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  open -n "$APP" --args -AppleLanguages "($lang)"

  window_id=""
  for _ in $(seq 1 60); do
    if window_id="$(Scripts/mac-window-id.swift "$APP_NAME" 2>/dev/null)"; then
      break
    fi
    window_id=""
    sleep 0.5
  done
  [ -n "$window_id" ] || { echo "FAIL: no window appeared for $lang within 30s"; exit 1; }
  # Let the score finish engraving before the shutter. A shot of a spinner exits 0 just as happily.
  sleep 3

  out="$out_dir/01_score_ScoreWindow.png"
  screencapture -o -l "$window_id" "$out"
  Scripts/flatten-screenshot.swift "$out"

  width="$(sips -g pixelWidth "$out" | awk '/pixelWidth/ {print $2}')"
  height="$(sips -g pixelHeight "$out" | awk '/pixelHeight/ {print $2}')"
  case "${width}x${height}" in
    2880x1800|1440x900) echo "    $out  ${width}x${height}" ;;
    *)
      echo "FAIL: $out is ${width}x${height}; the App Store accepts 2880x1800 or 1440x900."
      echo "      The window frame is set by ScreenshotApplication (App/MacScreenshot)."
      exit 1
      ;;
  esac
done

osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
echo "==> done. LOOK AT THE PNGs — this capture is not self-verifying."
```

Add `fastlane/screenshots-mac/` to `.gitignore` alongside the existing screenshots entry.

**One scene to start.** The script captures a single shot per locale; adding more means adding scenes to seed and a way to select them, which is worth doing only once the first one is confirmed good.

- [ ] **Step 5: Run it and look at the output**

```
Scripts/capture-mac-screenshots.sh
```

Then **open the PNGs and look at them.** The `app-store-screenshots` skill's standing warning applies unchanged: the capture is not self-verifying, and exit 0 does not mean the pixels are right. Check that the score rendered (not a spinner), that the window chrome is complete, and that the language actually changed between locales.

Three things will stop this and none is automatable: `screencapture` needs Screen Recording permission granted to the terminal (macOS re-prompts periodically), the screen must be unlocked, and the display must be at least 1440 × 900 points.

- [ ] **Step 6: Commit**

```bash
git add project.yml App/MacScreenshot Scripts/capture-mac-screenshots.sh Scripts/flatten-screenshot.swift Scripts/mac-window-id.swift .gitignore
git commit -m "build(macos): App Store screenshots from the real Mac window"
```

---

## Task 7: Record what Ⅷ deliberately did not do

**Files:**
- Modify: `App/Mac/SharedContainerTasks.swift:1-6`, `App/Shared/AppBootstrap.swift:104-107`, `App/Mac/MacCommands.swift` (marker only — see the constraint below), `Packages/Features/Reader/Sources/Reader/Screens/Mac/MacReaderRootScreen.swift`, `App/Mac/Info.plist`, `project.yml`
- Regenerate: `docs/engineering/ios-android-parity.md`

**Interfaces:** none — this task produces documentation and ledger rows.

- [ ] **Step 1: Split the `SharedContainerTasks` marker into two kinds of thing**

Its current text lumps "macOS has no such concept" together with "not built yet". Replace the header marker in `App/Mac/SharedContainerTasks.swift` with:

```swift
// PARITY(macos): cross-app App Group tasks — the Mac schedules three of the five, and will not schedule the other
//   two ever. Deferred gaps: shared-SoundFont reconciliation, the capability stamp, and the cross-app score drain.
//   They need the App Group entitlement, a `CFBundleURLTypes` declaration for `folino://open-score`, and the
//   removal of `AppPaths.sharedContainer`'s macOS gate (Ⅷ §2) — all three together, never separately.
//   NOT gaps, and never will be: the playlists index and the incoming-share drain. Both exist to serve a Share
//   Extension, and macOS has none.
```

Update the type's doc comment below it to match — it currently says "decline all five", which stays true, but its reasoning should point at the split above.

- [ ] **Step 2: Update the Firebase marker**

At `App/Shared/AppBootstrap.swift:104-107`, note that the sandbox half is now done:

```swift
        // PARITY(macos): Firebase registration — FirebaseAnalytics ships a macOS slice and Crashlytics is a source
        //   target, and both are already LINKED into the Mac binary through Packages/Infrastructure/Package.swift;
        //   the no-op is at this call site, not at the link line. `com.apple.security.network.client` is now
        //   declared (Ⅷ §2), so the sandbox is no longer a blocker either. What is missing is a console
        //   registration for a Mac app sharing com.KeyNumber.Folino, its own GoogleService-Info.plist, and a
        //   decision on attaching the upload-symbols post-build script. Until then the Mac composes the no-ops.
```

- [ ] **Step 3: Record the two deferred entry points**

**`App/Mac/MacCommands.swift` is owned by a parallel session.** Add *only* the marker comment, nothing else, and expect to resolve a conflict on it at merge:

```swift
// PARITY(macos): Finder document types — `.mscz` double-click and Open With do not reach folino; the open panel
//   below is the only import route. Needs `CFBundleDocumentTypes` in `App/Mac/Info.plist` plus an open handler in
//   the scene layer, which is why Ⅷ left it alone: that layer was being rewritten concurrently.
```

And beside the export toolbar item added in Task 4, in `MacReaderRootScreen.swift`:

```swift
        // PARITY(macos): File ▸ Export… — export is reachable from this toolbar and from the library rows, but not
        //   from the menu bar, which is its Mac-idiomatic home. The command belongs in `App/Mac/MacCommands.swift`,
        //   a file a parallel session was rewriting when Ⅷ landed. Placement, not capability.
```

- [ ] **Step 4: Decide the two cheap plist items**

Both touch only `App/Mac/Info.plist` and `project.yml`, never the scene layer, so neither risks the conflict that deferred Step 3:

- **`UTImportedTypeDeclarations`** — copy the score UTIs from `App/Info.plist:135-` into the Mac plist. Today `ScoreFileTypes.allowed` resolves through `dyn.*` types on macOS, which works by accident. This is independent of the open handler.
- **`PrivacyInfo.xcprivacy`** — add it to `FolinoMacScreenshot` and `FolinoMac` sources as a resource, matching the `Folino` target. Required-reason enforcement is iOS-family only, but the privacy label belongs to the shared app record.

Do both unless one turns out to change behavior, in which case report why and leave it.

- [ ] **Step 5: Regenerate the ledger**

```
Scripts/parity-report.py
```

Then read `docs/engineering/ios-android-parity.md` and confirm: `AppPaths`'s document-root row is **gone**, the `ActivityViewControllerRepresentable` and `BulkActionBar` share rows are **gone**, the `ScoreRowMenu` and `MacReaderRootScreen` rows are **narrowed**, and two new rows (Finder document types, File ▸ Export…) are present. **Check that no row is truncated mid-sentence** — a continuation line with only one leading space is silently dropped (`parity-report.py:50`).

- [ ] **Step 6: Commit**

```bash
git add App Packages docs/engineering/ios-android-parity.md project.yml
git commit -m "docs(macos): separate what macOS will never need from what Ⅷ deferred"
```

---

## Task 8: The QA sheet

**Files:**
- Create/extend: `docs/superpowers/plans/2026-09-03-macos-distribution-qa.md`

**Interfaces:** none.

- [ ] **Step 1: Write the sheet**

Ⅷ produces almost no new user-visible surface, so its acceptance is mostly mechanical — but the sandbox changes where every byte lives, and that is exactly the kind of change whose failures look like something else. Each item says what to do, what passing looks like, and **what a failure would be mistaken for**.

Sections, in this order:

1. **Prerequisites only the account holder can do** — already written in Task 5, Step 3.
2. **Before you start** — unlock the screen (hosted Mac tests hang otherwise, and `screencapture` refuses); grant Screen Recording to the terminal.
3. **Sandbox acceptance:**
   - *The app launches at all.* This is the Task 1 fix's real test — `prepareDirectories()` throws into `failure` if the SoundFont directory cannot be created, so a regression shows up as a broken app, not a missing SoundFont.
   - *The library is empty, and Mac settings have reset to defaults.* **Both are the expected result**, not bugs: the container is new. Three directories stopped being read — `~/Library/Application Support/folino/`, `~/Library/Group Containers/group.com.KeyNumber.shared/Soundfonts/`, and `~/Library/Preferences/com.KeyNumber.Folino.plist`. Nothing was deleted. Include the by-hand `cp` into `~/Library/Containers/com.KeyNumber.Folino/Data/Library/Application Support/folino/` for a test library worth keeping.
   - *Import through File ▸ Open*, then relaunch and confirm it persisted.
   - *Drag-and-drop import from Finder* — `MacLibraryBrowser.swift:95` has a `.dropDestination(for: URL.self)`, a second import route that reaches the sandbox through a pasteboard extension rather than Powerbox. It is not covered by the open-panel test.
   - *The high-quality SoundFont download completes.* **Trigger it explicitly.** The auto-download requires Wi-Fi (`LiveMuseScoreGeneralProvider.swift:140-145`, `allowsCellularAccess = false`), so a wired Mac never starts it on its own — and "nothing happened" would be misread as a `network.client` failure.
   - *Playback works.* **Release build**, per the standing rule that a Debug Mac build's playback is unrepresentative (swifty-synth is unoptimized there).
4. **Export acceptance:** from a library row; from a bulk selection of two scores (expect a folder chooser, not a save panel); from the score window toolbar; for a PDF-backed score. Each file lands where chosen, with the expected name, and opens. Confirm the macOS copy reads **Export…**, not Share.
5. **Screenshots:** every PNG is exactly 2880×1800 or 1440×900, has no alpha channel, and *is looked at*. Note the standing warning: the capture is not self-verifying and exit 0 proves nothing about the pixels.
6. **Not verified by this sheet**, and why: actual App Store upload (blocked on Ⅵb / SP2 shipping), Crashlytics on Mac (no Firebase registration), Finder double-click (deferred), File ▸ Export… (deferred).

- [ ] **Step 2: Commit**

```bash
git add docs/superpowers/plans/2026-09-03-macos-distribution-qa.md
git commit -m "docs(macos): the Ⅷ QA sheet, and what each failure would be mistaken for"
```

---

## Final gate

Run all of these and **state the count for each**, not a verdict:

```
Scripts/build-macos-packages.sh
Scripts/build-macos-app.sh
Scripts/check-macos-entitlements.sh
xcodebuild test -project Folino.xcodeproj -scheme FolinoMac -destination 'platform=macOS' -skipPackagePluginValidation
xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max,OS=26.5' -skipPackagePluginValidation build
```

and, from each package directory, the Reader, Library, and Editor suites plus `FolinoTests`.

Then hand the QA sheet to the user. **Do not merge to `main`** — that is the user's call, and `project.yml`, `App/Mac/Info.plist`, `App/Mac/SharedContainerTasks.swift`, and `App/Mac/MacCommands.swift` are all files the parallel library-chooser session may also have touched.
