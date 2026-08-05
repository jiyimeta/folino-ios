# Per-Score Prefs "Changed vs. Untouched" Instrumentation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make "the user never touched this setting" representable (`nil`) in `ReaderPreferences` end-to-end — Domain model, Reader view models, SQLite (migration v16), Android JSON blobs — and emit a launch-time `score_prefs` analytics event whose parameters are present only for explicitly-set values, so BigQuery can answer "how many scores/users changed each setting, and to what" without counting seeded defaults.

**Architecture:** Four scalar fields (`staffSize`, `honorLayoutBreaks`, `masterVolume`, `transposeSemitones`) become Optional in Domain with `nil` == untouched, mirroring the convention `tempoMultiplier` / `a4ReferenceHz` already use. Each Reader sub-model holds the raw Optional as its persistent slice and exposes an `effective*` accessor for the UI (the `TempoModel` split). Persistence stores real NULLs via the file's first table-rebuild migration (v16), which also reclassifies stored defaults as untouched and adds an `authored_hidden_staves` provenance column. A new Domain factory `AnalyticsEvent.scorePrefs` builds one event per changed score; iOS emits from `AppBootstrap`, Android through a per-blob `AnalyticsBridge` builder.

**Tech Stack:** Swift 6.3, SwiftUI + Observation, GRDB (raw-SQL migrations), Swift Testing (`@Test` / `#expect`), SwiftPM local packages, Firebase Analytics (shared Domain catalog), swift-wirelet JNI bridges + Kotlin/Room on Android.

**Spec:** `docs/superpowers/specs/2026-08-05-per-score-prefs-instrumentation-design.md` (source of truth; §ns below refer to it)

## Global Constraints

- Execute in a git worktree created via `superpowers:using-git-worktrees`. All paths below are repo-relative; prefix them with the worktree root. Never `cd` into the primary checkout; use `git -C <worktree>` for every git call.
- `nil` == "untouched; resolve to the current default". `.some(default)` == "explicitly set to the default" and MUST survive every re-seat/clamp/save round-trip. Only dedicated reset affordances write `nil`.
- Clamping is `Optional.map`-based everywhere. A clamp that materializes a number out of `nil` silently marks a score as touched — this is the failure the whole design exists to prevent.
- `repeatMode` stays non-Optional and out of `score_prefs` entirely; v16 copies the `repeat_mode` column through unchanged (legacy, no user write path — spec discrepancy note).
- The `score_prefs` event carries NO score identifier. Its parameters are exactly the twelve in §7's table; a parameter is included only when the underlying value is non-`nil` / non-empty. `screen_width_pt` is always present (when the event exists at all).
- Bucketing: `master_volume_pct` / `tempo_multiplier_pct` round to 10% steps; `screen_width_pt` floors to the largest of `320 / 375 / 390 / 430 / 744 / 834 / 1024 / 1366` not exceeding the width (below 320 → 320). All other params raw.
- Android: logic is shared Swift (Domain factory + reducer); no divergent Kotlin reimplementation. The `AnalyticsBridge` builder takes ONE JSON blob `String` per call — wirelet's `[String]` method-arg support is unreleased (memory `project_wirelet_string_array_args`); do not "simplify" into an array argument.
- New tests use Swift Testing with backtick-quoted natural-language names, e.g. ``@Test func `nil staff size stays nil through init`()``.
- Package tests run through `xcodebuild test` from the package directory, never `swift test` (SwiftLint plugin) — EXCEPT the Android-gated `FolinoLibraryJNI` targets, which have no SwiftLint plugin and run on the macOS host via `FOLINO_ANDROID=1 xcrun swift test`. Destination is always `platform=iOS Simulator,name=iPhone 17 Pro Max`; every `xcodebuild` call needs `-skipPackagePluginValidation`.
- Scheme names: single-product packages use the product name (`Domain`, `Reader`, `Library`, `Editor`); multi-product use `<PackageName>-Package` (`Infrastructure-Package`, `ImportExport-Package`). If a scheme errors, run `xcodebuild -list` in the package dir.
- Do not run builds in the background — wait for each result (memory `feedback_no_background_builds`).
- Access modifiers: `public` only where the symbol crosses a module boundary. Comments reflow at 120 columns, American spelling.
- Commit per task (this is plan implementation). No push, no `gh`. Stage whole files only — never `git add -p`.
- Expected mid-plan breakage: Task 1 breaks compile of Infrastructure (record), Reader, and the Android JNI targets until Tasks 5, 7, and 10 respectively land. Each task's verification is scoped to packages that are whole at that point; do not "fix ahead" into a later task's files.

---

### Task 1: Domain — four scalar fields become Optional

**Files:**
- Modify: `Packages/Domain/Sources/Domain/Models/ReaderPreferences.swift`
- Modify (fix breakage): `Packages/Domain/Tests/DomainTests/Models/ReaderPreferencesTests.swift`, `ReaderPreferencesA4Tests.swift`, `ReaderPreferencesRepeatTests.swift` and any other `DomainTests` file the compiler flags
- Test: `Packages/Domain/Tests/DomainTests/Models/ReaderPreferencesUntouchedTests.swift` (create)

**Interfaces:**
- Consumes: nothing new.
- Produces (later tasks rely on these exact names):
  - `var staffSize: Double?`, `var honorLayoutBreaks: Bool?`, `var masterVolume: Double?`, `var transposeSemitones: Int?`
  - `static let defaultHonorLayoutBreaks = true`, `static let defaultMasterVolume = 1.0`, `static let defaultTransposeSemitones = 0`
  - `var effectiveHonorLayoutBreaks: Bool`, `var effectiveMasterVolume: Double`, `var effectiveTransposeSemitones: Int`
  - `func effectiveStaffSize(default: Double) -> Double`
  - `init` params: `staffSize: Double? = nil`, `honorLayoutBreaks: Bool? = nil`, `masterVolume: Double? = nil`, `transposeSemitones: Int? = nil` (positions unchanged)

- [ ] **Step 1: Write the failing test**

Create `Packages/Domain/Tests/DomainTests/Models/ReaderPreferencesUntouchedTests.swift`:

```swift
import Domain
import Testing

/// `nil` == "the user never set this — resolve to the current default". These tests pin the two load-bearing rules:
/// clamping must never materialize a value out of `nil`, and explicit values (including explicit defaults) survive.
struct ReaderPreferencesUntouchedTests {
    private let scoreID = ScoreItemID()

    @Test func `omitted scalar fields default to nil`() {
        let prefs = ReaderPreferences(scoreItemID: scoreID, hiddenStaves: [])
        #expect(prefs.staffSize == nil)
        #expect(prefs.honorLayoutBreaks == nil)
        #expect(prefs.masterVolume == nil)
        #expect(prefs.transposeSemitones == nil)
    }

    @Test func `nil survives the memberwise init for all four fields`() {
        let prefs = ReaderPreferences(
            scoreItemID: scoreID, staffSize: nil, hiddenStaves: [],
            honorLayoutBreaks: nil, masterVolume: nil, transposeSemitones: nil,
        )
        #expect(prefs.staffSize == nil)
        #expect(prefs.honorLayoutBreaks == nil)
        #expect(prefs.masterVolume == nil)
        #expect(prefs.transposeSemitones == nil)
    }

    @Test func `set values still clamp`() {
        let prefs = ReaderPreferences(
            scoreItemID: scoreID, staffSize: 99, hiddenStaves: [],
            masterVolume: 5.0, transposeSemitones: 12,
        )
        #expect(prefs.staffSize == 28)
        #expect(prefs.masterVolume == 3.0)
        #expect(prefs.transposeSemitones == 7)
    }

    @Test func `an explicit default value is kept as some`() {
        let prefs = ReaderPreferences(
            scoreItemID: scoreID, staffSize: 14, hiddenStaves: [],
            honorLayoutBreaks: true, masterVolume: 1.0, transposeSemitones: 0,
        )
        #expect(prefs.staffSize == 14)
        #expect(prefs.honorLayoutBreaks == true)
        #expect(prefs.masterVolume == 1.0)
        #expect(prefs.transposeSemitones == 0)
    }

    @Test func `effective accessors resolve nil to the static defaults`() {
        let prefs = ReaderPreferences(scoreItemID: scoreID, hiddenStaves: [])
        #expect(prefs.effectiveHonorLayoutBreaks == true)
        #expect(prefs.effectiveMasterVolume == 1.0)
        #expect(prefs.effectiveTransposeSemitones == 0)
    }

    @Test func `effectiveStaffSize follows the injected default`() {
        let untouched = ReaderPreferences(scoreItemID: scoreID, hiddenStaves: [])
        #expect(untouched.effectiveStaffSize(default: 16) == 16)
        let touched = ReaderPreferences(scoreItemID: scoreID, staffSize: 20, hiddenStaves: [])
        #expect(touched.effectiveStaffSize(default: 16) == 20)
    }

    @Test func `explicit zero transpose is not a staff-bound override`() {
        let prefs = ReaderPreferences(scoreItemID: scoreID, hiddenStaves: [], transposeSemitones: 0)
        #expect(!prefs.hasStaffBoundOverrides)
    }

    @Test func `clearingStaffBoundOverrides resets transpose to nil`() {
        let prefs = ReaderPreferences(scoreItemID: scoreID, hiddenStaves: [], transposeSemitones: 3)
        #expect(prefs.clearingStaffBoundOverrides().transposeSemitones == nil)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

From `Packages/Domain`:

```bash
xcodebuild test -scheme Domain \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -skipPackagePluginValidation \
  -only-testing:DomainTests/ReaderPreferencesUntouchedTests
```

Expected: compile failure (`'nil' is not compatible with expected argument type 'Double'` or similar).

- [ ] **Step 3: Implement in `ReaderPreferences.swift`**

1. Stored properties (keep the existing doc comments, extend them with the `nil` == untouched semantics):

```swift
public var staffSize: Double?
public var honorLayoutBreaks: Bool?
public var masterVolume: Double?
public var transposeSemitones: Int?
```

2. Static defaults + effective accessors (place near the existing min/max statics):

```swift
/// Defaults an untouched (`nil`) field resolves to. Staff size has NO static default here — its default is the one
/// that becomes device-class-dependent (`ReaderRootScreen`), so resolution takes it as an argument instead.
public static let defaultHonorLayoutBreaks = true
public static let defaultMasterVolume = 1.0
public static let defaultTransposeSemitones = 0

public var effectiveHonorLayoutBreaks: Bool { honorLayoutBreaks ?? Self.defaultHonorLayoutBreaks }
public var effectiveMasterVolume: Double { masterVolume ?? Self.defaultMasterVolume }
public var effectiveTransposeSemitones: Int { transposeSemitones ?? Self.defaultTransposeSemitones }

