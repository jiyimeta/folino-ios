# Mac App Shell (Sub-project Ⅲb) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn Ⅲa's macOS-capable packages into a running Mac app that opens the library, renders a score, and plays it back.

**Architecture:** A second app target `FolinoMac` in the same Xcode project, sharing the bundle ID and a three-way split of `App/` (`Shared` / `iOS` / `Mac`). One `WindowGroup(for: ScoreItemID.self)` presenting a `NavigationSplitView` — library in the sidebar, Reader in the detail — so macOS supplies window tabbing for free. `Library` keeps one list and forks only its selection *chrome*; `Reader` keeps its view model and gets a separate Mac root screen with AppKit scroll hosts ported from swift-sheet-music's macOS example; `Infrastructure/Audio` is un-gated rather than abstracted.

**Tech Stack:** Swift 6.3, SwiftUI, AppKit, SwiftPM, XcodeGen 2.42.0, Xcode 26.6 / macOS 26.5 SDK, swift-sheet-music 2.3.1.

**Spec:** `docs/superpowers/specs/2026-08-31-macos-app-shell-design.md` (and its parent, `docs/superpowers/specs/2026-08-31-macos-app-design.md`)

## Global Constraints

- **iOS floor 18.0, macOS floor 15.0.** Every package and both app targets. iOS-26-only API stays behind `Packages/Utility/Sources/UtilityUI/GlassEffectCompat.swift`-shaped helpers.
- **`if #available(iOS 26, *)` does not guard macOS.** The `*` wildcard is satisfied on every platform not named. Write `if #available(iOS 26, macOS 26, *)`.
- **No iOS regression, ever.** Every task verifies the iOS app build before committing. The iOS app's appearance must not change except where a task says it does and shows a preview.
- **`public` is a decision.** New symbols get no access modifier; promote only when something outside the module references them. macOS branches keep exactly their iOS counterpart's access level.
- **`PARITY(macos):` grammar.** `Format: PARITY(<android|ios|macos>): <title> — <what the other platform still needs>`. Continuation lines repeat the comment token and indent **two or more** spaces (`Scripts/parity-report.py:50`); one space silently truncates the ledger row. Place the marker **outside** any `#if os(iOS)` block. Never hand-edit `docs/engineering/ios-android-parity.md` — the `parity-ledger` pre-commit hook regenerates it.
- **The house pattern for iOS-only SwiftUI is a compat helper in `UtilityUI`** (`PlatformToolbarCompat.swift`), iOS byte-for-byte unchanged, macOS neutral. Exception: Task 16, which is the deliberate migration off that pattern.
- **Divergence is paired files, not `#if` jungles.** Same type name in `App/iOS/` and `App/Mac/`; reserve `#if` for one-liners and file-scope gates.
- **No partial staging** (`git add -p`). Stage whole files. The pre-commit hook (SwiftFormat + `swiftlint --fix`) writes fixes back to disk and fails until clean — re-`git add` and re-commit.
- **`swift test` does not work in this repo.** Package tests go through `xcodebuild test -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation`. `swift build --package-path <pkg>` on the macOS host IS the macOS gate and works.
- **Regenerate the project after every `project.yml` edit**: `xcodegen generate`, run **from the worktree directory with no `--spec` / `--project` flags**.
- **Comment style:** reflow `//` / `///` paragraphs at 120 columns.
- **App name is lowercase `folino` anywhere a user can read it.** `Folino` is for type names, schemes, bundle IDs.
- **Do not add an `AVAudioEngineConfigurationChange` observer.** That belongs to sub-project Ⅱ, in ssm. A second observer races the engine's own teardown.

## Working directory

Everything happens in the worktree `/Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/macos-app-shell` on branch `worktree-macos-app-shell`. Subagents must be given that absolute path and must use `git -C <that path>` form.

---

## File Structure

| File | Responsibility | Change |
| --- | --- | --- |
| `App/Shared/*` | Platform-neutral composition: bootstrap, paths, reader seam, history/version/review coordinators | Move (from `App/`) |
| `App/iOS/*` | iOS scene + shell + iOS-only helpers | Move |
| `App/Mac/FolinoMacApp.swift` | Mac `@main` scene graph: `WindowGroup(for:)`, `Settings`, `.commands` | Create |
| `App/Mac/MacShellView.swift` | `NavigationSplitView`: library sidebar + Reader detail | Create |
| `App/Mac/MacCommands.swift` | File / View menu skeleton | Create |
| `App/{iOS,Mac}/AudioStackFactory.swift` | Paired factory building the platform's audio adapters for `AppBootstrap` | Create |
| `App/{iOS,Mac}/SharedContainerTasks.swift` | Paired: iOS schedules App Group work, macOS schedules none | Create |
| `project.yml` | XcodeGen manifest | Add `FolinoMac`; retarget `Folino` / `FolinoScreenshot` sources |
| `Scripts/build-macos-app.sh` | `xcodebuild` gate for the Mac app target | Create |
| `Scripts/build-macos-packages.sh` | Package gate | Add `Library`, then `Reader` |
| `docs/engineering/module-architecture.md` | Layer rules | Revise the composition-root rule |
| `Packages/Features/Library/Sources/Library/Screens/{ScoreListScreen,RecentlyDeletedScreen}.swift` | Selection state owners | `EditMode` → `isSelecting` |
| `Packages/Features/Library/Sources/Library/Views/{ScoreListView,RecentlyDeletedView,PlaylistDetailView,ScoreListRow,BulkActionBar}.swift` | Selection chrome | Fork the chrome, keep the list |
| `Packages/Features/Reader/Package.swift` | Reader manifest | Add `.macOS(.v15)` |
| `Packages/Features/Reader/Sources/Reader/**` (26 files) | iOS-only surface | File-scope `#if os(iOS)` + `PARITY(macos)` |
| `Packages/Features/Reader/Sources/Reader/Screens/Mac/*` | The Mac reading surface | Create |
| `Packages/Infrastructure/Sources/Audio/*` | Playback + export + route watching | Un-gate; two `#if` islands; one adapter split |
| `Packages/Utility/Sources/UtilityUI/PlatformImage.swift` | `UIImage` / `NSImage` alias for shared raster code | Create |

---

# Milestone 0 — Target and layout scaffolding

## Task 1: Split `App/` three ways without adding a target

Nothing about this task is macOS-specific — it is the refactor that makes a second target possible, verified entirely by the two existing iOS targets still building. Doing it first means Task 2's diff is only the new target.

**Files:**
- Move into `App/Shared/`: `AppBootstrap.swift`, `AppBootstrap+AnalyticsSnapshot.swift`, `AppBootstrap+PDFConversion.swift`, `AppBootstrap+SharedHandoff.swift`, `AppPaths.swift`, `AppVersion+Bundle.swift`, `DomainError+LocalizedError.swift`, `DrainBannerComposer.swift`, `DrainBannerView.swift`, `EditableReaderScreen.swift`, `EdwinFontLoader.swift`, `ImportLoadingHUD.swift`, `NavigationStateStore.swift`, `ProcessScoreEditHistoryStore.swift`, `ReviewPromptCoordinator.swift`, `ShareDrainNavigation.swift`, `ShareDuplicateAlert.swift`, `ShareDuplicateResolver.swift`, `VersionHistoryPresenter.swift`
- Move into `App/iOS/`: `FolinoApp.swift`, `AppShellView.swift`, `DebugView.swift`, `LiveVocalTunerHandoff.swift`, `PictureInPictureOptOutMigration.swift`, `UIKitInstalledAppChecker.swift`
- Modify: `project.yml` (the `Folino` and `FolinoScreenshot` `sources:` blocks)

**Interfaces:**
- Consumes: nothing.
- Produces: the directory contract every later task relies on — `App/Shared` is compiled by all three targets, `App/iOS` by `Folino` and `FolinoScreenshot`, `App/Mac` (created in Task 2) by `FolinoMac`.

Note `DebugView.swift` is `#if DEBUG`-only and uses UIKit; it goes to `App/iOS`. `ShareExtension/` stays where it is — it is its own target's source root.

- [ ] **Step 1: Create the directories and move the files with `git mv`**

```bash
cd /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/macos-app-shell
mkdir -p App/Shared App/iOS App/Mac
```

Then one `git mv` per file, e.g.:

```bash
git mv App/AppBootstrap.swift App/Shared/AppBootstrap.swift
git mv App/AppShellView.swift App/iOS/AppShellView.swift
```

Use `git mv` (not `mv`) so the rename is recorded and the diff stays reviewable.

- [ ] **Step 2: Point both existing targets at the new directories**

In `project.yml`, the `Folino` target's first `sources` entry is currently:

```yaml
    sources:
      - path: App
        excludes:
          - Info.plist
          - Folino.entitlements
          - Resources/Soundfonts
          - Resources/Clicks
          - Resources/Fonts
          - Resources/folino.icon
          - ShareExtension
```

Replace that single entry with two, leaving the four resource entries that follow it untouched:

```yaml
    sources:
      - path: App/Shared
      - path: App/iOS
```

The `excludes` list disappears because `Info.plist`, `Folino.entitlements`, `Resources/` and `ShareExtension/` are no longer under a compiled path — they stay at `App/` and are referenced by their own explicit entries and by `INFOPLIST_FILE` / `CODE_SIGN_ENTITLEMENTS`.

Apply the same replacement to the `FolinoScreenshot` target's `App`-rooted `sources` entry, keeping every screenshot-specific entry it has.

- [ ] **Step 3: Regenerate and build both iOS targets**

```bash
cd /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/macos-app-shell
xcodegen generate
```

```bash
xcodebuild -project Folino.xcodeproj -scheme Folino \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -skipPackagePluginValidation build
```

Expected: `BUILD SUCCEEDED`.

```bash
xcodebuild -project Folino.xcodeproj -scheme FolinoScreenshot \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -skipPackagePluginValidation build
```

