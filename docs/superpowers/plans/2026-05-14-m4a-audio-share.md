# m4a Audio Share Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an `.m4a` audio entry to the Library row share menu, backed by `swift-sheet-music`'s offline `PlaybackEngine.exportAudioFile`. Renders the score with the user's currently-resolved soundfonts at AAC 128 kbps stereo 44.1 kHz, hard-erroring if any required SF2 patch can't be fetched.

**Architecture:**
1. Domain adds `ScoreShareFormat.audioM4A` and a new `ScoreAudioExporter` protocol whose surface stays Foundation-only (no `SheetMusicAudio` types leak out).
2. The `Audio` infra module provides `LiveScoreAudioExporter`: prefetches every distinct `(bank, program, isDrums)` patch via the existing `Domain.SoundfontResolver`, then drives a one-shot `PlaybackEngine` to write the file.
3. `LiveScoreShareService` (in `ScoreFiles`) gains a `ScoreAudioExporter` collaborator and routes the new `.audioM4A` case to it. App wires both at composition time.

**Tech Stack:** Swift 6.3, `swift-sheet-music` (revision `efebe4092a017d4917f89648cbb93524b89e8ceb` — already pinned), AVFoundation (transitively, via SheetMusicAudio), Swift Testing (`@Test` / `#expect`).

Spec: `docs/superpowers/specs/2026-05-14-m4a-audio-share-design.md`.

---

## File Map

**Create:**
- `Packages/Domain/Sources/Domain/Protocols/ScoreAudioExporter.swift`
- `Packages/Infrastructure/Sources/Audio/LiveScoreAudioExporter.swift`
- `Packages/Infrastructure/Tests/InfrastructureTests/Audio/LiveScoreAudioExporterTests.swift`

**Modify:**
- `Packages/Domain/Sources/Domain/Protocols/ScoreShareService.swift` — add `.audioM4A` case
- `Packages/Infrastructure/Sources/Audio/LivePlaybackController.swift` — promote `distinctPatchKeys` from `private static` to `static` (package-internal), so `LiveScoreAudioExporter` can reuse it
- `Packages/Infrastructure/Sources/ScoreFiles/LiveScoreShareService.swift` — inject `ScoreAudioExporter`, append `.audioM4A` to `availableFormats`, add `.audioM4A` case to `prepareShare`
- `Packages/Infrastructure/Tests/InfrastructureTests/ScoreFiles/LiveScoreShareServiceTests.swift` — update existing `init`s, extend `availableFormats` assertion, add `.audioM4A` prepareShare test
- `Packages/Features/Library/Tests/LibraryTests/Fakes/FakeScoreShareService.swift` — append `.audioM4A` to default formats
- `Packages/Features/Library/Sources/Library/Views/ScoreRowMenu.swift` — add `.audioM4A` to `placeholderFormats` + switch arms in `shareMenuFormatText` / `shareMenuIconName`
- `Packages/Features/Library/Sources/Library/Resources/Localizable.xcstrings` — add `library.format.m4a`
- `App/AppBootstrap.swift` — build `LiveScoreAudioExporter`, pass to `LiveScoreShareService`

No `Package.swift` / `project.yml` edits — all dependencies are already declared.

---

## Task 1: Domain — add `.audioM4A` case to `ScoreShareFormat`

**Files:**
- Modify: `Packages/Domain/Sources/Domain/Protocols/ScoreShareService.swift`

- [ ] **Step 1: Edit `ScoreShareFormat`**

In `Packages/Domain/Sources/Domain/Protocols/ScoreShareService.swift`, add the new case as the last enum entry:

```swift
public enum ScoreShareFormat: Hashable, Sendable {
    case museScoreV4
    case museScoreV3
    case pdf
    case midi
    case audioM4A
}
```

Leave the surrounding doc comment as-is.

- [ ] **Step 2: Build the Domain package**

Run from repo root:

```sh
cd Packages/Domain && swift build
```

Expected: build succeeds with no warnings about exhaustive switches yet (other modules will surface those next).

- [ ] **Step 3: Commit**

```sh
git add Packages/Domain/Sources/Domain/Protocols/ScoreShareService.swift
git commit -m "Add audioM4A case to ScoreShareFormat"
```

---

## Task 2: Domain — add `ScoreAudioExporter` protocol

