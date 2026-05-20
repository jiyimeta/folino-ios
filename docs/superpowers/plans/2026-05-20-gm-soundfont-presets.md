# GM SoundFont Presets Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the per-patch SF2 download system with a two-tier GM SoundFont design: bundle GeneralUser GS (~31 MB) as the always-available default; auto-download MuseScore_General (~206 MB) on Wi-Fi as an opt-out upgrade. Surface state + opt-out in Settings.

**Architecture:** A single Domain protocol (`MuseScoreGeneralProvider`) owns the user preference, file presence, and download lifecycle. The audio engine consumes one resolver (`GMSoundfontResolver`) whose `defaultGMSoundfontURL` returns the best available preset and whose per-patch `soundfontURL(...)` always returns `nil` (full-GM fallback covers every voice). The per-patch `Domain.SoundfontResolver` / `SoundfontPatch` / `PrecisePatchProbe` machinery is retired.

**Tech Stack:** SwiftUI / Swift Concurrency / `URLSessionDownloadTask` for resumable foreground downloads, `NWPathMonitor` for Wi-Fi gating, `UserDefaults` for the opt-out toggle, `FileManager` + `URLResourceValues.isExcludedFromBackup` for storage.

---

## File Structure

**Domain** (`Packages/Domain/Sources/Domain/`):
- Create `Models/SoundfontPreset.swift` — enum `{ generalUserGS, museScoreGeneral }` + size/file-name constants.
- Create `Models/SoundfontDownloadState.swift` — enum `{ idle, downloading(progress: Double), downloaded, failed(reason: String) }`.
- Create `Protocols/MuseScoreGeneralProvider.swift` — owns the toggle, download lifecycle, file presence, derived "current preset".
- Modify `Protocols/PlaybackController.swift` — remove `areSoundfontsAvailableLocally(for:)`, `isSoundfontCached(...)`, `prefetchSoundfont(...)`.
- Delete `Models/SoundfontPatch.swift`, `Protocols/SoundfontResolver.swift`, `Protocols/PrecisePatchProbe.swift`.
- Delete the `SoundfontPatchKey` type wherever it lives (search will find it under `Models/` or in `DomainExports.swift`).

**Infrastructure / Soundfonts** (`Packages/Infrastructure/Sources/Soundfonts/`):
- Create `GMSoundfontResolver.swift` — implements `SheetMusicAudio.SoundfontResolver`. `soundfontURL(forBank:program:isDrums:)` returns `nil`; `defaultGMSoundfontURL` returns the downloaded MuseScore_General URL when present, else the bundled GeneralUser GS URL.
- Create `LiveMuseScoreGeneralProvider.swift` — implements `Domain.MuseScoreGeneralProvider`. Wraps a `URLSession` with `allowsCellularAccess = false` by default + an "allow cellular this once" override, `URLSessionDownloadDelegate` for progress, an `AsyncStream<SoundfontDownloadState>` for observers, `NWPathMonitor` for Wi-Fi gating + auto-retry.
- Delete `MuseScoreSF2Resolver.swift`.
- Keep `BundledSF2PresetCatalog.swift` (the SF2 preset-name parser is still useful and not touched by this plan).

**Infrastructure / Audio**:
- Modify `LivePlaybackController.swift` — drop `domainResolver`/`precisionProbe` params; delete `prefetchSoundfonts(...)`, `areSoundfontsAvailableLocally(...)`, `isSoundfontCached(...)`, `prefetchSoundfont(...)`, `scoreWithFallbackRewrites(...)`, `distinctPatchKeys(...)`. `load(...)` no longer prefetches; `engine.prepare(score:)` receives the unmodified score.
- Modify `LiveScoreAudioExporter.swift` — drop `domainResolver` param + the per-patch prefetch loop.

**Features / Settings** (`Packages/Features/Settings/Sources/Settings/`):
- Create `Screens/SoundfontPresetView.swift` — toggle, state subtitle, cellular DL button.
- Modify `Screens/SettingsSheet.swift` — replace `SoundfontCacheView` navigation entry; replace constructor params (`soundfontResolver` / `presetCatalog`) with `provider: any MuseScoreGeneralProvider`.
- Delete `Screens/SoundfontCacheView.swift`.
- Modify `Resources/Localizable.xcstrings` — add new keys; remove cache-screen keys.

**Features / Reader**:
- Modify `Sources/Reader/ReaderViewModel.swift` — remove the `areSoundfontsAvailableLocally(for:)` short-circuit (line ~446).
- Modify `Sources/Reader/PlaybackMixerModel.swift` — remove the `isSoundfontCached(...)` / `prefetchSoundfont(...)` calls (lines ~221, ~290) and any UI plumbing for the "soundfont downloading" badge.
- Modify `Tests/ReaderTests/Fakes/FakePlaybackController.swift` — drop `cachedPatches`, `prefetchedPatches`, `isSoundfontCached`, `prefetchSoundfont`, `areSoundfontsAvailableLocally`.
- Modify `Tests/ReaderTests/ReaderViewModelPlaybackTests.swift` — drop per-patch cache expectations.

**App**:
- Modify `AppPaths.swift` — replace `soundfontCacheDirectory` (Caches) with `soundfontsDirectory` (Application Support, `excludedFromBackup`).
- Modify `AppBootstrap.swift` — drop `MuseScoreSF2Resolver`; wire `GMSoundfontResolver` + `LiveMuseScoreGeneralProvider`; simplify `installAudioStack`.
- Modify `AppShellView.swift` (or wherever the scene root is) — call `provider.startDownloadIfNeeded()` after `AppBootstrap.isReady` flips true.
- Add `App/Resources/Soundfonts/GeneralUser-GS.sf2` (~31 MB; copied from `~/Desktop/Sounds/GeneralUser-GS.sf2`).
- Delete `App/Resources/Soundfonts/000_073.sf2` and `128_000.sf2`.

**Hosting (out of scope for this plan, prerequisite):** Upload `MuseScore_General.sf2` (206 MB) as an asset on a tag of `jiyimeta/musescore-general-sf2-split` (e.g. `v2.0.0`). The plan hard-codes the download URL — confirm the exact tag/asset name before starting Task 5.

---

## Task 1: Domain types

**Files:**
- Create: `Packages/Domain/Sources/Domain/Models/SoundfontPreset.swift`
- Create: `Packages/Domain/Sources/Domain/Models/SoundfontDownloadState.swift`
- Create: `Packages/Domain/Sources/Domain/Protocols/MuseScoreGeneralProvider.swift`
- Test: `Packages/Domain/Tests/DomainTests/Models/SoundfontPresetTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Packages/Domain/Tests/DomainTests/Models/SoundfontPresetTests.swift
import Foundation
import Testing
@testable import Domain

@Suite struct SoundfontPresetTests {
    @Test func `bundled file name matches the asset committed under App resources`() {
        #expect(SoundfontPreset.generalUserGS.fileName == "GeneralUser-GS.sf2")
        #expect(SoundfontPreset.generalUserGS.sizeBytes == 31 * 1024 * 1024)
        #expect(SoundfontPreset.generalUserGS.isBundled == true)
    }

    @Test func `downloadable file name matches the GitHub release asset`() {
        #expect(SoundfontPreset.museScoreGeneral.fileName == "MuseScore_General.sf2")
        #expect(SoundfontPreset.museScoreGeneral.sizeBytes == 206 * 1024 * 1024)
        #expect(SoundfontPreset.museScoreGeneral.isBundled == false)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd Packages/Domain && swift test --filter SoundfontPresetTests`
Expected: FAIL — `SoundfontPreset` not defined.

- [ ] **Step 3: Implement `SoundfontPreset`**

