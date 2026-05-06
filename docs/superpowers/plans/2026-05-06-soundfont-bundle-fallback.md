# SoundFont Bundle Fallback Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the 206 MB bundled `MuseScore_General.sf2` with on-demand downloads from `jiyimeta/musescore-general-sf2-split`, plus two committed split SF2 files (Flute `000_073.sf2`, Standard Drum Kit `128_000.sf2`) as the offline / cancelled-load fallback.

**Architecture:** A single `MuseScoreSF2Resolver` conforms to both `Domain.SoundfontResolver` (async, GitHub release downloads) and `SheetMusicAudio.SoundfontResolver` (sync, cache → bundle → fallback chain). `LivePlaybackController` prefetches per-`(bank, program, isDrums)` and rewrites missing-patch staves to the bundled fallback channels before the engine prepares. `swift-sheet-music`'s resolver protocol gains `isDrums` so drumset and pitched lookups never collide on `(0, 0)`.

**Tech Stack:** Swift 6.3, SwiftPM, Swift Testing, AVFoundation (via `swift-sheet-music`), `xcodegen`. Bundled SF2 files live under `App/Resources/Soundfonts/` (folder reference, ~6.8 MB total committed).

**Spec:** `docs/superpowers/specs/2026-05-06-soundfont-bundle-fallback-design.md`

**Spec extension noted during planning:** §1 says `defaultGMSoundfontURL` returns `nil`, but `PlaybackEngine.prepare(score:)` (swift-sheet-music) calls `metronome.prepare(soundfontURL: resolver.defaultGMSoundfontURL)` directly — the metronome would go silent. Resolution: route the metronome lookup through `resolver.soundfontURL(forBank: 0, program: 0, isDrums: true) ?? resolver.defaultGMSoundfontURL`. The drum bundle's standard kit (program 0, bankMSB 0x78) is exactly what `MetronomeController` loads for hi/low wood block (notes 76/77). This is implemented inside Task 1.

---

## File Structure

**`swift-sheet-music` (separate repo at `/Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music`):**
- Modify: `Sources/SheetMusicAudio/SoundfontResolver.swift` — add `isDrums:` parameter
- Modify: `Sources/SheetMusicAudio/PlaybackEngine.swift` — pass `isDrums` at the two staff resolver call sites + reroute the metronome lookup
- Modify: `Example/SheetMusicExample/Audio/BundledSoundfontResolver.swift` — add `isDrums:` parameter (example app must keep building)

**Folino — `Packages/Domain`:**
- Modify: `Sources/Domain/IDs.swift` — `SoundfontPatchKey` gains `isDrums: Bool`
- Modify: `Sources/Domain/Protocols/SoundfontResolver.swift` — async methods gain `isDrums:` parameter

**Folino — `Packages/Infrastructure`:**
- Modify: `Sources/Soundfonts/MuseScoreSF2Resolver.swift` — conform to both `Domain.SoundfontResolver` and `SheetMusicAudio.SoundfontResolver`; add bundle lookup, fallback chain, file naming with drums; add `precisePath(...)` helper for the controller's rewrite step
- Add: `Tests/InfrastructureTests/Soundfonts/MuseScoreSF2ResolverTests.swift`
- Modify: `Sources/Audio/LivePlaybackController.swift` — prefetch with `isDrums`, walk staves, rewrite missing-patch channels
- Delete: `Sources/Audio/BundleSoundfontResolver.swift`
- Add: `Tests/InfrastructureTests/Audio/LivePlaybackControllerTests.swift`
- Modify: `Tests/InfrastructureTests/InfrastructureTests.swift` — drop `BundleSoundfontResolver` smoke reference

**Folino — App & build config:**
- Modify: `App/AppBootstrap.swift` — pass single resolver instance into both `LivePlaybackController` slots
- Add (committed binaries): `App/Resources/Soundfonts/000_073.sf2`, `App/Resources/Soundfonts/128_000.sf2`
- Delete (dev-machine only, gitignored): `App/Resources/Sounds/MuseScore_General.sf2` and the empty `App/Resources/Sounds/` directory
- Modify: `project.yml` — drop `Sounds` folder reference, add `Soundfonts` folder reference, bump `swift-sheet-music` revision pin
- Modify: `Packages/Infrastructure/Package.swift` — bump `swift-sheet-music` revision pin (must match `project.yml`)
- Modify: `.gitignore` — drop `App/Resources/Sounds/` ignore
- Modify: `CLAUDE.md` — remove the GM-copy step in First-Time Setup

**Each task is one logical commit.** The pre-commit hook will reject hunk-level staging — only stage whole files.

---

### Task 1: Extend swift-sheet-music's `SoundfontResolver` with `isDrums`

This task lives in the `swift-sheet-music` repo (a sibling checkout, not in Folino). The package is owned by the same author, so we modify it in place, push, and bump Folino's revision pin in Task 8.

**Files:**
- Modify: `/Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/Sources/SheetMusicAudio/SoundfontResolver.swift`
- Modify: `/Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/Sources/SheetMusicAudio/PlaybackEngine.swift`
- Modify: `/Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/Example/SheetMusicExample/Audio/BundledSoundfontResolver.swift`

- [ ] **Step 1: Confirm starting state of swift-sheet-music**

```bash
cd /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music
git status
git log -1 --oneline
```

Expected: clean working tree on a feature branch or main. If dirty, stop and ask the user before proceeding.

- [ ] **Step 2: Update the protocol signature**

In `Sources/SheetMusicAudio/SoundfontResolver.swift`, replace the protocol body so it reads:

```swift
public protocol SoundfontResolver: Sendable {
    /// Resolve a `(bank, program)` to a SoundFont 2 file URL. Drum
    /// staves and metronome lookups pass `isDrums: true`; melodic
    /// staves pass `false`. Allows the host to disambiguate
    /// `(0, 0)` between Acoustic Grand Piano and the Standard Drum
    /// Kit, which the engine otherwise loads at different
    /// `bankMSB`s but identical `(bank, program)`.
    func soundfontURL(forBank bank: UInt8, program: UInt8, isDrums: Bool) -> URL?
    var defaultGMSoundfontURL: URL? { get }
}
```

Keep the file-level doc-comments unchanged.

- [ ] **Step 3: Update PlaybackEngine to thread `isDrums`**

In `Sources/SheetMusicAudio/PlaybackEngine.swift`:

(a) The `loadProgram(forStaff:program:)` method — change the resolver call to pass `params.isDrums`. Replace the existing `let url = resolver.soundfontURL(...)` block (around lines 121–124) with:

```swift
let url = resolver.soundfontURL(
    forBank: params.bankLSB, program: program, isDrums: params.isDrums
)
    ?? resolver.defaultGMSoundfontURL
```

(b) The `prepare(score:)` method — change the per-staff resolver call (around lines 177–180) to pass `isDrums`:

```swift
let url = resolver.soundfontURL(
    forBank: bank, program: program, isDrums: isDrums
)
    ?? resolver.defaultGMSoundfontURL
```

(c) The metronome lookup (line 154) — replace:

```swift
metronome.prepare(soundfontURL: resolver.defaultGMSoundfontURL)
```

with:

```swift
// Metronome always plays GM percussion (hi/low wood block on
// notes 76 / 77). Ask the resolver for the drum kit at
// (bank: 0, program: 0, isDrums: true) so a host that doesn't
// ship a full GM SoundFont can still serve the metronome from
// a per-(bank, program) split file. Falls back to the GM URL
// for hosts that haven't moved over.
let metronomeURL =
    resolver.soundfontURL(forBank: 0, program: 0, isDrums: true)
        ?? resolver.defaultGMSoundfontURL
metronome.prepare(soundfontURL: metronomeURL)
```

