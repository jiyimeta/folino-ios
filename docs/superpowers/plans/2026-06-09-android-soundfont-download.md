# Android Soundfont Download Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring the iOS high-quality SoundFont download feature to Android at full behavioral parity — Wi-Fi-by-default auto-download, cellular override, progress, delete, failure auto-retry, and paused hot-swap — by sharing the decision logic in Swift and injecting Android I/O from Kotlin.

**Architecture:** A pure, Foundation-only **reducer in Domain** owns the state machine, Wi-Fi gating, auto-retry, and preset selection. The existing iOS `LiveMuseScoreGeneralProvider` is refactored to drive its state through that reducer (behavior-preserving). A new Android-only Swift product **`FolinoSoundfontJNI`** (gated inside the Infrastructure package, depends on Domain + swift-wirelet) hosts a `@WireletObservable` store that drives the same reducer and exposes flattened state to Compose; the download transport, network reachability, and key-value persistence are Kotlin services injected over `@WireletProvided`, with progress flowing back through `@WireletExpose` ingest methods. The Android audio resolver prefers the downloaded file and the reader hot-swaps the engine while paused.

**Tech Stack:** Swift 6.3 (Domain reducer, iOS provider, JNI bridge), swift-wirelet (`@WireletObservable` / `@WireletProvided` / `@WireletExpose` / `@WireFormat`), Kotlin + Jetpack Compose, Android `DownloadManager` + `ConnectivityManager` + DataStore, swift-sheet-music Android audio engine.

---

## Reference patterns (read before starting)

- iOS provider being refactored: `Packages/Infrastructure/Sources/Soundfonts/LiveMuseScoreGeneralProvider.swift`
- Domain models reused as-is: `Packages/Domain/Sources/Domain/Models/SoundfontDownloadState.swift`, `.../SoundfontPreset.swift`
- iOS provider protocol: `Packages/Domain/Sources/Domain/Protocols/MuseScoreGeneralProvider.swift`
- iOS resolver: `Packages/Infrastructure/Sources/Soundfonts/GMSoundfontResolver.swift`
- Existing wirelet bridge to mirror: `Packages/Features/Library/Package.swift` (Android `if isAndroid` block), `Packages/Features/Library/Sources/FolinoLibraryJNI/LibraryAndroidStore.swift` (`@WireletObservable`), `.../LibraryStore.swift` (`@WireletProvided`), `.../ScoreRecordWire.swift` (`@WireFormat`)
- Kotlin impl + injection: `Android/FolinoLibraryAndroid/src/main/kotlin/com/keynumber/folino/library/RoomLibraryStore.kt`, `Android/app/src/main/kotlin/com/keynumber/folino/MainActivity.kt` (`LibraryVMFactory`)
- Build script to mirror: `Scripts/android-build-library-libs.sh`
- Gradle module to mirror: `Android/FolinoLibraryAndroid/build.gradle.kts`, `Android/settings.gradle.kts`
- Android resolver + playback service to modify: `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/FolinoSoundfontResolver.kt`, `.../ReaderPlaybackService.kt`
- Settings UI + prefs: `Android/app/src/main/kotlin/com/keynumber/folino/ui/settings/SettingsScreen.kt`, `.../SettingsPrefs.kt`

**Build/test commands (from project memory):**
- Package unit tests run via Xcode + iOS simulator, NOT `swift test` (SwiftLint plugin breaks `swift test`): `cd Packages/Domain && xcodebuild test -scheme Domain-Package -destination 'platform=iOS Simulator,name=iPhone 17'`. Same shape for `Infrastructure`.
- Android JNI build: `Scripts/android-build-soundfont-libs.sh` (created in this plan). Fresh worktree order: gradle codec/observable/provided generation must run before the `.so` consumes them; build the `.so` after.
- Android app: `cd Android && ./gradlew :app:installDebug`, then `adb shell am start -n com.keynumber.folino/.MainActivity`.

---

## File Structure

**Domain (shared, pure):**
- Create `Packages/Domain/Sources/Domain/Models/SoundfontDownloadEvent.swift` — event enum for the reducer.
- Create `Packages/Domain/Sources/Domain/Logic/SoundfontDownloadReducer.swift` — pure state machine + gating + preset selection.
- Create `Packages/Domain/Tests/DomainTests/SoundfontDownloadReducerTests.swift` — pure unit tests.

**iOS Infrastructure (refactor, behavior-preserving):**
- Modify `Packages/Infrastructure/Sources/Soundfonts/LiveMuseScoreGeneralProvider.swift` — route state through the reducer.
- Existing `Packages/Infrastructure/Tests/.../LiveMuseScoreGeneralProviderTests.swift` — must stay green.

**Android Swift JNI bridge (new, Android-gated in Infrastructure):**
- Modify `Packages/Infrastructure/Package.swift` — add `if isAndroid` block with `FolinoSoundfontJNI` product.
- Create `Packages/Infrastructure/Sources/FolinoSoundfontJNI/SoundfontWire.swift` — `@WireFormat` types.
- Create `.../FolinoSoundfontJNI/SoundfontServices.swift` — `@WireletProvided` interfaces.
- Create `.../FolinoSoundfontJNI/MuseScoreGeneralAndroidStore.swift` — `@WireletObservable` store.

**Build + Gradle (new):**
- Create `Scripts/android-build-soundfont-libs.sh`.
- Create `Android/FolinoSoundfontAndroid/build.gradle.kts` + `src/main/AndroidManifest.xml`.
- Modify `Android/settings.gradle.kts` — `include(":FolinoSoundfontAndroid")`.

**Android Kotlin services (new):**
- Create `Android/FolinoSoundfontAndroid/src/main/kotlin/com/keynumber/folino/soundfont/AndroidSoundfontDownloader.kt`.
- Create `.../soundfont/AndroidNetworkReachability.kt`.
- Create `.../soundfont/SoundfontPrefsStoreImpl.kt`.

**Android UI + engine integration (modify):**
- Modify `Android/app/src/main/kotlin/com/keynumber/folino/MainActivity.kt` — ViewModel factory + provide the store.
- Modify `Android/app/src/main/kotlin/com/keynumber/folino/ui/settings/SettingsScreen.kt` — soundfont row + dialogs.
- Modify `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/FolinoSoundfontResolver.kt` — prefer downloaded file.
- Modify `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderPlaybackService.kt` — hot-swap on download complete.
- Modify `Android/app/src/main/AndroidManifest.xml` — `ACCESS_NETWORK_STATE` permission.

---

## Phase 0 — Shared Domain reducer (pure, TDD)

### Task 1: Soundfont download event type

**Files:**
- Create: `Packages/Domain/Sources/Domain/Models/SoundfontDownloadEvent.swift`

- [ ] **Step 1: Write the type**

```swift
/// Inputs to `SoundfontDownloadReducer.nextState`. The reducer is the single place that maps a current
/// `SoundfontDownloadState` plus one of these events to the next state, so iOS (`LiveMuseScoreGeneralProvider`)
/// and Android (`MuseScoreGeneralAndroidStore`) share identical transition rules.
public enum SoundfontDownloadEvent: Sendable, Equatable {
    /// A download started (transport accepted the request).
    case started
    /// Progress update; `fraction` is bytes-written / expected, clamped to `[0, 1]`.
    case progress(fraction: Double)
    /// The file finished downloading and is installed on disk.
    case finished
    /// The download attempt failed. `reason` is a localized, displayable string.
    case failed(reason: String)
    /// A download was cancelled (user toggle-off or explicit stop). `fileExists` reflects whether a complete
    /// file nonetheless landed on disk before cancellation propagated.
    case cancelled(fileExists: Bool)
    /// Re-evaluate from disk (e.g. on launch): `fileExists` decides `downloaded` vs `idle`.
    case syncedFromDisk(fileExists: Bool)
}
```

- [ ] **Step 2: Commit**

```bash
git add Packages/Domain/Sources/Domain/Models/SoundfontDownloadEvent.swift
git commit -m "feat(domain): add SoundfontDownloadEvent for the shared reducer"
```

### Task 2: Soundfont download reducer