Expected: `BUILD SUCCEEDED`. This one matters — it is the target that would catch a file put in the wrong directory.

- [ ] **Step 4: Commit**

```bash
git add App project.yml
git commit -m "refactor(app): split App/ into Shared, iOS and Mac source roots"
```

---

## Task 2: Add the `FolinoMac` target, its build gate, and the architecture-doc revision

**Files:**
- Create: `App/Mac/FolinoMacApp.swift`
- Create: `App/Mac/Info.plist`
- Create: `Scripts/build-macos-app.sh`
- Modify: `project.yml`
- Modify: `docs/engineering/module-architecture.md`

**Interfaces:**
- Consumes: Task 1's `App/Shared` + `App/Mac` directory contract.
- Produces: `FolinoMacApp` (the `@main` entry point Task 4 replaces the body of), and `Scripts/build-macos-app.sh`, which every later task runs.

This task deliberately does **not** call `AppBootstrap` — that is Task 3's job, and `AppBootstrap` does not compile for macOS yet. The window is empty on purpose.

- [ ] **Step 1: Write the placeholder Mac scene**

Create `App/Mac/FolinoMacApp.swift`:

```swift
import SwiftUI

/// The Mac app's entry point. Task 4 replaces this body with the real `WindowGroup(for:)` scene graph; until then it
/// exists so the target has something to launch, and so the build gate has something to fail on.
@main
struct FolinoMacApp: App {
    var body: some Scene {
        WindowGroup {
            Text(verbatim: "folino")
                .frame(minWidth: 640, minHeight: 480)
        }
    }
}
```

- [ ] **Step 2: Write the Mac Info.plist**

Create `App/Mac/Info.plist`. Mirror the keys `App/Info.plist` sets that are not iOS-specific — at minimum `CFBundleDisplayName` (`folino`, lowercase), `CFBundleName`, `CFBundleShortVersionString` (`$(MARKETING_VERSION)`), `CFBundleVersion` (`$(CURRENT_PROJECT_VERSION)`), `CFBundlePackageType` (`APPL`), `LSMinimumSystemVersion` (`$(MACOSX_DEPLOYMENT_TARGET)`), and `NSHumanReadableCopyright`. Read `App/Info.plist` first and copy the document-type and UTType declarations only if they are platform-neutral; skip every `UI*` key.

- [ ] **Step 3: Declare the target**

Add to `project.yml` under `targets:`, after `Folino`:

```yaml
  FolinoMac:
    type: application
    platform: macOS
    deploymentTarget: "15.0"
    sources:
      - path: App/Shared
      - path: App/Mac
      - path: App/Resources/Soundfonts
        type: folder
        buildPhase: resources
      - path: App/Resources/Clicks
        type: folder
        buildPhase: resources
      - path: App/Resources/Fonts
        type: folder
        buildPhase: resources
    settings:
      base:
        # Same bundle ID as the iOS app: sub-project Ⅶ's iOS↔Mac universal purchase requires it.
        PRODUCT_BUNDLE_IDENTIFIER: com.KeyNumber.Folino
        PRODUCT_NAME: folino
        INFOPLIST_FILE: App/Mac/Info.plist
        GENERATE_INFOPLIST_FILE: NO
        ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME: AccentColor
        MACOSX_DEPLOYMENT_TARGET: "15.0"
    dependencies:
      - package: Domain
        product: Domain
      - package: Infrastructure
      - package: Utility
      - package: ScoreUI
      - package: Settings
      - package: ImportExport
```

Copy the exact `product:` spellings for each package from the `Folino` target's own `dependencies:` block — read it and mirror it, minus `Library`, `Reader` and `Editor`, which do not build for macOS until Tasks 5 and 7. Do not add the Crashlytics `postBuildScripts` block; §7.1 of the spec defers that to Task 3.

Add a `FolinoMac` scheme alongside the existing ones in the `schemes:` section, following the shape the `Folino` scheme uses.

- [ ] **Step 4: Write the build gate**

Create `Scripts/build-macos-app.sh`:

```bash
#!/usr/bin/env bash
# Builds the macOS app target. The package gate (build-macos-packages.sh) cannot see this target, so without this
# script the Mac composition root can break silently between sessions.
#
# Run from anywhere; it locates the repo root relative to itself.
set -euo pipefail

cd "$(dirname "$0")/.."

xcodebuild \
  -project Folino.xcodeproj \
  -scheme FolinoMac \
  -destination 'platform=macOS' \
  -skipPackagePluginValidation \
  build
```

```bash
chmod +x Scripts/build-macos-app.sh
```

- [ ] **Step 5: Regenerate, build the Mac target, and confirm the iOS targets still build**

```bash
cd /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/macos-app-shell
xcodegen generate
Scripts/build-macos-app.sh
```

Expected: `BUILD SUCCEEDED`.

```bash
xcodebuild -project Folino.xcodeproj -scheme Folino \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -skipPackagePluginValidation build
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 6: Launch it once and confirm a window appears**

Find the product and open it:

```bash
xcodebuild -project Folino.xcodeproj -scheme FolinoMac -destination 'platform=macOS' \
  -showBuildSettings 2>/dev/null | grep -m1 " BUILT_PRODUCTS_DIR ="
```

```bash
open "<BUILT_PRODUCTS_DIR>/folino.app"
```

Expected: a window titled `folino` showing the placeholder text. Quit it before continuing.

- [ ] **Step 7: Revise the composition-root rule**

In `docs/engineering/module-architecture.md`, find the rule that says `App/` is the only place Infrastructure adapters are wired into Feature view models. Replace it with:

> The composition root is `App/` — `App/Shared` plus one platform shell per app target (`App/iOS` for `Folino`, `App/Mac` for `FolinoMac`). These app targets remain the only place Infrastructure adapters are wired into Feature view models; no Feature may compose Infrastructure itself.

Also update the module diagram's `App/` line if it names a single file, and add one sentence noting that `FolinoMac` is a second application target sharing `App/Shared`.

- [ ] **Step 8: Commit**

```bash
git add project.yml App/Mac Scripts/build-macos-app.sh docs/engineering/module-architecture.md
git commit -m "feat(macos): add the FolinoMac app target and its build gate"
```

---

# Milestone 1 — The shell boots

## Task 3: Make `AppBootstrap` compile and run on macOS

**Files:**
- Modify: `App/Shared/AppBootstrap.swift`
- Create: `App/iOS/AudioStackFactory.swift`
- Create: `App/Mac/AudioStackFactory.swift`
- Create: `App/iOS/SharedContainerTasks.swift`
- Create: `App/Mac/SharedContainerTasks.swift`
- Modify: `App/Mac/FolinoMacApp.swift`
- Modify: `project.yml` (add `Infrastructure` products the Mac target now needs)

**Interfaces:**
- Consumes: Task 2's `FolinoMac` target.
- Produces:
  - `AudioStackFactory` — a struct with `static func make(gateway: LiveScoreFileGateway, scoresDirectory: URL, shareTempDirectory: URL) -> AudioStack`, where `AudioStack` is a struct declared in `App/Shared/AppBootstrap.swift` holding `museScoreGeneralProvider: LiveMuseScoreGeneralProvider`, `soundfontResolver: GMSoundfontResolver`, `shareService: LiveScoreShareService`, `metadataReader: LiveScoreMetadataReader`, `playbackController: LivePlaybackController?`.
  - `SharedContainerTasks` — a struct with `static func playlistsIndexWriter() -> PlaylistsIndexWriter?` and `static func makeIncomingShareCoordinator(...) -> IncomingShareCoordinator?`, returning `nil` on macOS.
- `playbackController` is `Optional` because macOS returns `nil` until Task 11 un-gates `LivePlaybackController`.

- [ ] **Step 1: Extract the audio stack construction into a paired factory**

`AppBootstrap.installAudioStack(gateway:)` (currently `App/Shared/AppBootstrap.swift`) builds seven things, and exactly two of them are platform-bound: `UIKitInstalledAppChecker()` (UIKit) and `LivePlaybackController` / `LiveScoreAudioExporter` (gated to iOS by Ⅲa).

Declare the result type in `App/Shared/AppBootstrap.swift`, above the class:

```swift
/// What the platform's audio and sharing adapters amount to, handed back by the per-platform `AudioStackFactory`.
/// `playbackController` is optional because macOS has none until sub-project Ⅲb's audio milestone lands.
struct AudioStack {
    let museScoreGeneralProvider: LiveMuseScoreGeneralProvider
    let soundfontResolver: GMSoundfontResolver
    let shareService: LiveScoreShareService
    let metadataReader: LiveScoreMetadataReader
    let playbackController: LivePlaybackController?
}
```

Move the current body of `installAudioStack` into `App/iOS/AudioStackFactory.swift` verbatim, as `AudioStackFactory.make(...)` returning an `AudioStack`, and replace `AppBootstrap.installAudioStack` with:

```swift
private func installAudioStack(gateway: LiveScoreFileGateway) {
    let stack = AudioStackFactory.make(
        gateway: gateway,
        scoresDirectory: AppPaths.scoresDirectory,
        shareTempDirectory: AppPaths.shareTempDirectory,
    )
    museScoreGeneralProvider = stack.museScoreGeneralProvider
    soundfontResolver = stack.soundfontResolver
    shareService = stack.shareService
    metadataReader = stack.metadataReader
    playbackController = stack.playbackController
    stack.museScoreGeneralProvider.reconcileSharedSoundfontMarkersAtLaunch()
}
```

- [ ] **Step 2: Write the Mac factory**

Create `App/Mac/AudioStackFactory.swift`. It is the iOS one minus the two platform-bound pieces:

- `SharedSoundfontReclaimer`'s `installedChecker:` — macOS has no `UIKitInstalledAppChecker`. Pass a checker that reports nothing installed. Read `SharedSoundfontReclaimer`'s initializer to find the protocol's name and its one requirement, and write a `NoSiblingAppChecker` conforming to it in the same file, returning `false`.
- `audioExporter:` — `LiveScoreAudioExporter` is iOS-gated until Task 11. Read `LiveScoreShareService`'s initializer: if `audioExporter` is non-optional, this task must make it optional (and have `LiveScoreShareService` refuse the m4a export path when it is `nil`), leaving a `PARITY(macos)` marker at that site. Prefer optionality over a stub that pretends to export.
- `playbackController: nil`.

Everything else — `LiveMuseScoreGeneralProvider`, `GMSoundfontResolver`, `BundledMetronomeClickProvider`, `LiveScoreMetadataReader` — is unchanged.

- [ ] **Step 3: Make the App Group work platform-owned**

`start()` currently calls `AppGroupPaths.container()` and builds a `PlaylistsIndexWriter` and an `IncomingShareCoordinator` from it, and `finishStartup` drains share tokens. On macOS the App Group container is team-ID-prefixed and no Share Extension exists, so the right behavior is **not to schedule the work at all** rather than to rely on nil-tolerance.

Create `App/iOS/SharedContainerTasks.swift` holding the current logic, and `App/Mac/SharedContainerTasks.swift` returning `nil` from both factory methods, with a file-header `PARITY(macos)` marker:

```swift
// PARITY(macos): App Group–backed share drain and playlist index — macOS has no Share Extension and its App Group
//   container is team-ID-prefixed, so the Mac bootstrap schedules neither. Revisit if a Mac share destination or a
//   sibling-app hand-off ever needs the shared container.
```

Replace the call sites in `AppBootstrap.start()` and `finishStartup` with `SharedContainerTasks.…`.

- [ ] **Step 4: Decide Firebase for the Mac target**

`start()` calls `FirebaseCrashReporter.configure` and `configureAnalytics()` unconditionally. `FirebaseAnalytics.xcframework` at the pinned 11.15.0 **does** ship a `macos-arm64_x86_64` slice and Crashlytics is a source target, so neither is a platform blocker — but the Mac app is not registered in the Firebase console and has no `GoogleService-Info.plist` of its own, and `FirebaseApp.configure()` without one traps.

For this task, compose the no-ops on macOS. Both types already exist and are already the nil-fallbacks used at `AppBootstrap.swift:107,125`:

```swift
#if os(iOS)
crashReporter = FirebaseCrashReporter.configure(collectionEnabled: crashEnabled)
configureAnalytics()
#else
// PARITY(macos): Firebase registration — FirebaseAnalytics ships a macOS slice and Crashlytics is a source target,
//   so neither is a platform blocker. What is missing is a console registration for a Mac app sharing
//   com.KeyNumber.Folino, its own GoogleService-Info.plist, and a decision on attaching the upload-symbols
//   post-build script (project.yml:110). Until then the Mac composes the no-ops.
crashReporter = NoopCrashReporter()
analytics = NoopAnalytics()
#endif
```

- [ ] **Step 5: Drive the bootstrap from the Mac scene**

Replace `App/Mac/FolinoMacApp.swift`'s body so it starts the bootstrap and reports its state, still without any real UI:

```swift
import SwiftUI

