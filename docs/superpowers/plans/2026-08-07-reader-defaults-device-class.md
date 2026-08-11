# Device-class Reader Defaults Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Resolve an untouched per-score staff size and break policy against the device class instead of a single constant, and close the two reset affordances that still persist an explicit default on Android.

**Architecture:** `ReaderPreferences` already models "untouched" as `nil` and resolves `staffSize` against a caller-supplied default. This plan gives `honorLayoutBreaks` the same shape, deletes the static Domain default so nothing can resolve against it by accident, and has each platform's composition root supply its own numbers from the device idiom. The Android JNI bridge keeps projecting resolved scalars to Compose, so Kotlin still never sees an Optional.

**Tech Stack:** Swift 6.3 / SwiftUI (iOS), Kotlin / Jetpack Compose + swift-wirelet JNI (Android), Swift Testing, JUnit 4, GRDB (iOS persistence), Room + JSON blob (Android persistence).

**Spec:** `docs/superpowers/specs/2026-08-06-reader-defaults-device-class-design.md`

## Global Constraints

- **Values, verbatim.** iOS `staffSize`: phone **12**, tablet **14**. Android `staffSize`: phone **21**, tablet **24**. `honorLayoutBreaks`: phone **false**, tablet **true**, both platforms.
- **Device class is fixed per device, never per window.** iOS: `UIDevice.current.userInterfaceIdiom == .pad`. Android: `Configuration.smallestScreenWidthDp >= 600`. Do not use `horizontalSizeClass`, `screenWidthDp`, or any live window measurement.
- **Frozen constants — do not touch.** `ReaderPreferences.LegacyStoredDefaults` (`staffSize: 14`, `honorLayoutBreaks: true`, `masterVolume: 1`, `transposeSemitones: 0`) and the v16 SQL literals in `Migrations+V16.swift` (`CASE WHEN staff_size = 14`, `CASE WHEN honor_layout_breaks = 1`). They describe data as it was written.
- **Comment style:** reflow `//` and `///` paragraphs at 120 columns, not 80.
- **Spelling:** American English, except identifiers mirroring Apple API spellings.
- **Staging:** never `git add -p` / hunk-level staging. Stage whole files (the pre-commit hook rewrites files in place).
- **iOS package tests** run from the package directory:
  `xcodebuild test -scheme <Scheme> -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation`
  Schemes: `Domain` (Packages/Domain), `Reader` (Packages/Features/Reader), `Infrastructure-Package` (Packages/Infrastructure). `swift test` does not work in this repo.
- **The Android JNI Swift tests** are a separate, host-built target that only exists under `FOLINO_ANDROID=1`. Run from `Packages/Features/Library`:
  `FOLINO_ANDROID=1 xcrun swift test`
  **Afterwards always run** `chmod -R u+w Packages/Features/Library/.build/checkouts/swift-wirelet` — the test run leaves that checkout read-only and the next Gradle wirelet codegen dies on it.
- **Android build ordering is load-bearing:** Gradle wirelet codegen first, then the `.so`, then `assembleDebug`. Building the `.so` first in a fresh worktree yields a library with no `JNI_OnLoad` that crashes at the first native call.
- **Android cross-compile toolchain:** prefix `PATH="/Library/Developer/Toolchains/swift-6.3.3-RELEASE.xctoolchain/usr/bin:$PATH"`. The Xcode-bundled Swift is incompatible with the prebuilt Android SDK.
- **Work in the worktree** `/Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/reader-defaults-device-class` on branch `worktree-reader-defaults-device-class`. Use `git -C <worktree>` or absolute paths; never `cd` into the primary checkout.
- **One command per Bash call.** No `&&` / `;` chaining, no `cd X && y`.

---

## File Structure

**Created**

| File | Responsibility |
|---|---|
| `Packages/Features/Reader/Sources/Reader/ReaderDeviceDefaults.swift` | iOS device-class → (`staffSize`, `honorLayoutBreaks`). Screen-level concern, so it sits beside `ReaderRootScreen`, not in Domain. |
| `Packages/Features/Reader/Tests/ReaderTests/ReaderDeviceDefaultsTests.swift` | Pins both pairs and that the idiom rule is the only input. |
| `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderDeviceDefaults.kt` | Android device-class → (`staffSize`, `honorLayoutBreaks`). Pure `Int`-taking functions plus thin `Context` overloads. |
| `Android/FolinoReaderAndroid/src/test/kotlin/com/keynumber/folino/reader/ReaderDeviceDefaultsTest.kt` | JVM unit test over the pure functions, including the 599/600 dp boundary. |

**Modified**

| File | Change |
|---|---|
| `Packages/Domain/Sources/Domain/Models/ReaderPreferences.swift` | Delete `defaultHonorLayoutBreaks`; `effectiveHonorLayoutBreaks` becomes `effectiveHonorLayoutBreaks(default:)`. |
| `Packages/Features/Reader/Sources/Reader/LayoutSettingsModel.swift` | New injected `defaultHonorLayoutBreaks`; resolve against it. |
| `Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift` | New `defaultHonorLayoutBreaks` init param + stored property; wire into `layoutModel`. |
| `Packages/Features/Reader/Sources/Reader/Screens/ReaderRootScreen.swift` | Seed both defaults from `ReaderDeviceDefaults`; retire the `// TBD` placeholder. |
| `Packages/Features/Library/Sources/FolinoLibraryJNI/ReaderPreferencesReducer.swift` | Tempo snap-to-untouched; `clearStaffSize`; frozen legacy staff-size seed; merge the two `decode` overloads. |
| `Packages/Features/Library/Sources/FolinoLibraryJNI/ReaderPreferencesBridge.swift` | `open` takes `defaultHonorLayoutBreaks`; new `clearStaffSize()` verb; `republish` resolves both. |
| `Packages/Features/Library/Sources/FolinoLibraryJNI/AnalyticsBridge.swift` | Drop the dead `defaultStaffSize` parameter; correct the doc's false premise about a user-movable global. |
| `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/DisplayInspectorSheet.kt` | `StaffSizeRow` takes the device default and a dedicated reset callback. |
| `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/LayoutOptions.kt` | Re-document `DEFAULT` as a render placeholder, not the preference default. |
| `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderViewModel.kt` | Seed `_layoutOptions` from the device default. |
| `Android/app/src/main/kotlin/com/keynumber/folino/ui/settings/SettingsPrefs.kt` | Device-derived `staffSize` fallback; delete the dead `honorBreaks` key + setter. |
| `Android/app/src/main/kotlin/com/keynumber/folino/MainActivity.kt` | Device-derived `collectAsState` initial; pass `defaultHonorLayoutBreaks` to `open`; wire the staff-size reset; drop the dead analytics argument. |

Tests updated alongside: `ReaderPreferencesUntouchedTests`, `ScorePrefsEventTests`, `ReaderPreferencesRecordTests`, `ReaderPreferencesBridgeTests`, `ReaderPreferencesReducerTests`, `ReaderViewModelTests`, `ReaderUntouchedPreferencesTests` (iOS `Reader`).

---

## Task 1: Domain — make `honorLayoutBreaks` caller-resolved

Everything that reads the break policy switches to an injected default in one commit, so the build never breaks. The injected value is still the literal `true` everywhere; Tasks 2 and 4 replace it with the real device default.

**Files:**
- Modify: `Packages/Domain/Sources/Domain/Models/ReaderPreferences.swift:29`, `:78-79`, `:149-151`
- Modify: `Packages/Domain/Tests/DomainTests/Models/ReaderPreferencesUntouchedTests.swift:49-54`
- Modify: `Packages/Domain/Tests/DomainTests/ScorePrefsEventTests.swift:34`
- Modify: `Packages/Infrastructure/Tests/InfrastructureTests/Persistence/ReaderPreferencesRecordTests.swift:137`, `:171`
- Modify: `Packages/Features/Library/Sources/FolinoLibraryJNI/ReaderPreferencesBridge.swift:235`
- Modify: `Packages/Features/Library/Tests/FolinoLibraryJNITests/ReaderPreferencesBridgeTests.swift:59`
- Modify: `Packages/Features/Reader/Sources/Reader/LayoutSettingsModel.swift:18`, `:25`, `:33-35`

