# Firebase Crashlytics Integration — Design

**Date:** 2026-05-27
**Status:** Approved for planning

## Goal

Add crash reporting to folino via Firebase Crashlytics, with a user-facing opt-out
in Settings (default on). Keep the third-party SDK behind folino's layered-module
boundary so Features stay testable and Firebase imports stay localized.

## Scope decisions (confirmed with user)

- **Crashlytics only** — `FirebaseCore` + `FirebaseCrashlytics`. No Analytics, no
  breadcrumbs, no crash-free-users metric. Minimal dependency and privacy footprint.
- **Opt-out consent** — collection defaults to on; a Settings toggle lets the user
  turn it off. The stored preference is authoritative over the Info.plist default.
- **`GoogleService-Info.plist` is committed** to the repo (it is project config, not
  a secret).
- **New Firebase project**, created via the Firebase MCP tooling.

## Out of scope (YAGNI)

- Firebase Analytics and breadcrumbs.
- Crash reporting in the `FolinoShareExtension` target (app target only for v1).
- Sprinkling `record(error:)` / `log(_:)` calls across existing catch sites. The
  protocol exposes them, but v1 only wires `configure()`, the collection toggle, and
  a debug test-crash trigger.
- `setUserID` / any user-identifying crash metadata (privacy).

## Architecture

Placement follows the documented ambient-service pattern (`Logger`, `Clock` live as
small Utility-layer protocols) — **chosen as approach A over an App-only integration
or a Domain-level protocol**.

```
UtilityCore         protocol CrashReporter (+ NoopCrashReporter)
   ▲        ▲
   │        └──────────────── Settings (SettingsSheet takes any CrashReporter)
   │
Infrastructure/CrashReporting   FirebaseCrashReporter: CrashReporter
   │                            (wraps FirebaseCrashlytics; owns configure())
   ▲
  App  ── FolinoApp.init() calls FirebaseCrashReporter.configure(),
          injects the reporter through AppBootstrap into SettingsSheet
```

Firebase imports are confined to `Infrastructure/CrashReporting`. `App` imports only
`CrashReporting` and `UtilityCore`; it does **not** import `firebase-ios-sdk`
directly.

### `UtilityCore` — the protocol

```swift
public protocol CrashReporter: Sendable {
    /// Enable/disable crash data collection. Persisted by the implementation across launches.
    func setCollectionEnabled(_ enabled: Bool)
    func log(_ message: String)
    func record(error: Error)
}

public struct NoopCrashReporter: CrashReporter {
    public init() {}
    public func setCollectionEnabled(_ enabled: Bool) {}
    public func log(_ message: String) {}
    public func record(error: Error) {}
}
```

`NoopCrashReporter` is the default for SwiftUI previews and feature tests.

### `Infrastructure/CrashReporting` — the Firebase adapter

New product/target in `Packages/Infrastructure`:

```swift
import FirebaseCore
import FirebaseCrashlytics
import UtilityCore

public struct FirebaseCrashReporter: CrashReporter {
    /// Configures FirebaseApp and applies the stored collection preference.
    /// Called once, early, from the composition root.
    public static func configure(collectionEnabled: Bool) -> FirebaseCrashReporter {
        FirebaseApp.configure()
        let reporter = FirebaseCrashReporter()
        reporter.setCollectionEnabled(collectionEnabled)
        return reporter
    }
    public func setCollectionEnabled(_ enabled: Bool) {
        Crashlytics.crashlytics().setCrashlyticsCollectionEnabled(enabled)
    }
    public func log(_ message: String) { Crashlytics.crashlytics().log(message) }
    public func record(error: Error) { Crashlytics.crashlytics().record(error: error) }
}
```

Depends on `FirebaseCrashlytics` (pulls `FirebaseCore` transitively) and `UtilityCore`.
Infrastructure gains a dependency on `../Utility` — allowed, since Utility is reachable
from any layer.

### Collection-enabled control flow

- **Info.plist:** `FirebaseCrashlyticsCollectionEnabled = NO`. This prevents auto-
  collection before our stored preference is applied, making the stored preference the
  single source of truth.
- **Stored preference:** a UserDefaults key, default `true` (opt-out semantics). The key
  constant lives in **Domain**, alongside the existing `ReaderGlobalSettingsKey`
  (`Packages/Domain/Sources/Domain/Models/ReaderLayoutMode.swift`), e.g. a new
  `PrivacySettingsKey.crashReportingEnabled`.
- **At launch:** `FolinoApp.init()` reads the stored value and calls
  `FirebaseCrashReporter.configure(collectionEnabled:)`, which applies it via
  `setCrashlyticsCollectionEnabled`.
- **On toggle change:** the Settings toggle persists the new value to UserDefaults and
  calls `reporter.setCollectionEnabled(newValue)`.

## Settings opt-out toggle

`SettingsSheet` currently has no view model; its toggles use `@AppStorage` bound
directly to UserDefaults. The crash-reporting toggle follows the same pattern:

- Add a new **Privacy** `Section` with a single toggle "Send crash reports".
- `@AppStorage(PrivacySettingsKey.crashReportingEnabled)` (default `true`) +
  `.onChange(of:)` calls `crashReporter.setCollectionEnabled(newValue)`.