public func effectiveStaffSize(default defaultValue: Double) -> Double { staffSize ?? defaultValue }
```

3. `init`: signatures become `staffSize: Double? = nil`, `honorLayoutBreaks: Bool? = nil`, `masterVolume: Double? = nil`, `transposeSemitones: Int? = nil` (same positions). Clamps become `map`-based, matching the `tempoMultiplier` form already in the file:

```swift
self.staffSize = staffSize.map { min(max($0, Self.minStaffSize), Self.maxStaffSize) }
self.honorLayoutBreaks = honorLayoutBreaks
self.masterVolume = masterVolume.map { min(max($0, Self.minMasterVolume), Self.maxMasterVolume) }
self.transposeSemitones = transposeSemitones.map { min(max($0, -7), 7) }
```

4. `hasStaffBoundOverrides`: `transposeSemitones != 0` becomes `(transposeSemitones ?? 0) != 0`.

5. `clearingStaffBoundOverrides()`: `copy.transposeSemitones = 0` becomes `copy.transposeSemitones = nil`.

6. `init(from decoder:)` (minimal compile fix for this task — the schemaVersion logic is Task 3): the four fields move to `decodeIfPresent` with no default fallback:

```swift
let staffSize = try c.decodeIfPresent(Double.self, forKey: .staffSize)
let honorBreaks = try c.decodeIfPresent(Bool.self, forKey: .honorLayoutBreaks)
let master = try c.decodeIfPresent(Double.self, forKey: .masterVolume)
let transpose = try c.decodeIfPresent(Int.self, forKey: .transposeSemitones)
```

- [ ] **Step 4: Fix broken DomainTests call sites/assertions**

Build the test bundle; the compiler and failing assertions will point at existing tests that assumed non-Optional fields (`ReaderPreferencesTests.swift` clamping assertions like `prefs.staffSize == 14`, A4/repeat test fixtures, `AuthoredVisibilitySeedTests.swift` still compiles because `Double` literals coerce to `Double?`). Update assertions to Optional comparisons (`== 14` still works on `Double?`; fix only genuine type errors and any test asserting that an omitted field equals the old default — those now expect `nil`). Do NOT touch `AuthoredVisibilitySeedTests` semantics — that is Task 2.

- [ ] **Step 5: Run the whole Domain suite**

From `Packages/Domain`:

```bash
xcodebuild test -scheme Domain \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -skipPackagePluginValidation
```

Expected: `** TEST SUCCEEDED **`. (Other packages are now expected broken — that is by design; see Global Constraints.)

- [ ] **Step 6: Commit**

```bash
git -C <worktree> add Packages/Domain
git -C <worktree> commit -m "feat(domain): make untouched per-score preferences representable as nil"
```

---

### Task 2: Domain — `authoredHiddenStaves` provenance + `reconcilingAuthoredHidden` rewrite

Depends on: Task 1.

**Files:**
- Modify: `Packages/Domain/Sources/Domain/Models/ReaderPreferences.swift`
- Modify: `Packages/Domain/Sources/Domain/Models/ReaderPreferences+AuthoredVisibilitySeed.swift`
- Test: `Packages/Domain/Tests/DomainTests/AuthoredVisibilitySeedTests.swift` (extend/update)

**Interfaces:**
- Produces:
  - `var authoredHiddenStaves: Set<StaffAddress>` on `ReaderPreferences`, init param `authoredHiddenStaves: Set<StaffAddress> = []` placed right after `hiddenStaves`.
  - New signature (the `defaultStaffSize:` parameter is REMOVED — its two callers are fixed in Tasks 7 and 10):
    `static func reconcilingAuthoredHidden(stored: ReaderPreferences?, authoredHiddenStaves: Set<StaffAddress>, scoreItemID: ScoreItemID) -> (preferences: ReaderPreferences, shouldPersist: Bool)`

- [ ] **Step 1: Write the failing tests**

In `AuthoredVisibilitySeedTests.swift`, update every call site to the new three-argument signature and add:

```swift
@Test func `fresh seed with no authored staves is not persisted`() {
    let (prefs, shouldPersist) = ReaderPreferences.reconcilingAuthoredHidden(
        stored: nil, authoredHiddenStaves: [], scoreItemID: scoreID,
    )
    #expect(!shouldPersist)
    #expect(prefs.staffSize == nil)
    #expect(prefs.hasSeededAuthoredVisibility)
}

@Test func `fresh seed with authored staves persists and records provenance`() {
    let authored: Set<StaffAddress> = [StaffAddress(partIndex: 1, staffIndexInPart: 0)]
    let (prefs, shouldPersist) = ReaderPreferences.reconcilingAuthoredHidden(
        stored: nil, authoredHiddenStaves: authored, scoreItemID: scoreID,
    )
    #expect(shouldPersist)
    #expect(prefs.hiddenStaves == authored)
    #expect(prefs.authoredHiddenStaves == authored)
    #expect(prefs.staffSize == nil)
}

@Test func `backfill records the authored set alongside the union`() {
    let user: Set<StaffAddress> = [StaffAddress(partIndex: 0, staffIndexInPart: 0)]
    let authored: Set<StaffAddress> = [StaffAddress(partIndex: 1, staffIndexInPart: 0)]
    let stored = ReaderPreferences(
        scoreItemID: scoreID, hiddenStaves: user, hasSeededAuthoredVisibility: false,
    )
    let (prefs, shouldPersist) = ReaderPreferences.reconcilingAuthoredHidden(
        stored: stored, authoredHiddenStaves: authored, scoreItemID: scoreID,
    )
    #expect(shouldPersist)
    #expect(prefs.hiddenStaves == user.union(authored))
    #expect(prefs.authoredHiddenStaves == authored)
}

@Test func `refresh updates a stale authored set without touching hidden staves`() {
    let authored: Set<StaffAddress> = [StaffAddress(partIndex: 1, staffIndexInPart: 0)]
    var stored = ReaderPreferences(
        scoreItemID: scoreID, hiddenStaves: [], hasSeededAuthoredVisibility: true,
    )
    stored.authoredHiddenStaves = [StaffAddress(partIndex: 2, staffIndexInPart: 0)]
    let (prefs, shouldPersist) = ReaderPreferences.reconcilingAuthoredHidden(
        stored: stored, authoredHiddenStaves: authored, scoreItemID: scoreID,
    )
    #expect(shouldPersist)
    #expect(prefs.hiddenStaves.isEmpty)          // user reveal stays sticky
    #expect(prefs.authoredHiddenStaves == authored)
}

@Test func `matching authored set returns stored unchanged with no persist`() {
    let authored: Set<StaffAddress> = [StaffAddress(partIndex: 1, staffIndexInPart: 0)]
    var stored = ReaderPreferences(
        scoreItemID: scoreID, hiddenStaves: authored, hasSeededAuthoredVisibility: true,
    )
    stored.authoredHiddenStaves = authored
    let (prefs, shouldPersist) = ReaderPreferences.reconcilingAuthoredHidden(
        stored: stored, authoredHiddenStaves: authored, scoreItemID: scoreID,
    )
    #expect(!shouldPersist)
    #expect(prefs == stored)
}
```

(`scoreID` is a `ScoreItemID` fixture — follow the file's existing pattern.)

- [ ] **Step 2: Run to verify failure**

Same command as Task 1 Step 5 with `-only-testing:DomainTests/AuthoredVisibilitySeedTests`. Expected: compile failure (extra `defaultStaffSize:` argument / missing `authoredHiddenStaves`).

- [ ] **Step 3: Implement**

In `ReaderPreferences.swift`: add the stored property with doc comment ("score-derived ground truth of the staves the score itself authored hidden; refreshed on every open — user intent is `hiddenStaves.subtracting(authoredHiddenStaves)` / `authoredHiddenStaves.subtracting(hiddenStaves)`"), init param `authoredHiddenStaves: Set<StaffAddress> = []` after `hiddenStaves`, assign unclamped, add `case authoredHiddenStaves` to `CodingKeys`, decode with `try c.decodeIfPresent(Set<StaffAddress>.self, forKey: .authoredHiddenStaves) ?? []` and pass through `self.init` (full legacy handling is Task 3).

In `ReaderPreferences+AuthoredVisibilitySeed.swift` replace the body (update the doc comment to describe all four branches):

```swift
public static func reconcilingAuthoredHidden(
    stored: ReaderPreferences?,
    authoredHiddenStaves: Set<StaffAddress>,
    scoreItemID: ScoreItemID,
) -> (preferences: ReaderPreferences, shouldPersist: Bool) {
    guard let stored else {
        let seeded = ReaderPreferences(
            scoreItemID: scoreItemID,
            hiddenStaves: authoredHiddenStaves,
            authoredHiddenStaves: authoredHiddenStaves,
            hasSeededAuthoredVisibility: true,
        )
        return (seeded, !authoredHiddenStaves.isEmpty)
    }
    if !stored.hasSeededAuthoredVisibility, !authoredHiddenStaves.isEmpty {
        var backfilled = stored
        backfilled.hiddenStaves.formUnion(authoredHiddenStaves)
        backfilled.authoredHiddenStaves = authoredHiddenStaves
        backfilled.hasSeededAuthoredVisibility = true
        return (backfilled, true)
    }
    if stored.authoredHiddenStaves != authoredHiddenStaves {
        var refreshed = stored
        refreshed.authoredHiddenStaves = authoredHiddenStaves
        return (refreshed, true)
    }
    return (stored, false)
}
```

Key behavior changes vs. today: fresh seed persists ONLY when there are authored staves (§5 — kills the pointless first-open write); fresh seed carries `staffSize: nil`; the refresh branch makes `authoredHiddenStaves` self-healing after v16 and after PDF re-reads (§6).

- [ ] **Step 4: Run the Domain suite (full)** — same command as Task 1 Step 5. Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git -C <worktree> add Packages/Domain
git -C <worktree> commit -m "feat(domain): record authored-hidden staff provenance and stop informationless seed writes"
```

---

### Task 3: Domain — Codable `schemaVersion` + legacy-blob normalization

Depends on: Tasks 1–2. This is the Android v16 equivalent (§8): the JSON blob store has no migration runner, so the Codable layer versions the payload.

**Files:**
- Modify: `Packages/Domain/Sources/Domain/Models/ReaderPreferences.swift`
- Test: `Packages/Domain/Tests/DomainTests/Models/ReaderPreferencesCodableVersionTests.swift` (create)

**Interfaces:**
- Produces: `encode(to:)` writes `schemaVersion: 2`; `init(from:)` treats a missing `schemaVersion` as legacy and normalizes 14 / `true` / 1.0 / 0 → `nil` and seeds `authoredHiddenStaves` from `hiddenStaves`; `schemaVersion >= 2` blobs take present values as authoritative.

- [ ] **Step 1: Write the failing test**