```swift
// Packages/Domain/Sources/Domain/Models/SoundfontPreset.swift
import Foundation

/// The GM SoundFont actively serving the playback engine. Folino ships GeneralUser GS bundled (always available); the
/// MuseScore_General upgrade is opted into via Settings and downloaded over the network the first time the toggle is on
/// and Wi-Fi is reachable.
public enum SoundfontPreset: String, Sendable, Hashable, CaseIterable {
    case generalUserGS
    case museScoreGeneral

    /// SF2 file name expected under `Bundle.main/Soundfonts/` (bundled) or `Application Support/Soundfonts/`
    /// (downloaded).
    public var fileName: String {
        switch self {
        case .generalUserGS: return "GeneralUser-GS.sf2"
        case .museScoreGeneral: return "MuseScore_General.sf2"
        }
    }

    /// Approximate uncompressed size used by Settings to label the toggle. Real file size on disk is read by the
    /// provider when available.
    public var sizeBytes: Int64 {
        switch self {
        case .generalUserGS: return 31 * 1024 * 1024
        case .museScoreGeneral: return 206 * 1024 * 1024
        }
    }

    public var isBundled: Bool { self == .generalUserGS }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd Packages/Domain && swift test --filter SoundfontPresetTests`
Expected: PASS.

- [ ] **Step 5: Implement `SoundfontDownloadState` and `MuseScoreGeneralProvider`**

```swift
// Packages/Domain/Sources/Domain/Models/SoundfontDownloadState.swift
import Foundation

/// Lifecycle of the MuseScore_General download. The Settings row reads this for its subtitle; `LiveMuseScoreGeneral-
/// Provider` is the sole writer.
public enum SoundfontDownloadState: Sendable, Equatable {
    /// File is not on disk and no download is in flight. The provider may transition to `downloading` automatically
    /// when the user's toggle is on and Wi-Fi becomes available.
    case idle

    /// A download is in flight. `progress` is in `[0, 1]`; bytes-written / expected-total.
    case downloading(progress: Double)

    /// File is on disk and ready for the audio engine to load.
    case downloaded

    /// The last download attempt failed. `reason` is a localized string suitable for display in Settings. The provider
    /// auto-retries when network becomes reachable again; the user can also tap "Retry".
    case failed(reason: String)
}
```

```swift
// Packages/Domain/Sources/Domain/Protocols/MuseScoreGeneralProvider.swift
import Foundation

/// Owns the MuseScore_General opt-out toggle, file presence, and download lifecycle. The audio resolver and the
/// Settings row both consume this protocol; only the live infrastructure implementation mutates state.
public protocol MuseScoreGeneralProvider: Sendable {
    /// User toggle. Defaults to `true` on first launch (auto-download by default; opt-out via Settings). When the user
    /// flips this to `false`: cancel any in-flight download; if the file is on disk, delete it.
    var isOptedIn: Bool { get async }
    func setOptedIn(_ value: Bool) async

    /// `true` iff `MuseScore_General.sf2` is currently on disk and readable. Cached file system observation; safe to
    /// poll from the audio thread.
    var isDownloaded: Bool { get async }

    /// File system URL of the downloaded preset, or `nil` if absent. `GMSoundfontResolver` consults this every time the
    /// engine asks for `defaultGMSoundfontURL`.
    var museScoreGeneralFileURL: URL? { get async }

    /// Currently-effective preset, derived from `(isOptedIn, isDownloaded)`: `museScoreGeneral` when both true,
    /// otherwise `generalUserGS`.
    var currentPreset: SoundfontPreset { get async }

    /// Async stream of state changes for the Settings UI. New subscribers receive the current state immediately.
    func downloadStateStream() -> AsyncStream<SoundfontDownloadState>

    /// Kick off a download if the toggle is on, the file is absent, and the network policy allows it. Idempotent —
    /// safe to call on every app launch and every network-availability change.
    func startDownloadIfNeeded() async

    /// Force a download attempt regardless of the network policy. Used by the "Download over cellular" button.
    func startDownloadAllowingCellular() async

    /// Cancel an in-flight download. No-op if idle.
    func cancelDownload() async

    /// Delete `MuseScore_General.sf2` from disk if present. No-op if absent.
    func deleteDownloaded() async
}
```

- [ ] **Step 6: Build and run Domain tests**

Run: `cd Packages/Domain && swift test`
Expected: All tests pass (the new types compile; existing tests untouched).

- [ ] **Step 7: Commit**

```bash
git add Packages/Domain/Sources/Domain/Models/SoundfontPreset.swift \
        Packages/Domain/Sources/Domain/Models/SoundfontDownloadState.swift \
        Packages/Domain/Sources/Domain/Protocols/MuseScoreGeneralProvider.swift \
        Packages/Domain/Tests/DomainTests/Models/SoundfontPresetTests.swift
git commit -m "Add MuseScoreGeneralProvider domain types"
```

---

## Task 2: AppPaths — Application Support / Soundfonts/

**Files:**
- Modify: `App/AppPaths.swift`

(No test file — `AppPaths` is a thin wrapper over `FileManager` and exercising it requires app sandboxing. The Application Support directory existence and backup exclusion are verified manually after Task 6's bootstrap rewrite.)

- [ ] **Step 1: Replace `soundfontCacheDirectory` with `soundfontsDirectory`**

```swift
// App/AppPaths.swift
import Foundation

/// Resolves on-disk locations the app uses. Centralized so AppBootstrap and any future migrations agree on layout.
enum AppPaths {
    static var documentsRoot: URL {
        guard let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            fatalError("Documents directory unavailable — sandbox is broken")
        }
        return url
    }

    static var scoresDirectory: URL {
        documentsRoot.appending(path: "Scores")
    }

    static var databaseURL: URL {
        documentsRoot.appending(path: "Folino.sqlite")
    }

    /// `Library/Application Support/Soundfonts/`. The MuseScore_General download lands here. Application Support
    /// (not Caches) so iOS storage cleanup does not silently evict a 206 MB asset the user opted to keep. Excluded from
    /// iCloud / iTunes backup at directory creation time (see `AppBootstrap.prepareDirectories`).
    static var soundfontsDirectory: URL {
        guard let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            fatalError("Application Support directory unavailable — sandbox is broken")
        }
        return url.appending(path: "Soundfonts")
    }

    static var shareTempDirectory: URL {
        documentsRoot.appending(path: "ShareTmp")
    }
}
```

- [ ] **Step 2: Build to confirm no callers of the renamed symbol break**

```bash
grep -rn "soundfontCacheDirectory" App Packages --include="*.swift"
```

Expected: matches in `App/AppBootstrap.swift` only — those will be updated in Task 6.

- [ ] **Step 3: Commit**

```bash
git add App/AppPaths.swift
git commit -m "Move soundfonts dir to Application Support"
```

---

## Task 3: Bundle GeneralUser-GS.sf2

**Files:**
- Add: `App/Resources/Soundfonts/GeneralUser-GS.sf2` (~31 MB, copied from `~/Desktop/Sounds/GeneralUser-GS.sf2`)
- Modify: `project.yml` (only if the `Soundfonts` folder reference needs explicit asset listing — XcodeGen's `path:`-style folder references already pick up new files, so usually no edit needed; verify after running xcodegen)

- [ ] **Step 1: Copy the bundle asset**

```bash
cp ~/Desktop/Sounds/GeneralUser-GS.sf2 App/Resources/Soundfonts/GeneralUser-GS.sf2
```

- [ ] **Step 2: Verify the size committed is what we expect**

```bash
ls -lh App/Resources/Soundfonts/GeneralUser-GS.sf2
```

Expected: roughly `31M`.

- [ ] **Step 3: Regenerate Xcode project and confirm the file is picked up**

```bash
xcodegen generate
grep -c "GeneralUser-GS.sf2" Folino.xcodeproj/project.pbxproj
```

Expected: ≥ 1 (XcodeGen's folder reference enumerates the directory).

- [ ] **Step 4: Build to confirm the asset is bundled**

```bash
xcodebuild -project Folino.xcodeproj -scheme Folino \
    -destination 'platform=iOS Simulator,name=iPhone 17' \
    -skipPackagePluginValidation build 2>&1 | tail -5
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add App/Resources/Soundfonts/GeneralUser-GS.sf2
git commit -m "Bundle GeneralUser-GS.sf2 as the default GM soundfont"
```

(`Folino.xcodeproj` is gitignored — only the asset is committed.)

---

## Task 4: `GMSoundfontResolver`

**Files:**
- Create: `Packages/Infrastructure/Sources/Soundfonts/GMSoundfontResolver.swift`
- Test: `Packages/Infrastructure/Tests/InfrastructureTests/Soundfonts/GMSoundfontResolverTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// Packages/Infrastructure/Tests/InfrastructureTests/Soundfonts/GMSoundfontResolverTests.swift
import Domain
import Foundation
@testable import Soundfonts
import Testing