@main
struct FolinoMacApp: App {
    @State private var bootstrap = AppBootstrap()

    init() {
        EdwinFontLoader.registerOnce()
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if bootstrap.isReady {
                    Text(verbatim: "ready")
                } else if let failure = bootstrap.failure {
                    Text(verbatim: "\(failure)")
                } else {
                    ProgressView()
                }
            }
            .frame(minWidth: 640, minHeight: 480)
            .task { bootstrap.start() }
        }
    }
}
```

- [ ] **Step 6: Build both platforms**

```bash
cd /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/macos-app-shell
xcodegen generate
Scripts/build-macos-app.sh
```

Expected: `BUILD SUCCEEDED`.

```bash
xcodebuild -project Folino.xcodeproj -scheme Folino \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -skipPackagePluginValidation build
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 7: Launch and confirm the bootstrap reaches `ready`**

`open` the built `folino.app` as in Task 2 Step 6. Expected: the window shows a spinner, then `ready`. If it shows an error instead, read it — the most likely causes are a missing directory under `Application Support` and the soundfont resources not being copied into the Mac bundle.

- [ ] **Step 8: Commit**

```bash
git add App project.yml
git commit -m "feat(macos): compose the app bootstrap on macOS"
```

---

## Task 4: The Mac window model — one `WindowGroup`, a split view, Settings, and a command skeleton

**Files:**
- Modify: `App/Mac/FolinoMacApp.swift`
- Create: `App/Mac/MacShellView.swift`
- Create: `App/Mac/MacCommands.swift`

**Interfaces:**
- Consumes: `AppBootstrap` from Task 3.
- Produces:
  - `MacShellView(bootstrap:scoreID:)` where `scoreID` is a `Binding<ScoreItem.ID?>` — the window's presented score. Task 6 fills its sidebar; Task 8 fills its detail.
  - `MacCommands` — a `Commands` struct whose File and View menus Tasks 6 and 9 extend.

The sidebar and detail are placeholders in this task. Wiring `LibraryRootScreen` in is Task 6, because `Library` does not build for macOS until Task 5.

- [ ] **Step 1: Write the shell view**

Create `App/Mac/MacShellView.swift`:

```swift
import Domain
import SwiftUI

/// One Mac window: the library in the sidebar, the score in the detail column. Every window comes from the same
/// `WindowGroup`, which is what gives macOS's automatic window tabbing (⌘T, tab drag-out, Merge All Windows) for
/// free — see the design spec §3.3 for why a separate library `Window` would forfeit that.
struct MacShellView: View {
    let bootstrap: AppBootstrap
    @Binding var scoreID: ScoreItem.ID?

    @State private var columnVisibility: NavigationSplitViewVisibility = .doubleColumn

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 260, ideal: 320)
        } detail: {
            detail
        }
        .frame(minWidth: 900, minHeight: 600)
    }

    @ViewBuilder
    private var sidebar: some View {
        // Task 6 replaces this with LibraryRootScreen.
        Text(verbatim: "library")
    }

    @ViewBuilder
    private var detail: some View {
        if scoreID == nil {
            ContentUnavailableView {
                Label {
                    Text("app.detail.empty.title")
                } icon: {
                    Image(systemName: "music.note")
                }
            }
        } else {
            // Task 8 replaces this with MacReaderRootScreen.
            Text(verbatim: "score")
        }
    }
}
```

- [ ] **Step 2: Write the command skeleton**

Create `App/Mac/MacCommands.swift`:

```swift
import SwiftUI

/// The menu-bar skeleton. Sub-project Ⅳ fills in the editing commands and the full key map; this is only what the
/// shell itself needs, plus the two toggles a reader wants on day one.
struct MacCommands: Commands {
    @Binding var columnVisibility: NavigationSplitViewVisibility

    var body: some Commands {
        // Import lands beside the system's own New/Open items rather than in a menu of its own.
        CommandGroup(after: .newItem) {
            Button {
                // Task 6 wires this to the importer.
            } label: {
                Text("mac.menu.import")
            }
            .keyboardShortcut("i", modifiers: [.command, .shift])
        }
        CommandGroup(before: .toolbar) {
            Button {
                columnVisibility = columnVisibility == .detailOnly ? .doubleColumn : .detailOnly
            } label: {
                Text("mac.menu.toggleLibrary")
            }
            .keyboardShortcut("0", modifiers: .command)
            Divider()
        }
    }
}
```

Add `mac.menu.import` ("Import…" / 「読み込む…」) and `mac.menu.toggleLibrary` ("Show Library" / 「ライブラリを表示」) to the app's `Localizable.xcstrings`. Find it first (`find App -name '*.xcstrings'`) and follow the file's existing key style; every user-visible string in this plan goes through xcstrings, never a literal.

- [ ] **Step 3: Rewrite the scene graph**

Replace `App/Mac/FolinoMacApp.swift`'s body:

```swift
var body: some Scene {
    WindowGroup(for: ScoreItem.ID.self) { $scoreID in
        Group {
            if bootstrap.isReady {
                MacShellView(bootstrap: bootstrap, scoreID: $scoreID)
            } else if let failure = bootstrap.failure {
                ContentUnavailableView {
                    Text("app.bootstrap.error.title")
                } description: {
                    Text((failure as? LocalizedError)?.errorDescription ?? failure.localizedDescription)
                }
            } else {
                ProgressView()
            }
        }
        .task { bootstrap.start() }
    }
    .commands { MacCommands(columnVisibility: $columnVisibility) }

    Settings {
        // Task 6 replaces this with SettingsSheet's content.
        Text(verbatim: "settings")
            .frame(width: 480, height: 320)
    }
}
```

`columnVisibility` has to be lifted to `FolinoMacApp` as `@State` for `MacCommands` to bind to it, and passed down to `MacShellView` as a `Binding`. Adjust `MacShellView` accordingly — replace its `@State private var columnVisibility` with `@Binding var columnVisibility`.

- [ ] **Step 4: Build both platforms**

```bash
cd /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/macos-app-shell
xcodegen generate
Scripts/build-macos-app.sh
```

Expected: `BUILD SUCCEEDED`.