```swift
import Domain
import Foundation
import Testing

/// The Android JSON-blob store has no migration runner, so the Codable layer carries the v16 conversion: a blob
/// without `schemaVersion` is legacy and its stored defaults are reclassified as untouched, exactly once in effect —
/// every re-encode stamps `schemaVersion: 2`, after which present values are authoritative.
struct ReaderPreferencesCodableVersionTests {
    private let scoreID = ScoreItemID()

    /// Builds legacy-blob JSON: encode a modern value, then strip `schemaVersion` and force the given raw fields.
    private func legacyJSON(overriding fields: [String: Any]) throws -> Data {
        let base = ReaderPreferences(scoreItemID: scoreID, hiddenStaves: [])
        let data = try JSONEncoder().encode(base)
        var dict = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        dict.removeValue(forKey: "schemaVersion")
        dict.removeValue(forKey: "authoredHiddenStaves")
        for (key, value) in fields { dict[key] = value }
        return try JSONSerialization.data(withJSONObject: dict)
    }

    @Test func `legacy blob normalizes stored defaults to nil`() throws {
        let data = try legacyJSON(overriding: [
            "staffSize": 14, "honorLayoutBreaks": true, "masterVolume": 1.0, "transposeSemitones": 0,
        ])
        let decoded = try JSONDecoder().decode(ReaderPreferences.self, from: data)
        #expect(decoded.staffSize == nil)
        #expect(decoded.honorLayoutBreaks == nil)
        #expect(decoded.masterVolume == nil)
        #expect(decoded.transposeSemitones == nil)
    }

    @Test func `legacy blob keeps non-default values`() throws {
        let data = try legacyJSON(overriding: [
            "staffSize": 18, "honorLayoutBreaks": false, "masterVolume": 1.5, "transposeSemitones": -3,
        ])
        let decoded = try JSONDecoder().decode(ReaderPreferences.self, from: data)
        #expect(decoded.staffSize == 18)
        #expect(decoded.honorLayoutBreaks == false)
        #expect(decoded.masterVolume == 1.5)
        #expect(decoded.transposeSemitones == -3)
    }

    @Test func `legacy blob seeds authored hidden from hidden staves`() throws {
        let hidden = [[1, 0]]
        let data = try legacyJSON(overriding: ["hiddenStaves": hidden, "staffSize": 14])
        let decoded = try JSONDecoder().decode(ReaderPreferences.self, from: data)
        #expect(decoded.authoredHiddenStaves == decoded.hiddenStaves)
        #expect(!decoded.hiddenStaves.isEmpty)
    }

    @Test func `v2 blob keeps an explicit default value as some`() throws {
        let original = ReaderPreferences(
            scoreItemID: scoreID, staffSize: 14, hiddenStaves: [],
            honorLayoutBreaks: true, masterVolume: 1.0, transposeSemitones: 0,
        )
        let decoded = try JSONDecoder().decode(
            ReaderPreferences.self, from: JSONEncoder().encode(original),
        )
        #expect(decoded.staffSize == 14)
        #expect(decoded.honorLayoutBreaks == true)
        #expect(decoded.masterVolume == 1.0)
        #expect(decoded.transposeSemitones == 0)
    }

    @Test func `v2 blob round-trips nil as nil`() throws {
        let original = ReaderPreferences(scoreItemID: scoreID, hiddenStaves: [])
        let decoded = try JSONDecoder().decode(
            ReaderPreferences.self, from: JSONEncoder().encode(original),
        )
        #expect(decoded.staffSize == nil)
        #expect(decoded.honorLayoutBreaks == nil)
        #expect(decoded.masterVolume == nil)
        #expect(decoded.transposeSemitones == nil)
        #expect(decoded == original)
    }
}
```

Note: the `hiddenStaves` JSON shape in `legacyJSON` is a **two-element unkeyed array `[partIndex, staffIndexInPart]`** — verified in `Packages/Domain/Sources/Domain/Models/StaffAddress+Codable.swift:15-19`, which gives the upstream `SheetMusicCore.StaffAddress` a retroactive `Codable` using an unkeyed container. So one hidden staff at part 1 / staff 0 serializes as `[[1,0]]`. Write the literal that way; no probing encode needed.

- [ ] **Step 2: Run to verify failure** — `-only-testing:DomainTests/ReaderPreferencesCodableVersionTests`. Expected: FAIL (`legacy blob normalizes stored defaults to nil` sees `14`, not `nil`; round-trip may also fail on the missing custom encoder).

- [ ] **Step 3: Implement**

In `ReaderPreferences.swift`:

1. `static let codableSchemaVersion = 2` (internal), `case schemaVersion` in `CodingKeys`.
2. Custom `encode(to:)` (synthesized encoding disappears once written — encode every stored property; use `encodeIfPresent` for `staffSize`, `honorLayoutBreaks`, `masterVolume`, `transposeSemitones`, `tempoMultiplier`, `abRepeat`, `a4ReferenceHz`; plain `encode` for the rest; and `try c.encode(Self.codableSchemaVersion, forKey: .schemaVersion)`).
3. `init(from:)`: decode `let version = try c.decodeIfPresent(Int.self, forKey: .schemaVersion)`; after decoding the four fields, when `version == nil` apply the legacy normalization before calling `self.init`:

```swift
let isLegacy = version == nil
let normalizedStaffSize = (isLegacy && staffSize == 14) ? nil : staffSize
let normalizedHonorBreaks = (isLegacy && honorBreaks == true) ? nil : honorBreaks
let normalizedMaster = (isLegacy && master == 1.0) ? nil : master
let normalizedTranspose = (isLegacy && transpose == 0) ? nil : transpose
let authored = try c.decodeIfPresent(Set<StaffAddress>.self, forKey: .authoredHiddenStaves)
    ?? (isLegacy ? hiddenStaves : [])
```

Why the marker matters (put this in a comment): without it, a decode-time normalization would forever collapse an explicitly-re-chosen default back to untouched — the marker makes the conversion one-time in effect. iOS persistence never uses this Codable path (GRDB records only), so the blast radius is the Android blob and tests.

- [ ] **Step 4: Run the full Domain suite** — Task 1 Step 5 command. Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git -C <worktree> add Packages/Domain
git -C <worktree> commit -m "feat(domain): version the ReaderPreferences codable payload and normalize legacy blobs"
```

---

### Task 4: Domain — `score_prefs` factory, width bucketing, and launch enumeration helper

Depends on: Tasks 1–2.

**Files:**
- Modify: `Packages/Domain/Sources/Domain/Analytics/AnalyticsEvent+Factories.swift`
- Test: `Packages/Domain/Tests/DomainTests/ScorePrefsEventTests.swift` (create)

**Interfaces:**
- Produces (used by Task 9's App emission and Task 11's Android bridge):
  - `static func scorePrefs(_ prefs: ReaderPreferences, screenWidthPt: Double) -> AnalyticsEvent?` — `nil` when the row is all-untouched.
  - `static func screenWidthBucket(_ widthPt: Double) -> Int` — public so the bucket table exists exactly once.
  - `static func scorePrefsEvents(allPreferences: [ReaderPreferences], liveScoreItemIDs: Set<ScoreItemID>, screenWidthPt: Double) -> [AnalyticsEvent]` — filters trashed scores, drops all-untouched rows.

- [ ] **Step 1: Write the failing test**

Create `Packages/Domain/Tests/DomainTests/ScorePrefsEventTests.swift` (mirror `AnalyticsEventFactoryTests.swift`'s style — `@testable import Domain`, `import UtilityCore`):

```swift
@testable import Domain
import Testing
import UtilityCore

struct ScorePrefsEventTests {
    private let scoreID = ScoreItemID()
    private let staffA = StaffAddress(partIndex: 0, staffIndexInPart: 0)
    private let staffB = StaffAddress(partIndex: 1, staffIndexInPart: 0)

    @Test func `an all-untouched row produces no event`() {
        let prefs = ReaderPreferences(scoreItemID: scoreID, hiddenStaves: [])
        #expect(AnalyticsEvent.scorePrefs(prefs, screenWidthPt: 430) == nil)
    }

    @Test func `a single touched field emits exactly that param plus width`() throws {
        let prefs = ReaderPreferences(scoreItemID: scoreID, staffSize: 18, hiddenStaves: [])
        let event = try #require(AnalyticsEvent.scorePrefs(prefs, screenWidthPt: 430))
        #expect(event.name == "score_prefs")
        #expect(event.parameters["staff_size"] == .int(18))
        #expect(event.parameters["screen_width_pt"] == .int(430))
        #expect(event.parameters.count == 2)
    }

    @Test func `explicit false honor breaks is present`() throws {
        let prefs = ReaderPreferences(scoreItemID: scoreID, hiddenStaves: [], honorLayoutBreaks: false)
        let event = try #require(AnalyticsEvent.scorePrefs(prefs, screenWidthPt: 375))
        #expect(event.parameters["honor_layout_breaks"] == .bool(false))
    }

    @Test func `percent params round to 10 percent steps`() throws {
        let prefs = ReaderPreferences(
            scoreItemID: scoreID, hiddenStaves: [],
            tempoMultiplier: 0.5, masterVolume: 3.0,
        )
        let event = try #require(AnalyticsEvent.scorePrefs(prefs, screenWidthPt: 375))
        #expect(event.parameters["master_volume_pct"] == .int(300))
        #expect(event.parameters["tempo_multiplier_pct"] == .int(50))
    }

    @Test func `hid and reveal counts come from the two sets`() throws {
        var prefs = ReaderPreferences(scoreItemID: scoreID, hiddenStaves: [staffA], authoredHiddenStaves: [staffB])
        // staffA is user-hidden (not authored); staffB is authored but visible == user-revealed.
        let event = try #require(AnalyticsEvent.scorePrefs(prefs, screenWidthPt: 375))
        #expect(event.parameters["hidden_staff_count"] == .int(1))
        #expect(event.parameters["revealed_staff_count"] == .int(1))
        // Authored-only hides emit neither param.
        prefs.hiddenStaves = [staffB]
        prefs.authoredHiddenStaves = [staffB]
        #expect(AnalyticsEvent.scorePrefs(prefs, screenWidthPt: 375) == nil)
    }

    @Test func `override dictionaries report counts`() throws {
        let prefs = ReaderPreferences(
            scoreItemID: scoreID, hiddenStaves: [],
            staffProgramOverrides: [staffA: 40], staffVolumeOverrides: [staffA: 0.5, staffB: 0.7],
            staffClefOverrides: [staffA: "F"],
        )
        let event = try #require(AnalyticsEvent.scorePrefs(prefs, screenWidthPt: 375))
        #expect(event.parameters["program_override_count"] == .int(1))
        #expect(event.parameters["volume_override_count"] == .int(2))
        #expect(event.parameters["clef_override_count"] == .int(1))
    }

    @Test func `a4 reference rounds to whole hz`() throws {
        let prefs = ReaderPreferences(scoreItemID: scoreID, hiddenStaves: [], a4ReferenceHz: 441.6)
        let event = try #require(AnalyticsEvent.scorePrefs(prefs, screenWidthPt: 375))
        #expect(event.parameters["a4_reference_hz"] == .int(442))
    }