**Files:**
- Create: `Packages/Domain/Sources/Domain/Logic/SoundfontDownloadReducer.swift`
- Test: `Packages/Domain/Tests/DomainTests/SoundfontDownloadReducerTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import Testing
@testable import Domain

@Suite struct SoundfontDownloadReducerTests {
    typealias R = SoundfontDownloadReducer

    @Test func progressMovesToDownloadingAndClamps() {
        #expect(R.nextState(.idle, on: .started) == .downloading(progress: 0))
        #expect(R.nextState(.downloading(progress: 0), on: .progress(fraction: 0.5)) == .downloading(progress: 0.5))
        #expect(R.nextState(.downloading(progress: 0.5), on: .progress(fraction: 1.4)) == .downloading(progress: 1))
        #expect(R.nextState(.downloading(progress: 0.5), on: .progress(fraction: -1)) == .downloading(progress: 0))
    }

    @Test func finishedAndFailed() {
        #expect(R.nextState(.downloading(progress: 0.9), on: .finished) == .downloaded)
        #expect(R.nextState(.downloading(progress: 0.2), on: .failed(reason: "boom")) == .failed(reason: "boom"))
    }

    @Test func cancelledAndSyncDependOnFile() {
        #expect(R.nextState(.downloading(progress: 0.2), on: .cancelled(fileExists: false)) == .idle)
        #expect(R.nextState(.downloading(progress: 0.2), on: .cancelled(fileExists: true)) == .downloaded)
        #expect(R.nextState(.idle, on: .syncedFromDisk(fileExists: true)) == .downloaded)
        #expect(R.nextState(.downloaded, on: .syncedFromDisk(fileExists: false)) == .idle)
    }

    @Test func autoStartRequiresOptInWiFiAbsentFileNoInflight() {
        #expect(R.shouldAutoStart(isOptedIn: true, fileExists: false, isDownloading: false, isWiFi: true))
        #expect(!R.shouldAutoStart(isOptedIn: false, fileExists: false, isDownloading: false, isWiFi: true))
        #expect(!R.shouldAutoStart(isOptedIn: true, fileExists: true, isDownloading: false, isWiFi: true))
        #expect(!R.shouldAutoStart(isOptedIn: true, fileExists: false, isDownloading: true, isWiFi: true))
        #expect(!R.shouldAutoStart(isOptedIn: true, fileExists: false, isDownloading: false, isWiFi: false))
    }

    @Test func retriesOnlyAfterFailure() {
        #expect(R.shouldRetryOnWiFi(.failed(reason: "x")))
        #expect(!R.shouldRetryOnWiFi(.idle))
        #expect(!R.shouldRetryOnWiFi(.downloading(progress: 0.1)))
        #expect(!R.shouldRetryOnWiFi(.downloaded))
    }

    @Test func presetSelection() {
        #expect(R.preset(isOptedIn: true, isDownloaded: true) == .highQuality)
        #expect(R.preset(isOptedIn: true, isDownloaded: false) == .lightweight)
        #expect(R.preset(isOptedIn: false, isDownloaded: true) == .lightweight)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd Packages/Domain && xcodebuild test -scheme Domain-Package -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:DomainTests/SoundfontDownloadReducerTests`
Expected: FAIL — `cannot find 'SoundfontDownloadReducer' in scope`.

- [ ] **Step 3: Write the reducer**

```swift
/// Pure decision logic for the high-quality SoundFont download — the single source of truth shared by the iOS
/// `LiveMuseScoreGeneralProvider` and the Android `MuseScoreGeneralAndroidStore`. No I/O, no Foundation networking;
/// callers supply the facts (file presence, reachability) and apply the verdicts.
public enum SoundfontDownloadReducer {
    /// Next state given the current state and an event.
    public static func nextState(
        _ current: SoundfontDownloadState,
        on event: SoundfontDownloadEvent,
    ) -> SoundfontDownloadState {
        switch event {
        case .started:
            return .downloading(progress: 0)
        case let .progress(fraction):
            return .downloading(progress: min(1, max(0, fraction)))
        case .finished:
            return .downloaded
        case let .failed(reason):
            return .failed(reason: reason)
        case let .cancelled(fileExists):
            return fileExists ? .downloaded : .idle
        case let .syncedFromDisk(fileExists):
            return fileExists ? .downloaded : .idle
        }
    }

    /// Whether an automatic (Wi-Fi-only) download should begin now. Mirrors the iOS `startDownloadIfNeeded` guards:
    /// opted in, file absent, nothing already in flight, and currently on Wi-Fi.
    public static func shouldAutoStart(
        isOptedIn: Bool,
        fileExists: Bool,
        isDownloading: Bool,
        isWiFi: Bool,
    ) -> Bool {
        isOptedIn && !fileExists && !isDownloading && isWiFi
    }

    /// Whether to auto-retry when Wi-Fi becomes reachable — only when the last attempt failed.
    public static func shouldRetryOnWiFi(_ current: SoundfontDownloadState) -> Bool {
        if case .failed = current { return true }
        return false
    }

    /// Currently-effective preset: high quality only when opted in AND the file is downloaded.
    public static func preset(isOptedIn: Bool, isDownloaded: Bool) -> SoundfontPreset {
        (isOptedIn && isDownloaded) ? .highQuality : .lightweight
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: same command as Step 2.
Expected: PASS (all cases).

- [ ] **Step 5: Commit**

```bash
git add Packages/Domain/Sources/Domain/Logic/SoundfontDownloadReducer.swift Packages/Domain/Tests/DomainTests/SoundfontDownloadReducerTests.swift
git commit -m "feat(domain): add pure SoundfontDownloadReducer with unit tests"
```

---

## Phase 1 — iOS provider drives the shared reducer (behavior-preserving)

### Task 3: Route iOS provider state through the reducer

**Files:**
- Modify: `Packages/Infrastructure/Sources/Soundfonts/LiveMuseScoreGeneralProvider.swift`

- [ ] **Step 1: Replace `currentPreset` with the shared reducer**

In `LiveMuseScoreGeneralProvider`, change:

```swift
    public var currentPreset: SoundfontPreset {
        (isOptedIn && isDownloaded) ? .highQuality : .lightweight
    }
```

to:

```swift
    public var currentPreset: SoundfontPreset {
        SoundfontDownloadReducer.preset(isOptedIn: isOptedIn, isDownloaded: isDownloaded)
    }
```

- [ ] **Step 2: Route the auto-start guard through the reducer**

Change `startDownloadIfNeeded()`:

```swift
    public func startDownloadIfNeeded() {
        guard isOptedIn else { return }
        if FileManager.default.fileExists(atPath: targetFileURL.path) {
            downloadState = .downloaded
            return
        }
        guard activeTask == nil else { return }
        guard pathMonitor.isCurrentlyWiFi else { return }
        startDownload(session: wifiSession)
    }
```

to:

```swift
    public func startDownloadIfNeeded() {
        let fileExists = FileManager.default.fileExists(atPath: targetFileURL.path)
        if fileExists {
            downloadState = SoundfontDownloadReducer.nextState(downloadState, on: .syncedFromDisk(fileExists: true))
            return
        }
        guard SoundfontDownloadReducer.shouldAutoStart(
            isOptedIn: isOptedIn,
            fileExists: fileExists,
            isDownloading: activeTask != nil,
            isWiFi: pathMonitor.isCurrentlyWiFi,
        ) else { return }
        startDownload(session: wifiSession)
    }
```

- [ ] **Step 3: Route the delegate callbacks and cancel through the reducer**

Change `updateProgress`, `cancelDownload`, `deleteDownloaded`, and `handlePathChange` to use the reducer:

```swift
    fileprivate func updateProgress(bytesWritten: Int64, expected: Int64) {
        guard expected > 0 else { return }
        downloadState = SoundfontDownloadReducer.nextState(
            downloadState, on: .progress(fraction: Double(bytesWritten) / Double(expected)),
        )
    }
```

```swift
    public func cancelDownload() {
        activeTask?.cancel()
        activeTask = nil
        activeDelegate = nil
        let exists = FileManager.default.fileExists(atPath: targetFileURL.path)
        downloadState = SoundfontDownloadReducer.nextState(downloadState, on: .cancelled(fileExists: exists))
    }
```

```swift
    public func deleteDownloaded() {
        try? FileManager.default.removeItem(at: targetFileURL)
        downloadState = SoundfontDownloadReducer.nextState(downloadState, on: .syncedFromDisk(fileExists: false))
    }
```

```swift
    private func handlePathChange(isWiFi: Bool) {
        guard isWiFi else { return }
        if SoundfontDownloadReducer.shouldRetryOnWiFi(downloadState) {
            startDownloadIfNeeded()
        }
    }
```

Also in `startDownload(session:)` replace `downloadState = .downloading(progress: 0)` with:

```swift
        downloadState = SoundfontDownloadReducer.nextState(downloadState, on: .started)
```

and in `handleDownloadFinished` replace the success `downloadState = .downloaded` with:

```swift
            downloadState = SoundfontDownloadReducer.nextState(downloadState, on: .finished)