- [ ] **Step 4: Update the example app's resolver to compile**

In `Example/SheetMusicExample/Audio/BundledSoundfontResolver.swift`, change the method signature and use `isDrums` in the file-name format. Replace the `soundfontURL(forBank:program:)` body with:

```swift
func soundfontURL(forBank bank: UInt8, program: UInt8, isDrums: Bool) -> URL? {
    let bankPrefix = isDrums ? 128 : Int(bank)
    let name = String(format: "%03d_%03d", bankPrefix, program)
    return bundle.url(
        forResource: name,
        withExtension: "sf2",
        subdirectory: "Sounds"
    )
}
```

Update the doc-comment's bullet list to mention `128_PPP.sf2` for drums.

- [ ] **Step 5: Build the package to verify**

```bash
cd /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music
swift build
```

Expected: clean build, no errors.

- [ ] **Step 6: Run the package's existing tests**

```bash
cd /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music
swift test
```

Expected: same pass/fail set as before this change. The protocol change only affects PlaybackEngine and the example resolver — the SheetMusic / SheetMusicMIDI tests don't touch `SoundfontResolver`.

If a test fails because it constructs a `SoundfontResolver`, fix that test by adding `isDrums: false` (or `true` for drum-related tests) — do not weaken the protocol.

- [ ] **Step 7: Commit and push**

```bash
cd /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music
git add Sources/SheetMusicAudio/SoundfontResolver.swift \
        Sources/SheetMusicAudio/PlaybackEngine.swift \
        Example/SheetMusicExample/Audio/BundledSoundfontResolver.swift
git commit -m "feat(audio): add isDrums to SoundfontResolver and route metronome through it"
git push origin HEAD
git rev-parse HEAD
```

Record the new commit SHA — it goes into Task 8's `revision:` pin updates.

---

### Task 2: Extend Domain `SoundfontResolver` and `SoundfontPatchKey` with `isDrums`

The Folino-side protocol (used by `LivePlaybackController` for async prefetch) gains the same `isDrums` parameter. `SoundfontPatchKey` carries `isDrums` so cache records and `cachedPatches()` can distinguish `000_000.sf2` from `128_000.sf2` even though they share `(bank: 0, program: 0)`.

**Files:**
- Modify: `Packages/Domain/Sources/Domain/IDs.swift`
- Modify: `Packages/Domain/Sources/Domain/Protocols/SoundfontResolver.swift`

- [ ] **Step 1: Add `isDrums` to `SoundfontPatchKey`**

In `Packages/Domain/Sources/Domain/IDs.swift`, replace the `SoundfontPatchKey` struct (lines 62–72) with:

```swift
/// Identity of a SoundFont 2 patch. Two patches with the same
/// `(bank, program, isDrums)` are interchangeable — the cache records
/// use this as the primary key. `isDrums` distinguishes a melodic
/// preset (e.g. `000_000.sf2` Acoustic Grand Piano) from a percussion
/// preset that shares the same on-paper `(bank, program)` but is
/// loaded at the percussion `bankMSB`.
public struct SoundfontPatchKey: Hashable, Sendable, Codable {
    public let bank: Int
    public let program: Int
    public let isDrums: Bool

    public init(bank: Int, program: Int, isDrums: Bool = false) {
        self.bank = bank
        self.program = program
        self.isDrums = isDrums
    }
}
```

The `isDrums: Bool = false` default lets call sites that don't yet know about drums keep working (none of them do today; all current call sites pass non-drums).

- [ ] **Step 2: Add `isDrums` to the protocol async methods**

In `Packages/Domain/Sources/Domain/Protocols/SoundfontResolver.swift`, replace the protocol body with:

```swift
public protocol SoundfontResolver: Sendable {
    /// Resolve a `(bank, program, isDrums)` to a local `.sf2` file
    /// URL, downloading and caching if necessary. `isDrums: true`
    /// requests the percussion file (e.g. `128_000.sf2`); `false`
    /// requests the melodic file (e.g. `000_073.sf2`).
    func resolveSoundfont(bank: Int, program: Int, isDrums: Bool) async throws -> URL

    /// All patches currently cached on disk. Includes bundled patches with
    /// `isBundled = true`.
    func cachedPatches() async throws -> [SoundfontPatch]

    /// Total disk usage of cached patches that are not bundled.
    func totalCacheSizeBytes() async throws -> Int64

    /// Remove a single cached (non-bundled) patch. No-op if the patch was
    /// bundled or missing.
    func deletePatch(bank: Int, program: Int, isDrums: Bool) async throws

    /// Remove every non-bundled cached patch.
    func clearCache() async throws
}
```

- [ ] **Step 3: Build Domain in isolation**

```bash
cd Packages/Domain
swift build
```

Expected: clean build. (Only callers within Domain are the protocol declaration and `DomainError` referencing `SoundfontPatchKey` — `SoundfontPatchKey(bank:program:)` still resolves because `isDrums` defaults to `false`.)

- [ ] **Step 4: Run Domain tests**

```bash
cd Packages/Domain
swift test
```

Expected: same pass/fail set as before. If anything constructs a `SoundfontPatchKey` and asserts equality, the new `isDrums = false` default keeps existing assertions valid.

- [ ] **Step 5: Commit**

```bash
git add Packages/Domain/Sources/Domain/IDs.swift \
        Packages/Domain/Sources/Domain/Protocols/SoundfontResolver.swift
git commit -m "feat(domain): add isDrums to SoundfontResolver and SoundfontPatchKey"
```

---

### Task 3: Add committed bundled fallback SF2 files

Two files (~6.8 MB total) committed at `App/Resources/Soundfonts/`. They replace the gitignored 206 MB `App/Resources/Sounds/MuseScore_General.sf2` developer-drop-in.

**Files:**
- Add (binary, committed): `App/Resources/Soundfonts/000_073.sf2`
- Add (binary, committed): `App/Resources/Soundfonts/128_000.sf2`
- Modify: `.gitignore`

- [ ] **Step 1: Create the directory and download the two bundled files**

```bash
mkdir -p App/Resources/Soundfonts
curl -L -o App/Resources/Soundfonts/000_073.sf2 \
  https://github.com/jiyimeta/musescore-general-sf2-split/releases/download/1.0.0/000_073.sf2
curl -L -o App/Resources/Soundfonts/128_000.sf2 \
  https://github.com/jiyimeta/musescore-general-sf2-split/releases/download/1.0.0/128_000.sf2
ls -lh App/Resources/Soundfonts/
```

Expected: `000_073.sf2` ~624 KB, `128_000.sf2` ~6.15 MB. If sizes are wildly different, the download was corrupted — re-fetch and verify.

- [ ] **Step 2: Drop the `App/Resources/Sounds/` ignore from `.gitignore`**

In `.gitignore`, remove the lines:

```
# Bundled SoundFonts (too large for git; copy from
# swift-sheet-music's Example/SheetMusicExample/Sounds/)
App/Resources/Sounds/
```

(They become obsolete: the directory itself is removed in Task 7, and any future bundled SF2 lives under `App/Resources/Soundfonts/` which is committed.)

- [ ] **Step 3: Verify git would track the new files**

```bash
git status
git check-ignore App/Resources/Soundfonts/000_073.sf2 || echo "not ignored — good"
```

Expected: both `000_073.sf2` and `128_000.sf2` show as untracked under `App/Resources/Soundfonts/`; `git check-ignore` prints "not ignored — good".

- [ ] **Step 4: Commit**

```bash
git add .gitignore App/Resources/Soundfonts/000_073.sf2 App/Resources/Soundfonts/128_000.sf2
git commit -m "feat(resources): bundle Flute and Std Drum Kit SF2 files as offline fallback"
```

---