```bash
xcodebuild -project Folino.xcodeproj -scheme Folino \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -skipPackagePluginValidation build
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 5: Verify the window behavior by hand**

Launch the app and check all four:

1. A window opens with a `library` sidebar and an empty-detail placeholder.
2. **⌘T opens a second tab** in the same window (this is the whole point of the single `WindowGroup` — if it opens a separate window instead, the scene graph is wrong).
3. **⌘0 collapses and restores the sidebar.**
4. **⌘, opens the Settings window.**

Then quit and relaunch: the windows and tabs should come back.

- [ ] **Step 6: Commit**

```bash
git add App
git commit -m "feat(macos): one WindowGroup, a split view, Settings and the command skeleton"
```

---

# Milestone 2 — The library is visible

## Task 5: Split Library's selection mode from its selection state

**Files:**
- Modify: `Packages/Features/Library/Sources/Library/Screens/ScoreListScreen.swift:14`
- Modify: `Packages/Features/Library/Sources/Library/Screens/RecentlyDeletedScreen.swift:12`
- Modify: `Packages/Features/Library/Sources/Library/Views/ScoreListView.swift:41,65,118,184`
- Modify: `Packages/Features/Library/Sources/Library/Views/RecentlyDeletedView.swift:17,30`
- Modify: `Packages/Features/Library/Sources/Library/Views/PlaylistDetailView.swift:22,82`
- Modify: `Packages/Features/Library/Sources/Library/NewScore/NewScoreSheet.swift:69`
- Modify: `Packages/Features/Library/Sources/Library/Views/ScoreListRow.swift` (its `isEditing:` parameter)
- Modify: `Scripts/build-macos-packages.sh`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `ScoreListView`, `RecentlyDeletedView` and `PlaylistDetailView` take `isSelecting: Binding<Bool>` in place of `editMode: Binding<EditMode>`. `ScoreListRow`'s `isEditing:` parameter becomes `isSelecting:`. `selectedIDs: Binding<Set<ScoreItemID>>` is unchanged — it was already platform-neutral.

**The iOS appearance and behavior must not change at all.** This is a rename plus a platform fork of chrome, nothing else.

- [ ] **Step 1: Read the six files and inventory every use**

Before editing, read each file's `EditMode` sites and note for each whether it is (a) the mode flag itself, (b) chrome gated on the mode, or (c) the `.environment(\.editMode,)` injection that makes `List(selection:)` show iOS checkmarks. Only (c) is genuinely iOS-only API; (a) becomes a `Bool` and (b) becomes `#if os(iOS)` chrome.

`NewScoreSheet.swift:69` is a fourth kind — `.environment(\.editMode, .constant(.active))` used purely for an affordance. `UtilityUI`'s `activeEditModeCompat()` already covers it; use that and change nothing else there.

- [ ] **Step 2: Convert the state owners**

In `ScoreListScreen.swift`, replace:

```swift
@State private var editMode: EditMode = .inactive
```

with:

```swift
@State private var isSelecting = false
```

and pass `isSelecting: $isSelecting` where it passed `editMode: $editMode`. Do the same in `RecentlyDeletedScreen.swift`. Wherever the screen previously reset with `editMode = .inactive`, write `isSelecting = false`.

- [ ] **Step 3: Convert the views and fork the chrome**

In `ScoreListView.swift`, replace `@Binding var editMode: EditMode` with `@Binding var isSelecting: Bool`. Every `editMode.isEditing` read becomes `isSelecting`. The three chrome sites — the `.environment(\.editMode, $editMode)` injection, the Select / Cancel toolbar button, and the `BulkActionBar` `safeAreaInset` — go inside `#if os(iOS)`:

```swift
#if os(iOS)
.environment(\.editMode, .constant(isSelecting ? .active : .inactive))
#endif
```

On macOS there is no mode: `List(selection:)` already multi-selects with ⌘/⇧-click, so `isSelecting` is simply never set true there and the chrome is absent. Leave a marker above the forked block:

```swift
// PARITY(macos): bulk-selection chrome — iOS needs an explicit Select mode because a touch list cannot distinguish
//   a tap-to-open from a tap-to-select. AppKit's List multi-selects natively with ⌘/⇧-click, so the Mac has no mode
//   and reaches the same bulk actions from the selection's context menu (and, in sub-project Ⅳ, the menu bar).
```

Apply the same shape to `RecentlyDeletedView.swift` and `PlaylistDetailView.swift`. `RecentlyDeletedView`'s swipe actions have no macOS meaning, but its context menu already carries restore and permanent-delete, so nothing is lost — gate the swipe actions to iOS and leave the context menu shared.

- [ ] **Step 4: Fix the availability guard**

`ScoreListView.swift:118` has `if #available(iOS 26, *)`, which macOS satisfies through the `*` wildcard and then fails to compile on. Change it to `if #available(iOS 26, macOS 26, *)`.

- [ ] **Step 5: Build Library for macOS**

```bash
cd /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/macos-app-shell
swift build --package-path Packages/Features/Library
```

Expected: `Build complete`. If new errors appear beyond the ten `EditMode` sites — the earlier build stopped at the first batch and could not report them — fix them with the same house pattern: a `UtilityUI` compat helper where iOS must stay byte-identical, an `#if` fork where the concept genuinely differs, and a `PARITY(macos)` marker either way.

- [ ] **Step 6: Add Library to the package gate**

In `Scripts/build-macos-packages.sh`, add `Packages/Features/Library` to the `PACKAGES` array after `Packages/ScoreUI`, and update the header comment — it currently says Library is deliberately absent and explains why. Replace that paragraph with a note that Library joined the gate in Ⅲb, and keep the sentence explaining that its `.macOS` declaration also serves as the Android JNI host-test build floor (which must not be removed).

```bash
Scripts/build-macos-packages.sh
```

Expected: `All macOS packages built.`

- [ ] **Step 7: Prove iOS is unchanged**

```bash
xcodebuild -project Folino.xcodeproj -scheme Folino \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -skipPackagePluginValidation build
```

Expected: `BUILD SUCCEEDED`.

Then render the list screen's preview and compare it against the same preview before the change. Add or update a `#Preview` in `ScoreListView.swift` that shows the list **in selecting state** (`isSelecting: .constant(true)`) with two rows selected, render it with `mcp__xcode__RenderPreview`, and read the PNG. The Select button, the checkmarks and the `BulkActionBar` must all still be there.

Run the Library package's tests:

```bash
xcodebuild test -scheme Library \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -skipPackagePluginValidation
```

Expected: all tests pass. (Run from `Packages/Features/Library`. If the scheme name is not found, try `Library-Package`.)

- [ ] **Step 8: Commit**

```bash
git add Packages/Features/Library Scripts/build-macos-packages.sh
git commit -m "refactor(library): fork the bulk-selection chrome, keep one list"
```

---

## Task 6: Put the library in the Mac sidebar, with import

**Files:**
- Modify: `App/Mac/MacShellView.swift`
- Modify: `App/Mac/MacCommands.swift`
- Modify: `App/Mac/FolinoMacApp.swift`
- Modify: `project.yml` (add the `Library` package dependency to `FolinoMac`)

**Interfaces:**
- Consumes: `MacShellView` (Task 4), Library's macOS build (Task 5), `AppBootstrap`'s adapters (Task 3).
- Produces: a `LibraryViewModel` owned by `MacShellView`, and a working import path. Task 8 replaces the detail placeholder.

`LibraryRootScreen`'s call shape is fixed — copy it from `App/iOS/AppShellView.swift`'s `sidebar` property, which is the regular-width (iPad) call and therefore the right model:

```swift
LibraryRootScreen(
    viewModel: libraryVM,
    path: $sidebarPath,
    onOpenScore: { item in … },
    readerDestination: { item in … },
    playlistReaderDestination: { route in … },
    onOpenInPlaylist: { item, playlistID in … },
    licenseContent: { LicenseListView() },
    leadingToolbarItem: { … },
)
```

- [ ] **Step 1: Add the package dependency**

Add `Library` (and `LicenseList`, which `licenseContent:` needs) to the `FolinoMac` target's `dependencies:` in `project.yml`, copying the exact `product:` spellings from the `Folino` target. Regenerate.

- [ ] **Step 2: Build the view model in `MacShellView`**

`LibraryViewModel`'s initializer is long; copy it verbatim from `ReadyShell.init` in `App/iOS/AppShellView.swift` — read that initializer and mirror every argument, substituting `bootstrap`'s adapters. Hold it as `@State private var libraryVM: LibraryViewModel`, initialized in `MacShellView.init`, exactly as `ReadyShell` does.

- [ ] **Step 3: Replace the sidebar placeholder**

Use the `LibraryRootScreen` call above. The Mac's `onOpenScore` sets the window's presented score rather than pushing a path:

```swift
onOpenScore: { item in
    scoreID = item.id
    columnVisibility = .detailOnly
},
```

`readerDestination` and `playlistReaderDestination` are the iOS `NavigationStack` seam; on the Mac the detail column owns the reader, so return an `EmptyView()` from both **and** leave a marker:

```swift
// PARITY(macos): library → reader navigation seam — LibraryRootScreen's readerDestination closures exist for the
//   iOS NavigationStack push. On the Mac the detail column owns the reader, so these are never entered. If a Mac
//   ever needs an in-sidebar push (a playlist drill-down that opens a score in place), this is where it hooks in.
```

`leadingToolbarItem:` returns `EmptyView()` on the Mac — Settings is the standard ⌘, window, not a toolbar button.

- [ ] **Step 4: Open the score in the current window, and in a new tab on demand**

Double-clicking a row already routes through `onOpenScore`. Add "Open in New Tab" as a context-menu item on the sidebar via `openWindow`:

```swift
@Environment(\.openWindow) private var openWindow
```

and call `openWindow(value: item.id)` from the menu item. Check whether `LibraryRootScreen` exposes a row context-menu seam first; if it does not, this step adds a **File ▸ Open in New Tab** command instead (bound to the current selection) rather than reaching into Library's row internals — a Feature's row menu is not the App layer's to edit.

- [ ] **Step 5: Wire Import**

`MacCommands`'s Import button opens an `NSOpenPanel`-backed `.fileImporter` and hands the URLs to `bootstrap.importer`. Read `LiveScoreFileImporter`'s public method for importing a URL and call it; mirror what the iOS import path does with the result (`DrainBannerComposer` is available in `App/Shared` if a message is wanted, but a Mac alert on failure is enough here).

