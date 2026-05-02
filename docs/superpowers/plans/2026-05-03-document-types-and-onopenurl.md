# Document Types + onOpenURL Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Folino a valid "Open in" target for `.mscx` / `.mscz` / `.musicxml` / `.mxl` / `.xml` / `.midi` files coming from Files.app, AirDrop, Mail, etc., and route incoming URLs through the existing import pipeline.

**Architecture:** Five `CFBundleDocumentTypes` + four `UTImportedTypeDeclarations` in `App/Info.plist` (identifiers match `swift-sheet-music`'s example for cross-app coherence). `FolinoApp` adds `.onOpenURL` on the WindowGroup. `AppBootstrap` gains a `pendingIncomingURL` slot (queue size 1, last-wins) so URLs received during cold-launch are not dropped. `AppShellView`'s `ReadyShell` drains the slot with `.task(id:)` and forwards to the existing `LibraryViewModel.startImport(from:)` — the dedupe alert / error alert / Reader auto-push behaviors are already wired and need no change. Security-scoped resource bracketing inside `LiveScoreFileImporter.prepareImport` and `commitImport` is **already in place** from the previous plan; no change needed there.

**Tech Stack:** Swift 6.3, SwiftUI iOS 26, `@Observable`, `.onOpenURL`, `.task(id:)`, `LSSupportsOpeningDocumentsInPlace`, `UTImportedTypeDeclarations`.

---

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `App/Info.plist` | Document type registration so Files.app / AirDrop / Mail show "Open in Folino" | Modify (add 3 top-level dicts) |
| `App/AppBootstrap.swift` | Hold incoming URL until app is ready | Modify (3 new members) |
| `App/FolinoApp.swift` | Wire `.onOpenURL` to bootstrap | Modify (1 modifier) |
| `App/AppShellView.swift` | Drain pending URL once the LibraryViewModel exists | Modify (pass bootstrap into ReadyShell + add `.task(id:)`) |
| `docs/superpowers/specs/2026-05-02-library-and-minimum-reader-design.md` | Strike "Document Types / `onOpenURL`" from v1 follow-up list | Modify (1 line) |

No new files. No new modules. No new types.

---

## Task 1: Register Document Types and UTType Declarations in Info.plist

**Files:**
- Modify: `App/Info.plist`

**Goal:** Add 5 `CFBundleDocumentTypes` entries, 4 `UTImportedTypeDeclarations` entries, and `LSSupportsOpeningDocumentsInPlace = YES`. After this task, Files.app shows Folino in the share sheet for `.mscx` / `.mscz` / `.musicxml` / `.xml` / `.mxl` / `.mid`. Tapping a file does nothing useful yet (no `.onOpenURL` handler), but the registration is visible.

- [ ] **Step 1: Read the existing Info.plist**

Run:
```sh
cat App/Info.plist
```

Confirm: top-level `<dict>` contains keys `CFBundleDevelopmentRegion`, `CFBundleDisplayName`, `CFBundleExecutable`, `CFBundleIdentifier`, `CFBundleInfoDictionaryVersion`, `CFBundleName`, `CFBundlePackageType`, `CFBundleShortVersionString`, `CFBundleVersion`, `LSRequiresIPhoneOS`, `UILaunchScreen`, `UIApplicationSceneManifest`, `UISupportedInterfaceOrientations`, `UISupportedInterfaceOrientations~ipad`. No `CFBundleDocumentTypes`, no `UTImportedTypeDeclarations`, no `LSSupportsOpeningDocumentsInPlace` yet.

- [ ] **Step 2: Replace `App/Info.plist` with the registered version**

Write the full file contents below:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>$(DEVELOPMENT_LANGUAGE)</string>
    <key>CFBundleDisplayName</key>
    <string>Folino</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>
            <string>MuseScore Score (mscx)</string>
            <key>LSHandlerRank</key>
            <string>Default</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>org.musescore.mscx</string>
            </array>
        </dict>
        <dict>
            <key>CFBundleTypeName</key>
            <string>MuseScore Score (mscz)</string>
            <key>LSHandlerRank</key>
            <string>Default</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>org.musescore.mscz</string>
            </array>
        </dict>
        <dict>
            <key>CFBundleTypeName</key>
            <string>MusicXML</string>
            <key>LSHandlerRank</key>
            <string>Default</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>com.recordare.musicxml</string>
            </array>
        </dict>
        <dict>
            <key>CFBundleTypeName</key>
            <string>Compressed MusicXML</string>
            <key>LSHandlerRank</key>
            <string>Default</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>com.recordare.musicxml.zipped</string>
            </array>
        </dict>
        <dict>
            <key>CFBundleTypeName</key>
            <string>Standard MIDI File</string>
            <key>LSHandlerRank</key>
            <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.midi-audio</string>
            </array>
        </dict>
    </array>
    <key>CFBundleExecutable</key>
    <string>$(EXECUTABLE_NAME)</string>
    <key>CFBundleIdentifier</key>
    <string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$(PRODUCT_NAME)</string>
    <key>CFBundlePackageType</key>
    <string>$(PRODUCT_BUNDLE_PACKAGE_TYPE)</string>
    <key>CFBundleShortVersionString</key>
    <string>$(MARKETING_VERSION)</string>
    <key>CFBundleVersion</key>
    <string>$(CURRENT_PROJECT_VERSION)</string>
    <key>LSRequiresIPhoneOS</key>
    <true/>
    <key>LSSupportsOpeningDocumentsInPlace</key>
    <true/>
    <key>UILaunchScreen</key>
    <dict/>
    <key>UIApplicationSceneManifest</key>
    <dict>
        <key>UIApplicationSupportsMultipleScenes</key>
        <true/>
    </dict>
    <key>UISupportedInterfaceOrientations</key>
    <array>
        <string>UIInterfaceOrientationPortrait</string>
        <string>UIInterfaceOrientationLandscapeLeft</string>
        <string>UIInterfaceOrientationLandscapeRight</string>
    </array>
    <key>UISupportedInterfaceOrientations~ipad</key>
    <array>
        <string>UIInterfaceOrientationPortrait</string>
        <string>UIInterfaceOrientationPortraitUpsideDown</string>
        <string>UIInterfaceOrientationLandscapeLeft</string>
        <string>UIInterfaceOrientationLandscapeRight</string>
    </array>
    <key>UTImportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeConformsTo</key>
            <array>
                <string>public.xml</string>
            </array>
            <key>UTTypeDescription</key>
            <string>MuseScore Score (MSCX)</string>
            <key>UTTypeIconFiles</key>
            <array/>
            <key>UTTypeIdentifier</key>
            <string>org.musescore.mscx</string>
            <key>UTTypeTagSpecification</key>
            <dict>
                <key>public.filename-extension</key>
                <array>
                    <string>mscx</string>
                </array>
            </dict>
        </dict>
        <dict>
            <key>UTTypeConformsTo</key>
            <array>
                <string>public.zip-archive</string>
            </array>
            <key>UTTypeDescription</key>
            <string>MuseScore Compressed Score (MSCZ)</string>
            <key>UTTypeIconFiles</key>
            <array/>
            <key>UTTypeIdentifier</key>
            <string>org.musescore.mscz</string>
            <key>UTTypeTagSpecification</key>
            <dict>
                <key>public.filename-extension</key>
                <array>
                    <string>mscz</string>
                </array>
            </dict>
        </dict>
        <dict>
            <key>UTTypeConformsTo</key>
            <array>
                <string>public.xml</string>
            </array>
            <key>UTTypeDescription</key>
            <string>MusicXML Score</string>
            <key>UTTypeIconFiles</key>
            <array/>
            <key>UTTypeIdentifier</key>
            <string>com.recordare.musicxml</string>
            <key>UTTypeTagSpecification</key>
            <dict>
                <key>public.filename-extension</key>
                <array>
                    <string>musicxml</string>
                    <string>xml</string>
                </array>
                <key>public.mime-type</key>
                <array>
                    <string>application/vnd.recordare.musicxml+xml</string>
                </array>
            </dict>
        </dict>
        <dict>
            <key>UTTypeConformsTo</key>
            <array>
                <string>public.zip-archive</string>
            </array>
            <key>UTTypeDescription</key>
            <string>Compressed MusicXML Score</string>
            <key>UTTypeIconFiles</key>
            <array/>
            <key>UTTypeIdentifier</key>
            <string>com.recordare.musicxml.zipped</string>
            <key>UTTypeTagSpecification</key>
            <dict>
                <key>public.filename-extension</key>
                <array>
                    <string>mxl</string>
                </array>
                <key>public.mime-type</key>
                <array>
                    <string>application/vnd.recordare.musicxml</string>
                </array>
            </dict>
        </dict>
    </array>
</dict>
</plist>
```

- [ ] **Step 3: Verify the file is valid plist XML**

Run:
```sh
plutil -lint App/Info.plist
```

Expected output: `App/Info.plist: OK`.

- [ ] **Step 4: Build the app**

Run:
```sh
xcodebuild -project Folino.xcodeproj -scheme Folino \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -skipPackagePluginValidation build
```

Expected: `** BUILD SUCCEEDED **` near the end.

- [ ] **Step 5: Commit**

```sh
git add App/Info.plist
git commit -m "feat(app): register score document types + UTI imports

Folino now appears in 'Open in' sheets for .mscx, .mscz, .musicxml,
.xml, .mxl, and .mid. Identifiers match swift-sheet-music's example
so multi-app coexistence shows a coherent share sheet.
LSSupportsOpeningDocumentsInPlace lets Files.app hand the original
URL through instead of forcing an Inbox copy."
```

---

## Task 2: Add Pending-URL Slot to AppBootstrap

**Files:**
- Modify: `App/AppBootstrap.swift`

**Goal:** `AppBootstrap` exposes a single-slot URL queue (`pendingIncomingURL`, last-wins) and accept/consume helpers. After this task no observer reacts to the slot yet.

- [ ] **Step 1: Read the current AppBootstrap.swift**

Run:
```sh
cat App/AppBootstrap.swift
```

Confirm: it's an `@MainActor @Observable` class with `isReady`, `failure`, `database`, `repository`, `gateway`, `importer`, and a `start()` method. No URL handling.

- [ ] **Step 2: Add `pendingIncomingURL` and helpers**

Edit `App/AppBootstrap.swift`. Add the property block after the existing `private(set) var importer:` line, just before the `init` / `start` section. The full updated file:

```swift
import Domain
import Foundation
import Observation
import Persistence
import ScoreFiles

@MainActor
@Observable
final class AppBootstrap {
    private(set) var isReady = false
    private(set) var failure: Error?

    private(set) var database: AppDatabase?
    private(set) var repository: LiveScoreLibraryRepository?
    private(set) var gateway: LiveScoreFileGateway?
    private(set) var importer: LiveScoreFileImporter?

    /// Single-slot queue for an incoming URL received via `.onOpenURL`.
    /// Last-wins: a second URL arriving before the first is consumed
    /// overwrites it. v1 only opens one file at a time.
    private(set) var pendingIncomingURL: URL?

    func start() {
        do {
            try FileManager.default.createDirectory(
                at: AppPaths.scoresDirectory, withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: AppPaths.soundfontCacheDirectory, withIntermediateDirectories: true
            )
            let database = try AppDatabase(databaseURL: AppPaths.databaseURL)
            let repository = LiveScoreLibraryRepository(
                database: database,
                scoresDirectory: AppPaths.scoresDirectory
            )
            let gateway = LiveScoreFileGateway()
            let importer = LiveScoreFileImporter(
                gateway: gateway,
                repository: repository,
                scoresDirectory: AppPaths.scoresDirectory
            )

            self.database = database
            self.repository = repository
            self.gateway = gateway
            self.importer = importer

            Task { [weak self] in
                do {
                    try await repository.refresh()
                    self?.isReady = true
                } catch {
                    self?.failure = error
                }
            }
        } catch {
            failure = error
        }
    }

    func acceptIncomingURL(_ url: URL) {
        pendingIncomingURL = url
    }

    func consumePendingIncomingURL() -> URL? {
        let url = pendingIncomingURL
        pendingIncomingURL = nil
        return url
    }
}
```

- [ ] **Step 3: Build the app**

Run:
```sh
xcodebuild -project Folino.xcodeproj -scheme Folino \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -skipPackagePluginValidation build
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```sh
git add App/AppBootstrap.swift
git commit -m "feat(app): add pendingIncomingURL slot to AppBootstrap

Single-slot last-wins queue for URLs received via .onOpenURL during
cold launch. accept/consume helpers stay sync — the slot's only job
is to bridge the gap until ReadyShell exists."
```

---

## Task 3: Wire `.onOpenURL` in FolinoApp

**Files:**
- Modify: `App/FolinoApp.swift`

**Goal:** SwiftUI delivers incoming URLs to `AppBootstrap.acceptIncomingURL`. Nothing observes the slot yet (Task 4 does), but URLs are no longer dropped on the floor.

- [ ] **Step 1: Read the current FolinoApp.swift**

Run:
```sh
cat App/FolinoApp.swift
```

Confirm: it's a 12-ish line `@main struct FolinoApp: App` with one WindowGroup containing `AppShellView(bootstrap: bootstrap).task { bootstrap.start() }`.

- [ ] **Step 2: Add `.onOpenURL`**

Replace `App/FolinoApp.swift` with:

```swift
import SwiftUI

@main
struct FolinoApp: App {
    @State private var bootstrap = AppBootstrap()

    var body: some Scene {
        WindowGroup {
            AppShellView(bootstrap: bootstrap)
                .task { bootstrap.start() }
                .onOpenURL { bootstrap.acceptIncomingURL($0) }
        }
    }
}
```

- [ ] **Step 3: Build the app**

Run:
```sh
xcodebuild -project Folino.xcodeproj -scheme Folino \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -skipPackagePluginValidation build
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```sh
git add App/FolinoApp.swift
git commit -m "feat(app): forward .onOpenURL to AppBootstrap

Slot lives on AppBootstrap because LibraryViewModel doesn't exist yet
during cold launch. AppShellView drains it once the library is wired."
```

---

## Task 4: Drain Pending URL from ReadyShell

**Files:**
- Modify: `App/AppShellView.swift`

**Goal:** Once `bootstrap.isReady` is `true` and `ReadyShell` is on screen, observe `bootstrap.pendingIncomingURL` via `.task(id:)` and forward to `libraryVM.startImport`. This closes the loop: file tapped in Files.app → import flow → Reader push.

- [ ] **Step 1: Read the current AppShellView.swift**

Run:
```sh
cat App/AppShellView.swift
```

Confirm: `AppShellView` holds `let bootstrap: AppBootstrap` and conditionally renders `ReadyShell(repository:importer:gateway:scoresDirectory:)`. ReadyShell does not currently take `bootstrap`.

- [ ] **Step 2: Pass `bootstrap` into ReadyShell and add the `.task(id:)`**

Replace the file with:

```swift
import Domain
import Library
import LicenseList
import Reader
import Settings
import SwiftUI

struct AppShellView: View {
    let bootstrap: AppBootstrap

    var body: some View {
        Group {
            if let repository = bootstrap.repository,
               let importer = bootstrap.importer,
               let gateway = bootstrap.gateway,
               bootstrap.isReady
            {
                ReadyShell(
                    bootstrap: bootstrap,
                    repository: repository,
                    importer: importer,
                    gateway: gateway,
                    scoresDirectory: AppPaths.scoresDirectory
                )
            } else if let failure = bootstrap.failure {
                ContentUnavailableView {
                    Label("Folino couldn't start", systemImage: "exclamationmark.triangle")
                } description: {
                    Text((failure as? LocalizedError)?.errorDescription ?? failure.localizedDescription)
                }
            } else {
                ProgressView().controlSize(.large)
            }
        }
    }
}

private struct ReadyShell: View {
    let bootstrap: AppBootstrap
    let repository: any ScoreLibraryRepository
    let importer: any ScoreFileImporter
    let gateway: any ScoreFileGateway
    let scoresDirectory: URL

    @State private var libraryVM: LibraryViewModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var compactPath = NavigationPath()
    @State private var sidebarPath = NavigationPath()
    @State private var detailScoreItem: ScoreItem?
    @State private var isSettingsPresented = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .doubleColumn

    init(
        bootstrap: AppBootstrap,
        repository: any ScoreLibraryRepository,
        importer: any ScoreFileImporter,
        gateway: any ScoreFileGateway,
        scoresDirectory: URL
    ) {
        self.bootstrap = bootstrap
        self.repository = repository
        self.importer = importer
        self.gateway = gateway
        self.scoresDirectory = scoresDirectory
        _libraryVM = State(
            wrappedValue: LibraryViewModel(
                repository: repository, importer: importer, gateway: gateway
            )
        )
    }

    var body: some View {
        Group {
            if horizontalSizeClass == .regular {
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    sidebar
                } detail: {
                    if let item = detailScoreItem {
                        ReaderView(
                            scoreItem: item,
                            repository: repository,
                            gateway: gateway,
                            scoresDirectory: scoresDirectory
                        )
                    } else {
                        ContentUnavailableView(
                            "Select a score",
                            systemImage: "music.note"
                        )
                    }
                }
            } else {
                LibraryRootView(
                    viewModel: libraryVM,
                    path: $compactPath,
                    onOpenScore: { compactPath.append($0) },
                    readerDestination: { item in
                        ReaderView(
                            scoreItem: item,
                            repository: repository,
                            gateway: gateway,
                            scoresDirectory: scoresDirectory
                        )
                    },
                    licenseContent: { LicenseListView() },
                    leadingToolbarItem: { settingsButton }
                )
            }
        }
        .sheet(isPresented: $isSettingsPresented) {
            SettingsSheet { LicenseListView() }
        }
        .onChange(of: libraryVM.pendingScoreToOpen?.id) { _, newID in
            guard let newID,
                  let item = libraryVM.pendingScoreToOpen,
                  item.id == newID else { return }
            libraryVM.pendingScoreToOpen = nil
            if horizontalSizeClass == .regular {
                detailScoreItem = item
                columnVisibility = .detailOnly
            } else {
                compactPath.append(item)
            }
        }
        .task(id: bootstrap.pendingIncomingURL) {
            guard let url = bootstrap.consumePendingIncomingURL() else { return }
            await libraryVM.startImport(from: url)
        }
    }

    @ViewBuilder
    private var sidebar: some View {
        LibraryRootView(
            viewModel: libraryVM,
            path: $sidebarPath,
            onOpenScore: { item in
                detailScoreItem = item
                columnVisibility = .detailOnly
            },
            readerDestination: { item in
                ReaderView(
                    scoreItem: item,
                    repository: repository,
                    gateway: gateway,
                    scoresDirectory: scoresDirectory
                )
            },
            licenseContent: { LicenseListView() },
            leadingToolbarItem: { settingsButton }
        )
    }

    private var settingsButton: some View {
        Button {
            isSettingsPresented = true
        } label: {
            Image(systemName: "gear").accessibilityLabel("Settings")
        }
    }
}
```

The only structural changes vs HEAD are:
1. `AppShellView` passes `bootstrap` into `ReadyShell`.
2. `ReadyShell` has a new `let bootstrap: AppBootstrap` and a matching init parameter.
3. The body gets one new modifier: `.task(id: bootstrap.pendingIncomingURL) { ... }`.

- [ ] **Step 3: Build the app**

Run:
```sh
xcodebuild -project Folino.xcodeproj -scheme Folino \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -skipPackagePluginValidation build
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Run all package tests to verify no regressions**

