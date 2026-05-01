# Domain Models & Protocols Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Land Folino's Domain layer — the value types that describe the library's contents and the protocols that abstract every Infrastructure adapter — so subsequent feature plans can wire view models and adapters against a stable, well-typed contract.

**Architecture:** Foundation-only Swift value types and protocols. The `Domain` library re-exports `SheetMusicCore` (already wired in bootstrap T7) so consumers see one notation model. Each new type/protocol gets its own source file and its own test file; `swift test` from `Packages/Domain` is the per-task gate.

**Tech Stack:** Swift 6.3, Foundation, Swift Testing (`@Suite` / `@Test` / `#expect`), `SheetMusicCore` (re-exported). No CoreGraphics, no SwiftUI, no AVFoundation, no SDKs.

**Working directory:** `/Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.worktrees/feat-domain-layer`. Branch: `feat/domain-layer`. All paths below are relative to that directory unless noted.

**Done condition:** Every task lands on `feat/domain-layer` with passing `swift test` in `Packages/Domain`. The package contains 6 model files, 6 protocol files, supporting infrastructure (IDs, MusicalAnchor, ScoreFormat, DomainError), and a single `DomainExports.swift` that replaces `Placeholder.swift`. The whole-project `xcodebuild build` continues to succeed.

---

## File Structure

Files this plan produces, all under `Packages/Domain/`:

```
Sources/Domain/
  DomainExports.swift                   ─ @_exported import + module marker (replaces Placeholder.swift in Task 14)
  IDs.swift                             ─ Typed UUID newtypes + SoundfontPatchKey
  ScoreFormat.swift                     ─ The ScoreFormat enum + filename detection
  MusicalAnchor.swift                   ─ MusicalAnchor + UnitRect
  DomainError.swift                     ─ Shared Domain error type
  Models/
    ScoreItem.swift                     ─ Top-level library entry
    Tag.swift                           ─ User-defined tag
    Playlist.swift                      ─ Manual ordered playlist
    AnnotationLayer.swift               ─ Per-score annotations (drawings + text boxes)
    PlaybackPreferences.swift           ─ Mixer / tempo / loop preferences per score
    SoundfontPatch.swift                ─ Cache record for one (bank, program) sf2
  Protocols/
    ScoreLibraryRepository.swift        ─ Storage for ScoreItem / Tag / Playlist
    AnnotationStore.swift               ─ Storage for AnnotationLayer
    PlaybackController.swift            ─ Audio engine façade + cursor stream
    SoundfontResolver.swift             ─ Bank/program → URL + cache management
    CloudSync.swift                     ─ CloudKit sync state machine
    ScoreFileGateway.swift              ─ Score file I/O (mscx/mscz/MusicXML/MIDI/PDF)
Tests/DomainTests/
  DomainSmokeTests.swift                ─ Existing module-link + SheetMusicCore re-export checks (kept)
  IdentifiersTests.swift
  ScoreFormatTests.swift
  MusicalAnchorTests.swift
  DomainErrorTests.swift
  Models/
    ScoreItemTests.swift
    TagTests.swift
    PlaylistTests.swift
    AnnotationLayerTests.swift
    PlaybackPreferencesTests.swift
    SoundfontPatchTests.swift
  Protocols/
    StorageProtocolsTests.swift          ─ ScoreLibraryRepository + AnnotationStore fakes
    AudioProtocolsTests.swift            ─ PlaybackController + SoundfontResolver fakes
    SyncFileProtocolsTests.swift         ─ CloudSync + ScoreFileGateway fakes
```

Per-test-task pattern (strict TDD):

1. Write the test file with the assertions you expect to pass.
2. `swift test` — fails to compile because the type/protocol doesn't exist.
3. Write the implementation file.
4. `swift test` — passes.
5. Stage both files and commit.

The pre-commit hook will run SwiftFormat + SwiftLint on staged Swift files. SwiftFormat may reorder imports (alphabetical with `@testable` after); re-stage and re-commit if it does. `swiftlint lint --strict` will fail commits with real warnings — do not silence them; ask if a warning surfaces.

---

## Task 1: Identifier types

**Files:**
- Create: `Packages/Domain/Sources/Domain/IDs.swift`
- Create: `Packages/Domain/Tests/DomainTests/IdentifiersTests.swift`

- [ ] **Step 1: Write the failing test**

`Packages/Domain/Tests/DomainTests/IdentifiersTests.swift`:

```swift
import Foundation
import Testing
@testable import Domain

@Suite struct IdentifiersTests {
    @Test func scoreItemIDIsDistinctEachTime() {
        let a = ScoreItemID()
        let b = ScoreItemID()
        #expect(a != b)
        #expect(a.rawValue != b.rawValue)
    }

    @Test func scoreItemIDRoundTripsThroughCodable() throws {
        let id = ScoreItemID()
        let data = try JSONEncoder().encode(id)
        let decoded = try JSONDecoder().decode(ScoreItemID.self, from: data)
        #expect(decoded == id)
    }

    @Test func eachIdentifierKindIsDistinctType() {
        // Compile-time guarantee: passing a ScoreItemID where a TagID is required must not compile.
        // Runtime guarantee: their UUIDs can collide (extremely unlikely) but the values are still
        // not equatable because they are different types.
        let scoreID = ScoreItemID()
        let tagID = TagID()
        let _: ScoreItemID = scoreID
        let _: TagID = tagID
        // Cannot write `#expect(scoreID == tagID)` — that would not compile, which is the point.
    }

    @Test func soundfontPatchKeyEqualsByBankAndProgram() {
        let a = SoundfontPatchKey(bank: 0, program: 4)
        let b = SoundfontPatchKey(bank: 0, program: 4)
        let c = SoundfontPatchKey(bank: 128, program: 0)
        #expect(a == b)
        #expect(a != c)
    }

    @Test func soundfontPatchKeyHashesByBankAndProgram() {
        let set: Set<SoundfontPatchKey> = [
            SoundfontPatchKey(bank: 0, program: 4),
            SoundfontPatchKey(bank: 0, program: 4),
            SoundfontPatchKey(bank: 128, program: 0),
        ]
        #expect(set.count == 2)
    }
}
```

- [ ] **Step 2: Run the failing test**

```bash
cd Packages/Domain && swift test 2>&1 | tail -10
```

Expected: compile errors of the form `cannot find 'ScoreItemID' in scope` / `cannot find 'TagID' in scope` / `cannot find 'SoundfontPatchKey' in scope`.

- [ ] **Step 3: Write the implementation**

`Packages/Domain/Sources/Domain/IDs.swift`:

```swift
import Foundation

/// Strongly-typed identifier for a `ScoreItem`. Two identifiers of the same kind
/// can be equated; two identifiers of different kinds are different types and
/// will not compile when compared.
public struct ScoreItemID: Hashable, Sendable, Codable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct TagID: Hashable, Sendable, Codable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct PlaylistID: Hashable, Sendable, Codable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct AnnotationID: Hashable, Sendable, Codable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct AnnotationLayerID: Hashable, Sendable, Codable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct PlaybackPreferencesID: Hashable, Sendable, Codable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

/// Identity of a SoundFont 2 patch. Two patches with the same (bank, program)
/// are interchangeable — the cache records use this as the primary key.
public struct SoundfontPatchKey: Hashable, Sendable, Codable {
    public let bank: Int
    public let program: Int

    public init(bank: Int, program: Int) {
        self.bank = bank
        self.program = program
    }
}
```

- [ ] **Step 4: Run the test, verify pass**

```bash
swift test 2>&1 | tail -10
```

Expected: `5 tests passed` (the four explicit `@Test`s plus the existing `DomainSmokeTests`'s 2 — total 7). The newly added 5 tests in `IdentifiersTests` must all pass.

- [ ] **Step 5: Commit**

```bash
cd ../..
git add Packages/Domain/Sources/Domain/IDs.swift Packages/Domain/Tests/DomainTests/IdentifiersTests.swift
git commit -m "feat(domain): add typed identifier newtypes and SoundfontPatchKey

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: `ScoreFormat` enum

**Files:**
- Create: `Packages/Domain/Sources/Domain/ScoreFormat.swift`
- Create: `Packages/Domain/Tests/DomainTests/ScoreFormatTests.swift`

- [ ] **Step 1: Write the failing test**

`Packages/Domain/Tests/DomainTests/ScoreFormatTests.swift`:

```swift
import Foundation
import Testing
@testable import Domain

@Suite struct ScoreFormatTests {
    @Test func detectsExtensionsCaseInsensitively() {
        #expect(ScoreFormat.detect(filename: "song.mscz") == .mscz)
        #expect(ScoreFormat.detect(filename: "song.MSCZ") == .mscz)
        #expect(ScoreFormat.detect(filename: "song.mscx") == .mscx)
        #expect(ScoreFormat.detect(filename: "song.musicxml") == .musicXML)
        #expect(ScoreFormat.detect(filename: "song.xml") == .musicXML)
        #expect(ScoreFormat.detect(filename: "song.mxl") == .mxl)
        #expect(ScoreFormat.detect(filename: "song.mid") == .midi)
        #expect(ScoreFormat.detect(filename: "song.midi") == .midi)
        #expect(ScoreFormat.detect(filename: "song.smf") == .midi)
        #expect(ScoreFormat.detect(filename: "song.pdf") == .pdf)
    }

    @Test func returnsNilForUnknownExtension() {
        #expect(ScoreFormat.detect(filename: "song.txt") == nil)
        #expect(ScoreFormat.detect(filename: "song") == nil)
        #expect(ScoreFormat.detect(filename: "") == nil)
    }

    @Test func handlesPathsWithDirectories() {
        #expect(ScoreFormat.detect(filename: "/Documents/Scores/song.mscz") == .mscz)
        #expect(ScoreFormat.detect(filename: "subdir/song.mscz") == .mscz)
    }

    @Test func roundTripsThroughCodable() throws {
        for format in ScoreFormat.allCases {
            let data = try JSONEncoder().encode(format)
            let decoded = try JSONDecoder().decode(ScoreFormat.self, from: data)
            #expect(decoded == format)
        }
    }

    @Test func canonicalExtensionMatchesDetect() {
        for format in ScoreFormat.allCases {
            #expect(ScoreFormat.detect(filename: "song.\(format.canonicalExtension)") == format)
        }
    }
}
```

- [ ] **Step 2: Run the failing test**

```bash
cd Packages/Domain && swift test 2>&1 | tail -10
```

Expected: `cannot find type 'ScoreFormat'` errors.

- [ ] **Step 3: Write the implementation**

`Packages/Domain/Sources/Domain/ScoreFormat.swift`:

```swift
import Foundation

/// File format Folino can read and write. Each case represents a distinct on-disk encoding.
public enum ScoreFormat: String, Hashable, Sendable, Codable, CaseIterable {
    case mscx
    case mscz
    case musicXML
    case mxl
    case midi
    case pdf

    /// The default file extension Folino writes when exporting this format.
    public var canonicalExtension: String {
        switch self {
        case .mscx: "mscx"
        case .mscz: "mscz"
        case .musicXML: "musicxml"
        case .mxl: "mxl"
        case .midi: "mid"
        case .pdf: "pdf"
        }
    }

    /// Best-effort detection from a filename or path. Case-insensitive on the extension.
    public static func detect(filename: String) -> ScoreFormat? {
        guard let dotIndex = filename.lastIndex(of: ".") else { return nil }
        let ext = filename[filename.index(after: dotIndex)...].lowercased()
        switch ext {
        case "mscx": return .mscx
        case "mscz": return .mscz
        case "musicxml", "xml": return .musicXML
        case "mxl": return .mxl
        case "mid", "midi", "smf": return .midi
        case "pdf": return .pdf
        default: return nil
        }
    }
}
```

- [ ] **Step 4: Run the test, verify pass**

```bash
swift test 2>&1 | tail -10
```

Expected: `ScoreFormatTests` reports 5 tests passed.

- [ ] **Step 5: Commit**

```bash
cd ../..
git add Packages/Domain/Sources/Domain/ScoreFormat.swift Packages/Domain/Tests/DomainTests/ScoreFormatTests.swift
git commit -m "feat(domain): add ScoreFormat enum with filename detection

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: `MusicalAnchor` and `UnitRect`

**Files:**
- Create: `Packages/Domain/Sources/Domain/MusicalAnchor.swift`
- Create: `Packages/Domain/Tests/DomainTests/MusicalAnchorTests.swift`

- [ ] **Step 1: Write the failing test**

`Packages/Domain/Tests/DomainTests/MusicalAnchorTests.swift`:

```swift
import Foundation
import Testing
@testable import Domain

@Suite struct UnitRectTests {
    @Test func clampsValuesIntoUnitInterval() {
        let r = UnitRect(x: -0.1, y: 1.2, width: 0.5, height: 0.5)
        #expect(r.x == 0)
        #expect(r.y == 1)
        #expect(r.width == 0.5)
        #expect(r.height == 0.5)
    }

    @Test func clampsWidthAndHeightSoTheyFit() {
        let r = UnitRect(x: 0.8, y: 0.8, width: 0.5, height: 0.5)
        #expect(r.x == 0.8)
        #expect(r.y == 0.8)
        #expect(r.width == 0.2)
        #expect(r.height == 0.2)
    }

    @Test func roundTripsThroughCodable() throws {
        let r = UnitRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        let data = try JSONEncoder().encode(r)
        let decoded = try JSONDecoder().decode(UnitRect.self, from: data)
        #expect(decoded == r)
    }
}

@Suite struct MusicalAnchorTests {
    @Test func roundTripsThroughCodable() throws {
        let a = MusicalAnchor(systemIndex: 7, normalizedFrame: UnitRect(x: 0, y: 0, width: 1, height: 1))
        let data = try JSONEncoder().encode(a)
        let decoded = try JSONDecoder().decode(MusicalAnchor.self, from: data)
        #expect(decoded == a)
    }

    @Test func systemIndexCannotBeNegative() {
        let a = MusicalAnchor(systemIndex: -1, normalizedFrame: .zero)
        #expect(a.systemIndex == 0)
    }
}
```

- [ ] **Step 2: Run the failing test**

```bash
cd Packages/Domain && swift test 2>&1 | tail -10
```

Expected: `cannot find type 'UnitRect'` / `cannot find type 'MusicalAnchor'` errors.

- [ ] **Step 3: Write the implementation**

`Packages/Domain/Sources/Domain/MusicalAnchor.swift`:

```swift
import Foundation

/// A rectangle in normalized coordinates. All fields are clamped to [0, 1] and
/// (x + width) / (y + height) are clamped not to exceed 1.
public struct UnitRect: Hashable, Sendable, Codable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        let clampedX = min(max(x, 0), 1)
        let clampedY = min(max(y, 0), 1)
        let clampedW = min(max(width, 0), 1 - clampedX)
        let clampedH = min(max(height, 0), 1 - clampedY)
        self.x = clampedX
        self.y = clampedY
        self.width = clampedW
        self.height = clampedH
    }

    public static let zero = UnitRect(x: 0, y: 0, width: 0, height: 0)
}

/// Anchors annotation content (a stroke or text box) to a position inside the
/// engraved score's layout. Coordinates are relative to the system at
/// `systemIndex`, so anchors survive content reflow as long as the system
/// itself still exists.
public struct MusicalAnchor: Hashable, Sendable, Codable {
    public let systemIndex: Int
    public let normalizedFrame: UnitRect

    public init(systemIndex: Int, normalizedFrame: UnitRect) {
        self.systemIndex = max(0, systemIndex)
        self.normalizedFrame = normalizedFrame
    }
}
```

- [ ] **Step 4: Run the test, verify pass**

```bash
swift test 2>&1 | tail -10
```

Expected: `UnitRectTests` 3 passed and `MusicalAnchorTests` 2 passed.

- [ ] **Step 5: Commit**

```bash
cd ../..
git add Packages/Domain/Sources/Domain/MusicalAnchor.swift Packages/Domain/Tests/DomainTests/MusicalAnchorTests.swift
git commit -m "feat(domain): add MusicalAnchor and UnitRect for annotation positioning

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: `DomainError`

**Files:**
- Create: `Packages/Domain/Sources/Domain/DomainError.swift`
- Create: `Packages/Domain/Tests/DomainTests/DomainErrorTests.swift`

- [ ] **Step 1: Write the failing test**

`Packages/Domain/Tests/DomainTests/DomainErrorTests.swift`:

```swift
import Foundation
import Testing
@testable import Domain

@Suite struct DomainErrorTests {
    @Test func conformsToError() {
        let error: any Error = DomainError.scoreFileNotFound(name: "x.mscz")
        let _ = error
    }

    @Test func equatableCases() {
        #expect(DomainError.scoreFileNotFound(name: "a") == DomainError.scoreFileNotFound(name: "a"))
        #expect(DomainError.scoreFileNotFound(name: "a") != DomainError.scoreFileNotFound(name: "b"))
        let key = SoundfontPatchKey(bank: 0, program: 4)
        #expect(DomainError.soundfontDownloadFailed(key) == DomainError.soundfontDownloadFailed(key))
    }

    @Test func providesLocalizedDescription() {
        let error = DomainError.unsupportedFormat("rtf")
        #expect(!error.localizedDescription.isEmpty)
    }
}
```

- [ ] **Step 2: Run the failing test**

```bash
cd Packages/Domain && swift test 2>&1 | tail -10
```

Expected: `cannot find 'DomainError'` errors.

- [ ] **Step 3: Write the implementation**

`Packages/Domain/Sources/Domain/DomainError.swift`:

```swift
import Foundation

/// Shared error type for the Domain layer. Infrastructure adapters either throw
/// these directly or wrap their own errors as a `DomainError` at the Domain
/// boundary. Equatable so tests can compare expected errors directly.
public enum DomainError: Error, Sendable, Equatable {
    case scoreFileNotFound(name: String)
    case unsupportedFormat(String)
    case scoreParseFailed(reason: String)
    case scoreWriteFailed(reason: String)
    case soundfontDownloadFailed(SoundfontPatchKey)
    case persistenceFailed(reason: String)
    case syncFailed(reason: String)
    case audioEngineFailed(reason: String)
}

extension DomainError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .scoreFileNotFound(let name):
            "Score file not found: \(name)"
        case .unsupportedFormat(let ext):
            "Unsupported file format: \(ext)"
        case .scoreParseFailed(let reason):
            "Could not parse score file: \(reason)"
        case .scoreWriteFailed(let reason):
            "Could not write score file: \(reason)"
        case .soundfontDownloadFailed(let key):
            "Failed to download SoundFont (bank \(key.bank), program \(key.program))"
        case .persistenceFailed(let reason):
            "Library save failed: \(reason)"
        case .syncFailed(let reason):
            "Sync failed: \(reason)"
        case .audioEngineFailed(let reason):
            "Audio engine error: \(reason)"
        }
    }
}
```