Add the same via drag-and-drop onto the sidebar with `.dropDestination(for: URL.self)`.

Allowed content types must match the iOS document types — read them from `App/Info.plist`'s `CFBundleDocumentTypes` / `UTImportedTypeDeclarations` and use the same UTTypes.

- [ ] **Step 6: Point Settings at the real settings content**

Replace the `Settings` scene's placeholder with `SettingsSheet`'s content, called the way `App/iOS/AppShellView.swift` calls it:

```swift
SettingsSheet(
    provider: bootstrap.museScoreGeneralProvider,
    onVersionHistoryViewed: { },
    crashReporter: bootstrap.crashReporter ?? NoopCrashReporter(),
    analytics: bootstrap.analytics ?? NoopAnalytics(),
) {
    LicenseListView()
}
```

If `SettingsSheet` draws its own sheet chrome (a Done button, a navigation title), that chrome is wrong in a Settings window — gate it out on macOS with the same `#if` + `PARITY(macos)` pattern rather than forking the screen.

- [ ] **Step 7: Build both platforms**

```bash
cd /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/macos-app-shell
xcodegen generate
Scripts/build-macos-app.sh
```

Expected: `BUILD SUCCEEDED`.

```bash
xcodebuild -project Folino.xcodeproj -scheme Folino \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -skipPackagePluginValidation build
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 8: Verify by hand**

Launch the app. Then:

1. **Import an `.mscz`** through File ▸ Import. A row appears in the sidebar.
2. **Quit and relaunch.** The row is still there (this is what proves the database and scores directory are right on macOS, not just that the UI drew).
3. **Drag an `.mscz` onto the sidebar.** It imports.
4. **Double-click a row.** The detail shows the `score` placeholder and the sidebar collapses.
5. **⌘, still opens real Settings.**

Use a fixture from `Packages/Features/*/Tests/**/Resources` or any `.mscz` on disk.

- [ ] **Step 9: Commit**

```bash
git add App project.yml
git commit -m "feat(macos): the library in the sidebar, with import"
```

---

# Milestone 3 — A score renders

## Task 7: Make the `Reader` package compile for macOS

This task adds **no Mac UI**. It gates the 26 non-portable files so that the package builds, which is the precondition for Task 8 having somewhere to put the Mac screen.

**Files:**
- Modify: `Packages/Features/Reader/Package.swift:123`
- Modify: 26 files under `Packages/Features/Reader/Sources/Reader/` (list below)
- Create: `Packages/Utility/Sources/UtilityUI/PlatformImage.swift`
- Modify: `Scripts/build-macos-packages.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: `PlatformImage` — `typealias PlatformImage = UIImage` on iOS, `= NSImage` on macOS, in `UtilityUI`, for shared raster code (Task 10 needs it). `ReaderPiPSession.isSupported` returns `false` on macOS.

The 26 files, from a static census:

```
Annotation/AnnotationAnchoring.swift          Screens/PDF/VerticalPDFContainer.swift
Annotation/AnnotationAnchorPolicy.swift       Screens/PinchState.swift
Annotation/InkStrokePencilKitBridge.swift     Screens/ReaderRootScreen.swift
Annotation/PDFAnnotationAnchoring.swift       Screens/ReaderScoreLayout.swift
Hints/ReaderHintBubble.swift                  Screens/ScoreScrollHost.swift
Hints/ReaderHintCopy.swift                    Screens/Shared/ReaderPinchCommit.swift
PiP/ScorePiPCoordinator.swift                 Screens/Shared/StaticInkLayer.swift
PiP/ScorePiPFrameRenderer.swift               Screens/Shared/VerticalReaderShell.swift
PiP/ScorePiPHostView.swift                    Screens/Vertical/AnnotationCanvasView.swift
PiP/ScorePiPPlaybackDelegate.swift            Screens/Vertical/VerticalScoreContainer.swift
ReaderDeviceDefaults.swift                    Views/RehearsalMarkBar.swift
Screens/Horizontal/HorizontalScoreContainer.swift   Views/TempoBeatGlyph.swift
Screens/Paged/PagedScoreContainer.swift
Screens/PDF/PagedPDFContainer.swift
```

- [ ] **Step 1: Add the platform image alias**

Create `Packages/Utility/Sources/UtilityUI/PlatformImage.swift`:

```swift
#if os(iOS)
import UIKit

/// The platform's raster image type, for the small amount of shared code that genuinely produces one (annotation ink
/// flattening, the now-playing artwork). Everything else should stay in SwiftUI's `Image`.
public typealias PlatformImage = UIImage
#else
import AppKit

public typealias PlatformImage = NSImage
#endif
```

- [ ] **Step 2: Raise the manifest floor**

`Packages/Features/Reader/Package.swift:123`:

```swift
platforms: [.iOS(.v18), .macOS(.v15)],
```

- [ ] **Step 3: Gate the files, iterating on the compiler**

```bash
cd /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/macos-app-shell
swift build --package-path Packages/Features/Reader
```

This will fail. Work the errors down in passes — the build stops at the first module-import failure, so expect many rounds. For each file:

- **Wrap the whole file** in `#if os(iOS)` … `#endif` when the type has no macOS meaning at all in Ⅲb: everything under `PiP/`, `Annotation/InkStrokePencilKitBridge.swift`, `Screens/Vertical/AnnotationCanvasView.swift`, `Screens/ScoreScrollHost.swift`, the four iOS containers, `Screens/Shared/ReaderPinchCommit.swift`, `Screens/PinchState.swift`, `Screens/Shared/VerticalReaderShell.swift`, `Screens/ReaderRootScreen.swift`, `Screens/ReaderScoreLayout.swift`.
- **Gate only the iOS-bound member** where the rest of the file is portable: `ReaderDeviceDefaults.swift` (`UIScreen`/`UIDevice` probes), `Hints/ReaderHintBubble.swift`, `Hints/ReaderHintCopy.swift`, `Views/RehearsalMarkBar.swift`, `Views/TempoBeatGlyph.swift`, `Annotation/AnnotationAnchoring.swift`, `Annotation/AnnotationAnchorPolicy.swift`, `Annotation/PDFAnnotationAnchoring.swift`, `Screens/Shared/StaticInkLayer.swift`.
- Put a `PARITY(macos):` marker on every gate, **outside** the `#if`, saying what macOS still needs. Several are already owed to Ⅴ (annotation input) or Ⅳ (hints) — say so in the marker text.

`ReaderPiPSession.isSupported` must report `false` on macOS so `ReaderRootScreen`'s conditional PiP host and Task 8's Mac screen both agree; find its declaration (`grep -rn "isSupported" Packages/Features/Reader/Sources/Reader`) and gate its body.

- [ ] **Step 4: Confirm the view model is untouched**

`ReaderViewModel` and its twelve extensions are already platform-neutral. If the compiler asks for a gate inside any `ReaderViewModel*.swift` beyond the PiP session, **stop and report it** — that would contradict the spec's seam (§5.2) and the fix probably belongs in the screen layer instead.

- [ ] **Step 5: Build the package and add it to the gate**

```bash
swift build --package-path Packages/Features/Reader
```

Expected: `Build complete`.

Add `Packages/Features/Reader` to `PACKAGES` in `Scripts/build-macos-packages.sh` (after `Packages/Features/Library`) and rewrite the header comment paragraph that says Reader is deliberately absent.

```bash
Scripts/build-macos-packages.sh
```

Expected: `All macOS packages built.`

- [ ] **Step 6: Prove iOS is unchanged**

```bash
xcodebuild -project Folino.xcodeproj -scheme Folino \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -skipPackagePluginValidation build
```

Expected: `BUILD SUCCEEDED`.

```bash
xcodebuild test -scheme Reader \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -skipPackagePluginValidation
```

Expected: all tests pass. (Run from `Packages/Features/Reader`; try `Reader-Package` if the scheme is not found.)

- [ ] **Step 7: Commit**

```bash
git add Packages/Features/Reader Packages/Utility Scripts/build-macos-packages.sh
git commit -m "feat(reader): compile the Reader package for macOS"
```

---

## Task 8: `MacReaderRootScreen` and the vertical container — a score on screen

Vertical first because ssm's macOS reference for it is 127 lines of **pure SwiftUI** with no AppKit host, which makes it the cheapest possible proof that the whole chain — library row → view model → layout → render — works on the Mac.

**Files:**
- Create: `Packages/Features/Reader/Sources/Reader/Screens/Mac/MacReaderRootScreen.swift`
- Create: `Packages/Features/Reader/Sources/Reader/Screens/Mac/MacVerticalScoreContainer.swift`
- Modify: `App/Mac/MacShellView.swift`
- Modify: `project.yml` (add the `Reader` package to `FolinoMac`)

**Interfaces:**
- Consumes: `ReaderViewModel` (unchanged, shared), Task 7's package build, Task 6's sidebar selection.
- Produces: `MacReaderRootScreen(scoreItem:repository:originalStore:gateway:shareService:metadataReader:annotationCoordinator:scoresDirectory:playbackController:analytics:)` — mirror `ReaderRootScreen`'s initializer for the arguments that still apply, dropping every iOS-only one. Read `ReaderRootScreen`'s `init` and `App/Shared/EditableReaderScreen.swift`'s call to it before writing this signature.

**Reference:** `/Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/Examples/Apple/SheetMusicExample/macOS/VerticalScoreContainer.swift` (127 lines). Read it in full first. It is example code from a sibling package by the same author — copy and adapt, do not import.

- [ ] **Step 1: Read the three sources this task is built from**