```

(Leave the `catch`/`handleDownloadFailed` branches that set `.failed(reason:)` as-is — they already mirror `nextState(.failed)`; converting them is optional and not required for parity.)

- [ ] **Step 4: Run the existing iOS provider tests to verify no regression**

Run: `cd Packages/Infrastructure && xcodebuild test -scheme Infrastructure-Package -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:InfrastructureTests/LiveMuseScoreGeneralProviderTests`
Expected: PASS — all existing cases still green (default opt-in, toggle cancel/delete, Wi-Fi gating, progress, success+install, cellular override, failure→auto-retry).

- [ ] **Step 5: Commit**

```bash
git add Packages/Infrastructure/Sources/Soundfonts/LiveMuseScoreGeneralProvider.swift
git commit -m "refactor(ios): drive soundfont provider state through shared reducer"
```

---

## Phase 2 — `FolinoSoundfontJNI` Swift bridge

### Task 4: Wire `FolinoSoundfontJNI` product into Infrastructure Package.swift

**Files:**
- Modify: `Packages/Infrastructure/Package.swift`

- [ ] **Step 1: Add the Android-only block**

Mirror the Library package's `if isAndroid` gate. Near the top of `Package.swift`, ensure an `isAndroid` flag exists (copy from `Packages/Features/Library/Package.swift` if Infrastructure does not have one):

```swift
import Foundation
let isAndroid = Context.environment["FOLINO_ANDROID"] == "1"
```

Then append, after the existing iOS products/targets are assembled (use the same `products += [...]` / `targets += [...]` accumulation shape the file already uses; if the file uses inline literals, convert the `products:`/`targets:`/`dependencies:` arrays to `var` accumulators first, mirroring Library):

```swift
if isAndroid {
    packageDependencies += [
        // swiftlint:disable:next line_length
        .package(url: "https://github.com/jiyimeta/swift-wirelet.git", revision: "ba1b8e337a508079c5213656e4c01e9edbedc8b4"),
        .package(path: "../Domain"),
    ]
    products += [
        .library(name: "FolinoSoundfontJNI", type: .dynamic, targets: ["FolinoSoundfontJNI"]),
    ]
    targets += [
        .target(
            name: "FolinoSoundfontJNI",
            dependencies: [
                "Domain",
                .product(name: "Wirelet", package: "swift-wirelet"),
                .product(name: "WireletObservable", package: "swift-wirelet"),
                .product(name: "WireletProvided", package: "swift-wirelet"),
            ],
            plugins: [
                .plugin(name: "WireletObservableBridges", package: "swift-wirelet"),
                .plugin(name: "WireletProvidedBridges", package: "swift-wirelet"),
            ],
        ),
    ]
}
```

(Use the same swift-wirelet revision the Library package currently pins — verify it matches `Packages/Features/Library/Package.swift` at implementation time; if Library has advanced, match that revision so the two `.so`s share one wirelet runtime.)

- [ ] **Step 2: Verify the package still resolves on the host (iOS path unaffected)**

Run: `cd Packages/Infrastructure && swift package dump-package > /dev/null`
Expected: no error (the `isAndroid` block is inert without `FOLINO_ANDROID=1`).

- [ ] **Step 3: Commit**

```bash
git add Packages/Infrastructure/Package.swift
git commit -m "build(android): add FolinoSoundfontJNI product to Infrastructure package"
```

### Task 5: Wire-format types for the bridge

**Files:**
- Create: `Packages/Infrastructure/Sources/FolinoSoundfontJNI/SoundfontWire.swift`

- [ ] **Step 1: Write the wire types**

```swift
import WireletProvided

/// Wire projection of the download state for Compose. Wirelet's `@WireletObservable` cannot bridge a Swift enum
/// with associated values, so the store exposes these flattened fields and the Kotlin UI reconstructs a sealed
/// state from `statusRaw` + `progress` + `failureReason`.
///
/// `statusRaw` is one of: "idle", "downloading", "downloaded", "failed".
@WireFormat
public struct SoundfontStateWire: Equatable, Sendable {
    public var statusRaw: String
    public var progress: Double // meaningful when statusRaw == "downloading"; else 0
    public var failureReason: String // non-empty when statusRaw == "failed"; else ""

