# Firebase Crashlytics Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Firebase Crashlytics crash reporting to folino, behind folino's layered-module boundary, with a Settings opt-out toggle (default on).

**Architecture:** A `CrashReporter` protocol in `UtilityCore` (ambient-service pattern, like `Clock`); a `FirebaseCrashReporter` adapter in a new `Infrastructure/CrashReporting` product that wraps `FirebaseCrashlytics` and owns `FirebaseApp.configure()`; `AppBootstrap` (composition root) creates and configures it and threads it into `SettingsSheet`. Firebase imports are confined to the `CrashReporting` target and `AppBootstrap`.

**Tech Stack:** Swift 6.3, iOS 26, SwiftPM, xcodegen, Firebase iOS SDK (`firebase-ios-sdk`: `FirebaseCore` + `FirebaseCrashlytics`), Swift Testing.

**Reference spec:** `docs/superpowers/specs/2026-05-27-firebase-crashlytics-design.md`

---

## File Structure

| File | Responsibility | Action |
| --- | --- | --- |
| `Packages/Utility/Sources/UtilityCore/CrashReporter.swift` | `CrashReporter` protocol + `NoopCrashReporter` | Create |
| `Packages/Utility/Tests/UtilityCoreTests/CrashReporterTests.swift` | Noop conformance test | Create |
| `Packages/Domain/Sources/Domain/Models/PrivacySettingsKey.swift` | UserDefaults key for the opt-out | Create |
| `Packages/Domain/Tests/DomainTests/Models/PrivacySettingsKeyTests.swift` | Key-string regression guard | Create |
| `Packages/Infrastructure/Sources/CrashReporting/FirebaseCrashReporter.swift` | Firebase adapter + `configure()` | Create |
| `Packages/Infrastructure/Package.swift` | Add firebase + Utility deps, new product/target | Modify |
| `project.yml` | firebase package, App dep, dSYM upload script, Release dSYM | Modify |
| `App/GoogleService-Info.plist` | Firebase config (from MCP) | Create (committed) |
| `App/Info.plist` | `FirebaseCrashlyticsCollectionEnabled = NO` | Modify |
| `App/PrivacyInfo.xcprivacy` | App-level privacy manifest (Crash Data) | Create |
| `App/AppBootstrap.swift` | Configure Crashlytics + hold reporter | Modify |
| `App/AppShellView.swift` | Pass `bootstrap.crashReporter` into `SettingsSheet` | Modify |
| `Packages/Features/Settings/Sources/Settings/Screens/SettingsSheet.swift` | Privacy section + toggle + injected reporter | Modify |
| `Packages/Features/Settings/Sources/Settings/Resources/Localizable.xcstrings` | New localization keys (5 locales) | Modify |
| `Packages/Features/Settings/Package.swift` | (already depends on UtilityCore — no change needed; verify) | Verify |
| `Packages/Features/Settings/Tests/SettingsTests/SettingsSheetTests.swift` | Spy reporter + construction test | Modify |
| `docs/product/privacy-and-accessibility.md` | Document opt-out behavior | Modify |

---

## Task 1: `CrashReporter` protocol in UtilityCore

**Files:**
- Create: `Packages/Utility/Sources/UtilityCore/CrashReporter.swift`
- Test: `Packages/Utility/Tests/UtilityCoreTests/CrashReporterTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Packages/Utility/Tests/UtilityCoreTests/CrashReporterTests.swift`:

```swift
import Testing
@testable import UtilityCore

struct CrashReporterTests {
    @Test func `noop reporter satisfies the protocol and ignores all calls`() {
        let reporter: any CrashReporter = NoopCrashReporter()
        // None of these should crash or have observable effect.
        reporter.setCollectionEnabled(true)
        reporter.setCollectionEnabled(false)
        reporter.log("hello")
        reporter.record(error: CocoaError(.fileNoSuchFile))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd Packages/Utility && swift test --filter CrashReporterTests`
Expected: FAIL — `cannot find 'CrashReporter' / 'NoopCrashReporter' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `Packages/Utility/Sources/UtilityCore/CrashReporter.swift`:

```swift
import Foundation