### Task 4: Expand `MuseScoreSF2Resolver` to conform to both protocols

The resolver becomes the single source of truth. It conforms to `Domain.SoundfontResolver` (async, with `isDrums`) and `SheetMusicAudio.SoundfontResolver` (sync, with `isDrums`). The sync path follows: cache → bundle → drum-or-flute fallback. A `precisePath(...)` helper returns nil instead of falling through, for the controller's rewrite logic.

**Files:**
- Modify: `Packages/Infrastructure/Sources/Soundfonts/MuseScoreSF2Resolver.swift`

- [ ] **Step 1: Add `SheetMusicAudio` to the `Soundfonts` target's dependencies**

In `Packages/Infrastructure/Package.swift`, the `Soundfonts` target currently has `dependencies: ["Domain"]`. Replace that target declaration with:

```swift
.target(
    name: "Soundfonts",
    dependencies: [
        "Domain",
        .product(name: "SheetMusicAudio", package: "swift-sheet-music"),
    ],
    plugins: swiftLintPlugins
),
```

- [ ] **Step 2: Build to confirm the package graph still resolves**

```bash
cd Packages/Infrastructure
swift build --target Soundfonts
```

Expected: clean build (the target now has no implementation referencing `SheetMusicAudio` yet — that lands in step 4). Any import error indicates a typo in `Package.swift`; fix and re-run.

- [ ] **Step 3: Replace `MuseScoreSF2Resolver` with the dual-conforming version**

Overwrite `Packages/Infrastructure/Sources/Soundfonts/MuseScoreSF2Resolver.swift` with:

```swift
import Domain
import Foundation
import SheetMusicAudio

/// Single resolver that covers both Folino's async download path
/// (`Domain.SoundfontResolver`) and `swift-sheet-music`'s synchronous
/// per-(bank, program, isDrums) lookup (`SheetMusicAudio.SoundfontResolver`).
///
/// Lookup order, sync path:
///   1. Cache hit at `cacheDirectory/<name>` — return.
///   2. Bundle hit at `Bundle.main/Soundfonts/<name>` — return.
///   3. Drum lookup with no precise hit — return bundled
///      `Soundfonts/128_000.sf2` (Standard Drum Kit fallback).
///   4. Pitched lookup with no precise hit — return bundled
///      `Soundfonts/000_073.sf2` (Flute fallback).
///   5. Even the fallback bundle is missing (only happens in
///      misbuilt apps) — return `nil`.
///
/// Async path (`resolveSoundfont`):
///   1. Cache hit — return.
///   2. Bundle hit — return (no copy; bundle URL is fine).
///   3. Download `<baseURL>/<name>` to cache atomically — return.
///   4. Download fails — throw `DomainError.soundfontDownloadFailed`.
///
/// File naming follows `jiyimeta/musescore-general-sf2-split`:
///   - melodic: `BBB_PPP.sf2` (zero-padded decimal `bank`, `program`)
///   - drums:   `128_PPP.sf2` (drum bank prefix is `128`, ignoring `bank`)
public struct MuseScoreSF2Resolver: Domain.SoundfontResolver, SheetMusicAudio.SoundfontResolver {
    public static let defaultBaseURL = URL(
        string: "https://github.com/jiyimeta/musescore-general-sf2-split/releases/download/1.0.0"
    )! // swiftlint:disable:this force_unwrapping

    /// Subdirectory inside `Bundle.main` that hosts committed
    /// fallback SF2 files. Matches the folder reference set up in
    /// `project.yml`.
    static let bundleSubdirectory = "Soundfonts"
    /// Pitched fallback (GM Flute, ~624 KB).
    static let pitchedFallbackName = "000_073.sf2"
    /// Drum fallback (Standard Drum Kit, ~6.15 MB).
    static let drumFallbackName = "128_000.sf2"

    private let cacheDirectory: URL
    private let baseURL: URL
    private let session: URLSession
    private let bundle: Bundle

    public init(
        cacheDirectory: URL,
        baseURL: URL = MuseScoreSF2Resolver.defaultBaseURL,
        session: URLSession = .shared,
        bundle: Bundle = .main
    ) {
        self.cacheDirectory = cacheDirectory
        self.baseURL = baseURL
        self.session = session
        self.bundle = bundle
    }

    // MARK: - SheetMusicAudio.SoundfontResolver (sync)

    public func soundfontURL(forBank bank: UInt8, program: UInt8, isDrums: Bool) -> URL? {
        let name = Self.fileName(bank: Int(bank), program: Int(program), isDrums: isDrums)
        if let precise = precisePath(name: name) {
            return precise
        }
        let fallbackName = isDrums ? Self.drumFallbackName : Self.pitchedFallbackName
        return bundleURL(name: fallbackName)
    }

    public var defaultGMSoundfontURL: URL? { nil }

    /// Sync resolver path that returns `nil` if neither cache nor
    /// bundle has a precise file — used by `LivePlaybackController`
    /// to decide whether a staff needs a fallback channel rewrite.
    public func precisePath(forBank bank: Int, program: Int, isDrums: Bool) -> URL? {
        precisePath(name: Self.fileName(bank: bank, program: program, isDrums: isDrums))
    }

    private func precisePath(name: String) -> URL? {
        let cached = cacheDirectory.appending(path: name)
        if FileManager.default.fileExists(atPath: cached.path) {
            return cached
        }
        return bundleURL(name: name)
    }

    private func bundleURL(name: String) -> URL? {
        // `Bundle.url(forResource:withExtension:subdirectory:)`
        // wants the components split. Strip the `.sf2` suffix.
        guard name.hasSuffix(".sf2") else { return nil }
        let stem = String(name.dropLast(".sf2".count))
        return bundle.url(
            forResource: stem,
            withExtension: "sf2",
            subdirectory: Self.bundleSubdirectory
        )
    }

    // MARK: - Domain.SoundfontResolver (async)

    public func resolveSoundfont(bank: Int, program: Int, isDrums: Bool) async throws -> URL {
        let name = Self.fileName(bank: bank, program: program, isDrums: isDrums)
        if let precise = precisePath(name: name) {
            return precise
        }
        try createCacheDirectoryIfNeeded()
        let local = cacheDirectory.appending(path: name)
        let remote = baseURL.appending(path: name)
        let (data, response) = try await session.data(from: remote)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw DomainError.soundfontDownloadFailed(
                SoundfontPatchKey(bank: bank, program: program, isDrums: isDrums)
            )
        }
        try data.write(to: local, options: .atomic)
        return local
    }

    public func cachedPatches() throws -> [SoundfontPatch] {
        try createCacheDirectoryIfNeeded()
        let urls = try FileManager.default.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        return urls.compactMap { url -> SoundfontPatch? in
            guard url.pathExtension.lowercased() == "sf2",
                  let parsed = Self.parseFileName(url.lastPathComponent)
            else { return nil }
            let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            let modified = (attrs[.modificationDate] as? Date) ?? .distantPast
            return SoundfontPatch(
                bank: parsed.bank, program: parsed.program,
                localFileName: url.lastPathComponent,
                sizeBytes: size,
                downloadedAt: modified,
                lastUsedAt: modified,
                isBundled: false
            )
        }
    }

    public func totalCacheSizeBytes() throws -> Int64 {
        try cachedPatches().reduce(0) { $0 + $1.sizeBytes }
    }

    public func deletePatch(bank: Int, program: Int, isDrums: Bool) throws {
        let name = Self.fileName(bank: bank, program: program, isDrums: isDrums)
        let url = cacheDirectory.appending(path: name)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    public func clearCache() throws {
        guard FileManager.default.fileExists(atPath: cacheDirectory.path) else { return }
        let urls = try FileManager.default.contentsOfDirectory(
            at: cacheDirectory, includingPropertiesForKeys: nil
        )
        for url in urls where url.pathExtension.lowercased() == "sf2" {
            try? FileManager.default.removeItem(at: url)
        }
    }

    // MARK: - Helpers

    static func fileName(bank: Int, program: Int, isDrums: Bool) -> String {
        let prefix = isDrums ? 128 : bank
        return String(format: "%03d_%03d.sf2", prefix, program)
    }

    static func parseFileName(_ name: String) -> (bank: Int, program: Int)? {
        // Expected shape: "BBB_PPP.sf2" with three-digit decimals.
        let stem = name.split(separator: ".").first.map(String.init) ?? name
        let parts = stem.split(separator: "_")
        guard parts.count == 2,
              let bank = Int(parts[0]),
              let program = Int(parts[1])
        else { return nil }
        return (bank, program)
    }

    private func createCacheDirectoryIfNeeded() throws {
        if !FileManager.default.fileExists(atPath: cacheDirectory.path) {
            try FileManager.default.createDirectory(
                at: cacheDirectory, withIntermediateDirectories: true
            )
        }
    }
}
```