    public init(statusRaw: String, progress: Double, failureReason: String) {
        self.statusRaw = statusRaw
        self.progress = progress
        self.failureReason = failureReason
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add Packages/Infrastructure/Sources/FolinoSoundfontJNI/SoundfontWire.swift
git commit -m "feat(android): add SoundfontStateWire wire-format type"
```

### Task 6: `@WireletProvided` service interfaces

**Files:**
- Create: `Packages/Infrastructure/Sources/FolinoSoundfontJNI/SoundfontServices.swift`

- [ ] **Step 1: Write the provided interfaces**

```swift
import WireletProvided

/// Kotlin-implemented HTTP transport for the high-quality SF2. The Swift store calls `start`/`cancel`; the Kotlin
/// implementation reports progress and terminal events by calling back into the store's `@WireletExpose`
/// `ingestProgress` / `ingestFinished` / `ingestFailed` methods (no Swift closures cross the bridge).
@WireletProvided
public protocol SoundfontDownloader {
    /// Begin downloading `remoteURL` to `destinationPath`. `allowCellular` chooses the network policy
    /// (false = Wi-Fi only). Must be idempotent if a transfer is already running.
    func start(remoteURL: String, destinationPath: String, allowCellular: Bool)
    /// Cancel any in-flight transfer and remove partial output.
    func cancel()
}

/// Kotlin-implemented reachability. `isWiFi` is a synchronous snapshot; `startObserving` registers a callback that
/// invokes the store's `@WireletExpose onReachabilityChanged(_:)` on every Wi-Fi transition.
@WireletProvided
public protocol SoundfontReachability {
    func isWiFi() -> Bool
    func startObserving()
}

/// Kotlin-implemented persistence + storage location. `loadOptedIn` defaults to `true` on first launch (parity with
/// iOS UserDefaults default). `soundfontsDirectoryPath` is `filesDir/Soundfonts` (created by the Kotlin impl).
@WireletProvided
public protocol SoundfontPrefsStore {
    func loadOptedIn() -> Bool
    func saveOptedIn(value: Bool)
    func soundfontsDirectoryPath() -> String
}
```

- [ ] **Step 2: Commit**

```bash
git add Packages/Infrastructure/Sources/FolinoSoundfontJNI/SoundfontServices.swift
git commit -m "feat(android): add @WireletProvided soundfont service interfaces"
```

### Task 7: `@WireletObservable` Android store

**Files:**
- Create: `Packages/Infrastructure/Sources/FolinoSoundfontJNI/MuseScoreGeneralAndroidStore.swift`

- [ ] **Step 1: Write the store**

```swift
import Domain
import Foundation
import Observation
import WireletObservable

/// Android-side high-quality SoundFont provider, mirroring iOS `LiveMuseScoreGeneralProvider` but with transport,
/// reachability, and persistence injected from Kotlin. State transitions, Wi-Fi gating, auto-retry, and preset
/// selection all run through the shared `SoundfontDownloadReducer`, so behavior matches iOS exactly.
///
/// Exposes flattened state to Compose (`stateWire`, `isOptedIn`, `presetRaw`) because Wirelet cannot bridge an
/// enum with associated values.
@WireletObservable
@Observable
public final class MuseScoreGeneralAndroidStore {
    @ObservationIgnored private let downloader: SoundfontDownloader
    @ObservationIgnored private let reachability: SoundfontReachability
    @ObservationIgnored private let prefs: SoundfontPrefsStore
    // swiftlint:disable:next line_length
    @ObservationIgnored private let remoteURL = "https://github.com/jiyimeta/musescore-general-sf2-split/releases/download/unsplit/MuseScore_General.sf2"

    public var stateWire: SoundfontStateWire = .init(statusRaw: "idle", progress: 0, failureReason: "")
    public var isOptedIn: Bool = true
    public var presetRaw: String = SoundfontPreset.lightweight.rawValue

    @ObservationIgnored private var downloadState: SoundfontDownloadState = .idle {
        didSet { stateWire = Self.wire(downloadState); recomputePreset() }
    }

    public init(downloader: SoundfontDownloader, reachability: SoundfontReachability, prefs: SoundfontPrefsStore) {
        self.downloader = downloader
        self.reachability = reachability
        self.prefs = prefs
        isOptedIn = prefs.loadOptedIn()
        downloadState = FileManager.default.fileExists(atPath: targetFilePath) ? .downloaded : .idle
        recomputePreset()
        reachability.startObserving()
        startDownloadIfNeeded()
    }

    // MARK: - Derived

    private var soundfontsDir: String { prefs.soundfontsDirectoryPath() }
    private var targetFilePath: String { "\(soundfontsDir)/\(SoundfontPreset.highQuality.fileName)" }
    private var isDownloaded: Bool {
        if case .downloaded = downloadState { return true }
        return false
    }

    private func recomputePreset() {
        presetRaw = SoundfontDownloadReducer.preset(isOptedIn: isOptedIn, isDownloaded: isDownloaded).rawValue
    }

    private static func wire(_ state: SoundfontDownloadState) -> SoundfontStateWire {
        switch state {
        case .idle: .init(statusRaw: "idle", progress: 0, failureReason: "")
        case let .downloading(progress): .init(statusRaw: "downloading", progress: progress, failureReason: "")
        case .downloaded: .init(statusRaw: "downloaded", progress: 0, failureReason: "")
        case let .failed(reason): .init(statusRaw: "failed", progress: 0, failureReason: reason)
        }
    }

    // MARK: - Commands (Kotlin → Swift)

    @WireletExpose
    public func setOptedIn(value: Bool) {
        prefs.saveOptedIn(value: value)
        isOptedIn = value
        recomputePreset()
        if value {
            startDownloadIfNeeded()
        } else {
            cancelDownload()
            deleteDownloaded()
        }
    }

    @WireletExpose
    public func startDownloadIfNeeded() {
        let exists = FileManager.default.fileExists(atPath: targetFilePath)
        if exists {
            downloadState = SoundfontDownloadReducer.nextState(downloadState, on: .syncedFromDisk(fileExists: true))
            return
        }
        guard SoundfontDownloadReducer.shouldAutoStart(
            isOptedIn: isOptedIn,
            fileExists: exists,
            isDownloading: isDownloadingNow,
            isWiFi: reachability.isWiFi(),
        ) else { return }
        beginDownload(allowCellular: false)
    }

    @WireletExpose
    public func startDownloadAllowingCellular() {
        if FileManager.default.fileExists(atPath: targetFilePath) {
            downloadState = SoundfontDownloadReducer.nextState(downloadState, on: .syncedFromDisk(fileExists: true))
            return
        }
        guard !isDownloadingNow else { return }
        beginDownload(allowCellular: true)
    }

    @WireletExpose
    public func cancelDownload() {
        downloader.cancel()
        let exists = FileManager.default.fileExists(atPath: targetFilePath)
        downloadState = SoundfontDownloadReducer.nextState(downloadState, on: .cancelled(fileExists: exists))
    }

    @WireletExpose
    public func deleteDownloaded() {
        try? FileManager.default.removeItem(atPath: targetFilePath)
        downloadState = SoundfontDownloadReducer.nextState(downloadState, on: .syncedFromDisk(fileExists: false))
    }

    /// Absolute path of the downloaded high-quality SF2 if present, else empty string. Read by the Kotlin resolver.
    @WireletExpose
    public func highQualityFilePath() -> String {
        FileManager.default.fileExists(atPath: targetFilePath) ? targetFilePath : ""
    }

    // MARK: - Ingest (Kotlin downloader / reachability → Swift)

    @WireletExpose
    public func ingestProgress(fraction: Double) {
        downloadState = SoundfontDownloadReducer.nextState(downloadState, on: .progress(fraction: fraction))
    }

    @WireletExpose
    public func ingestFinished() {
        downloadState = SoundfontDownloadReducer.nextState(downloadState, on: .finished)
    }

    @WireletExpose
    public func ingestFailed(reason: String) {
        downloadState = SoundfontDownloadReducer.nextState(downloadState, on: .failed(reason: reason))
    }

    @WireletExpose
    public func onReachabilityChanged(isWiFi: Bool) {
        guard isWiFi else { return }
        if SoundfontDownloadReducer.shouldRetryOnWiFi(downloadState) {
            startDownloadIfNeeded()
        }
    }

    // MARK: - Private

    private var isDownloadingNow: Bool {
        if case .downloading = downloadState { return true }
        return false
    }

    private func beginDownload(allowCellular: Bool) {
        try? FileManager.default.createDirectory(
            atPath: soundfontsDir, withIntermediateDirectories: true,
        )
        downloadState = SoundfontDownloadReducer.nextState(downloadState, on: .started)
        downloader.start(remoteURL: remoteURL, destinationPath: targetFilePath, allowCellular: allowCellular)
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add Packages/Infrastructure/Sources/FolinoSoundfontJNI/MuseScoreGeneralAndroidStore.swift
git commit -m "feat(android): add MuseScoreGeneralAndroidStore wirelet bridge"
```

---

## Phase 3 — Build script + Gradle module

### Task 8: Build script for `FolinoSoundfontJNI`

**Files:**
- Create: `Scripts/android-build-soundfont-libs.sh`

- [ ] **Step 1: Write the script (mirror `android-build-library-libs.sh`)**

```bash
#!/usr/bin/env bash
# Build FolinoSoundfontJNI for each enabled Android ABI and stage .so files
# (plus Swift runtime + libc++_shared.so) into
# Android/FolinoSoundfontAndroid/src/main/jniLibs/.
set -euo pipefail

: "${TOOLCHAINS:=org.swift.632202605101a}"
export TOOLCHAINS
export FOLINO_ANDROID=1

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
PKG_PATH="$ROOT/Packages/Infrastructure"
JNI_DIR="$ROOT/Android/FolinoSoundfontAndroid/src/main/jniLibs"
SDK_BUNDLE="$HOME/Library/org.swift.swiftpm/swift-sdks/swift-6.3.2-RELEASE_android.artifactbundle"
RUNTIME_BASE="$SDK_BUNDLE/swift-android/swift-resources/usr/lib"

if [[ -z "${ANDROID_NDK_HOME:-}" ]]; then
    sdk_root="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
    if [[ -d "$sdk_root/ndk" ]]; then
        ANDROID_NDK_HOME="$(ls -d "$sdk_root"/ndk/*/ 2>/dev/null | sort -V | tail -1 | sed 's:/$::')"
    fi
fi
if [[ -z "${ANDROID_NDK_HOME:-}" || ! -d "$ANDROID_NDK_HOME" ]]; then
    echo "error: could not locate Android NDK; set ANDROID_NDK_HOME" >&2
    exit 1
fi
NDK_LIB_BASE="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/darwin-x86_64/sysroot/usr/lib"

mkdir -p "$JNI_DIR"

TARGETS=(
    "aarch64-unknown-linux-android28:arm64-v8a:swift-aarch64:aarch64-linux-android"
    "x86_64-unknown-linux-android28:x86_64:swift-x86_64:x86_64-linux-android"
)
FOLINO_ANDROID_ABIS="${FOLINO_ANDROID_ABIS:-arm64-v8a,x86_64}"
filtered=()
for entry in "${TARGETS[@]}"; do
    rest="${entry#*:}"; abi="${rest%%:*}"
    [[ ",${FOLINO_ANDROID_ABIS}," == *",${abi},"* ]] && filtered+=("$entry")
done
TARGETS=("${filtered[@]}")

for entry in "${TARGETS[@]}"; do
    triple="${entry%%:*}"; rest="${entry#*:}"
    abi="${rest%%:*}"; rest="${rest#*:}"
    arch="${rest%%:*}"; ndk_triple="${rest#*:}"

    echo "==> Building libFolinoSoundfontJNI.so for $abi ($triple)"
    swift build --package-path "$PKG_PATH" \
                --product FolinoSoundfontJNI \
                --swift-sdk "$triple" \
                -c release

    src_so="$PKG_PATH/.build/$triple/release/libFolinoSoundfontJNI.so"
    dst_dir="$JNI_DIR/$abi"
    rm -rf "$dst_dir"; mkdir -p "$dst_dir"
    cp "$src_so" "$dst_dir/"

    runtime_src="$RUNTIME_BASE/$arch/android"
    [[ -d "$runtime_src" ]] || { echo "error: Swift runtime not found at $runtime_src" >&2; exit 1; }
    for so in "$runtime_src"/*.so; do
        name="$(basename "$so")"
        case "$name" in
            libTesting.so|libXCTest.so|lib_Testing_Foundation.so|lib_TestingInterop.so) continue ;;
        esac
        cp -L "$so" "$dst_dir/"
    done

    ndk_libcxx="$NDK_LIB_BASE/$ndk_triple/libc++_shared.so"
    [[ -f "$ndk_libcxx" ]] && cp -L "$ndk_libcxx" "$dst_dir/" || { echo "error: libc++_shared.so not found at $ndk_libcxx" >&2; exit 1; }
done

echo "Done. libFolinoSoundfontJNI.so + runtime staged under $JNI_DIR/{arm64-v8a,x86_64}/"
```

- [ ] **Step 2: Make it executable**

Run: `chmod +x Scripts/android-build-soundfont-libs.sh`
Expected: no output.

- [ ] **Step 3: Commit**

```bash
git add Scripts/android-build-soundfont-libs.sh
git commit -m "build(android): add android-build-soundfont-libs.sh"
```

### Task 9: Gradle module `FolinoSoundfontAndroid`

**Files:**
- Create: `Android/FolinoSoundfontAndroid/build.gradle.kts`
- Create: `Android/FolinoSoundfontAndroid/src/main/AndroidManifest.xml`
- Modify: `Android/settings.gradle.kts`

- [ ] **Step 1: Write the module build script (mirror `FolinoLibraryAndroid/build.gradle.kts`)**

```kotlin
plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
    id("io.github.jiyimeta.wirelet") version "0.3.2"
}

android {
    namespace = "com.keynumber.folino.soundfont"
    compileSdk = 35

    defaultConfig {
        minSdk = 28
        ndk { abiFilters += listOf("arm64-v8a", "x86_64") }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }

    sourceSets["main"].jniLibs.srcDirs("src/main/jniLibs")
}

dependencies {
    api("io.github.jiyimeta:wirelet-runtime:0.3.2")
    api("io.github.jiyimeta:wirelet-observable-runtime:0.3.2")
    api("androidx.lifecycle:lifecycle-viewmodel:2.8.7")
    api("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")
}

val packageRoot: File = rootProject.projectDir.resolve("..").canonicalFile

wirelet {
    val infraCheckout = packageRoot.resolve("Packages/Infrastructure/.build/checkouts/swift-wirelet")
    val rootCheckout = packageRoot.resolve(".build/checkouts/swift-wirelet")
    swiftPackagePath.set(if (infraCheckout.exists()) infraCheckout else rootCheckout)

    sources {
        register("main") {
            schemaPaths.from(packageRoot.resolve("Packages/Infrastructure/Sources/FolinoSoundfontJNI"))
            codecPackage.set("com.keynumber.folino.soundfont")
            modelPackage.set("com.keynumber.folino.soundfont")
            emitModels.set(true)
        }
    }
    observable {
        register("main") {
            schemaPaths.from(packageRoot.resolve("Packages/Infrastructure/Sources/FolinoSoundfontJNI"))
            viewModelPackage.set("com.keynumber.folino.soundfont.generated")
            modelPackage.set("com.keynumber.folino.soundfont")
            codecPackage.set("com.keynumber.folino.soundfont")
            libraryName.set("FolinoSoundfontJNI")
            providedAdapterPackage.set("com.keynumber.folino.soundfont")
        }
    }
    provided {
        register("main") {
            schemaPaths.from(packageRoot.resolve("Packages/Infrastructure/Sources/FolinoSoundfontJNI"))
            interfacePackage.set("com.keynumber.folino.soundfont")
            adapterPackage.set("com.keynumber.folino.soundfont")
            modelPackage.set("com.keynumber.folino.soundfont")
            codecPackage.set("com.keynumber.folino.soundfont")
        }
    }
}

val generateCodecs = tasks.named("generateWireletCodecsMain")
val generateViewModels = tasks.named("generateWireletObservableViewModelsMain")
val generateProvided = tasks.named("generateWireletProvidedInterfacesMain")

android {
    sourceSets["main"].kotlin.srcDir(
        generateCodecs.flatMap { (it as io.github.jiyimeta.wirelet.gradle.GenerateWireletCodecs).outputDir }
    )
    sourceSets["main"].kotlin.srcDir(
        generateViewModels.flatMap { (it as io.github.jiyimeta.wirelet.gradle.GenerateWireletObservableViewModels).outputDir }
    )
    sourceSets["main"].kotlin.srcDir(
        generateProvided.flatMap { (it as io.github.jiyimeta.wirelet.gradle.GenerateWireletProvidedInterfaces).outputDir }
    )
}

tasks.matching { it.name.startsWith("compile") && it.name.endsWith("Kotlin") }
    .configureEach { dependsOn(generateCodecs, generateViewModels, generateProvided) }
```

- [ ] **Step 2: Write the manifest (declares the network-state permission used by the reachability service)**

```xml
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />
    <uses-permission android:name="android.permission.INTERNET" />
</manifest>
```

- [ ] **Step 3: Register the module in settings.gradle.kts**

In `Android/settings.gradle.kts`, add after `include(":FolinoLibraryAndroid")`:

```kotlin
include(":FolinoSoundfontAndroid")
```

- [ ] **Step 4: Add the module as an app dependency**

In `Android/app/build.gradle.kts`, in the `dependencies { }` block (next to the other `implementation(project(":Folino...Android"))` entries), add:

```kotlin
implementation(project(":FolinoSoundfontAndroid"))
```

- [ ] **Step 5: Generate wirelet bindings, then build the `.so`**

Run (codegen first so the generated Kotlin exists, then the native lib):
```bash
cd Android && ./gradlew :FolinoSoundfontAndroid:generateWireletProvidedInterfacesMain :FolinoSoundfontAndroid:generateWireletObservableViewModelsMain :FolinoSoundfontAndroid:generateWireletCodecsMain
```
Then:
```bash
./Scripts/android-build-soundfont-libs.sh
```
Expected: `libFolinoSoundfontJNI.so` staged under `Android/FolinoSoundfontAndroid/src/main/jniLibs/{arm64-v8a,x86_64}/`, and generated `SoundfontDownloader` / `SoundfontReachability` / `SoundfontPrefsStore` interfaces + `MuseScoreGeneralAndroidStoreViewModel` under the module's build/generated dir.

- [ ] **Step 6: Commit**

```bash
git add Android/FolinoSoundfontAndroid/build.gradle.kts Android/FolinoSoundfontAndroid/src/main/AndroidManifest.xml Android/settings.gradle.kts Android/app/build.gradle.kts
git commit -m "build(android): add FolinoSoundfontAndroid gradle module"
```

---

## Phase 4 — Kotlin platform services

### Task 10: DataStore-backed prefs store

**Files:**
- Create: `Android/FolinoSoundfontAndroid/src/main/kotlin/com/keynumber/folino/soundfont/SoundfontPrefsStoreImpl.kt`

- [ ] **Step 1: Write the impl (implements the generated `SoundfontPrefsStore` interface)**

```kotlin
package com.keynumber.folino.soundfont

import android.content.Context
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.preferencesDataStore
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.runBlocking
import java.io.File

private val Context.soundfontDataStore by preferencesDataStore(name = "folino_soundfont")
private val OPTED_IN = booleanPreferencesKey("soundfont.museScoreGeneral.optedIn")

/**
 * Kotlin implementation of the generated `@WireletProvided` `SoundfontPrefsStore` interface. Persists the opt-in
 * flag in DataStore (default `true`, parity with iOS UserDefaults) and owns the `filesDir/Soundfonts` location.
 *
 * The Swift store calls these synchronously on the JNI thread, so reads/writes block on the DataStore flow. The
 * payload is a single boolean, so the cost is negligible.
 */
class SoundfontPrefsStoreImpl(context: Context) : SoundfontPrefsStore {
    private val appContext = context.applicationContext
    private val dir: File = File(appContext.filesDir, "Soundfonts").apply { mkdirs() }

    override fun loadOptedIn(): Boolean = runBlocking {
        appContext.soundfontDataStore.data.first()[OPTED_IN] ?: true
    }

    override fun saveOptedIn(value: Boolean): Unit = runBlocking {
        appContext.soundfontDataStore.edit { it[OPTED_IN] = value }
        Unit
    }

    override fun soundfontsDirectoryPath(): String = dir.absolutePath
}
```

- [ ] **Step 2: Commit**

```bash
git add Android/FolinoSoundfontAndroid/src/main/kotlin/com/keynumber/folino/soundfont/SoundfontPrefsStoreImpl.kt
git commit -m "feat(android): add DataStore-backed SoundfontPrefsStore impl"
```

### Task 11: Network reachability service

**Files:**
- Create: `Android/FolinoSoundfontAndroid/src/main/kotlin/com/keynumber/folino/soundfont/AndroidNetworkReachability.kt`

- [ ] **Step 1: Write the impl**

```kotlin
package com.keynumber.folino.soundfont

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest

/**
 * Kotlin implementation of the generated `@WireletProvided` `SoundfontReachability` interface over
 * `ConnectivityManager`. `isWiFi` is a synchronous snapshot; `startObserving` registers a callback that pushes
 * Wi-Fi transitions back into the Swift store via [onReachabilityChanged].
 *
 * @param onReachabilityChanged invoked with the new Wi-Fi state on every transition. Wired to the generated
 *   ViewModel's `onReachabilityChanged(isWiFi:)` at construction.
 */
class AndroidNetworkReachability(
    context: Context,
    private val onReachabilityChanged: (Boolean) -> Unit,
) : SoundfontReachability {
    private val cm =
        context.applicationContext.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager

    override fun isWiFi(): Boolean {
        val network = cm.activeNetwork ?: return false
        val caps = cm.getNetworkCapabilities(network) ?: return false
        return caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) &&
            caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED)
    }

    override fun startObserving() {
        val request = NetworkRequest.Builder()
            .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .build()
        cm.registerNetworkCallback(request, object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) = onReachabilityChanged(isWiFi())
            override fun onLost(network: Network) = onReachabilityChanged(isWiFi())
            override fun onCapabilitiesChanged(network: Network, caps: NetworkCapabilities) =
                onReachabilityChanged(isWiFi())
        })
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add Android/FolinoSoundfontAndroid/src/main/kotlin/com/keynumber/folino/soundfont/AndroidNetworkReachability.kt
git commit -m "feat(android): add ConnectivityManager-backed reachability service"
```

### Task 12: DownloadManager-backed downloader

**Files:**
- Create: `Android/FolinoSoundfontAndroid/src/main/kotlin/com/keynumber/folino/soundfont/AndroidSoundfontDownloader.kt`

- [ ] **Step 1: Write the impl**

```kotlin
package com.keynumber.folino.soundfont

import android.app.DownloadManager
import android.content.Context
import android.database.Cursor
import android.net.Uri
import androidx.core.net.toUri
import java.io.File
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

/**
 * Kotlin implementation of the generated `@WireletProvided` `SoundfontDownloader` interface using the system
 * `DownloadManager` (resilient for a ~206 MB transfer). Progress and terminal events are pushed back into the
 * Swift store via the [onProgress] / [onFinished] / [onFailed] callbacks (wired to the ViewModel's
 * `ingestProgress` / `ingestFinished` / `ingestFailed`).
 *
 * `DownloadManager` writes to its own staging location; on success the file is moved to [destinationPath] the
 * store handed us, then [onFinished] fires. A coroutine polls progress every 500 ms while the transfer runs.
 */
class AndroidSoundfontDownloader(
    context: Context,
    private val onProgress: (Double) -> Unit,
    private val onFinished: () -> Unit,
    private val onFailed: (String) -> Unit,
) : SoundfontDownloader {
    private val appContext = context.applicationContext
    private val dm = appContext.getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager
    private val scope = CoroutineScope(Dispatchers.IO)
    private var pollJob: Job? = null
    private var currentId: Long = -1L

    override fun start(remoteURL: String, destinationPath: String, allowCellular: Boolean) {
        if (currentId != -1L) return // idempotent: a transfer is already running
        val staging = File(appContext.cacheDir, "MuseScore_General.sf2.part")
        staging.delete()
        val request = DownloadManager.Request(remoteURL.toUri())
            .setDestinationUri(Uri.fromFile(staging))
            .setAllowedNetworkTypes(
                if (allowCellular) {
                    DownloadManager.Request.NETWORK_WIFI or DownloadManager.Request.NETWORK_MOBILE
                } else {
                    DownloadManager.Request.NETWORK_WIFI
                },
            )
            .setNotificationVisibility(DownloadManager.Request.VISIBILITY_HIDDEN)
        currentId = dm.enqueue(request)
        pollJob = scope.launch { poll(staging, File(destinationPath)) }
    }

    override fun cancel() {
        pollJob?.cancel()
        pollJob = null
        if (currentId != -1L) {
            dm.remove(currentId)
            currentId = -1L
        }
    }

    private suspend fun poll(staging: File, destination: File) {
        while (scope.isActive && currentId != -1L) {
            val query = DownloadManager.Query().setFilterById(currentId)
            dm.query(query).use { c: Cursor ->
                if (!c.moveToFirst()) {
                    finish(failure = "download not found")
                    return
                }
                val status = c.getInt(c.getColumnIndexOrThrow(DownloadManager.COLUMN_STATUS))
                when (status) {
                    DownloadManager.STATUS_SUCCESSFUL -> {
                        destination.parentFile?.mkdirs()
                        staging.copyTo(destination, overwrite = true)
                        staging.delete()
                        finish(failure = null)
                        return
                    }
                    DownloadManager.STATUS_FAILED -> {
                        val reason = c.getInt(c.getColumnIndexOrThrow(DownloadManager.COLUMN_REASON))
                        finish(failure = "download failed (reason $reason)")
                        return
                    }
                    else -> {
                        val soFar = c.getLong(
                            c.getColumnIndexOrThrow(DownloadManager.COLUMN_BYTES_DOWNLOADED_SO_FAR),
                        )
                        val total = c.getLong(
                            c.getColumnIndexOrThrow(DownloadManager.COLUMN_TOTAL_SIZE_BYTES),
                        )
                        if (total > 0) onProgress(soFar.toDouble() / total.toDouble())
                    }
                }
            }
            delay(500)
        }
    }

    private fun finish(failure: String?) {
        currentId = -1L
        pollJob = null
        if (failure == null) onFinished() else onFailed(failure)
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add Android/FolinoSoundfontAndroid/src/main/kotlin/com/keynumber/folino/soundfont/AndroidSoundfontDownloader.kt
git commit -m "feat(android): add DownloadManager-backed soundfont downloader"
```

### Task 13: Compose-facing wrapper that builds the store + holds a shared instance

**Files:**
- Create: `Android/FolinoSoundfontAndroid/src/main/kotlin/com/keynumber/folino/soundfont/SoundfontController.kt`

- [ ] **Step 1: Write the controller**

The generated `MuseScoreGeneralAndroidStoreViewModel.create(...)` (companion factory, mirroring `LibraryAndroidStoreViewModel.create`) takes the three `@WireletProvided` services. The reachability and downloader need to call back into the ViewModel's `@WireletExpose` ingest methods, so we build the ViewModel first, then construct the services bound to it. Because the services reference the ViewModel and the ViewModel's `create` needs the services, build the downloader/reachability with a deferred reference.

```kotlin
package com.keynumber.folino.soundfont

import android.content.Context
import com.keynumber.folino.soundfont.generated.MuseScoreGeneralAndroidStoreViewModel

/**
 * Process-wide owner of the soundfont download bridge. Builds the `@WireletProvided` Kotlin services, wires their
 * callbacks to the generated ViewModel's `@WireletExpose` ingest methods, and exposes the ViewModel for Compose
 * and the singleton store for the audio resolver / playback service.
 *
 * Single instance per process (the high-quality SF2 is global). Construct once from `MainActivity` (or an
 * Application) and reuse.
 */
object SoundfontController {
    @Volatile private var vm: MuseScoreGeneralAndroidStoreViewModel? = null

    fun viewModel(context: Context): MuseScoreGeneralAndroidStoreViewModel =
        vm ?: synchronized(this) { vm ?: build(context).also { vm = it } }

    private fun build(context: Context): MuseScoreGeneralAndroidStoreViewModel {
        val app = context.applicationContext
        // Late-bound holder so the services can call into the ViewModel that is constructed with them.
        val holder = arrayOfNulls<MuseScoreGeneralAndroidStoreViewModel>(1)
        val downloader = AndroidSoundfontDownloader(
            context = app,
            onProgress = { holder[0]?.ingestProgress(it) },
            onFinished = { holder[0]?.ingestFinished() },
            onFailed = { holder[0]?.ingestFailed(it) },
        )
        val reachability = AndroidNetworkReachability(
            context = app,
            onReachabilityChanged = { holder[0]?.onReachabilityChanged(it) },
        )
        val prefs = SoundfontPrefsStoreImpl(app)
        val created = MuseScoreGeneralAndroidStoreViewModel.create(downloader, reachability, prefs)
        holder[0] = created
        return created
    }
}
```

> Note for implementer: confirm the generated `@WireletExpose` method names on the ViewModel match (`ingestProgress(Double)`, `ingestFinished()`, `ingestFailed(String)`, `onReachabilityChanged(Boolean)`, `setOptedIn(Boolean)`, `startDownloadIfNeeded()`, `startDownloadAllowingCellular()`, `cancelDownload()`, `deleteDownloaded()`, `highQualityFilePath(): String`). If the wirelet emitter name-mangles (e.g. drops argument labels), adjust the call sites — the generated ViewModel source under `build/generated/.../MuseScoreGeneralAndroidStoreViewModel.kt` is the source of truth.

- [ ] **Step 2: Commit**

```bash
git add Android/FolinoSoundfontAndroid/src/main/kotlin/com/keynumber/folino/soundfont/SoundfontController.kt
git commit -m "feat(android): add SoundfontController wiring services to the bridge"
```

---

## Phase 5 — Compose Settings UI

### Task 14: Soundfont download row + dialogs

**Files:**
- Modify: `Android/app/src/main/kotlin/com/keynumber/folino/ui/settings/SettingsScreen.kt`
- Modify: `Android/app/src/main/AndroidManifest.xml` (add `ACCESS_NETWORK_STATE` if not already inherited via the library module merge — Android merges library manifests, so this is usually unnecessary; verify and add only if a runtime check shows it missing).

- [ ] **Step 1: Add a soundfont state holder read in the Settings composable**

In `SettingsScreen.kt`, obtain the ViewModel and collect its flattened state. Add near the top of the `SettingsScreen` composable (mirroring how `prefs.metronome.collectAsState` is read):

```kotlin
val context = LocalContext.current
val soundfontVM = remember { com.keynumber.folino.soundfont.SoundfontController.viewModel(context) }
val sfState by soundfontVM.stateWire.collectAsStateWithLifecycle()
val sfOptedIn by soundfontVM.isOptedIn.collectAsStateWithLifecycle()
```

(`stateWire` and `isOptedIn` are `StateFlow`s on the generated ViewModel, exactly like `LibraryAndroidStoreViewModel.scores`.)

- [ ] **Step 2: Add the row composable**

Add a new private composable in `SettingsScreen.kt`:

```kotlin
@Composable
private fun SoundfontRow(
    state: SoundfontStateWire,
    optedIn: Boolean,
    isWiFi: Boolean,
    onSetOptedIn: (Boolean) -> Unit,
    onDownloadNow: () -> Unit,
    onStop: () -> Unit,
) {
    var showCellularDialog by remember { mutableStateOf(false) }
    var showDeleteDialog by remember { mutableStateOf(false) }

    val subtitle = when (state.statusRaw) {
        "downloading" -> "Downloading… ${(state.progress * 100).toInt()}%"
        "failed" -> state.failureReason
        "idle" -> if (optedIn) "Waiting for Wi-Fi" else "High-fidelity instruments (≈206 MB)"
        else -> "" // downloaded
    }

    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 8.dp),
    ) {
        Icon(Icons.Filled.Piano, contentDescription = null, modifier = Modifier.padding(end = 12.dp))
        Column(modifier = Modifier.weight(1f)) {
            Text("High-Quality SoundFont")
            if (subtitle.isNotEmpty()) {
                val isError = state.statusRaw == "failed"
                Text(
                    subtitle,
                    style = MaterialTheme.typography.bodySmall,
                    color = if (isError) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.onSurfaceVariant,
                )
                if (state.statusRaw == "idle" && optedIn) {
                    TextButton(onClick = onDownloadNow, contentPadding = PaddingValues(0.dp)) {
                        Text("Download now")
                    }
                }
            }
        }
        when (state.statusRaw) {
            "downloading" -> Row(verticalAlignment = Alignment.CenterVertically) {
                CircularProgressIndicator(progress = { state.progress.toFloat() }, modifier = Modifier.size(24.dp))
                IconButton(onClick = onStop) { Icon(Icons.Filled.Stop, contentDescription = "Stop") }
            }
            "idle" -> if (optedIn) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    CircularProgressIndicator(modifier = Modifier.size(24.dp))
                    IconButton(onClick = onStop) { Icon(Icons.Filled.Stop, contentDescription = "Stop") }
                }
            } else {
                Switch(checked = false, onCheckedChange = { if (it) { if (isWiFi) onSetOptedIn(true) else showCellularDialog = true } })
            }
            "downloaded" -> Switch(checked = true, onCheckedChange = { if (!it) showDeleteDialog = true })
            "failed" -> Switch(checked = false, onCheckedChange = { if (it) onSetOptedIn(true) })
        }
    }

