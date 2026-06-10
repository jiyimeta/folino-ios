# Android Settings Persistence (iOS Scope Parity) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Persist every Android Reader/Settings control at the same scope iOS uses (per-score or global), reusing the shared Domain `ReaderPreferences` as the single source of truth, and add parity settings UI for two not-yet-implemented features (playlist continuation, transpose) so their values persist now and the behavior can be wired later.

**Architecture:** Per-score settings are stored as a JSON blob of the shared Domain `ReaderPreferences` (clamping lives only in its `init`), kept in a new Room `reader_preferences(score_id, json)` table reached over a new `@WireletProvided ReaderPreferencesStore` (Kotlin/Room backend, Swift policy). A new `@WireletObservable ReaderPreferencesBridge` in `FolinoReaderJNI` decodes the blob, projects typed scalar fields + small wire lists to Compose, and exposes scalar `@WireletExpose` mutators that re-normalize through `ReaderPreferences.init` and persist. Global settings stay in DataStore; only `playlistContinuationMode` is added and the inspector metronome is rebound to the existing global key.

**Tech Stack:** Swift 6.3 (Domain, FolinoLibraryJNI, swift-wirelet codegen), Kotlin + Jetpack Compose + Room + DataStore (Android), Android NDK cross-compile via `Scripts/android-build-*.sh`.

---

## COURSE CORRECTION (2026-06-10, during execution — supersedes the original module placement)

The original plan placed the wirelet bridge in **`FolinoReaderJNI`**. That target has **no swift-wirelet pipeline** (it is jextract/swift-java only), and `FolinoReaderAndroid` has **no wirelet gradle plugin** — standing the pipeline up there is high-risk new infra (pin drift, plugin ordering, jextract+wirelet coexistence). `FolinoLibraryJNI` / `FolinoLibraryAndroid` already have the **complete wirelet pipeline (pinned `ba1b8e3`) AND the Room `LibraryDatabase`**. User-approved decision: **place all new wirelet pieces in `FolinoLibraryJNI` + `FolinoLibraryAndroid`**; the **app module (`MainActivity`) constructs the controller and injects per-score values/hooks into the Reader**, mirroring the existing `installRepeatController(loadRange, persistRange, persistMode)` flow (keeps Reader decoupled, no new Reader→Library dependency).

Apply these substitutions throughout the tasks below:
- `Packages/Features/Reader/Sources/FolinoReaderJNI/…` → `Packages/Features/Library/Sources/FolinoLibraryJNI/…`
- Build/codegen script `Scripts/android-build-reader-libs.sh` → `Scripts/android-build-library-libs.sh`
- Generated Kotlin package → `com.keynumber.folino.library` (codecs/provided) and `com.keynumber.folino.library.generated` (observable view model), per `FolinoLibraryAndroid/build.gradle.kts`.
- The reducer tests (Task 4) now run on the **host** via the Library package's macOS platform: `FOLINO_ANDROID=1 xcrun swift test --package-path Packages/Features/Library --filter ReaderPreferencesReducerTests` (test target `FolinoLibraryJNITests`).
- Task 6 (`RoomReaderPreferencesStore`) implements the generated `ReaderPreferencesStore` interface; place it in `FolinoLibraryAndroid` next to `RoomLibraryStore` (direct DB access), or let `RoomLibraryStore` implement it directly.
- Task 8 controller wraps the **generated** observable view model (mirror `SoundfontController.kt`); place it where the app module can reach it.

### AB-repeat stays in its existing measure-based Room table (do NOT fold into the blob)

Domain `ABRepeatRange` is **ChordPath-based** (systemIndex/measureIndex/…), but Android's A-B loop is **measure-index-based** and is **already persisted per-score** via the existing `reader_ab_repeat` Room table + `installRepeatController(loadRange, persistRange, persistMode)`. Folding it into the shared blob would require a lossy measure↔ChordPath conversion for no behavior gain (the persisted value is equivalent either way — parity is about behavior, not storage shape). Decision: **keep `reader_ab_repeat` as-is**; the blob's Domain `abRepeat`/`repeatMode` fields stay unused on Android (same as `repeatMode`). Therefore **Task 5 does NOT drop `reader_ab_repeat`** — it only ADDS `reader_preferences`. The bridge correctly omits AB-repeat getters/setters.

---

## Reference Material (read before starting)

- Spec: `docs/superpowers/specs/2026-06-10-android-settings-persistence-design.md`
- Shared model: `Packages/Domain/Sources/Domain/Models/ReaderPreferences.swift` (all fields + clamping)
- iOS store being mirrored: `Packages/Features/Reader/Sources/Reader/ReaderPreferencesStore.swift`
- `@WireletProvided` template: `Packages/Infrastructure/Sources/FolinoSoundfontJNI/SoundfontServices.swift`
- `@WireletObservable` + `@WireletExpose` + `@WireFormat` template: `Packages/Infrastructure/Sources/FolinoSoundfontJNI/{MuseScoreGeneralAndroidStore,SoundfontWire}.swift`
- Kotlin observable controller template (Swift @Observable → Kotlin StateFlow): `Android/FolinoSoundfontAndroid/.../SoundfontController.kt` and its use at `SettingsScreen.kt:62-63`
- Kotlin `@WireletProvided` impl template: `Android/FolinoSoundfontAndroid/.../SoundfontPrefsStoreImpl.kt`
- Room table + side-channel template: `Android/FolinoLibraryAndroid/.../RoomLibraryStore.kt` (`reader_ab_repeat`, `loadAbRepeat`/`saveAbRepeat`)
- Wire structs template: `Android/FolinoReaderAndroid/.../LayoutOptions.kt` (`HiddenStaffWire`, `ClefOverrideWire`, `StaffAddress`)
- Reader screen wiring: `Android/FolinoReaderAndroid/.../ReaderAudioViewModel.kt`, `.../PlaybackInspectorSheet.kt`, `.../DisplayInspectorSheet.kt`, app `MainActivity.kt` (~lines 480-540)
- Build scripts: `Scripts/android-build-reader-libs.sh`, `Scripts/android-build-library-libs.sh`