- [ ] **Step 4: Build Soundfonts**

```bash
cd Packages/Infrastructure
swift build --target Soundfonts
```

Expected: clean build. The compiler will reject the build if Domain hasn't already grown `isDrums` (Task 2 must precede this) — that's a sign Tasks 2 and 4 were re-ordered.

- [ ] **Step 5: Commit (resolver + Package.swift, no tests yet)**

```bash
git add Packages/Infrastructure/Package.swift \
        Packages/Infrastructure/Sources/Soundfonts/MuseScoreSF2Resolver.swift
git commit -m "feat(soundfonts): MuseScoreSF2Resolver conforms to sync + async resolver protocols"
```

---

### Task 5: Resolver tests — file naming, lookup chain, fallback selection

New Swift Testing suite covering the sync `soundfontURL(...)` and `precisePath(...)` chain plus the async download path with a stubbed `URLProtocol`.

**Files:**
- Add: `Packages/Infrastructure/Tests/InfrastructureTests/Soundfonts/MuseScoreSF2ResolverTests.swift`

- [ ] **Step 1: Write the test file**

Create `Packages/Infrastructure/Tests/InfrastructureTests/Soundfonts/MuseScoreSF2ResolverTests.swift`:

```swift
import Domain
import Foundation
@testable import Soundfonts
import Testing

@Suite struct MuseScoreSF2ResolverTests {
    // MARK: - File naming

    @Test func melodicFileNameUsesBankAndProgram() {
        #expect(MuseScoreSF2Resolver.fileName(bank: 0, program: 73, isDrums: false) == "000_073.sf2")
        #expect(MuseScoreSF2Resolver.fileName(bank: 8, program: 0, isDrums: false) == "008_000.sf2")
    }

    @Test func drumFileNameAlwaysUsesBank128() {
        #expect(MuseScoreSF2Resolver.fileName(bank: 0, program: 0, isDrums: true) == "128_000.sf2")
        // Bank arg is ignored for drums — both produce 128_PPP.
        #expect(MuseScoreSF2Resolver.fileName(bank: 7, program: 25, isDrums: true) == "128_025.sf2")
    }

    // MARK: - Sync lookup chain

    @Test func cacheHitWinsOverBundleAndFallback() throws {
        let tmp = try TempDirectory()
        let cache = tmp.url
        // Pretend (0, 73, false) is in the cache.
        let cachedFile = cache.appending(path: "000_073.sf2")
        try Data([0xAA]).write(to: cachedFile)

        let bundle = try makeFakeBundle(
            tmp: tmp,
            files: ["Soundfonts/000_073.sf2": Data([0xBB])]
        )
        let resolver = MuseScoreSF2Resolver(cacheDirectory: cache, bundle: bundle)

        let url = resolver.soundfontURL(forBank: 0, program: 73, isDrums: false)
        #expect(url == cachedFile)
    }

    @Test func bundleHitWinsOverFallbackWhenCacheEmpty() throws {
        let tmp = try TempDirectory()
        let bundleFile = "Soundfonts/008_000.sf2"
        let bundle = try makeFakeBundle(
            tmp: tmp,
            files: [bundleFile: Data([0xBB])]
        )
        let resolver = MuseScoreSF2Resolver(cacheDirectory: tmp.url, bundle: bundle)

        let url = resolver.soundfontURL(forBank: 8, program: 0, isDrums: false)
        #expect(url?.lastPathComponent == "008_000.sf2")
        #expect(url?.path.contains(tmp.url.path) == true)
    }

    @Test func pitchedMissFallsBackToFlute() throws {
        let tmp = try TempDirectory()
        let bundle = try makeFakeBundle(
            tmp: tmp,
            files: ["Soundfonts/000_073.sf2": Data([0xFF])]
        )
        let resolver = MuseScoreSF2Resolver(cacheDirectory: tmp.url, bundle: bundle)

        let url = resolver.soundfontURL(forBank: 5, program: 42, isDrums: false)
        #expect(url?.lastPathComponent == "000_073.sf2")
    }

    @Test func drumMissFallsBackToStandardKit() throws {
        let tmp = try TempDirectory()
        let bundle = try makeFakeBundle(
            tmp: tmp,
            files: ["Soundfonts/128_000.sf2": Data([0xCC])]
        )
        let resolver = MuseScoreSF2Resolver(cacheDirectory: tmp.url, bundle: bundle)

        let url = resolver.soundfontURL(forBank: 0, program: 25, isDrums: true)
        #expect(url?.lastPathComponent == "128_000.sf2")
    }

    @Test func defaultGMSoundfontURLIsNil() throws {
        let tmp = try TempDirectory()
        let resolver = MuseScoreSF2Resolver(cacheDirectory: tmp.url)
        #expect(resolver.defaultGMSoundfontURL == nil)
    }

    @Test func precisePathReturnsNilWhenNoCacheOrBundleHit() throws {
        let tmp = try TempDirectory()
        let bundle = try makeFakeBundle(
            tmp: tmp,
            files: ["Soundfonts/128_000.sf2": Data([0xCC])]
        )
        let resolver = MuseScoreSF2Resolver(cacheDirectory: tmp.url, bundle: bundle)

        // Pitched lookup that has no precise file — even though the
        // drum fallback bundle is present, precisePath must return nil.
        #expect(resolver.precisePath(forBank: 5, program: 42, isDrums: false) == nil)
        // Drum lookup whose precise file IS the same as the fallback name —
        // must return the bundle URL (it's a precise hit, not a fallthrough).
        #expect(resolver.precisePath(forBank: 0, program: 0, isDrums: true) != nil)
    }

    // MARK: - Async download path

    @Test func resolveSoundfontReturnsCacheHit() async throws {
        let tmp = try TempDirectory()
        let cached = tmp.url.appending(path: "000_073.sf2")
        try Data([0xAA]).write(to: cached)
        let resolver = MuseScoreSF2Resolver(cacheDirectory: tmp.url, session: stubSession())

        let url = try await resolver.resolveSoundfont(bank: 0, program: 73, isDrums: false)
        #expect(url == cached)
    }

    @Test func resolveSoundfontReturnsBundleHitWithoutDownload() async throws {
        let tmp = try TempDirectory()
        let bundle = try makeFakeBundle(
            tmp: tmp,
            files: ["Soundfonts/000_073.sf2": Data([0xBB])]
        )
        // Stub session would 500 if hit — assert it isn't.
        let resolver = MuseScoreSF2Resolver(
            cacheDirectory: tmp.url.appending(path: "cache"),
            session: stubSession(failing: true),
            bundle: bundle
        )

        let url = try await resolver.resolveSoundfont(bank: 0, program: 73, isDrums: false)
        #expect(url.lastPathComponent == "000_073.sf2")
    }

    @Test func resolveSoundfontDownloadsToCacheOnMiss() async throws {
        let tmp = try TempDirectory()
        let payload = Data([0xDE, 0xAD, 0xBE, 0xEF])
        let resolver = MuseScoreSF2Resolver(
            cacheDirectory: tmp.url,
            session: stubSession(payload: payload, status: 200)
        )

        let url = try await resolver.resolveSoundfont(bank: 8, program: 0, isDrums: false)
        #expect(url == tmp.url.appending(path: "008_000.sf2"))
        let written = try Data(contentsOf: url)
        #expect(written == payload)
    }

    @Test func resolveSoundfontThrowsOnNon200() async throws {
        let tmp = try TempDirectory()
        let resolver = MuseScoreSF2Resolver(
            cacheDirectory: tmp.url,
            session: stubSession(payload: Data(), status: 404)
        )
        await #expect(throws: DomainError.self) {
            _ = try await resolver.resolveSoundfont(bank: 8, program: 0, isDrums: false)
        }
    }
}

// MARK: - Test helpers

/// Builds a real on-disk `Bundle` so `Bundle.url(forResource:...)` works.
/// Files are written under `tmp.url/FakeBundle.bundle/<relative path>`.
private func makeFakeBundle(tmp: TempDirectory, files: [String: Data]) throws -> Bundle {
    let bundleURL = tmp.url.appending(path: "FakeBundle.bundle", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
    for (relative, data) in files {
        let target = bundleURL.appending(path: relative)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try data.write(to: target)
    }
    guard let bundle = Bundle(url: bundleURL) else {
        throw NSError(domain: "TestBundle", code: 1)
    }
    return bundle
}

/// Returns a `URLSession` whose `URLProtocol` either serves a fixed payload
/// or throws — chosen at construction so a single test stays declarative.
private func stubSession(
    payload: Data = Data(),
    status: Int = 200,
    failing: Bool = false
) -> URLSession {
    StubURLProtocol.next = StubURLProtocol.Response(
        payload: payload, status: status, failing: failing
    )
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubURLProtocol.self]
    return URLSession(configuration: config)
}

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Response { let payload: Data; let status: Int; let failing: Bool }
    nonisolated(unsafe) static var next: Response?

    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let response = StubURLProtocol.next else {
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        if response.failing {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let httpResponse = HTTPURLResponse(
            url: request.url!, statusCode: response.status,
            httpVersion: "HTTP/1.1", headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.payload)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
```