    if (showCellularDialog) {
        AlertDialog(
            onDismissRequest = { showCellularDialog = false },
            title = { Text("No Wi-Fi") },
            text = { Text("The high-quality SoundFont is about 206 MB. Download over cellular now, or wait for Wi-Fi?") },
            confirmButton = {
                TextButton(onClick = { showCellularDialog = false; onDownloadNow() }) {
                    Text("Download over cellular")
                }
            },
            dismissButton = {
                TextButton(onClick = { showCellularDialog = false; onSetOptedIn(true) }) { Text("Wait for Wi-Fi") }
            },
        )
    }
    if (showDeleteDialog) {
        AlertDialog(
            onDismissRequest = { showDeleteDialog = false },
            title = { Text("Delete download") },
            text = { Text("Remove the high-quality SoundFont and use the bundled one?") },
            confirmButton = {
                TextButton(onClick = { showDeleteDialog = false; onSetOptedIn(false) }) { Text("Delete") }
            },
            dismissButton = { TextButton(onClick = { showDeleteDialog = false }) { Text("Cancel") } },
        )
    }
}
```

(Imports needed: `androidx.compose.material.icons.filled.Piano`, `Stop`, `androidx.compose.material3.*`, `androidx.lifecycle.compose.collectAsStateWithLifecycle`, `androidx.compose.ui.platform.LocalContext`. The `CircularProgressIndicator(progress = { ... })` lambda overload is the determinate API in Compose Material3 1.3+.)

- [ ] **Step 3: Place the row in the Reader section**

In the `LazyColumn` Reader section of `SettingsScreen.kt`, after the existing reader rows, add an `item { }` calling the row. For the "download now" gesture pick cellular-allowing start (it bypasses the Wi-Fi gate, matching the iOS `folino-action://download-now` link):

