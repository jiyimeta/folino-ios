# Shared SoundFont via App Group — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Share the ~206 MB `MuseScore_General.sf2` between Folino and VocalTuner through a `group.com.KeyNumber.shared` App Group container — migrating Folino's existing private copy without breaking shipped users, and reference-counting reclaim so one app's opt-out never strands the other.

**Architecture:** Both apps point their existing soundfont download/resolver at the shared container. Folino runs a one-time idempotent move+dedup migration on launch. A shared marker-file + `canOpenURL` reference count governs deletion on opt-out. Two small pure types (`SoundfontContainerMigration`, `SharedSoundfontReclaimer`) carry the logic and are unit-tested with temp dirs; UIKit `canOpenURL` is injected behind `InstalledAppChecking`.

**Tech Stack:** Swift 6.3 (Folino) / Swift 6 (VocalTuner), XcodeGen, SwiftPM, Swift Testing for new tests. Folino: SPM/GRDB, foreground `URLSession`. VocalTuner: CocoaPods/Realm, background `URLSession`.

**Spec:** `docs/superpowers/specs/2026-06-26-shared-soundfont-app-group-design.md`

## Global Constraints

- App Group: **`group.com.KeyNumber.shared`** (both iOS targets). Team **`944L8NCGUH`**. iOS-only (VocalTuner macOS target excluded).
- Bundle IDs: Folino `com.KeyNumber.Folino`, VocalTuner `com.KeyNumber.VocalTuner`.
- Canonical shared file: **`MuseScore_General.sf2`** (unversioned) at `<container>/Soundfonts/MuseScore_General.sf2`.
- Validity threshold: file size **≥ 150 MB** (`150 * 1024 * 1024`).
- URL schemes: Folino `folino` (already declared), VocalTuner `vocaltuner` (new, declaration only).
- Markers: `<container>/Soundfonts/consumers/<bundle-id>`; **presence ⇔ that app is opted in**; body JSON `{"displayName": "<own CFBundleDisplayName>"}`. Each app publishes its OWN display name (`folino` stays lowercase).
- Reclaim rule: delete the shared file **iff** this app is opted out **and** no installed sibling (per `canOpenURL`) has a marker. Never delete while this app is opted in.
- "In use" note copy (Folino Settings), `%@` = sibling display name:
  - EN: `Shared with %@, so it’s kept on your device. To free this storage, turn it off in %@ as well.`
  - JA: `%@ と共有しているため端末に残しています。容量を解放するには %@ 側でもオフにしてください。`
- Don't break shipped Folino users: every migration/reclaim filesystem call is `try?`; resolver falls back to legacy/private path when the container is unavailable; legacy copy deleted only after the shared copy is confirmed valid.
- Deferred (do NOT implement): atomic `replaceItemAt` hardening; macOS sharing; score-file sharing; the symmetric "kept because folino is using it" note in VocalTuner (optional only).

**Folino package test command** (run from `Packages/Infrastructure/`):
```
xcodebuild test -scheme Infrastructure-Package -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation -only-testing:Infrastructure-Package/InfrastructureTests
```
**Folino app build command:**
```
xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation build
```
**VocalTuner build/test command** (run from VocalTuner repo root):
```
xcodebuild -project VocalTuner.xcodeproj -scheme VocalTunerDev -destination 'platform=iOS Simulator,name=iPhone 15' test
```

---

# Phase A — Folino (`/Users/kiichi/Developer/Personal/ios-apps/Folino-iOS`)

Phase A is independently shippable: until VocalTuner ships, `canOpenURL("vocaltuner://")` is false, so Folino is the sole consumer and opt-out deletes immediately — identical to today.

## Task A1: `SoundfontContainerMigration` (pure move+dedup)

**Files:**
- Create: `Packages/Infrastructure/Sources/Soundfonts/SoundfontContainerMigration.swift`
- Test: `Packages/Infrastructure/Tests/InfrastructureTests/Soundfonts/SoundfontContainerMigrationTests.swift`

**Interfaces:**
- Produces: `struct SoundfontContainerMigration { init(fileManager:); func reconcile(fileName:String, sharedDirectory:URL, legacyDirectory:URL, minimumValidByteSize:Int64) }`

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import Soundfonts

@Suite struct SoundfontContainerMigrationTests {
    private let fm = FileManager.default
    private let name = "MuseScore_General.sf2"
    private let minBytes: Int64 = 100   // small threshold for fast tests