- [ ] **Step 4: Run the test, verify pass**

```bash
swift test 2>&1 | tail -10
```

Expected: `DomainErrorTests` 3 passed.

- [ ] **Step 5: Commit**

```bash
cd ../..
git add Packages/Domain/Sources/Domain/DomainError.swift Packages/Domain/Tests/DomainTests/DomainErrorTests.swift
git commit -m "feat(domain): add DomainError shared error type

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: `Tag` model

**Files:**
- Create: `Packages/Domain/Sources/Domain/Models/Tag.swift`
- Create: `Packages/Domain/Tests/DomainTests/Models/TagTests.swift`

- [ ] **Step 1: Write the failing test**

`Packages/Domain/Tests/DomainTests/Models/TagTests.swift`:

```swift
import Foundation
import Testing
@testable import Domain

@Suite struct TagTests {
    @Test func roundTripsThroughCodable() throws {
        let tag = Tag(id: TagID(), name: "classical", colorHex: "#3366FF")
        let data = try JSONEncoder().encode(tag)
        let decoded = try JSONDecoder().decode(Tag.self, from: data)
        #expect(decoded == tag)
    }

    @Test func equalityIsIdentityBased() {
        let id = TagID()
        let a = Tag(id: id, name: "x", colorHex: "#000000")
        let b = Tag(id: id, name: "x", colorHex: "#000000")
        let c = Tag(id: TagID(), name: "x", colorHex: "#000000")
        #expect(a == b)
        #expect(a != c)
    }

    @Test func conformsToIdentifiable() {
        let id = TagID()
        let tag = Tag(id: id, name: "x", colorHex: "#000000")
        #expect(tag.id == id)
    }
}
```

- [ ] **Step 2: Run the failing test**

```bash
cd Packages/Domain && swift test 2>&1 | tail -10
```

Expected: `cannot find type 'Tag'`.

- [ ] **Step 3: Write the implementation**

`Packages/Domain/Sources/Domain/Models/Tag.swift`:

```swift
import Foundation

/// A user-defined tag used to group score items. The color is stored as
/// `#RRGGBB` or `#RRGGBBAA` so Domain stays free of UI-framework types.
public struct Tag: Hashable, Sendable, Codable, Identifiable {
    public let id: TagID
    public var name: String
    public var colorHex: String

    public init(id: TagID = TagID(), name: String, colorHex: String) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
    }
}
```

- [ ] **Step 4: Run the test, verify pass**

```bash
swift test 2>&1 | tail -10
```

Expected: `TagTests` 3 passed.

- [ ] **Step 5: Commit**

```bash
cd ../..
git add Packages/Domain/Sources/Domain/Models/Tag.swift Packages/Domain/Tests/DomainTests/Models/TagTests.swift
git commit -m "feat(domain): add Tag model

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: `ScoreItem` model

**Files:**
- Create: `Packages/Domain/Sources/Domain/Models/ScoreItem.swift`
- Create: `Packages/Domain/Tests/DomainTests/Models/ScoreItemTests.swift`

- [ ] **Step 1: Write the failing test**

`Packages/Domain/Tests/DomainTests/Models/ScoreItemTests.swift`:

```swift
import Foundation
import Testing
@testable import Domain

@Suite struct ScoreItemTests {
    private func sample() -> ScoreItem {
        ScoreItem(
            id: ScoreItemID(),
            title: "Prelude in C",
            composer: "J. S. Bach",
            instrumentationSummary: "Piano",
            format: .mscz,
            localFileName: "prelude.mscz",
            sizeBytes: 8_192,
            lengthBeats: 56,
            defaultTempoBpm: 72,
            primaryKey: "C major",
            addedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastOpenedAt: nil,
            tagIDs: [],
            isFavorite: false
        )
    }

    @Test func roundTripsThroughCodable() throws {
        let item = sample()
        let data = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(ScoreItem.self, from: data)
        #expect(decoded == item)
    }

    @Test func canHoldOptionalMetadata() {
        let item = ScoreItem(
            id: ScoreItemID(),
            title: "Untitled",
            composer: nil,
            instrumentationSummary: nil,
            format: .midi,
            localFileName: "x.mid",
            sizeBytes: 0,
            lengthBeats: 0,
            defaultTempoBpm: 120,
            primaryKey: nil,
            addedAt: Date(),
            lastOpenedAt: nil,
            tagIDs: [],
            isFavorite: false
        )
        #expect(item.composer == nil)
        #expect(item.primaryKey == nil)
    }

    @Test func conformsToIdentifiable() {
        let item = sample()
        let _: ScoreItemID = item.id
    }

    @Test func tagIDsAreOrderIndependent() {
        let t1 = TagID()
        let t2 = TagID()
        let a = sample().with(tagIDs: [t1, t2])
        let b = sample().with(tagIDs: [t2, t1])
        // Same id (since `with` keeps id), same tag set → equal.
        #expect(a == b)
    }
}

private extension ScoreItem {
    func with(tagIDs: Set<TagID>) -> ScoreItem {
        ScoreItem(
            id: id,
            title: title,
            composer: composer,
            instrumentationSummary: instrumentationSummary,
            format: format,
            localFileName: localFileName,
            sizeBytes: sizeBytes,
            lengthBeats: lengthBeats,
            defaultTempoBpm: defaultTempoBpm,
            primaryKey: primaryKey,
            addedAt: addedAt,
            lastOpenedAt: lastOpenedAt,
            tagIDs: tagIDs,
            isFavorite: isFavorite
        )
    }
}
```

- [ ] **Step 2: Run the failing test**

```bash
cd Packages/Domain && swift test 2>&1 | tail -10
```

Expected: `cannot find type 'ScoreItem'`.

- [ ] **Step 3: Write the implementation**

`Packages/Domain/Sources/Domain/Models/ScoreItem.swift`:

```swift
import Foundation

/// A persisted entry in Folino's library. The actual score bytes live on disk
/// at `AppPaths.scoresDirectory/localFileName` (the resolution to absolute URL
/// happens in Infrastructure, not Domain).
public struct ScoreItem: Hashable, Sendable, Codable, Identifiable {
    public let id: ScoreItemID
    public var title: String
    public var composer: String?
    public var instrumentationSummary: String?
    public var format: ScoreFormat
    /// Filename relative to the scores directory. Convention: `<id>.<canonical-extension>`.
    public var localFileName: String
    public var sizeBytes: Int64
    public var lengthBeats: Int
    public var defaultTempoBpm: Int
    public var primaryKey: String?
    public let addedAt: Date
    public var lastOpenedAt: Date?
    public var tagIDs: Set<TagID>
    public var isFavorite: Bool

    public init(
        id: ScoreItemID = ScoreItemID(),
        title: String,
        composer: String?,
        instrumentationSummary: String?,
        format: ScoreFormat,
        localFileName: String,
        sizeBytes: Int64,
        lengthBeats: Int,
        defaultTempoBpm: Int,
        primaryKey: String?,
        addedAt: Date,
        lastOpenedAt: Date?,
        tagIDs: Set<TagID>,
        isFavorite: Bool
    ) {
        self.id = id
        self.title = title
        self.composer = composer
        self.instrumentationSummary = instrumentationSummary
        self.format = format
        self.localFileName = localFileName
        self.sizeBytes = sizeBytes
        self.lengthBeats = lengthBeats
        self.defaultTempoBpm = defaultTempoBpm
        self.primaryKey = primaryKey
        self.addedAt = addedAt
        self.lastOpenedAt = lastOpenedAt
        self.tagIDs = tagIDs
        self.isFavorite = isFavorite
    }
}
```

- [ ] **Step 4: Run the test, verify pass**

```bash
swift test 2>&1 | tail -10
```

Expected: `ScoreItemTests` 4 passed.

- [ ] **Step 5: Commit**

```bash
cd ../..
git add Packages/Domain/Sources/Domain/Models/ScoreItem.swift Packages/Domain/Tests/DomainTests/Models/ScoreItemTests.swift
git commit -m "feat(domain): add ScoreItem model

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 7: `Playlist` model

**Files:**
- Create: `Packages/Domain/Sources/Domain/Models/Playlist.swift`
- Create: `Packages/Domain/Tests/DomainTests/Models/PlaylistTests.swift`

- [ ] **Step 1: Write the failing test**

`Packages/Domain/Tests/DomainTests/Models/PlaylistTests.swift`:

```swift
import Foundation
import Testing
@testable import Domain

@Suite struct PlaylistTests {
    @Test func preservesScoreOrder() {
        let s1 = ScoreItemID()
        let s2 = ScoreItemID()
        let s3 = ScoreItemID()
        let p = Playlist(
            id: PlaylistID(),
            name: "Recital 1",
            orderedScoreItemIDs: [s1, s2, s3],
            createdAt: Date()
        )
        #expect(p.orderedScoreItemIDs == [s1, s2, s3])
    }