```kotlin
item {
    SoundfontRow(
        state = sfState,
        optedIn = sfOptedIn,
        isWiFi = remember { com.keynumber.folino.soundfont.SoundfontController.viewModel(context) }.let { true }, // see note
        onSetOptedIn = { soundfontVM.setOptedIn(it) },
        onDownloadNow = { soundfontVM.startDownloadAllowingCellular() },
        onStop = { soundfontVM.cancelDownload() },
    )
}
```

> Note: there is no `@WireletObservable` Wi-Fi flag (it is queried synchronously inside the store). For the UI's "is Wi-Fi available right now" check used to decide whether toggling ON should prompt, expose it by adding a tiny `@WireletExpose public func isWiFiNow() -> Bool { reachability.isWiFi() }` to `MuseScoreGeneralAndroidStore` (Task 7) and calling `soundfontVM.isWiFiNow()` here. If you prefer to avoid the extra bridge method, always show the cellular dialog when toggling ON from `idle && !optedIn` (slightly more conservative — one extra confirmation on Wi-Fi). Pick the `isWiFiNow()` approach for true parity.

- [ ] **Step 4: Build the app**

Run: `cd Android && ./gradlew :app:assembleDebug`
Expected: BUILD SUCCESSFUL; the new row compiles and the generated ViewModel resolves.