    private func tempDir() -> URL {
        let url = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func write(_ dir: URL, bytes: Int) {
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try? Data(count: bytes).write(to: dir.appendingPathComponent(name))
    }
    private func exists(_ dir: URL) -> Bool { fm.fileExists(atPath: dir.appendingPathComponent(name).path) }

    @Test func folinoFirst_movesLegacyIntoShared() {
        let shared = tempDir(), legacy = tempDir()
        write(legacy, bytes: 200)
        SoundfontContainerMigration().reconcile(
            fileName: name, sharedDirectory: shared, legacyDirectory: legacy, minimumValidByteSize: minBytes)
        #expect(exists(shared))
        #expect(!exists(legacy))
    }

    @Test func vocalTunerFirst_deletesRedundantLegacy() {
        let shared = tempDir(), legacy = tempDir()
        write(shared, bytes: 200)   // sibling already populated shared
        write(legacy, bytes: 200)   // existing Folino user still has the private copy
        SoundfontContainerMigration().reconcile(
            fileName: name, sharedDirectory: shared, legacyDirectory: legacy, minimumValidByteSize: minBytes)
        #expect(exists(shared))
        #expect(!exists(legacy))    // redundant legacy removed
    }

    @Test func freshInstall_noLegacy_noop() {
        let shared = tempDir(), legacy = tempDir()
        SoundfontContainerMigration().reconcile(
            fileName: name, sharedDirectory: shared, legacyDirectory: legacy, minimumValidByteSize: minBytes)
        #expect(!exists(shared))
        #expect(!exists(legacy))
    }

    @Test func partialLegacy_belowThreshold_notMovedNotDeleted() {
        let shared = tempDir(), legacy = tempDir()
        write(legacy, bytes: 10)   // truncated
        SoundfontContainerMigration().reconcile(
            fileName: name, sharedDirectory: shared, legacyDirectory: legacy, minimumValidByteSize: minBytes)
        #expect(!exists(shared))
        #expect(exists(legacy))    // left for re-download
    }

    @Test func equalDirs_noop() {
        let dir = tempDir()
        write(dir, bytes: 200)
        SoundfontContainerMigration().reconcile(
            fileName: name, sharedDirectory: dir, legacyDirectory: dir, minimumValidByteSize: minBytes)
        #expect(exists(dir))
    }

    @Test func idempotent_secondRunNoop() {
        let shared = tempDir(), legacy = tempDir()
        write(legacy, bytes: 200)
        let m = SoundfontContainerMigration()
        m.reconcile(fileName: name, sharedDirectory: shared, legacyDirectory: legacy, minimumValidByteSize: minBytes)
        m.reconcile(fileName: name, sharedDirectory: shared, legacyDirectory: legacy, minimumValidByteSize: minBytes)
        #expect(exists(shared))
        #expect(!exists(legacy))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run (from `Packages/Infrastructure/`):
```
xcodebuild test -scheme Infrastructure-Package -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation -only-testing:Infrastructure-Package/InfrastructureTests/SoundfontContainerMigrationTests
```
Expected: FAIL — `cannot find 'SoundfontContainerMigration' in scope`.

- [ ] **Step 3: Implement `SoundfontContainerMigration`**

```swift
import Foundation

/// One-time, idempotent reconcile of the high-quality SoundFont to a single copy in the shared App Group container.
/// Existence-driven (no "did I migrate" flag) so it self-heals and is safe to run on every launch. See the
/// shared-soundfont spec for the move-then-dedup invariant.
public struct SoundfontContainerMigration: Sendable {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func reconcile(
        fileName: String,
        sharedDirectory: URL,
        legacyDirectory: URL,
        minimumValidByteSize: Int64,
    ) {
        // When the container is unavailable both resolve to the private dir — nothing to reconcile.
        guard sharedDirectory != legacyDirectory else { return }
        try? fileManager.createDirectory(at: sharedDirectory, withIntermediateDirectories: true)
        excludeFromBackup(sharedDirectory)
        let sharedFile = sharedDirectory.appendingPathComponent(fileName)
        let legacyFile = legacyDirectory.appendingPathComponent(fileName)

        // ① Populate shared from a valid legacy copy when shared is empty/invalid (intra-volume rename: instant).
        if !isValid(sharedFile, minimumValidByteSize), isValid(legacyFile, minimumValidByteSize) {
            try? fileManager.moveItem(at: legacyFile, to: sharedFile)
            excludeFromBackup(sharedFile)
        }
        // ② Drop the redundant legacy copy once shared holds a valid file (the "sibling downloaded first" case).
        if isValid(sharedFile, minimumValidByteSize), fileManager.fileExists(atPath: legacyFile.path) {
            try? fileManager.removeItem(at: legacyFile)
        }
    }

    private func isValid(_ url: URL, _ minimumBytes: Int64) -> Bool {
        guard let size = try? fileManager.attributesOfItem(atPath: url.path)[.size] as? Int64 else { return false }
        return size >= minimumBytes
    }

    private func excludeFromBackup(_ url: URL) {
        var mutable = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? mutable.setResourceValues(values)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run the same command as Step 2. Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```
git add Packages/Infrastructure/Sources/Soundfonts/SoundfontContainerMigration.swift Packages/Infrastructure/Tests/InfrastructureTests/Soundfonts/SoundfontContainerMigrationTests.swift
git commit -m "feat(soundfonts): add SoundfontContainerMigration move+dedup reconcile"
```

## Task A2: `SharedSoundfontReclaimer` (markers + reference count)

**Files:**
- Create: `Packages/Infrastructure/Sources/Soundfonts/SharedSoundfontReclaimer.swift`
- Test: `Packages/Infrastructure/Tests/InfrastructureTests/Soundfonts/SharedSoundfontReclaimerTests.swift`

**Interfaces:**
- Produces:
  - `struct SiblingApp { let bundleId: String; let urlScheme: String }`
  - `protocol InstalledAppChecking: Sendable { func isInstalled(urlScheme: String) -> Bool }`
  - `struct SharedSoundfontReclaimer { init(fileManager:soundfontsDirectory:soundfontFileName:minimumValidByteSize:ownBundleId:ownDisplayName:siblings:installedChecker:); func syncOwnMarker(isOptedIn:Bool); func siblingInUseDisplayName() -> String?; func reclaimIfUnused(isOptedIn:Bool) }`

- [ ] **Step 1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import Soundfonts

private final class FakeChecker: InstalledAppChecking, @unchecked Sendable {
    var installed: Set<String>
    init(_ installed: Set<String>) { self.installed = installed }
    func isInstalled(urlScheme: String) -> Bool { installed.contains(urlScheme) }
}

@Suite struct SharedSoundfontReclaimerTests {
    private let fm = FileManager.default
    private let name = "MuseScore_General.sf2"
    private let minBytes: Int64 = 100
    private let sibling = SiblingApp(bundleId: "com.KeyNumber.VocalTuner", urlScheme: "vocaltuner")

    private func dir() -> URL {
        let url = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func writeSoundfont(_ d: URL, bytes: Int) {
        try? Data(count: bytes).write(to: d.appendingPathComponent(name))
    }
    private func sfExists(_ d: URL) -> Bool { fm.fileExists(atPath: d.appendingPathComponent(name).path) }
    private func markerExists(_ d: URL, _ id: String) -> Bool {
        fm.fileExists(atPath: d.appendingPathComponent("consumers").appendingPathComponent(id).path)
    }
    private func make(_ d: URL, ownOptedInDoesNotMatter checker: FakeChecker) -> SharedSoundfontReclaimer {
        SharedSoundfontReclaimer(
            fileManager: fm, soundfontsDirectory: d, soundfontFileName: name, minimumValidByteSize: minBytes,
            ownBundleId: "com.KeyNumber.Folino", ownDisplayName: "folino",
            siblings: [sibling], installedChecker: checker)
    }

    @Test func syncOwnMarker_writesWhenOptedIn_removesWhenOut() {
        let d = dir(); let r = make(d, ownOptedInDoesNotMatter: FakeChecker([]))
        r.syncOwnMarker(isOptedIn: true)
        #expect(markerExists(d, "com.KeyNumber.Folino"))
        r.syncOwnMarker(isOptedIn: false)
        #expect(!markerExists(d, "com.KeyNumber.Folino"))
    }

    @Test func reclaim_optedOut_noSibling_deletesFile() {
        let d = dir(); writeSoundfont(d, bytes: 200)
        make(d, ownOptedInDoesNotMatter: FakeChecker([])).reclaimIfUnused(isOptedIn: false)
        #expect(!sfExists(d))
    }

    @Test func reclaim_optedIn_keepsFile() {
        let d = dir(); writeSoundfont(d, bytes: 200)
        make(d, ownOptedInDoesNotMatter: FakeChecker([])).reclaimIfUnused(isOptedIn: true)
        #expect(sfExists(d))
    }

    @Test func reclaim_optedOut_installedSiblingOptedIn_keepsFile() {
        let d = dir(); writeSoundfont(d, bytes: 200)
        // sibling marker present + installed
        try? fm.createDirectory(at: d.appendingPathComponent("consumers"), withIntermediateDirectories: true)
        try? Data("{}".utf8).write(to: d.appendingPathComponent("consumers").appendingPathComponent(sibling.bundleId))
        make(d, ownOptedInDoesNotMatter: FakeChecker([sibling.urlScheme])).reclaimIfUnused(isOptedIn: false)
        #expect(sfExists(d))
    }

    @Test func reclaim_optedOut_siblingMarkerButNotInstalled_deletesAndPrunes() {
        let d = dir(); writeSoundfont(d, bytes: 200)
        try? fm.createDirectory(at: d.appendingPathComponent("consumers"), withIntermediateDirectories: true)
        try? Data("{}".utf8).write(to: d.appendingPathComponent("consumers").appendingPathComponent(sibling.bundleId))
        make(d, ownOptedInDoesNotMatter: FakeChecker([])).reclaimIfUnused(isOptedIn: false)  // sibling NOT installed
        #expect(!sfExists(d))
        #expect(!markerExists(d, sibling.bundleId))  // stale marker pruned
    }

    @Test func siblingInUseDisplayName_returnsPublishedName_whenInstalledAndMarkerPresent() {
        let d = dir()
        try? fm.createDirectory(at: d.appendingPathComponent("consumers"), withIntermediateDirectories: true)
        try? Data(#"{"displayName":"VocalTuner"}"#.utf8)
            .write(to: d.appendingPathComponent("consumers").appendingPathComponent(sibling.bundleId))
        let name = make(d, ownOptedInDoesNotMatter: FakeChecker([sibling.urlScheme])).siblingInUseDisplayName()
        #expect(name == "VocalTuner")
    }

    @Test func siblingInUseDisplayName_nil_whenNotInstalled() {
        let d = dir()
        try? fm.createDirectory(at: d.appendingPathComponent("consumers"), withIntermediateDirectories: true)
        try? Data(#"{"displayName":"VocalTuner"}"#.utf8)
            .write(to: d.appendingPathComponent("consumers").appendingPathComponent(sibling.bundleId))
        #expect(make(d, ownOptedInDoesNotMatter: FakeChecker([])).siblingInUseDisplayName() == nil)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run (from `Packages/Infrastructure/`):
```
xcodebuild test -scheme Infrastructure-Package -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation -only-testing:Infrastructure-Package/InfrastructureTests/SharedSoundfontReclaimerTests
```
Expected: FAIL — `cannot find 'SharedSoundfontReclaimer' in scope`.

- [ ] **Step 3: Implement `SharedSoundfontReclaimer`**

```swift
import Foundation

public struct SiblingApp: Sendable, Equatable {
    public let bundleId: String
    public let urlScheme: String
    public init(bundleId: String, urlScheme: String) {
        self.bundleId = bundleId
        self.urlScheme = urlScheme
    }
}

/// Abstracts `UIApplication.canOpenURL` so the reclaim logic stays UIKit-free and unit-testable.
public protocol InstalledAppChecking: Sendable {
    func isInstalled(urlScheme: String) -> Bool
}

/// Reference-counted reclaim of the shared high-quality SoundFont. Pure file I/O over injected directories. The marker
/// contract (`consumers/<bundleId>` whose presence means "opted in", JSON body `{"displayName": …}`) and the delete
/// rule (delete iff this app is opted out AND no installed sibling is opted in) are shared verbatim with VocalTuner —
/// see the shared-soundfont spec.
public struct SharedSoundfontReclaimer: Sendable {
    private let fileManager: FileManager
    private let soundfontsDirectory: URL
    private let soundfontFileName: String
    private let minimumValidByteSize: Int64
    private let ownBundleId: String
    private let ownDisplayName: String
    private let siblings: [SiblingApp]
    private let installedChecker: any InstalledAppChecking

    public init(
        fileManager: FileManager = .default,
        soundfontsDirectory: URL,
        soundfontFileName: String,
        minimumValidByteSize: Int64,
        ownBundleId: String,
        ownDisplayName: String,
        siblings: [SiblingApp],
        installedChecker: any InstalledAppChecking,
    ) {
        self.fileManager = fileManager
        self.soundfontsDirectory = soundfontsDirectory
        self.soundfontFileName = soundfontFileName
        self.minimumValidByteSize = minimumValidByteSize
        self.ownBundleId = ownBundleId
        self.ownDisplayName = ownDisplayName
        self.siblings = siblings
        self.installedChecker = installedChecker
    }

    private var consumersDirectory: URL { soundfontsDirectory.appendingPathComponent("consumers", isDirectory: true) }
    private var soundfontFileURL: URL { soundfontsDirectory.appendingPathComponent(soundfontFileName) }
    private func markerURL(_ bundleId: String) -> URL { consumersDirectory.appendingPathComponent(bundleId) }

    /// Publishes this app's opt-in into the shared container. Presence of the marker means "opted in".
    public func syncOwnMarker(isOptedIn: Bool) {
        if isOptedIn {
            try? fileManager.createDirectory(at: consumersDirectory, withIntermediateDirectories: true)
            if let data = try? JSONSerialization.data(withJSONObject: ["displayName": ownDisplayName]) {
                try? data.write(to: markerURL(ownBundleId), options: .atomic)
            }
        } else {
            try? fileManager.removeItem(at: markerURL(ownBundleId))
        }
    }

    /// Display name of an installed sibling that is currently opted in (for the "in use" note), or nil.
    public func siblingInUseDisplayName() -> String? {
        for sibling in siblings where installedChecker.isInstalled(urlScheme: sibling.urlScheme) {
            let url = markerURL(sibling.bundleId)
            guard fileManager.fileExists(atPath: url.path) else { continue }
            if let data = try? Data(contentsOf: url),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: String],
               let name = json["displayName"] {
                return name
            }
            return sibling.bundleId  // marker present but unreadable — fall back to the bundle id
        }
        return nil
    }

    /// Deletes the shared file iff this app is opted out AND no installed sibling is opted in. Prunes markers belonging
    /// to siblings that are no longer installed. Never touches the file while this app is opted in.
    public func reclaimIfUnused(isOptedIn: Bool) {
        defer { pruneStaleSiblingMarkers() }
        guard isValidSoundfont() else { return }
        let anyInstalledSiblingOptedIn = siblings.contains { sibling in
            installedChecker.isInstalled(urlScheme: sibling.urlScheme)
                && fileManager.fileExists(atPath: markerURL(sibling.bundleId).path)
        }
        if !isOptedIn, !anyInstalledSiblingOptedIn {
            try? fileManager.removeItem(at: soundfontFileURL)
        }
    }

    private func pruneStaleSiblingMarkers() {
        for sibling in siblings where !installedChecker.isInstalled(urlScheme: sibling.urlScheme) {
            try? fileManager.removeItem(at: markerURL(sibling.bundleId))
        }
    }

    private func isValidSoundfont() -> Bool {
        guard let size = try? fileManager.attributesOfItem(atPath: soundfontFileURL.path)[.size] as? Int64 else {
            return false
        }
        return size >= minimumValidByteSize
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run the same command as Step 2. Expected: PASS (7 tests).

- [ ] **Step 5: Commit**

```
git add Packages/Infrastructure/Sources/Soundfonts/SharedSoundfontReclaimer.swift Packages/Infrastructure/Tests/InfrastructureTests/Soundfonts/SharedSoundfontReclaimerTests.swift
git commit -m "feat(soundfonts): add SharedSoundfontReclaimer reference-counted reclaim"
```

## Task A3: `AppPaths` shared-container resolution

**Files:**
- Modify: `App/AppPaths.swift`

**Interfaces:**
- Produces: `AppPaths.sharedAppGroupIdentifier: String`, `AppPaths.sharedSoundfontsDirectory: URL?`, `AppPaths.legacySoundfontsDirectory: URL`, changed `AppPaths.soundfontsDirectory: URL`.

- [ ] **Step 1: Replace the `soundfontsDirectory` accessor**

Replace lines 20-28 (`/// Library/Application Support/Soundfonts/ …` through the closing brace of `soundfontsDirectory`) with:

```swift
    /// The cross-app shared App Group container. Soundfonts (and, later, scores) live here so Folino and VocalTuner
    /// share one copy. See `docs/superpowers/specs/2026-06-26-shared-soundfont-app-group-design.md`.
    static let sharedAppGroupIdentifier = "group.com.KeyNumber.shared"

    /// `<shared container>/Soundfonts/`. `nil` when the container is unavailable (entitlement/provisioning gap) — the
    /// resolver and migration both degrade to `legacySoundfontsDirectory` so playback never breaks.
    static var sharedSoundfontsDirectory: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: sharedAppGroupIdentifier)?
            .appending(path: "Soundfonts")
    }

    /// The pre-sharing private location (`Library/Application Support/Soundfonts/`). Migration source + degraded
    /// fallback. Application Support (not Caches) so iOS storage cleanup does not evict a 206 MB opted-in asset.
    static var legacySoundfontsDirectory: URL {
        guard let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            fatalError("Application Support directory unavailable — sandbox is broken")
        }
        return url.appending(path: "Soundfonts")
    }

    /// Primary soundfont location used by the provider/resolver: the shared container when available, else legacy.
    static var soundfontsDirectory: URL {
        sharedSoundfontsDirectory ?? legacySoundfontsDirectory
    }
```

- [ ] **Step 2: Build to verify it compiles**

```
xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation build
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```
git add App/AppPaths.swift
git commit -m "feat(app): resolve soundfontsDirectory to shared App Group container"
```

## Task A4: Live `InstalledAppChecking` + wire migration into bootstrap

**Files:**
- Create: `App/UIKitInstalledAppChecker.swift`
- Modify: `App/AppBootstrap.swift`

**Interfaces:**
- Consumes: `SoundfontContainerMigration` (A1), `AppPaths.sharedSoundfontsDirectory`/`legacySoundfontsDirectory` (A3), `SoundfontPreset.highQuality.fileName`.
- Produces: `struct UIKitInstalledAppChecker: InstalledAppChecking`; `AppBootstrap.reconcileSoundfontToSharedContainerIfNeeded()`; `AppBootstrap.soundfontMinimumValidByteSize`, `AppBootstrap.soundfontSiblings`.

- [ ] **Step 1: Create the live installed-app checker**

```swift
import Soundfonts
import UIKit

/// Live `InstalledAppChecking` backed by `UIApplication.canOpenURL`. Requires the queried scheme to be listed in
/// `LSApplicationQueriesSchemes` (see `App/Info.plist`).
struct UIKitInstalledAppChecker: InstalledAppChecking {
    func isInstalled(urlScheme: String) -> Bool {
        guard let url = URL(string: "\(urlScheme)://") else { return false }
        return UIApplication.shared.canOpenURL(url)
    }
}
```

- [ ] **Step 2: Add the reconcile call + shared constants to `AppBootstrap`**

In `App/AppBootstrap.swift`, add these constants near `legacySoundfontCacheCleanupDidRunKey` (around line 209):

```swift
    static let soundfontMinimumValidByteSize: Int64 = 150 * 1024 * 1024
    static let soundfontSiblings: [SiblingApp] = [
        SiblingApp(bundleId: "com.KeyNumber.VocalTuner", urlScheme: "vocaltuner"),
    ]
```

Add the reconcile method (next to `prepareDirectories()`):

```swift
    /// Move-then-dedup the high-quality SoundFont into the shared App Group container before the provider is built.
    /// No-op when the container is unavailable (resolvers degrade to the legacy private path).
    private func reconcileSoundfontToSharedContainerIfNeeded() {
        guard let shared = AppPaths.sharedSoundfontsDirectory else { return }
        SoundfontContainerMigration().reconcile(
            fileName: SoundfontPreset.highQuality.fileName,
            sharedDirectory: shared,
            legacyDirectory: AppPaths.legacySoundfontsDirectory,
            minimumValidByteSize: Self.soundfontMinimumValidByteSize,
        )
    }
```

In `start()`, call it immediately after `cleanupLegacySoundfontCacheIfNeeded()` (line 60) and before `installAudioStack` runs. Change:

```swift
            try prepareDirectories()
            cleanupLegacySoundfontCacheIfNeeded()
```
to:
```swift
            try prepareDirectories()
            cleanupLegacySoundfontCacheIfNeeded()
            reconcileSoundfontToSharedContainerIfNeeded()
```

Add `import Soundfonts` is already present (line 11). Confirm `SiblingApp` resolves (it's in `Soundfonts`).

- [ ] **Step 3: Build to verify it compiles**

```
xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation build
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```
git add App/UIKitInstalledAppChecker.swift App/AppBootstrap.swift
git commit -m "feat(app): run soundfont container migration at launch"
```

## Task A5: Wire the reclaimer into the provider (opt-out reference count)

**Files:**
- Modify: `Packages/Infrastructure/Sources/Soundfonts/LiveMuseScoreGeneralProvider.swift`
- Modify: `App/AppBootstrap.swift`

**Interfaces:**
- Consumes: `SharedSoundfontReclaimer` (A2), `UIKitInstalledAppChecker` (A4).
- Produces on the provider: `init(..., reclaimer: SharedSoundfontReclaimer? = nil)`; `reconcileSharedSoundfontMarkersAtLaunch()`; `handleForeground()`; `refreshDownloadStateFromDisk()`; `var soundfontKeptBySiblingDisplayName: String?`.

- [ ] **Step 1: Add the reclaimer to the provider**

In `LiveMuseScoreGeneralProvider.swift`, add a stored property and init parameter:

```swift
    @ObservationIgnored private let reclaimer: SharedSoundfontReclaimer?
```

Add `reclaimer: SharedSoundfontReclaimer? = nil,` as the last parameter of `init(...)` (after `cellularSession:`), and assign `self.reclaimer = reclaimer` in the body.

- [ ] **Step 2: Reference-count opt-out, publish marker on opt-in/install**

Replace `setOptedIn(_:)` (lines 102-111) with:

```swift
    public func setOptedIn(_ value: Bool) {
        defaults.set(value, forKey: Self.optInKey)
        isOptedIn = value
        if value {
            reclaimer?.syncOwnMarker(isOptedIn: true)
            startDownloadIfNeeded()
        } else {
            cancelDownload()
            if let reclaimer {
                reclaimer.syncOwnMarker(isOptedIn: false)
                reclaimer.reclaimIfUnused(isOptedIn: false)
            } else {
                deleteDownloaded()  // legacy single-app behavior when no shared reclaimer is wired (e.g. unit tests)
            }
        }
    }
```

In `handleDownloadFinished(temporaryURL:)`, after the successful `downloadState = … .finished` line (line 187), add:

```swift
            reclaimer?.syncOwnMarker(isOptedIn: true)
```

- [ ] **Step 3: Add launch/foreground hooks**

Add these methods to the provider (after `handlePathChange`):

```swift
    /// Called once at launch (after migration). Publishes the current opt-in as a marker and reclaims the shared file
    /// if this app is opted out and no installed sibling wants it.
    public func reconcileSharedSoundfontMarkersAtLaunch() {
        reclaimer?.syncOwnMarker(isOptedIn: isOptedIn)
        reclaimer?.reclaimIfUnused(isOptedIn: isOptedIn)
    }

    /// Called on scene-phase `.active`. Reflects a copy a sibling downloaded while we were backgrounded, and reclaims
    /// if a sibling opted out / was deleted while we were away and we are opted out.
    public func handleForeground() {
        refreshDownloadStateFromDisk()
        reclaimer?.reclaimIfUnused(isOptedIn: isOptedIn)
    }

    /// Re-derive `downloadState` from disk (App Groups give no cross-process change notification).
    public func refreshDownloadStateFromDisk() {
        let exists = FileManager.default.fileExists(atPath: targetFileURL.path)
        downloadState = SoundfontDownloadReducer.nextState(downloadState, on: .syncedFromDisk(fileExists: exists))
    }

    /// Sibling display name keeping the (opted-out) shared file on device, for the Settings "in use" note; nil unless
    /// this app is opted out, the shared file exists, and an installed sibling is opted in.
    public var soundfontKeptBySiblingDisplayName: String? {
        guard !isOptedIn, museScoreGeneralFileURLSync != nil else { return nil }
        return reclaimer?.siblingInUseDisplayName()
    }
```

- [ ] **Step 4: Construct + inject the reclaimer in `installAudioStack`**

In `App/AppBootstrap.swift` `installAudioStack(gateway:)`, replace the provider construction (line 163) with:

```swift
        let reclaimer = SharedSoundfontReclaimer(
            soundfontsDirectory: AppPaths.soundfontsDirectory,
            soundfontFileName: SoundfontPreset.highQuality.fileName,
            minimumValidByteSize: Self.soundfontMinimumValidByteSize,
            ownBundleId: Bundle.main.bundleIdentifier ?? "com.KeyNumber.Folino",
            ownDisplayName: (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? "folino",
            siblings: Self.soundfontSiblings,
            installedChecker: UIKitInstalledAppChecker(),
        )
        let provider = LiveMuseScoreGeneralProvider(
            targetDirectory: AppPaths.soundfontsDirectory, reclaimer: reclaimer,
        )
```

At the end of `installAudioStack(gateway:)` (after `playbackController = …`), add:

```swift
        provider.reconcileSharedSoundfontMarkersAtLaunch()
```

- [ ] **Step 5: Build to verify it compiles**

```
xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation build
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 6: Run the existing provider tests to confirm no regression**

```
xcodebuild test -scheme Infrastructure-Package -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation -only-testing:Infrastructure-Package/InfrastructureTests/LiveMuseScoreGeneralProviderTests
```
Expected: PASS (opt-out still deletes because these tests construct the provider with no reclaimer → legacy branch).

- [ ] **Step 7: Commit**

```
git add Packages/Infrastructure/Sources/Soundfonts/LiveMuseScoreGeneralProvider.swift App/AppBootstrap.swift
git commit -m "feat(soundfonts): reference-count shared SoundFont reclaim on opt-out"
```

## Task A6: Foreground recheck hook

**Files:**
- Modify: `App/AppShellView.swift:64-74`

**Interfaces:**
- Consumes: `LiveMuseScoreGeneralProvider.handleForeground()` (A5).

- [ ] **Step 1: Call `handleForeground()` on `.active`**

In `App/AppShellView.swift`, inside the existing `.onChange(of: scenePhase)` block (lines 64-66) where `newPhase == .active`, add a call alongside the existing kickoff. Find:

```swift
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active {
```
and within that `if`, ensure both run:
```swift
                bootstrap.museScoreGeneralProvider?.handleForeground()
```
(Keep the existing `startDownloadIfNeeded()` call at line 74 — `handleForeground()` refreshes state and reclaims; `startDownloadIfNeeded()` still drives a resume when opted-in and missing.)

- [ ] **Step 2: Build to verify it compiles**

```
xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation build
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```
git add App/AppShellView.swift
git commit -m "feat(app): refresh + reclaim shared SoundFont on foreground"
```

## Task A7: "In use by sibling" note in Settings

**Files:**
- Modify: `Packages/Features/Settings/Sources/Settings/Screens/SoundfontPresetRow.swift` (render the note)
- Modify: the Settings package string catalog (add the localized key) — locate via `git grep -l xcstrings Packages/Features/Settings`
- Reference: `Packages/Features/Settings/Sources/Settings/Screens/SoundfontStateSubtitle.swift` (existing state-text pattern to match)

**Interfaces:**
- Consumes: `LiveMuseScoreGeneralProvider.soundfontKeptBySiblingDisplayName` (A5).

- [ ] **Step 1: Add the localized string key**

In the Settings package's string catalog (`.xcstrings`), add key `settings.soundfont.keptBySibling` with:
- English (`en`): `Shared with %@, so it’s kept on your device. To free this storage, turn it off in %@ as well.`
- Japanese (`ja`): `%@ と共有しているため端末に残しています。容量を解放するには %@ 側でもオフにしてください。`
- For every other locale already present in the catalog, add a translation that matches this meaning and tone (do not leave them as the English source; the app ships 5 languages). Keep `%@` in both positions.

- [ ] **Step 2: Render the note when a sibling is keeping the file**

In `SoundfontPresetRow.swift`, where the row reads the provider (`@Bindable`/`isOptedIn`/`downloadState`), append an informational footnote below the existing content when `provider.soundfontKeptBySiblingDisplayName` is non-nil:

```swift
        if let siblingName = provider.soundfontKeptBySiblingDisplayName {
            Text(String(format: String(localized: "settings.soundfont.keptBySibling", bundle: .module),
                        siblingName, siblingName))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
```

Match the surrounding container (place it inside the same `VStack`/section the row already uses; mirror `SoundfontStateSubtitle`'s styling for consistency).

- [ ] **Step 3: Build + render check**

```
xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation build
```
Expected: BUILD SUCCEEDED. (Visual verification is deferred to the device smoke in Task A9 — the note only appears with a real sibling installed.)

- [ ] **Step 4: Commit**

```
git add Packages/Features/Settings/Sources/Settings
git commit -m "feat(settings): note when a sibling app is keeping the shared SoundFont"
```

## Task A8: Entitlements + Info.plist

**Files:**
- Modify: `App/Folino.entitlements`
- Modify: `App/Info.plist`

- [ ] **Step 1: Add the shared App Group**

In `App/Folino.entitlements`, extend the `application-groups` array (keep the existing `group.com.KeyNumber.Folino`):

```xml
    <key>com.apple.security.application-groups</key>
    <array>
        <string>group.com.KeyNumber.Folino</string>
        <string>group.com.KeyNumber.shared</string>
    </array>
```

- [ ] **Step 2: Declare the sibling query scheme**

In `App/Info.plist`, add (the `folino` scheme under `CFBundleURLTypes` already exists; this adds the *query* allow-list):

```xml
    <key>LSApplicationQueriesSchemes</key>
    <array>
        <string>vocaltuner</string>
    </array>
```

- [ ] **Step 3: Enable the capability + build**

Enable App Group `group.com.KeyNumber.shared` on the `com.KeyNumber.Folino` App ID in the Developer portal (or let automatic signing add it) and regenerate provisioning. **STOP-AND-CONFIRM** with the maintainer before changing portal/provisioning. Then:

```
xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation build
```
Expected: BUILD SUCCEEDED (simulator builds don't require the provisioning update; device builds do).

- [ ] **Step 4: Commit**

```
git add App/Folino.entitlements App/Info.plist
git commit -m "feat(app): add group.com.KeyNumber.shared + vocaltuner query scheme"
```

## Task A9: Full Folino verification

- [ ] **Step 1: Run the full Infrastructure test suite**

```
xcodebuild test -scheme Infrastructure-Package -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation -only-testing:Infrastructure-Package/InfrastructureTests
```
Expected: PASS (all suites incl. the two new ones).

- [ ] **Step 2: Full app build**

```
xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation build
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Device smoke (hand to maintainer)**

Document for manual verification on a real device (App Group needs the entitlement): (a) existing-user simulation — pre-seed `Library/Application Support/Soundfonts/MuseScore_General.sf2`, launch, confirm the file moved into the shared container and playback uses high-quality with no re-download; (b) opt-out as sole consumer frees the file immediately. This is a checklist item for the maintainer, not an automated step.

---

# Phase B — VocalTuner (`/Users/kiichi/Developer/Personal/ios-apps/VocalTuner`)

VocalTuner is greenfield for the soundfont feature (no shipped users have the file). All paths flow through the
centralized `SoundfontPaths`. Run commands from the VocalTuner repo root.

## Task B1: Point `SoundfontPaths` at the shared container; unversioned name

**Files:**
- Modify: `Domain/Sources/Domain/Soundfont/SoundfontPaths.swift`

- [ ] **Step 1: Change the filename and directory resolution**

Replace `highQualityFileName` (line 7) and `soundfontsDirectory(_:)` (lines 24-26):

```swift
    public static let appGroupIdentifier = "group.com.KeyNumber.shared"

    /// Canonical shared name (unversioned). Shared with Folino via the App Group container; a future SF2 swap is
    /// invalidated by a coordinated cross-app rename, not a per-app suffix. See Folino's shared-soundfont spec.
    public static let highQualityFileName = "MuseScore_General.sf2"
```

```swift
    public static func soundfontsDirectory(_ fileManager: FileManager) -> URL {
        if let shared = fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) {
            return shared.appendingPathComponent("Soundfonts", isDirectory: true)
        }
        // Degrade to the private location when the container is unavailable (entitlement/provisioning gap).
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Soundfonts", isDirectory: true)
    }
```

Remove the now-inaccurate "Versioned so a future SF2 swap…" comment above `highQualityFileName`.

- [ ] **Step 2: Build**

```
xcodebuild -project VocalTuner.xcodeproj -scheme VocalTunerDev -destination 'platform=iOS Simulator,name=iPhone 15' build
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```
git add Domain/Sources/Domain/Soundfont/SoundfontPaths.swift
git commit -m "feat(soundfont): resolve shared App Group container, unversioned filename"
```

## Task B2: `SharedSoundfontReclaimer` (VocalTuner Domain) + tests

**Files:**
- Create: `Domain/Sources/Domain/Soundfont/SharedSoundfontReclaimer.swift`
- Test: `VocalTunerTests/SharedSoundfontReclaimerTests.swift`

**Interfaces:**
- Produces (Domain): `SiblingApp`, `InstalledAppChecking`, `SharedSoundfontReclaimer` — **identical contract** to Folino's Task A2 (same marker layout, JSON body, delete rule). Copy the implementation from Task A2 verbatim, changing only the access already `public` and the module it lives in.

- [ ] **Step 1: Write the failing tests**

Create `VocalTunerTests/SharedSoundfontReclaimerTests.swift` — port the same 7 tests from Folino Task A2 Step 1, with `@testable import Domain`, `ownBundleId: "com.KeyNumber.VocalTuner"`, `ownDisplayName: "VocalTuner"`, and `sibling = SiblingApp(bundleId: "com.KeyNumber.Folino", urlScheme: "folino")`. (Same temp-dir helpers, same assertions.)

- [ ] **Step 2: Run tests to verify they fail**

```
xcodebuild test -project VocalTuner.xcodeproj -scheme VocalTunerDev -destination 'platform=iOS Simulator,name=iPhone 15' -only-testing:VocalTunerTests/SharedSoundfontReclaimerTests
```
Expected: FAIL — `cannot find 'SharedSoundfontReclaimer' in scope`.

- [ ] **Step 3: Implement `SharedSoundfontReclaimer` in Domain**

Create `Domain/Sources/Domain/Soundfont/SharedSoundfontReclaimer.swift` with the **exact** code from Folino Task A2 Step 3 (the `SiblingApp`, `InstalledAppChecking`, `SharedSoundfontReclaimer` definitions are pure Foundation and identical). No changes needed beyond living in the `Domain` module.

- [ ] **Step 4: Run tests to verify they pass**

Same command as Step 2. Expected: PASS (7 tests).

- [ ] **Step 5: Commit**

```
git add Domain/Sources/Domain/Soundfont/SharedSoundfontReclaimer.swift VocalTunerTests/SharedSoundfontReclaimerTests.swift
git commit -m "feat(soundfont): add SharedSoundfontReclaimer (matches Folino contract)"
```

## Task B3: Wire the reclaimer into VocalTuner's provider

**Files:**
- Modify: `Features/Sources/Features/Helper/LiveMuseScoreGeneralProvider.swift`
- Create: `Features/Sources/Features/Helper/UIKitInstalledAppChecker.swift`
- Modify: `VocalTuner/Application/VocalTunerApp.swift` (launch reconcile)

**Interfaces:**
- Consumes: `SharedSoundfontReclaimer`, `SiblingApp`, `InstalledAppChecking` (B2).

- [ ] **Step 1: Add the live checker (Features can import UIKit)**

```swift
import Domain
import UIKit

struct UIKitInstalledAppChecker: InstalledAppChecking {
    func isInstalled(urlScheme: String) -> Bool {
        guard let url = URL(string: "\(urlScheme)://") else { return false }
        return UIApplication.shared.canOpenURL(url)
    }
}
```

- [ ] **Step 2: Build the reclaimer in the provider + reference-count opt-out**

In `LiveMuseScoreGeneralProvider.swift`, add a stored reclaimer built from `SoundfontPaths`:

```swift
    @ObservationIgnored private lazy var reclaimer = SharedSoundfontReclaimer(
        fileManager: fileManager,
        soundfontsDirectory: SoundfontPaths.soundfontsDirectory(fileManager),
        soundfontFileName: SoundfontPaths.highQualityFileName,
        minimumValidByteSize: SoundfontPaths.minimumValidByteSize,
        ownBundleId: Bundle.main.bundleIdentifier ?? "com.KeyNumber.VocalTuner",
        ownDisplayName: (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? "VocalTuner",
        siblings: [SiblingApp(bundleId: "com.KeyNumber.Folino", urlScheme: "folino")],
        installedChecker: UIKitInstalledAppChecker())
```

In `setOptedIn(_:)` (lines 119-129), publish the marker on opt-in and, on opt-out, replace the unconditional
grace-delete-then-`deleteDownloaded` with a reference-counted reclaim:

```swift
    public func setOptedIn(_ value: Bool) {
        defaults.set(value, forKey: SoundfontPaths.optInDefaultsKey)
        isOptedIn = value
        if value {
            cancelGraceDelete()
            reclaimer.syncOwnMarker(isOptedIn: true)
            startDownloadIfNeeded()
        } else {
            cancelDownload()
            reclaimer.syncOwnMarker(isOptedIn: false)
            scheduleGraceReclaim()
        }
    }
```

Replace `scheduleGraceDelete()` (lines 200-209) with `scheduleGraceReclaim()` that runs the reference count after the
grace window instead of an unconditional delete:

```swift
    private func scheduleGraceReclaim() {
        guard fileManager.fileExists(atPath: targetFileURL.path) else { return }
        defaults.set(Date(), forKey: SoundfontPaths.pendingDeletionDefaultsKey)
        graceDeleteTask?.cancel()
        graceDeleteTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(SoundfontPaths.graceDeleteSeconds))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                self.defaults.removeObject(forKey: SoundfontPaths.pendingDeletionDefaultsKey)
                self.reclaimer.reclaimIfUnused(isOptedIn: self.isOptedIn)
            }
        }
    }
```

In `handleDownloadFinished` after the `.finished` transition (line 256), add `reclaimer.syncOwnMarker(isOptedIn: true)`.

Update `runLaunchCleanupIfNeeded()` (lines 218-223) to publish the marker and reference-count rather than the old
unconditional cleanup:

```swift
    public func runLaunchCleanupIfNeeded() {
        reclaimer.syncOwnMarker(isOptedIn: isOptedIn)
        reclaimer.reclaimIfUnused(isOptedIn: isOptedIn)
    }
```

- [ ] **Step 3: Confirm the launch call exists**

`runLaunchCleanupIfNeeded()` must be invoked once at the composition root. Verify it is already called at launch in
`VocalTuner/Application/VocalTunerApp.swift` (the provider singleton is touched there for background completion at
line ~184). If it is not yet called, add `LiveMuseScoreGeneralProvider.shared.runLaunchCleanupIfNeeded()` in the same
launch `.task`/`init` path.

- [ ] **Step 4: Build + test**

```
xcodebuild -project VocalTuner.xcodeproj -scheme VocalTunerDev -destination 'platform=iOS Simulator,name=iPhone 15' test
```
Expected: BUILD SUCCEEDED + tests PASS. (The provider's `startDownload` already early-returns inside test hosts, so no real download is triggered.)

- [ ] **Step 5: Commit**

```
git add Features/Sources/Features/Helper/LiveMuseScoreGeneralProvider.swift Features/Sources/Features/Helper/UIKitInstalledAppChecker.swift VocalTuner/Application/VocalTunerApp.swift
git commit -m "feat(soundfont): reference-count shared SoundFont reclaim on opt-out"
```

## Task B4: Entitlements + Info.plist (App Group + vocaltuner scheme)

**Files:**
- Modify: `VocalTuner/Application/VocalTuner.entitlements`
- Modify: `VocalTuner/Application/Info.plist`

- [ ] **Step 1: Add the App Group**

In `VocalTuner.entitlements` (currently only `aps-environment`), add:

```xml
    <key>com.apple.security.application-groups</key>
    <array>
        <string>group.com.KeyNumber.shared</string>
    </array>
```

- [ ] **Step 2: Declare the `vocaltuner` scheme + query `folino`**

In `VocalTuner/Application/Info.plist`, add a URL type so `canOpenURL("vocaltuner://")` from Folino returns true
(declaration only — no incoming-URL handling), and the query allow-list for `folino`:

```xml
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeRole</key>
            <string>Editor</string>
            <key>CFBundleURLName</key>
            <string>com.KeyNumber.VocalTuner.detect</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>vocaltuner</string>
            </array>
        </dict>
    </array>
    <key>LSApplicationQueriesSchemes</key>
    <array>
        <string>folino</string>
    </array>
```

(If `CFBundleURLTypes` already exists, add the dict to the existing array rather than duplicating the key.)

- [ ] **Step 3: Enable capability + build**

Enable App Group `group.com.KeyNumber.shared` on the `com.KeyNumber.VocalTuner` App ID (portal / automatic signing) and
regenerate provisioning. **STOP-AND-CONFIRM** with the maintainer before changing portal/provisioning. Then:

```
xcodebuild -project VocalTuner.xcodeproj -scheme VocalTunerDev -destination 'platform=iOS Simulator,name=iPhone 15' build
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```
git add VocalTuner/Application/VocalTuner.entitlements VocalTuner/Application/Info.plist
git commit -m "feat(app): add group.com.KeyNumber.shared + vocaltuner scheme/folino query"
```

## Task B5: Dev-hygiene cleanup of the legacy `_v1` file (optional)

**Files:**
- Modify: `Features/Sources/Features/Helper/LiveMuseScoreGeneralProvider.swift`

- [ ] **Step 1: Delete a leftover private `_v1` copy once a valid shared copy exists**

In `runLaunchCleanupIfNeeded()`, before the marker sync, add a best-effort cleanup (no real users are affected; this
only tidies dev/TestFlight devices that downloaded under the old name/location):

```swift
        let legacyV1 = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Soundfonts").appendingPathComponent("MuseScore_General_v1.sf2")
        if let size = try? fileManager.attributesOfItem(atPath: targetFileURL.path)[.size] as? Int64,
           size >= SoundfontPaths.minimumValidByteSize {
            try? fileManager.removeItem(at: legacyV1)
        }
```

- [ ] **Step 2: Build + test**

```
xcodebuild -project VocalTuner.xcodeproj -scheme VocalTunerDev -destination 'platform=iOS Simulator,name=iPhone 15' test
```
Expected: BUILD SUCCEEDED + tests PASS.

- [ ] **Step 3: Commit**

```
git add Features/Sources/Features/Helper/LiveMuseScoreGeneralProvider.swift
git commit -m "chore(soundfont): clean up legacy _v1 private copy after shared adoption"
```

## Task B6: Full VocalTuner verification

- [ ] **Step 1: Full build + test**

```
xcodebuild -project VocalTuner.xcodeproj -scheme VocalTunerDev -destination 'platform=iOS Simulator,name=iPhone 15' test
```
Expected: BUILD SUCCEEDED + all tests PASS.

- [ ] **Step 2: Device smoke (hand to maintainer)**

On a device with both apps: opt in on VocalTuner → file downloads into the shared container; install/launch Folino →
reuses it without re-download; opt out on one app while the other stays opted in → file is retained and Folino shows
the "in use" note; opt out on both → file is reclaimed.

---

## Cross-cutting notes

- **Subagent worktree discipline:** if executing Folino tasks in a worktree, commit with absolute paths + `git -C <worktree>`. VocalTuner tasks run in the VocalTuner repo (a separate working copy) — never commit VocalTuner changes into the Folino tree or vice versa.
- **Stop-and-confirm gates:** the two portal/provisioning capability enablements (A8 Step 3, B4 Step 3) and any push are not auto-approved — surface them to the maintainer.
- **Rollout:** ship Folino (Phase A) first, then VocalTuner (Phase B). Both are independently green; the reference count only spans both once VocalTuner ships.