Run:
```sh
for d in Packages/Domain Packages/Utility Packages/Infrastructure \
         Packages/Features/Library Packages/Features/Reader \
         Packages/Features/Settings Packages/Features/ImportExport \
         Packages/Features/Editor; do
  echo "=== $d ==="
  (cd "$d" && swift test 2>&1 | tail -1)
done
```

Expected: Every line ending in `passed`. Total: ~128 tests across 8 packages.

- [ ] **Step 5: Commit**

```sh
git add App/AppShellView.swift
git commit -m "feat(app): drain pending incoming URL through LibraryViewModel.startImport

ReadyShell observes bootstrap.pendingIncomingURL via .task(id:) and
forwards to the existing import pipeline. Cold-launch and warm-foreground
paths share one handler; existing duplicate alert / error alert / Reader
push behaviors carry the rest."
```

---

## Task 5: Manual Verification Pass

**Files:**
- Modify: `docs/superpowers/specs/2026-05-02-library-and-minimum-reader-design.md`

**Goal:** Confirm Folino is reachable from real share-sheet entry points and that each error mode is visible. Also strike "Document Types / `onOpenURL`" from the v1 follow-up list in the previous spec.

This task is hands-on. Document any anomalies in this task's commit message.

- [ ] **Step 1: Boot iPhone simulator and install fresh build**