- [ ] **Step 5: Commit**

```bash
git add Android/app/src/main/kotlin/com/keynumber/folino/ui/settings/SettingsScreen.kt Packages/Infrastructure/Sources/FolinoSoundfontJNI/MuseScoreGeneralAndroidStore.swift
git commit -m "feat(android): add high-quality soundfont row to Settings"
```

---

## Phase 6 — Engine integration & hot-swap

### Task 15: Resolver prefers the downloaded high-quality file

**Files:**
- Modify: `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/FolinoSoundfontResolver.kt`

- [ ] **Step 1: Inject a high-quality path provider and prefer it**

Replace the resolver so it consults a callback for the downloaded file each lookup (no `by lazy` caching of the final URI), falling back to the bundled SF2:

```kotlin
package com.keynumber.folino.reader

import android.content.Context
import android.net.Uri
import androidx.core.net.toUri
import io.github.jiyimeta.sheetmusic.audio.SoundfontResolver
import java.io.File

/**
 * Resolves the SoundFont URI, preferring the downloaded high-quality `MuseScore_General.sf2` when present and
 * opted-in, else the bundled `GeneralUser-GS.sf2` materialized from assets to the cache dir.
 *
 * @param highQualityPath returns the absolute path of the downloaded high-quality SF2, or an empty string when it
 *   should not be used (absent or opted-out). Backed by the soundfont bridge's `highQualityFilePath()`.
 */
class FolinoSoundfontResolver(
    private val context: Context,
    private val highQualityPath: () -> String,
) : SoundfontResolver {

    private val bundledUri: Uri? by lazy {
        try {
            val out = File(context.cacheDir, "GeneralUser-GS.sf2")
            if (!out.exists()) {
                context.assets.open("GeneralUser-GS.sf2").use { input ->
                    out.outputStream().use { input.copyTo(it) }
                }
            }
            out.absoluteFile.toUri()
        } catch (e: Exception) {
            android.util.Log.w("FolinoSoundfont", "GeneralUser-GS.sf2 missing — audio silent", e)
            null
        }
    }

    private fun activeUri(): Uri? {
        val hq = highQualityPath()
        if (hq.isNotEmpty()) {
            val f = File(hq)
            if (f.exists()) return f.absoluteFile.toUri()
        }
        return bundledUri
    }

    override fun soundfontUriFor(bank: Int, program: Int, isDrums: Boolean): Uri? = activeUri()
    override val defaultGmSoundfontUri: Uri? get() = activeUri()
}
```

