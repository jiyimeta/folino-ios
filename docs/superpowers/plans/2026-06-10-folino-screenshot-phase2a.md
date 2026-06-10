# Folino Screenshot Automation — Phase 2a Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stand up Folino's UITest-driven, framed App Store screenshot pipeline using the reusable `ScreenshotKit` package + `ios-screenshot` CLI, and capture the 3 public-API scenes (Library, Reader, Horizontal) end-to-end.

**Architecture:** A dedicated `FolinoScreenshot` app target (`-D SCREENSHOT_ENABLED`) whose root bypasses `AppBootstrap`/`AppShellView` and renders one `ScreenshotScene` per launch arg. Each scene constructs a real Folino screen via its **public** init with self-contained fixtures (the screenshot target owns trivial conformances to the public Domain protocols — Library's test fakes are unreachable from an app target), wrapped in `ScreenshotKit.ScreenshotFrameView` with a Folino-branded layout (folino.icon gradient + black text). A `FolinoUITests` target drives capture via `captureScene`; `ios-screenshot` lays the PNGs out for fastlane deliver.

**Tech Stack:** XcodeGen (`project.yml`), SwiftUI, ScreenshotKit (`git@github.com:jiyimeta/swift-screenshot-kit.git` @ `c583b524966dfb754c7f60b68ebe2dee9728c1b5`), `ios-screenshot` CLI (`~/Developer/Personal/tools/ios-screenshot/`), Swift Testing for any unit tests, `#Preview` + `mcp__xcode__RenderPreview` for visual verification of scenes.

**Scope:** This is Phase 2a. The 3 inspector scenes (PlaybackInspector, VisualInspector, ABRepeat) need `@testable import Reader` + internal models + an async score load; they are a separate **Phase 2b** plan written after 2a lands. PiP is out of scope entirely (per spec).

**Worktree:** All paths are relative to `/Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/screenshot-tooling/` (branch `worktree-screenshot-tooling`). Run all git/xcodegen/xcodebuild from there.

---

## Key facts (verified during planning)

- DI is constructor injection; no swift-dependencies. The screenshot root does not need a global DI swap — `ScreenshotEnvironment.bootstrap` runs with an empty (or animations-only) `prepare`.
- `LibraryRootScreen` (PUBLIC, `Packages/Features/Library/Sources/Library/Screens/LibraryRootScreen.swift:30`) init: `viewModel: LibraryViewModel`, `path: Binding<NavigationPath>`, `onOpenScore`, `readerDestination` (ViewBuilder), `playlistReaderDestination` (ViewBuilder), `onOpenInPlaylist`, `licenseContent` (ViewBuilder), `leadingToolbarItem` (ViewBuilder, defaulted).
- `LibraryViewModel` (PUBLIC, `.../LibraryViewModel.swift:50`) init: `repository: any ScoreLibraryRepository`, `importer: any ScoreFileImporter`, `gateway: any ScoreFileGateway`, `shareService: any ScoreShareService`, `metadataReader: any ScoreMetadataReading`.
- `ReaderRootScreen` (PUBLIC, `Packages/Features/Reader/Sources/Reader/Screens/ReaderRootScreen.swift:56`) init: `scoreItem: ScoreItem`, `repository`, `gateway`, `shareService`, `metadataReader`, `scoresDirectory: URL`, `playbackController: (any PlaybackController)? = nil`, `museScoreGeneralProvider: ...? = nil`, `playlistID: PlaylistID? = nil`, `onBack: (() -> Void)? = nil`, `hidesBackButton: Bool = false`.
- `ScoreItem` (PUBLIC, `Packages/Domain/Sources/Domain/Models/ScoreItem.swift:8`) — memberwise fields: `id: ScoreItemID`, `title`, `composer`, `instrumentationSummary`, `localFileName`, `contentHash`, `sizeBytes`, `lengthBeats`, `defaultTempoBpm`, `primaryKey`, `addedAt: Date`, `lastOpenedAt`, `tagIDs`, `isFavorite`, `deletedAt`.
- Public Domain protocols to conform fixtures against: `ScoreLibraryRepository` (`Packages/Domain/Sources/Domain/Protocols/ScoreLibraryRepository.swift:10`), `ScoreFileGateway` (`.../ScoreFileGateway.swift:45`), `ScoreShareService` (`.../ScoreShareService.swift:35`), `ScoreMetadataReading` (`.../ScoreMetadataReading.swift:56`), `ScoreFileImporter` (in Domain Protocols).
- `ReaderLayoutMode` (PUBLIC enum, `Packages/Domain/Sources/Domain/Models/ReaderLayoutMode.swift:8`): `.vertical`/`.horizontal`/`.page`. Reader reads UserDefaults key `"readerLayoutMode"` (`ReaderGlobalSettingsKey.layoutMode`) to pick the container.
- `Score` value type (used as `Score(division: Int, parts: [Part], metaTags: [String:String])`). **Access level of `Score`/`Part`/`Staff`/`Instrument` inits must be confirmed in Task 4** (they're used in Reader's internal previews; if not public, the fixture gateway returns an empty `Score(division:480, parts:[], metaTags:[:])` and the Reader renders an empty staff — acceptable for a framed marketing shot, or a public builder is found).

---

## File structure

**`project.yml`** (modify) — add ScreenshotKit package, `FolinoScreenshot` target, `FolinoUITests` target, `FolinoScreenshot` scheme.

**`FolinoScreenshot/`** (new app-target source dir):
- `ScreenshotApp.swift` — `@main`, bootstrap + scene dispatch root.
- `ScreenshotScene.swift` — `enum ScreenshotScene` (id + view).
- `FolinoScreenshotLayout.swift` — the folino.icon-gradient/black-text layout helper.
- `Fixtures/FixtureScoreRepository.swift` — populated `ScoreLibraryRepository`.
- `Fixtures/FixtureServices.swift` — no-op `ScoreFileImporter`/`ScoreFileGateway`/`ScoreShareService`/`ScoreMetadataReading` + the fixture `Score`/`ScoreItem`s.
- `Scenes/LibraryScene.swift`, `Scenes/ReaderScene.swift`, `Scenes/HorizontalScene.swift`.
- `ScreenshotStrings.xcstrings` — scene title/subtitle copy (3 scenes × 5 locales).
- `Info.plist` — reuse `App/Info.plist` (shared, like the main target).

**`Tests/FolinoUITests/`** (new):
- `ScreenshotsUITests.swift` — `captureScene` per scene.

**`.screenshots.yml`** (new, repo root) — CLI config.

---

## Task 1: Wire the screenshot + UITest targets in project.yml

**Files:**
- Modify: `project.yml`
- Create: `FolinoScreenshot/ScreenshotApp.swift` (temporary stub so the target compiles)

- [ ] **Step 1: Add the ScreenshotKit package**

In `project.yml` under `packages:`, add:
```yaml
  ScreenshotKit:
    url: git@github.com:jiyimeta/swift-screenshot-kit.git
    revision: c583b524966dfb754c7f60b68ebe2dee9728c1b5
```

- [ ] **Step 2: Add the `FolinoScreenshot` app target**

Under `targets:`, add (mirroring the `Folino` target's package wiring, minus the share extension and Firebase post-build; linking the feature packages that render the scenes):
```yaml
  FolinoScreenshot:
    type: application
    platform: iOS
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
      - path: App/Resources/folino.icon
        type: file
        buildPhase: resources
      - path: App/Resources/Fonts
        type: folder
        buildPhase: resources
      - path: FolinoScreenshot
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.KeyNumber.Folino.screenshot
        PRODUCT_NAME: folino
        INFOPLIST_FILE: App/Info.plist
        CODE_SIGN_ENTITLEMENTS: App/Folino.entitlements
        TARGETED_DEVICE_FAMILY: 1,2
        ASSETCATALOG_COMPILER_APPICON_NAME: folino
        ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME: AccentColor
        GENERATE_INFOPLIST_FILE: NO
        OTHER_SWIFT_FLAGS:
          - $(inherited)
          - -D SCREENSHOT_ENABLED
    dependencies:
      - package: Utility
        products: [UtilityCore, UtilityUI, Navigation]
      - package: Domain
      - package: Infrastructure
        products: [Persistence, CloudSync, Soundfonts, Audio, ScoreFiles, CrashReporting]
      - package: Library
      - package: Reader
      - package: Editor
      - package: ImportExport
        products: [ImportExport, ImportExportAppGroup]
      - package: Settings
      - package: swift-sheet-music
        product: SheetMusicLayoutApple
      - package: LicenseList
        product: LicenseList
      - package: ScreenshotKit
        products: [ScreenshotKit]
```
(Start from the full `Folino` dependency set so linking always succeeds; trimming heavy deps is a later optimization, NOT part of 2a. The `App/` sources are included because the screenshot `@main` lives in `FolinoScreenshot/` and the `App/` tree's own `@main FolinoApp` must be excluded — see Step 4.)

- [ ] **Step 3: Add the `FolinoUITests` target**

```yaml
  FolinoUITests:
    type: bundle.ui-testing
    platform: iOS
    sources:
      - Tests/FolinoUITests
    dependencies:
      - target: FolinoScreenshot
      - package: ScreenshotKit
        products: [ScreenshotKitUITest]
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.KeyNumber.Folino.uiTests
        GENERATE_INFOPLIST_FILE: YES
        TEST_TARGET_NAME: FolinoScreenshot
```

- [ ] **Step 4: Exclude the production `@main` from the screenshot target**

The `App/` tree contains `FolinoApp.swift` with `@main`. The screenshot target adds its own `@main` in `FolinoScreenshot/ScreenshotApp.swift`, so `App/FolinoApp.swift` must be excluded from the `FolinoScreenshot` target's `App` source (two `@main` = compile error). Add `FolinoApp.swift` to the `excludes:` list under the `FolinoScreenshot` target's `- path: App` entry (alongside `Info.plist` etc. from Step 2).

- [ ] **Step 5: Add the `FolinoScreenshot` scheme**

Under `schemes:` (create the key if absent):
```yaml
  FolinoScreenshot:
    build:
      targets:
        FolinoScreenshot: [run, test]
        FolinoUITests: [test]
    run:
      config: Debug
    test:
      config: Debug
      targets:
        - FolinoUITests
```

- [ ] **Step 6: Write a temporary stub `@main` so the target compiles**

Create `FolinoScreenshot/ScreenshotApp.swift`:
```swift
import SwiftUI

@main
struct ScreenshotApp: App {
    var body: some Scene {
        WindowGroup {
            Text("screenshot stub")
        }
    }
}
```

- [ ] **Step 7: Generate and build**

Run: `/opt/homebrew/bin/xcodegen --spec project.yml --project .`
Run: `xcodebuild -project Folino.xcodeproj -scheme FolinoScreenshot -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' build -skipPackagePluginValidation -quiet`
Expected: exit 0. If linking fails for a missing product, adjust the `dependencies` to match what the Folino app target declares for that package.

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "Add FolinoScreenshot + FolinoUITests targets and ScreenshotKit dep"
```

---

## Task 2: Screenshot root — bootstrap + scene dispatch

**Files:**
- Create: `FolinoScreenshot/ScreenshotScene.swift`
- Modify: `FolinoScreenshot/ScreenshotApp.swift`

- [ ] **Step 1: Define the scene enum (3 scenes for 2a)**

Create `FolinoScreenshot/ScreenshotScene.swift`:
```swift
import SwiftUI

enum ScreenshotScene: CaseIterable {
    case library
    case reader
    case horizontal

    var id: String {
        switch self {
        case .library: "01_Library"
        case .reader: "02_Reader"
        case .horizontal: "06_Horizontal"
        }
    }

    @MainActor @ViewBuilder
    var view: some View {
        switch self {
        case .library: LibraryScene()
        case .reader: ReaderScene()
        case .horizontal: HorizontalScene()
        }
    }
}
```
(Scene ids are stable across 2a/2b: 2b adds `03_PlaybackInspector`/`04_VisualInspector`/`05_ABRepeat`.)

- [ ] **Step 2: Rewrite `ScreenshotApp.swift` to dispatch by launch arg**

```swift
import ScreenshotKit
import SwiftUI

@main
struct ScreenshotApp: App {
    init() {
        ScreenshotEnvironment.bootstrap()
    }

    var body: some Scene {
        WindowGroup {
            if let id = ScreenshotEnvironment.requestedSceneID,
               let scene = ScreenshotScene.allCases.first(where: { $0.id == id }) {
                scene.view
                    .environment(\.screenshotIdiom, ScreenshotEnvironment.idiom)
            } else {
                Text("No scene requested")
            }
        }
    }
}
```
`ScreenshotEnvironment.bootstrap()` with no `prepare` closure proves the DI-agnostic hook works for an app with no global DI container (it only disables animations + registers an empty defaults dict).

- [ ] **Step 3: Add temporary scene stubs so it compiles**

Create `FolinoScreenshot/Scenes/LibraryScene.swift`, `ReaderScene.swift`, `HorizontalScene.swift`, each:
```swift
import SwiftUI
struct LibraryScene: View { var body: some View { Color.clear } }   // rename per file
```
(Real scenes land in Tasks 5-7.)

- [ ] **Step 4: Build**

Run: `xcodebuild -project Folino.xcodeproj -scheme FolinoScreenshot -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' build -skipPackagePluginValidation -quiet`
Expected: exit 0. (`screenshotIdiom` is an `EnvironmentValues` key from ScreenshotKit; confirm it builds.)

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "Add screenshot root: bootstrap + scene dispatch"
```

---

## Task 3: Folino frame layout helper (icon gradient + black text)

**Files:**
- Create: `FolinoScreenshot/FolinoScreenshotLayout.swift`

- [ ] **Step 1: Write the layout helper**

`ScreenshotLayout` exposes `background`/`titleColor`/`subtitleColor`; the `.standard(...)`/`.iPad(...)` factories accept them. Build a Folino layout from the idiom:
```swift
import ScreenshotKit
import SwiftUI

enum FolinoScreenshotLayout {
    /// folino.icon canvas gradient: white -> light blue, vertical (y 0 -> 0.7).
    static let background = LinearGradient(
        stops: [
            .init(color: .white, location: 0),
            .init(color: Color(.sRGB, red: 0.807, green: 0.884, blue: 1.0), location: 0.7),
        ],
        startPoint: .top,
        endPoint: .bottom
    )

    static func layout(for idiom: ScreenshotIdiom, subtitleBullet: Bool = false) -> ScreenshotLayout {
        switch idiom {
        case .iPhone:
            .standard(
                titleColor: .black,
                subtitleColor: .black.opacity(0.85),
                subtitleBullet: subtitleBullet,
                background: background
            )
        case .iPad:
            .iPad(
                titleColor: .black,
                subtitleColor: .black.opacity(0.85),
                subtitleBullet: subtitleBullet,
                background: background
            )
        }
    }
}
```

- [ ] **Step 2: Build**

Run: `xcodebuild -project Folino.xcodeproj -scheme FolinoScreenshot -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' build -skipPackagePluginValidation -quiet`
Expected: exit 0. (Confirms `.standard`/`.iPad` accept `titleColor`/`subtitleColor`/`background` as named args — they do per the ScreenshotKit source.)

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "Add Folino frame layout (icon gradient + black text)"
```

---

## Task 4: Fixture layer

**Files:**
- Create: `FolinoScreenshot/Fixtures/FixtureServices.swift`
- Create: `FolinoScreenshot/Fixtures/FixtureScoreRepository.swift`

- [ ] **Step 1: Confirm the access level of `Score` and its building blocks**

Run: `grep -rn "public struct Score\b\|public init" $(grep -rl "struct Score" Packages/*/Sources Packages/Features/*/Sources 2>/dev/null | head) | head`
Also check `Part`/`Staff`/`Instrument`. Decide the fixture `Score`:
- If `Score(division:parts:metaTags:)` and `Part`/`Staff`/`Instrument` inits are **public**, build a small 1-part score.
- If they are **not public** from the screenshot target, use `Score(division: 480, parts: [], metaTags: ["workTitle": "Now is the time!"])` (an empty score still renders the Reader chrome + an empty staff, which is acceptable for a framed marketing shot in 2a). Record which path you took.

- [ ] **Step 2: Write the no-op services + fixtures**

Create `FolinoScreenshot/Fixtures/FixtureServices.swift`. Conform to each PUBLIC Domain protocol (read each at the file:line in "Key facts"); for a fixture, every method is a minimal no-op / throws / returns empty, EXCEPT the gateway returns the fixture `Score`:
```swift
import Domain
import Foundation
// import SheetMusic module if Score lives there (confirm in Step 1)

enum Fixture {
    static let score = /* Score per Step 1 decision */

    static func scoreItem(title: String, composer: String, favorite: Bool = false) -> ScoreItem {
        ScoreItem(
            id: ScoreItemID(),
            title: title,
            composer: composer,
            instrumentationSummary: "Piano",
            localFileName: "\(title).mscx",
            contentHash: title,
            sizeBytes: 50_000,
            lengthBeats: 1920,
            defaultTempoBpm: 120,
            primaryKey: nil,
            addedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastOpenedAt: nil,
            tagIDs: [],
            isFavorite: favorite,
            deletedAt: nil
        )
    }

    static let items: [ScoreItem] = [
        scoreItem(title: "Now is the time!", composer: "Kiichi", favorite: true),
        scoreItem(title: "Prelude in C", composer: "Bach"),
        scoreItem(title: "Gymnopédie No.1", composer: "Satie"),
    ]
}

// One struct per protocol. Implement EVERY protocol method as a no-op/throw/empty.
// Read the protocol at its cited file:line and stub each requirement.
struct FixtureGateway: ScoreFileGateway { /* return Fixture.score where a Score is needed; no-op writes */ }
struct FixtureImporter: ScoreFileImporter { /* no-op / throw */ }
struct FixtureShareService: ScoreShareService { /* return [] formats / no-op */ }
struct FixtureMetadataReader: ScoreMetadataReading { /* throw / return nil */ }
```
NOTE: The exact method bodies depend on each protocol's requirements — read `ScoreFileGateway.swift:45`, `ScoreShareService.swift:35`, `ScoreMetadataReading.swift:56`, and the `ScoreFileImporter` protocol, and implement each requirement minimally. The compiler enforces completeness; iterate until it builds.

- [ ] **Step 3: Write the populated repository**

Create `FolinoScreenshot/Fixtures/FixtureScoreRepository.swift` conforming to `ScoreLibraryRepository` (read `ScoreLibraryRepository.swift:10` for the full method set). The list-returning method(s) return `Fixture.items`; everything else is a minimal no-op/throw. If the protocol vends an async stream / observation of items, return a stream that yields `Fixture.items` once.

- [ ] **Step 4: Build**

Run: `xcodebuild -project Folino.xcodeproj -scheme FolinoScreenshot -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' build -skipPackagePluginValidation -quiet`
Expected: exit 0 (all protocol conformances complete).

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "Add screenshot fixtures: populated repository + no-op services + fixture score"
```

---

## Task 5: Library scene

**Files:**
- Modify: `FolinoScreenshot/Scenes/LibraryScene.swift`
- Modify: `FolinoScreenshot/ScreenshotStrings.xcstrings` (create)

- [ ] **Step 1: Add the copy catalog with the Library entry**

Create `FolinoScreenshot/ScreenshotStrings.xcstrings` as an empty String Catalog (sourceLanguage `en`) with two keys: `scene.library.title` and `scene.library.subtitle`, English values e.g. "Your whole library" / "Every score in one place". (Localized values for ja/ko/zh-Hans/zh-Hant are filled later by the user/translators; the catalog falls back to en until then.) Add it to the target as a resource (XcodeGen picks up `.xcstrings` under the source path automatically).

- [ ] **Step 2: Implement `LibraryScene`**

```swift
import Domain
import Library
import ScreenshotKit
import SwiftUI

struct LibraryScene: View {
    @Environment(\.screenshotIdiom) private var idiom

    var body: some View {
        ScreenshotFrameView(
            title: LocalizedStringResource("scene.library.title", bundle: .atURL(Bundle.main.bundleURL)),
            subtitle: LocalizedStringResource("scene.library.subtitle", bundle: .atURL(Bundle.main.bundleURL)),
            layout: FolinoScreenshotLayout.layout(for: idiom)
        ) {
            LibraryRootScreen(
                viewModel: LibraryViewModel(
                    repository: FixtureScoreRepository(),
                    importer: FixtureImporter(),
                    gateway: FixtureGateway(),
                    shareService: FixtureShareService(),
                    metadataReader: FixtureMetadataReader()
                ),
                path: .constant(NavigationPath()),
                onOpenScore: { _ in },
                readerDestination: { _ in EmptyView() },
                playlistReaderDestination: { _ in EmptyView() },
                onOpenInPlaylist: { _, _ in },
                licenseContent: { EmptyView() }
            )
        } overlay: {
            EmptyView()
        }
    }
}
```
NOTE: `LibraryRootScreen`'s ViewBuilder generic params (`ReaderContent`, `LicenseContent`) are inferred from `EmptyView` here. If the compiler needs explicit `NavigationStack` wrapping for the list to render its toolbar/title, wrap `LibraryRootScreen` in `NavigationStack { ... }`. Confirm the bundle accessor for the xcstrings: `LocalizedStringResource(_, bundle:)` resolves from the app bundle (`.atURL(Bundle.main.bundleURL)`); if Folino has a different idiom for app-bundle xcstrings, match it.

- [ ] **Step 3: Add a `#Preview` and render it**

Append to `LibraryScene.swift`:
```swift
#Preview { LibraryScene().environment(\.screenshotIdiom, .iPhone) }
```
Verify the rendered preview via `mcp__xcode__RenderPreview` (the Folino worktree project must be the open Xcode project) and Read the PNG. Confirm: light gradient background, black title/subtitle, the library list populated with the 3 fixture items. Iterate on copy/positioning if needed.

- [ ] **Step 4: Build the screenshot scheme**

Run: `xcodebuild -project Folino.xcodeproj -scheme FolinoScreenshot -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' build -skipPackagePluginValidation -quiet`
Expected: exit 0.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "Add Library screenshot scene"
```

---

## Task 6: Reader scene

**Files:**
- Modify: `FolinoScreenshot/Scenes/ReaderScene.swift`
- Modify: `FolinoScreenshot/ScreenshotStrings.xcstrings`

- [ ] **Step 1: Add Reader copy keys**

Add `scene.reader.title` / `scene.reader.subtitle` to `ScreenshotStrings.xcstrings` (en values e.g. "Read any score" / "Clean, focused notation").

- [ ] **Step 2: Implement `ReaderScene`**

```swift
import Domain
import Reader
import ScreenshotKit
import SwiftUI

struct ReaderScene: View {
    @Environment(\.screenshotIdiom) private var idiom

    var body: some View {
        ScreenshotFrameView(
            title: LocalizedStringResource("scene.reader.title", bundle: .atURL(Bundle.main.bundleURL)),
            subtitle: LocalizedStringResource("scene.reader.subtitle", bundle: .atURL(Bundle.main.bundleURL)),
            layout: FolinoScreenshotLayout.layout(for: idiom)
        ) {
            NavigationStack {
                ReaderRootScreen(
                    scoreItem: Fixture.items[0],
                    repository: FixtureScoreRepository(),
                    gateway: FixtureGateway(),
                    shareService: FixtureShareService(),
                    metadataReader: FixtureMetadataReader(),
                    scoresDirectory: URL(filePath: NSTemporaryDirectory()),
                    hidesBackButton: true
                )
            }
        } overlay: {
            EmptyView()
        }
    }
}
```
NOTE: `ReaderRootScreen` loads the score from `gateway` asynchronously on appear; the fixture gateway returns `Fixture.score` synchronously-enough that the UI-test warmup delay (default 5s in `captureScene`) covers it. If the reader shows a loading state in the snapshot, increase the capture `warmup`.

- [ ] **Step 3: Preview + render**

Append `#Preview { ReaderScene().environment(\.screenshotIdiom, .iPhone) }`, render via `mcp__xcode__RenderPreview`, Read the PNG, confirm the reader renders the score (or an acceptable empty staff per Task 4 Step 1) inside the framed layout.

- [ ] **Step 4: Build**

Run: `xcodebuild -project Folino.xcodeproj -scheme FolinoScreenshot -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' build -skipPackagePluginValidation -quiet`
Expected: exit 0.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "Add Reader screenshot scene"
```

---

## Task 7: Horizontal scene

**Files:**
- Modify: `FolinoScreenshot/Scenes/HorizontalScene.swift`
- Modify: `FolinoScreenshot/ScreenshotStrings.xcstrings`

- [ ] **Step 1: Add Horizontal copy keys**

Add `scene.horizontal.title` / `scene.horizontal.subtitle` (en e.g. "Horizontal scrolling" / "Follow along left to right").

- [ ] **Step 2: Implement `HorizontalScene`**

Same as `ReaderScene` but force horizontal layout via the UserDefaults key before the Reader reads it. Set it at scene init (runs before the view body):
```swift
import Domain
import Reader
import ScreenshotKit
import SwiftUI

struct HorizontalScene: View {
    @Environment(\.screenshotIdiom) private var idiom

    init() {
        UserDefaults.standard.set(
            ReaderLayoutMode.horizontal.rawValue,
            forKey: "readerLayoutMode"
        )
    }

    var body: some View {
        ScreenshotFrameView(
            title: LocalizedStringResource("scene.horizontal.title", bundle: .atURL(Bundle.main.bundleURL)),
            subtitle: LocalizedStringResource("scene.horizontal.subtitle", bundle: .atURL(Bundle.main.bundleURL)),
            layout: FolinoScreenshotLayout.layout(for: idiom)
        ) {
            NavigationStack {
                ReaderRootScreen(
                    scoreItem: Fixture.items[0],
                    repository: FixtureScoreRepository(),
                    gateway: FixtureGateway(),
                    shareService: FixtureShareService(),
                    metadataReader: FixtureMetadataReader(),
                    scoresDirectory: URL(filePath: NSTemporaryDirectory()),
                    hidesBackButton: true
                )
            }
        } overlay: {
            EmptyView()
        }
    }
}
```
NOTE: confirm the UserDefaults key string `"readerLayoutMode"` matches `ReaderGlobalSettingsKey.layoutMode` (read `Packages/Domain/.../ReaderLayoutMode.swift`); use the constant if it's public (`ReaderGlobalSettingsKey.layoutMode`) instead of the literal.

- [ ] **Step 3: Preview + render**

Append `#Preview`, render via `mcp__xcode__RenderPreview`, confirm horizontal layout shows.

- [ ] **Step 4: Build**

Run: `xcodebuild -project Folino.xcodeproj -scheme FolinoScreenshot -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' build -skipPackagePluginValidation -quiet`
Expected: exit 0.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "Add Horizontal screenshot scene"
```

---

## Task 8: UITests + .screenshots.yml + validation run

**Files:**
- Create: `Tests/FolinoUITests/ScreenshotsUITests.swift`
- Create: `.screenshots.yml`

- [ ] **Step 1: Write the UI test**

Create `Tests/FolinoUITests/ScreenshotsUITests.swift`:
```swift
import ScreenshotKitUITest
import XCTest

@MainActor
final class ScreenshotsUITests: XCTestCase {
    private let languages = ["en", "ja", "ko", "zh-Hans", "zh-Hant"]

    override func setUp() {
        continueAfterFailure = false
    }

    func testCaptureLibrary() { captureScene(id: "01_Library", languages: languages, in: self) }
    func testCaptureReader() { captureScene(id: "02_Reader", languages: languages, in: self) }
    func testCaptureHorizontal() { captureScene(id: "06_Horizontal", languages: languages, in: self) }
}
```

- [ ] **Step 2: Build-for-testing (verifies ScreenshotKitUITest links)**

Run: `xcodebuild -project Folino.xcodeproj -scheme FolinoScreenshot -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' build-for-testing -skipPackagePluginValidation -quiet`
Expected: exit 0.

- [ ] **Step 3: Write `.screenshots.yml`**

Create `.screenshots.yml` at the worktree root:
```yaml
project: Folino.xcodeproj
scheme: FolinoScreenshot
test_plan: FolinoUITests/ScreenshotsUITests
destinations:
  - { name: "iPhone 17 Pro Max",     alias: "iPhone69" }
  - { name: "iPad Pro 13-inch (M5)", alias: "iPad13" }
locales:
  en: en-US
  ja: ja
  ko: ko
  zh-Hans: zh-Hans
  zh-Hant: zh-Hant
output: fastlane/screenshots
filename: "{order}_{alias}_{scene}"
options:
  skip_package_plugin_validation: true
  parallel: true
```

- [ ] **Step 4: Temporarily narrow languages for the validation run**

Edit `ScreenshotsUITests.swift` `languages` to `["en", "ja"]` (temporary; do NOT commit this narrowing). Also temporarily set `output: /tmp/folino-shots` in `.screenshots.yml` so the validation run doesn't wipe `fastlane/screenshots`.

- [ ] **Step 5: Run the capture (long; run in background if it exceeds the shell timeout)**

Run: `~/Developer/Personal/tools/ios-screenshot/ios-screenshot .screenshots.yml`
Expected: PNGs under `/tmp/folino-shots/<locale>/`.

- [ ] **Step 6: Validate the output tree**

Run: `find /tmp/folino-shots -name '*.png' | sort`
Expected: `en-US/` and `ja/`, each with `01_iPhone69_Library.png`, `01_iPad13_Library.png`, `02_*_Reader.png`, `06_*_Horizontal.png` — 3 scenes × 2 devices × 2 langs = 12 PNGs, none empty. Spot-check dimensions: `sips -g pixelWidth -g pixelHeight /tmp/folino-shots/en-US/01_iPhone69_Library.png` → 1320×2868; iPad → 2064×2752. Read one PNG to confirm the framed Folino styling (gradient + black text).

- [ ] **Step 7: Restore full languages + deliver output dir**

Revert `ScreenshotsUITests.swift` `languages` to all 5; revert `.screenshots.yml` `output` to `fastlane/screenshots`.

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "Add FolinoUITests screenshot capture + .screenshots.yml (validated en/ja)"
```

---

## Done criteria (Phase 2a)

- `FolinoScreenshot` + `FolinoUITests` targets build; `ios-screenshot` drives them.
- 3 scenes (Library, Reader, Horizontal) render framed with the folino.icon gradient + black text, validated en/ja × iPhone/iPad (12 PNGs, correct dimensions).
- `.screenshots.yml` committed with full 5 locales; output to `fastlane/screenshots`.
- DI-agnostic `bootstrap()` (empty prepare) confirmed working for Folino.
- Phase 2b (inspector scenes) ready to plan; full 5-language production capture + visual review + localized copy happen at the next Folino release.
```