Run:
```sh
xcrun simctl list devices booted | grep iPhone
```

If none booted, boot one:
```sh
xcrun simctl boot "iPhone 17"
open -a Simulator
```

Install:
```sh
xcodebuild -project Folino.xcodeproj -scheme Folino \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -skipPackagePluginValidation build
APP_PATH="$HOME/Library/Developer/Xcode/DerivedData/Folino-brqhloqdrzitgwdvrsoomtfkoeyt/Build/Products/Debug-iphonesimulator/Folino.app"
xcrun simctl uninstall "iPhone 17" com.KeyNumber.Folino 2>/dev/null
xcrun simctl install "iPhone 17" "$APP_PATH"
```

(If the DerivedData hash differs, locate it via `xcodebuild -showBuildSettings | grep BUILD_DIR`.)

- [ ] **Step 2: Push a sample score into the simulator's Files**

Pick any `.mscx` or `.mscz` you have on your Mac. Drop it into the simulator window — it lands in the simulator's Photos / Files. Or use:
```sh
xcrun simctl push "iPhone 17" /path/to/score.mscz '{ "fileURL": "..." }'
```

The simplest path: drag the score from Finder onto the running simulator window. The OS prompts where to save it; pick **Files → On My iPhone**.

- [ ] **Step 3: Verify "Open in Folino" appears in Files.app**