- [ ] **Step 2: Run the new tests in isolation**

```bash
cd Packages/Infrastructure
swift test --filter MuseScoreSF2ResolverTests
```

Expected: PASS for every `@Test`.

If any test fails, treat it as a bug in the resolver (Task 4) — fix the resolver, not the test.

- [ ] **Step 3: Commit**

```bash
git add Packages/Infrastructure/Tests/InfrastructureTests/Soundfonts/MuseScoreSF2ResolverTests.swift
git commit -m "test(soundfonts): cover resolver lookup chain and async download path"
```

---

### Task 6: `LivePlaybackController` — single resolver, prefetch with `isDrums`, channel rewrite

`BundleSoundfontResolver` is deleted. `LivePlaybackController` takes a single concrete resolver (typed as both protocols). Prefetch walks staves with `(bank, program, isDrums)`. After prefetch, every staff with no precise hit gets its channel rewritten to the fallback `(0, 73)` for pitched or `(0, 0)` for drums, before `engine.prepare(score:)` runs.

**Files:**
- Modify: `Packages/Infrastructure/Sources/Audio/LivePlaybackController.swift`
- Delete: `Packages/Infrastructure/Sources/Audio/BundleSoundfontResolver.swift`
- Modify: `Packages/Infrastructure/Tests/InfrastructureTests/InfrastructureTests.swift`

The rewrite step needs a synchronous "is this staff's patch precisely available?" probe. Currently the controller only sees `domainResolver` typed as `Domain.SoundfontResolver` — that protocol is async-only, so it can't answer the question synchronously. We add a Domain-level extension method on a new protocol `PrecisePathResolving` that `MuseScoreSF2Resolver` implements, and have the controller require it on top of the Domain resolver.

Actually — simpler: `MuseScoreSF2Resolver` already conforms to `SheetMusicAudio.SoundfontResolver`, which is sync. The controller's `soundfontResolver` parameter is already typed as that protocol. Use `precisePath(...)` via a new public method that lives on the concrete type, but expose it through a protocol so tests can fake it.

We'll add a small protocol in the `Audio` module:

```swift
public protocol PrecisePatchProbe: Sendable {
    func precisePath(forBank bank: Int, program: Int, isDrums: Bool) -> URL?
}
```

`MuseScoreSF2Resolver` already implements that signature; we just declare conformance in Task 4's resolver (or here — see Step 1 below).

- [ ] **Step 1: Add `PrecisePatchProbe` protocol and conform `MuseScoreSF2Resolver`**

In `Packages/Infrastructure/Sources/Audio/LivePlaybackController.swift`, before the `LivePlaybackController` class, add:

```swift
/// Synchronous "is this patch precisely cached or bundled?" probe used
/// by `LivePlaybackController` to decide whether a staff's
/// `(bank, program, isDrums)` resolves to a real file before falling
/// through to the flute / drum bundled defaults. Separate from the
/// async `Domain.SoundfontResolver` because the rewrite decision must
/// happen synchronously between prefetch and `engine.prepare(score:)`.
public protocol PrecisePatchProbe: Sendable {
    func precisePath(forBank bank: Int, program: Int, isDrums: Bool) -> URL?
}
```

Then in `Packages/Infrastructure/Sources/Soundfonts/MuseScoreSF2Resolver.swift`, change the type's conformance list to also include `PrecisePatchProbe`. The `precisePath(forBank:program:isDrums:)` method already has the right signature (added in Task 4).

The `Soundfonts` target needs to depend on `Audio`? No — `Audio` already depends on `Soundfonts` indirectly via `Domain`, and we don't want a cycle. Instead, declare `PrecisePatchProbe` in **`Domain`** so it's reachable from both Audio (which uses it) and Soundfonts (which conforms). Move the protocol into `Packages/Domain/Sources/Domain/Protocols/PrecisePatchProbe.swift`:

Create `Packages/Domain/Sources/Domain/Protocols/PrecisePatchProbe.swift`:

```swift
import Foundation

/// Synchronous "is this patch precisely cached or bundled?" probe.
/// Separate from the async `SoundfontResolver` because the
/// playback controller's fallback-rewrite decision must happen
/// synchronously between async prefetch and `engine.prepare(score:)`.
public protocol PrecisePatchProbe: Sendable {
    /// Returns the URL of a precisely-matching `.sf2` file (cache or
    /// bundle hit). Returns `nil` when no precise file exists, even if
    /// a fallback would be served by the async / non-precise resolver.
    func precisePath(forBank bank: Int, program: Int, isDrums: Bool) -> URL?
}
```

In `Packages/Infrastructure/Sources/Soundfonts/MuseScoreSF2Resolver.swift`, change the type declaration line from:

```swift
public struct MuseScoreSF2Resolver: Domain.SoundfontResolver, SheetMusicAudio.SoundfontResolver {
```

to:

```swift
public struct MuseScoreSF2Resolver:
    Domain.SoundfontResolver,
    Domain.PrecisePatchProbe,
    SheetMusicAudio.SoundfontResolver
{
```

- [ ] **Step 2: Build Domain and Soundfonts to verify the protocol is reachable**