**Files:**
- Create: `Packages/Domain/Sources/Domain/Protocols/ScoreAudioExporter.swift`

- [ ] **Step 1: Create the protocol file**

Write `Packages/Domain/Sources/Domain/Protocols/ScoreAudioExporter.swift` with exactly:

```swift
import Foundation
import SheetMusicCore

/// Renders a `Score` to an audio file at `url`. Implementations
/// run an offline AVAudioEngine pass via `swift-sheet-music`'s
/// `PlaybackEngine.exportAudioFile`. The protocol surface is
/// Foundation-only — codec / bitrate / sample-rate choices live
/// inside the implementation so Domain stays free of
/// `SheetMusicAudio` types.
///
/// Errors thrown:
/// - `DomainError.scoreWriteFailed(reason:)` — every failure mode
///   (missing soundfont, engine setup, file write) is funnelled
///   through this case so the Library's existing error-alert
///   plumbing can render the message verbatim.
/// - `CancellationError` — if the calling Task is cancelled
///   mid-render.
public protocol ScoreAudioExporter: Sendable {
    /// Render `score` and write the resulting `.m4a` to `url`. The
    /// caller picks the destination path; the implementation
    /// overwrites any pre-existing file at that URL.
    func exportM4A(score: Score, to url: URL) async throws
}
```

`Score` is re-exported by Domain through `SheetMusicCore` — the existing `ScoreShareService.swift` and `PlaybackController.swift` files already import `SheetMusicCore` directly, so this matches the established pattern.

- [ ] **Step 2: Build Domain**

```sh
cd Packages/Domain && swift build
```

Expected: success.

- [ ] **Step 3: Commit**

```sh
git add Packages/Domain/Sources/Domain/Protocols/ScoreAudioExporter.swift
git commit -m "Add ScoreAudioExporter protocol"
```

---

## Task 3: Audio — promote `distinctPatchKeys` so the new exporter can reuse it

**Files:**
- Modify: `Packages/Infrastructure/Sources/Audio/LivePlaybackController.swift:192-203`

- [ ] **Step 1: Change visibility**

In `LivePlaybackController.swift`, locate the existing helper around line 192:

```swift
    private static func distinctPatchKeys(in score: Score) -> Set<SoundfontPatchKey> {
```

Change it to (drop the `private`, default to package-internal):

```swift
    /// Distinct `(bank, program, isDrums)` triples used by `score`.
    /// Internal so `LiveScoreAudioExporter` can prefetch the same
    /// patch set before its offline render.
    static func distinctPatchKeys(in score: Score) -> Set<SoundfontPatchKey> {
```

Body unchanged.

- [ ] **Step 2: Build the Audio target**

```sh
cd Packages/Infrastructure && swift build --target Audio
```

Expected: success. No callers break — the helper was only called from inside `LivePlaybackController` itself.

- [ ] **Step 3: Commit**

```sh
git add Packages/Infrastructure/Sources/Audio/LivePlaybackController.swift
git commit -m "Expose distinctPatchKeys for LiveScoreAudioExporter reuse"
```

---

## Task 4: Audio — write `LiveScoreAudioExporter` failing test

**Files:**
- Create: `Packages/Infrastructure/Tests/InfrastructureTests/Audio/LiveScoreAudioExporterTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Packages/Infrastructure/Tests/InfrastructureTests/Audio/LiveScoreAudioExporterTests.swift`:

```swift
@testable import Audio
@testable import Domain
import Foundation
import SheetMusic
import SheetMusicAudio
import Testing

@MainActor
struct LiveScoreAudioExporterTests {
    /// Domain.SoundfontResolver fake that always throws on resolve. Used
    /// to verify the exporter's prefetch gate hard-fails before the
    /// PlaybackEngine is touched.
    private final class ThrowingDomainResolver: Domain.SoundfontResolver, @unchecked Sendable {
        struct Boom: Error {}
        func resolveSoundfont(bank _: Int, program _: Int, isDrums _: Bool) async throws -> URL {
            throw Boom()
        }

        func cachedPatches() async throws -> [SoundfontPatch] { [] }
        func totalCacheSizeBytes() async throws -> Int64 { 0 }
        func deletePatch(bank _: Int, program _: Int, isDrums _: Bool) async throws {}
        func clearCache() async throws {}
    }

    /// SheetMusicAudio.SoundfontResolver fake that the exporter passes
    /// to `PlaybackEngine`. The throwing-prefetch test never reaches
    /// the engine, so this just satisfies the constructor.
    private final class StubAudioResolver: SheetMusicAudio.SoundfontResolver, @unchecked Sendable {
        func resolveSoundfont(bank _: Int, program _: Int, isDrums _: Bool) -> URL? { nil }
    }

    @Test func `exportM4A throws scoreWriteFailed when a required patch cannot be resolved`() async throws {
        let score = try SheetMusic.loadScore(mscxData: Fixtures.minimalMSCXData())
        let exporter = LiveScoreAudioExporter(
            soundfontResolver: StubAudioResolver(),
            domainResolver: ThrowingDomainResolver(),
        )
        let tmp = try TempDirectory()
        let dest = tmp.url.appending(path: "out.m4a")

        await #expect(throws: DomainError.self) {
            try await exporter.exportM4A(score: score, to: dest)
        }
        #expect(!FileManager.default.fileExists(atPath: dest.path))
    }
}
```

- [ ] **Step 2: Run the test — confirm it fails to compile**

```sh
cd Packages/Infrastructure && swift test --filter LiveScoreAudioExporterTests
```

Expected: compile error — `LiveScoreAudioExporter` is undefined.

(We move on to Task 5 to add the implementation; the test stays red until then.)

- [ ] **Step 3: Stage but do NOT commit yet**

```sh
git add Packages/Infrastructure/Tests/InfrastructureTests/Audio/LiveScoreAudioExporterTests.swift
```

The commit happens together with Task 5's implementation so the repo never has a broken-build commit.

---

## Task 5: Audio — implement `LiveScoreAudioExporter`

**Files:**
- Create: `Packages/Infrastructure/Sources/Audio/LiveScoreAudioExporter.swift`

- [ ] **Step 1: Write the implementation**

Create `Packages/Infrastructure/Sources/Audio/LiveScoreAudioExporter.swift`:

```swift
import Domain
import Foundation
import SheetMusicAudio
import SheetMusicCore

/// `Domain.ScoreAudioExporter` backed by `swift-sheet-music`'s
/// offline `PlaybackEngine.exportAudioFile`.
///
/// Builds a one-shot `PlaybackEngine` per call (the engine is
/// `@MainActor` and not designed to be reused for back-to-back
/// renders), so live playback through `LivePlaybackController` is
/// unaffected — `exportAudioFile` itself spins a dedicated
/// `AVAudioEngine` internally for the offline render.
///
/// Soundfont policy: every distinct `(bank, program, isDrums)` triple
/// the score uses is prefetched through the `Domain.SoundfontResolver`
/// before the engine is asked to prepare. A single resolve failure
/// (e.g. offline + uncached) propagates as
/// `DomainError.scoreWriteFailed` and the offline render is never
/// attempted. This is a deliberate departure from
/// `LivePlaybackController.scoreWithFallbackRewrites`, which silently
/// falls back to bundled patches: an audio export that secretly
/// substitutes piano for, say, drums would be confusing once shared
/// out of the app.
@MainActor
public final class LiveScoreAudioExporter: Domain.ScoreAudioExporter {
    private let soundfontResolver: any SheetMusicAudio.SoundfontResolver
    private let domainResolver: any Domain.SoundfontResolver

    public init(
        soundfontResolver: any SheetMusicAudio.SoundfontResolver,
        domainResolver: any Domain.SoundfontResolver,
    ) {
        self.soundfontResolver = soundfontResolver
        self.domainResolver = domainResolver
    }

    public func exportM4A(score: Score, to url: URL) async throws {
        try await prefetchAllPatches(in: score)

        let engine = PlaybackEngine(soundfontResolver: soundfontResolver)
        do {
            try engine.prepare(score: score)
        } catch {
            throw DomainError.scoreWriteFailed(
                reason: "engine prepare failed: \((error as NSError).localizedDescription)",
            )
        }

        do {
            try await engine.exportAudioFile(
                to: url,
                score: score,
                format: .m4a(.init(
                    sampleRate: 44_100,
                    bitRate: 128_000,
                    channels: .stereo,
                )),
                range: .full,
            )
        } catch let error as AudioExportError {
            throw DomainError.scoreWriteFailed(reason: "\(error)")
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw DomainError.scoreWriteFailed(
                reason: (error as NSError).localizedDescription,
            )
        }
    }

    private func prefetchAllPatches(in score: Score) async throws {
        let keys = LivePlaybackController.distinctPatchKeys(in: score)
        for key in keys {
            do {
                _ = try await domainResolver.resolveSoundfont(
                    bank: key.bank,
                    program: key.program,
                    isDrums: key.isDrums,
                )
            } catch {
                throw DomainError.scoreWriteFailed(
                    reason: "soundfont unavailable (bank \(key.bank), program \(key.program)): \((error as NSError).localizedDescription)",
                )
            }
        }
    }
}
```