1. `ReaderRootScreen.swift` — specifically its `init`, how it constructs `ReaderViewModel`, and which of its modifiers are iOS physics (`hostingAppearance(.light)` :334, `restoresInteractivePopGesture()` :314, `UIApplication.shared.isIdleTimerDisabled` :421, `ScorePiPHostView` :254). None of those come across.
2. The ssm macOS `VerticalScoreContainer.swift`.
3. folino's own `Screens/Vertical/VerticalScoreContainer.swift` — for the folino-specific behavior the Mac version must keep (which view model properties drive layout, how the playback cursor is read).

- [ ] **Step 2: Write the Mac vertical container**

Create `Screens/Mac/MacVerticalScoreContainer.swift`, adapted from the ssm reference, driven by folino's `ReaderViewModel` rather than the example's own state. Keep the per-tick playback-cursor read isolated in a leaf view, the way folino's iOS containers do — `reference_reader_playback_cursor_overinvalidation` is the reason, and it applies identically on the Mac.

Wrap the file in `#if os(macOS)`.

- [ ] **Step 3: Write the Mac root screen**

Create `Screens/Mac/MacReaderRootScreen.swift`, wrapped in `#if os(macOS)`. It builds the same `ReaderViewModel` `ReaderRootScreen` does and hosts `MacVerticalScoreContainer`. No top bar, no transport, no inspectors yet — Task 13 adds the transport, sub-project Ⅳ adds the rest.

Target roughly 250 lines. If it grows past that, something iOS-shaped is being carried across that should not be.

- [ ] **Step 4: Wire it into the detail column**

In `App/Mac/MacShellView.swift`, replace the `score` placeholder: look the `ScoreItem` up from `libraryVM` by the window's `scoreID` and build `MacReaderRootScreen`. Add the `Reader` package to `FolinoMac`'s dependencies in `project.yml` and regenerate.

- [ ] **Step 5: Build and run**

```bash
cd /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/macos-app-shell
xcodegen generate
Scripts/build-macos-app.sh
```

Expected: `BUILD SUCCEEDED`.

Launch, double-click an imported score. **Expected: the score engraves in the detail column.** This is the milestone's headline — if it draws, the whole chain works.

- [ ] **Step 6: Confirm iOS did not move**

```bash
xcodebuild -project Folino.xcodeproj -scheme Folino \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -skipPackagePluginValidation build
```

Expected: `BUILD SUCCEEDED`. Nothing in this task touches an iOS code path, so a failure here means a gate was written wrong in Task 7.

- [ ] **Step 7: Commit**

```bash
git add Packages/Features/Reader App project.yml
git commit -m "feat(macos): the Mac reader root screen and vertical mode"
```

---

## Task 9: Page mode — the magnifying page deck

Page is the Mac default per the umbrella spec §3, so this is what makes the Mac reader real rather than a demo.

**Files:**
- Create: `Packages/Features/Reader/Sources/Reader/Screens/Mac/MagnifyingScoreScrollView.swift`
- Create: `Packages/Features/Reader/Sources/Reader/Screens/Mac/MacPagedScoreContainer.swift`
- Modify: `Packages/Features/Reader/Sources/Reader/Screens/Mac/MacReaderRootScreen.swift`
- Modify: `App/Mac/MacCommands.swift`

**Interfaces:**
- Consumes: Task 8's `MacReaderRootScreen`.
- Produces: a View ▸ display-mode command group that switches the Mac reader between Page and Vertical, writing the same `ReaderLayoutMode` the iOS reader uses.

**Reference:** `/Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/Examples/Apple/SheetMusicExample/macOS/MagnifyingPDFScrollView.swift` (167 lines) — the re-engraved page deck on `NSScrollView.allowsMagnification`. Note the name: it renders **this app's own layout as pages**, not an imported PDF. `OriginalPDFView.swift` is the imported-PDF one and belongs to Task 10.

- [ ] **Step 1: Read the reference and folino's paged container**

Read `MagnifyingPDFScrollView.swift` end to end, then folino's `Screens/Paged/PagedScoreContainer.swift` for the folino-specific behavior (which page the reader is on, how page turns are reported to the view model, how the cursor is drawn).

- [ ] **Step 2: Port the AppKit scroll host**

Create `Screens/Mac/MagnifyingScoreScrollView.swift` — an `NSViewRepresentable` over `NSScrollView` with `allowsMagnification`, adapted from the reference. Keep the reference's magnification bounds as a starting point (`0.25`–`4.0`) and its `usesPredominantAxisScrolling = false`.

The property that matters and must survive the port: **AppKit re-rasterizes the layer tree at the current magnification**, which is what keeps the engraving vector-sharp at any zoom without redrawing per frame. If the port ends up rendering into a fixed-size bitmap, it is wrong.

Wrap in `#if os(macOS)`.

- [ ] **Step 3: Write the paged container over it**

Create `Screens/Mac/MacPagedScoreContainer.swift` hosting the deck, laid out horizontally by default (umbrella §3: MuseScore's default is horizontal, and ssm's deck already matches).

- [ ] **Step 4: Switch modes from the View menu**

In `MacReaderRootScreen`, branch on the reader's layout mode between `MacPagedScoreContainer` and `MacVerticalScoreContainer`, defaulting to **page**. Add a View ▸ display-mode command group in `MacCommands` bound to the same preference the iOS reader writes — find it (`grep -rn "ReaderLayoutMode" Packages/Features/Reader/Sources/Reader | head`) and use that, not a new key.

Add the mode names to the app's xcstrings if they are not already there.

- [ ] **Step 5: Build and verify sharpness**

```bash
cd /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/macos-app-shell
Scripts/build-macos-app.sh
```

Expected: `BUILD SUCCEEDED`.

Launch, open a score in Page mode, and **magnify to 4×**. Expected: staff lines and note heads stay crisp — no pixelation. Then switch to Vertical from the View menu and back. Both modes draw, and the mode persists across a relaunch.

- [ ] **Step 6: Confirm iOS still builds**

```bash
xcodebuild -project Folino.xcodeproj -scheme Folino \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -skipPackagePluginValidation build
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 7: Commit**

```bash
git add Packages/Features/Reader App
git commit -m "feat(macos): page mode on a magnifying AppKit scroll host"
```

---

## Task 10: PDF originals, read-only ink, and the appearance pin

Three small things that share one theme: **what the Mac must not silently lose.**

**Files:**
- Create: `Packages/Features/Reader/Sources/Reader/Screens/Mac/MacOriginalPDFView.swift`
- Modify: `Packages/Features/Reader/Sources/Reader/Screens/Shared/StaticInkLayer.swift`
- Modify: `Packages/Features/Reader/Sources/Reader/Screens/Mac/MacReaderRootScreen.swift`
- Modify: `Packages/Utility/Sources/UtilityUI/HostingAppearance.swift`

**Interfaces:**
- Consumes: Tasks 8 and 9.
- Produces: nothing new for later tasks.

**Reference:** `/Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/Examples/Apple/SheetMusicExample/macOS/OriginalPDFView.swift` (132 lines) — PDFKit with a cursor overlay and click-to-seek, driven by `PDFScoreGeometry`.

- [ ] **Step 1: Port the original-PDF view**

Create `Screens/Mac/MacOriginalPDFView.swift` from the reference, wrapped in `#if os(macOS)`. Branch to it from `MacReaderRootScreen` when the score item's display source is its imported PDF — read `ReaderViewModel+DisplaySource.swift` for the condition the iOS reader uses and use the same one.

- [ ] **Step 2: Make ink display on the Mac**

`StaticInkLayer` flattens stored ink into a raster. `PKDrawing(data:)` and `imageFromRect(_:scale:)` are macOS 10.15+, so the technique ports; what does not is the `UIImage` it produces. Replace that with Task 7's `PlatformImage`, and gate only the genuinely UIKit-shaped parts.

This is **display only**. Annotation input stays sub-project Ⅴ's; leave the marker saying so.

If the port turns out not to work — a `PKDrawing` API that is iOS-only in practice, or ink that renders at the wrong scale — **do not ship silence**. Show a hint in the reader that the score carries annotations the Mac cannot yet draw, add a `PARITY(macos)` row, and report it. A Mac that quietly hides an iPad's ink looks like data loss.

- [ ] **Step 3: Pin the Mac reader light**

`ReaderRootScreen.swift:318-334` pins the iOS reader to a light appearance because its content is light: the paper is `Color.white` and ink is resolved against a light trait before it is stored. Ⅲa made `HostingAppearance` a **no-op on macOS**, so a Mac in dark mode would draw dark chrome over white paper.

Give `MacReaderRootScreen` the equivalent. The Mac reader has none of the iOS pop-animation concern that forced the hosting-VC route on iOS, so a scene-scoped `.preferredColorScheme(.light)` on the reader's own subtree is enough; use it rather than teaching `HostingAppearance` about `NSAppearance`. Update `HostingAppearance.swift`'s existing `PARITY(macos)` marker to record that the Mac reader solved this locally and that the general per-screen scoping is still owed.

- [ ] **Step 4: Build and verify all three**

```bash
cd /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/macos-app-shell
Scripts/build-macos-app.sh
```

Expected: `BUILD SUCCEEDED`.

Then, on a Mac **set to dark mode**:

1. Open a score with annotations made on iOS. **The ink is visible.**
2. Open a PDF-origin item. **The PDF renders.**
3. **The reader's chrome is light**, matching the white paper — not dark chrome over white.

- [ ] **Step 5: Confirm iOS is unchanged, in appearance too**

```bash
xcodebuild -project Folino.xcodeproj -scheme Folino \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -skipPackagePluginValidation build
```

Expected: `BUILD SUCCEEDED`.

`StaticInkLayer` is shared code and this task edited it, so render the reader preview that shows annotated ink on iOS and read the PNG. The ink must look exactly as before.

- [ ] **Step 6: Commit**

```bash
git add Packages/Features/Reader Packages/Utility
git commit -m "feat(macos): PDF originals, read-only ink, and the reader's light pin"
```

---

# Milestone 4 — Playback

## Task 11: Un-gate the playback controller and the audio exporter