**Interfaces:**
- Produces: `ReaderPreferences.effectiveHonorLayoutBreaks(default: Bool) -> Bool`
- Produces: `LayoutSettingsModel.defaultHonorLayoutBreaks: Bool` (settable stored property, `@ObservationIgnored`, defaults to `true` in this task)
- Removes: `ReaderPreferences.defaultHonorLayoutBreaks`

- [ ] **Step 1: Write the failing test**

Replace the `effective accessors resolve nil to the static defaults` test and extend the block below it in `ReaderPreferencesUntouchedTests.swift`:

```swift
    @Test func `effective accessors resolve nil to the static defaults`() {
        let prefs = ReaderPreferences(scoreItemID: scoreID, hiddenStaves: [])
        #expect(prefs.effectiveMasterVolume == 1.0)
        #expect(prefs.effectiveTransposeSemitones == 0)
    }

    /// `honorLayoutBreaks` resolves against the caller's default for the same reason `staffSize` does: the default is
    /// device-class-dependent, so it cannot live on the model.
    @Test func `effectiveHonorLayoutBreaks follows the injected default`() {
        let untouched = ReaderPreferences(scoreItemID: scoreID, hiddenStaves: [])
        #expect(untouched.effectiveHonorLayoutBreaks(default: false) == false)
        #expect(untouched.effectiveHonorLayoutBreaks(default: true) == true)
        let touched = ReaderPreferences(scoreItemID: scoreID, hiddenStaves: [], honorLayoutBreaks: false)
        #expect(touched.effectiveHonorLayoutBreaks(default: true) == false)
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run from `Packages/Domain`:
`xcodebuild test -scheme Domain -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation -only-testing:Domain/ReaderPreferencesUntouchedTests`

Expected: compile failure — `effectiveHonorLayoutBreaks` is a property, not a method, so `effectiveHonorLayoutBreaks(default:)` does not exist.

- [ ] **Step 3: Change the Domain model**

In `ReaderPreferences.swift`, delete line 29 (`public static let defaultHonorLayoutBreaks = true`) from the defaults block, leaving `defaultMasterVolume` and `defaultTransposeSemitones`, and update that block's doc comment:

```swift
    /// Defaults an untouched (`nil`) field resolves to. Staff size and the break policy have NO static default here —
    /// theirs are device-class-dependent (`ReaderDeviceDefaults` on iOS, `ReaderDeviceDefaults.kt` on Android), so
    /// resolution takes them as arguments instead.
    public static let defaultMasterVolume = 1.0
    public static let defaultTransposeSemitones = 0
```

Replace the computed property at `:149-151`:

```swift
    /// Break policy resolved against the caller's default, because the default is device-class-dependent (a phone
    /// ignores authored breaks and wraps to the viewport; a tablet reproduces the engraver's boundaries) and so can't
    /// live on the model.
    public func effectiveHonorLayoutBreaks(default defaultValue: Bool) -> Bool {
        honorLayoutBreaks ?? defaultValue
    }
```

Update the `honorLayoutBreaks` property doc at `:78-79` so it ends:

```swift
    /// size. `nil` = the user never chose, so it resolves to the caller's device-class default via
    /// `effectiveHonorLayoutBreaks(default:)`.
```

- [ ] **Step 4: Update `LayoutSettingsModel`**

Change the doc at `:18` and the property block at `:25`/`:33-35`:

```swift
    /// `nil` = untouched; resolves to the injected `defaultHonorLayoutBreaks`. Same raw-Optional reasoning as
    /// `staffSize`.
    private(set) var honorLayoutBreaks: Bool?
```

```swift
    /// Injected by `ReaderViewModel` at wiring time — the screen-level defaults, which are device-class-dependent.
    @ObservationIgnored var defaultStaffSize: Double = 14
    @ObservationIgnored var defaultHonorLayoutBreaks: Bool = true
```

```swift
    var effectiveHonorLayoutBreaks: Bool {
        honorLayoutBreaks ?? defaultHonorLayoutBreaks
    }
```

- [ ] **Step 5: Update the five remaining call sites**

`ReaderPreferencesBridge.swift:235` — inside `republish()`:

```swift
            honorLayoutBreaks: prefs.effectiveHonorLayoutBreaks(default: true),
```

`ScorePrefsEventTests.swift:34` — replace `ReaderPreferences.defaultHonorLayoutBreaks` with the literal `true`.

`ReaderPreferencesRecordTests.swift:137`:

```swift
        #expect(restored.effectiveHonorLayoutBreaks(default: true))
```

`ReaderPreferencesRecordTests.swift:171` — replace `ReaderPreferences.defaultHonorLayoutBreaks` with the literal `true`.

`ReaderPreferencesBridgeTests.swift:59`:

```swift
        #expect(bridge.state.honorLayoutBreaks == true)
```

- [ ] **Step 6: Run the tests to verify they pass**

Run from `Packages/Domain`:
`xcodebuild test -scheme Domain -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation`

Run from `Packages/Infrastructure`:
`xcodebuild test -scheme Infrastructure-Package -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation`

Run from `Packages/Features/Reader`:
`xcodebuild test -scheme Reader -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation`

Expected: `** TEST SUCCEEDED **` for all three.

- [ ] **Step 7: Verify the Android JNI target still builds and tests**

Run from `Packages/Features/Library`:
`FOLINO_ANDROID=1 xcrun swift test`

Expected: all suites pass.

Then run (mandatory, from the repo root):
`chmod -R u+w Packages/Features/Library/.build/checkouts/swift-wirelet`

- [ ] **Step 8: Commit**

```bash
git add Packages/Domain/Sources/Domain/Models/ReaderPreferences.swift Packages/Domain/Tests/DomainTests/Models/ReaderPreferencesUntouchedTests.swift Packages/Domain/Tests/DomainTests/ScorePrefsEventTests.swift Packages/Infrastructure/Tests/InfrastructureTests/Persistence/ReaderPreferencesRecordTests.swift Packages/Features/Library/Sources/FolinoLibraryJNI/ReaderPreferencesBridge.swift Packages/Features/Library/Tests/FolinoLibraryJNITests/ReaderPreferencesBridgeTests.swift Packages/Features/Reader/Sources/Reader/LayoutSettingsModel.swift
git commit -m "refactor(domain): resolve the break policy against a caller default"
```

---

## Task 2: iOS — device-class defaults

**Files:**
- Create: `Packages/Features/Reader/Sources/Reader/ReaderDeviceDefaults.swift`
- Create: `Packages/Features/Reader/Tests/ReaderTests/ReaderDeviceDefaultsTests.swift`
- Modify: `Packages/Features/Reader/Sources/Reader/LayoutSettingsModel.swift:25-26`
- Modify: `Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift:161`, `:190`, `:210`, `:245`
- Modify: `Packages/Features/Reader/Sources/Reader/Screens/ReaderRootScreen.swift:175-177`, `:188`
- Modify: `Packages/Features/Reader/Tests/ReaderTests/ReaderViewModelTests.swift:316-325`
- Modify: `Packages/Features/Reader/Tests/ReaderTests/ReaderUntouchedPreferencesTests.swift:59-79`

**Interfaces:**
- Consumes: `LayoutSettingsModel.defaultHonorLayoutBreaks` (Task 1)
- Produces: `enum ReaderDeviceDefaults` with `@MainActor static var staffSize: Double` and `@MainActor static var honorLayoutBreaks: Bool`
- Produces: `ReaderViewModel.init(..., defaultStaffSize: Double = 12, defaultHonorLayoutBreaks: Bool = false, ...)`

- [ ] **Step 1: Write the failing test**

Create `Packages/Features/Reader/Tests/ReaderTests/ReaderDeviceDefaultsTests.swift`:

```swift
@testable import Reader
import Testing
import UIKit