## Critical Build-Order Rules (from prior Android learnings)

1. **Wirelet codegen must run before staging the `.so`.** A fresh worktree / new wire surface needs `swift package resolve` + the `generateWirelet*` plugin to run; then `android-build-reader-libs.sh` builds the `.so` and copies the swift-java Java bindings. Skipping codegen → `UnsatisfiedLinkError` / missing JNI symbols at launch.
2. **After changing the wire surface, ALWAYS regenerate the `.so` from worktree source** (don't copy a primary-checkout `.so` — schema drift causes decode underflow / `JNI_OnLoad JNI_ERR`).
3. **Wirelet codegen friction:** keep method args **scalar or String** (no dictionaries; `Int` works as method args here but avoid bare-`Bool` *observable stored properties* — fold into a `@WireFormat` struct like `SoundfontStateWire`). New `@WireFormat` structs mirror the proven `HiddenStaffWire` shape.
4. **Room is pre-release v1, destructive reset** (`fallbackToDestructiveMigration`). Adding/removing a table = bump `LibraryDatabase` schema is unnecessary (version stays 1); a clean reinstall or `pm clear` resets the DB.
5. Android verification = `installDebug` + `adb shell` launch on the Claude-started **emulator** (`ANDROID_SERIAL=emulator-5554`); never disconnect the physical Pixel.

---

## Worktree Setup (do first, at execution time)

- [ ] **Create an isolated worktree from local main** (per `superpowers:using-git-worktrees` + repo convention `feedback_worktree_for_folino_work`):

Use the EnterWorktree tool with base = local `main` HEAD, branch `android-settings-persistence`. Then symlink the gitignored config + soundfont so Android/xcodegen don't prompt:

```bash
ln -s /Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/Config/Local.xcconfig <worktree>/Config/Local.xcconfig
```

(Android jniLibs/java-generated will be regenerated by the build scripts, so no copy needed — but the first Reader build MUST run codegen, see Build-Order Rule 1.)

---

# Phase 1 — Per-score persistence infrastructure + migrate existing settings

## Task 1: Confirm Domain `ReaderPreferences` JSON round-trip (no code change expected)

**Files:**
- Test: `Packages/Domain/Tests/DomainTests/Models/ReaderPreferencesTests.swift`

- [ ] **Step 1: Add a full-field JSON round-trip test** (the Android blob relies on this exact encoding). Append to the existing suite:

```swift
@Test func fullFieldJSONRoundTripPreservesEverything() throws {
    let original = ReaderPreferences(
        scoreItemID: ScoreItemID(),
        staffSize: 17,
        hiddenStaves: [StaffAddress(partIndex: 0, staffIndexInPart: 1)],
        staffProgramOverrides: [StaffAddress(partIndex: 0, staffIndexInPart: 0): 40],
        staffVolumeOverrides: [StaffAddress(partIndex: 1, staffIndexInPart: 0): 0.5],
        staffClefOverrides: [StaffAddress(partIndex: 0, staffIndexInPart: 0): "F"],
        tempoMultiplier: 1.5,
        honorLayoutBreaks: false,
        repeatMode: .off,
        abRepeat: ABRepeatRange(startMeasure: 2, endMeasure: 5),
        masterVolume: 1.2,
        transposeSemitones: 3,
        a4ReferenceHz: 432,
    )
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(ReaderPreferences.self, from: data)
    #expect(decoded == original)
}
```

- [ ] **Step 2: Run the Domain test suite**

Run: `cd Packages/Domain && swift test --filter ReaderPreferencesTests`
Expected: PASS (confirms the encoding the Android blob depends on). If `ABRepeatRange`'s member labels differ, fix the test to match the type — do not change the type.

- [ ] **Step 3: Commit**

```bash
git add Packages/Domain/Tests/DomainTests/Models/ReaderPreferencesTests.swift
git commit -m "test(domain): full-field ReaderPreferences JSON round-trip"
```

## Task 2: New `@WireletProvided ReaderPreferencesStore` (Swift declaration)

**Files:**
- Create: `Packages/Features/Reader/Sources/FolinoReaderJNI/ReaderPreferencesStoreProtocol.swift`

- [ ] **Step 1: Declare the Kotlin-backed persistence protocol** (mirrors `SoundfontPrefsStore`):

```swift
import WireletProvided

/// Per-score Reader-preferences persistence, *implemented in Kotlin* (Room
/// `reader_preferences` table) and injected into `ReaderPreferencesBridge` over JNI.
///
/// Rule-free: it stores/returns the opaque JSON blob the Swift bridge hands it.
/// All shape + clamping lives in the shared Domain `ReaderPreferences`, in
/// lockstep with iOS.
@WireletProvided
public protocol ReaderPreferencesStore {
    /// The stored JSON for `scoreId`, or `nil` if none has been saved yet.
    func loadJSON(scoreId: String) -> String?
    /// Insert or replace the stored JSON for `scoreId`.
    func saveJSON(scoreId: String, json: String)
}
```

- [ ] **Step 2: Confirm it compiles for host** (codegen/.so come later in Task 7)

Run: `cd Packages/Features/Reader && swift build --product FolinoReaderJNI 2>&1 | tail -5`
Expected: builds (host arch). If `FolinoReaderJNI` isn't host-buildable standalone, defer the compile check to Task 7's Android build and note it.

- [ ] **Step 3: Commit**

```bash
git add Packages/Features/Reader/Sources/FolinoReaderJNI/ReaderPreferencesStoreProtocol.swift
git commit -m "feat(reader-jni): @WireletProvided ReaderPreferencesStore protocol"
```

## Task 3: Wire-format structs for per-staff overrides (Swift)

**Files:**
- Create: `Packages/Features/Reader/Sources/FolinoReaderJNI/ReaderPreferencesWire.swift`

- [ ] **Step 1: Define the wire lists the bridge projects** (mirror `HiddenStaffWire`/`ClefOverrideWire` shape from `sheet-music`):

```swift
import Wirelet

/// A per-staff GM program override projected to Compose. `partIndex`/`staffIndexInPart`
/// mirror Domain `StaffAddress`; `program` is the 0…127 GM program.
@WireFormat
public struct ProgramOverrideWire: Equatable, Sendable {
    public var partIndex: Int
    public var staffIndexInPart: Int
    public var program: Int
    public init(partIndex: Int, staffIndexInPart: Int, program: Int) {
        self.partIndex = partIndex; self.staffIndexInPart = staffIndexInPart; self.program = program
    }
}

/// A per-staff volume override (0…1) projected to Compose.
@WireFormat
public struct VolumeOverrideWire: Equatable, Sendable {
    public var partIndex: Int
    public var staffIndexInPart: Int
    public var volume: Double
    public init(partIndex: Int, staffIndexInPart: Int, volume: Double) {
        self.partIndex = partIndex; self.staffIndexInPart = staffIndexInPart; self.volume = volume
    }
}

/// A hidden-staff entry projected to Compose (part/staff address).
@WireFormat
public struct HiddenStaffEntryWire: Equatable, Sendable {
    public var partIndex: Int
    public var staffIndexInPart: Int
    public init(partIndex: Int, staffIndexInPart: Int) {
        self.partIndex = partIndex; self.staffIndexInPart = staffIndexInPart
    }
}

/// A clef override entry projected to Compose (part/staff address + NotatedClef.rawType).
@WireFormat
public struct ClefOverrideEntryWire: Equatable, Sendable {
    public var partIndex: Int
    public var staffIndexInPart: Int
    public var rawType: String
    public init(partIndex: Int, staffIndexInPart: Int, rawType: String) {
        self.partIndex = partIndex; self.staffIndexInPart = staffIndexInPart; self.rawType = rawType
    }
}
```

- [ ] **Step 2: Commit**

```bash
git add Packages/Features/Reader/Sources/FolinoReaderJNI/ReaderPreferencesWire.swift
git commit -m "feat(reader-jni): wire-format structs for per-staff overrides"
```

## Task 4: `ReaderPreferencesBridge` (`@WireletObservable`) — core logic, host-testable

**Files:**
- Create: `Packages/Features/Reader/Sources/FolinoReaderJNI/ReaderPreferencesBridge.swift`
- Test: `Packages/Features/Reader/Tests/FolinoReaderJNITests/ReaderPreferencesBridgeTests.swift` (create test target if absent — see Step 0)

> **Sentinel conventions** (wirelet can't bridge `nil`): `tempoMultiplier` and `a4ReferenceHz` use `0.0` to mean "no override / inherit". The bridge maps `0.0 ↔ nil` at the boundary.

- [ ] **Step 0: Ensure a host-testable unit exists.** If `Packages/Features/Reader/Package.swift` has no test target for `FolinoReaderJNI`, add one (the JNI macros are no-ops on host; the class logic compiles). If the wirelet macros block host compilation, instead extract the pure logic into a `ReaderPreferencesReducer` enum (free functions over `ReaderPreferences`) in a host-buildable target and test THAT; the bridge then just calls the reducer. Prefer the reducer split — it keeps the testable logic off the JNI class.

- [ ] **Step 1: Write the failing reducer tests** (`ReaderPreferencesReducer` is the pure core):

```swift
import Domain
import Testing
@testable import FolinoReaderJNI   // or the reducer's module

@Suite struct ReaderPreferencesReducerTests {
    @Test func setMasterVolumeClampsAndPersistsThroughInit() {
        var prefs = ReaderPreferences(scoreItemID: ScoreItemID(), staffSize: 14, hiddenStaves: [])
        prefs = ReaderPreferencesReducer.setMasterVolume(prefs, 5.0)   // above max 3.0
        #expect(prefs.masterVolume == 3.0)
    }

    @Test func tempoZeroSentinelMeansNoOverride() {
        var prefs = ReaderPreferences(scoreItemID: ScoreItemID(), staffSize: 14, hiddenStaves: [])
        prefs = ReaderPreferencesReducer.setTempoMultiplier(prefs, 0.0)
        #expect(prefs.tempoMultiplier == nil)
        prefs = ReaderPreferencesReducer.setTempoMultiplier(prefs, 1.5)
        #expect(prefs.tempoMultiplier == 1.5)
    }

    @Test func setStaffProgramUpdatesAddressedEntryOnly() {
        var prefs = ReaderPreferences(scoreItemID: ScoreItemID(), staffSize: 14, hiddenStaves: [])
        prefs = ReaderPreferencesReducer.setStaffProgram(prefs, part: 0, staff: 1, program: 40)
        #expect(prefs.staffProgramOverrides[StaffAddress(partIndex: 0, staffIndexInPart: 1)] == 40)
    }

    @Test func setStaffHiddenTogglesMembership() {
        var prefs = ReaderPreferences(scoreItemID: ScoreItemID(), staffSize: 14, hiddenStaves: [])
        let addr = StaffAddress(partIndex: 1, staffIndexInPart: 0)
        prefs = ReaderPreferencesReducer.setStaffHidden(prefs, part: 1, staff: 0, hidden: true)
        #expect(prefs.hiddenStaves.contains(addr))
        prefs = ReaderPreferencesReducer.setStaffHidden(prefs, part: 1, staff: 0, hidden: false)
        #expect(!prefs.hiddenStaves.contains(addr))
    }

    @Test func transposeClampsToSevenSemitones() {
        var prefs = ReaderPreferences(scoreItemID: ScoreItemID(), staffSize: 14, hiddenStaves: [])
        prefs = ReaderPreferencesReducer.setTranspose(prefs, 99)
        #expect(prefs.transposeSemitones == 7)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `cd Packages/Features/Reader && swift test --filter ReaderPreferencesReducerTests`
Expected: FAIL ("cannot find 'ReaderPreferencesReducer'").

- [ ] **Step 3: Implement the reducer** (every mutator re-seats through `ReaderPreferences.init`, mirroring `ReaderPreferencesStore.mutate`):

```swift
import Domain

/// Pure, host-testable mutations over `ReaderPreferences`. Every function re-seats
/// the value through `ReaderPreferences.init` so the type's clamping always runs
/// (the same discipline as iOS `ReaderPreferencesStore.mutate`). Sentinel rule:
/// `tempo`/`a4` of `0` means "no override" → `nil`.
enum ReaderPreferencesReducer {
    private static func reseat(_ p: ReaderPreferences) -> ReaderPreferences {
        ReaderPreferences(
            id: p.id, scoreItemID: p.scoreItemID, staffSize: p.staffSize,
            hiddenStaves: p.hiddenStaves, staffProgramOverrides: p.staffProgramOverrides,
            staffVolumeOverrides: p.staffVolumeOverrides, staffClefOverrides: p.staffClefOverrides,
            tempoMultiplier: p.tempoMultiplier, honorLayoutBreaks: p.honorLayoutBreaks,
            repeatMode: p.repeatMode, abRepeat: p.abRepeat, masterVolume: p.masterVolume,
            transposeSemitones: p.transposeSemitones, a4ReferenceHz: p.a4ReferenceHz,
        )
    }

    static func setStaffSize(_ p: ReaderPreferences, _ v: Double) -> ReaderPreferences {
        var c = p; c.staffSize = v; return reseat(c)
    }
    static func setHonorLayoutBreaks(_ p: ReaderPreferences, _ v: Bool) -> ReaderPreferences {
        var c = p; c.honorLayoutBreaks = v; return reseat(c)
    }
    static func setMasterVolume(_ p: ReaderPreferences, _ v: Double) -> ReaderPreferences {
        var c = p; c.masterVolume = v; return reseat(c)
    }
    static func setTempoMultiplier(_ p: ReaderPreferences, _ v: Double) -> ReaderPreferences {
        var c = p; c.tempoMultiplier = (v == 0 ? nil : v); return reseat(c)
    }
    static func setA4ReferenceHz(_ p: ReaderPreferences, _ v: Double) -> ReaderPreferences {
        var c = p; c.a4ReferenceHz = (v == 0 ? nil : v); return reseat(c)
    }
    static func setTranspose(_ p: ReaderPreferences, _ v: Int) -> ReaderPreferences {
        var c = p; c.transposeSemitones = v; return reseat(c)
    }
    static func setStaffHidden(_ p: ReaderPreferences, part: Int, staff: Int, hidden: Bool) -> ReaderPreferences {
        var c = p
        let a = StaffAddress(partIndex: part, staffIndexInPart: staff)
        if hidden { c.hiddenStaves.insert(a) } else { c.hiddenStaves.remove(a) }
        return reseat(c)
    }
    static func setClef(_ p: ReaderPreferences, part: Int, staff: Int, rawType: String) -> ReaderPreferences {
        var c = p
        let a = StaffAddress(partIndex: part, staffIndexInPart: staff)
        if rawType.isEmpty { c.staffClefOverrides[a] = nil } else { c.staffClefOverrides[a] = rawType }
        return reseat(c)   // init drops unknown rawTypes
    }
    static func setStaffProgram(_ p: ReaderPreferences, part: Int, staff: Int, program: Int) -> ReaderPreferences {
        var c = p
        c.staffProgramOverrides[StaffAddress(partIndex: part, staffIndexInPart: staff)] = program
        return reseat(c)
    }
    static func setStaffVolume(_ p: ReaderPreferences, part: Int, staff: Int, volume: Double) -> ReaderPreferences {
        var c = p
        c.staffVolumeOverrides[StaffAddress(partIndex: part, staffIndexInPart: staff)] = volume
        return reseat(c)
    }

    static func decode(_ json: String) -> ReaderPreferences? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ReaderPreferences.self, from: data)
    }
    static func encode(_ p: ReaderPreferences) -> String {
        guard let data = try? JSONEncoder().encode(p) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `cd Packages/Features/Reader && swift test --filter ReaderPreferencesReducerTests`
Expected: PASS.

- [ ] **Step 5: Implement the `@WireletObservable` bridge** (thin shell over the reducer + store; mirror `MuseScoreGeneralAndroidStore`):

```swift
import Domain
import Observation
import WireletObservable

/// Per-score Reader-preferences bridge for Compose. Decodes the persisted blob,
/// projects typed scalar fields + small wire lists, and exposes scalar mutators
/// that re-normalize through the shared `ReaderPreferences` and persist. One
/// instance per open score; `open(scoreId:defaultStaffSize:)` (re)seeds it.
@WireletObservable
@Observable
public final class ReaderPreferencesBridge {
    @ObservationIgnored private let store: ReaderPreferencesStore
    @ObservationIgnored private var scoreId: String = ""
    @ObservationIgnored private var prefs: ReaderPreferences {
        didSet { republish() }
    }

    // Scalar projections (0 = no override / inherit for tempo + a4).
    public var staffSize: Double = 14
    public var honorLayoutBreaks: Bool = true
    public var masterVolume: Double = 1.0
    public var tempoMultiplier: Double = 0    // 0 => nil
    public var a4ReferenceHz: Double = 0      // 0 => inherit global
    public var transposeSemitones: Int = 0
    // List projections.
    public var hiddenStaves: [HiddenStaffEntryWire] = []
    public var clefOverrides: [ClefOverrideEntryWire] = []
    public var programOverrides: [ProgramOverrideWire] = []
    public var volumeOverrides: [VolumeOverrideWire] = []

    public init(store: ReaderPreferencesStore) {
        self.store = store
        prefs = ReaderPreferences(scoreItemID: ScoreItemID(), staffSize: 14, hiddenStaves: [])
    }

    @WireletExpose
    public func open(scoreId: String, defaultStaffSize: Double) {
        self.scoreId = scoreId
        if let json = store.loadJSON(scoreId: scoreId), let decoded = ReaderPreferencesReducer.decode(json) {
            prefs = decoded
        } else {
            let seeded = ReaderPreferences(
                scoreItemID: ScoreItemID(), staffSize: defaultStaffSize, hiddenStaves: [],
            )
            prefs = seeded
            persist()   // seed-through, matching iOS loadOrSeed
        }
    }

    private func mutate(_ f: (ReaderPreferences) -> ReaderPreferences) {
        prefs = f(prefs)   // didSet republishes
        persist()
    }
    private func persist() { store.saveJSON(scoreId: scoreId, json: ReaderPreferencesReducer.encode(prefs)) }

    private func republish() {
        staffSize = prefs.staffSize
        honorLayoutBreaks = prefs.honorLayoutBreaks
        masterVolume = prefs.masterVolume
        tempoMultiplier = prefs.tempoMultiplier ?? 0
        a4ReferenceHz = prefs.a4ReferenceHz ?? 0
        transposeSemitones = prefs.transposeSemitones
        hiddenStaves = prefs.hiddenStaves.map { HiddenStaffEntryWire(partIndex: $0.partIndex, staffIndexInPart: $0.staffIndexInPart) }
        clefOverrides = prefs.staffClefOverrides.map { ClefOverrideEntryWire(partIndex: $0.key.partIndex, staffIndexInPart: $0.key.staffIndexInPart, rawType: $0.value) }
        programOverrides = prefs.staffProgramOverrides.map { ProgramOverrideWire(partIndex: $0.key.partIndex, staffIndexInPart: $0.key.staffIndexInPart, program: $0.value) }
        volumeOverrides = prefs.staffVolumeOverrides.map { VolumeOverrideWire(partIndex: $0.key.partIndex, staffIndexInPart: $0.key.staffIndexInPart, volume: $0.value) }
    }

    @WireletExpose public func setStaffSize(value: Double) { mutate { ReaderPreferencesReducer.setStaffSize($0, value) } }
    @WireletExpose public func setHonorLayoutBreaks(value: Bool) { mutate { ReaderPreferencesReducer.setHonorLayoutBreaks($0, value) } }
    @WireletExpose public func setMasterVolume(value: Double) { mutate { ReaderPreferencesReducer.setMasterVolume($0, value) } }
    @WireletExpose public func setTempoMultiplier(value: Double) { mutate { ReaderPreferencesReducer.setTempoMultiplier($0, value) } }
    @WireletExpose public func setA4ReferenceHz(value: Double) { mutate { ReaderPreferencesReducer.setA4ReferenceHz($0, value) } }
    @WireletExpose public func setTranspose(value: Int) { mutate { ReaderPreferencesReducer.setTranspose($0, value) } }
    @WireletExpose public func setStaffHidden(part: Int, staff: Int, hidden: Bool) { mutate { ReaderPreferencesReducer.setStaffHidden($0, part: part, staff: staff, hidden: hidden) } }
    @WireletExpose public func setClef(part: Int, staff: Int, rawType: String) { mutate { ReaderPreferencesReducer.setClef($0, part: part, staff: staff, rawType: rawType) } }
    @WireletExpose public func setStaffProgram(part: Int, staff: Int, program: Int) { mutate { ReaderPreferencesReducer.setStaffProgram($0, part: part, staff: staff, program: program) } }
    @WireletExpose public func setStaffVolume(part: Int, staff: Int, volume: Double) { mutate { ReaderPreferencesReducer.setStaffVolume($0, part: part, staff: staff, volume: volume) } }
}
```

- [ ] **Step 6: Re-run the reducer tests** (bridge compiles for host; macros are no-ops there)

Run: `cd Packages/Features/Reader && swift test --filter ReaderPreferencesReducerTests`
Expected: PASS. If wirelet macros break host compilation, the reducer + its tests still build in their own target — keep going; the bridge is validated by the Android build in Task 7.

- [ ] **Step 7: Commit**

```bash
git add Packages/Features/Reader/Sources/FolinoReaderJNI/ReaderPreferences*.swift Packages/Features/Reader/Tests/FolinoReaderJNITests/
git commit -m "feat(reader-jni): ReaderPreferencesBridge + reducer (per-score prefs over JNI)"
```

## Task 5: Room `reader_preferences` table + store impl (Kotlin)

**Files:**
- Modify: `Android/FolinoLibraryAndroid/.../RoomLibraryStore.kt` (add entity, DAO, register in `LibraryDatabase`, side-channel methods; remove `reader_ab_repeat`)
- Test: `Android/FolinoLibraryAndroid/src/test/.../ReaderPreferencesDaoTest.kt` (or instrumented if Room needs a device)

- [ ] **Step 1: Add the entity + DAO and register them** (mirror `ReaderAbRepeatEntity`):

```kotlin
@Entity(tableName = "reader_preferences")
data class ReaderPreferencesEntity(
    @PrimaryKey @ColumnInfo(name = "score_id") val scoreId: String,
    val json: String,
)

@Dao
interface ReaderPreferencesDao {
    @Query("SELECT json FROM reader_preferences WHERE score_id = :scoreId")
    fun load(scoreId: String): String?

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    fun upsert(entity: ReaderPreferencesEntity)
}
```

Register in `LibraryDatabase`: add `ReaderPreferencesEntity::class` to `entities`, add `abstract fun readerPreferencesDao(): ReaderPreferencesDao`, and **remove** `ReaderAbRepeatEntity::class` + `readerAbRepeatDao()` (A-B range now lives in the blob). Version stays `1` (pre-release destructive reset).

- [ ] **Step 2: Replace the AB-repeat side-channel with prefs JSON methods** on `RoomLibraryStore`:

```kotlin
fun loadReaderPreferencesJSON(scoreId: String): String? =
    db.readerPreferencesDao().load(scoreId)

fun saveReaderPreferencesJSON(scoreId: String, json: String) {
    db.readerPreferencesDao().upsert(ReaderPreferencesEntity(scoreId, json))
}
```

Delete `loadAbRepeat`/`saveAbRepeat` and the `reader_ab_repeat` entity/DAO. (Callers in `MainActivity` are rewired in Task 9.)

- [ ] **Step 3: Write the DAO round-trip test**

```kotlin
@Test fun readerPreferencesRoundTrips() {
    val db = Room.inMemoryDatabaseBuilder(ctx, LibraryDatabase::class.java).allowMainThreadQueries().build()
    val dao = db.readerPreferencesDao()
    dao.upsert(ReaderPreferencesEntity("score-1", """{"masterVolume":1.2}"""))
    assertEquals("""{"masterVolume":1.2}""", dao.load("score-1"))
    assertNull(dao.load("absent"))
    db.close()
}
```

- [ ] **Step 4: Run the Kotlin test**

Run: `cd Android && ./gradlew :FolinoLibraryAndroid:testDebugUnitTest --tests "*ReaderPreferencesDaoTest*"`
Expected: PASS (use `:FolinoLibraryAndroid:connectedDebugAndroidTest` if Room requires a device runtime).

- [ ] **Step 5: Commit**

```bash
git add Android/FolinoLibraryAndroid/
git commit -m "feat(android-library): reader_preferences Room table; drop reader_ab_repeat"
```

## Task 6: Kotlin `ReaderPreferencesStore` impl (the `@WireletProvided` backend)

**Files:**
- Create: `Android/app/src/main/kotlin/com/keynumber/folino/reader/RoomReaderPreferencesStore.kt`

> The generated Kotlin interface name from Task 2 is `ReaderPreferencesStore` (jextract maps the Swift protocol). Implement it by delegating to `RoomLibraryStore` (same shared DB).

- [ ] **Step 1: Implement the interface**

```kotlin
package com.keynumber.folino.reader

import com.keynumber.folino.library.RoomLibraryStore
// import the generated ReaderPreferencesStore interface (java-generated package)

/** Kotlin backend for the Swift @WireletProvided ReaderPreferencesStore — delegates to the shared Room DB. */
class RoomReaderPreferencesStore(private val library: RoomLibraryStore) : ReaderPreferencesStore {
    override fun loadJSON(scoreId: String): String? = library.loadReaderPreferencesJSON(scoreId)
    override fun saveJSON(scoreId: String, json: String) = library.saveReaderPreferencesJSON(scoreId, json)
}
```

(Adjust the `import` for the generated interface's actual package once Task 7 produces the bindings.)

- [ ] **Step 2: Commit** (compiles after Task 7 generates the interface; commit together with Task 7 if needed)

```bash
git add Android/app/src/main/kotlin/com/keynumber/folino/reader/RoomReaderPreferencesStore.kt
git commit -m "feat(android): RoomReaderPreferencesStore (@WireletProvided backend)"
```

## Task 7: Regenerate wirelet codegen + `.so` + Java bindings for the new wire surface

**Files:**
- Generated/staged: `Android/FolinoReaderAndroid/src/main/jniLibs/**`, `Android/FolinoReaderAndroid/src/main/java-generated/**`

- [ ] **Step 1: Resolve + run wirelet codegen, then build the Reader `.so`** (Build-Order Rules 1-2). From the worktree root:

```bash
swift package resolve --package-path Packages/Features/Reader
FOLINO_ANDROID_ABIS=arm64-v8a,x86_64 Scripts/android-build-reader-libs.sh
```

Expected: `Done. libFolinoReaderJNI.so + libSwiftJava.so + runtime staged …`, and fresh `java-generated/` containing the generated `ReaderPreferencesBridge`, `ReaderPreferencesStore`, and the four `*Wire` classes.

- [ ] **Step 2: Verify the new symbols/classes exist**

Run: `ls Android/FolinoReaderAndroid/src/main/java-generated/ | rg -i "ReaderPreferences|OverrideWire|HiddenStaffEntry|ClefOverrideEntry"`
Expected: the bridge + store + wire classes are listed. If missing, codegen didn't run — re-check `swift package resolve` ran and `FOLINO_ANDROID=1` is exported by the script.

- [ ] **Step 3: Commit the regenerated artifacts**

```bash
git add Android/FolinoReaderAndroid/src/main/jniLibs Android/FolinoReaderAndroid/src/main/java-generated
git commit -m "build(android-reader): regenerate .so + bindings for ReaderPreferences bridge"
```

## Task 8: Kotlin observable controller (Swift @Observable → Compose StateFlows)

**Files:**
- Create: `Android/FolinoReaderAndroid/.../ReaderPreferencesController.kt`

> Mirror `SoundfontController.kt` (which adapts the Swift `@Observable` to Kotlin `StateFlow`s consumed via `collectAsState()`). Expose one StateFlow per projected field and pass-through methods for each `@WireletExpose` mutator.

- [ ] **Step 1: Implement the controller** following the Soundfont template exactly (same observation-subscription mechanism; substitute the `ReaderPreferencesBridge` fields). Provide:
  - `StateFlow<Double> staffSize, masterVolume, tempoMultiplier, a4ReferenceHz` and `StateFlow<Int> transposeSemitones`, `StateFlow<Boolean> honorLayoutBreaks`
  - `StateFlow<List<…Wire>> hiddenStaves, clefOverrides, programOverrides, volumeOverrides`
  - `fun open(scoreId, defaultStaffSize)`, and `setStaffSize`, `setMasterVolume`, `setTempoMultiplier`, `setA4ReferenceHz`, `setTranspose`, `setHonorLayoutBreaks`, `setStaffHidden(part,staff,hidden)`, `setClef(part,staff,raw)`, `setStaffProgram(part,staff,program)`, `setStaffVolume(part,staff,volume)` forwarding to the bridge.
  - A factory `fun create(store: ReaderPreferencesStore): ReaderPreferencesController` constructing the bridge.

- [ ] **Step 2: Build the Android module to confirm it compiles**

Run: `cd Android && ./gradlew :FolinoReaderAndroid:compileDebugKotlin`
Expected: BUILD SUCCESSFUL.

- [ ] **Step 3: Commit**

```bash
git add Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderPreferencesController.kt
git commit -m "feat(android-reader): ReaderPreferencesController (bridge → Compose StateFlows)"
```

## Task 9: Wire the bridge into the Reader load/apply flow + migrate display + playback to per-score

**Files:**
- Modify: `Android/app/.../MainActivity.kt` (~480-540: construct controller, inject store, replace AB-repeat callbacks + display DataStore flows)
- Modify: `Android/FolinoReaderAndroid/.../ReaderAudioViewModel.kt` (seed master volume/tempo/A4 from controller; persist on change; replay mixer overrides after prepare)
- Modify: `Android/FolinoReaderAndroid/.../DisplayInspectorSheet.kt` (read/write LayoutOptions from controller, not global DataStore)
- Modify: `Android/FolinoReaderAndroid/.../PlaybackInspectorSheet.kt` (mixer + master/tempo/A4 write to controller too)

- [ ] **Step 1: Construct + inject** in `MainActivity` where `RoomLibraryStore` is created: build `RoomReaderPreferencesStore(roomLibraryStore)` → `ReaderPreferencesController.create(store)`; on Reader entry call `controller.open(scoreId, defaultStaffSize = globalStaffSizeFromSettingsPrefs)`. Remove the `loadAbRange`/`persistAbRange` Room callbacks (A-B range now flows through the blob — see Step 4).

- [ ] **Step 2: Display settings → per-score.** Replace the `layoutOptionsFromPrefs(...)` source for staffSize/hiddenStaves/honorBreaks/clefOverrides with the controller's StateFlows. Keep `mode`/`collapseRests`/`showInvisible` on global DataStore (those are global per the spec). The `DisplayInspectorSheet` `onChange` handlers call `controller.setStaffSize/setHonorLayoutBreaks/setStaffHidden/setClef` instead of `prefs.setStaffSize` etc.

- [ ] **Step 3: Playback scalars → per-score.** In `ReaderAudioViewModel`, seed `_masterVolume`/`rate`/`_a4ReferenceHz` from the controller's current values on score open; in `setMasterVolume`/A4 setters and the tempo `engine.setRate` path, also call `controller.setMasterVolume/setTempoMultiplier/setA4ReferenceHz` to persist. Bind the inspector **metronome** toggle to the global `SettingsPrefs.metronome` (read via flow, write via `prefs.setMetronome`) — drop `_metronomeEnabled` as the source of truth (still push the value to the engine).

- [ ] **Step 4: Mixer overrides → per-score + replay.** Build the `staffIndex ↔ StaffAddress` map from the parts/staves descriptor (the same enumeration `ReaderViewModel.kt:159-164` uses). In `PlaybackInspectorSheet`'s `onProgram`/`onVolume`, after the live `engine.setStaff…` call, look up the row's `StaffAddress` and call `controller.setStaffProgram/setStaffVolume`. After `engine.prepare` completes (in `preparePlayback`), replay persisted `programOverrides`/`volumeOverrides`: map each `StaffAddress → staffIndex` and call `engine.setStaffProgram/setStaffVolume`; **skip** entries whose address doesn't resolve (guard for the channel-order risk). Also replay `abRepeat` via the existing repeat controller path, sourced from the blob.

- [ ] **Step 5: A-B range via blob.** Change `installRepeatController`'s `loadRange`/`persistRange` to read/write the controller's `abRepeat` (add `abRepeat` projection + `setAbRepeat(start,end)`/`clearAbRepeat()` to the bridge/controller if not already present — add them mirroring the other mutators). Mode stays in global DataStore as today.

- [ ] **Step 6: Build + install + launch on the emulator**

```bash
cd Android && ./gradlew :app:installDebug
ANDROID_SERIAL=emulator-5554 adb shell am start -n com.KeyNumber.Folino/.MainActivity
```

Expected: app launches without `UnsatisfiedLinkError`. If it crashes on a `nativeReaderPreferences…` symbol, the `.so`/bindings are stale → re-run Task 7 from worktree source (Build-Order Rule 2).

- [ ] **Step 7: Manual per-score verification** (you drive, then hand to user per `feedback_android_install_launch`): open score A, set staff size / hide a staff / change an instrument / master volume / tempo / A4 / set A-B range; close + reopen A → all restored. Open score B → independent defaults (proves per-score). Change a global (layout mode) → shared across A and B.

- [ ] **Step 8: Commit**

```bash
git add Android/
git commit -m "feat(android-reader): persist per-score display+playback+mixer via ReaderPreferences blob"
```

---

# Phase 2 — New parity settings UI (persist-only; behavior deferred)

## Task 10: Global `playlistContinuationMode` DataStore key

**Files:**
- Modify: `Android/app/.../ui/settings/SettingsPrefs.kt`

- [ ] **Step 1: Add the key + flow + setter** (default `"playThrough"`, matching Domain `PlaylistContinuationMode`):

```kotlin
// in SettingsKeys:
val playlistContinuationMode = stringPreferencesKey("playlistContinuationMode")

// in SettingsPrefs:
val playlistContinuationMode: Flow<String> =
    context.dataStore.data.map { it[SettingsKeys.playlistContinuationMode] ?: "playThrough" }
suspend fun setPlaylistContinuationMode(v: String) =
    context.dataStore.edit { it[SettingsKeys.playlistContinuationMode] = v }
```

- [ ] **Step 2: Build to confirm**

Run: `cd Android && ./gradlew :app:compileDebugKotlin`
Expected: BUILD SUCCESSFUL.

- [ ] **Step 3: Commit**

```bash
git add Android/app/src/main/kotlin/com/keynumber/folino/ui/settings/SettingsPrefs.kt
git commit -m "feat(android-settings): persist playlistContinuationMode (global DataStore)"
```

## Task 11: Playlist-continuation picker in Settings UI

**Files:**
- Modify: `Android/app/.../ui/settings/SettingsScreen.kt`
- Modify: `Android/app/src/main/res/values*/strings.xml` (+ `values-ja`, `-ko`, `-zh-rCN`, `-zh-rTW` to match iOS localization parity)

- [ ] **Step 1: Add a picker row** under "Reader" (after the Repeat row), mirroring the existing menu-picker pattern (`Layout` row at `SettingsScreen.kt:116-168`). Three options bound to `prefs.playlistContinuationMode` → `setPlaylistContinuationMode`:

```kotlin
val continuation by prefs.playlistContinuationMode.collectAsState(initial = "playThrough")
// row: Icon(Icons.Filled.PlaylistPlay) + Text(stringResource(R.string.settings_playlist_continuation)) + menu picker
val options = listOf(
    "off" to stringResource(R.string.playlist_continuation_off),
    "playThrough" to stringResource(R.string.playlist_continuation_play_through),
    "loopPlaylist" to stringResource(R.string.playlist_continuation_loop),
)
// DropdownMenu identical to the Layout row; onClick -> scope.launch { prefs.setPlaylistContinuationMode(raw) }
```

Add the four string resources (label + three option titles) to every `strings.xml`, matching the iOS copy from the `reader.settings.playlistContinuation*` / `PlaylistContinuationPicker` localization (`Packages/Features/Reader/Sources/Reader/Views/PlaylistContinuationPicker.swift`, `Packages/Features/Settings/.../ReaderModeSettingRows.swift`).

- [ ] **Step 2: Build + install + launch; verify persistence**

```bash
cd Android && ./gradlew :app:installDebug
ANDROID_SERIAL=emulator-5554 adb shell am start -n com.KeyNumber.Folino/.MainActivity
```

Expected: the picker appears, selecting a value survives app restart (selecting does not change playback — behavior is deferred).

- [ ] **Step 3: Commit**

```bash
git add Android/app/
git commit -m "feat(android-settings): playlist continuation picker (persist-only, parity UI)"
```

## Task 12: Transpose stepper in the playback inspector

**Files:**
- Modify: `Android/FolinoReaderAndroid/.../PlaybackInspectorSheet.kt`
- Modify: `Android/FolinoReaderAndroid/src/main/res/values*/strings.xml`

- [ ] **Step 1: Add a Transpose row** in the "General" group (after the A4 row, before Repeat), mirroring iOS `TransposeRow.swift` and the existing `A4ReferenceRow` stepper layout: `Icons.Filled.SwapVert` icon + "Transpose" label + signed monospaced readout (tap-to-reset to 0) + ±1 stepper bounded `-7…7`, bound to the controller:

```kotlin
val transpose by audioVm.preferences.transposeSemitones.collectAsStateWithLifecycle() // via controller
// readout: if (transpose > 0) "+$transpose" else "$transpose", Modifier.clickable { controller.setTranspose(0) }
// two IconButtons: onClick { controller.setTranspose((transpose - 1).coerceAtLeast(-7)) } / (+1).coerceAtMost(7)
```

Add `R.string.reader_inspector_transpose` to every `strings.xml`, copy matching iOS `reader.inspector.transpose`. Add a code comment: `// Persist-only: the audio/notation transpose effect is wired in a later feature (see spec Non-Goals).`

- [ ] **Step 2: Build + install + launch; verify**

```bash
cd Android && ./gradlew :app:installDebug
ANDROID_SERIAL=emulator-5554 adb shell am start -n com.KeyNumber.Folino/.MainActivity
```

Expected: the stepper appears, ranges `-7…7`, tap-to-reset works, and the value persists per-score across reopen (no audible/visual transpose — deferred).

- [ ] **Step 3: Commit**

```bash
git add Android/FolinoReaderAndroid/
git commit -m "feat(android-reader): transpose stepper in playback inspector (persist-only, parity UI)"
```

---

## Final Verification

- [ ] **iOS unaffected:** `cd Packages/Domain && swift test` green (only additive test); no iOS source changed beyond the new `@WireletProvided`/`@WireletObservable` files in `FolinoReaderJNI` (Android-only product) + the Domain test.
- [ ] **Android full smoke** on the emulator: every per-score control persists per-score; globals persist globally; `playlistContinuationMode` picker + transpose stepper persist across restart.
- [ ] **Hand to user** for physical-device confirmation and any by-ear checks (per `feedback_android_install_launch`); do not disconnect the Pixel.
- [ ] Update the memory note for this work when complete (new `project_android_settings_persistence.md`).

## Self-Review Notes (gaps to watch during execution)

- **Generated interface/package names** (Tasks 6, 8): the exact Kotlin package of the jextract-generated `ReaderPreferencesBridge`/`ReaderPreferencesStore`/`*Wire` classes is only known after Task 7. Fix imports then.
- **AB-repeat blob projection** (Task 9 Step 5): the bridge needs `abRepeat` get + `setAbRepeat`/`clearAbRepeat` — add them mirroring the scalar mutators if not present (they were omitted from Task 4's first cut intentionally to keep that task focused; add in Step 5).
- **Channel-order assumption** (Task 9 Step 4): guarded by skipping unresolved addresses; if the manual test shows overrides landing on the wrong staff, derive the map from `MixerChannel`'s own part/staff fields instead of positional order.