    @Test func isOrderSensitiveInEquality() {
        let s1 = ScoreItemID()
        let s2 = ScoreItemID()
        let id = PlaylistID()
        let date = Date(timeIntervalSince1970: 0)
        let a = Playlist(id: id, name: "x", orderedScoreItemIDs: [s1, s2], createdAt: date)
        let b = Playlist(id: id, name: "x", orderedScoreItemIDs: [s2, s1], createdAt: date)
        #expect(a != b)
    }

    @Test func roundTripsThroughCodable() throws {
        let p = Playlist(
            id: PlaylistID(),
            name: "Recital 1",
            orderedScoreItemIDs: [ScoreItemID(), ScoreItemID()],
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let data = try JSONEncoder().encode(p)
        let decoded = try JSONDecoder().decode(Playlist.self, from: data)
        #expect(decoded == p)
    }
}
```

- [ ] **Step 2: Run the failing test**

```bash
cd Packages/Domain && swift test 2>&1 | tail -10
```

Expected: `cannot find type 'Playlist'`.

- [ ] **Step 3: Write the implementation**

`Packages/Domain/Sources/Domain/Models/Playlist.swift`:

```swift
import Foundation

/// A manually ordered sequence of score items. v1 only supports manual playlists;
/// smart playlists arrive in v1.x.
public struct Playlist: Hashable, Sendable, Codable, Identifiable {
    public let id: PlaylistID
    public var name: String
    public var orderedScoreItemIDs: [ScoreItemID]
    public let createdAt: Date

    public init(
        id: PlaylistID = PlaylistID(),
        name: String,
        orderedScoreItemIDs: [ScoreItemID],
        createdAt: Date
    ) {
        self.id = id
        self.name = name
        self.orderedScoreItemIDs = orderedScoreItemIDs
        self.createdAt = createdAt
    }
}
```

- [ ] **Step 4: Run the test, verify pass**

```bash
swift test 2>&1 | tail -10
```

Expected: `PlaylistTests` 3 passed.

- [ ] **Step 5: Commit**

```bash
cd ../..
git add Packages/Domain/Sources/Domain/Models/Playlist.swift Packages/Domain/Tests/DomainTests/Models/PlaylistTests.swift
git commit -m "feat(domain): add Playlist model

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 8: `AnnotationLayer` + `DrawingAnchor` + `TextBoxAnchor`

**Files:**
- Create: `Packages/Domain/Sources/Domain/Models/AnnotationLayer.swift`
- Create: `Packages/Domain/Tests/DomainTests/Models/AnnotationLayerTests.swift`

- [ ] **Step 1: Write the failing test**

`Packages/Domain/Tests/DomainTests/Models/AnnotationLayerTests.swift`:

```swift
import Foundation
import Testing
@testable import Domain

@Suite struct AnnotationLayerTests {
    private func anchor(system: Int = 0) -> MusicalAnchor {
        MusicalAnchor(systemIndex: system, normalizedFrame: UnitRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2))
    }

    @Test func emptyLayerHasNoEntries() {
        let layer = AnnotationLayer(
            id: AnnotationLayerID(),
            scoreItemID: ScoreItemID(),
            drawings: [],
            textBoxes: [],
            updatedAt: Date()
        )
        #expect(layer.drawings.isEmpty)
        #expect(layer.textBoxes.isEmpty)
    }

    @Test func roundTripsThroughCodable() throws {
        let layer = AnnotationLayer(
            id: AnnotationLayerID(),
            scoreItemID: ScoreItemID(),
            drawings: [
                DrawingAnchor(id: AnnotationID(), anchor: anchor(system: 0), encodedDrawing: Data([0xDE, 0xAD])),
                DrawingAnchor(id: AnnotationID(), anchor: anchor(system: 3), encodedDrawing: Data([0xBE, 0xEF])),
            ],
            textBoxes: [
                TextBoxAnchor(id: AnnotationID(), anchor: anchor(system: 1), text: "fingering"),
            ],
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let data = try JSONEncoder().encode(layer)
        let decoded = try JSONDecoder().decode(AnnotationLayer.self, from: data)
        #expect(decoded == layer)
    }

    @Test func drawingAnchorIsIdentifiable() {
        let id = AnnotationID()
        let d = DrawingAnchor(id: id, anchor: anchor(), encodedDrawing: Data())
        #expect(d.id == id)
    }

    @Test func textBoxAnchorIsIdentifiable() {
        let id = AnnotationID()
        let t = TextBoxAnchor(id: id, anchor: anchor(), text: "x")
        #expect(t.id == id)
    }
}
```

- [ ] **Step 2: Run the failing test**

```bash
cd Packages/Domain && swift test 2>&1 | tail -10
```

Expected: `cannot find type 'AnnotationLayer'` / `'DrawingAnchor'` / `'TextBoxAnchor'`.

- [ ] **Step 3: Write the implementation**

`Packages/Domain/Sources/Domain/Models/AnnotationLayer.swift`:

```swift
import Foundation

/// A free-hand stroke (or stroke group) anchored to a position inside a system.
/// `encodedDrawing` is opaque to Domain — the Reader feature decodes it as a
/// `PKDrawing`. Domain does not depend on PencilKit.
public struct DrawingAnchor: Hashable, Sendable, Codable, Identifiable {
    public let id: AnnotationID
    public var anchor: MusicalAnchor
    public var encodedDrawing: Data

    public init(id: AnnotationID = AnnotationID(), anchor: MusicalAnchor, encodedDrawing: Data) {
        self.id = id
        self.anchor = anchor
        self.encodedDrawing = encodedDrawing
    }
}

/// A user-typed text box anchored to a position inside a system. Plain text
/// only — no rich formatting in v1.
public struct TextBoxAnchor: Hashable, Sendable, Codable, Identifiable {
    public let id: AnnotationID
    public var anchor: MusicalAnchor
    public var text: String

    public init(id: AnnotationID = AnnotationID(), anchor: MusicalAnchor, text: String) {
        self.id = id
        self.anchor = anchor
        self.text = text
    }
}

/// All annotations for a single score. There is at most one `AnnotationLayer`
/// per `ScoreItem`.
public struct AnnotationLayer: Hashable, Sendable, Codable, Identifiable {
    public let id: AnnotationLayerID
    public let scoreItemID: ScoreItemID
    public var drawings: [DrawingAnchor]
    public var textBoxes: [TextBoxAnchor]
    public var updatedAt: Date

    public init(
        id: AnnotationLayerID = AnnotationLayerID(),
        scoreItemID: ScoreItemID,
        drawings: [DrawingAnchor],
        textBoxes: [TextBoxAnchor],
        updatedAt: Date
    ) {
        self.id = id
        self.scoreItemID = scoreItemID
        self.drawings = drawings
        self.textBoxes = textBoxes
        self.updatedAt = updatedAt
    }
}
```

- [ ] **Step 4: Run the test, verify pass**

```bash
swift test 2>&1 | tail -10
```

Expected: `AnnotationLayerTests` 4 passed.

- [ ] **Step 5: Commit**

```bash
cd ../..
git add Packages/Domain/Sources/Domain/Models/AnnotationLayer.swift Packages/Domain/Tests/DomainTests/Models/AnnotationLayerTests.swift
git commit -m "feat(domain): add AnnotationLayer with drawing and text-box anchors

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 9: `PlaybackPreferences` + `StaffMixerState` + `ABRepeatRange` + `ChordPath`

**Files:**
- Create: `Packages/Domain/Sources/Domain/Models/PlaybackPreferences.swift`
- Create: `Packages/Domain/Tests/DomainTests/Models/PlaybackPreferencesTests.swift`

- [ ] **Step 1: Write the failing test**

`Packages/Domain/Tests/DomainTests/Models/PlaybackPreferencesTests.swift`:

```swift
import Foundation
import Testing
@testable import Domain

@Suite struct ChordPathTests {
    @Test func equatable() {
        let a = ChordPath(systemIndex: 0, measureIndex: 1, voiceIndex: 0, chordIndex: 2)
        let b = ChordPath(systemIndex: 0, measureIndex: 1, voiceIndex: 0, chordIndex: 2)
        let c = ChordPath(systemIndex: 0, measureIndex: 1, voiceIndex: 0, chordIndex: 3)
        #expect(a == b)
        #expect(a != c)
    }

    @Test func roundTripsThroughCodable() throws {
        let p = ChordPath(systemIndex: 1, measureIndex: 2, voiceIndex: 3, chordIndex: 4)
        let data = try JSONEncoder().encode(p)
        let decoded = try JSONDecoder().decode(ChordPath.self, from: data)
        #expect(decoded == p)
    }
}

@Suite struct StaffMixerStateTests {
    @Test func volumeIsClampedToUnitInterval() {
        let s = StaffMixerState(staffIndex: 0, volume: 1.5, isMuted: false, isSolo: false, gmBank: 0, gmProgram: 0)
        #expect(s.volume == 1)
        let s2 = StaffMixerState(staffIndex: 0, volume: -0.1, isMuted: false, isSolo: false, gmBank: 0, gmProgram: 0)
        #expect(s2.volume == 0)
    }