    @Test func `screen width floors to the breakpoint table`() {
        #expect(AnalyticsEvent.screenWidthBucket(507) == 430)
        #expect(AnalyticsEvent.screenWidthBucket(300) == 320)
        #expect(AnalyticsEvent.screenWidthBucket(320) == 320)
        #expect(AnalyticsEvent.screenWidthBucket(834) == 834)
        #expect(AnalyticsEvent.screenWidthBucket(1400) == 1366)
    }

    @Test func `enumeration filters trashed scores and untouched rows`() {
        let liveID = ScoreItemID()
        let trashedID = ScoreItemID()
        let untouchedID = ScoreItemID()
        let rows = [
            ReaderPreferences(scoreItemID: liveID, staffSize: 18, hiddenStaves: []),
            ReaderPreferences(scoreItemID: trashedID, staffSize: 20, hiddenStaves: []),
            ReaderPreferences(scoreItemID: untouchedID, hiddenStaves: []),
        ]
        let events = AnalyticsEvent.scorePrefsEvents(
            allPreferences: rows, liveScoreItemIDs: [liveID, untouchedID], screenWidthPt: 430,
        )
        #expect(events.count == 1)
        #expect(events[0].parameters["staff_size"] == .int(18))
    }
}
```

- [ ] **Step 2: Run to verify failure** — `-only-testing:DomainTests/ScorePrefsEventTests`. Expected: compile failure (`scorePrefs` not found).

- [ ] **Step 3: Implement in `AnalyticsEvent+Factories.swift`**

Add under the "Launch snapshots" MARK:

```swift
/// One-per-changed-score launch snapshot (§7 of the 2026-08-05 per-score-prefs spec). THE mechanic: a parameter is
/// included only when the underlying value is non-`nil` (non-empty for sets/dictionaries) — in BigQuery "param
/// present" == changed and its value is the settled value. Returns `nil` for an all-untouched row so callers skip
/// the event entirely. Carries NO score identifier by design. `master_volume_pct` / `tempo_multiplier_pct` round to
/// 10% steps and `screen_width_pt` snaps to a breakpoint — a documented exception to the raw-params policy; these
/// are continuous values whose sub-bucket precision carries no decision value.
public static func scorePrefs(_ prefs: ReaderPreferences, screenWidthPt: Double) -> AnalyticsEvent? {
    var params: [String: AnalyticsValue] = [:]
    if let staffSize = prefs.staffSize { params["staff_size"] = .int(Int(staffSize.rounded())) }
    if let honorBreaks = prefs.honorLayoutBreaks { params["honor_layout_breaks"] = .bool(honorBreaks) }
    if let volume = prefs.masterVolume { params["master_volume_pct"] = .int(Int((volume * 10).rounded()) * 10) }
    if let transpose = prefs.transposeSemitones { params["transpose_semitones"] = .int(transpose) }
    if let tempo = prefs.tempoMultiplier { params["tempo_multiplier_pct"] = .int(Int((tempo * 10).rounded()) * 10) }
    if let a4 = prefs.a4ReferenceHz { params["a4_reference_hz"] = .int(Int(a4.rounded())) }
    let userHidden = prefs.hiddenStaves.subtracting(prefs.authoredHiddenStaves)
    if !userHidden.isEmpty { params["hidden_staff_count"] = .int(userHidden.count) }
    let userRevealed = prefs.authoredHiddenStaves.subtracting(prefs.hiddenStaves)
    if !userRevealed.isEmpty { params["revealed_staff_count"] = .int(userRevealed.count) }
    if !prefs.staffProgramOverrides.isEmpty {
        params["program_override_count"] = .int(prefs.staffProgramOverrides.count)
    }
    if !prefs.staffVolumeOverrides.isEmpty {
        params["volume_override_count"] = .int(prefs.staffVolumeOverrides.count)
    }
    if !prefs.staffClefOverrides.isEmpty {
        params["clef_override_count"] = .int(prefs.staffClefOverrides.count)
    }
    guard !params.isEmpty else { return nil }
    params["screen_width_pt"] = .int(screenWidthBucket(screenWidthPt))
    return AnalyticsEvent(name: "score_prefs", parameters: params)
}

/// Effective-width bucket: the largest breakpoint that does not exceed the width (below 320 reports 320). Owned by
/// Domain so iOS (points) and Android (dp) share one table.
public static func screenWidthBucket(_ widthPt: Double) -> Int {
    let breakpoints = [1366, 1024, 834, 744, 430, 390, 375, 320]
    return breakpoints.first { Double($0) <= widthPt } ?? 320
}

/// Launch-time enumeration: one event per LIVE score whose row has any explicitly-set preference. Trashed scores are
/// excluded so the numerator matches `library_snapshot.score_count_total`.
public static func scorePrefsEvents(
    allPreferences: [ReaderPreferences],
    liveScoreItemIDs: Set<ScoreItemID>,
    screenWidthPt: Double,
) -> [AnalyticsEvent] {
    allPreferences
        .filter { liveScoreItemIDs.contains($0.scoreItemID) }
        .compactMap { scorePrefs($0, screenWidthPt: screenWidthPt) }
}
```

Note: `repeat_mode` and `ab_repeat` deliberately have no parameter (spec discrepancy note / YAGNI).

- [ ] **Step 4: Run the full Domain suite** — Task 1 Step 5 command. Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git -C <worktree> add Packages/Domain
git -C <worktree> commit -m "feat(domain): add the score_prefs launch event factory with presence-means-changed params"
```

---

### Task 5: Persistence — nullable record + migration v16 (the file's first table rebuild)

Depends on: Tasks 1–2. **Getting the rebuilt table's constraints wrong silently breaks cascade deletes** — the `score_item_id` PRIMARY KEY and its `REFERENCES score_items(id) ON DELETE CASCADE` must be reproduced exactly; the cascade test below is not optional.

**Files:**
- Modify: `Packages/Infrastructure/Sources/Persistence/Records/ReaderPreferencesRecord.swift`
- Modify: `Packages/Infrastructure/Sources/Persistence/Database/Migrations.swift`
- Test: `Packages/Infrastructure/Tests/InfrastructureTests/Persistence/MigrationV16Tests.swift` (create)
- Modify: `Packages/Infrastructure/Tests/InfrastructureTests/Persistence/ReaderPreferencesRecordTests.swift` (extend)

**Interfaces:**
- Consumes: `ReaderPreferences` Optionals + `authoredHiddenStaves` (Tasks 1–2).
- Produces: `AppMigrations.upToV15` (registers v1…v15, for fixture tests), `migrateV16`, record fields `staffSize: Double?`, `honorLayoutBreaks: Bool?`, `masterVolume: Double?`, `transposeSemitones: Int?`, `authoredHiddenStaves: String` (CodingKey `authored_hidden_staves`).

- [ ] **Step 1: Write the failing migration test**

Create `MigrationV16Tests.swift` — model DB setup on the existing migration-step tests in `InfrastructureTests` (they use the `upToVn` migrators; read `AppDatabaseTests.swift` first and reuse its in-memory/tmpdir DatabaseQueue pattern):

```swift
import GRDB
@testable import Persistence
import Testing

/// v16 is this schema's first table rebuild (SQLite cannot drop NOT NULL in place). It reclassifies stored default
/// values as untouched (NULL) and initializes `authored_hidden_staves` from `hidden_staff_ids`. The rebuild must
/// reproduce the `score_item_id` PRIMARY KEY and its ON DELETE CASCADE — losing either silently breaks score deletes.
struct MigrationV16Tests {
    private func makeV15Database() throws -> DatabaseQueue {
        let dbQueue = try DatabaseQueue()
        try AppMigrations.upToV15.migrate(dbQueue)
        try dbQueue.write { db in
            try db.execute(sql: """
            INSERT INTO score_items (id, title, local_file_name, content_hash, size_bytes,
                                     length_beats, default_tempo_bpm, added_at)
            VALUES ('S1', 't', 'f1', 'h1', 0, 0, 120, 0), ('S2', 't', 'f2', 'h2', 0, 0, 120, 0)
            """)
            try db.execute(sql: """
            INSERT INTO reader_preferences
                (id, score_item_id, staff_size, hidden_staff_ids, honor_layout_breaks,
                 master_volume, transpose_semitones, repeat_mode)
            VALUES
                ('P1', 'S1', 14, '[[1,0]]', 1, 1.0, 0, 'loopAll'),
                ('P2', 'S2', 15, '[]',      0, 1.5, -3, 'off')
            """)
        }
        return dbQueue
    }

    @Test func `v16 reclassifies stored defaults as NULL and keeps explicit values`() throws {
        let dbQueue = try makeV15Database()
        try AppMigrations.all.migrate(dbQueue)
        try dbQueue.read { db in
            let row1 = try #require(try Row.fetchOne(
                db, sql: "SELECT * FROM reader_preferences WHERE score_item_id = 'S1'",
            ))
            let staffSize1: Double? = row1["staff_size"]
            let honorBreaks1: Bool? = row1["honor_layout_breaks"]
            let masterVolume1: Double? = row1["master_volume"]
            let transpose1: Int? = row1["transpose_semitones"]
            let repeatMode1: String = row1["repeat_mode"]
            let authored1: String = row1["authored_hidden_staves"]
            #expect(staffSize1 == nil)
            #expect(honorBreaks1 == nil)
            #expect(masterVolume1 == nil)
            #expect(transpose1 == nil)
            #expect(repeatMode1 == "loopAll")
            #expect(authored1 == "[[1,0]]")
            let row2 = try #require(try Row.fetchOne(
                db, sql: "SELECT * FROM reader_preferences WHERE score_item_id = 'S2'",
            ))
            let staffSize2: Double? = row2["staff_size"]
            let honorBreaks2: Bool? = row2["honor_layout_breaks"]
            let masterVolume2: Double? = row2["master_volume"]
            let transpose2: Int? = row2["transpose_semitones"]
            #expect(staffSize2 == 15)
            #expect(honorBreaks2 == false)
            #expect(masterVolume2 == 1.5)
            #expect(transpose2 == -3)
        }
    }

    @Test func `v16 preserves the primary key and the delete cascade`() throws {
        let dbQueue = try makeV15Database()
        try AppMigrations.all.migrate(dbQueue)
        try dbQueue.write { db in
            // PK: a second row for S1 must replace/conflict, not duplicate.
            let duplicate = try? db.execute(sql: """
            INSERT INTO reader_preferences (id, score_item_id, hidden_staff_ids, authored_hidden_staves)
            VALUES ('P3', 'S1', '[]', '[]')
            """)
            #expect(duplicate == nil)
            // Cascade: deleting the score row deletes its preferences row.
            try db.execute(sql: "DELETE FROM score_items WHERE id = 'S1'")
            let remaining = try Int.fetchOne(
                db, sql: "SELECT COUNT(*) FROM reader_preferences WHERE score_item_id = 'S1'",
            )
            #expect(remaining == 0)
        }
    }
}
```