/// The defaults an untouched per-score preference resolves to. Pinned as a pair because the two values move together:
/// a phone gets the smaller staff AND ignores authored breaks, a tablet gets neither.
@MainActor
struct ReaderDeviceDefaultsTests {
    @Test func `each device class gets its own pair`() {
        #expect(ReaderDeviceDefaults.staffSize(isTablet: false) == 12)
        #expect(ReaderDeviceDefaults.staffSize(isTablet: true) == 14)
        #expect(ReaderDeviceDefaults.honorLayoutBreaks(isTablet: false) == false)
        #expect(ReaderDeviceDefaults.honorLayoutBreaks(isTablet: true) == true)
    }

    /// The live accessors must agree with the pure ones for whatever device the test happens to run on, so a future
    /// edit cannot change one without the other.
    @Test func `the live accessors follow the running device's idiom`() {
        let isTablet = UIDevice.current.userInterfaceIdiom == .pad
        #expect(ReaderDeviceDefaults.staffSize == ReaderDeviceDefaults.staffSize(isTablet: isTablet))
        #expect(ReaderDeviceDefaults.honorLayoutBreaks == ReaderDeviceDefaults.honorLayoutBreaks(isTablet: isTablet))
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run from `Packages/Features/Reader`:
`xcodebuild test -scheme Reader -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation -only-testing:Reader/ReaderDeviceDefaultsTests`

Expected: compile failure — `cannot find 'ReaderDeviceDefaults' in scope`.

- [ ] **Step 3: Create `ReaderDeviceDefaults`**

`Packages/Features/Reader/Sources/Reader/ReaderDeviceDefaults.swift`:

```swift
import UIKit

/// What an untouched (`nil`) per-score Reader preference resolves to on this device.
///
/// Deliberately keyed on the device *idiom*, not on the live window width. These values are what `nil` resolves to, so
/// a width-driven rule would re-engrave every untouched score the moment the user rotated the device or resized a
/// Split View. The cost is that a genuinely narrow window on an iPad (Slide Over, a 1/3 Split View) still gets the
/// iPad pair — accepted: a default that is occasionally too generous beats one that moves under the reader's hands.
///
/// The two values move together on purpose. A phone viewport is narrower than the page the score was engraved for, so
/// honoring the authored `<LayoutBreak>` boundaries leaves the staves cramped against an empty right margin; wrapping
/// to the viewport at a smaller staff size is what makes the same score readable.
@MainActor
enum ReaderDeviceDefaults {
    /// Engraved staff size for a score the user has never sized themselves.
    static func staffSize(isTablet: Bool) -> Double {
        isTablet ? 14 : 12
    }

    /// Whether a score the user has never configured reproduces the engraver's authored system / page boundaries.
    static func honorLayoutBreaks(isTablet: Bool) -> Bool {
        isTablet
    }

    private static var isTablet: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
    }

    static var staffSize: Double { staffSize(isTablet: isTablet) }

    static var honorLayoutBreaks: Bool { honorLayoutBreaks(isTablet: isTablet) }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run from `Packages/Features/Reader`:
`xcodebuild test -scheme Reader -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation -only-testing:Reader/ReaderDeviceDefaultsTests`

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Thread the second default through the view model**

In `ReaderViewModel.swift`, beside the existing stored property at `:161`:

```swift
    @ObservationIgnored private let defaultStaffSize: Double
    @ObservationIgnored private let defaultHonorLayoutBreaks: Bool
```

In the `init` signature at `:190`, replace `defaultStaffSize: Double = 14,` with:

```swift
        defaultStaffSize: Double = 12,
        defaultHonorLayoutBreaks: Bool = false,
```

Beside the assignment at `:210`:

```swift
        self.defaultStaffSize = defaultStaffSize
        self.defaultHonorLayoutBreaks = defaultHonorLayoutBreaks
```

In `wireLayoutModel()` at `:245`:

```swift
        layoutModel.defaultStaffSize = defaultStaffSize
        layoutModel.defaultHonorLayoutBreaks = defaultHonorLayoutBreaks
```

In `LayoutSettingsModel.swift:25-26`, move the fallbacks onto the phone pair so an un-updated call site gets the narrower layout rather than a stale one:

```swift
    @ObservationIgnored var defaultStaffSize: Double = 12
    @ObservationIgnored var defaultHonorLayoutBreaks: Bool = false
```

- [ ] **Step 6: Seed both defaults at the root screen**

In `ReaderRootScreen.swift`, replace `:175-177`:

```swift
        // Seed the device-class defaults at construction time. The view model only uses these if no persisted record
        // exists — a stored value, including one equal to the default, always wins.
        let deviceStaffSize = ReaderDeviceDefaults.staffSize
        let deviceHonorLayoutBreaks = ReaderDeviceDefaults.honorLayoutBreaks
```

and at `:188` replace `defaultStaffSize: initialDefault,` with:

```swift
                defaultStaffSize: deviceStaffSize,
                defaultHonorLayoutBreaks: deviceHonorLayoutBreaks,
```

- [ ] **Step 7: Update the two affected test files**

`ReaderViewModelTests.swift` — the view model at `:316-321` now has to state the break-policy default it expects, so the assertion at `:325` documents the injection rather than a constant. Replace `:320` and `:325`:

```swift
            defaultStaffSize: 14,
            defaultHonorLayoutBreaks: true,
```

```swift
        #expect(vm.layoutModel.effectiveHonorLayoutBreaks == true)
```

`ReaderUntouchedPreferencesTests.swift` — `makeViewModel` passes no default, so it now inherits the phone pair. Replace `:65` and `:78`:

```swift
        #expect(saved.staffSize == 13) // the harness leaves `defaultStaffSize` at the phone default, 12
```

```swift
        #expect(saved.staffSize == 12)
```

Append this test to `ReaderUntouchedPreferencesTests` — the persistence seam the spec calls for, which neither of the
edits above covers. `makeViewModel` gains a defaults parameter so the same untouched row can be opened as each device
class:

```swift
    private static func makeViewModel(
        repository: FakeScoreLibraryRepository,
        defaultStaffSize: Double = 12,
        defaultHonorLayoutBreaks: Bool = false,
    ) -> ReaderViewModel {
        let item = Self.makeItem()
        repository.scoreItems = [item]
        return ReaderViewModel(
            scoreItem: item,
            repository: repository,
            gateway: FakeScoreFileGateway(),
            scoresDirectory: URL(filePath: "/tmp"),
            defaultStaffSize: defaultStaffSize,
            defaultHonorLayoutBreaks: defaultHonorLayoutBreaks,
        )
    }

    /// The same untouched row reads differently per device class, and reading it never marks it touched — the whole
    /// point of keeping the slice a raw Optional. A regression here is silent: the score just quietly starts counting
    /// as one the user configured.
    @Test func `the device default resolves an untouched break policy without persisting it`() async throws {
        let phoneRepo = FakeScoreLibraryRepository()
        let phone = Self.makeViewModel(repository: phoneRepo, defaultHonorLayoutBreaks: false)
        await phone.loadOrSeedPreferences()
        #expect(phone.layoutModel.honorLayoutBreaks == nil)
        #expect(phone.layoutModel.effectiveHonorLayoutBreaks == false)

        let tabletRepo = FakeScoreLibraryRepository()
        let tablet = Self.makeViewModel(
            repository: tabletRepo, defaultStaffSize: 14, defaultHonorLayoutBreaks: true,
        )
        await tablet.loadOrSeedPreferences()
        #expect(tablet.layoutModel.honorLayoutBreaks == nil)
        #expect(tablet.layoutModel.effectiveHonorLayoutBreaks == true)

        // A save triggered by an unrelated field must not materialize the resolved default.
        await tablet.layoutModel.toggleStaff(StaffAddress(partIndex: 0, staffIndexInPart: 0))
        let saved = try #require(tabletRepo.savedReaderPreferences.last)
        #expect(saved.honorLayoutBreaks == nil)
        #expect(saved.staffSize == nil)
    }
```

- [ ] **Step 8: Run the Reader tests to verify they pass**

Run from `Packages/Features/Reader`:
`xcodebuild test -scheme Reader -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation`

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 9: Commit**

```bash
git add Packages/Features/Reader/Sources/Reader/ReaderDeviceDefaults.swift Packages/Features/Reader/Tests/ReaderTests/ReaderDeviceDefaultsTests.swift Packages/Features/Reader/Sources/Reader/LayoutSettingsModel.swift Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift Packages/Features/Reader/Sources/Reader/Screens/ReaderRootScreen.swift Packages/Features/Reader/Tests/ReaderTests/ReaderViewModelTests.swift Packages/Features/Reader/Tests/ReaderTests/ReaderUntouchedPreferencesTests.swift
git commit -m "feat(reader): resolve untouched staff size and break policy per device class"
```

---

## Task 3: Android reducer — tempo snap, `clearStaffSize`, frozen legacy seed

Pure Swift, host-testable, no wire change yet.

**Files:**
- Modify: `Packages/Features/Library/Sources/FolinoLibraryJNI/ReaderPreferencesReducer.swift:52-56`, `:113-152`
- Modify: `Packages/Features/Library/Sources/FolinoLibraryJNI/ReaderPreferencesBridge.swift:70`
- Modify: `Packages/Features/Library/Tests/FolinoLibraryJNITests/ReaderPreferencesReducerTests.swift`

**Interfaces:**
- Produces: `ReaderPreferencesReducer.clearStaffSize(_ p: ReaderPreferences) -> ReaderPreferences`
- Produces: `ReaderPreferencesReducer.decode(_ json: String) -> ReaderPreferences?` — single overload, applies the frozen legacy correction
- Removes: `ReaderPreferencesReducer.decode(_:defaultStaffSize:)`

- [ ] **Step 1: Write the failing tests**

Append to `ReaderPreferencesReducerTests.swift`, inside the struct:

```swift
    /// iOS's `TempoModel.commitMultiplier` snaps a value visually at 100% back to "no override", so a slider that
    /// stops at 0.9999 doesn't leave one behind — and so the two reset affordances (BPM-readout tap, slider
    /// double-tap), which both route through `onRate(1.0f)`, actually clear. Without the snap Android persists an
    /// explicit 1.0 and reports the score in `score_prefs` as one the user set a tempo on.
    @Test func `a tempo at unity snaps back to untouched`() {
        let touched = ReaderPreferencesReducer.setTempoMultiplier(base(), 1.5)
        #expect(ReaderPreferencesReducer.setTempoMultiplier(touched, 1.0).tempoMultiplier == nil)
        #expect(ReaderPreferencesReducer.setTempoMultiplier(touched, 0.9999).tempoMultiplier == nil)
        #expect(ReaderPreferencesReducer.setTempoMultiplier(touched, 1.004).tempoMultiplier == nil)
        #expect(ReaderPreferencesReducer.setTempoMultiplier(touched, 0.0).tempoMultiplier == nil)
        // Outside the snap window a set is still an explicit choice.
        #expect(ReaderPreferencesReducer.setTempoMultiplier(touched, 1.01).tempoMultiplier == 1.01)
        #expect(ReaderPreferencesReducer.setTempoMultiplier(touched, 0.5).tempoMultiplier == 0.5)
    }

    /// The staff-size slider's double-tap means "I never chose a size", like every other reset affordance. It used to
    /// write a hardcoded 28, which both marked the score touched and ignored the device default entirely.
    @Test func `clearing staff size goes back to untouched`() {
        let touched = ReaderPreferencesReducer.setStaffSize(base(), 18)
        #expect(touched.staffSize == 18)
        let cleared = ReaderPreferencesReducer.clearStaffSize(touched)
        #expect(cleared.staffSize == nil)
        // Clearing one scalar leaves the others alone.
        #expect(ReaderPreferencesReducer.clearStaffSize(
            ReaderPreferencesReducer.setMasterVolume(touched, 0.4),
        ).masterVolume == 0.4)
    }

    /// Legacy (pre-`schemaVersion`) blobs are demoted against the seed Android actually wrote — a frozen 28.0 — not
    /// against the live default. Once the live default moved to 21/24, comparing against it would strand every
    /// previously-opened score at an explicit 28 AND would reclassify a tablet user's deliberate 24 as untouched.
    @Test func `a legacy blob demotes only the frozen android seed`() {
        // `legacyReaderPreferencesBlob` is the shared file-scope helper in `ReaderPreferencesBridgeTests.swift` —
        // same test target, and it already asserts that what it builds really reads as legacy.
        func legacy(_ staffSize: Double) -> String {
            legacyReaderPreferencesBlob(
                ReaderPreferences(scoreItemID: ScoreItemID(), staffSize: staffSize, hiddenStaves: []),
            )
        }
        #expect(ReaderPreferencesReducer.decode(legacy(28))?.staffSize == nil)
        #expect(ReaderPreferencesReducer.decode(legacy(24))?.staffSize == 24)
        #expect(ReaderPreferencesReducer.decode(legacy(21))?.staffSize == 21)
        // A v2 blob is authoritative even at the frozen seed value.
        let current = ReaderPreferencesReducer.encode(
            ReaderPreferences(scoreItemID: ScoreItemID(), staffSize: 28, hiddenStaves: []),
        )
        #expect(ReaderPreferencesReducer.decode(current)?.staffSize == 28)
    }