    @Test func gmProgramIsClampedTo0Through127() {
        let s = StaffMixerState(staffIndex: 0, volume: 1, isMuted: false, isSolo: false, gmBank: 0, gmProgram: 200)
        #expect(s.gmProgram == 127)
        let s2 = StaffMixerState(staffIndex: 0, volume: 1, isMuted: false, isSolo: false, gmBank: 0, gmProgram: -1)
        #expect(s2.gmProgram == 0)
    }
}

@Suite struct ABRepeatRangeTests {
    @Test func rangeKeepsBothEndpoints() {
        let start = ChordPath(systemIndex: 0, measureIndex: 0, voiceIndex: 0, chordIndex: 0)
        let end = ChordPath(systemIndex: 1, measureIndex: 4, voiceIndex: 0, chordIndex: 2)
        let r = ABRepeatRange(start: start, end: end)
        #expect(r.start == start)
        #expect(r.end == end)
    }
}

@Suite struct PlaybackPreferencesTests {
    @Test func tempoMultiplierIsClampedToHalfThroughTwo() {
        let p = PlaybackPreferences(
            id: PlaybackPreferencesID(),
            scoreItemID: ScoreItemID(),
            perStaff: [],
            tempoMultiplier: 5.0,
            abRepeat: nil
        )
        #expect(p.tempoMultiplier == 2.0)
        let p2 = PlaybackPreferences(
            id: PlaybackPreferencesID(),
            scoreItemID: ScoreItemID(),
            perStaff: [],
            tempoMultiplier: 0.1,
            abRepeat: nil
        )
        #expect(p2.tempoMultiplier == 0.5)
    }

    @Test func roundTripsThroughCodable() throws {
        let mixer = StaffMixerState(staffIndex: 0, volume: 0.8, isMuted: false, isSolo: true, gmBank: 0, gmProgram: 4)
        let p = PlaybackPreferences(
            id: PlaybackPreferencesID(),
            scoreItemID: ScoreItemID(),
            perStaff: [mixer],
            tempoMultiplier: 1.0,
            abRepeat: ABRepeatRange(
                start: ChordPath(systemIndex: 0, measureIndex: 0, voiceIndex: 0, chordIndex: 0),
                end: ChordPath(systemIndex: 0, measureIndex: 4, voiceIndex: 0, chordIndex: 0)
            )
        )
        let data = try JSONEncoder().encode(p)
        let decoded = try JSONDecoder().decode(PlaybackPreferences.self, from: data)
        #expect(decoded == p)
    }
}
```

- [ ] **Step 2: Run the failing test**

```bash
cd Packages/Domain && swift test 2>&1 | tail -10
```

Expected: `cannot find type 'ChordPath'` / `'StaffMixerState'` / `'ABRepeatRange'` / `'PlaybackPreferences'`.

- [ ] **Step 3: Write the implementation**

`Packages/Domain/Sources/Domain/Models/PlaybackPreferences.swift`:

```swift
import Foundation

/// A coordinate that uniquely identifies a chord inside an engraved score's
/// layout. Used as the cursor position and as the endpoints of A–B repeat
/// ranges. The exact mapping to `SheetMusicLayout` cursor types is the
/// Infrastructure adapter's responsibility — Domain only stores integer
/// indices.
public struct ChordPath: Hashable, Sendable, Codable {
    public let systemIndex: Int
    public let measureIndex: Int
    public let voiceIndex: Int
    public let chordIndex: Int

    public init(systemIndex: Int, measureIndex: Int, voiceIndex: Int, chordIndex: Int) {
        self.systemIndex = systemIndex
        self.measureIndex = measureIndex
        self.voiceIndex = voiceIndex
        self.chordIndex = chordIndex
    }
}

/// Mixer settings for one staff in the engraved score. `gmBank` follows the
/// MIDI convention (0 = melodic, 128 = drum); `gmProgram` is the General MIDI
/// program number (0…127).
public struct StaffMixerState: Hashable, Sendable, Codable {
    public let staffIndex: Int
    public var volume: Double
    public var isMuted: Bool
    public var isSolo: Bool
    public var gmBank: Int
    public var gmProgram: Int

    public init(staffIndex: Int, volume: Double, isMuted: Bool, isSolo: Bool, gmBank: Int, gmProgram: Int) {
        self.staffIndex = staffIndex
        self.volume = min(max(volume, 0), 1)
        self.isMuted = isMuted
        self.isSolo = isSolo
        self.gmBank = max(0, gmBank)
        self.gmProgram = min(max(gmProgram, 0), 127)
    }
}

/// A loop range selected on the score. Both endpoints are inclusive.
public struct ABRepeatRange: Hashable, Sendable, Codable {
    public let start: ChordPath
    public let end: ChordPath

    public init(start: ChordPath, end: ChordPath) {
        self.start = start
        self.end = end
    }
}

/// Per-score playback preferences: mixer state, tempo multiplier, and any
/// active A–B loop. Persisted alongside the score item.
public struct PlaybackPreferences: Hashable, Sendable, Codable, Identifiable {
    public let id: PlaybackPreferencesID
    public let scoreItemID: ScoreItemID
    public var perStaff: [StaffMixerState]
    public var tempoMultiplier: Double
    public var abRepeat: ABRepeatRange?