```bash
cd Packages/Domain && swift build && cd -
cd Packages/Infrastructure && swift build --target Soundfonts && cd -
```

Expected: clean builds.

- [ ] **Step 3: Rewrite `LivePlaybackController`**

Overwrite `Packages/Infrastructure/Sources/Audio/LivePlaybackController.swift` with:

```swift
import Combine
import Domain
import Foundation
import SheetMusicAudio
import SheetMusicCore

/// Bridges Folino's `Domain.PlaybackController` onto
/// `SheetMusicAudio.PlaybackEngine`. The engine is `@MainActor` so this
/// adapter is too — the protocol's `async` methods become hops onto the
/// main actor.
@MainActor
public final class LivePlaybackController: Domain.PlaybackController {
    private let engine: PlaybackEngine
    private let domainResolver: any Domain.SoundfontResolver
    private let precisionProbe: any Domain.PrecisePatchProbe
    private var loadedScore: Score?

    private let cursorContinuation: AsyncStream<ScoreCursor?>.Continuation
    public nonisolated let cursor: AsyncStream<ScoreCursor?>
    private var cancellables: Set<AnyCancellable> = []

    /// Bank / program of the bundled fallback patches. When a staff's
    /// precise SF2 is unavailable, the controller rewrites the staff's
    /// channel to one of these so the resolver's sync path returns the
    /// committed bundle file rather than an unrelated cached patch.
    static let pitchedFallbackChannel = (bank: 0, program: 73)
    static let drumFallbackChannel = (bank: 0, program: 0)

    public init(
        soundfontResolver: any SheetMusicAudio.SoundfontResolver,
        domainResolver: any Domain.SoundfontResolver,
        precisionProbe: any Domain.PrecisePatchProbe
    ) {
        engine = PlaybackEngine(soundfontResolver: soundfontResolver)
        self.domainResolver = domainResolver
        self.precisionProbe = precisionProbe
        var continuation: AsyncStream<ScoreCursor?>.Continuation!
        cursor = AsyncStream { continuation = $0 }
        cursorContinuation = continuation
        engine.$currentCursor
            .sink { [continuation] value in
                continuation.yield(value)
            }
            .store(in: &cancellables)
    }

    public func load(score: Score, preferences: PlaybackPreferences) async throws {
        await Self.prefetchSoundfonts(score: score, resolver: domainResolver)
        try Task.checkCancellation()
        let prepared = Self.scoreWithFallbackRewrites(score, probe: precisionProbe)
        try engine.prepare(score: prepared)
        loadedScore = prepared
        for state in preferences.perStaff {
            engine.setVolume(
                forChannel: .staff(state.staffIndex), to: Float(state.volume)
            )
            engine.setMuted(
                forChannel: .staff(state.staffIndex), to: state.isMuted
            )
            engine.setSoloed(
                forChannel: .staff(state.staffIndex), to: state.isSolo
            )
        }
    }

    /// Walks the score's distinct `(bank, program, isDrums)` triples and
    /// asks the resolver to materialise each on disk, in parallel.
    /// Soft-fails per patch — if one download 404s, the others still land.
    /// Patches that fail outright are handled later by
    /// `scoreWithFallbackRewrites` rewriting the staff channel.
    private static func prefetchSoundfonts(
        score: Score, resolver: any Domain.SoundfontResolver
    ) async {
        var seen: Set<SoundfontPatchKey> = []
        var triples: [(bank: Int, program: Int, isDrums: Bool)] = []
        for entry in score.allStaves {
            guard let part = score.part(at: entry.address) else { continue }
            let channel = part.instrument.channels.first ?? InstrumentChannel()
            let isDrums = part.instrument.useDrumset
            let key = SoundfontPatchKey(
                bank: channel.bank, program: channel.program, isDrums: isDrums
            )
            if seen.insert(key).inserted {
                triples.append((channel.bank, channel.program, isDrums))
            }
        }
        await withTaskGroup(of: Void.self) { group in
            for triple in triples {
                group.addTask {
                    _ = try? await resolver.resolveSoundfont(
                        bank: triple.bank, program: triple.program,
                        isDrums: triple.isDrums
                    )
                }
            }
        }
    }

    /// Returns a `Score` where every staff whose `(bank, program, isDrums)`
    /// has no precise SF2 file (cache or bundle) is rewritten to the
    /// matching bundled fallback channel (`(0, 73)` for pitched,
    /// `(0, 0)` for drums). Staves whose patch *is* available pass
    /// through unmodified.
    static func scoreWithFallbackRewrites(
        _ score: Score, probe: any Domain.PrecisePatchProbe
    ) -> Score {
        // Reach into the score's mutable channel slots once per part.
        // Each part's `instrument.channels.first` is the slot used by
        // `PlaybackEngine.prepare(score:)`; rewriting it there is enough.
        var rewritten = score
        for entry in rewritten.allStaves {
            guard let part = rewritten.part(at: entry.address) else { continue }
            let channel = part.instrument.channels.first ?? InstrumentChannel()
            let isDrums = part.instrument.useDrumset
            if probe.precisePath(
                forBank: channel.bank, program: channel.program, isDrums: isDrums
            ) != nil {
                continue
            }
            let target = isDrums ? drumFallbackChannel : pitchedFallbackChannel
            var newPart = part
            var newChannel = channel
            newChannel.bank = target.bank
            newChannel.program = target.program
            if newPart.instrument.channels.isEmpty {
                newPart.instrument.channels = [newChannel]
            } else {
                newPart.instrument.channels[0] = newChannel
            }
            rewritten.setPart(newPart, at: entry.address)
        }
        return rewritten
    }

    public func play() throws {
        guard let score = loadedScore else { return }
        engine.play(in: score)
    }

    public func pause() { engine.pause() }

    public func setStaffVolume(staff: Int, volume: Double) {
        engine.setVolume(forChannel: .staff(staff), to: Float(volume))
    }

    public func setStaffMute(staff: Int, isMuted: Bool) {
        engine.setMuted(forChannel: .staff(staff), to: isMuted)
    }

    public func setStaffSolo(staff: Int, isSolo: Bool) {
        engine.setSoloed(forChannel: .staff(staff), to: isSolo)
    }

    public func setStaffInstrument(staff: Int, bank _: Int, program: Int) {
        engine.setProgram(
            forChannel: .staff(staff), to: UInt8(clamping: program)
        )
    }

    public func setMetronomeEnabled(_ enabled: Bool) {
        engine.setMuted(forChannel: .metronome, to: !enabled)
    }

    public func setCursor(to cursor: ScoreCursor) {
        if engine.state == .playing, let score = loadedScore {
            engine.play(from: cursor, in: score)
        } else {
            engine.seek(to: cursor)
        }
    }

    public func setLoopRange(_: ABRepeatRange?) {}
    public func setTempoMultiplier(_: Double) {}
}
```

- [ ] **Step 4: Verify `Score.setPart(_:at:)` exists**

The rewrite uses `rewritten.setPart(newPart, at: entry.address)`. Verify the signature in `swift-sheet-music`:

```bash
grep -rn "setPart\|mutating.*part" /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/Sources/SheetMusicCore | head -10
```

If `setPart(_:at:)` doesn't exist (only `part(at:)` does), choose one of:
  - The Score type exposes `parts: [Part]` mutably or a `mutating func setPart` — use whichever is canonical.
  - Otherwise, build the rewritten Score by mapping over `score.parts` (or whatever the public mutable accessor is).

Adapt the implementation to whatever `swift-sheet-music`'s public API offers — do not add a new public mutator to `swift-sheet-music` for this; rebuild the Score on the Folino side.

- [ ] **Step 5: Delete `BundleSoundfontResolver`**

```bash
git rm Packages/Infrastructure/Sources/Audio/BundleSoundfontResolver.swift
```