```

No new imports are needed — the helper lives in the same test target.

- [ ] **Step 2: Run the tests to verify they fail**

Run from `Packages/Features/Library`:
`FOLINO_ANDROID=1 xcrun swift test --filter ReaderPreferencesReducerTests`

Expected: compile failure — `clearStaffSize` does not exist.

Then run: `chmod -R u+w Packages/Features/Library/.build/checkouts/swift-wirelet`

- [ ] **Step 3: Add the tempo snap**

In `ReaderPreferencesReducer.swift`, replace `setTempoMultiplier` at `:52-56`:

```swift
    /// `0` is the wire's "no override" sentinel. The unity window is the deliberate exception to this type's rule that
    /// a `set…` always records an explicit choice: it mirrors iOS `TempoModel.commitMultiplier`, where a slider that
    /// stops visually at 100% clears the override rather than pinning one the user thought they had released. It is
    /// also what makes Android's two reset affordances clear — both route through `onRate(1.0f)`, not a `clear…` verb.
    /// An explicit `1.0` is therefore unrepresentable here, exactly as on iOS.
    static func setTempoMultiplier(_ p: ReaderPreferences, _ v: Double) -> ReaderPreferences {
        var c = p
        c.tempoMultiplier = (v == 0 || abs(v - 1.0) < 0.005) ? nil : v
        return reseat(c)
    }
```

- [ ] **Step 4: Add `clearStaffSize`**

Insert immediately above `clearMasterVolume` (currently `:73`):

```swift
    /// Reset staff size to "the user never chose one" (`nil`), so it resolves to the current device-class default.
    /// The Compose affordance is the slider's double-tap; it used to write a hardcoded `28.0`, which both marked the
    /// score as configured and ignored the device default it was supposed to return to.
    static func clearStaffSize(_ p: ReaderPreferences) -> ReaderPreferences {
        var c = p
        c.staffSize = nil
        return reseat(c)
    }