    public init(
        id: PlaybackPreferencesID = PlaybackPreferencesID(),
        scoreItemID: ScoreItemID,
        perStaff: [StaffMixerState],
        tempoMultiplier: Double,
        abRepeat: ABRepeatRange?
    ) {
        self.id = id
        self.scoreItemID = scoreItemID
        self.perStaff = perStaff
        self.tempoMultiplier = min(max(tempoMultiplier, 0.5), 2.0)
        self.abRepeat = abRepeat
    }
}
```

- [ ] **Step 4: Run the test, verify pass**

```bash
swift test 2>&1 | tail -10
```

Expected: 8 new tests passed (ChordPath 2 + StaffMixerState 2 + ABRepeatRange 1 + PlaybackPreferences 2 + 1 from earlier ABRepeatRange test = wait, let me recount: 2 + 2 + 1 + 2 = 7. Verify the count fits).

- [ ] **Step 5: Commit**

```bash
cd ../..
git add Packages/Domain/Sources/Domain/Models/PlaybackPreferences.swift Packages/Domain/Tests/DomainTests/Models/PlaybackPreferencesTests.swift
git commit -m "feat(domain): add PlaybackPreferences with mixer, tempo, A-B repeat

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 10: `SoundfontPatch` model

**Files:**
- Create: `Packages/Domain/Sources/Domain/Models/SoundfontPatch.swift`
- Create: `Packages/Domain/Tests/DomainTests/Models/SoundfontPatchTests.swift`

- [ ] **Step 1: Write the failing test**

`Packages/Domain/Tests/DomainTests/Models/SoundfontPatchTests.swift`:

```swift
import Foundation
import Testing
@testable import Domain

@Suite struct SoundfontPatchTests {
    @Test func identityIsBankAndProgram() {
        let a = SoundfontPatch(
            bank: 0, program: 4,
            localFileName: "000_004.sf2",
            sizeBytes: 1_600_000,
            downloadedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastUsedAt: Date(timeIntervalSince1970: 1_700_001_000)
        )
        #expect(a.id == SoundfontPatchKey(bank: 0, program: 4))
    }

    @Test func roundTripsThroughCodable() throws {
        let p = SoundfontPatch(
            bank: 128, program: 0,
            localFileName: "128_000_lite.sf2",
            sizeBytes: 1_800_000,
            downloadedAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastUsedAt: Date(timeIntervalSince1970: 1_700_001_000)
        )
        let data = try JSONEncoder().encode(p)
        let decoded = try JSONDecoder().decode(SoundfontPatch.self, from: data)
        #expect(decoded == p)
    }

    @Test func bundledFlagDefaultsFalse() {
        let p = SoundfontPatch(
            bank: 0, program: 4,
            localFileName: "x.sf2", sizeBytes: 0,
            downloadedAt: Date(), lastUsedAt: Date()
        )
        #expect(p.isBundled == false)
    }

    @Test func bundledFlagPropagates() {
        let p = SoundfontPatch(
            bank: 0, program: 4,
            localFileName: "x.sf2", sizeBytes: 0,
            downloadedAt: Date(), lastUsedAt: Date(),
            isBundled: true
        )
        #expect(p.isBundled == true)
    }
}
```

- [ ] **Step 2: Run the failing test**

```bash
cd Packages/Domain && swift test 2>&1 | tail -10
```

Expected: `cannot find type 'SoundfontPatch'`.

- [ ] **Step 3: Write the implementation**

`Packages/Domain/Sources/Domain/Models/SoundfontPatch.swift`:

```swift
import Foundation

/// A cache record describing one (bank, program) SoundFont 2 patch on disk.
/// Bundled patches and downloaded patches both use this record; the
/// `isBundled` flag distinguishes them so the cache management UI can prevent
/// deletion of bundled patches.
public struct SoundfontPatch: Hashable, Sendable, Codable, Identifiable {
    public var id: SoundfontPatchKey { SoundfontPatchKey(bank: bank, program: program) }

    public let bank: Int
    public let program: Int
    public var localFileName: String
    public var sizeBytes: Int64
    public let downloadedAt: Date
    public var lastUsedAt: Date
    public var isBundled: Bool

    public init(
        bank: Int,
        program: Int,
        localFileName: String,
        sizeBytes: Int64,
        downloadedAt: Date,
        lastUsedAt: Date,
        isBundled: Bool = false
    ) {
        self.bank = bank
        self.program = program
        self.localFileName = localFileName
        self.sizeBytes = sizeBytes
        self.downloadedAt = downloadedAt
        self.lastUsedAt = lastUsedAt
        self.isBundled = isBundled
    }
}
```

- [ ] **Step 4: Run the test, verify pass**

```bash
swift test 2>&1 | tail -10
```

Expected: `SoundfontPatchTests` 4 passed.

- [ ] **Step 5: Commit**

```bash
cd ../..
git add Packages/Domain/Sources/Domain/Models/SoundfontPatch.swift Packages/Domain/Tests/DomainTests/Models/SoundfontPatchTests.swift
git commit -m "feat(domain): add SoundfontPatch cache record

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 11: Storage protocols (`ScoreLibraryRepository`, `AnnotationStore`)

**Files:**
- Create: `Packages/Domain/Sources/Domain/Protocols/ScoreLibraryRepository.swift`
- Create: `Packages/Domain/Sources/Domain/Protocols/AnnotationStore.swift`
- Create: `Packages/Domain/Tests/DomainTests/Protocols/StorageProtocolsTests.swift`

- [ ] **Step 1: Write the failing test**

`Packages/Domain/Tests/DomainTests/Protocols/StorageProtocolsTests.swift`:

```swift
import Foundation
import Testing
@testable import Domain

/// In-memory fake conforming to `ScoreLibraryRepository`. Living inside the
/// test target ensures the protocol's shape compiles for at least one
/// concrete implementor.
private actor FakeScoreLibraryRepository: ScoreLibraryRepository {
    var items: [ScoreItemID: ScoreItem] = [:]
    var tags: [TagID: Tag] = [:]
    var playlists: [PlaylistID: Playlist] = [:]

    func allScoreItems() async throws -> [ScoreItem] { Array(items.values) }
    func scoreItem(id: ScoreItemID) async throws -> ScoreItem? { items[id] }
    func saveScoreItem(_ item: ScoreItem) async throws { items[item.id] = item }
    func deleteScoreItem(id: ScoreItemID) async throws { items.removeValue(forKey: id) }

    func allTags() async throws -> [Tag] { Array(tags.values) }
    func saveTag(_ tag: Tag) async throws { tags[tag.id] = tag }
    func deleteTag(id: TagID) async throws { tags.removeValue(forKey: id) }

    func allPlaylists() async throws -> [Playlist] { Array(playlists.values) }
    func savePlaylist(_ playlist: Playlist) async throws { playlists[playlist.id] = playlist }
    func deletePlaylist(id: PlaylistID) async throws { playlists.removeValue(forKey: id) }
}

private actor FakeAnnotationStore: AnnotationStore {
    var layers: [ScoreItemID: AnnotationLayer] = [:]

    func annotationLayer(forScoreItem id: ScoreItemID) async throws -> AnnotationLayer? {
        layers[id]
    }
    func saveAnnotationLayer(_ layer: AnnotationLayer) async throws {
        layers[layer.scoreItemID] = layer
    }
    func deleteAnnotationLayer(forScoreItem id: ScoreItemID) async throws {
        layers.removeValue(forKey: id)
    }
}

@Suite struct StorageProtocolsTests {
    @Test func libraryRepositoryRoundTripsItems() async throws {
        let repo: any ScoreLibraryRepository = FakeScoreLibraryRepository()
        let item = ScoreItem(
            title: "x", composer: nil, instrumentationSummary: nil,
            format: .midi, localFileName: "x.mid", sizeBytes: 0,
            lengthBeats: 0, defaultTempoBpm: 120, primaryKey: nil,
            addedAt: Date(), lastOpenedAt: nil, tagIDs: [], isFavorite: false
        )
        try await repo.saveScoreItem(item)
        let fetched = try await repo.scoreItem(id: item.id)
        #expect(fetched == item)
        try await repo.deleteScoreItem(id: item.id)
        let removed = try await repo.scoreItem(id: item.id)
        #expect(removed == nil)
    }

    @Test func annotationStoreRoundTripsLayers() async throws {
        let store: any AnnotationStore = FakeAnnotationStore()
        let scoreID = ScoreItemID()
        let layer = AnnotationLayer(
            scoreItemID: scoreID, drawings: [], textBoxes: [],
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try await store.saveAnnotationLayer(layer)
        let fetched = try await store.annotationLayer(forScoreItem: scoreID)
        #expect(fetched == layer)
        try await store.deleteAnnotationLayer(forScoreItem: scoreID)
        let removed = try await store.annotationLayer(forScoreItem: scoreID)
        #expect(removed == nil)
    }
}
```

- [ ] **Step 2: Run the failing test**

```bash
cd Packages/Domain && swift test 2>&1 | tail -10
```

Expected: `cannot find protocol 'ScoreLibraryRepository'` / `cannot find protocol 'AnnotationStore'`.

- [ ] **Step 3: Write the implementations**

`Packages/Domain/Sources/Domain/Protocols/ScoreLibraryRepository.swift`:

```swift
import Foundation

/// Persistence façade for the score library: items, tags, and playlists.
/// Infrastructure provides a SQLite-backed implementation; CloudKit sync
/// observes the same protocol surface so swapping backends is mechanical.
public protocol ScoreLibraryRepository: Sendable {
    func allScoreItems() async throws -> [ScoreItem]
    func scoreItem(id: ScoreItemID) async throws -> ScoreItem?
    func saveScoreItem(_ item: ScoreItem) async throws
    func deleteScoreItem(id: ScoreItemID) async throws

    func allTags() async throws -> [Tag]
    func saveTag(_ tag: Tag) async throws
    func deleteTag(id: TagID) async throws