- [ ] **Step 6: Drop the smoke-test reference to `BundleSoundfontResolver`**

In `Packages/Infrastructure/Tests/InfrastructureTests/InfrastructureTests.swift`, replace:

```swift
        _ = BundleSoundfontResolver.self
        _ = MuseScoreSF2Resolver.self
```

with just:

```swift
        _ = MuseScoreSF2Resolver.self
```

- [ ] **Step 7: Build the Audio target**

```bash
cd Packages/Infrastructure
swift build --target Audio
```

Expected: clean build. The Audio target now depends transitively on `SheetMusicAudio` only via the resolver protocol — which it always did.

- [ ] **Step 8: Run the existing infrastructure smoke tests**

```bash
cd Packages/Infrastructure
swift test --filter InfrastructureSmokeTests
```

Expected: PASS — `BundleSoundfontResolver.self` reference is gone, `MuseScoreSF2Resolver.self` still resolves.

- [ ] **Step 9: Commit**

```bash
git add Packages/Domain/Sources/Domain/Protocols/PrecisePatchProbe.swift \
        Packages/Infrastructure/Sources/Soundfonts/MuseScoreSF2Resolver.swift \
        Packages/Infrastructure/Sources/Audio/LivePlaybackController.swift \
        Packages/Infrastructure/Tests/InfrastructureTests/InfrastructureTests.swift
git rm Packages/Infrastructure/Sources/Audio/BundleSoundfontResolver.swift
git commit -m "refactor(audio): single resolver + fallback channel rewrite for missing patches"
```

(`git rm` already stages the deletion; `git add` stages the rest. The pre-commit hook only sees whole files, so this is safe.)

---

### Task 7: Tests for `LivePlaybackController`'s rewrite

A small Swift Testing suite that constructs minimal `Score`s and a fake `PrecisePatchProbe`, then verifies `scoreWithFallbackRewrites` rewrites only the staves whose patch is unavailable.

**Files:**
- Add: `Packages/Infrastructure/Tests/InfrastructureTests/Audio/LivePlaybackControllerTests.swift`

- [ ] **Step 1: Survey what fixture builders exist for `Score`**

```bash
grep -rn "Score(" Packages/Infrastructure/Tests/InfrastructureTests/ | head -20
grep -rn "Score(\|Part(\|Instrument(\|InstrumentChannel(" /Users/kiichi/Developer/Personal/swift-packages/swift-sheet-music/Sources/SheetMusicCore | grep "public init" | head -20
```

Expected: confirm public initializers for `Score`, `Part`, `Instrument`, `InstrumentChannel`. The test will construct a minimal Score directly. If no public init lets you build a useful fixture, look for an existing test fixture in `swift-sheet-music`'s `Tests/SheetMusicTests` and mirror its approach (e.g. parsing a tiny `.mscx` string).

- [ ] **Step 2: Write the test**

Create `Packages/Infrastructure/Tests/InfrastructureTests/Audio/LivePlaybackControllerTests.swift`. The exact Score construction depends on what step 1 found, but the shape is:

```swift
@testable import Audio
import Domain
import Foundation
import SheetMusicCore
import Testing

@Suite struct LivePlaybackControllerTests {
    /// Resolver probe that reports a fixed set of `(bank, program, isDrums)`
    /// triples as "precisely available", everything else as missing.
    private struct StubProbe: PrecisePatchProbe {
        let available: Set<Triple>
        struct Triple: Hashable { let bank: Int; let program: Int; let isDrums: Bool }

        func precisePath(forBank bank: Int, program: Int, isDrums: Bool) -> URL? {
            available.contains(.init(bank: bank, program: program, isDrums: isDrums))
                ? URL(fileURLWithPath: "/dev/null")
                : nil
        }
    }

    @Test func pitchedStaffWithMissingPatchRewritesToFlute() {
        // Build a score with one pitched part on (bank: 5, program: 42).
        // (Use whatever fixture builder Step 1 confirmed.)
        let score = makeScore(parts: [.pitched(bank: 5, program: 42)])
        let probe = StubProbe(available: [])

        let result = LivePlaybackController.scoreWithFallbackRewrites(score, probe: probe)
        let channel = firstChannel(of: result, partIndex: 0)
        #expect(channel.bank == 0)
        #expect(channel.program == 73)
    }

    @Test func drumStaffWithMissingPatchRewritesToStandardKit() {
        let score = makeScore(parts: [.drums(bank: 0, program: 0)])
        let probe = StubProbe(available: [])

        let result = LivePlaybackController.scoreWithFallbackRewrites(score, probe: probe)
        let channel = firstChannel(of: result, partIndex: 0)
        #expect(channel.bank == 0)
        #expect(channel.program == 0)
        // Sanity: the part is still flagged as drums.
        #expect(result.parts[0].instrument.useDrumset)
    }

    @Test func availablePatchPassesThrough() {
        let score = makeScore(parts: [.pitched(bank: 8, program: 0)])
        let probe = StubProbe(available: [.init(bank: 8, program: 0, isDrums: false)])

        let result = LivePlaybackController.scoreWithFallbackRewrites(score, probe: probe)
        let channel = firstChannel(of: result, partIndex: 0)
        #expect(channel.bank == 8)
        #expect(channel.program == 0)
    }
}

// `makeScore`, `firstChannel(of:partIndex:)`, and the `.pitched` /
// `.drums` shorthand live in a small fixture file alongside the test.
// If Step 1 surfaced an existing fixture builder, use it — otherwise
// implement these helpers in the same file under a `// MARK: -
// Fixtures` divider.
```

If Step 1 showed that constructing a minimal `Score` by hand is impractical (e.g. requires populating `Measure`s, `Voice`s, etc.), instead parse a tiny inline MSCX or similar fixture used elsewhere in the codebase, but keep the assertions identical.

- [ ] **Step 3: Run the new tests**

```bash
cd Packages/Infrastructure
swift test --filter LivePlaybackControllerTests
```

Expected: PASS for all three `@Test`s.

- [ ] **Step 4: Run the full Infrastructure test suite to catch regressions**

```bash
cd Packages/Infrastructure
swift test
```

Expected: every previously-passing test still passes. New `MuseScoreSF2ResolverTests` and `LivePlaybackControllerTests` pass.

- [ ] **Step 5: Commit**

```bash
git add Packages/Infrastructure/Tests/InfrastructureTests/Audio/LivePlaybackControllerTests.swift
git commit -m "test(audio): cover LivePlaybackController fallback channel rewrite"
```

---

### Task 8: Wire `AppBootstrap`, bump `swift-sheet-music` revision, update `project.yml`

**Files:**
- Modify: `App/AppBootstrap.swift`
- Modify: `project.yml`
- Modify: `Packages/Infrastructure/Package.swift`

- [ ] **Step 1: Bump the swift-sheet-music revision pin in both manifests**

Use the SHA recorded at the end of Task 1 (`<NEW_SHA>`).

In `project.yml`, replace:

```yaml
  swift-sheet-music:
    url: "git@github.com:jiyimeta/swift-sheet-music.git"
    revision: 3d8b3894e93dc55ad205b939cfc82d52bf22831e
```

with:

```yaml
  swift-sheet-music:
    url: "git@github.com:jiyimeta/swift-sheet-music.git"
    revision: <NEW_SHA>
```

In `Packages/Infrastructure/Package.swift`, replace:

```swift
        .package(
            url: "git@github.com:jiyimeta/swift-sheet-music.git",
            revision: "3d8b3894e93dc55ad205b939cfc82d52bf22831e"
        ),
```

with:

```swift
        .package(
            url: "git@github.com:jiyimeta/swift-sheet-music.git",
            revision: "<NEW_SHA>"
        ),