In the simulator: open Files.app. Long-press the score → tap "Share" → confirm Folino is in the list. Tap Folino. Expected:
- Folino opens (cold-launch from the share sheet).
- The Reader displays the score, OR the duplicate alert fires if the score was already imported, OR an error alert fires for `.midi`.

- [ ] **Step 4: Verify the warm-foreground path**

While Folino is open in the simulator, repeat Step 3 from Files.app. Expected: same outcome, but no app re-launch animation.

- [ ] **Step 5: Verify the error path with a `.midi` file**

Drop a `.mid` file into the simulator's Files. Tap Share → Folino. Expected: Library opens with an alert "Folino can't open this file type." (the existing localized string for `DomainError.scoreParseFailed("MIDI parsing not yet supported")`). Dismiss the alert.

- [ ] **Step 6: Verify cold launch with a queued URL**

Force-quit Folino in the simulator (swipe up + flick away). In Files.app, tap Share → Folino. Expected: Folino cold-launches and the imported score's Reader appears (or the duplicate alert).

- [ ] **Step 7: Strike the follow-up bullet from the previous spec**

Edit `docs/superpowers/specs/2026-05-02-library-and-minimum-reader-design.md`. Find the bullet:

```markdown
- **Document Types / `onOpenURL`** — "Open in Folino" from Files.app, AirDrop targets. Requires `CFBundleDocumentTypes`, `UTImportedTypeDeclarations`, and an `.onOpenURL` handler that calls `commitImport(at:as: .importAsNew)` with the same duplicate flow.
```