    func allPlaylists() async throws -> [Playlist]
    func savePlaylist(_ playlist: Playlist) async throws
    func deletePlaylist(id: PlaylistID) async throws
}
```

`Packages/Domain/Sources/Domain/Protocols/AnnotationStore.swift`:

```swift
import Foundation

/// Persistence façade for `AnnotationLayer`s. There is at most one layer per
/// score item; this protocol exposes a CRUD-by-score-id interface.
public protocol AnnotationStore: Sendable {
    func annotationLayer(forScoreItem id: ScoreItemID) async throws -> AnnotationLayer?
    func saveAnnotationLayer(_ layer: AnnotationLayer) async throws
    func deleteAnnotationLayer(forScoreItem id: ScoreItemID) async throws
}
```

- [ ] **Step 4: Run the test, verify pass**

```bash
swift test 2>&1 | tail -10
```

Expected: `StorageProtocolsTests` 2 passed.

- [ ] **Step 5: Commit**

```bash
cd ../..
git add Packages/Domain/Sources/Domain/Protocols/ScoreLibraryRepository.swift \
        Packages/Domain/Sources/Domain/Protocols/AnnotationStore.swift \
        Packages/Domain/Tests/DomainTests/Protocols/StorageProtocolsTests.swift
git commit -m "feat(domain): add ScoreLibraryRepository and AnnotationStore protocols

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 12: Audio protocols (`PlaybackController`, `SoundfontResolver`)

**Files:**
- Create: `Packages/Domain/Sources/Domain/Protocols/PlaybackController.swift`
- Create: `Packages/Domain/Sources/Domain/Protocols/SoundfontResolver.swift`
- Create: `Packages/Domain/Tests/DomainTests/Protocols/AudioProtocolsTests.swift`

- [ ] **Step 1: Write the failing test**

`Packages/Domain/Tests/DomainTests/Protocols/AudioProtocolsTests.swift`:

```swift
import Foundation
import Testing
@testable import Domain

private final class FakePlaybackController: PlaybackController, @unchecked Sendable {
    var loadedScores = 0
    var lastTempo: Double = 1.0
    var lastCursor: ChordPath?
    let cursorContinuation: AsyncStream<ChordPath?>.Continuation
    let cursor: AsyncStream<ChordPath?>

    init() {
        var c: AsyncStream<ChordPath?>.Continuation!
        self.cursor = AsyncStream { c = $0 }
        self.cursorContinuation = c
    }

    func load(score: Score, preferences: PlaybackPreferences) async throws {
        loadedScores += 1
    }
    func play() async throws {}
    func pause() async {}
    func setCursor(to chord: ChordPath) async { lastCursor = chord }
    func setLoopRange(_ range: ABRepeatRange?) async {}
    func setMetronomeEnabled(_ enabled: Bool) async {}
    func setTempoMultiplier(_ value: Double) async { lastTempo = value }
    func setStaffVolume(staff: Int, volume: Double) async {}
    func setStaffMute(staff: Int, isMuted: Bool) async {}
    func setStaffSolo(staff: Int, isSolo: Bool) async {}
    func setStaffInstrument(staff: Int, bank: Int, program: Int) async {}
}

private actor FakeSoundfontResolver: SoundfontResolver {
    var calls: [SoundfontPatchKey] = []
    var cache: [SoundfontPatch] = []

    func resolveSoundfont(bank: Int, program: Int) async throws -> URL {
        calls.append(SoundfontPatchKey(bank: bank, program: program))
        return URL(fileURLWithPath: "/tmp/fake.sf2")
    }
    func cachedPatches() async throws -> [SoundfontPatch] { cache }
    func totalCacheSizeBytes() async throws -> Int64 { cache.reduce(0) { $0 + $1.sizeBytes } }
    func deletePatch(bank: Int, program: Int) async throws {
        cache.removeAll { $0.bank == bank && $0.program == program }
    }
    func clearCache() async throws { cache.removeAll() }
}

@Suite struct AudioProtocolsTests {
    @Test func playbackControllerSetsCursorAndTempo() async throws {
        let p = FakePlaybackController()
        await p.setCursor(to: ChordPath(systemIndex: 1, measureIndex: 2, voiceIndex: 0, chordIndex: 3))
        await p.setTempoMultiplier(0.75)
        #expect(p.lastCursor == ChordPath(systemIndex: 1, measureIndex: 2, voiceIndex: 0, chordIndex: 3))
        #expect(p.lastTempo == 0.75)
    }

    @Test func soundfontResolverRecordsCalls() async throws {
        let r = FakeSoundfontResolver()
        _ = try await r.resolveSoundfont(bank: 0, program: 4)
        _ = try await r.resolveSoundfont(bank: 128, program: 0)
        let calls = await r.calls
        #expect(calls == [SoundfontPatchKey(bank: 0, program: 4), SoundfontPatchKey(bank: 128, program: 0)])
    }
}
```

- [ ] **Step 2: Run the failing test**

```bash
cd Packages/Domain && swift test 2>&1 | tail -10
```

Expected: `cannot find protocol 'PlaybackController'` / `cannot find protocol 'SoundfontResolver'` / `cannot find type 'Score'` (the last appears only briefly — `Score` is re-exported from `SheetMusicCore` via `Domain`).

- [ ] **Step 3: Write the implementations**

`Packages/Domain/Sources/Domain/Protocols/PlaybackController.swift`:

```swift
import Foundation

/// Façade over the SheetMusicAudio engine. Owns the audio session lifetime,
/// the per-staff sampler graph, and the cursor stream that the Reader feature
/// observes for highlight animation.
public protocol PlaybackController: Sendable {
    /// Set up the engine for a score and seed it with the user's saved
    /// preferences. Subsequent setter calls update the live engine state.
    func load(score: Score, preferences: PlaybackPreferences) async throws
    func play() async throws
    func pause() async

    func setCursor(to chord: ChordPath) async
    func setLoopRange(_ range: ABRepeatRange?) async
    func setMetronomeEnabled(_ enabled: Bool) async
    func setTempoMultiplier(_ value: Double) async

    func setStaffVolume(staff: Int, volume: Double) async
    func setStaffMute(staff: Int, isMuted: Bool) async
    func setStaffSolo(staff: Int, isSolo: Bool) async
    func setStaffInstrument(staff: Int, bank: Int, program: Int) async

    /// Cursor positions emitted by the engine while playing. Yields `nil` when
    /// playback stops.
    var cursor: AsyncStream<ChordPath?> { get }
}
```

`Packages/Domain/Sources/Domain/Protocols/SoundfontResolver.swift`:

```swift
import Foundation

/// Provides URLs for SoundFont 2 (`.sf2`) files keyed by (bank, program).
/// Bundled patches resolve to URLs inside the app bundle; downloaded patches
/// resolve to `Caches/Soundfonts/`. The Settings UI uses this protocol's cache
/// management methods to display sizes and delete entries.
public protocol SoundfontResolver: Sendable {
    /// Resolve a (bank, program) to a local `.sf2` file URL, downloading and
    /// caching if necessary.
    func resolveSoundfont(bank: Int, program: Int) async throws -> URL

    /// All patches currently cached on disk. Includes bundled patches with
    /// `isBundled = true`.
    func cachedPatches() async throws -> [SoundfontPatch]

    /// Total disk usage of cached patches that are not bundled.
    func totalCacheSizeBytes() async throws -> Int64

    /// Remove a single cached (non-bundled) patch. No-op if the patch was
    /// bundled or missing.
    func deletePatch(bank: Int, program: Int) async throws

    /// Remove every non-bundled cached patch.
    func clearCache() async throws
}
```

- [ ] **Step 4: Run the test, verify pass**

```bash
swift test 2>&1 | tail -10
```

Expected: `AudioProtocolsTests` 2 passed.

- [ ] **Step 5: Commit**

```bash
cd ../..
git add Packages/Domain/Sources/Domain/Protocols/PlaybackController.swift \
        Packages/Domain/Sources/Domain/Protocols/SoundfontResolver.swift \
        Packages/Domain/Tests/DomainTests/Protocols/AudioProtocolsTests.swift
git commit -m "feat(domain): add PlaybackController and SoundfontResolver protocols

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 13: Sync + File I/O protocols (`CloudSync`, `ScoreFileGateway`)

**Files:**
- Create: `Packages/Domain/Sources/Domain/Protocols/CloudSync.swift`
- Create: `Packages/Domain/Sources/Domain/Protocols/ScoreFileGateway.swift`
- Create: `Packages/Domain/Tests/DomainTests/Protocols/SyncFileProtocolsTests.swift`

- [ ] **Step 1: Write the failing test**

`Packages/Domain/Tests/DomainTests/Protocols/SyncFileProtocolsTests.swift`:

```swift
import Foundation
import Testing
@testable import Domain

private final class FakeCloudSync: CloudSync, @unchecked Sendable {
    let stateContinuation: AsyncStream<CloudSyncState>.Continuation
    let state: AsyncStream<CloudSyncState>
    var startCount = 0
    var stopCount = 0
    var syncNowCount = 0

    init() {
        var c: AsyncStream<CloudSyncState>.Continuation!
        self.state = AsyncStream { c = $0 }
        self.stateContinuation = c
    }

    func start() async { startCount += 1 }
    func stop() async { stopCount += 1 }
    func syncNow() async throws { syncNowCount += 1 }
}

private actor FakeScoreFileGateway: ScoreFileGateway {
    func detectFormat(fileName: String) -> ScoreFormat? {
        ScoreFormat.detect(filename: fileName)
    }

    func loadScore(fileURL: URL) async throws -> (score: Score, summary: ScoreFileSummary) {
        // Cannot construct a real `Score` without SheetMusicCore knowledge; throw to prove
        // the throwing signature compiles.
        throw DomainError.scoreParseFailed(reason: "fake")
    }

    func saveScore(_ score: Score, fileURL: URL, format: ScoreFormat) async throws {
        throw DomainError.scoreWriteFailed(reason: "fake")
    }
}

@Suite struct CloudSyncProtocolTests {
    @Test func recordsLifecycleCalls() async {
        let sync = FakeCloudSync()
        await sync.start()
        await sync.start()
        await sync.stop()
        try? await sync.syncNow()
        #expect(sync.startCount == 2)
        #expect(sync.stopCount == 1)
        #expect(sync.syncNowCount == 1)
    }

    @Test func cloudSyncStateValuesAreDistinct() {
        let cases: [CloudSyncState] = [
            .idle, .syncing, .failed(error: "x"), .unavailable,
        ]
        // Just exercise the enum so the cases are reachable from outside the module.
        #expect(cases.count == 4)
    }
}

@Suite struct ScoreFileGatewayProtocolTests {
    @Test func detectFormatDelegatesToScoreFormat() async {
        let g = FakeScoreFileGateway()
        let result = await g.detectFormat(fileName: "x.mscz")
        #expect(result == .mscz)
    }

    @Test func loadScoreThrowsOnFakeFiles() async {
        let g = FakeScoreFileGateway()
        do {
            _ = try await g.loadScore(fileURL: URL(fileURLWithPath: "/dev/null"))
            Issue.record("expected throw")
        } catch let error as DomainError {
            if case .scoreParseFailed = error {
                // Expected.
            } else {
                Issue.record("unexpected DomainError: \(error)")
            }
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }
}
```

- [ ] **Step 2: Run the failing test**

```bash
cd Packages/Domain && swift test 2>&1 | tail -10
```

Expected: `cannot find protocol 'CloudSync'` / `cannot find type 'CloudSyncState'` / `cannot find protocol 'ScoreFileGateway'` / `cannot find type 'ScoreFileSummary'`.

- [ ] **Step 3: Write the implementations**

`Packages/Domain/Sources/Domain/Protocols/CloudSync.swift`:

```swift
import Foundation

/// Snapshot of the CloudKit sync engine's state, exposed via an
/// `AsyncStream` so UI can drive a status indicator.
public enum CloudSyncState: Sendable, Equatable {
    case idle
    case syncing
    case failed(error: String)
    case unavailable
}

/// Drives CloudKit Private Database sync of `ScoreItem`, `Tag`, `Playlist`,
/// `AnnotationLayer`, and `PlaybackPreferences`. Always-local invariant
/// (`docs/product/feasibility.md` D4) lives in the Infrastructure
/// implementation — this protocol does not expose any toggle for eviction.
public protocol CloudSync: Sendable {
    /// Start the sync engine. Idempotent.
    func start() async
    /// Stop the sync engine.
    func stop() async
    /// Force a sync cycle now (UI "Sync now" affordance).
    func syncNow() async throws
    /// Stream of state transitions.
    var state: AsyncStream<CloudSyncState> { get }
}
```

`Packages/Domain/Sources/Domain/Protocols/ScoreFileGateway.swift`:

```swift
import Foundation

/// Metadata extracted from a score file at load time. Distinct from
/// `ScoreItem` because the gateway runs before the file is added to the
/// library and therefore has no `ScoreItemID` or persistent state yet.
public struct ScoreFileSummary: Hashable, Sendable {
    public var title: String?
    public var composer: String?
    public var instrumentationSummary: String
    public var lengthBeats: Int
    public var defaultTempoBpm: Int
    public var primaryKey: String?