- [ ] **Step 2: Commit**

```bash
git add Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/FolinoSoundfontResolver.kt
git commit -m "feat(android): resolver prefers downloaded high-quality soundfont"
```

### Task 16: Playback service hot-swaps on download completion

**Files:**
- Modify: `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderPlaybackService.kt`

- [ ] **Step 1: Build the resolver with the bridge's high-quality path + observe download completion**

Where the engine is constructed (currently `soundfontResolver = FolinoSoundfontResolver(applicationContext)`), pass the bridge-backed path and capture the ViewModel:

```kotlin
private val soundfontVM by lazy {
    com.keynumber.folino.soundfont.SoundfontController.viewModel(applicationContext)
}
```

```kotlin
engine = AndroidPlaybackEngine(
    context = applicationContext,
    soundfontResolver = FolinoSoundfontResolver(
        applicationContext,
        highQualityPath = { soundfontVM.highQualityFilePath() },
    ),
    metronomeClickProvider = MetronomeClickProvider { MetronomeClickSource.DefaultGm },
)
```

- [ ] **Step 2: Observe `stateWire` and reload when downloaded (paused → now; playing → on next pause)**

Add, in `onCreate()` after the engine is built (mirror the existing `observeEngineForForegroundNotification()` coroutine pattern):

```kotlin
private var pendingSoundfontSwap = false

private fun observeSoundfontDownload() {
    lifecycleScope.launch {
        soundfontVM.stateWire.collect { state ->
            if (state.statusRaw == "downloaded") {
                if (engine.state.value == PlaybackEngineState.PLAYING) {
                    pendingSoundfontSwap = true
                } else {
                    reloadSoundfont()
                }
            }
        }
    }
    // Flush a pending swap the next time playback pauses/stops.
    lifecycleScope.launch {
        engine.state.collect { s ->
            if (pendingSoundfontSwap && s != PlaybackEngineState.PLAYING) {
                pendingSoundfontSwap = false
                reloadSoundfont()
            }
        }
    }
}
```

(Adjust `PlaybackEngineState.PLAYING` and `engine.state` to the actual engine state API names already used by `observeEngineForForegroundNotification()`. `ReaderPlaybackService` already references `engine.state` for foreground notifications, so reuse those exact symbols.)

- [ ] **Step 3: Implement `reloadSoundfont()` reusing the existing engine lifecycle**

The iOS `reloadSoundfont` does teardown → re-prepare → restore prefs → restore cursor. On Android, reuse the same prepare/seek path the service already uses to load a score. Implement:

```kotlin
private fun reloadSoundfont() {
    val score = currentScore ?: return // the score the service last prepared
    val savedTick = engine.currentTick() // or whatever cursor/position accessor the service already reads
    engine.teardown()
    engine.prepare(score) // re-queries FolinoSoundfontResolver → picks up the high-quality file
    reapplyPlaybackPreferences() // the service's existing helper for volumes/mutes/solos/tempo/metronome
    engine.seek(savedTick)
}
```

> Implementer: wire the three placeholders to the service's real members. `currentScore`, the position accessor, and the preferences-reapply helper already exist in `ReaderPlaybackService` (it prepares a score, applies prefs, and tracks position for the cursor). If a single `reapplyPlaybackPreferences()` helper does not exist yet, extract one from the existing `prepare`-time code so both the initial prepare and the reload call it (DRY). Do NOT add a new soundfont-reload API to swift-sheet-music — `teardown` + `prepare` already exist.

- [ ] **Step 4: Call `observeSoundfontDownload()` from `onCreate()`**

Add the call right after the existing `observeEngineForForegroundNotification()` invocation in `onCreate()`.

- [ ] **Step 5: Build**

Run: `cd Android && ./gradlew :app:assembleDebug`
Expected: BUILD SUCCESSFUL.

- [ ] **Step 6: Commit**

```bash
git add Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderPlaybackService.kt
git commit -m "feat(android): hot-swap soundfont on download completion while paused"
```

---

## Phase 7 — Device verification

### Task 17: Install, launch, and verify on Pixel

**Files:** none (verification only)

- [ ] **Step 1: Rebuild the native lib if any FolinoSoundfontJNI Swift changed since Phase 3**

Run: `./Scripts/android-build-soundfont-libs.sh`
Expected: `.so` re-staged for both ABIs.

- [ ] **Step 2: Install and launch**

Run:
```bash
cd Android && ./gradlew :app:installDebug
```
Then:
```bash
adb shell am start -n com.keynumber.folino/.MainActivity
```
Expected: app launches without `UnsatisfiedLinkError` / `JNI_OnLoad` failure (a clean launch confirms the `.so` symbols and generated bindings line up).

- [ ] **Step 3: Manual parity checks (perform on the Pixel; confirm each)**

- On Wi-Fi, first launch with opt-in default true: Settings → Reader shows the row downloading; progress advances; on completion the switch shows ON with no subtitle.
- Toggle OFF → delete confirmation dialog → confirm → file removed, switch OFF.
- Toggle ON while on cellular (disable Wi-Fi): "No Wi-Fi" dialog appears; "Download over cellular" starts the transfer; "Wait for Wi-Fi" leaves it idle with the "Waiting for Wi-Fi" subtitle + "Download now".
- Force a failure (airplane mode mid-download): row shows the red error; re-enabling Wi-Fi auto-retries.
- Open a score, pause, and let a download complete while paused: playback uses the higher-fidelity samples on the next play (audible check).

- [ ] **Step 4: Final commit if any verification fixes were made**

```bash
git add -A
git commit -m "fix(android): soundfont download verification fixes"
```

(Skip if no changes were needed.)

---

## Self-Review

**Spec coverage:**
- Wi-Fi-by-default auto-download → Task 7 (`startDownloadIfNeeded` in store + `shouldAutoStart`), Task 12 (`NETWORK_WIFI`). ✓
- Cellular override → Task 7 (`startDownloadAllowingCellular`), Task 14 (dialog), Task 12 (`NETWORK_WIFI or NETWORK_MOBILE`). ✓
- In-flight progress → Task 12 (poll → `onProgress`), Task 7 (`ingestProgress`), Task 14 (determinate indicator). ✓
- Delete → Task 7 (`deleteDownloaded`), Task 14 (delete dialog). ✓
- Failure + auto-retry on reachability → Task 7 (`ingestFailed`, `onReachabilityChanged` + `shouldRetryOnWiFi`), Task 11 (callback). ✓
- Hot-swap while paused → Task 16. ✓
- Shared Swift logic → Task 1–2 (Domain reducer), Task 3 (iOS uses it), Task 7 (Android store uses it). ✓
- New `FolinoSoundfontJNI` in Infrastructure → Task 4. ✓
- Resolver prefers downloaded file → Task 15. ✓
- Default opt-in true → Task 10 (`?: true`). ✓
- `ACCESS_NETWORK_STATE` permission → Task 9 (library manifest). ✓
- iOS no regression → Task 3 Step 4 (existing tests). ✓

**Placeholder scan:** The three deliberately-marked implementer notes (SoundfontController callback names, `isWiFiNow` UI option, `reloadSoundfont` member wiring) point at concrete generated/existing symbols the implementer must read off the generated ViewModel and `ReaderPlaybackService` — they are not vague "handle edge cases" placeholders; each names the exact symbol and the file that is the source of truth. Acceptable because the generated names cannot be known until codegen runs in Task 9.

**Type consistency:** `SoundfontStateWire(statusRaw, progress, failureReason)` is used identically in Task 5 (definition), Task 7 (`wire(_:)`), Task 14 (UI read). Reducer method names (`nextState`, `shouldAutoStart`, `shouldRetryOnWiFi`, `preset`) match between Task 2 (definition), Task 3 (iOS), Task 7 (Android). `@WireletProvided` method signatures match between Task 6 (Swift) and Tasks 10–12 (Kotlin impls): `start(remoteURL:destinationPath:allowCellular:)`, `cancel()`, `isWiFi()`, `startObserving()`, `loadOptedIn()`, `saveOptedIn(value:)`, `soundfontsDirectoryPath()`.