@Suite struct GMSoundfontResolverTests {
    @Test func `soundfontURL is always nil — engine consults defaultGMSoundfontURL`() async {
        let resolver = GMSoundfontResolver(
            provider: StubProvider(museScoreGeneralFileURL: nil),
            bundle: try! makeBundleStub(),
        )
        #expect(resolver.soundfontURL(forBank: 0, program: 0, isDrums: false) == nil)
        #expect(resolver.soundfontURL(forBank: 0, program: 0, isDrums: true) == nil)
    }

    @Test func `defaultGMSoundfontURL prefers downloaded MuseScore_General when present`() async {
        let downloaded = URL(filePath: "/tmp/MuseScore_General.sf2")
        let resolver = GMSoundfontResolver(
            provider: StubProvider(museScoreGeneralFileURL: downloaded),
            bundle: try! makeBundleStub(),
        )
        #expect(resolver.defaultGMSoundfontURL == downloaded)
    }

    @Test func `defaultGMSoundfontURL falls back to bundled GeneralUser GS when nothing downloaded`() async {
        let bundle = try! makeBundleStub()
        let resolver = GMSoundfontResolver(
            provider: StubProvider(museScoreGeneralFileURL: nil),
            bundle: bundle,
        )
        let url = resolver.defaultGMSoundfontURL
        #expect(url?.lastPathComponent == "GeneralUser-GS.sf2")
    }
}

private struct StubProvider: MuseScoreGeneralProvider {
    let museScoreGeneralFileURL: URL?
    var isOptedIn: Bool { true }
    var isDownloaded: Bool { museScoreGeneralFileURL != nil }
    var currentPreset: SoundfontPreset { isDownloaded ? .museScoreGeneral : .generalUserGS }
    func setOptedIn(_: Bool) async {}
    func downloadStateStream() -> AsyncStream<SoundfontDownloadState> { AsyncStream { _ in } }
    func startDownloadIfNeeded() async {}
    func startDownloadAllowingCellular() async {}
    func cancelDownload() async {}
    func deleteDownloaded() async {}
}