```

- [ ] **Step 5: Freeze the legacy seed and merge the `decode` overloads**

Replace the whole block from `:113` (`/// Decodes a stored JSON blob…`) through `:152` (the end of `decode(_:defaultStaffSize:)`) with:

```swift
    /// What Android's since-removed eager seed wrote for a staff size the user never chose. `SettingsPrefs`' global
    /// `staffSize` key has existed since `db9ca50e`, but `SettingsPrefs.setStaffSize` has never been called from
    /// anywhere — the Display inspector's slider is the *per-score* one — so the global was `28.0` in every build that
    /// could write a legacy blob. Frozen for the same reason `ReaderPreferences.LegacyStoredDefaults` is: a migration
    /// has to keep describing the data as it was written, even after the live defaults move (which they now have, to
    /// 21 on a phone and 24 on a tablet).
    private enum LegacyAndroidSeed {
        static let staffSize: Double = 28
    }

    /// Decodes a stored JSON blob back into `ReaderPreferences`, applying the one legacy correction Domain cannot make
    /// on its own. Returns `nil` for empty / invalid input — the caller treats `nil` as "no saved preferences yet" and
    /// seeds defaults.
    ///
    /// `ReaderPreferences.init(from:)` demotes a legacy (pre-`schemaVersion`) `staffSize` only when it equals the
    /// frozen constant `14`, the value iOS seeded. Android's eager seed wrote its own global instead. Left alone such a
    /// blob decodes as `.some`, permanently marking every score any Android user has ever opened as one with an
    /// explicitly configured staff size.
    ///
    /// The rule mirrors the iOS v16 migration — "the stored value equals the seed that was in effect, so treat it as
    /// untouched" — and carries the same accepted trade-off: a user who deliberately chose 28 (the slider maximum) is
    /// reclassified as untouched. That was already true when 28 was also the live default, so this is not a
    /// regression.
    ///
    /// There is no user-visible effect on a phone or tablet whose default is now 21 / 24: the score re-engraves at the
    /// current default, which is the intent of the defaults change. A v2 blob is authoritative and is never touched.
    static func decode(_ json: String) -> ReaderPreferences? {
        guard let data = json.data(using: .utf8), !data.isEmpty,
              var prefs = try? JSONDecoder().decode(ReaderPreferences.self, from: data)
        else { return nil }
        guard isLegacyBlob(json), prefs.staffSize == LegacyAndroidSeed.staffSize else { return prefs }
        prefs.staffSize = nil
        return prefs
    }
```

- [ ] **Step 6: Update the one caller of the removed overload**

In `ReaderPreferencesBridge.swift:70`, replace `ReaderPreferencesReducer.decode(json, defaultStaffSize: defaultStaffSize)` with `ReaderPreferencesReducer.decode(json)`.

In the `open` doc comment above it, replace the sentence beginning "and it is what a legacy blob's eagerly-seeded staff size is demoted against" so the paragraph reads:

```swift
    /// `defaultStaffSize` is the Reader's current global default. It is not stored into the preferences — it is
    /// retained as the value the wire projection resolves an untouched `staffSize` against. The legacy demotion no
    /// longer uses it: it compares against the frozen seed Android actually wrote (see
    /// `ReaderPreferencesReducer.decode(_:)`).
```

- [ ] **Step 7: Run the tests to verify they pass**

Run from `Packages/Features/Library`:
`FOLINO_ANDROID=1 xcrun swift test`

Expected: all suites pass. Two existing `ReaderPreferencesBridgeTests` cases (`a legacy blob whose staff size is the global default decodes as untouched`, `a legacy blob whose staff size differs from the global default keeps it`) already use `28` and `18`, so they keep passing against the frozen seed.

Then run: `chmod -R u+w Packages/Features/Library/.build/checkouts/swift-wirelet`

- [ ] **Step 8: Commit**

```bash
git add Packages/Features/Library/Sources/FolinoLibraryJNI/ReaderPreferencesReducer.swift Packages/Features/Library/Sources/FolinoLibraryJNI/ReaderPreferencesBridge.swift Packages/Features/Library/Tests/FolinoLibraryJNITests/ReaderPreferencesReducerTests.swift
git commit -m "fix(android): clear a reset tempo and staff size instead of pinning a default"
```

---

## Task 4: Android bridge — wire the second default and the new verb

**Files:**
- Modify: `Packages/Features/Library/Sources/FolinoLibraryJNI/ReaderPreferencesBridge.swift:25-28`, `:65-75`, `:107-110`, `:231-242`
- Modify: `Packages/Features/Library/Sources/FolinoLibraryJNI/AnalyticsBridge.swift:296-331`
- Modify: `Packages/Features/Library/Tests/FolinoLibraryJNITests/ReaderPreferencesBridgeTests.swift`
- Modify: `Packages/Features/Library/Tests/FolinoLibraryJNITests/AnalyticsBridgeScorePrefsTests.swift`

**Interfaces:**
- Consumes: `ReaderPreferencesReducer.clearStaffSize` and `decode(_:)` (Task 3)
- Produces: `ReaderPreferencesBridge.open(scoreId: String, defaultStaffSize: Double, defaultHonorLayoutBreaks: Bool)`
- Produces: `ReaderPreferencesBridge.clearStaffSize()`
- Produces: `AnalyticsBridge.scorePrefs(prefsJson: String, widthDp: Double) -> AnalyticsEventWire`

- [ ] **Step 1: Write the failing tests**

In `ReaderPreferencesBridgeTests.swift`, every `bridge.open(scoreId:defaultStaffSize:)` call gains the new argument. Update all eight existing call sites to pass `defaultHonorLayoutBreaks: true`, change the assertion at `:59` to read the injected value, and append these two tests to the struct:

```swift
    /// The break policy is device-class-dependent now, so the bridge resolves it against what `open` was handed rather
    /// than a constant. Two bridges over the same untouched row must project differently.
    @Test func `the wire projection resolves the break policy against the opened default`() {
        let store = FakeReaderPreferencesStore()
        let phone = ReaderPreferencesBridge(store: store)
        phone.open(scoreId: "s1", defaultStaffSize: 21, defaultHonorLayoutBreaks: false)
        #expect(phone.state.staffSize == 21)
        #expect(phone.state.honorLayoutBreaks == false)

        let tablet = ReaderPreferencesBridge(store: store)
        tablet.open(scoreId: "s1", defaultStaffSize: 24, defaultHonorLayoutBreaks: true)
        #expect(tablet.state.staffSize == 24)
        #expect(tablet.state.honorLayoutBreaks == true)
        // Projecting a default never writes one.
        #expect(store.saveCount == 0)
    }

    /// An explicitly chosen break policy outranks the device default in both directions.
    @Test func `an explicit break policy survives the device default`() {
        let store = FakeReaderPreferencesStore()
        let bridge = ReaderPreferencesBridge(store: store)
        bridge.open(scoreId: "s1", defaultStaffSize: 21, defaultHonorLayoutBreaks: false)
        bridge.setHonorLayoutBreaks(value: true)
        #expect(bridge.state.honorLayoutBreaks == true)
        #expect(saved(store, "s1")?.honorLayoutBreaks == true)
    }

    /// Reset parity with the other scalars: the staff-size double-tap means untouched, and Compose still sees the
    /// device default resolved back.
    @Test func `clearing staff size persists untouched and projects the default`() {
        let store = FakeReaderPreferencesStore()
        let bridge = ReaderPreferencesBridge(store: store)
        bridge.open(scoreId: "s1", defaultStaffSize: 21, defaultHonorLayoutBreaks: false)
        bridge.setStaffSize(value: 18)
        #expect(saved(store, "s1")?.staffSize == 18)
        bridge.clearStaffSize()
        #expect(saved(store, "s1")?.staffSize == nil)
        #expect(bridge.state.staffSize == 21)
    }
```