/// Ambient crash-reporting abstraction. Production code depends on `any CrashReporter` rather than a concrete crash SDK
/// so Features stay testable and the SDK import stays in one Infrastructure target.
///
/// Implementations must be safe to call from any actor.
public protocol CrashReporter: Sendable {
    /// Enable or disable crash-data collection. Implementations persist this across launches.
    func setCollectionEnabled(_ enabled: Bool)

    /// Append a breadcrumb-style message to the next crash report, if collection is enabled.
    func log(_ message: String)

    /// Record a non-fatal error.
    func record(error: Error)
}

/// No-op `CrashReporter` for SwiftUI previews and tests. Never touches a crash SDK.
public struct NoopCrashReporter: CrashReporter {
    public init() {}
    public func setCollectionEnabled(_: Bool) {}
    public func log(_: String) {}
    public func record(error _: Error) {}
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd Packages/Utility && swift test --filter CrashReporterTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/Utility/Sources/UtilityCore/CrashReporter.swift Packages/Utility/Tests/UtilityCoreTests/CrashReporterTests.swift
git commit -m "Add CrashReporter ambient-service protocol to UtilityCore"
```

---

## Task 2: `PrivacySettingsKey` in Domain

**Files:**
- Create: `Packages/Domain/Sources/Domain/Models/PrivacySettingsKey.swift`
- Test: `Packages/Domain/Tests/DomainTests/Models/PrivacySettingsKeyTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Packages/Domain/Tests/DomainTests/Models/PrivacySettingsKeyTests.swift`:

```swift
import Testing
@testable import Domain

struct PrivacySettingsKeyTests {
    /// The raw string is user state. Renaming it silently resets every installed user's opt-out preference, so this
    /// test guards the literal the way `ReaderGlobalSettingsKey.metronomeEnabled` is guarded by comment.
    @Test func `crash reporting key is the stable literal`() {
        #expect(PrivacySettingsKey.crashReportingEnabled == "privacyCrashReportingEnabled")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd Packages/Domain && swift test --filter PrivacySettingsKeyTests`
Expected: FAIL — `cannot find 'PrivacySettingsKey' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `Packages/Domain/Sources/Domain/Models/PrivacySettingsKey.swift`:

```swift
import Foundation

/// `@AppStorage` / `UserDefaults` keys for privacy-related preferences that persist across sessions.
public enum PrivacySettingsKey {
    /// Bool. Whether Crashlytics crash-data collection is enabled. Opt-out semantics: absent (first launch) is treated
    /// as `true`. Do not rename — the raw string is persisted user state.
    public static let crashReportingEnabled = "privacyCrashReportingEnabled"
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd Packages/Domain && swift test --filter PrivacySettingsKeyTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/Domain/Sources/Domain/Models/PrivacySettingsKey.swift Packages/Domain/Tests/DomainTests/Models/PrivacySettingsKeyTests.swift
git commit -m "Add PrivacySettingsKey.crashReportingEnabled to Domain"
```

---

## Task 3: `CrashReporting` product in Infrastructure

No unit test: `FirebaseCrashReporter` is a thin pass-through to a third-party singleton and is not meaningfully testable without the SDK. Verification is "the package builds and the target links Firebase."

**Files:**
- Create: `Packages/Infrastructure/Sources/CrashReporting/FirebaseCrashReporter.swift`
- Modify: `Packages/Infrastructure/Package.swift`

- [ ] **Step 1: Add the firebase dependency and new target to `Package.swift`**

In `Packages/Infrastructure/Package.swift`:

Add to `products` (after the `ScoreFiles` library):

```swift
        .library(name: "CrashReporting", targets: ["CrashReporting"]),
```

Add to `dependencies` (after the `../Domain` package line):

```swift
        .package(path: "../Utility"),
        .package(url: "https://github.com/firebase/firebase-ios-sdk", from: "11.0.0"),
```

Add to `targets` (before the `InfrastructureTests` test target):

```swift
        .target(
            name: "CrashReporting",
            dependencies: [
                .product(name: "UtilityCore", package: "Utility"),
                .product(name: "FirebaseCrashlytics", package: "firebase-ios-sdk"),
            ],
            plugins: swiftLintPlugins,
        ),
```

> **iOS 26 / Swift 6.3 compatibility note:** `from: "11.0.0"` resolves to the newest 11.x. If `swift build` or the app build fails to resolve or compile against iOS 26 / Swift 6.3, bump the requirement to the latest major (e.g. `from: "12.0.0"`) and keep `project.yml` identical (Task 4).

- [ ] **Step 2: Write the adapter**

Create `Packages/Infrastructure/Sources/CrashReporting/FirebaseCrashReporter.swift`:

```swift
import FirebaseCore
import FirebaseCrashlytics
import Foundation
import UtilityCore

/// `CrashReporter` backed by Firebase Crashlytics. The only place in folino that imports the Firebase SDK besides the
/// composition root that calls `configure`.
public struct FirebaseCrashReporter: CrashReporter {
    public init() {}

    /// Configures `FirebaseApp` exactly once and applies the stored collection preference. Call from the composition
    /// root early in launch.
    ///
    /// `FirebaseApp.configure()` reads `GoogleService-Info.plist` from the app bundle and must run on the main thread.
    @MainActor
    public static func configure(collectionEnabled: Bool) -> FirebaseCrashReporter {
        FirebaseApp.configure()
        let reporter = FirebaseCrashReporter()
        reporter.setCollectionEnabled(collectionEnabled)
        return reporter
    }

    public func setCollectionEnabled(_ enabled: Bool) {
        Crashlytics.crashlytics().setCrashlyticsCollectionEnabled(enabled)
    }

    public func log(_ message: String) {
        Crashlytics.crashlytics().log(message)
    }

    public func record(error: Error) {
        Crashlytics.crashlytics().record(error: error)
    }
}
```

- [ ] **Step 3: Build the package**

Run: `cd Packages/Infrastructure && swift build`
Expected: Build succeeds; Firebase resolves and `CrashReporting` compiles. (First resolve is slow — Firebase is large.)

- [ ] **Step 4: Commit**

```bash
git add Packages/Infrastructure/Package.swift Packages/Infrastructure/Sources/CrashReporting/FirebaseCrashReporter.swift
git commit -m "Add CrashReporting product with FirebaseCrashReporter adapter"
```

---

## Task 4: Wire the dependency and dSYM upload into `project.yml`

**Files:**
- Modify: `project.yml`

- [ ] **Step 1: Add the firebase package under `packages:`**

In `project.yml`, in the `packages:` block (after the `Yams` entry), add:

```yaml
  firebase-ios-sdk:
    url: https://github.com/firebase/firebase-ios-sdk
    from: 11.0.0
```

> Keep this `from:` value identical to `Package.swift` (Task 3). If you bumped the major there, bump it here too.

- [ ] **Step 2: Add `CrashReporting` to the Folino target's Infrastructure products**

In `project.yml`, under `targets: > Folino: > dependencies:`, change the Infrastructure entry from:

```yaml
      - package: Infrastructure
        products: [Persistence, CloudSync, Soundfonts, Audio, ScoreFiles]
```

to:

```yaml
      - package: Infrastructure
        products: [Persistence, CloudSync, Soundfonts, Audio, ScoreFiles, CrashReporting]
```

(`firebase-ios-sdk` links transitively through `CrashReporting`; the App target does not declare it directly.)

- [ ] **Step 3: Add the Release dSYM setting and the upload-symbols build script**

In `project.yml`, under `targets: > Folino: > settings:`, the current block is:

```yaml
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.KeyNumber.Folino
        ...
        GENERATE_INFOPLIST_FILE: NO
```

Add a config-specific `configs:` block alongside `base:` so Release produces dSYMs (required for symbolication):

```yaml
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.KeyNumber.Folino
        PRODUCT_NAME: folino
        INFOPLIST_FILE: App/Info.plist
        CODE_SIGN_ENTITLEMENTS: App/Folino.entitlements
        TARGETED_DEVICE_FAMILY: 1,2
        ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon
        ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME: AccentColor
        SUPPORTS_MACCATALYST: NO
        GENERATE_INFOPLIST_FILE: NO
      configs:
        Release:
          DEBUG_INFORMATION_FORMAT: dwarf-with-dsym
```

Then add a `postBuildScripts:` key to the Folino target (sibling of `sources:`, `settings:`, `dependencies:`):

```yaml
    postBuildScripts:
      - name: "Firebase Crashlytics Upload Symbols"
        script: '"${BUILD_DIR%/Build/*}/SourcePackages/checkouts/firebase-ios-sdk/Crashlytics/run"'
        inputFiles:
          - "${DWARF_DSYM_FOLDER_PATH}/${DWARF_DSYM_FILE_NAME}/Contents/Resources/DWARF/${TARGET_NAME}"
          - "$(SRCROOT)/$(BUILT_PRODUCTS_DIR)/$(INFOPLIST_PATH)"
```

- [ ] **Step 4: Regenerate the project**

Run: `xcodegen generate`
Expected: `Folino.xcodeproj` regenerates with no errors. (Build verification happens in Task 7 after `GoogleService-Info.plist` exists; building now would crash at launch on a missing config.)

- [ ] **Step 5: Commit**

```bash
git add project.yml
git commit -m "Wire firebase-ios-sdk, CrashReporting, and dSYM upload into project.yml"
```

---

## Task 5: Firebase console setup (Firebase MCP) — INTERACTIVE CHECKPOINT

This task uses the Firebase MCP tools and **requires the user to complete `firebase_login` in a browser**. Pause and coordinate with the user before running.

**Files:**
- Create: `App/GoogleService-Info.plist` (committed)

- [ ] **Step 1: Authenticate**

Call `mcp__firebase__firebase_login`. The user completes the browser sign-in and accepts Firebase Terms of Service for their Google account if prompted.

- [ ] **Step 2: Create (or select) the Firebase project**

Call `mcp__firebase__firebase_create_project` (e.g. display name "folino"). If the user already has a project, call `mcp__firebase__firebase_list_projects` and use that project id instead.

- [ ] **Step 3: Register the iOS app**

Call `mcp__firebase__firebase_create_app` with platform iOS and bundle id `com.KeyNumber.Folino`.

- [ ] **Step 4: Fetch the config and write the plist**

Call `mcp__firebase__firebase_get_sdk_config` for the iOS app, then write the returned plist contents to `App/GoogleService-Info.plist`.

- [ ] **Step 5: Verify the plist is valid XML and has the expected keys**

Run: `plutil -lint App/GoogleService-Info.plist`
Expected: `App/GoogleService-Info.plist: OK`. Confirm it contains `BUNDLE_ID = com.KeyNumber.Folino`, `GOOGLE_APP_ID`, and `API_KEY`.

- [ ] **Step 6: Commit**

```bash
git add App/GoogleService-Info.plist
git commit -m "Add Firebase GoogleService-Info.plist for com.KeyNumber.Folino"
```

---

## Task 6: Info.plist collection default + privacy manifest

**Files:**
- Modify: `App/Info.plist`
- Create: `App/PrivacyInfo.xcprivacy`

- [ ] **Step 1: Disable auto-collection in Info.plist**

In `App/Info.plist`, inside the top-level `<dict>`, add (alphabetical order near other keys is fine):

```xml
	<key>FirebaseCrashlyticsCollectionEnabled</key>
	<false/>
```

This makes the stored UserDefaults preference (applied at launch in Task 7) the single source of truth, rather than the SDK auto-collecting before the preference is read.

- [ ] **Step 2: Add the app-level privacy manifest**

Create `App/PrivacyInfo.xcprivacy`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>NSPrivacyTracking</key>
	<false/>
	<key>NSPrivacyTrackingDomains</key>
	<array/>
	<key>NSPrivacyCollectedDataTypes</key>
	<array>
		<dict>
			<key>NSPrivacyCollectedDataType</key>
			<string>NSPrivacyCollectedDataTypeCrashData</string>
			<key>NSPrivacyCollectedDataTypeLinked</key>
			<false/>
			<key>NSPrivacyCollectedDataTypeTracking</key>
			<false/>
			<key>NSPrivacyCollectedDataTypePurposes</key>
			<array>
				<string>NSPrivacyCollectedDataTypePurposeAppFunctionality</string>
			</array>
		</dict>
	</array>
	<key>NSPrivacyAccessedAPITypes</key>
	<array/>
</dict>
</plist>
```

- [ ] **Step 3: Validate both plists**

Run: `plutil -lint App/Info.plist App/PrivacyInfo.xcprivacy`
Expected: both report `OK`.

- [ ] **Step 4: Regenerate and confirm the manifest is bundled**

Run: `xcodegen generate`
Expected: succeeds. `App/PrivacyInfo.xcprivacy` and `App/GoogleService-Info.plist` are inside the `App` source path (not in the `excludes:` list), so xcodegen adds them to the Folino resources copy phase.

- [ ] **Step 5: Commit**

```bash
git add App/Info.plist App/PrivacyInfo.xcprivacy
git commit -m "Disable Crashlytics auto-collection and add app privacy manifest"
```

---

## Task 7: Configure Crashlytics in `AppBootstrap` and build the app

**Files:**
- Modify: `App/AppBootstrap.swift`

- [ ] **Step 1: Import CrashReporting and add the reporter property**

In `App/AppBootstrap.swift`, add to the imports (alphabetical):

```swift
import CrashReporting
```

(`Domain` and `UtilityCore` are already imported.)

Add a stored property alongside the other `private(set) var` service slots (after `incomingShareCoordinator`):

```swift
    private(set) var crashReporter: (any CrashReporter)?
```

- [ ] **Step 2: Configure at the top of `start()`**

In `App/AppBootstrap.swift`, `start()` currently begins:

```swift
    func start() {
        do {
            try prepareDirectories()
```

Insert the configure call as the first lines of `start()`, before the `do {`:

```swift
    func start() {
        let crashEnabled = UserDefaults.standard.object(forKey: PrivacySettingsKey.crashReportingEnabled) as? Bool ?? true
        crashReporter = FirebaseCrashReporter.configure(collectionEnabled: crashEnabled)
        do {
            try prepareDirectories()
```

(Opt-out default: absent key → `true`. `start()` is `@MainActor`, satisfying `configure`'s main-thread requirement.)

- [ ] **Step 3: Build the app**

Run:
```bash
xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 16' -skipPackagePluginValidation build
```
Expected: build succeeds, Firebase links, app compiles. (If the Crashlytics upload script errors under script sandboxing during this Debug build, see the fallback in Task 10's verification notes.)

- [ ] **Step 4: Commit**

```bash
git add App/AppBootstrap.swift
git commit -m "Configure Crashlytics from AppBootstrap with opt-out default"
```

---

## Task 8: Settings opt-out toggle

**Files:**
- Modify: `Packages/Features/Settings/Sources/Settings/Screens/SettingsSheet.swift`
- Modify: `Packages/Features/Settings/Sources/Settings/Resources/Localizable.xcstrings`
- Modify: `Packages/Features/Settings/Tests/SettingsTests/SettingsSheetTests.swift`

`Packages/Features/Settings/Package.swift` already depends on `UtilityCore` and `Domain` — no manifest change needed. Verify with `grep UtilityCore Packages/Features/Settings/Package.swift`.

- [ ] **Step 1: Write the failing test (Spy reporter + construction)**

In `Packages/Features/Settings/Tests/SettingsTests/SettingsSheetTests.swift`, add an `import UtilityCore` at the top, then add a spy and a test:

```swift
@MainActor
final class SpyCrashReporter: CrashReporter {
    nonisolated(unsafe) var collectionEnabledCalls: [Bool] = []
    nonisolated func setCollectionEnabled(_ enabled: Bool) { collectionEnabledCalls.append(enabled) }
    nonisolated func log(_: String) {}
    nonisolated func record(error _: Error) {}
}

extension SettingsSheetTests {
    @Test func `sheet constructs with an injected crash reporter`() {
        let sheet = SettingsSheet(crashReporter: SpyCrashReporter()) { Text("License placeholder") }
        _ = sheet.body
    }
}
```

> The toggle's runtime `onChange → setCollectionEnabled` effect is verified end-to-end in Task 10 (a SwiftUI `@AppStorage` `onChange` cannot be triggered from a value-level unit test). This test pins the new `init` parameter and the `CrashReporter` injection seam.

- [ ] **Step 2: Run test to verify it fails**

Run: `cd Packages/Features/Settings && swift test --filter SettingsSheetTests`
Expected: FAIL — `SettingsSheet` has no `crashReporter:` parameter / `CrashReporter` not found.

- [ ] **Step 3: Add the injected reporter and Privacy section to `SettingsSheet`**

In `SettingsSheet.swift`, add `import UtilityCore` to the imports.

Add a stored property near `licenseContent`:

```swift
    private let crashReporter: any CrashReporter
```

Add the `@AppStorage` binding alongside the other `@AppStorage` properties:

```swift
    @AppStorage(PrivacySettingsKey.crashReportingEnabled)
    private var isCrashReportingEnabled = true
```

Update `init` to accept the reporter (defaulted so previews and the existing first `#Preview` keep compiling):

```swift
    public init(
        provider: (any MuseScoreGeneralProvider)? = nil,
        versionHistoryLoader: any VersionHistoryLoader = DefaultVersionHistoryLoader(),
        onVersionHistoryViewed: @escaping @MainActor () -> Void = {},
        crashReporter: any CrashReporter = NoopCrashReporter(),
        @ViewBuilder licenseContent: @escaping () -> LicenseContent,
    ) {
        self.provider = provider
        self.versionHistoryLoader = versionHistoryLoader
        self.onVersionHistoryViewed = onVersionHistoryViewed
        self.crashReporter = crashReporter
        self.licenseContent = licenseContent
    }
```

Add `privacySection` to the `Form` in `body`, between `readerSection` and `aboutSection`:

```swift
            Form {
                readerSection
                privacySection
                aboutSection
            }
```

Add the section definition (e.g. after `readerSection`'s computed property):

```swift
    private var privacySection: some View {
        Section {
            Toggle(isOn: $isCrashReportingEnabled) {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("settings.privacy.crashReporting.title", bundle: .module)
                        Text("settings.privacy.crashReporting.footer", bundle: .module)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "ladybug")
                }
            }
            .onChange(of: isCrashReportingEnabled) { _, newValue in
                crashReporter.setCollectionEnabled(newValue)
            }
        } header: {
            Text("settings.privacy.title", bundle: .module)
        }
    }
```

- [ ] **Step 4: Add localization keys (all 5 locales)**

In `Packages/Features/Settings/Sources/Settings/Resources/Localizable.xcstrings`, add three entries to the `"strings"` object (match the existing entry shape — `localizations` with `en`, `ja`, `ko`, `zh-Hans`, `zh-Hant`, each `stringUnit` with `state: "translated"`):

- `settings.privacy.title`: en `Privacy`, ja `プライバシー`, ko `개인정보 보호`, zh-Hans `隐私`, zh-Hant `隱私`
- `settings.privacy.crashReporting.title`: en `Send crash reports`, ja `クラッシュレポートを送信`, ko `오류 보고서 전송`, zh-Hans `发送崩溃报告`, zh-Hant `傳送當機報告`
- `settings.privacy.crashReporting.footer`: en `Helps fix bugs by sharing anonymous crash diagnostics. Never linked to you.`, ja `匿名のクラッシュ診断を共有して不具合の修正に役立てます。個人とは結び付けられません。`, ko `익명 오류 진단을 공유해 버그 수정에 도움을 줍니다. 사용자와 연결되지 않습니다.`, zh-Hans `共享匿名崩溃诊断信息以帮助修复缺陷。绝不与您关联。`, zh-Hant `分享匿名當機診斷以協助修正錯誤。絕不與您關聯。`

- [ ] **Step 5: Run the test to verify it passes**

Run: `cd Packages/Features/Settings && swift test --filter SettingsSheetTests`
Expected: PASS (all three tests in the suite).

- [ ] **Step 6: Commit**

```bash
git add Packages/Features/Settings/Sources/Settings/Screens/SettingsSheet.swift Packages/Features/Settings/Sources/Settings/Resources/Localizable.xcstrings Packages/Features/Settings/Tests/SettingsTests/SettingsSheetTests.swift
git commit -m "Add crash-reporting opt-out toggle to Settings"
```

---

## Task 9: Inject the live reporter at the `SettingsSheet` call site

**Files:**
- Modify: `App/AppShellView.swift`

- [ ] **Step 1: Pass `bootstrap.crashReporter` into `SettingsSheet`**

In `App/AppShellView.swift`, the `SettingsSheet(...)` call (around line 210) currently reads:

```swift
            SettingsSheet(
                provider: bootstrap.museScoreGeneralProvider,
                onVersionHistoryViewed: { versionHistoryPresenter.markCurrentVersionAsSeen() },
            ) {
                LicenseListView()
            }
```

Change it to inject the configured reporter (fall back to `NoopCrashReporter` if bootstrap has not configured one yet):

```swift
            SettingsSheet(
                provider: bootstrap.museScoreGeneralProvider,
                onVersionHistoryViewed: { versionHistoryPresenter.markCurrentVersionAsSeen() },
                crashReporter: bootstrap.crashReporter ?? NoopCrashReporter(),
            ) {
                LicenseListView()
            }
```

Add `import UtilityCore` to `App/AppShellView.swift` if `NoopCrashReporter` is otherwise unresolved (it already imports `UtilityUI`; add `UtilityCore`).

- [ ] **Step 2: Build the app**

Run:
```bash
xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 16' -skipPackagePluginValidation build
```
Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
git add App/AppShellView.swift
git commit -m "Inject live crash reporter into Settings sheet"
```

---

## Task 10: Document the opt-out and verify end to end

**Files:**
- Modify: `docs/product/privacy-and-accessibility.md`

- [ ] **Step 1: Document the behavior**

In `docs/product/privacy-and-accessibility.md`, add a short subsection describing crash reporting: folino uses Firebase Crashlytics to collect anonymous crash diagnostics for bug fixing; it is on by default, never linked to user identity, never used for tracking, and can be turned off under Settings → Privacy → "Send crash reports".

- [ ] **Step 2: Commit the doc**

```bash
git add docs/product/privacy-and-accessibility.md
git commit -m "Document crash-reporting opt-out in privacy docs"
```

- [ ] **Step 3: End-to-end crash pipeline verification (manual, with the user)**

This must use a real device or simulator build that has run once, relaunched, and uploaded the dSYM. Hand control to the user for the crash gesture per the project's iOS workflow.

1. Build & run on the simulator (DEBUG `.debuggable()` toolbar is available).
2. Open the ladybug debug sheet → tap **fatalError** (existing `App/DebugView.swift` button) to crash.
3. Relaunch the app (Crashlytics uploads the prior crash on next launch).
4. Confirm the crash appears, symbolicated, in the Firebase console Crashlytics dashboard.
5. In Settings → Privacy, toggle "Send crash reports" off, crash again, relaunch, and confirm no new report is uploaded.

> **Sandboxing fallback:** if the "Firebase Crashlytics Upload Symbols" run script fails at build time due to `ENABLE_USER_SCRIPT_SANDBOXING = YES`, add `ENABLE_USER_SCRIPT_SANDBOXING: NO` under the Folino target's `settings: base:` in `project.yml`, `xcodegen generate`, and rebuild. Commit that change if needed.

- [ ] **Step 4: App Store Connect privacy label (manual, user — release-time)**

Before the next App Store submission, the user updates the privacy nutrition label in App Store Connect to declare **Crash Data / Diagnostics** collection: not linked to identity, not used for tracking. No code change.

---

## Self-Review Notes

- **Spec coverage:** protocol (T1), Domain key (T2), Infra adapter (T3), dependency + dSYM + Release dSYM (T4), console/plist (T5), Info.plist collection-off + privacy manifest (T6), launch configure with opt-out default (T7), Settings toggle + localization (T8), live injection (T9), product docs + E2E + ASC label + sandboxing fallback (T10). All spec sections mapped.
- **Type consistency:** `CrashReporter` methods `setCollectionEnabled(_:)`, `log(_:)`, `record(error:)` are used identically in T1, T3, T8, T9. `FirebaseCrashReporter.configure(collectionEnabled:)` defined T3, called T7. `PrivacySettingsKey.crashReportingEnabled` defined T2, used T7 and T8. `AppBootstrap.crashReporter` defined T7, read T9.
- **Out of scope kept out:** no Analytics, no Share Extension reporting, no `record(error:)` call sites beyond the protocol surface, no `setUserID`.