/// Builds a fake `Bundle` containing only `Soundfonts/GeneralUser-GS.sf2` so the resolver's bundle lookup has a target.
private func makeBundleStub() throws -> Bundle {
    let tmp = FileManager.default.temporaryDirectory.appending(
        path: "GMSoundfontResolverTests-\(UUID().uuidString).bundle",
    )
    let soundfontsDir = tmp.appending(path: "Soundfonts")
    try FileManager.default.createDirectory(at: soundfontsDir, withIntermediateDirectories: true)
    try Data([0xFF]).write(to: soundfontsDir.appending(path: "GeneralUser-GS.sf2"))
    guard let bundle = Bundle(url: tmp) else { throw NSError(domain: "bundle", code: 1) }
    return bundle
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cd Packages/Infrastructure && swift test --filter GMSoundfontResolverTests`
Expected: FAIL — `GMSoundfontResolver` not defined.

- [ ] **Step 3: Implement `GMSoundfontResolver`**

```swift
// Packages/Infrastructure/Sources/Soundfonts/GMSoundfontResolver.swift
import Domain
import Foundation
import SheetMusicAudio

/// Adapter from `SheetMusicAudio.SoundfontResolver` to Folino's GM-only sound model. The audio engine asks this
/// resolver for `defaultGMSoundfontURL` every time it loads a score; we hand back either the downloaded
/// MuseScore_General URL (preferred when present + opted in) or the bundled GeneralUser GS URL.
public struct GMSoundfontResolver: SheetMusicAudio.SoundfontResolver {
    private let provider: any MuseScoreGeneralProvider
    private let bundle: Bundle

    public init(provider: any MuseScoreGeneralProvider, bundle: Bundle = .main) {
        self.provider = provider
        self.bundle = bundle
    }

    /// Always `nil` — the engine falls through to `defaultGMSoundfontURL`, which carries the full GM bank. Returning
    /// nil here keeps the engine code path identical for every voice in every score.
    public func soundfontURL(forBank _: UInt8, program _: UInt8, isDrums _: Bool) -> URL? {
        nil
    }

    public var defaultGMSoundfontURL: URL? {
        // Synchronous read of the provider's snapshot is fine because the file URL only changes on download completion
        // / deletion, both of which are user-initiated rare events. Audio thread tolerates an occasional cross-actor
        // hop via `unsafeWait` (see provider implementation).
        if let downloaded = provider.museScoreGeneralFileURLSync {
            return downloaded
        }
        return bundle.url(
            forResource: "GeneralUser-GS",
            withExtension: "sf2",
            subdirectory: "Soundfonts",
        )
    }
}

extension MuseScoreGeneralProvider {
    /// Synchronous accessor used by the audio thread. Concrete providers override; default is `nil` to keep stub
    /// providers in tests trivially compliant.
    public var museScoreGeneralFileURLSync: URL? { nil }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `cd Packages/Infrastructure && swift test --filter GMSoundfontResolverTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Packages/Infrastructure/Sources/Soundfonts/GMSoundfontResolver.swift \
        Packages/Infrastructure/Tests/InfrastructureTests/Soundfonts/GMSoundfontResolverTests.swift
git commit -m "Add GMSoundfontResolver"
```

---

## Task 5: `LiveMuseScoreGeneralProvider`

**Files:**
- Create: `Packages/Infrastructure/Sources/Soundfonts/LiveMuseScoreGeneralProvider.swift`
- Test: `Packages/Infrastructure/Tests/InfrastructureTests/Soundfonts/LiveMuseScoreGeneralProviderTests.swift`

**Prerequisite:** Confirm the GitHub release URL. The plan uses `https://github.com/jiyimeta/musescore-general-sf2-split/releases/download/v2.0.0/MuseScore_General.sf2` as the placeholder — replace before running this task if the release tag differs.

- [ ] **Step 1: Write the failing tests**

The provider has six concerns — write one test per concern using a stub `URLProtocol` for the network.

```swift
// Packages/Infrastructure/Tests/InfrastructureTests/Soundfonts/LiveMuseScoreGeneralProviderTests.swift
import Domain
import Foundation
@testable import Soundfonts
import Testing

@Suite(.serialized) struct LiveMuseScoreGeneralProviderTests {
    @Test func `default opt-in is true on first launch`() async throws {
        let env = try TestEnvironment()
        defer { env.cleanup() }
        let provider = env.makeProvider()
        #expect(await provider.isOptedIn == true)
    }

    @Test func `toggling off cancels in-flight download and deletes file`() async throws {
        let env = try TestEnvironment()
        defer { env.cleanup() }
        try env.placeDownloadedFile(bytes: 100)
        let provider = env.makeProvider()
        await provider.setOptedIn(false)
        #expect(await provider.isDownloaded == false)
        #expect(await provider.currentPreset == .generalUserGS)
    }

    @Test func `startDownloadIfNeeded skips when network is cellular and policy is wifi-only`() async throws {
        let env = try TestEnvironment(networkIsWiFi: false)
        defer { env.cleanup() }
        let provider = env.makeProvider()
        await provider.startDownloadIfNeeded()
        #expect(await provider.isDownloaded == false)
        var observed: [SoundfontDownloadState] = []
        for await state in provider.downloadStateStream().prefix(1) { observed.append(state) }
        #expect(observed == [.idle])
    }

    @Test func `startDownloadIfNeeded on wifi reports progress and lands the file`() async throws {
        let env = try TestEnvironment(networkIsWiFi: true)
        defer { env.cleanup() }
        env.stubResponseBody = Data(repeating: 0xAB, count: 1024)
        let provider = env.makeProvider()
        await provider.startDownloadIfNeeded()
        // Wait for completion via the stream.
        for await state in provider.downloadStateStream() {
            if case .downloaded = state { break }
        }
        #expect(await provider.isDownloaded == true)
        #expect(await provider.currentPreset == .museScoreGeneral)
    }

    @Test func `startDownloadAllowingCellular runs even when wifi policy would refuse`() async throws {
        let env = try TestEnvironment(networkIsWiFi: false)
        defer { env.cleanup() }
        env.stubResponseBody = Data(repeating: 0xCC, count: 1024)
        let provider = env.makeProvider()
        await provider.startDownloadAllowingCellular()
        for await state in provider.downloadStateStream() {
            if case .downloaded = state { break }
        }
        #expect(await provider.isDownloaded == true)
    }

    @Test func `network failure transitions to .failed and auto-retries when wifi reachability returns`() async throws {
        let env = try TestEnvironment(networkIsWiFi: true)
        defer { env.cleanup() }
        env.stubResponseError = URLError(.notConnectedToInternet)
        let provider = env.makeProvider()
        await provider.startDownloadIfNeeded()
        var sawFailed = false
        for await state in provider.downloadStateStream() {
            if case .failed = state { sawFailed = true; break }
        }
        #expect(sawFailed)
        // Drop the error; signal reachability change; expect the provider to retry.
        env.stubResponseError = nil
        env.stubResponseBody = Data(repeating: 0xDD, count: 1024)
        env.simulateReachabilityChange(toWiFi: true)
        for await state in provider.downloadStateStream() {
            if case .downloaded = state { break }
        }
        #expect(await provider.isDownloaded == true)
    }
}

// `TestEnvironment` is a helper struct in the same file. Sketch (engineer fills in):
// - tmp Application Support dir
// - stub URLProtocol that responds with `stubResponseBody` or throws `stubResponseError`
// - fake NWPathMonitor injected via a small abstraction (define `NetworkPathObserving` in Soundfonts module)
// - `makeProvider()` returns a `LiveMuseScoreGeneralProvider(targetDirectory: env.dir, downloadURL: ..., session: ...,
//   pathMonitor: env.pathMonitor, defaults: UserDefaults(suiteName:))` configured for isolation.
// - `placeDownloadedFile(bytes:)` drops a fake `MuseScore_General.sf2` into env.dir.
// - `simulateReachabilityChange(toWiFi:)` pushes through the fake path monitor.
// - `cleanup()` removes the tmp dir and the per-test UserDefaults suite.
```

- [ ] **Step 2: Run to verify failure**

Run: `cd Packages/Infrastructure && swift test --filter LiveMuseScoreGeneralProviderTests`
Expected: FAIL — type undefined.

- [ ] **Step 3: Implement `LiveMuseScoreGeneralProvider`**

```swift
// Packages/Infrastructure/Sources/Soundfonts/LiveMuseScoreGeneralProvider.swift
import Domain
import Foundation
import Network
import os

/// UserDefaults-backed opt-out toggle + foreground `URLSessionDownloadTask` lifecycle for `MuseScore_General.sf2`.
///
/// Network policy: `URLSessionConfiguration.allowsCellularAccess = false` for the auto-download session — that means
/// `startDownloadIfNeeded` is a no-op when Wi-Fi is unreachable, but a `URLSessionDownloadTask` already in flight on
/// Wi-Fi will not be killed if the user later steps onto cellular. `startDownloadAllowingCellular` uses a separate
/// session with `allowsCellularAccess = true` for the explicit "Download over cellular" button.
///
/// State stream: `downloadStateStream()` returns a multicast `AsyncStream` so Settings + the resolver can both watch.
/// New subscribers receive the current state immediately.
///
/// Auto-retry: an `NWPathMonitor` watches for a Wi-Fi transition. When the last download failed and Wi-Fi becomes
/// reachable, the provider re-issues `startDownloadIfNeeded`.
public actor LiveMuseScoreGeneralProvider: MuseScoreGeneralProvider {
    private let targetDirectory: URL
    private let downloadURL: URL
    private let defaults: UserDefaults
    private let pathMonitor: any NetworkPathObserving
    private let wifiSession: URLSession
    private let cellularSession: URLSession
    private let logger = Logger(subsystem: "com.KeyNumber.Folino", category: "MuseScoreGeneralProvider")

    private var activeTask: URLSessionDownloadTask?
    private var currentState: SoundfontDownloadState = .idle
    private var continuations: [UUID: AsyncStream<SoundfontDownloadState>.Continuation] = [:]

    public init(
        targetDirectory: URL,
        downloadURL: URL = URL(
            string: "https://github.com/jiyimeta/musescore-general-sf2-split/releases/download/v2.0.0/MuseScore_General.sf2",
        )!, // swiftlint:disable:this force_unwrapping
        defaults: UserDefaults = .standard,
        pathMonitor: any NetworkPathObserving = NWPathMonitorAdapter(),
        wifiSession: URLSession? = nil,
        cellularSession: URLSession? = nil,
    ) {
        self.targetDirectory = targetDirectory
        self.downloadURL = downloadURL
        self.defaults = defaults
        self.pathMonitor = pathMonitor
        self.wifiSession = wifiSession ?? Self.makeSession(allowsCellular: false)
        self.cellularSession = cellularSession ?? Self.makeSession(allowsCellular: true)
        currentState = FileManager.default.fileExists(atPath: targetFileURL.path) ? .downloaded : .idle
        pathMonitor.start { [weak self] isWiFi in
            Task { await self?.handlePathChange(isWiFi: isWiFi) }
        }
    }

    private static func makeSession(allowsCellular: Bool) -> URLSession {
        let config = URLSessionConfiguration.default
        config.allowsCellularAccess = allowsCellular
        config.waitsForConnectivity = true
        config.timeoutIntervalForResource = 60 * 30
        return URLSession(configuration: config)
    }

    private static let optInKey = "soundfont.museScoreGeneral.optedIn"

    private var targetFileURL: URL {
        targetDirectory.appending(path: SoundfontPreset.museScoreGeneral.fileName)
    }

    // MARK: - MuseScoreGeneralProvider

    public var isOptedIn: Bool {
        defaults.object(forKey: Self.optInKey) as? Bool ?? true
    }

    public func setOptedIn(_ value: Bool) async {
        defaults.set(value, forKey: Self.optInKey)
        if value {
            await startDownloadIfNeeded()
        } else {
            await cancelDownload()
            await deleteDownloaded()
        }
    }

    public var isDownloaded: Bool {
        FileManager.default.fileExists(atPath: targetFileURL.path)
    }

    public var museScoreGeneralFileURL: URL? {
        isDownloaded ? targetFileURL : nil
    }

    public nonisolated var museScoreGeneralFileURLSync: URL? {
        let url = targetDirectory.appending(path: SoundfontPreset.museScoreGeneral.fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    public var currentPreset: SoundfontPreset {
        (isOptedIn && isDownloaded) ? .museScoreGeneral : .generalUserGS
    }

    public nonisolated func downloadStateStream() -> AsyncStream<SoundfontDownloadState> {
        AsyncStream { continuation in
            let id = UUID()
            Task { await self.register(id: id, continuation: continuation) }
            continuation.onTermination = { _ in
                Task { await self.unregister(id: id) }
            }
        }
    }

    private func register(id: UUID, continuation: AsyncStream<SoundfontDownloadState>.Continuation) {
        continuations[id] = continuation
        continuation.yield(currentState)
    }

    private func unregister(id: UUID) { continuations.removeValue(forKey: id) }

    private func publish(_ state: SoundfontDownloadState) {
        currentState = state
        for continuation in continuations.values { continuation.yield(state) }
    }

    public func startDownloadIfNeeded() async {
        guard isOptedIn else { return }
        guard !isDownloaded else { publish(.downloaded); return }
        guard activeTask == nil else { return }
        guard pathMonitor.isCurrentlyWiFi else { return }
        startDownload(session: wifiSession)
    }

    public func startDownloadAllowingCellular() async {
        guard !isDownloaded else { publish(.downloaded); return }
        guard activeTask == nil else { return }
        startDownload(session: cellularSession)
    }

    private func startDownload(session: URLSession) {
        try? FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
        var request = URLRequest(url: downloadURL)
        request.timeoutInterval = 60
        let delegate = DownloadDelegate(owner: self)
        let task = session.downloadTask(with: request)
        task.delegate = delegate
        activeTask = task
        publish(.downloading(progress: 0))
        task.resume()
    }

    public func cancelDownload() async {
        activeTask?.cancel()
        activeTask = nil
        // Keep state machine honest: if a file landed before cancel propagated, surface that.
        publish(isDownloaded ? .downloaded : .idle)
    }

    public func deleteDownloaded() async {
        try? FileManager.default.removeItem(at: targetFileURL)
        publish(.idle)
    }

    // MARK: - Internal — called by URLSessionDownloadDelegate

    fileprivate func updateProgress(bytesWritten: Int64, expected: Int64) {
        guard expected > 0 else { return }
        publish(.downloading(progress: Double(bytesWritten) / Double(expected)))
    }

    fileprivate func handleDownloadFinished(temporaryURL: URL) {
        do {
            if FileManager.default.fileExists(atPath: targetFileURL.path) {
                try FileManager.default.removeItem(at: targetFileURL)
            }
            try FileManager.default.moveItem(at: temporaryURL, to: targetFileURL)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var moved = targetFileURL
            try moved.setResourceValues(values)
            activeTask = nil
            publish(.downloaded)
        } catch {
            logger.error("Failed to install MuseScore_General.sf2: \(String(describing: error), privacy: .public)")
            activeTask = nil
            publish(.failed(reason: error.localizedDescription))
        }
    }

    fileprivate func handleDownloadFailed(error: Error) {
        activeTask = nil
        // `URLError.cancelled` arrives when the user toggles off mid-download or app foregrounds with a stale handle —
        // do not surface a "failed" state in that case; cancellation already drove the state machine.
        if (error as? URLError)?.code == .cancelled { return }
        publish(.failed(reason: error.localizedDescription))
    }

    // MARK: - Reachability

    private func handlePathChange(isWiFi: Bool) async {
        guard isWiFi else { return }
        if case .failed = currentState {
            await startDownloadIfNeeded()
        }
    }
}

/// `URLSessionDownloadDelegate` lives outside the actor (URLSession's delegate callbacks are not isolated). It hops
/// back into the actor for every state mutation.
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let owner: LiveMuseScoreGeneralProvider
    init(owner: LiveMuseScoreGeneralProvider) { self.owner = owner }

    func urlSession(
        _: URLSession, downloadTask _: URLSessionDownloadTask,
        didWriteData _: Int64, totalBytesWritten written: Int64,
        totalBytesExpectedToWrite expected: Int64,
    ) {
        Task { await owner.updateProgress(bytesWritten: written, expected: expected) }
    }

    func urlSession(_: URLSession, downloadTask _: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // Move synchronously off the delegate's tmp directory before returning; the file is deleted as soon as this
        // callback returns. Copy into our own scratch URL, then let the actor move it into place.
        let scratch = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        do {
            try FileManager.default.moveItem(at: location, to: scratch)
        } catch {
            Task { await owner.handleDownloadFailed(error: error) }
            return
        }
        Task { await owner.handleDownloadFinished(temporaryURL: scratch) }
    }

    func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return } // Success path is handled by `didFinishDownloadingTo`.
        Task { await owner.handleDownloadFailed(error: error) }
    }
}

/// Indirection over `NWPathMonitor` so tests can swap in a stub.
public protocol NetworkPathObserving: Sendable {
    var isCurrentlyWiFi: Bool { get }
    func start(handler: @escaping @Sendable (_ isWiFi: Bool) -> Void)
}

public final class NWPathMonitorAdapter: NetworkPathObserving, @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "soundfont.network-path", qos: .utility)
    private var cachedIsWiFi = false

    public init() {}
    public var isCurrentlyWiFi: Bool { cachedIsWiFi }
    public func start(handler: @escaping @Sendable (Bool) -> Void) {
        monitor.pathUpdateHandler = { [weak self] path in
            let isWiFi = path.status == .satisfied && path.usesInterfaceType(.wifi)
            self?.cachedIsWiFi = isWiFi
            handler(isWiFi)
        }
        monitor.start(queue: queue)
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `cd Packages/Infrastructure && swift test --filter LiveMuseScoreGeneralProviderTests`
Expected: PASS for all six tests.

- [ ] **Step 5: Commit**

```bash
git add Packages/Infrastructure/Sources/Soundfonts/LiveMuseScoreGeneralProvider.swift \
        Packages/Infrastructure/Tests/InfrastructureTests/Soundfonts/LiveMuseScoreGeneralProviderTests.swift
git commit -m "Add LiveMuseScoreGeneralProvider"
```

---

## Task 6: AppBootstrap rewiring + audio simplification

This task migrates the runtime wiring and shrinks `LivePlaybackController` / `LiveScoreAudioExporter` in one commit because the protocol surface (`PlaybackController.areSoundfontsAvailableLocally` etc.) is shared between the App composition root, the Reader feature, and the audio adapter — partial changes would not compile.

**Files:**
- Modify: `App/AppBootstrap.swift`
- Modify: `Packages/Infrastructure/Sources/Audio/LivePlaybackController.swift`
- Modify: `Packages/Infrastructure/Sources/Audio/LivePlaybackController+LoopBounds.swift` (only if it imports `Domain.SoundfontResolver`)
- Modify: `Packages/Infrastructure/Sources/Audio/LiveScoreAudioExporter.swift`
- Modify: `Packages/Domain/Sources/Domain/Protocols/PlaybackController.swift` — remove three methods
- Modify: `Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift` — drop the `areSoundfontsAvailableLocally` short-circuit
- Modify: `Packages/Features/Reader/Sources/Reader/PlaybackMixerModel.swift` — drop `isSoundfontCached` / `prefetchSoundfont` calls
- Modify: `Packages/Features/Reader/Tests/ReaderTests/Fakes/FakePlaybackController.swift` — drop matching properties / methods
- Modify: `Packages/Features/Reader/Tests/ReaderTests/ReaderViewModelPlaybackTests.swift` — drop per-patch cache test expectations
- Modify: `Packages/Infrastructure/Tests/InfrastructureTests/Audio/LivePlaybackControllerTests.swift` — drop per-patch tests
- Modify: `Packages/Infrastructure/Tests/InfrastructureTests/Audio/LiveScoreAudioExporterTests.swift` — drop per-patch test
- Modify: `Packages/Domain/Tests/DomainTests/Protocols/AudioProtocolsTests.swift` — strip the three methods from the stub `PlaybackController`

- [ ] **Step 1: Trim `Domain.PlaybackController`**

Remove these three method declarations from `Packages/Domain/Sources/Domain/Protocols/PlaybackController.swift`:

```swift
// Delete these three:
func areSoundfontsAvailableLocally(for score: Score) async -> Bool
func isSoundfontCached(bank: Int, program: Int, isDrums: Bool) async -> Bool
func prefetchSoundfont(bank: Int, program: Int, isDrums: Bool) async throws
```

- [ ] **Step 2: Shrink `LivePlaybackController`**

Apply this targeted diff to `Packages/Infrastructure/Sources/Audio/LivePlaybackController.swift`:

- Constructor signature changes from `init(soundfontResolver:, domainResolver:, precisionProbe:)` to `init(soundfontResolver:)`. The single param is the `SheetMusicAudio.SoundfontResolver` (the new `GMSoundfontResolver`).
- Delete stored properties `domainResolver`, `precisionProbe`.
- In `load(score:displayTitle:preferences:)`: remove the `await Self.prefetchSoundfonts(...)` call and the `Self.scoreWithFallbackRewrites(...)` rewrite — pass the original `score` straight into `engine.prepare(score:)`.
- Delete the static helpers `prefetchSoundfonts(score:resolver:)`, `distinctPatchKeys(in:)`, and `scoreWithFallbackRewrites(_:probe:)`.
- Delete `areSoundfontsAvailableLocally(for:)`, `isSoundfontCached(...)`, `prefetchSoundfont(...)`.

The resulting `LivePlaybackController` no longer imports `Domain.SoundfontResolver` / `PrecisePatchProbe`. Keep the `import Domain` for the `PlaybackController` protocol conformance.

- [ ] **Step 3: Shrink `LiveScoreAudioExporter`**

Apply this diff to `Packages/Infrastructure/Sources/Audio/LiveScoreAudioExporter.swift`:

- Constructor: drop `domainResolver:` param.
- Remove the per-patch prefetch loop (around line 79: `_ = try await domainResolver.resolveSoundfont(...)`).
- The exporter now relies on `GMSoundfontResolver.defaultGMSoundfontURL` providing the file synchronously; nothing to await before `engine.export(...)`.

- [ ] **Step 4: Rewire `AppBootstrap.installAudioStack`**

```swift
// App/AppBootstrap.swift — replace the existing installAudioStack(...) body.
private func installAudioStack(gateway: LiveScoreFileGateway) {
    let provider = LiveMuseScoreGeneralProvider(targetDirectory: AppPaths.soundfontsDirectory)
    self.museScoreGeneralProvider = provider

    let resolver = GMSoundfontResolver(provider: provider)
    self.soundfontResolver = resolver

    if let bundledGS = Bundle.main.url(
        forResource: "GeneralUser-GS", withExtension: "sf2", subdirectory: "Soundfonts",
    ) {
        presetCatalog = try? BundledSF2PresetCatalog(sf2URL: bundledGS)
    }

    let audioExporter = LiveScoreAudioExporter(
        soundfontResolver: resolver,
        metronomeEnabled: {
            UserDefaults.standard.bool(forKey: ReaderGlobalSettingsKey.metronomeEnabled)
        },
    )
    shareService = LiveScoreShareService(
        scoresDirectory: AppPaths.scoresDirectory,
        shareTempDirectory: AppPaths.shareTempDirectory,
        gateway: gateway,
        audioExporter: audioExporter,
    )
    playbackController = LivePlaybackController(soundfontResolver: resolver)
}
```

Update the stored properties at the top of `AppBootstrap`:

```swift
// Replace these two:
//   private(set) var soundfontResolver: MuseScoreSF2Resolver?
//   private(set) var presetCatalog: BundledSF2PresetCatalog?
// With:
private(set) var soundfontResolver: GMSoundfontResolver?
private(set) var museScoreGeneralProvider: LiveMuseScoreGeneralProvider?
private(set) var presetCatalog: BundledSF2PresetCatalog?
```

Update `prepareDirectories()` to create `soundfontsDirectory` (already created via Application Support path) and apply the no-backup attribute:

```swift
private func prepareDirectories() throws {
    try FileManager.default.createDirectory(
        at: AppPaths.scoresDirectory, withIntermediateDirectories: true,
    )
    var soundfontsDir = AppPaths.soundfontsDirectory
    try FileManager.default.createDirectory(at: soundfontsDir, withIntermediateDirectories: true)
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try? soundfontsDir.setResourceValues(values)
    try? FileManager.default.removeItem(at: AppPaths.shareTempDirectory)
    try FileManager.default.createDirectory(
        at: AppPaths.shareTempDirectory, withIntermediateDirectories: true,
    )
}
```

- [ ] **Step 5: Strip Reader call sites**

In `Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift` around line 446, replace this block:

```swift
let cached = await controller.areSoundfontsAvailableLocally(for: score)
```

…and the surrounding loading-overlay state machine that depends on `cached`. After the change, `load(score:displayTitle:preferences:)` is invoked unconditionally with no "loading sounds" suppression — the engine load is fast now (GeneralUser GS is bundled and read directly).

In `Packages/Features/Reader/Sources/Reader/PlaybackMixerModel.swift`:
- Line ~221 (`await controller.isSoundfontCached(...)`): delete this check and the associated UI state (the "downloading" badge).
- Line ~290 (`try await controller.prefetchSoundfont(...)`): delete the prefetch and the surrounding `do/catch`.

Run a grep at the end of this step to make sure nothing references the three removed protocol methods:

```bash
grep -rn "areSoundfontsAvailableLocally\|isSoundfontCached\|prefetchSoundfont" \
    App Packages --include="*.swift" | grep -v "\.build/"
```

Expected: zero matches.

- [ ] **Step 6: Update fakes and tests**

In `Packages/Features/Reader/Tests/ReaderTests/Fakes/FakePlaybackController.swift`, delete `cachedPatches`, `prefetchedPatches`, `isSoundfontCached`, `prefetchSoundfont`, `areSoundfontsAvailableLocally`.

In `Packages/Features/Reader/Tests/ReaderTests/ReaderViewModelPlaybackTests.swift`, delete each `controller.cachedPatches = [...]` setup line and the assertions it backs (lines ~532, 576, 602, 645, 684, 806).

In `Packages/Infrastructure/Tests/InfrastructureTests/Audio/LivePlaybackControllerTests.swift`, delete the per-patch tests (search for `isSoundfontCached`, `prefetchSoundfont`, `FakeDomainSoundfontResolver` usages).

In `Packages/Infrastructure/Tests/InfrastructureTests/Audio/LiveScoreAudioExporterTests.swift`, delete the per-patch prefetch test.

In `Packages/Domain/Tests/DomainTests/Protocols/AudioProtocolsTests.swift`, remove the three methods from the in-file stub `PlaybackController` conformance.

- [ ] **Step 7: Build the whole project**

```bash
xcodegen generate
xcodebuild -project Folino.xcodeproj -scheme Folino \
    -destination 'platform=iOS Simulator,name=iPhone 17' \
    -skipPackagePluginValidation build 2>&1 | grep -E "error:|BUILD " | head
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 8: Run all tests**

```bash
xcodebuild -project Folino.xcodeproj -scheme Folino \
    -destination 'platform=iOS Simulator,name=iPhone 17' \
    -skipPackagePluginValidation test 2>&1 | tail -5
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 9: Commit**

```bash
git add Packages/Domain/Sources/Domain/Protocols/PlaybackController.swift \
        Packages/Domain/Tests/DomainTests/Protocols/AudioProtocolsTests.swift \
        Packages/Infrastructure/Sources/Audio/LivePlaybackController.swift \
        Packages/Infrastructure/Sources/Audio/LiveScoreAudioExporter.swift \
        Packages/Infrastructure/Tests/InfrastructureTests/Audio/LivePlaybackControllerTests.swift \
        Packages/Infrastructure/Tests/InfrastructureTests/Audio/LiveScoreAudioExporterTests.swift \
        Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift \
        Packages/Features/Reader/Sources/Reader/PlaybackMixerModel.swift \
        Packages/Features/Reader/Tests/ReaderTests/Fakes/FakePlaybackController.swift \
        Packages/Features/Reader/Tests/ReaderTests/ReaderViewModelPlaybackTests.swift \
        App/AppBootstrap.swift
git commit -m "Switch audio stack to GM-only soundfont path"
```

---

## Task 7: Launch hook — kick off auto-download

**Files:**
- Modify: `App/AppShellView.swift` (or whichever view receives the `.onAppear` that fires after `AppBootstrap.isReady`; grep `isReady` to locate)

- [ ] **Step 1: Add the launch hook**

```swift
// Inside AppShellView (or equivalent), in the .task / .onAppear that runs after isReady flips:
.task(id: bootstrap.isReady) {
    guard bootstrap.isReady else { return }
    await bootstrap.museScoreGeneralProvider?.startDownloadIfNeeded()
}
```

- [ ] **Step 2: Verify**

Build and launch the app on a Wi-Fi-connected simulator. With the toggle ON (default) and the file absent, observe the network activity in Console.app — `LiveMuseScoreGeneralProvider` should log download progress.

- [ ] **Step 3: Commit**

```bash
git add App/AppShellView.swift
git commit -m "Kick MuseScore_General download on launch when opted in"
```

---

## Task 8: Settings UI — SoundfontPresetView

**Files:**
- Create: `Packages/Features/Settings/Sources/Settings/Screens/SoundfontPresetView.swift`
- Modify: `Packages/Features/Settings/Sources/Settings/Screens/SettingsSheet.swift`
- Modify: `Packages/Features/Settings/Tests/SettingsTests/SettingsSheetTests.swift`

- [ ] **Step 1: Write the failing snapshot/preview-driven test**

Settings tests in this repo are light-touch. Add a smoke test that the new view can be instantiated with a stub provider and exposes the expected accessibility label states.

```swift
// Packages/Features/Settings/Tests/SettingsTests/SoundfontPresetViewTests.swift
import Domain
import Foundation
@testable import Settings
import Testing

@Suite struct SoundfontPresetViewTests {
    @Test func `view instantiates with a stub provider`() async {
        let view = SoundfontPresetView(provider: StubProvider())
        _ = view.body // forces View construction; SwiftUI throws if init / body is malformed
    }
}

private struct StubProvider: MuseScoreGeneralProvider {
    var isOptedIn: Bool { true }
    var isDownloaded: Bool { false }
    var museScoreGeneralFileURL: URL? { nil }
    var currentPreset: SoundfontPreset { .generalUserGS }
    func setOptedIn(_: Bool) async {}
    func downloadStateStream() -> AsyncStream<SoundfontDownloadState> { AsyncStream { _ in } }
    func startDownloadIfNeeded() async {}
    func startDownloadAllowingCellular() async {}
    func cancelDownload() async {}
    func deleteDownloaded() async {}
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cd Packages/Features/Settings && swift test --filter SoundfontPresetViewTests`
Expected: FAIL — `SoundfontPresetView` not defined.

- [ ] **Step 3: Implement `SoundfontPresetView`**

```swift
// Packages/Features/Settings/Sources/Settings/Screens/SoundfontPresetView.swift
import Domain
import SwiftUI
import UtilityUI

@MainActor
struct SoundfontPresetView: View {
    let provider: any MuseScoreGeneralProvider

    @State private var isOptedIn = true
    @State private var downloadState: SoundfontDownloadState = .idle
    @State private var canUseCellular = false

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $isOptedIn) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("settings.soundfont.musescore.title", bundle: .module)
                        Text("settings.soundfont.musescore.subtitle", bundle: .module)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .onChange(of: isOptedIn) { _, newValue in
                    Task { await provider.setOptedIn(newValue) }
                }
            } footer: {
                stateFooter
            }

            if isOptedIn, case .failed = downloadState {
                Section {
                    Button {
                        Task { await provider.startDownloadIfNeeded() }
                    } label: {
                        Label {
                            Text("settings.soundfont.retry", bundle: .module)
                        } icon: { Image(systemName: "arrow.clockwise") }
                    }
                }
            }

            if isOptedIn, !isCurrentlyDownloaded, canUseCellular {
                Section {
                    Button {
                        Task { await provider.startDownloadAllowingCellular() }
                    } label: {
                        Label {
                            Text("settings.soundfont.downloadOverCellular", bundle: .module)
                        } icon: { Image(systemName: "antenna.radiowaves.left.and.right") }
                    }
                } footer: {
                    Text("settings.soundfont.cellularWarning", bundle: .module)
                }
            }
        }
        .navigationTitle(Text("settings.soundfont.title", bundle: .module))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            isOptedIn = await provider.isOptedIn
            canUseCellular = true // always offer; user makes the call
            for await state in provider.downloadStateStream() {
                downloadState = state
            }
        }
    }

    private var isCurrentlyDownloaded: Bool {
        if case .downloaded = downloadState { return true }
        return false
    }

    @ViewBuilder
    private var stateFooter: some View {
        switch downloadState {
        case .idle:
            Text("settings.soundfont.state.idle", bundle: .module)
        case .downloading(let progress):
            VStack(alignment: .leading, spacing: 8) {
                Text("settings.soundfont.state.downloading", bundle: .module)
                ProgressView(value: progress)
            }
        case .downloaded:
            Text("settings.soundfont.state.downloaded", bundle: .module)
        case .failed(let reason):
            Text(verbatim: String(localized: "settings.soundfont.state.failed", bundle: .module) + " (\(reason))")
                .foregroundStyle(.red)
        }
    }
}
```

- [ ] **Step 4: Replace the SettingsSheet entry**

In `Packages/Features/Settings/Sources/Settings/Screens/SettingsSheet.swift`:

- Drop the `soundfontResolver` and `presetCatalog` constructor params; add `provider: (any MuseScoreGeneralProvider)?`.
- Replace `storageSection(resolver:)` with a `storageSection(provider:)` that links to `SoundfontPresetView(provider: provider)`.
- Update `#Preview` blocks: drop `PreviewResolver`, supply a `StubProvider`.

Also update `Packages/Features/Settings/Tests/SettingsTests/SettingsSheetTests.swift`: replace `StubSoundfontResolver` with a `StubProvider` and pass it via the new constructor param.

- [ ] **Step 5: Wire from AppShellView**

In whichever view instantiates `SettingsSheet`, pass `bootstrap.museScoreGeneralProvider` for the `provider:` param.

- [ ] **Step 6: Run tests + build**

```bash
xcodebuild -project Folino.xcodeproj -scheme Folino \
    -destination 'platform=iOS Simulator,name=iPhone 17' \
    -skipPackagePluginValidation test 2>&1 | tail -5
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 7: Commit**

```bash
git add Packages/Features/Settings/Sources/Settings/Screens/SoundfontPresetView.swift \
        Packages/Features/Settings/Sources/Settings/Screens/SettingsSheet.swift \
        Packages/Features/Settings/Tests/SettingsTests/SettingsSheetTests.swift \
        Packages/Features/Settings/Tests/SettingsTests/SoundfontPresetViewTests.swift \
        App/<whichever-view-passes-resolver-to-settings>.swift
git commit -m "Add SoundfontPresetView Settings screen"
```

---

## Task 9: Localization strings

**Files:**
- Modify: `Packages/Features/Settings/Sources/Settings/Resources/Localizable.xcstrings`

- [ ] **Step 1: Add the new keys**

The keys referenced in Task 8's `SoundfontPresetView`:

- `settings.soundfont.title` → "サウンドフォント" / "Soundfont" (likely already present — confirm)
- `settings.soundfont.musescore.title` → "MuseScore_General (高品質)" / "MuseScore_General (high quality)"
- `settings.soundfont.musescore.subtitle` → "206 MB の追加ダウンロード。オフは GeneralUser GS で再生。" / "206 MB optional download. Off uses bundled GeneralUser GS."
- `settings.soundfont.state.idle` → "未ダウンロード — Wi-Fi 接続時に自動取得します。" / "Not downloaded — will fetch automatically on Wi-Fi."
- `settings.soundfont.state.downloading` → "ダウンロード中" / "Downloading"
- `settings.soundfont.state.downloaded` → "ダウンロード済み — MuseScore_General で再生中。" / "Downloaded — playing with MuseScore_General."
- `settings.soundfont.state.failed` → "ダウンロード失敗" / "Download failed"
- `settings.soundfont.retry` → "再試行" / "Retry"
- `settings.soundfont.downloadOverCellular` → "モバイル通信でダウンロード" / "Download over cellular"
- `settings.soundfont.cellularWarning` → "モバイル通信で 206 MB をダウンロードします。" / "Downloads 206 MB over cellular."

Use Xcode's String Catalog editor or hand-edit the JSON. Mark each entry as `state: "translated"` for both `en` and `ja`.

- [ ] **Step 2: Remove obsolete keys**

Search the catalog for the cache-screen keys we're removing along with `SoundfontCacheView`:

```bash
grep -E '"settings\.soundfont\.(cache|patch|delete|clear|bundled)' \
    Packages/Features/Settings/Sources/Settings/Resources/Localizable.xcstrings
```

Remove each match. Re-run after editing — expect zero matches.

- [ ] **Step 3: Build and verify**

```bash
xcodebuild -project Folino.xcodeproj -scheme Folino \
    -destination 'platform=iOS Simulator,name=iPhone 17' \
    -skipPackagePluginValidation build 2>&1 | grep -E "warning:.*xcstrings|error:" | head
```

Expected: no `stale string` warnings, no errors.

- [ ] **Step 4: Commit**

```bash
git add Packages/Features/Settings/Sources/Settings/Resources/Localizable.xcstrings
git commit -m "Localize SoundfontPresetView strings"
```

---

## Task 10: Cleanup — delete the per-patch system

**Files:**
- Delete: `Packages/Infrastructure/Sources/Soundfonts/MuseScoreSF2Resolver.swift`
- Delete: `Packages/Infrastructure/Tests/InfrastructureTests/Soundfonts/MuseScoreSF2ResolverTests.swift`
- Delete: `Packages/Features/Settings/Sources/Settings/Screens/SoundfontCacheView.swift`
- Delete: `Packages/Domain/Sources/Domain/Models/SoundfontPatch.swift`
- Delete: `Packages/Domain/Sources/Domain/Protocols/SoundfontResolver.swift`
- Delete: `Packages/Domain/Sources/Domain/Protocols/PrecisePatchProbe.swift`
- Delete: `App/Resources/Soundfonts/000_073.sf2`
- Delete: `App/Resources/Soundfonts/128_000.sf2`
- Search-and-remove: `SoundfontPatchKey` type (likely in `Packages/Domain/Sources/Domain/Models/` or re-exported via `DomainExports.swift`) and `DomainError.soundfontDownloadFailed` case (in `DomainError.swift`).

- [ ] **Step 1: Delete the files**

```bash
rm Packages/Infrastructure/Sources/Soundfonts/MuseScoreSF2Resolver.swift
rm Packages/Infrastructure/Tests/InfrastructureTests/Soundfonts/MuseScoreSF2ResolverTests.swift
rm Packages/Features/Settings/Sources/Settings/Screens/SoundfontCacheView.swift
rm Packages/Domain/Sources/Domain/Models/SoundfontPatch.swift
rm Packages/Domain/Sources/Domain/Protocols/SoundfontResolver.swift
rm Packages/Domain/Sources/Domain/Protocols/PrecisePatchProbe.swift
rm App/Resources/Soundfonts/000_073.sf2
rm App/Resources/Soundfonts/128_000.sf2
```

- [ ] **Step 2: Find and remove `SoundfontPatchKey`**

```bash
grep -rn "SoundfontPatchKey\|soundfontDownloadFailed" \
    Packages App --include="*.swift" | grep -v "\.build/"
```

For each match, decide:
- Type declaration / case declaration → delete.
- Test reference → delete the test.
- Any remaining caller → that's a missed Reader / Audio call site from Task 6; clean it up here.

- [ ] **Step 3: Remove `Infrastructure.InfrastructureTests.swift` sanity reference**

`Packages/Infrastructure/Tests/InfrastructureTests/InfrastructureTests.swift:14` mentions `_ = MuseScoreSF2Resolver.self`. Replace with `_ = GMSoundfontResolver.self`.

- [ ] **Step 4: Build and test**

```bash
xcodegen generate
xcodebuild -project Folino.xcodeproj -scheme Folino \
    -destination 'platform=iOS Simulator,name=iPhone 17' \
    -skipPackagePluginValidation test 2>&1 | grep -E "error:|TEST " | head
```

Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add -A   # ok here because the only changes are deletions + the InfrastructureTests sanity check
git commit -m "Retire per-patch soundfont download system"
```

(`-A` is acceptable for this commit because the working tree should contain only the listed deletions + one-line change. Confirm with `git status` before staging.)

---

## Self-Review

**Spec coverage** (verified against the brainstorm spec):

| Requirement | Task |
| --- | --- |
| Bundle GeneralUser GS as default | Task 3 |
| Wi-Fi-only auto-download on launch with auto-retry | Tasks 5, 7 |
| Manual cellular download button | Tasks 5, 8 |
| Download progress / state visible in Settings | Task 8 |
| Opt-out toggle: deletes file when opting out, cancels future downloads | Task 5 (`setOptedIn(false)`) |
| Silent fallback to GeneralUser GS on failure | Task 4 (`GMSoundfontResolver`), Task 5 (`currentPreset` derivation) |
| Per-patch system retired | Tasks 6, 10 |

**Placeholder scan**: One placeholder remains intentionally — the GitHub release URL in Task 5's `LiveMuseScoreGeneralProvider` default-init (`v2.0.0` is a guess). The plan flags this as a prerequisite to be confirmed before Task 5 executes. No other placeholders.

**Type consistency**: `MuseScoreGeneralProvider` is the same name in every task. `GMSoundfontResolver` is the same name. `SoundfontPreset` cases are `generalUserGS` / `museScoreGeneral` everywhere. `SoundfontDownloadState` cases are `idle` / `downloading(progress:)` / `downloaded` / `failed(reason:)` everywhere.

---

## Open prerequisites (do before Task 5)

1. **Publish `MuseScore_General.sf2`** as an asset on `jiyimeta/musescore-general-sf2-split`. Confirm the exact tag and asset URL; replace the default in `LiveMuseScoreGeneralProvider.init(downloadURL:)`.
2. **License audit** for both SF2 files — confirm that GeneralUser GS (MIT-compatible) and MuseScore_General (MIT) are acceptable for inclusion (already on `jiyimeta/musescore-general-sf2-split` so likely fine). Add license texts to `LicenseList` if the build-time plugin doesn't already pick them up from the upstream release.