    public init(
        title: String?,
        composer: String?,
        instrumentationSummary: String,
        lengthBeats: Int,
        defaultTempoBpm: Int,
        primaryKey: String?
    ) {
        self.title = title
        self.composer = composer
        self.instrumentationSummary = instrumentationSummary
        self.lengthBeats = lengthBeats
        self.defaultTempoBpm = defaultTempoBpm
        self.primaryKey = primaryKey
    }
}

/// Bridges `swift-sheet-music`'s format I/O modules into Domain. The
/// Infrastructure implementation wraps `SheetMusicMSCX`, `SheetMusicMusicXML`,
/// `SheetMusicMIDI`, and `SheetMusicPDF` behind this single protocol so
/// Features only depend on Domain.
public protocol ScoreFileGateway: Sendable {
    /// Best-effort format detection from filename. Should agree with
    /// `ScoreFormat.detect(filename:)`.
    func detectFormat(fileName: String) -> ScoreFormat?

    /// Parse a score file into the in-memory `Score` plus a transient summary.
    func loadScore(fileURL: URL) async throws -> (score: Score, summary: ScoreFileSummary)

    /// Write a `Score` to disk in the requested format.
    func saveScore(_ score: Score, fileURL: URL, format: ScoreFormat) async throws
}
```

- [ ] **Step 4: Run the test, verify pass**

```bash
swift test 2>&1 | tail -10
```

Expected: `CloudSyncProtocolTests` 2 passed and `ScoreFileGatewayProtocolTests` 2 passed.

- [ ] **Step 5: Commit**

```bash
cd ../..
git add Packages/Domain/Sources/Domain/Protocols/CloudSync.swift \
        Packages/Domain/Sources/Domain/Protocols/ScoreFileGateway.swift \
        Packages/Domain/Tests/DomainTests/Protocols/SyncFileProtocolsTests.swift
git commit -m "feat(domain): add CloudSync and ScoreFileGateway protocols

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 14: Replace `Placeholder.swift` with `DomainExports.swift` and verify whole-project build

**Files:**
- Delete: `Packages/Domain/Sources/Domain/Placeholder.swift`
- Create: `Packages/Domain/Sources/Domain/DomainExports.swift`
- (Existing) `Packages/Domain/Tests/DomainTests/DomainTests.swift` will be renamed to `DomainSmokeTests.swift` and updated to reference the renamed module marker.

- [ ] **Step 1: Rename the test file**

```bash
git mv Packages/Domain/Tests/DomainTests/DomainTests.swift Packages/Domain/Tests/DomainTests/DomainSmokeTests.swift
```

- [ ] **Step 2: Rewrite `DomainSmokeTests.swift`**

`Packages/Domain/Tests/DomainTests/DomainSmokeTests.swift`:

```swift
import Foundation
import Testing
@testable import Domain

@Suite struct DomainSmokeTests {
    @Test func moduleLinks() {
        #expect(DomainModule.isLinked)
    }

    @Test func sheetMusicCoreReexported() {
        // Verifies the @_exported import surfaces SheetMusicCore through Domain.
        let _: Score.Type = Score.self
    }
}
```

(Identical content to before — the rename is the meaningful change.)

- [ ] **Step 3: Replace `Placeholder.swift` with `DomainExports.swift`**

```bash
git rm Packages/Domain/Sources/Domain/Placeholder.swift
```

`Packages/Domain/Sources/Domain/DomainExports.swift`:

```swift
@_exported import SheetMusicCore

/// Module marker. Exists so other layers can verify Domain is linked at
/// runtime, and so test targets can `@testable import Domain` without needing
/// any concrete type. The actual Domain surface is defined in sibling files.
public enum DomainModule {
    public static let isLinked = true
}
```

- [ ] **Step 4: Run the package's tests**

```bash
cd Packages/Domain && swift test 2>&1 | tail -20
```

Expected: all the cumulative tests from Tasks 1–13 plus the two `DomainSmokeTests` pass. Total expected: 2 (smoke) + 5 (Identifiers) + 5 (ScoreFormat) + 5 (UnitRect+MusicalAnchor) + 3 (DomainError) + 3 (Tag) + 4 (ScoreItem) + 3 (Playlist) + 4 (AnnotationLayer) + 7 (PlaybackPreferences group) + 4 (SoundfontPatch) + 2 (Storage) + 2 (Audio) + 4 (Sync+File) = **53 tests**.

If the count differs by ±2, that's fine — the inner test counts depend on how Swift Testing groups suite-level counts. What matters is **0 failures**.

- [ ] **Step 5: Verify the whole-project xcodebuild still succeeds**

```bash
cd ../..
xcodegen generate 2>&1 | tail -5
xcodebuild -project Folino.xcodeproj \
  -scheme Folino \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -skipPackagePluginValidation \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  build 2>&1 | tail -10
```

(Substitute `iPhone 17 Pro Max` for whatever simulator is available; bootstrap T11 used the same.)

Expected: `** BUILD SUCCEEDED **`. The App target links against `Domain` and now sees all the new public types via that import; nothing in the App actually consumes them yet, so the build remains a pure compile-and-link verification.

- [ ] **Step 6: Commit**

```bash
git add Packages/Domain/Sources/Domain/DomainExports.swift \
        Packages/Domain/Sources/Domain/Placeholder.swift \
        Packages/Domain/Tests/DomainTests/DomainSmokeTests.swift \
        Packages/Domain/Tests/DomainTests/DomainTests.swift
git commit -m "refactor(domain): rename Placeholder to DomainExports and rename smoke tests

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

(`git add` of the deleted `Placeholder.swift` and `DomainTests.swift` records the deletes; the rename is captured by git's content-similarity heuristic when staged this way.)

---

## Self-Review Notes (writing-plans skill)

**Spec coverage** — the data model in `docs/product/architecture.md` lists six top-level entities (`ScoreItem`, `AnnotationLayer`, `Playlist`, `Tag`, `PlaybackPreferences`, `SoundfontPatch`) and six adapter protocols (`ScoreLibraryRepository`, `AnnotationStore`, `PlaybackController`, `SoundfontResolver`, `CloudSync`, `ScoreFileGateway`). All twelve appear in this plan. `ScoreContent` from the spec is not persisted (the spec calls it out as a runtime cache), so it is intentionally absent from Domain — Features will hold onto the parsed `Score` directly when a reader is open.

The supporting types `MusicalAnchor`, `UnitRect`, `ChordPath`, `StaffMixerState`, `ABRepeatRange`, `ScoreFormat`, `SoundfontPatchKey`, `DomainError`, and the typed identifier newtypes are derived from the data-model description.

**Naming consistency** — every per-task prefix matches across source, test, and commit message: `ScoreItem` / `ScoreItemID` / `ScoreItemTests`; `AnnotationLayer` / `AnnotationLayerID`; `PlaybackPreferences` / `PlaybackPreferencesID`; etc. Protocol names are nouns describing the role (`ScoreLibraryRepository`, not `ScoreLibraryRepositoryProtocol`).

**Sequencing** — Tasks 1–4 land low-level supporting types (IDs, ScoreFormat, MusicalAnchor, DomainError) so model tasks (5–10) can reference them. Protocol tasks (11–13) come last because they reference both the models and the IDs. Task 14 cleans up `Placeholder.swift` and verifies the whole xcodebuild still goes green.

**Risk callouts** —
- The `Score` type referenced in `PlaybackController.load(score:preferences:)` and `ScoreFileGateway.loadScore(fileURL:)` comes from `SheetMusicCore` via the `@_exported` re-export. If `Score` is private or namespaced inside `SheetMusicCore` in a way that breaks the re-export, those protocols will fail to compile. Bootstrap T7 already verified `Score` is publicly accessible from outside the module, so this should hold — but worth confirming during Task 12.
- The plan keeps `ScoreItem.localFileName` as a relative `String` rather than an absolute `URL` so records survive device-to-device sync. This decision is documented in the comment on the field.
- Codable tests use `JSONEncoder` / `JSONDecoder` round-trips. `Date` is encoded as a Double-since-1970 by default; tests use explicit dates via `Date(timeIntervalSince1970:)` to avoid floating-point comparison surprises.
- The `CloudSync.state` and `PlaybackController.cursor` properties are `AsyncStream<...>` declared as `var` for protocol conformance. Concrete actors and classes can synthesize the stream however they like.

**Done condition recap** — branch `feat/domain-layer` ends with ~14 commits each adding one type-or-protocol unit, `swift test` from `Packages/Domain` reports 50+ tests passing, and `xcodebuild build` for the App target still succeeds.