**Files:**
- Modify: `Packages/Infrastructure/Sources/Audio/LivePlaybackController.swift` (file-scope gate; `:257`; `:474`)
- Modify: `Packages/Infrastructure/Sources/Audio/LivePlaybackController+LoopBounds.swift`
- Modify: `Packages/Infrastructure/Sources/Audio/LivePlaybackController+Preview.swift`
- Modify: `Packages/Infrastructure/Sources/Audio/LivePlaybackController+Reload.swift`
- Modify: `Packages/Infrastructure/Sources/Audio/LivePlaybackController+Transpose.swift`
- Modify: `Packages/Infrastructure/Sources/Audio/LiveScoreAudioExporter.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `LivePlaybackController` and `LiveScoreAudioExporter` exist on macOS, which lets Task 13's `AudioStackFactory` stop returning `nil`.

- [ ] **Step 1: Verify ssm's engine initializer compiles on macOS first**

`PlaybackEngine`'s `audioSessionPolicy:` parameter is expected to exist on macOS and be inert (its `PlaybackEngine+AudioSession` bodies are iOS-gated, and ssm's own macOS example builds without passing it). Confirm before writing anything:

```bash
grep -rn "audioSessionPolicy" /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/Sources/SheetMusicAudio | head
```

If the parameter is itself iOS-gated, the Mac construction must omit it — a one-line `#if` at the call site, not a redesign. Report which case holds.

- [ ] **Step 2: Un-gate the four forwarding extensions**

`+LoopBounds`, `+Preview`, `+Reload`, `+Transpose` contain no platform-specific code — they were gated only because Ⅲa gated all seven files together. Remove their file-scope `#if os(iOS)` and delete their `PARITY(macos)` markers (each says "ports once that type does" — it just did).

- [ ] **Step 3: Un-gate the controller, keeping two `#if` islands**

Remove the file-scope gate from `LivePlaybackController.swift`. Two things stay platform-bound:

**`releaseEngine`'s session demote (around :257).** `AVAudioSession` does not exist on macOS, and nothing replaces it — teardown alone suffices:

```swift
#if os(iOS)
let session = AVAudioSession.sharedInstance()
// … existing body, unchanged …
#endif
```

**`appIconArtwork` (around :474).** `MPMediaItemArtwork` exists on macOS; `UIImage(named:)` and the `CFBundleIcons` lookup do not. On macOS the app icon is one call:

```swift
#if os(iOS)
// … existing CFBundleIcons → CFBundlePrimaryIcon → CFBundleIconFiles lookup, unchanged …
#else
guard let image = NSApplication.shared.applicationIconImage else { return nil }
return MPMediaItemArtwork(boundsSize: image.size) { _ in image }
#endif
```

Move the file's `PARITY(macos)` header marker down to whichever island still owes macOS something (the session demote does not — it is genuinely nothing on macOS; say that in the marker rather than deleting it, so a future reader does not "fix" it).

- [ ] **Step 4: Un-gate the exporter**

`LiveScoreAudioExporter.swift` has no platform-specific code: `.hostManaged` means it never touches a session. Remove the file-scope gate and its marker.

If Task 3 made `LiveScoreShareService`'s `audioExporter` optional to accommodate its absence, revert that here — the Mac can pass a real exporter now — and remove the marker that went with it.

- [ ] **Step 5: Build the package for both platforms**

```bash
cd /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/macos-app-shell
swift build --package-path Packages/Infrastructure
```

Expected: `Build complete`.

```bash
xcodebuild -project Folino.xcodeproj -scheme Folino \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -skipPackagePluginValidation build
```

Expected: `BUILD SUCCEEDED`.

```bash
xcodebuild test -scheme Infrastructure \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -skipPackagePluginValidation
```

Expected: all tests pass. (Run from `Packages/Infrastructure`; try `Infrastructure-Package` if the scheme is not found.)

- [ ] **Step 6: Commit**

```bash
git add Packages/Infrastructure
git commit -m "feat(audio): un-gate the playback controller and exporter for macOS"
```

---

## Task 12: The macOS output-route watcher

**Files:**
- Modify: `Packages/Infrastructure/Sources/Audio/OutputRouteDisconnectWatcher.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `OutputRouteDisconnectWatcher` exists on both platforms with an unchanged `onDisconnect` contract.

The iOS body observes `AVAudioSession.routeChangeNotification` for `.oldDeviceUnavailable`. The macOS equivalent is CoreAudio: listen on `kAudioObjectSystemObject` for `kAudioHardwarePropertyDefaultOutputDevice` **plus the device list** (`kAudioHardwarePropertyDevices`), per design §6.1.

**Both are required — the default moving is not the disconnect signal.** On macOS, plugging a device IN usually promotes it to default output, which moves `kAudioHardwarePropertyDefaultOutputDevice` exactly as unplugging one does. Treating every move as a disconnect would pause playback when the user connects headphones mid-score — the one transition iOS deliberately plays through, since the iOS body filters `.newDeviceAvailable` out. So the default moving is only a question; the device list answers it: a disconnect is *the device that was the default having left the device list*.

Do not assume an ordering between the two notifications — CoreAudio does not document one, and this repo's audio history is ordering races. Reconcile so that whichever callback arrives holding the evidence reports it.

**No protocol.** Same type name, same file, `#if` at type scope — a third implementation will never exist. And **do not** add an `AVAudioEngineConfigurationChange` observer while in this file: that is sub-project Ⅱ's work inside ssm, and a second observer races the engine's own teardown.

- [ ] **Step 1: Read the iOS body and note the exact contract**

Read all 53 lines. Note what `onDisconnect` promises the caller (when it fires, on which actor/queue) — the macOS body must promise the same, because `LivePlaybackController` is written against it.

- [ ] **Step 2: Write the macOS body**

Add an `#else` branch registering an `AudioObjectPropertyListenerBlock` on `AudioObjectID(kAudioObjectSystemObject)` for **each** of:

```swift
var address = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDefaultOutputDevice,   // and kAudioHardwarePropertyDevices
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain,
)
```

Keep a cached `Set<AudioDeviceID>` device list and the current default output. A default-output change whose old device is *still listed* is a user switch (or a removal not yet published) — not a disconnect; park the old id rather than discarding it, since that callback is the last place it is known. A device-list change reports when the id that left is the one being played through, or the parked one. Park for exactly one device-list change so a hand switch cannot leave the watcher primed. Both callbacks land on `.main`, so the state needs no further synchronization.

Dispatch `onDisconnect` on the same actor the iOS body uses. Unregister **every** listener in `deinit` (or in whatever teardown method the iOS body already has), on the same block identity — a leaked CoreAudio listener fires into a deallocated object. Log a failed registration; silently never pausing is undiagnosable.

Import `CoreAudio` in the macOS branch only.

- [ ] **Step 3: Build both platforms**

```bash
cd /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/macos-app-shell
swift build --package-path Packages/Infrastructure
```

Expected: `Build complete`.

```bash
xcodebuild -project Folino.xcodeproj -scheme Folino \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -skipPackagePluginValidation build
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Commit**

```bash
git add Packages/Infrastructure
git commit -m "feat(audio): observe CoreAudio default-output changes on macOS"
```

---

## Task 13: Play a score on the Mac

**Files:**
- Modify: `App/Mac/AudioStackFactory.swift`
- Modify: `Packages/Features/Reader/Sources/Reader/Screens/Mac/MacReaderRootScreen.swift`
- Create: `Packages/Features/Reader/Sources/Reader/Screens/Mac/MacTransportBar.swift`
- Modify: `App/Mac/MacCommands.swift`

**Interfaces:**
- Consumes: Tasks 11 and 12 (a real `LivePlaybackController` on macOS), Task 8's Mac reader.
- Produces: audible playback. Nothing later depends on it.

- [ ] **Step 1: Build a real playback controller on the Mac**

In `App/Mac/AudioStackFactory.swift`, replace `playbackController: nil` with the same construction the iOS factory uses:

```swift
playbackController: LivePlaybackController(
    soundfontResolver: resolver,
    metronomeClickProvider: clickProvider,
)
```

and restore the real `LiveScoreAudioExporter` if Task 3 stubbed it out.

- [ ] **Step 2: Write a minimal transport**

Create `Screens/Mac/MacTransportBar.swift` (`#if os(macOS)`): play/pause, a position readout, and a seek slider, bound to the same `ReaderViewModel` members the iOS transport uses. Read `Screens/ReaderTransportControl.swift` for which members those are — but do **not** port its iOS chrome (the swipe-to-resize card, the rubber band). This is a plain Mac bar.

Host it in `MacReaderRootScreen` below the score.

- [ ] **Step 3: Space bar plays and pauses**

Add a play/pause command to `MacCommands` bound to `.space`, or attach a `.keyboardShortcut(.space, modifiers: [])` button in the transport — whichever does not steal the key from a text field. Verify by hand that typing in the library's search field still inserts spaces.

- [ ] **Step 4: Build**

```bash
cd /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/macos-app-shell
Scripts/build-macos-app.sh
```

Expected: `BUILD SUCCEEDED`.

```bash
xcodebuild -project Folino.xcodeproj -scheme Folino \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -skipPackagePluginValidation build
```

Expected: `BUILD SUCCEEDED`.

- [ ] **Step 5: Verify by hand — the milestone's pass condition**

Launch, open a score, press space:

1. **Sound comes out of the default output device.**
2. **The playback cursor moves** with the audio.
3. **Unplug headphones (or switch the default output in System Settings) mid-playback → playback pauses.** This is Task 12's watcher proving itself.
4. **The Now Playing widget** (Control Center) shows the score and reflects play/pause state, with the app icon as artwork.

- [ ] **Step 6: Commit**

```bash
git add App Packages/Features/Reader
git commit -m "feat(macos): playback, transport and the space-bar shortcut"
```