Remove it (delete the entire line, including the trailing newline). Verify the surrounding "Tracked as v1 follow-ups" list still has the other 3 items: Multi-file import, Search kana-folding, Tag color UI.

- [ ] **Step 8: Commit**

```sh
git add docs/superpowers/specs/2026-05-02-library-and-minimum-reader-design.md
git commit -m "docs: strike Document Types/onOpenURL from v1 follow-up list

Shipped in plan #5 (2026-05-03). Manual verification covered Files.app
cold-launch, warm-foreground, MIDI error alert, and cold-launch URL
queuing on iPhone 17 simulator."
```

---

## Self-Review Notes (resolved)

- **Spec said path was `Packages/Infrastructure/Sources/ScoreFiles/LiveScoreFileImporter.swift`.** Actual path is `Packages/Infrastructure/Sources/Persistence/LiveScoreFileImporter.swift`. The plan does not modify the importer (security-scoped bracketing is already present at lines 28-29 of that file), so the path discrepancy is moot for execution.
- **No automated test for `AppBootstrap.acceptIncomingURL` / `consumePendingIncomingURL`.** No App-level XCTest target exists; the queue is two trivial accessors over an optional. Manual verification covers the behavior.
- **Identifier coherence with `swift-sheet-music`.** All four declared UTType identifiers (`org.musescore.mscx`, `org.musescore.mscz`, `com.recordare.musicxml`, `com.recordare.musicxml.zipped`) match `Packages/Infrastructure/.build/checkouts/swift-sheet-music/Example/Info.plist` exactly, so a future user with both apps installed sees a consistent share sheet.
- **`.task(id:)` semantics with `nil`.** When `consumePendingIncomingURL()` clears the slot back to `nil`, `bootstrap.pendingIncomingURL` becomes `nil` and `.task(id:)` re-runs — but immediately bails on `guard let url = ... else { return }`. No infinite loop because consume only runs when the URL was non-nil to begin with.