```

- [ ] **Step 2: Replace the `Sounds` folder reference with `Soundfonts` in `project.yml`**

In `project.yml`'s `targets.Folino.sources` block, replace:

```yaml
      - path: App
        excludes:
          - Info.plist
          - Folino.entitlements
          - Resources/Sounds
      - path: App/Resources/Sounds
        type: folder
        buildPhase: resources
```

with:

```yaml
      - path: App
        excludes:
          - Info.plist
          - Folino.entitlements
          - Resources/Soundfonts
      - path: App/Resources/Soundfonts
        type: folder
        buildPhase: resources
```

- [ ] **Step 3: Wire AppBootstrap to a single resolver instance**

In `App/AppBootstrap.swift`, replace lines 50–56 (the resolver / playbackController construction) with:

```swift
            let soundfontResolver = MuseScoreSF2Resolver(
                cacheDirectory: AppPaths.soundfontCacheDirectory
            )
            playbackController = LivePlaybackController(
                soundfontResolver: soundfontResolver,
                domainResolver: soundfontResolver,
                precisionProbe: soundfontResolver
            )
```

(`MuseScoreSF2Resolver` conforms to all three protocols, so the same instance can satisfy all three slots.)

The `import Audio` line stays (for `LivePlaybackController`); the `BundleSoundfontResolver` reference is gone — verify there's no lingering `BundleSoundfontResolver` mention in `App/AppBootstrap.swift`:

```bash
grep -n BundleSoundfontResolver App/AppBootstrap.swift
```

Expected: no matches.

- [ ] **Step 4: Regenerate the Xcode project**

```bash
xcodegen generate
```

Expected: `Folino.xcodeproj` rewritten. The tool is idempotent; it pulls the new `swift-sheet-music` revision via SwiftPM on next build.

- [ ] **Step 5: Build the app**

```bash
xcodebuild -project Folino.xcodeproj -scheme Folino \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -skipPackagePluginValidation build
```

Expected: clean build, exit code 0. SwiftPM resolves the new `swift-sheet-music` revision and the new resolver protocol signature compiles end-to-end (Tasks 1, 2, 4, 6 must all be in place).

If the build fails because `Score.setPart(...)` doesn't exist, return to Task 6 Step 4 and adapt the rewrite to whatever public mutator `SheetMusicCore` actually exposes.

- [ ] **Step 6: Run the app's UI test bundle**

```bash
xcodebuild -project Folino.xcodeproj -scheme Folino \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -skipPackagePluginValidation test
```

Expected: same pass/fail set as before this branch's other UI work. The change shouldn't touch any UI test, but a regression here means a non-test path (like AppBootstrap) shipped broken.

- [ ] **Step 7: Commit**

```bash
git add App/AppBootstrap.swift project.yml Packages/Infrastructure/Package.swift
git commit -m "feat(app): wire single MuseScoreSF2Resolver and bump swift-sheet-music"
```

---

### Task 9: Cleanup — remove the gitignored GM SoundFont and update CLAUDE.md

**Files:**
- Delete (untracked, gitignored): `App/Resources/Sounds/MuseScore_General.sf2` and the directory itself
- Modify: `CLAUDE.md`

- [ ] **Step 1: Confirm the directory is untracked, then remove it**

```bash
git check-ignore App/Resources/Sounds/ && rm -rf App/Resources/Sounds
ls -la App/Resources/
```

Expected: `App/Resources/` no longer contains `Sounds/`. (`git check-ignore` confirms the path is still gitignored — at this point the directory is dev-machine-only, so the rm is safe.)

- [ ] **Step 2: Strip the GM-copy step from `CLAUDE.md`**

In `CLAUDE.md`, replace the First-Time Setup block (lines 9–28) with:

```markdown
## First-Time Setup

```sh
cp Config/Local.xcconfig.sample Config/Local.xcconfig
# edit Local.xcconfig to set your Apple Developer Team ID

xcodegen generate
open Folino.xcodeproj

# install the pre-commit hook (one-time per clone)
brew install pre-commit swiftlint swiftformat   # if not already installed
pre-commit install
```
```

(The bundled SoundFonts are committed under `App/Resources/Soundfonts/` — no manual copy step.)

- [ ] **Step 3: Verify `git status` is clean of stray paths**

```bash
git status
```

Expected: only `CLAUDE.md` shows as modified. No leftover `App/Resources/Sounds/` (untracked dir was removed in Step 1; `.gitignore` was updated in Task 3).

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md
git commit -m "docs(setup): drop manual GM SoundFont copy step"
```

---

### Task 10: End-to-end smoke

Verify the change actually plays a score on device-class hardware. The previews path doesn't exercise audio, so this needs the simulator.

- [ ] **Step 1: Re-run the full app build + tests**

```bash
xcodebuild -project Folino.xcodeproj -scheme Folino \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -skipPackagePluginValidation test
```

Expected: green.

- [ ] **Step 2: Manually verify playback in the simulator**

```bash
xcodebuild -project Folino.xcodeproj -scheme Folino \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -skipPackagePluginValidation -derivedDataPath /tmp/folino-dd build
xcrun simctl install booted /tmp/folino-dd/Build/Products/Debug-iphonesimulator/Folino.app
xcrun simctl launch booted com.KeyNumber.Folino
```

Hand control back to the user (or perform manually). What to look for:
1. Open a pitched score whose patches are NOT yet cached and NOT bundled (e.g. anything other than Flute) — confirm playback starts after a brief download window. After the download completes and the app is restarted, second launch plays without a network fetch (confirms cache hit beats download).
2. Open a drumset score (e.g. one with a percussion staff) — confirm the metronome and drum staff both produce sound. (This was the regression risk: drum bundle vs pitched bundle naming.)
3. With the network disabled (Settings → Network Link Conditioner → 100% Loss, or `xcrun simctl status_bar booted override --dataNetwork wifi 0`), open a fresh score whose patches are not yet cached. Confirm pitched parts play with a flute timbre and drum parts play with the standard kit — neither silent, neither crashing.

If audio is wrong on any of those three, file a defect against the resolver lookup chain (Task 4) and the controller rewrite (Task 6) before merging.

- [ ] **Step 3: Stop / report back**

No commit for this task — it's a verification gate. If everything is green, the branch is ready to merge.

---

## Self-Review Notes

- **Spec coverage:** §1 protocol change → Task 1; metronome path is explicitly extended in Task 1 §3c. §2 bundled fallback files → Task 3. §3 resolver consolidation → Task 4 (struct) + Task 6 (controller side). §4 channel rewrite → Task 6. §5 AppBootstrap wiring → Task 8. §6 tests → Tasks 5 and 7. Out-of-scope items (UI status, pre-warm, cache pruning, GM opt-in) are intentionally not in any task.
- **Migration:** Task 3 adds `App/Resources/Soundfonts/` and removes `App/Resources/Sounds/` from `.gitignore`. Task 8 updates `project.yml`. Task 9 deletes the dev-machine `Sounds/` directory and updates `CLAUDE.md`.
- **Type consistency:** `isDrums: Bool` is added to `SoundfontResolver` (sync, async), `SoundfontPatchKey`, and `MuseScoreSF2Resolver.fileName(...)` consistently. `precisePath(forBank:program:isDrums:)` is the same name across the protocol and the implementation. `PrecisePatchProbe` is the protocol name in both Domain (declaration) and the controller (use site).
- **Open risk:** Task 6 Step 3 assumes `Score.setPart(_:at:)` (or an equivalent public mutator) exists in `SheetMusicCore`. Step 4 of Task 6 verifies this against the package; if missing, the controller rebuilds the score using whatever public API does exist. This is called out in the plan rather than buried.