---

# Milestone 5 — Library operations

## Task 14: Bulk actions and Recently Deleted on the Mac

**Files:**
- Modify: `Packages/Features/Library/Sources/Library/Views/ScoreListView.swift`
- Modify: `Packages/Features/Library/Sources/Library/Views/RecentlyDeletedView.swift`
- Modify: `App/Mac/MacCommands.swift`

**Interfaces:**
- Consumes: Task 5's `isSelecting` split, Task 6's sidebar.
- Produces: nothing later depends on it.

The bulk *actions* on `LibraryViewModel` are already selection-set-based and need no change. What is missing on the Mac is a way to invoke them.

- [ ] **Step 1: Give the selection a context menu on macOS**

Add a `#if os(macOS)` context menu on the list's selection offering the same actions iOS's `BulkActionBar` offers — read `BulkActionBar` for the exact list and call the same `LibraryViewModel` methods. Item titles come from the same xcstrings keys the bar uses; do not write new copy for the same action.

- [ ] **Step 2: Delete with ⌫**

Bind the delete key to the same method the bar's delete action calls, on macOS only.

- [ ] **Step 3: The same for Recently Deleted**

`RecentlyDeletedView` already has a context menu with restore and permanent-delete, so on macOS it may need nothing beyond what Task 5 left. Verify by hand; add what is missing.

- [ ] **Step 4: Build both platforms and verify**

```bash
cd /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/macos-app-shell
swift build --package-path Packages/Features/Library
Scripts/build-macos-app.sh
```

```bash
xcodebuild -project Folino.xcodeproj -scheme Folino \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -skipPackagePluginValidation build
```

Expected: all `BUILD SUCCEEDED` / `Build complete`.

By hand on the Mac: ⌘-click two rows, right-click → every bulk action is offered and works; ⌫ deletes them; Recently Deleted lists them and restores them.

- [ ] **Step 5: Commit**

```bash
git add Packages/Features/Library App
git commit -m "feat(macos): bulk actions from the selection's context menu"
```

---

## Task 15: Playlists and tags on the Mac

**Files:**
- Modify: `Packages/Features/Library/Sources/Library/Views/PlaylistDetailView.swift`
- Modify: whichever tag views need it (determined in Step 1)

**Interfaces:**
- Consumes: Task 14.
- Produces: nothing later depends on it.

- [ ] **Step 1: Find out what `.onMove` does on a macOS `List` — measure, don't assume**

`PlaylistDetailView` reorders with `.onMove`, whose behavior on a macOS `List` with no edit mode is **unverified**; Ⅲa's plan flagged the same question. Build and run, open a playlist, and try to drag a row.

Write down which of these is true before designing anything:

- Drag-reorder works with no affordance → nothing to do; delete the open question from the spec's §4.4.
- Drag-reorder does not work → add an explicit affordance (a drag handle, or reorder commands in a context menu), and record a `PARITY(macos)` row if it ships worse than iOS.

- [ ] **Step 2: Implement whichever case Step 1 found**

- [ ] **Step 3: Check tags**

Open the tag surfaces on the Mac. Anything that reads or writes tags should already work — the sheets are shared and Ⅲa's compat helpers cover their toolbars. Fix or record what does not.

- [ ] **Step 4: Sweep for anything else Library can do that the Mac cannot**

Walk the Library's iOS capabilities one by one — search, sort, favorites, playlists, tags, Recently Deleted, share, new score, metadata editing — and for each, either it works on the Mac or it gets a `PARITY(macos)` marker at the code site that explains what macOS still needs. **This sweep is the milestone's pass condition**, and it is the last chance to catch something before Ⅳ builds on top.

- [ ] **Step 5: Build both platforms and commit**

```bash
cd /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/macos-app-shell
swift build --package-path Packages/Features/Library
Scripts/build-macos-app.sh
xcodebuild -project Folino.xcodeproj -scheme Folino \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -skipPackagePluginValidation build
```

```bash
git add Packages/Features/Library
git commit -m "feat(macos): playlist reordering, tags, and the Library parity sweep"
```

---

# Milestone 6 — Chrome finish

## Task 16: Migrate sheet toolbars to semantic placements

Ⅲa deliberately deferred this: `PlatformToolbarCompat`'s `topBarLeadingCompat` / `topBarTrailingCompat` keep iOS byte-identical and give macOS something neutral, but a Mac sheet only gets Esc and Return key equivalents from **semantic** placements (`.cancellationAction` / `.confirmationAction`). That migration changes iOS appearance per site, which is why it is one screen at a time with a preview each.

**Files:**
- Modify: every call site of `topBarLeadingCompat` / `topBarTrailingCompat` (enumerate in Step 1)
- Modify: `Packages/Utility/Sources/UtilityUI/PlatformToolbarCompat.swift` (its `PARITY(macos)` marker)

**Interfaces:**
- Consumes: nothing.
- Produces: nothing.

- [ ] **Step 1: Enumerate the call sites**

```bash
cd /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/macos-app-shell
grep -rn "topBarLeadingCompat\|topBarTrailingCompat" --include="*.swift" Packages App
```

Work them **one screen at a time**, committing per screen. A Cancel button becomes `.cancellationAction`; a Done / Save / Add button becomes `.confirmationAction`. A button that is neither (a menu, an overflow) keeps the compat helper.

- [ ] **Step 2: For each screen — migrate, then render its preview and read the PNG**

Use `mcp__xcode__RenderPreview` and `Read` the resulting image. **iOS placement must be visually identical**: on iOS, `.cancellationAction` resolves to the leading slot and `.confirmationAction` to the trailing one, so it should be — but "should be" is not evidence, and a screen whose buttons swapped sides is a regression the user will see. If a preview shows a change, revert that site to the compat helper and record why.

- [ ] **Step 3: Verify Esc and Return on the Mac**

```bash
Scripts/build-macos-app.sh
```

Open each migrated sheet on the Mac: **Esc cancels, Return confirms.** That is what the migration bought.

- [ ] **Step 4: Update the compat helper's marker**

`PlatformToolbarCompat.swift`'s `PARITY(macos)` marker says Ⅲb migrates each call site. Rewrite it to describe what is left: which sites intentionally still use the compat helper and why.

- [ ] **Step 5: Confirm the iOS app builds and commit**

```bash
xcodebuild -project Folino.xcodeproj -scheme Folino \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -skipPackagePluginValidation build
```

```bash
git add Packages App
git commit -m "refactor(ui): semantic toolbar placements, one screen at a time"
```

---

## Task 17: Horizontal mode, or the parity row that replaces it

Horizontal carries the sticky leading pane and its bracket geometry — the most intricate port for the least-used mode. The spec schedules it last precisely so it can be cut.

**Files:**
- Create: `Packages/Features/Reader/Sources/Reader/Screens/Mac/MacHorizontalScoreContainer.swift` (if built)
- Modify: `Packages/Features/Reader/Sources/Reader/Screens/Mac/MacReaderRootScreen.swift`
- Modify: `Packages/Features/Reader/Sources/Reader/Screens/Horizontal/HorizontalScoreContainer.swift` (marker only, if cut)

**Reference:** `/Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/Examples/Apple/SheetMusicExample/macOS/MagnifyingScoreScrollView.swift` (444 lines) and `HorizontalScoreContainer.swift` (172 lines).

- [ ] **Step 1: Decide, and say which way you went**

Read both references and folino's own `Screens/Horizontal/HorizontalScoreContainer.swift`. If the port is a day's work, build it. If the sticky-pane geometry does not come across cleanly, **cut it** — that is a legitimate outcome this task plans for, not a failure.

- [ ] **Step 2a (if building): port it**

Create `Screens/Mac/MacHorizontalScoreContainer.swift` over `MagnifyingScoreScrollView`, and add Horizontal to the View menu's display-mode group.

- [ ] **Step 2b (if cutting): record it where its reader will look**

Put a marker on folino's `Screens/Horizontal/HorizontalScoreContainer.swift`, outside any `#if`:

```swift
// PARITY(macos): horizontal display mode — the Mac reader ships page and vertical. Horizontal needs the sticky
//   leading pane that takes over part labels and the bracket once the score scrolls past them; ssm's macOS example
//   has a working reference (Examples/Apple/SheetMusicExample/macOS/MagnifyingScoreScrollView.swift plus its
//   HorizontalScoreContainer). Sub-project Ⅳ picks this up.
```

Make sure the View menu does not offer a mode the Mac cannot draw.

- [ ] **Step 3: Build both platforms, verify, commit**

```bash
cd /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/macos-app-shell
Scripts/build-macos-app.sh
Scripts/build-macos-packages.sh
xcodebuild -project Folino.xcodeproj -scheme Folino \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -skipPackagePluginValidation build
```

```bash
git add Packages/Features/Reader
git commit -m "feat(macos): horizontal display mode"   # or: docs(parity): hand horizontal mode to sub-project Ⅳ
```

---

## Closing out

After Task 17:

1. Run all three gates one final time — `Scripts/build-macos-packages.sh`, `Scripts/build-macos-app.sh`, and the iOS app build — plus the package test suites for `Library`, `Reader` and `Infrastructure`.
2. Confirm `docs/engineering/ios-android-parity.md` regenerated cleanly (the `parity-ledger` pre-commit hook enforces this, so a clean commit is the evidence).
3. Update `~/.claude/projects/-Users-kiichi-Developer-Personal-ios-apps-Folino-iOS/memory/project_macos_app.md`: Ⅲb's remaining-task bullet is done; what stays open is Ⅰ, Ⅱ, Ⅳ, Ⅴ, Ⅶ, Ⅷ, plus anything Tasks 15 and 17 handed forward. Refresh the one-line hook in `MEMORY.md` if its text is now stale.
4. Report to the user what shipped, what became a `PARITY(macos)` row, and what the Firebase decision from Task 3 still owes.