- [ ] **Step 2: Run the test — confirm it now passes**

```sh
cd Packages/Infrastructure && swift test --filter LiveScoreAudioExporterTests
```

Expected: 1 test passes (`exportM4A throws scoreWriteFailed when a required patch cannot be resolved`).

If the resolver's swift-sheet-music API call from `LivePlaybackController` differs (e.g. parameter labels), match them by re-reading `LivePlaybackController.swift:192-203`.

- [ ] **Step 3: Commit (test + implementation together)**

```sh
git add Packages/Infrastructure/Sources/Audio/LiveScoreAudioExporter.swift Packages/Infrastructure/Tests/InfrastructureTests/Audio/LiveScoreAudioExporterTests.swift
git commit -m "Add LiveScoreAudioExporter for offline m4a render"
```

---

## Task 6: ScoreFiles — failing test for `LiveScoreShareService` audio routing

**Files:**
- Modify: `Packages/Infrastructure/Tests/InfrastructureTests/ScoreFiles/LiveScoreShareServiceTests.swift`

- [ ] **Step 1: Add a fake exporter type and update existing rig**

Edit `LiveScoreShareServiceTests.swift`. Add this fake near the top of the type, before the `Rig` class:

```swift
    /// Fake `ScoreAudioExporter` that captures its call args and
    /// writes a sentinel byte to the destination URL so the
    /// returned share URL can be inspected.
    private final class FakeAudioExporter: Domain.ScoreAudioExporter, @unchecked Sendable {
        var error: Error?
        private(set) var calls: [(score: Score, url: URL)] = []

        func exportM4A(score: Score, to url: URL) async throws {
            calls.append((score, url))
            if let error { throw error }
            try Data([0]).write(to: url)
        }
    }
```