In `AnalyticsBridgeScorePrefsTests.swift`, drop the third argument from every `scorePrefs(...)` call.

- [ ] **Step 2: Run the tests to verify they fail**

Run from `Packages/Features/Library`:
`FOLINO_ANDROID=1 xcrun swift test --filter ReaderPreferencesBridgeTests`

Expected: compile failure — `open` has no `defaultHonorLayoutBreaks` parameter and `clearStaffSize` does not exist.

Then run: `chmod -R u+w Packages/Features/Library/.build/checkouts/swift-wirelet`

- [ ] **Step 3: Retain the second default in the bridge**

In `ReaderPreferencesBridge.swift`, beside the retained default at `:25-28`:

```swift
    /// The Reader's current global default staff size, handed in by `open`. Retained because `staffSize` is Optional
    /// on the model (`nil` = the user never chose one) while the wire is a resolved scalar — this is the value the
    /// projection resolves against. Kept in sync only by `open`, which is also where the Reader learns it.
    @ObservationIgnored private var openDefaultStaffSize: Double = 14
    /// The same, for the break policy. Both defaults are device-class-dependent on Android
    /// (`ReaderDeviceDefaults.kt`), which is why neither can be a constant here.
    @ObservationIgnored private var openDefaultHonorLayoutBreaks = true
```

Change the `open` signature and body at `:65-75`:

```swift
    @WireletExpose
    public func open(scoreId: String, defaultStaffSize: Double, defaultHonorLayoutBreaks: Bool) {
        self.scoreId = scoreId
        openDefaultStaffSize = defaultStaffSize
        openDefaultHonorLayoutBreaks = defaultHonorLayoutBreaks
        let json = store.loadJSON(scoreId: scoreId)
        if let decoded = ReaderPreferencesReducer.decode(json) {
            prefs = decoded
        } else {
            prefs = ReaderPreferences(scoreItemID: ScoreItemID(), hiddenStaves: [])
        }
    }
```

Extend the `open` doc comment's `defaultStaffSize` paragraph to cover both arguments:

```swift
    /// `defaultStaffSize` and `defaultHonorLayoutBreaks` are the Reader's current device-class defaults. Neither is
    /// stored into the preferences — they are retained as the values the wire projection resolves the matching
    /// untouched fields against. The legacy demotion does not use them: it compares against the frozen seed Android
    /// actually wrote (see `ReaderPreferencesReducer.decode(_:)`).
```

- [ ] **Step 4: Add the `clearStaffSize` verb and resolve both defaults**

Insert into the reset-verbs section, above `clearMasterVolume` at `:142`:

```swift
    /// Reset affordance for staff size (the slider's double-tap). Writes "the user never chose one" rather than a
    /// number, so the score follows the device-class default. Its predecessor wrote a hardcoded `28.0`.
    @WireletExpose
    public func clearStaffSize() {
        mutate { ReaderPreferencesReducer.clearStaffSize($0) }
    }
```

In `republish()` at `:234-235`:

```swift
            staffSize: prefs.effectiveStaffSize(default: openDefaultStaffSize),
            honorLayoutBreaks: prefs.effectiveHonorLayoutBreaks(default: openDefaultHonorLayoutBreaks),
```

- [ ] **Step 5: Drop the dead analytics argument and correct its doc**

In `AnalyticsBridge.swift`, replace the signature at `:322`:

```swift
    public func scorePrefs(prefsJson: String, widthDp: Double) -> AnalyticsEventWire {
```

and replace the two doc paragraphs at `:303-320` (from "**A legacy (pre-`schemaVersion`) blob never reports `staff_size`" through the `defaultStaffSize` paragraph) with:

```swift
    /// **A legacy (pre-`schemaVersion`) blob never reports `staff_size`, whatever it stores.** Android's
    /// since-removed eager seed wrote the global staff size in effect when the score was first opened. The Reader's
    /// own decode demotes that value when it equals the frozen seed Android actually wrote
    /// (`ReaderPreferencesReducer.decode(_:)`), but the pre-`schemaVersion` world did not record the
    /// chosen-vs-seeded distinction at all, so anything else a legacy blob holds is ambiguous. Dropping the parameter
    /// under-reports, which is the direction this instrumentation errs everywhere else (spec §4, §6), and the
    /// population is self-limiting — the first mutation of any such score re-encodes it as `schemaVersion: 2`, after
    /// which its `staffSize` is authoritative and reported. iOS needs no such rule: its seed was the frozen constant
    /// `14`, so the v16 migration's `CASE WHEN staff_size = 14 THEN NULL` is exact.
    ///
    /// This is an **analytics-only** widening. `ReaderPreferencesBridge.open` renders from the decoded value, so what
    /// the Reader shows is unaffected.
```

- [ ] **Step 6: Run the tests to verify they pass**

Run from `Packages/Features/Library`:
`FOLINO_ANDROID=1 xcrun swift test`

Expected: all suites pass.

Then run: `chmod -R u+w Packages/Features/Library/.build/checkouts/swift-wirelet`

- [ ] **Step 7: Commit**

```bash
git add Packages/Features/Library/Sources/FolinoLibraryJNI/ReaderPreferencesBridge.swift Packages/Features/Library/Sources/FolinoLibraryJNI/AnalyticsBridge.swift Packages/Features/Library/Tests/FolinoLibraryJNITests/ReaderPreferencesBridgeTests.swift Packages/Features/Library/Tests/FolinoLibraryJNITests/AnalyticsBridgeScorePrefsTests.swift
git commit -m "feat(android): carry the device-class break policy and a staff-size reset across the bridge"
```

---

## Task 5: Android Kotlin — device defaults, reset wiring, dead-key removal

**Files:**
- Create: `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderDeviceDefaults.kt`
- Create: `Android/FolinoReaderAndroid/src/test/kotlin/com/keynumber/folino/reader/ReaderDeviceDefaultsTest.kt`
- Modify: `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/DisplayInspectorSheet.kt:118-159`, `:169-187`, `:225-227`, `:367-398`
- Modify: `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/LayoutOptions.kt:61-72`
- Modify: `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderViewModel.kt:146`
- Modify: `Android/app/src/main/kotlin/com/keynumber/folino/ui/settings/SettingsPrefs.kt:41-42`, `:139-140`, `:183-184`
- Modify: `Android/app/src/main/kotlin/com/keynumber/folino/MainActivity.kt:341-357`, `:577`, `:615`, `:691`

**Interfaces:**
- Consumes: `ReaderPreferencesBridgeViewModel.open(scoreId, defaultStaffSize, defaultHonorLayoutBreaks)` and `.clearStaffSize()` (Task 4, via regenerated wirelet bindings)
- Produces: `ReaderDeviceDefaults.staffSize(smallestScreenWidthDp: Int): Double`, `ReaderDeviceDefaults.honorLayoutBreaks(smallestScreenWidthDp: Int): Boolean`, `ReaderDeviceDefaults.staffSize(context: Context): Double`, `ReaderDeviceDefaults.honorLayoutBreaks(context: Context): Boolean`
- Produces: `DisplayInspectorSheet(..., defaultStaffSize: Double, onResetStaffSize: () -> Unit)` and the same pair on `DisplayInspectorContent`

- [ ] **Step 1: Write the failing test**

Create `Android/FolinoReaderAndroid/src/test/kotlin/com/keynumber/folino/reader/ReaderDeviceDefaultsTest.kt`:

```kotlin
package com.keynumber.folino.reader

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The defaults an untouched per-score Reader preference resolves to. The tablet cut is `smallestScreenWidthDp >= 600`
 * — the smallest dimension, so it does not move when the device rotates.
 */
class ReaderDeviceDefaultsTest {
    @Test fun phoneGetsTheNarrowPair() {
        assertEquals(21.0, ReaderDeviceDefaults.staffSize(smallestScreenWidthDp = 411), 0.0)
        assertFalse(ReaderDeviceDefaults.honorLayoutBreaks(smallestScreenWidthDp = 411))
    }

    @Test fun tabletGetsTheWidePair() {
        assertEquals(24.0, ReaderDeviceDefaults.staffSize(smallestScreenWidthDp = 800), 0.0)
        assertTrue(ReaderDeviceDefaults.honorLayoutBreaks(smallestScreenWidthDp = 800))
    }

    @Test fun theCutIsAtSixHundred() {
        assertEquals(21.0, ReaderDeviceDefaults.staffSize(smallestScreenWidthDp = 599), 0.0)
        assertEquals(24.0, ReaderDeviceDefaults.staffSize(smallestScreenWidthDp = 600), 0.0)
        assertFalse(ReaderDeviceDefaults.honorLayoutBreaks(smallestScreenWidthDp = 599))
        assertTrue(ReaderDeviceDefaults.honorLayoutBreaks(smallestScreenWidthDp = 600))
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run from `Android`:
`./gradlew :FolinoReaderAndroid:testDebugUnitTest --tests '*ReaderDeviceDefaultsTest'`

Expected: compile failure — unresolved reference `ReaderDeviceDefaults`.

- [ ] **Step 3: Create `ReaderDeviceDefaults.kt`**

```kotlin
package com.keynumber.folino.reader

import android.content.Context

/**
 * What an untouched (`null` on the Swift side) per-score Reader preference resolves to on this device.
 *
 * Keyed on `smallestScreenWidthDp` — the device's smaller dimension, which does not change when the device rotates or
 * when a window is resized. These values are what "the user never chose" resolves to, so a rule driven by the live
 * window width would re-engrave every untouched score mid-session. The `>= 600` cut is Android's own tablet
 * convention (`sw600dp`).
 *
 * The two values move together on purpose. A phone viewport is narrower than the page the score was engraved for, so
 * honoring the authored layout breaks leaves the staves cramped against an empty right margin; wrapping to the
 * viewport at a smaller staff size is what makes the same score readable.
 *
 * iOS resolves the same pair from `UIDevice.userInterfaceIdiom` (`ReaderDeviceDefaults.swift`). The numbers differ
 * between the platforms because Android engraves at a fixed layout density, so the same millimetre value renders at a
 * different apparent size.
 */
object ReaderDeviceDefaults {
    private const val TABLET_MIN_WIDTH_DP = 600

    /** Engraved staff size for a score the user has never sized themselves. */
    fun staffSize(smallestScreenWidthDp: Int): Double =
        if (smallestScreenWidthDp >= TABLET_MIN_WIDTH_DP) 24.0 else 21.0

    /** Whether a score the user has never configured reproduces the engraver's authored system / page boundaries. */
    fun honorLayoutBreaks(smallestScreenWidthDp: Int): Boolean =
        smallestScreenWidthDp >= TABLET_MIN_WIDTH_DP

    fun staffSize(context: Context): Double =
        staffSize(context.resources.configuration.smallestScreenWidthDp)