- `SettingsSheet.init` gains `crashReporter: any CrashReporter = NoopCrashReporter()`
  so previews and existing call sites keep working; `App` passes the real reporter.

### Localization

New keys in the Settings module xcstrings, following the `module.feature.thing`
scheme:

- `settings.privacy.title` — section header
- `settings.privacy.crashReporting.title` — toggle label
- `settings.privacy.crashReporting.footer` — short explanation

Provide `en` and `ja` values; `zh-Hans`, `zh-Hant`, `ko` fall back to English and are
filled in as part of the ongoing Settings localization pass.

### Product docs

Document the opt-out behavior in `docs/product/privacy-and-accessibility.md` (crash
data is collected by default for diagnostics, user can disable it in Settings, never
linked to identity, never used for tracking).

## Build configuration (xcodegen / project.yml)

### Dependency wiring (both files, same version)

- `project.yml` `packages:` — add:
  ```yaml
  firebase-ios-sdk:
    url: https://github.com/firebase/firebase-ios-sdk
    from: <latest 11.x, pinned to the resolved version>
  ```
- `project.yml` Folino target — add `CrashReporting` to the `Infrastructure` products
  list. App does **not** add `firebase-ios-sdk` directly.
- `Packages/Infrastructure/Package.swift` — add the `firebase-ios-sdk` package and
  `../Utility`; define a new `CrashReporting` library target depending on
  `.product(name: "FirebaseCrashlytics", package: "firebase-ios-sdk")` and
  `UtilityCore`; export it as a product.
- Keep the `from:` version identical in `project.yml` and `Package.swift`.

### dSYM upload build phase

Add a `postBuildScripts` entry to the Folino target so symbols upload after the dSYM
is produced:

```yaml
postBuildScripts:
  - name: "Firebase Crashlytics Upload Symbols"
    script: '"${BUILD_DIR%/Build/*}/SourcePackages/checkouts/firebase-ios-sdk/Crashlytics/run"'
    inputFiles:
      - "${DWARF_DSYM_FOLDER_PATH}/${DWARF_DSYM_FILE_NAME}/Contents/Resources/DWARF/${TARGET_NAME}"
      - "$(SRCROOT)/$(BUILT_PRODUCTS_DIR)/$(INFOPLIST_PATH)"
```

- Ensure Release produces dSYMs: `DEBUG_INFORMATION_FORMAT = dwarf-with-dsym` for the
  Release config (set in `project.yml` config-specific settings or the xcconfig).
- **Sandboxing gotcha:** the project sets `ENABLE_USER_SCRIPT_SANDBOXING = YES`. The
  declared `inputFiles` are expected to satisfy the sandbox, but if symbol upload fails
  at build time, the fallback is to set `ENABLE_USER_SCRIPT_SANDBOXING = NO` on the
  Folino target only. The plan must verify a real Release/Archive build runs the script.

### GoogleService-Info.plist

Place the MCP-fetched plist at `App/GoogleService-Info.plist` and commit it. It is
already inside the `App` source path, so xcodegen bundles it as a resource — verify it
lands in the app bundle (the Crashlytics run script reads it via `$(INFOPLIST_PATH)`'s
sibling resources).

## Privacy manifest & App Store

- Add an app-level `App/PrivacyInfo.xcprivacy` declaring `NSPrivacyCollectedDataTypes`
  → **Crash Data** with `linked = NO`, `tracking = NO`, purpose **App Functionality**.
  (The Firebase SDK ships its own privacy manifest for SDK-level API usage.)
- **Manual (user) step:** in App Store Connect, update the privacy nutrition label to
  declare Crash Data / Diagnostics collection (not linked, not tracking).

## Test-crash trigger

Add a DEBUG-only "Force crash" control to the existing `App/DebugView.swift` to
validate the pipeline end to end (crash → symbolicated report in console).

## Testing

- `SettingsTests` (Swift Testing): a fake `CrashReporter` records calls; assert the
  toggle's `onChange` path calls `setCollectionEnabled` with the new value.
- Previews and feature tests use `NoopCrashReporter`. No real Firebase in any test.
- No Infrastructure unit test for `FirebaseCrashReporter` itself (it is a thin pass-
  through to a third-party singleton; not meaningfully testable without the SDK).

## Firebase Console / external setup

### Automated via Firebase MCP (I perform)

1. `firebase_login` — requires interactive browser auth; user completes the sign-in.
2. `firebase_create_project` — create the folino project.
3. `firebase_create_app` — register an iOS app with bundle id `com.KeyNumber.Folino`.
4. `firebase_get_sdk_config` — fetch and write `App/GoogleService-Info.plist`.

### Manual (user performs)

- Open the Crashlytics dashboard in the Firebase console and confirm the first crash
  report is received (run a build, hit the DEBUG force-crash, relaunch).
- App Store Connect: declare Crash Data in the privacy nutrition label.
- Accept Firebase Terms of Service for the Google account if prompted.

## Risks / open items

- **Script sandboxing** may block the upload script (see fallback above) — verify with
  a real Release/Archive build, not just a simulator Debug build.
- **Firebase SDK size / build time** increases; acceptable for crash visibility.
- **iOS 26 / Swift 6.3 compatibility** of the chosen `firebase-ios-sdk` 11.x release —
  confirm it resolves and builds during implementation; bump the pin if needed.