(Add `import SheetMusic` if it's not already at the top — it is, per the existing imports.)

Update the `Rig` class to take and store a fake exporter, and forward it into the service:

```swift
    private final class Rig {
        let tmp: TempDirectory
        let svc: LiveScoreShareService
        let scores: URL
        let shareTmp: URL
        let item: ScoreItem
        let audio: FakeAudioExporter

        init(scoreData: Data, localFileName: String) throws {
            tmp = try TempDirectory()
            scores = tmp.url.appending(path: "Scores")
            shareTmp = tmp.url.appending(path: "Share")
            try FileManager.default.createDirectory(at: scores, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: shareTmp, withIntermediateDirectories: true)
            try scoreData.write(to: scores.appending(path: localFileName))
            audio = FakeAudioExporter()
            svc = LiveScoreShareService(
                scoresDirectory: scores,
                shareTempDirectory: shareTmp,
                gateway: LiveScoreFileGateway(),
                audioExporter: audio,
            )
            item = LiveScoreShareServiceTests.makeItem(localFileName: localFileName)
        }
    }
```

Also update the `available formats leaves everything unflagged when source cannot load` test, which constructs the service inline:

```swift
        let svc = LiveScoreShareService(
            scoresDirectory: tmp.url.appending(path: "Scores"),
            shareTempDirectory: tmp.url.appending(path: "Share"),
            gateway: LiveScoreFileGateway(),
            audioExporter: FakeAudioExporter(),
        )
```

- [ ] **Step 2: Update `availableFormats` expectation**

In the test `available formats reports the same four formats for every loadable item`:

- Rename the test (Swift Testing names embed in failure output, keep them honest):
  ```swift
  @Test func `available formats reports the same five formats for every loadable item`() async throws {
  ```
- Update the assertion:
  ```swift
  #expect(formats == [.museScoreV4, .museScoreV3, .pdf, .midi, .audioM4A])
  ```

In the two `available formats flags the matching muse score version for ...` tests, append:

```swift
        #expect(options.first { $0.format == .audioM4A }?.isOriginal == false)
```

- [ ] **Step 3: Add prepareShare audio test**

Append at the bottom of the type, after `prepare share twice overwrites`:

```swift
    @Test func `prepare share audio m4a writes a file via the audio exporter`() async throws {
        let rig = try Self.makeRig(
            scoreData: Fixtures.minimalMSCZData(), localFileName: "abc.mscz",
        )

        let url = try await rig.svc.prepareShare(item: rig.item, format: .audioM4A)

        #expect(url.pathExtension == "m4a")
        #expect(url.deletingLastPathComponent().path == rig.shareTmp.path)
        #expect(rig.audio.calls.count == 1)
        #expect(rig.audio.calls.first?.url == url)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func `prepare share audio m4a propagates exporter errors`() async throws {
        let rig = try Self.makeRig(
            scoreData: Fixtures.minimalMSCZData(), localFileName: "abc.mscz",
        )
        rig.audio.error = DomainError.scoreWriteFailed(reason: "no soundfont")

        await #expect(throws: DomainError.self) {
            try await rig.svc.prepareShare(item: rig.item, format: .audioM4A)
        }
    }
```

- [ ] **Step 4: Run the tests — confirm compile failure first**

```sh
cd Packages/Infrastructure && swift test --filter LiveScoreShareServiceTests
```

Expected: compile error — `LiveScoreShareService.init` doesn't accept `audioExporter:` yet, and the `.audioM4A` switch arm is missing.

Stage but don't commit; Task 7 fixes the build.

```sh
git add Packages/Infrastructure/Tests/InfrastructureTests/ScoreFiles/LiveScoreShareServiceTests.swift
```

---

## Task 7: ScoreFiles — extend `LiveScoreShareService` for `.audioM4A`

**Files:**
- Modify: `Packages/Infrastructure/Sources/ScoreFiles/LiveScoreShareService.swift`

- [ ] **Step 1: Add the collaborator + init param**

Top of the type, replace the existing properties + init with:

```swift
public struct LiveScoreShareService: ScoreShareService {
    private let scoresDirectory: URL
    private let shareTempDirectory: URL
    private let gateway: any ScoreFileGateway
    private let audioExporter: any ScoreAudioExporter

    public init(
        scoresDirectory: URL,
        shareTempDirectory: URL,
        gateway: any ScoreFileGateway,
        audioExporter: any ScoreAudioExporter,
    ) {
        self.scoresDirectory = scoresDirectory
        self.shareTempDirectory = shareTempDirectory
        self.gateway = gateway
        self.audioExporter = audioExporter
    }
```

- [ ] **Step 2: Append `.audioM4A` to `availableFormats`**

Change:

```swift
        let formats: [ScoreShareFormat] = [.museScoreV4, .museScoreV3, .pdf, .midi]
```

to:

```swift
        let formats: [ScoreShareFormat] = [.museScoreV4, .museScoreV3, .pdf, .midi, .audioM4A]
```

- [ ] **Step 3: Add `.audioM4A` arm + writer helper**

In the `prepareShare` switch, add the new case:

```swift
        case .audioM4A:
            return try await writeM4A(score: score, sanitizedTitle: title)
```

At the bottom of the type, after `writeMSCZ`, add:

```swift
    private func writeM4A(
        score: Score,
        sanitizedTitle: String,
    ) async throws -> URL {
        let destination = shareTempDirectory.appending(path: "\(sanitizedTitle).m4a")
        try? FileManager.default.removeItem(at: destination)
        try await audioExporter.exportM4A(score: score, to: destination)
        return destination
    }
```

`exportM4A` already wraps every failure in `DomainError.scoreWriteFailed`, so the helper just lets it throw.

- [ ] **Step 4: Build + test**

```sh
cd Packages/Infrastructure && swift test --filter LiveScoreShareServiceTests
```

Expected: every `LiveScoreShareServiceTests` test passes — including the two new audio tests.

Then run the broader Infrastructure tests:

```sh
cd Packages/Infrastructure && swift test
```

Expected: all green. (`LiveScoreAudioExporterTests` from Task 5 still passes.)

- [ ] **Step 5: Commit**

```sh
git add Packages/Infrastructure/Sources/ScoreFiles/LiveScoreShareService.swift Packages/Infrastructure/Tests/InfrastructureTests/ScoreFiles/LiveScoreShareServiceTests.swift
git commit -m "Route audioM4A share through ScoreAudioExporter"
```

---

## Task 8: Library tests fake — add `.audioM4A`

**Files:**
- Modify: `Packages/Features/Library/Tests/LibraryTests/Fakes/FakeScoreShareService.swift`

- [ ] **Step 1: Append the new format to the default options**

Replace `availableFormatsByDefault` with:

```swift
    var availableFormatsByDefault: [ScoreShareFormatOption] = [
        ScoreShareFormatOption(format: .museScoreV4, isOriginal: true),
        ScoreShareFormatOption(format: .museScoreV3),
        ScoreShareFormatOption(format: .pdf),
        ScoreShareFormatOption(format: .midi),
        ScoreShareFormatOption(format: .audioM4A),
    ]
```

- [ ] **Step 2: Run Library tests**

```sh
cd Packages/Features/Library && swift test
```

Expected: all green. If any existing test asserts a count of 4 share options, update to 5.

- [ ] **Step 3: Commit**

```sh
git add Packages/Features/Library/Tests/LibraryTests/Fakes/FakeScoreShareService.swift
git commit -m "Include audioM4A in FakeScoreShareService default formats"
```

---

## Task 9: Library UI — render the new format in `ScoreRowMenu`

**Files:**
- Modify: `Packages/Features/Library/Sources/Library/Views/ScoreRowMenu.swift`

- [ ] **Step 1: Add to placeholder list**

Replace `placeholderFormats` with:

```swift
    static let placeholderFormats: [ScoreShareFormatOption] = [
        ScoreShareFormatOption(format: .museScoreV4),
        ScoreShareFormatOption(format: .museScoreV3),
        ScoreShareFormatOption(format: .pdf),
        ScoreShareFormatOption(format: .midi),
        ScoreShareFormatOption(format: .audioM4A),
    ]
```

- [ ] **Step 2: Add switch arms**

In `shareMenuFormatText`, add the `.audioM4A` case:

```swift
private func shareMenuFormatText(for format: ScoreShareFormat) -> Text {
    switch format {
    case .museScoreV4:
        Text("library.format.musescore4", bundle: .module)
    case .museScoreV3:
        Text("library.format.musescore3", bundle: .module)
    case .pdf:
        Text("library.format.pdf", bundle: .module)
    case .midi:
        Text("library.format.midi", bundle: .module)
    case .audioM4A:
        Text("library.format.m4a", bundle: .module)
    }
}
```

In `shareMenuIconName`:

```swift
private func shareMenuIconName(for format: ScoreShareFormat) -> String {
    switch format {
    case .museScoreV4, .museScoreV3:
        "doc.zipper"
    case .pdf:
        "doc.richtext"
    case .midi:
        "pianokeys"
    case .audioM4A:
        "waveform"
    }
}
```

- [ ] **Step 3: Build the Library package**

```sh
cd Packages/Features/Library && swift build
```

Expected: success.

- [ ] **Step 4: Stage; commit happens after Task 10's xcstrings update**

```sh
git add Packages/Features/Library/Sources/Library/Views/ScoreRowMenu.swift
```

---

## Task 10: Library localization — add `library.format.m4a`

**Files:**
- Modify: `Packages/Features/Library/Sources/Library/Resources/Localizable.xcstrings`

- [ ] **Step 1: Insert the new key**

Add a new string entry for `library.format.m4a` immediately before `library.format.midi` (alphabetical ordering — file is alphabetised by key). Use the same shape as the surrounding entries; value is `"M4A"` for every locale (term of art, intentionally not translated). Insert this block:

```json
    "library.format.m4a" : {
      "localizations" : {
        "en" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "M4A"
          }
        },
        "ja" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "M4A"
          }
        },
        "ko" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "M4A"
          }
        },
        "zh-Hans" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "M4A"
          }
        },
        "zh-Hant" : {
          "stringUnit" : {
            "state" : "translated",
            "value" : "M4A"
          }
        }
      }
    },
```

(Check the trailing comma rules — every preceding sibling entry already ends with a `,`, so the new entry's terminating `,` is correct as long as the next entry is `library.format.midi`.)

- [ ] **Step 2: Build the Library package**

```sh
cd Packages/Features/Library && swift build
```

Expected: success.

- [ ] **Step 3: Commit (UI + localization together)**

```sh
git add Packages/Features/Library/Sources/Library/Views/ScoreRowMenu.swift Packages/Features/Library/Sources/Library/Resources/Localizable.xcstrings
git commit -m "Render audioM4A row in Library share menu"
```

---

## Task 11: App — wire `LiveScoreAudioExporter` into bootstrap

**Files:**
- Modify: `App/AppBootstrap.swift`

- [ ] **Step 1: Build the audio exporter and pass it through**

In `AppBootstrap.start()`, the current order is:
1. Build `gateway`, `importer`.
2. Construct `shareService` with `(scoresDirectory:, shareTempDirectory:, gateway:)`.
3. Build `soundfontResolver`.
4. Build `playbackController`.

Reorder so `soundfontResolver` is built **before** `shareService`, then construct the exporter and pass it in:

```swift
            // `MuseScoreSF2Resolver` conforms to all three protocols
            // (`SheetMusicAudio.SoundfontResolver`, `Domain.SoundfontResolver`,
            // `Domain.PrecisePatchProbe`); one instance satisfies every slot.
            let soundfontResolver = MuseScoreSF2Resolver(
                cacheDirectory: AppPaths.soundfontCacheDirectory,
            )
            self.soundfontResolver = soundfontResolver
            if let bundleSF2URL = Bundle.main.url(
                forResource: "MuseScore_General", withExtension: "sf2", subdirectory: "Sounds",
            ) {
                presetCatalog = try? BundledSF2PresetCatalog(sf2URL: bundleSF2URL)
            }
            let audioExporter = LiveScoreAudioExporter(
                soundfontResolver: soundfontResolver,
                domainResolver: soundfontResolver,
            )
            shareService = LiveScoreShareService(
                scoresDirectory: AppPaths.scoresDirectory,
                shareTempDirectory: AppPaths.shareTempDirectory,
                gateway: gateway,
                audioExporter: audioExporter,
            )
            playbackController = LivePlaybackController(
                soundfontResolver: soundfontResolver,
                domainResolver: soundfontResolver,
                precisionProbe: soundfontResolver,
            )
```

`LiveScoreAudioExporter` lives in the `Audio` module which `AppBootstrap` already imports (line 1: `import Audio`).

- [ ] **Step 2: Build the app**

```sh
xcodegen generate
xcodebuild -project Folino.xcodeproj -scheme Folino \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -skipPackagePluginValidation build
```

Expected: success.

- [ ] **Step 3: Commit**

```sh
git add App/AppBootstrap.swift
git commit -m "Wire LiveScoreAudioExporter into AppBootstrap"
```

---

## Task 12: Smoke test on simulator

**Files:** none

- [ ] **Step 1: Run the full test suite**

```sh
xcodebuild -project Folino.xcodeproj -scheme Folino \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -skipPackagePluginValidation test
```

Expected: all tests pass.

- [ ] **Step 2: Manual verification — share an m4a from Library**

The user runs this themselves (programmatic gesture is unreliable per the project's iOS rules):

1. Open Folino in the iPhone 16 simulator.
2. Long-press a row that's been imported (any `.mscz` already in Library is fine).
3. Tap **Share → M4A**.
4. The share spinner should appear, then the iOS share sheet with one `.m4a` attachment named `<title>.m4a`.
5. Save it to Files / AirDrop it out and verify it plays in QuickTime / Music.

If a row exists whose required SF2 isn't bundled, repeat with the simulator in airplane mode after clearing Soundfont cache via Settings → Soundfonts → "Clear Cache". Picking M4A on that row should surface the existing error alert with a message like `Could not write score file: soundfont unavailable …` rather than producing a silent or fallback-rendered file.

- [ ] **Step 3: Report back**

If anything renders incorrectly, capture the error message and surface to the user. Otherwise the feature is complete.