(If `INSERT` column lists clash with NOT NULL columns the v1–v15 schema requires, extend the fixture inserts — the test's assertions are the contract, the fixtures may need more columns.)

- [ ] **Step 2: Run to verify failure**

From `Packages/Infrastructure`:

```bash
xcodebuild test -scheme Infrastructure-Package \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -skipPackagePluginValidation \
  -only-testing:InfrastructureTests/MigrationV16Tests
```

Expected: compile failure — the package is still broken from Task 1 (`ReaderPreferencesRecord.init(domain:)` maps non-Optionals) and `upToV15` doesn't exist. That IS the failing state; proceed.

- [ ] **Step 3: Implement**

**`ReaderPreferencesRecord.swift`:**
- Field types: `staffSize: Double?`, `honorLayoutBreaks: Bool?`, `masterVolume: Double?`, `transposeSemitones: Int?`; new `authoredHiddenStaves: String` with CodingKey `authoredHiddenStaves = "authored_hidden_staves"`.
- `init(domain:)`: `staffSize = prefs.staffSize` (drop the `Double(...)` cast), the other three straight assignments; encode `authoredHiddenStaves` exactly like `hiddenStaffIds` (sorted `[StaffAddress]`, JSON, `?? "[]"`).
- `toDomain()`: pass the four Optionals straight through (drop the `CGFloat` cast), `authoredHiddenStaves: Self.decodeHidden(authoredHiddenStaves)`.

**`Migrations.swift`:**
- Register `m.registerMigration("v16", migrate: migrateV16)` in `all`.
- Add `upToV15` static migrator registering v1…v15 (same shape as `upToV8`, listing all fifteen).
- Add:

```swift
// MARK: - v16

/// First table rebuild in this file: SQLite cannot drop a NOT NULL constraint in place, so `reader_preferences` is
/// recreated with `staff_size` / `honor_layout_breaks` / `master_volume` / `transpose_semitones` nullable (NULL ==
/// the user never touched the setting) plus the new `authored_hidden_staves` provenance column. Stored default values
/// (14 / 1 / 1.0 / 0) are reclassified as untouched — the accepted tradeoff of the 2026-08-05 per-score-prefs spec.
/// `authored_hidden_staves` starts as a copy of `hidden_staff_ids` (conservative: all pre-v16 hides read as authored)
/// and self-heals on each score's next open. The rebuild reproduces the `score_item_id` PRIMARY KEY and its
/// `ON DELETE CASCADE` from v2 — GRDB disables foreign keys during migration and re-checks after, so the standard
/// create-copy-drop-rename recipe is safe.
private static func migrateV16(_ db: Database) throws {
    try db.execute(sql: """
    CREATE TABLE reader_preferences_new (
        id                             TEXT    NOT NULL,
        score_item_id                  TEXT    NOT NULL PRIMARY KEY REFERENCES score_items(id) ON DELETE CASCADE,
        staff_size                     REAL,
        hidden_staff_ids               TEXT    NOT NULL,
        staff_program_overrides        TEXT    NOT NULL DEFAULT '[]',
        honor_layout_breaks            INTEGER,
        staff_volume_overrides         TEXT    NOT NULL DEFAULT '[]',
        staff_clef_overrides           TEXT    NOT NULL DEFAULT '[]',
        repeat_mode                    TEXT    NOT NULL DEFAULT 'off',
        tempo_multiplier               REAL,
        ab_repeat                      TEXT,
        master_volume                  REAL,
        transpose_semitones            INTEGER,
        a4_reference_hz                REAL,
        has_seeded_authored_visibility INTEGER NOT NULL DEFAULT 0,
        authored_hidden_staves         TEXT    NOT NULL DEFAULT '[]'
    )
    """)
    try db.execute(sql: """
    INSERT INTO reader_preferences_new
        (id, score_item_id, staff_size, hidden_staff_ids, staff_program_overrides, honor_layout_breaks,
         staff_volume_overrides, staff_clef_overrides, repeat_mode, tempo_multiplier, ab_repeat,
         master_volume, transpose_semitones, a4_reference_hz, has_seeded_authored_visibility,
         authored_hidden_staves)
    SELECT
        id, score_item_id,
        CASE WHEN staff_size = 14 THEN NULL ELSE staff_size END,
        hidden_staff_ids, staff_program_overrides,
        CASE WHEN honor_layout_breaks = 1 THEN NULL ELSE honor_layout_breaks END,
        staff_volume_overrides, staff_clef_overrides, repeat_mode, tempo_multiplier, ab_repeat,
        CASE WHEN master_volume = 1.0 THEN NULL ELSE master_volume END,
        CASE WHEN transpose_semitones = 0 THEN NULL ELSE transpose_semitones END,
        a4_reference_hz, has_seeded_authored_visibility,
        hidden_staff_ids
    FROM reader_preferences
    """)
    try db.execute(sql: "DROP TABLE reader_preferences")
    try db.execute(sql: "ALTER TABLE reader_preferences_new RENAME TO reader_preferences")
}
```

**`ReaderPreferencesRecordTests.swift`:** extend with a round-trip test — a domain value with all four fields `nil` and a non-empty `authoredHiddenStaves` survives `init(domain:)` → `toDomain()` with `nil` still `nil` and the set intact; a `.some(14)` staff size survives as `.some(14)`.

- [ ] **Step 4: Run the full Infrastructure suite**

From `Packages/Infrastructure`:

```bash
xcodebuild test -scheme Infrastructure-Package \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -skipPackagePluginValidation
```

Expected: `** TEST SUCCEEDED **`. Fix any other Infrastructure test the Optional change broke (compiler will point at them).

- [ ] **Step 5: Commit**

```bash
git -C <worktree> add Packages/Infrastructure
git -C <worktree> commit -m "feat(persistence): rebuild reader_preferences with nullable columns and authored-hidden provenance (v16)"
```

---

### Task 6: Domain protocol — `allReaderPreferences()` (additive, wide blast radius)

Depends on: Task 5 (the live implementation lives in Infrastructure, which must already compile).

**This is the "stop and confirm" class of change (Domain-protocol addition rippling across every repository fake) — the user approved it as part of this spec; the point of isolating it here is that the compile breakage below is EXPECTED and enumerated, not surprising.**

**Files:**
- Modify: `Packages/Domain/Sources/Domain/Protocols/ScoreLibraryRepository.swift`
- Modify: `Packages/Domain/Tests/DomainTests/Protocols/StorageProtocolsTests.swift` (fake at line ~10)
- Modify: `Packages/Infrastructure/Sources/Persistence/LiveScoreLibraryRepository.swift`
- Modify: `Packages/Infrastructure/Tests/InfrastructureTests/Persistence/LiveScoreFileImporterTests.swift` (`FailingRepository`, line ~9)
- Modify: `Packages/Features/Library/Tests/LibraryTests/Fakes/FakeScoreLibraryRepository.swift`
- Modify: `Packages/Features/Editor/Tests/EditorTests/Support/Fakes.swift` (`FakeScoreLibraryRepository`, line ~29)
- Modify: `Packages/Features/ImportExport/Tests/ImportExportTests/IncomingShareCoordinatorTests.swift` (`FakeRepository`, line ~74)
- NOT here: the Reader-package fakes (`ReaderTests/Fakes/FakeScoreLibraryRepository.swift`, `Sources/Reader/PreviewSupport.swift` ×2) — Reader is still broken from Task 1 and gets its conformances in Task 7.
- Test: `Packages/Infrastructure/Tests/InfrastructureTests/Persistence/LiveScoreLibraryRepositoryTests.swift` (extend)

**Interfaces:**
- Produces: `func allReaderPreferences() async throws -> [ReaderPreferences]` on `ScoreLibraryRepository`.

- [ ] **Step 1: Write the failing test**

In `LiveScoreLibraryRepositoryTests.swift` add (reuse the file's existing repository/database setup helper):

```swift
@Test func `allReaderPreferences returns every stored row`() async throws {
    // Arrange: two score items, one preferences row each (one all-nil, one with staffSize 18), via
    // saveScoreItem + saveReaderPreferences.
    // Act:
    let rows = try await repository.allReaderPreferences()
    // Assert:
    #expect(rows.count == 2)
    #expect(rows.contains { $0.staffSize == 18 })
}
```

(Flesh out the arrange section with the file's existing fixtures — the shape above is the contract.)

- [ ] **Step 2: Run to verify failure** — Task 5 Step 4 command with `-only-testing:InfrastructureTests/LiveScoreLibraryRepositoryTests`. Expected: compile failure (`allReaderPreferences` not found).

- [ ] **Step 3: Implement**

Protocol (next to the existing reader-preferences pair):

```swift
/// Every stored per-score Reader preferences row, in no particular order. Used once per launch by the
/// `score_prefs` analytics snapshot; callers filter to live score items themselves.
func allReaderPreferences() async throws -> [ReaderPreferences]
```

`LiveScoreLibraryRepository` (next to `loadReaderPreferences`, same error-mapping shape):

```swift
public func allReaderPreferences() async throws -> [ReaderPreferences] {
    do {
        let records = try await database.pool.read { db in
            try ReaderPreferencesRecord.fetchAll(db)
        }
        return try records.map { try $0.toDomain() }
    } catch {
        throw DomainError.persistenceFailed(reason: "\(error)")
    }
}
```

Every fake listed above gets the minimal conformance. For fakes with a `storedReaderPreferences` dictionary:

```swift
func allReaderPreferences() throws -> [ReaderPreferences] {
    Array(storedReaderPreferences.values)
}
```

For fakes without one (Editor, ImportExport, Domain's `StorageProtocolsTests`, `FailingRepository` — the latter throws like its other methods): return `[]` / throw, matching each file's house pattern.

- [ ] **Step 4: Verify every whole package**

Run and require `** TEST SUCCEEDED **` from each package dir:

```bash
# Packages/Domain
xcodebuild test -scheme Domain -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation
# Packages/Infrastructure
xcodebuild test -scheme Infrastructure-Package -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation
# Packages/Features/Library
xcodebuild test -scheme Library -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation
# Packages/Features/Editor
xcodebuild test -scheme Editor -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation
# Packages/Features/ImportExport
xcodebuild test -scheme ImportExport-Package -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation
```

- [ ] **Step 5: Commit**

```bash
git -C <worktree> add Packages/Domain Packages/Infrastructure Packages/Features/Library Packages/Features/Editor Packages/Features/ImportExport
git -C <worktree> commit -m "feat(domain): add ScoreLibraryRepository.allReaderPreferences for the launch prefs snapshot"
```

---

### Task 7: Reader — Optional-carrying sub-models + the clef-only regression test

Depends on: Tasks 1–2, 6. **This task closes the plan's main correctness risk (§2): `wireLayoutModel`'s shared `onChange` writes `staffSize`, `honorLayoutBreaks`, `hiddenStaves`, and `staffClefOverrides` together — if any sub-model held a resolved value, a clef-only change would write `14.0` back into `prefs.staffSize` and permanently mark it touched. The regression test is written FIRST and must be observed failing (as a compile error against the old model, then as an assertion if the wiring is wrong) before this task is done.**

**Files:**
- Modify: `Packages/Features/Reader/Sources/Reader/LayoutSettingsModel.swift`
- Modify: `Packages/Features/Reader/Sources/Reader/MasterVolumeModel.swift`
- Modify: `Packages/Features/Reader/Sources/Reader/TransposeModel.swift`
- Modify: `Packages/Features/Reader/Sources/Reader/ReaderPreferencesStore.swift`
- Modify: `Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift`
- Modify: `Packages/Features/Reader/Sources/Reader/ReaderViewModel+SessionWiring.swift`
- Modify: `Packages/Features/Reader/Sources/Reader/PlaybackPreferences+Initial.swift`
- Modify: `Packages/Features/Reader/Sources/Reader/Screens/VisualInspectorScreen.swift`
- Modify: `Packages/Features/Reader/Sources/Reader/Screens/ScoreContentView.swift`
- Modify: `Packages/Features/Reader/Sources/Reader/PreviewSupport.swift`
- Modify: `Packages/Features/Reader/Tests/ReaderTests/Fakes/FakeScoreLibraryRepository.swift`
- Modify: `Packages/Features/Reader/Tests/ReaderTests/ReaderPreferencesStoreSeedTests.swift`
- Test: `Packages/Features/Reader/Tests/ReaderTests/ReaderUntouchedPreferencesTests.swift` (create)

**Interfaces:**
- Consumes: `ReaderPreferences` Optionals, `effective*`, `reconcilingAuthoredHidden(stored:authoredHiddenStaves:scoreItemID:)`, `allReaderPreferences()`.
- Produces (Task 8's tests rely on these):
  - `LayoutSettingsModel`: `private(set) var staffSize: Double?`, `private(set) var honorLayoutBreaks: Bool?`, `@ObservationIgnored var defaultStaffSize: Double = 14`, `var effectiveStaffSize: Double`, `var effectiveHonorLayoutBreaks: Bool`.
  - `MasterVolumeModel`: `private(set) var value: Double?`, `displayValue` resolves `liveValue ?? value ?? ReaderPreferences.defaultMasterVolume`.
  - `TransposeModel`: `private(set) var semitones: Int?`, `var effectiveSemitones: Int`.
  - `ReaderPreferencesStore.init(scoreItemID:repository:)` (the `defaultStaffSize:` parameter is removed).

- [ ] **Step 1: Write the failing regression test**

Create `ReaderUntouchedPreferencesTests.swift`. Build the `ReaderViewModel` the way `ReaderViewModelMasterVolumeTests.swift` does (read it first and reuse its `makeViewModel`/fixture helpers — do not invent a new harness):

```swift
import Domain
import Foundation
@testable import Reader
import SheetMusicCore
import Testing

/// The §2 regression: `wireLayoutModel`'s shared `onChange` persists staffSize, honorLayoutBreaks, hiddenStaves, and
/// staffClefOverrides together. Changing ONE of them must not materialize values for the others out of their
/// untouched (`nil`) state.
@MainActor
struct ReaderUntouchedPreferencesTests {
    @Test func `changing only a clef override leaves staff size and breaks nil`() async throws {
        let repo = FakeScoreLibraryRepository()
        let vm = makeViewModel(repository: repo)   // per ReaderViewModelMasterVolumeTests' helper
        await vm.loadOrSeedPreferences()
        await vm.layoutModel.setClefOverride("F", for: StaffAddress(partIndex: 0, staffIndexInPart: 0))
        let saved = try #require(repo.savedReaderPreferences.last)
        #expect(saved.staffClefOverrides.count == 1)
        #expect(saved.staffSize == nil)
        #expect(saved.honorLayoutBreaks == nil)
    }

    @Test func `toggling only a staff leaves staff size and breaks nil`() async throws {
        let repo = FakeScoreLibraryRepository()
        let vm = makeViewModel(repository: repo)
        await vm.loadOrSeedPreferences()
        await vm.layoutModel.toggleStaff(StaffAddress(partIndex: 0, staffIndexInPart: 0))
        let saved = try #require(repo.savedReaderPreferences.last)
        #expect(saved.hiddenStaves.count == 1)
        #expect(saved.staffSize == nil)
        #expect(saved.honorLayoutBreaks == nil)
    }
}
```

- [ ] **Step 2: Run to verify failure**

From `Packages/Features/Reader`:

```bash
xcodebuild test -scheme Reader \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -skipPackagePluginValidation \
  -only-testing:ReaderTests/ReaderUntouchedPreferencesTests
```

Expected: compile failure (the package is still broken from Task 1; the models still hold resolved values). This is the required failing state.

- [ ] **Step 3: Implement the sub-model split**

**`LayoutSettingsModel.swift`:**

```swift
private(set) var staffSize: Double?
private(set) var honorLayoutBreaks: Bool?
/// Injected by `ReaderViewModel` at wiring time — the screen-level default that will become device-class-dependent.
@ObservationIgnored var defaultStaffSize: Double = 14

var effectiveStaffSize: Double { staffSize ?? defaultStaffSize }
var effectiveHonorLayoutBreaks: Bool { honorLayoutBreaks ?? ReaderPreferences.defaultHonorLayoutBreaks }

func sync(from prefs: ReaderPreferences) {
    staffSize = prefs.staffSize          // raw Optional — resolving here would mark every score touched on save
    honorLayoutBreaks = prefs.honorLayoutBreaks
    hiddenStaves = prefs.hiddenStaves
    staffClefOverrides = prefs.staffClefOverrides
}

func incrementStaffSize() async {
    let next = min(effectiveStaffSize + 1, ReaderPreferences.maxStaffSize)
    guard next != effectiveStaffSize else { return }
    staffSize = next
    await onChange?()
}
// decrementStaffSize mirrors with max(effectiveStaffSize - 1, ReaderPreferences.minStaffSize).

func setHonorLayoutBreaks(_ value: Bool) async {
    guard value != effectiveHonorLayoutBreaks else { return }
    honorLayoutBreaks = value
    await onChange?()
}
```

Delete the old `= 14` / `= false` initial values (the incoherent `honorLayoutBreaks = false` initial disappears — `nil` resolves correctly before the first `sync`).

**`MasterVolumeModel.swift`:**

```swift
private(set) var value: Double?
var displayValue: Double { liveValue ?? value ?? ReaderPreferences.defaultMasterVolume }
func sync(from prefs: ReaderPreferences) { value = prefs.masterVolume }
// commitValue: unchanged clamp; `value = clamped` now stores `.some` — an explicit choice is an explicit choice,
// even when it lands exactly on 1.0.
// resetValue: `value = nil` (reset means "follow the default"); still forwards
// ReaderPreferences.defaultMasterVolume to the engine.
```

**`TransposeModel.swift`:**

```swift
private(set) var semitones: Int?
var effectiveSemitones: Int { semitones ?? ReaderPreferences.defaultTransposeSemitones }
func sync(from prefs: ReaderPreferences) { semitones = prefs.transposeSemitones }

func setSemitones(_ value: Int) async {
    let clamped = max(-7, min(7, value))
    guard clamped != effectiveSemitones else { return }
    semitones = clamped
    await controllerProvider()?.setTranspose(semitones: clamped)
    await onChange?()
}

func reset() async {
    guard semitones != nil else { return }
    semitones = nil
    await controllerProvider()?.setTranspose(semitones: ReaderPreferences.defaultTransposeSemitones)
    await onChange?()
}
```

- [ ] **Step 4: Adapt the store, view model, and read sites**

- `ReaderPreferencesStore`: delete the `defaultStaffSize` property and init parameter; placeholder becomes `ReaderPreferences(scoreItemID: scoreItemID, hiddenStaves: [])`; `loadOrSeed` calls the three-argument `reconcilingAuthoredHidden` (no `defaultStaffSize:`); `mutate`'s re-seat init call adds `authoredHiddenStaves: copy.authoredHiddenStaves,` after `hiddenStaves:`.
- `ReaderViewModel`: both `ReaderPreferencesStore(...)` constructions (init and `advance(to:)`) drop `defaultStaffSize:`; `wireLayoutModel()` adds `layoutModel.defaultStaffSize = defaultStaffSize` as its first line (the VM keeps its own `defaultStaffSize`); the `onChange` bodies stay byte-identical — they now copy raw Optionals. Reads move to effective accessors: `recomputeVisibleScore()`'s `transposeModel.semitones` → `transposeModel.effectiveSemitones`; `loadOrSeedPreferences()`'s `lastTransposeSemitones = transposeModel.semitones` → `.effectiveSemitones`.
- `ReaderViewModel+SessionWiring.swift` `currentPiPLayoutSnapshot()`: `layoutModel.staffSize` → `layoutModel.effectiveStaffSize`, `transposeModel.semitones` → `transposeModel.effectiveSemitones`.
- `PlaybackPreferences+Initial.swift`: `masterVolume: readerPreferences.effectiveMasterVolume`, `transposeSemitones: readerPreferences.effectiveTransposeSemitones` (sits beside the existing `tempoMultiplier ?? 1.0` — `PlaybackPreferences` stays resolved-by-design).
- `VisualInspectorScreen.swift`: the honor-breaks binding `get` (line ~110) → `layoutModel.effectiveHonorLayoutBreaks`; the staff-size binding `get`/`current` (lines ~168–171) and the accessibility label (line ~186) → `layoutModel.effectiveStaffSize`.
- `ScoreContentView.swift`: all three `staffSize:`/`honorLayoutBreaks:` pass-throughs (lines ~94–95, 110–111, 125–126) → `effectiveStaffSize` / `effectiveHonorLayoutBreaks`.
- `PreviewSupport.swift`: both fake repositories gain `allReaderPreferences()` (return `[]` / stored values per class); fix any `ReaderPreferences(...)` fixture the compiler flags.
- `ReaderTests/Fakes/FakeScoreLibraryRepository.swift`: add `func allReaderPreferences() throws -> [ReaderPreferences] { Array(storedReaderPreferences.values) }`.
- `ReaderPreferencesStoreSeedTests.swift`: `makeStore` drops `defaultStaffSize:`. Two expectation updates: `seeds authored hidden when no row exists` still persists (authored non-empty); `respects user reveal once seeded` NOW persists once — the §6 refresh rule records the score's authored set on a row whose stored `authoredHiddenStaves` (empty) differs. Change `#expect(repo.savedReaderPreferences.isEmpty)` to assert one save whose `hiddenStaves` is still empty and whose `authoredHiddenStaves` equals the authored set.

- [ ] **Step 5: Run the full Reader suite**

From `Packages/Features/Reader`:

```bash
xcodebuild test -scheme Reader \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -skipPackagePluginValidation
```

Expected: `** TEST SUCCEEDED **`, including `ReaderUntouchedPreferencesTests`. Fix remaining compile fallout the build surfaces (other Reader tests constructing `ReaderPreferences`/store fixtures).

- [ ] **Step 6: Commit**

```bash
git -C <worktree> add Packages/Features/Reader
git -C <worktree> commit -m "feat(reader): carry untouched preference state through the sub-models"
```

---

### Task 8: Reader — untouched-semantics behavior tests

Depends on: Task 7. Pure test additions pinning the §2/§5 forward semantics.

**Files:**
- Modify: `Packages/Features/Reader/Tests/ReaderTests/ReaderUntouchedPreferencesTests.swift`
- Modify: `Packages/Features/Reader/Tests/ReaderTests/ReaderPreferencesStoreSeedTests.swift`

- [ ] **Step 1: Write the tests**

Add to `ReaderUntouchedPreferencesTests` (same harness as Task 7):

```swift
@Test func `first staff size step from untouched persists default plus one`() async throws {
    let repo = FakeScoreLibraryRepository()
    let vm = makeViewModel(repository: repo)   // vm.defaultStaffSize is 14 in the test harness
    await vm.loadOrSeedPreferences()
    await vm.layoutModel.incrementStaffSize()
    let saved = try #require(repo.savedReaderPreferences.last)
    #expect(saved.staffSize == 15)
}

@Test func `master volume reset persists nil and commit of unity persists some`() async throws {
    let repo = FakeScoreLibraryRepository()
    let vm = makeViewModel(repository: repo)
    await vm.loadOrSeedPreferences()
    await vm.masterVolumeModel.commitValue(1.0)
    #expect(try #require(repo.savedReaderPreferences.last).masterVolume == 1.0)
    await vm.masterVolumeModel.resetValue()
    #expect(try #require(repo.savedReaderPreferences.last).masterVolume == nil)
}

@Test func `transpose reset persists nil`() async throws {
    let repo = FakeScoreLibraryRepository()
    let vm = makeViewModel(repository: repo)
    await vm.loadOrSeedPreferences()
    await vm.transposeModel.setSemitones(3)
    #expect(try #require(repo.savedReaderPreferences.last).transposeSemitones == 3)
    await vm.transposeModel.reset()
    #expect(try #require(repo.savedReaderPreferences.last).transposeSemitones == nil)
}

@Test func `honor breaks explicit true after false persists some true`() async throws {
    let repo = FakeScoreLibraryRepository()
    let vm = makeViewModel(repository: repo)
    await vm.loadOrSeedPreferences()
    await vm.layoutModel.setHonorLayoutBreaks(false)
    await vm.layoutModel.setHonorLayoutBreaks(true)
    #expect(try #require(repo.savedReaderPreferences.last).honorLayoutBreaks == true)
}
```

Add to `ReaderPreferencesStoreSeedTests`:

```swift
@Test func `loadOrSeed with no row and no authored staves performs no save`() async {
    let repo = FakeScoreLibraryRepository()
    _ = await makeStore(repo).loadOrSeed(authoredHiddenStaves: [])
    #expect(repo.savedReaderPreferences.isEmpty)
}
```

- [ ] **Step 2: Run the new tests** — Task 7 Step 5 command with `-only-testing:ReaderTests/ReaderUntouchedPreferencesTests -only-testing:ReaderTests/ReaderPreferencesStoreSeedTests`. Expected: PASS (Task 7 already implemented the behavior; if any fails, the implementation is wrong — fix Task 7's files, not the test).

- [ ] **Step 3: Run the full Reader suite** — Task 7 Step 5 command. Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git -C <worktree> add Packages/Features/Reader
git -C <worktree> commit -m "test(reader): pin untouched-vs-explicit persistence semantics"
```

---

### Task 9: App — emit `score_prefs` at launch

Depends on: Tasks 4, 6. **`pushAnalyticsSnapshot` is currently synchronous (`App/AppBootstrap.swift:170`); the repository fetch makes it async — this task owns that plumbing.**

**Files:**
- Modify: `App/AppBootstrap.swift`

**Interfaces:**
- Consumes: `AnalyticsEvent.scorePrefsEvents(allPreferences:liveScoreItemIDs:screenWidthPt:)`, `repository.allReaderPreferences()`.

- [ ] **Step 1: Implement**

All in `AppBootstrap.swift` (no new file, so no `xcodegen generate` needed). Add `import UIKit`.

1. `private func pushAnalyticsSnapshot(repository: LiveScoreLibraryRepository)` becomes `async`; the call site in `finishStartup` becomes `await pushAnalyticsSnapshot(repository: repository)`.
2. At the end of `pushAnalyticsSnapshot` (after the `settings_snapshot` log — snapshot order: library, settings, then score_prefs):

```swift
// One event per changed score (spec 2026-08-05). Fetch failure degrades to "no events" — same
// best-effort stance as the surrounding snapshots. Filtering to live items keeps the numerator
// aligned with library_snapshot.score_count_total.
let allPrefs = (try? await repository.allReaderPreferences()) ?? []
let liveIDs = Set(repository.scoreItems.map(\.id))
for event in AnalyticsEvent.scorePrefsEvents(
    allPreferences: allPrefs,
    liveScoreItemIDs: liveIDs,
    screenWidthPt: Self.effectiveWindowWidthPt(),
) {
    analytics.log(event)
}
```

3. Width measurement (App owns the window scene; Domain owns the bucketing):

```swift
/// Effective app-window width in points at emission time — Split View / Stage Manager narrow it below the screen
/// width, which is exactly the layout-relevant fact. Falls back to the screen bounds before a key window exists.
private static func effectiveWindowWidthPt() -> Double {
    let scene = UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .first
    let window = scene?.windows.first(where: \.isKeyWindow) ?? scene?.windows.first
    if let window { return window.bounds.width }
    return scene?.screen.bounds.width ?? 0
}
```

(A width of 0 buckets to 320 — acceptable degenerate case for a headless launch.)

- [ ] **Step 2: Build the app and run the app-level tests**

From the repo root (run `xcodegen generate` first if `Folino.xcodeproj` does not exist in the worktree):

```bash
xcodebuild -project Folino.xcodeproj -scheme Folino \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -skipPackagePluginValidation \
  build
```

Expected: `** BUILD SUCCEEDED **`. The emission logic itself is fully covered by Task 4's Domain tests; this task is wiring only. Do not launch the Simulator (memory `feedback_no_simulator_launch`).

- [ ] **Step 3: Commit**

```bash
git -C <worktree> add App/AppBootstrap.swift
git -C <worktree> commit -m "feat(app): emit score_prefs launch snapshots behind the consent gate"
```

---

### Task 10: Android — bridge + reducer carry the Optionals

Depends on: Tasks 1–3. Runs on the macOS host (`FolinoLibraryJNI` has no SwiftLint plugin, so `swift test` is allowed here — the ONE exception to the xcodebuild rule).

**Files:**
- Modify: `Packages/Features/Library/Sources/FolinoLibraryJNI/ReaderPreferencesReducer.swift`
- Modify: `Packages/Features/Library/Sources/FolinoLibraryJNI/ReaderPreferencesBridge.swift`
- Test: `Packages/Features/Library/Tests/FolinoLibraryJNITests/ReaderPreferencesReducerTests.swift` (extend)

**Interfaces:**
- Consumes: `ReaderPreferences` Optionals + `authoredHiddenStaves` + `effective*` + three-argument `reconcilingAuthoredHidden`.
- Produces: unchanged wire surface — `ReaderPreferencesStateWire` stays a resolved scalar projection; Compose/Kotlin see no change.

- [ ] **Step 1: Write the failing tests**

Extend `ReaderPreferencesReducerTests.swift`:

```swift
@Test func `reseat carries nil scalars and provenance through`() {
    var p = ReaderPreferences(scoreItemID: ScoreItemID(), hiddenStaves: [])
    p.authoredHiddenStaves = [StaffAddress(partIndex: 1, staffIndexInPart: 0)]
    p.hasSeededAuthoredVisibility = true
    let reseated = ReaderPreferencesReducer.setClef(p, part: 0, staff: 0, rawType: "F")
    #expect(reseated.staffSize == nil)
    #expect(reseated.honorLayoutBreaks == nil)
    #expect(reseated.masterVolume == nil)
    #expect(reseated.transposeSemitones == nil)
    #expect(reseated.authoredHiddenStaves == p.authoredHiddenStaves)
    #expect(reseated.hasSeededAuthoredVisibility)
}

@Test func `kotlin setters still write explicit values`() {
    let p = ReaderPreferences(scoreItemID: ScoreItemID(), hiddenStaves: [])
    #expect(ReaderPreferencesReducer.setStaffSize(p, 18).staffSize == 18)
    #expect(ReaderPreferencesReducer.setMasterVolume(p, 1.0).masterVolume == 1.0)
    #expect(ReaderPreferencesReducer.setTranspose(p, 0).transposeSemitones == 0)
}
```

- [ ] **Step 2: Run to verify failure**

```bash
FOLINO_ANDROID=1 xcrun swift test \
  --package-path <worktree>/Packages/Features/Library \
  --filter ReaderPreferencesReducerTests
```

Expected: FAIL — `reseat` currently omits `authoredHiddenStaves` and `hasSeededAuthoredVisibility` from the re-seat init (the seeded-flag drop is a pre-existing latent bug this task fixes; with the new provenance field it would break the refresh rule outright). Compile errors from the Optional change count as the failing state.

- [ ] **Step 3: Implement**

**`ReaderPreferencesReducer.swift`** — `reseat` passes EVERY field through:

```swift
private static func reseat(_ p: ReaderPreferences) -> ReaderPreferences {
    ReaderPreferences(
        id: p.id, scoreItemID: p.scoreItemID, staffSize: p.staffSize,
        hiddenStaves: p.hiddenStaves, authoredHiddenStaves: p.authoredHiddenStaves,
        staffProgramOverrides: p.staffProgramOverrides,
        staffVolumeOverrides: p.staffVolumeOverrides, staffClefOverrides: p.staffClefOverrides,
        tempoMultiplier: p.tempoMultiplier, honorLayoutBreaks: p.honorLayoutBreaks,
        repeatMode: p.repeatMode, abRepeat: p.abRepeat, masterVolume: p.masterVolume,
        transposeSemitones: p.transposeSemitones, a4ReferenceHz: p.a4ReferenceHz,
        hasSeededAuthoredVisibility: p.hasSeededAuthoredVisibility,
    )
}
```

The setters need no body changes — a Kotlin-side set is always an explicit user action and keeps writing non-`nil` (assigning `Double`/`Bool`/`Int` into the Optional fields is `.some` automatically). If Android later grows reset affordances they get new `clear*` functions writing `nil`; none today.

**`ReaderPreferencesBridge.swift`:**
- New stored property `@ObservationIgnored private var openDefaultStaffSize: Double = 14` — the bridge retains the default it already receives for wire resolution.
- `open(scoreId:defaultStaffSize:)`: set `openDefaultStaffSize = defaultStaffSize`; the no-blob branch becomes `prefs = ReaderPreferences(scoreItemID: ScoreItemID(), hiddenStaves: [])` and **drops the `store.saveJSON` write** (§5 — hold the seed in memory; the first real mutation persists via `mutate`). Update the doc comment.
- `init(store:)` placeholder likewise drops `staffSize: 14`.
- `seedAuthoredHidden`: the shared call loses `defaultStaffSize:` (three arguments).
- `republish()` resolves at the wire boundary (sentinel projection unchanged for Compose):

```swift
state = ReaderPreferencesStateWire(
    staffSize: prefs.effectiveStaffSize(default: openDefaultStaffSize),
    honorLayoutBreaks: prefs.effectiveHonorLayoutBreaks,
    masterVolume: prefs.effectiveMasterVolume,
    tempoMultiplier: prefs.tempoMultiplier ?? 0,
    a4ReferenceHz: prefs.a4ReferenceHz ?? 0,
    transposeSemitones: Int32(prefs.effectiveTransposeSemitones),
    revision: revision,
)
```

- [ ] **Step 4: Run the whole host suite**

```bash
FOLINO_ANDROID=1 xcrun swift test --package-path <worktree>/Packages/Features/Library
```

Expected: all suites pass (fix compile fallout in the other JNI test files as flagged).

- [ ] **Step 5: Commit**

```bash
git -C <worktree> add Packages/Features/Library
git -C <worktree> commit -m "feat(android): carry untouched preference state through the JNI bridge and reducer"
```

---

### Task 11: Android — `AnalyticsBridge.scorePrefs` builder (one blob per call)

Depends on: Tasks 4, 10.

**Files:**
- Modify: `Packages/Features/Library/Sources/FolinoLibraryJNI/AnalyticsBridge.swift`
- Test: `Packages/Features/Library/Tests/FolinoLibraryJNITests/AnalyticsBridgeScorePrefsTests.swift` (create; mirror the existing bridge test helpers in that directory)

**Interfaces:**
- Produces: `@WireletExpose public func scorePrefs(prefsJson: String, widthDp: Double) -> AnalyticsEventWire` — an empty-`name` wire means "skip".

- [ ] **Step 1: Write the failing test**

```swift
import Domain
import Testing
@testable import FolinoLibraryJNI

struct AnalyticsBridgeScorePrefsTests {
    @Test func `changed blob builds a score_prefs wire with bucketed width`() {
        var prefs = ReaderPreferences(scoreItemID: ScoreItemID(), hiddenStaves: [])
        prefs = ReaderPreferencesReducer.setStaffSize(prefs, 18)
        let json = ReaderPreferencesReducer.encode(prefs)
        let wire = AnalyticsBridge().scorePrefs(prefsJson: json, widthDp: 507)
        #expect(wire.name == "score_prefs")
        #expect(wire.params.contains { $0.key == "staff_size" && $0.longValue == 18 })
        #expect(wire.params.contains { $0.key == "screen_width_pt" && $0.longValue == 430 })
    }

    @Test func `untouched blob and invalid json return the skip wire`() {
        let untouched = ReaderPreferencesReducer.encode(
            ReaderPreferences(scoreItemID: ScoreItemID(), hiddenStaves: []),
        )
        #expect(AnalyticsBridge().scorePrefs(prefsJson: untouched, widthDp: 430).name.isEmpty)
        #expect(AnalyticsBridge().scorePrefs(prefsJson: "not json", widthDp: 430).name.isEmpty)
    }
}
```

- [ ] **Step 2: Run to verify failure** — Task 10 Step 2 command with `--filter AnalyticsBridgeScorePrefsTests`. Expected: compile failure.

- [ ] **Step 3: Implement**

Add to `AnalyticsBridge` under a `// MARK: Launch snapshots` sibling:

```swift
/// One `score_prefs` wire event from ONE stored preferences JSON blob. Kotlin's launch path enumerates its live
/// blobs and relays each through this builder, skipping empty-named results (all-untouched rows and undecodable
/// blobs). Event name, the presence-means-changed rule, and every bucket boundary live in the shared Domain
/// factory — Kotlin authors no wire string. `widthDp` is Android's point-equivalent width; analysis never compares
/// widths across platforms without the auto-attached `platform`. Deliberately a single-`String` argument per call:
/// wirelet's `[String]` method-arg support is unreleased.
@WireletExpose
public func scorePrefs(prefsJson: String, widthDp: Double) -> AnalyticsEventWire {
    guard let prefs = ReaderPreferencesReducer.decode(prefsJson),
          let event = AnalyticsEvent.scorePrefs(prefs, screenWidthPt: widthDp)
    else { return AnalyticsEventWire(name: "", params: []) }
    return Self.encode(event)
}
```

(Adjust the empty-wire construction to `AnalyticsEventWire`'s real memberwise init if it differs — check the file's `encode`.)

- [ ] **Step 4: Run the whole host suite** — Task 10 Step 4 command. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git -C <worktree> add Packages/Features/Library
git -C <worktree> commit -m "feat(android): relay score_prefs through the analytics bridge one blob at a time"
```

---

### Task 12: Android — Kotlin launch enumeration

Depends on: Task 11. The only Kotlin written is enumeration/relay plumbing — no event logic (parity rule).

**Files:**
- Modify: `Android/FolinoLibraryAndroid/src/main/kotlin/com/keynumber/folino/library/RoomLibraryStore.kt`
- Modify: `Android/app/src/main/kotlin/com/keynumber/folino/MainActivity.kt`

- [ ] **Step 1: Implement the DAO + store accessor**

In `RoomLibraryStore.kt`, extend `ReaderPreferencesDao` (check `ScoreRecordDao`'s existing queries for the live-row convention — `deleted_at` is a `Double` sentinel where `0.0` == live; mirror whatever comparison the existing live queries use):

```kotlin
@Query(
    "SELECT json FROM reader_preferences " +
        "INNER JOIN score_records ON score_records.id = reader_preferences.score_id " +
        "WHERE score_records.deleted_at = 0",
)
fun loadAllLive(): List<String>
```

And on `RoomLibraryStore`:

```kotlin
/** Stored preferences blobs for live (non-trashed) scores — the launch `score_prefs` snapshot's input. */
fun loadAllLiveReaderPreferencesJson(): List<String> = db.readerPreferencesDao().loadAllLive()
```

- [ ] **Step 2: Relay at launch**

In `MainActivity.kt`, inside the existing `LaunchedEffect(Unit)` that logs `librarySnapshot` + `settingsSnapshot` (~line 307), after those two logs (reach the `RoomLibraryStore` instance the same way that block's collaborators are reached — it is constructed in `MainActivity`; follow the existing wiring):

```kotlin
// One score_prefs per changed score, mirroring iOS AppBootstrap. The bridge decodes each blob with the
// shared Domain factory; an empty name means "untouched or undecodable — skip". One call per blob:
// wirelet's [String] args are unreleased.
val widthDp = resources.configuration.screenWidthDp.toDouble()
store.loadAllLiveReaderPreferencesJson().forEach { json ->
    val wire = AndroidAnalytics.bridge.scorePrefs(json, widthDp)
    if (wire.name.isNotEmpty()) AndroidAnalytics.log(wire)
}
```

(If the block is a composable context, `LocalConfiguration.current.screenWidthDp` is the equivalent — match the file's style.)

- [ ] **Step 3: Verify — full Android build**

The bridge's `@WireletExpose` surface changed in Tasks 10–11, so ordering matters (memory `project_android_library_wirelet_resolved_drift`): resolve → gradle wirelet codegen → rebuild `.so`s → assemble. From the worktree root:

```bash
FOLINO_ANDROID=1 xcrun swift package resolve --package-path <worktree>/Packages/Features/Library
```

```bash
env PATH="/Library/Developer/Toolchains/swift-6.3.3-RELEASE.xctoolchain/usr/bin:$PATH" FOLINO_ANDROID_ABIS=arm64-v8a <worktree>/Scripts/android-build-library-libs.sh
```

```bash
env -C <worktree>/Android ./gradlew :app:assembleDebug --console=plain
```

Expected: `BUILD SUCCESSFUL`. If gradle codegen ordering bites (missing `JNI_OnLoad` symptoms), consult the memory notes referenced in CLAUDE.md's "Android builds (pointer)". If a Pixel device is reachable over adb, also install + launch and confirm no crash on the list screen (memory `feedback_android_install_launch`); otherwise flag device verification for the user in the task report.

- [ ] **Step 4: Commit**

```bash
git -C <worktree> add Android
git -C <worktree> commit -m "feat(android): enumerate live preference blobs into score_prefs at launch"
```

---

### Task 13: Final — full iOS build + test sweep

Depends on: all previous tasks.

- [ ] **Step 1: Regenerate the project if needed**

From the worktree root: if `Folino.xcodeproj` is absent, run `xcodegen generate`.

- [ ] **Step 2: Run the full app suite**

```bash
xcodebuild -project Folino.xcodeproj -scheme Folino \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -skipPackagePluginValidation \
  test
```

- [ ] **Step 3: Re-run every package suite touched by this plan**

Task 6 Step 4's five commands, plus Task 7 Step 5 (Reader) and Task 10 Step 4 (host JNI).

**Green looks like:** every command ends `** TEST SUCCEEDED **` (host `swift test`: `Test run with N tests passed`), including the new suites `ReaderPreferencesUntouchedTests`, `ReaderPreferencesCodableVersionTests`, `ScorePrefsEventTests`, `MigrationV16Tests`, `ReaderUntouchedPreferencesTests`, `AnalyticsBridgeScorePrefsTests`, the updated `AuthoredVisibilitySeedTests` / `ReaderPreferencesStoreSeedTests`, and zero regressions in the pre-existing suites. The app `test` run also exercises the UI test target — a UI-test failure unrelated to preferences (e.g. flaky simulator) should be retried once before investigating.

- [ ] **Step 4: Commit any straggler fixes**

```bash
git -C <worktree> add -A
git -C <worktree> commit -m "test: green up the full suite for per-score prefs instrumentation"
```

(Skip the commit if the tree is clean.)

---

## Out of scope (from the spec — do NOT implement)

- Any score identifier in `score_prefs`; per-change events; the actual iPad staff-size default (`ReaderRootScreen.swift:166` keeps its `14` constant and its TBD comment); GA4 custom-dimension registration; dropping the legacy `repeat_mode` column / `repeatMode` field; an `ab_repeat` parameter; Android UI changes of any kind.