    fun honorLayoutBreaks(context: Context): Boolean =
        honorLayoutBreaks(context.resources.configuration.smallestScreenWidthDp)
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run from `Android`:
`./gradlew :FolinoReaderAndroid:testDebugUnitTest --tests '*ReaderDeviceDefaultsTest'`

Expected: `BUILD SUCCESSFUL`.

- [ ] **Step 5: Give the staff-size row a real default and a reset callback**

In `DisplayInspectorSheet.kt`, replace `StaffSizeRow` at `:367-398`:

```kotlin
@Composable
private fun StaffSizeRow(
    staffSize: Double,
    defaultStaffSize: Double,
    onChange: (Double) -> Unit,
    onReset: () -> Unit,
) {
    Row(
        Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text(
            stringResource(R.string.reader_pref_staff_size),
            modifier = Modifier.width(88.dp),
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            style = MaterialTheme.typography.bodyMedium,
        )
        ResettableSlider(
            value = staffSize.toFloat(),
            onValueChange = { onChange(it.toDouble()) },
            // The tick and the double-tap target both sit at this device's default. Reset CLEARS the per-score value
            // rather than writing this number, so the score keeps following the default (iOS parity, and the reason
            // `onReset` is separate from `onChange`).
            defaultValue = defaultStaffSize.toFloat(),
            onReset = onReset,
            valueRange = 8f..28f,
            modifier = Modifier.weight(1f).height(InspectorSliderHeight),
        )
        Text(
            "${staffSize.roundToInt()} pt",
            modifier = Modifier.width(44.dp),
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            style = MaterialTheme.typography.bodySmall,
        )
    }
}
```

Add the two parameters to `DisplayInspectorSheet` (after `onResetTranspose` at `:135`) and to `DisplayInspectorContent` (after `onResetTranspose` at `:184`), using identical text in both:

```kotlin
    /** This device's default staff size — the slider's tick and double-tap target. */
    defaultStaffSize: Double = ReaderDeviceDefaults.staffSize(LocalContext.current),
    /** Double-tap on the staff-size slider: clears the stored value instead of writing an explicit number. */
    onResetStaffSize: () -> Unit = {},
```

Forward both from the sheet to the content, inside the `DisplayInspectorContent(...)` call at `:143-157`:

```kotlin
            defaultStaffSize = defaultStaffSize,
            onResetStaffSize = onResetStaffSize,
```

Replace the row's call site at `:226`:

```kotlin
                    item {
                        StaffSizeRow(
                            staffSize = options.staffSize,
                            defaultStaffSize = defaultStaffSize,
                            onChange = { onChange(options.copy(staffSize = it)) },
                            onReset = onResetStaffSize,
                        )
                    }
```

Add `import androidx.compose.ui.platform.LocalContext` to the file's import block if it is not already there.

- [ ] **Step 6: Re-document `LayoutOptions.DEFAULT` and seed the view model**

In `LayoutOptions.kt`, replace the doc at `:62`:

```kotlin
        /**
         * Render placeholder — NOT the preference default. The per-score defaults are device-class-dependent and live
         * in [ReaderDeviceDefaults]; this constant is what [ReaderViewModel] starts from before the real preferences
         * arrive, what `PdfScoreRenderer` exports with (a printed page should not re-engrave according to the phone
         * that triggered the export), and the base the screenshot scenes copy from.
         */
```

In `ReaderViewModel.kt:146`, seed from the device instead:

```kotlin
    // Seeded from this device's default so the first composed frame does not engrave at the placeholder size and then
    // reflow when the real per-score preferences arrive from the bridge.
    private val _layoutOptions = MutableStateFlow(
        LayoutOptions.DEFAULT.copy(
            staffSize = ReaderDeviceDefaults.staffSize(app),
            honorLayoutBreaks = ReaderDeviceDefaults.honorLayoutBreaks(app),
        ),
    )
```

- [ ] **Step 7: Move the global staff-size fallback onto the device and delete the dead break key**

In `SettingsPrefs.kt`, delete line `:42` (`val honorBreaks = booleanPreferencesKey("reader.honorLayoutBreaks")`), delete line `:140` (the `honorBreaks` flow), and delete line `:184` (`suspend fun setHonorBreaks`). They have never been written or collected — the break policy is per-score and comes from the bridge.

Replace the `staffSize` flow at `:139`:

```kotlin
    /**
     * The Reader's global default staff size. No UI writes this key — it is the device-class default, read here so the
     * per-score bridge has a value to resolve an untouched `staffSize` against. See [ReaderDeviceDefaults].
     */
    val staffSize: Flow<Double> = context.dataStore.data.map {
        it[SettingsKeys.staffSize] ?: ReaderDeviceDefaults.staffSize(context)
    }
```

Add `import com.keynumber.folino.reader.ReaderDeviceDefaults` to the file's import block.

- [ ] **Step 8: Wire `MainActivity`**

At `:577`, replace the hardcoded initial:

```kotlin
                val staffSize by prefs.staffSize.collectAsState(initial = ReaderDeviceDefaults.staffSize(context))
```

`context` is already in scope at `:596` — move that `val context = LocalContext.current` line above the `collectAsState` block so it is declared first.

At `:615`, pass both defaults:

```kotlin
                LaunchedEffect(currentScoreId) {
                    prefsVm.open(
                        currentScoreId,
                        defaultStaffSize = staffSize,
                        defaultHonorLayoutBreaks = ReaderDeviceDefaults.honorLayoutBreaks(context),
                    )
                }
```

In the `ReaderScreen(...)` call, immediately after the `displayOptions = displayOptions,` argument:

```kotlin
                    defaultStaffSize = ReaderDeviceDefaults.staffSize(context),
                    onResetStaffSize = { prefsVm.clearStaffSize() },
```

In the analytics block, delete `:350` (`val defaultStaffSize = prefs.staffSize.first()`), replace `:355` with:

```kotlin
            val wire = AndroidAnalytics.bridge.scorePrefs(json, widthDp)
```

and delete the now-false paragraph at `:341-344` (the one beginning "defaultStaffSize is still the *live* global staff size").

- [ ] **Step 9: Thread the two parameters through `ReaderScreen`**

In `ReaderScreen.kt`, add both parameters immediately after `persistTransposeReset` at `:240`:

```kotlin
    /** This device's default staff size — the display inspector's slider tick and double-tap target. */
    defaultStaffSize: Double = ReaderDeviceDefaults.staffSize(LocalContext.current),
    /** Double-tap on the staff-size slider: clears the stored value instead of writing an explicit number. */
    onResetStaffSize: () -> Unit = {},
```

Forward both in the `DisplayInspectorSheet(...)` call at `:909-925`, after `onResetTranspose = persistTransposeReset,`:

```kotlin
            defaultStaffSize = defaultStaffSize,
            onResetStaffSize = onResetStaffSize,
```

Only that call site changes. The other `onResetTranspose = persistTransposeReset,` at `:895` belongs to the playback
inspector, which has no staff-size row.

Add `import androidx.compose.ui.platform.LocalContext` to the file's import block if it is not already there.

- [ ] **Step 10: Regenerate the wire, rebuild the `.so`, and build the app**

Fresh worktree, so resolve the wirelet checkouts for all four JNI packages first. Run each from the repo root:

```bash
env FOLINO_ANDROID=1 PATH=/Library/Developer/Toolchains/swift-6.3.3-RELEASE.xctoolchain/usr/bin:$PATH swift package resolve --package-path Packages/Features/Library
```
```bash
env FOLINO_ANDROID=1 PATH=/Library/Developer/Toolchains/swift-6.3.3-RELEASE.xctoolchain/usr/bin:$PATH swift package resolve --package-path Packages/Features/Reader
```
```bash
env FOLINO_ANDROID=1 PATH=/Library/Developer/Toolchains/swift-6.3.3-RELEASE.xctoolchain/usr/bin:$PATH swift package resolve --package-path Packages/Features/Settings
```
```bash
env FOLINO_ANDROID=1 PATH=/Library/Developer/Toolchains/swift-6.3.3-RELEASE.xctoolchain/usr/bin:$PATH swift package resolve --package-path Packages/Infrastructure
```
```bash
chmod -R u+w Packages/Features/Library/.build/checkouts/swift-wirelet
```

Copy the JNI artifacts this task does not change from the primary checkout (rebuilding all four takes 30–60 minutes):

```bash
cp -R /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/Android/FolinoSettingsAndroid/src/main/java-generated /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/Android/FolinoSettingsAndroid/src/main/jniLibs /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/reader-defaults-device-class/Android/FolinoSettingsAndroid/src/main/
```
```bash
cp -R /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/Android/FolinoReaderAndroid/src/main/java-generated /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/Android/FolinoReaderAndroid/src/main/jniLibs /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/reader-defaults-device-class/Android/FolinoReaderAndroid/src/main/
```
```bash
cp -R /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/Android/FolinoSoundfontAndroid/src/main/jniLibs /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/reader-defaults-device-class/Android/FolinoSoundfontAndroid/src/main/
```

Now the ordering that matters — codegen first, `.so` second. Run from `Android`:

```bash
./gradlew --no-daemon :FolinoLibraryAndroid:compileDebugKotlin
```

Then from the repo root:

```bash
env PATH=/Library/Developer/Toolchains/swift-6.3.3-RELEASE.xctoolchain/usr/bin:$PATH Scripts/android-build-library-libs.sh
```

Then from `Android`:

```bash
./gradlew :app:assembleDebug
```

Expected: `BUILD SUCCESSFUL`. If `compileDebugKotlin` fails on an unresolved `clearStaffSize` or an `open` arity mismatch, the codegen has not picked up Task 4's bridge changes — re-run it before touching the `.so`.

- [ ] **Step 11: Run the Android unit tests**

Run from `Android`:
`./gradlew :FolinoReaderAndroid:testDebugUnitTest`

Expected: `BUILD SUCCESSFUL`.

- [ ] **Step 12: Commit**

```bash
git add Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderDeviceDefaults.kt Android/FolinoReaderAndroid/src/test/kotlin/com/keynumber/folino/reader/ReaderDeviceDefaultsTest.kt Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/DisplayInspectorSheet.kt Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/LayoutOptions.kt Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderViewModel.kt Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderScreen.kt Android/app/src/main/kotlin/com/keynumber/folino/ui/settings/SettingsPrefs.kt Android/app/src/main/kotlin/com/keynumber/folino/MainActivity.kt
git commit -m "feat(android): resolve untouched staff size and break policy per device class"
```

---

## Task 6: Whole-app verification

**Files:** none modified unless a failure is found.

- [ ] **Step 1: Build the iOS app**

Run from the worktree root:
`xcodegen generate`

Then:
`xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation build`

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 2: Run the full iOS test suite**

Run from the worktree root:
`xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation test`

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 3: Install and launch on the Android device**

Run from `Android`:
`./gradlew :app:installDebug`

Then:
`adb shell am start -n com.harmolo.folino/com.keynumber.folino.MainActivity`

Verify in `adb logcat` that all four `.so` files load and there is no `FATAL`.

- [ ] **Step 4: Verify the defaults on device**

On the phone: open a score never opened before. Confirm the staves render at 21 pt and that measures wrap to the viewport width rather than following the score's authored line breaks. Open the Display inspector and confirm the staff-size slider's tick sits at 21 and the honor-breaks switch reads off.

Drag the staff size to 18, close and reopen the score, and confirm 18 survives. Double-tap the slider and confirm it returns to 21 (not 28).

In the Playback inspector, drag the tempo away from 100%, then tap the `♩ = N` readout. Confirm it returns to 100%.

If a tablet or an `sw600dp` emulator is available, repeat the first check and confirm 24 pt with authored breaks honored.

- [ ] **Step 5: Report**

Summarize what was verified on device and what was not (for example, the tablet pair if no tablet was available). Do not commit; there is nothing to commit unless a failure was found and fixed.

---

## Follow-ups (not part of this plan)

- `project_per_score_prefs_instrumentation` memory: the "iPad device-class default" item is closed by Task 2; the `Migrations.swift` 394/400-line warning and the `hasStaffBoundOverrides` product question stay open.
- No `PARITY(android)` marker is warranted — both platforms land together.
