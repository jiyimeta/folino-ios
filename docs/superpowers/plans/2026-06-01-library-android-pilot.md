# Library Android pilot — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a minimal one-screen Android port of the Folino Library — an All-Scores list backed by a swift-wirelet Observable-bridge store, with `.mscz` import parsed in Swift, soft-delete, and a stub Reader.

**Architecture:** A new `@WireletObservable @Observable` Swift class (`LibraryAndroidStore`) holds a stored `[ScoreRowWire]` array rebuilt on each mutation (the bridge's supported stored-property → `StateFlow` path). It is cross-compiled into `libFolinoLibraryJNI.so`; the wirelet Gradle plugin generates `LibraryAndroidStoreViewModel.kt`; a Jetpack Compose screen consumes its `StateFlow<List<ScoreRowWire>>`. `.mscz` parsing uses swift-sheet-music's `MSCZReader` (Foundation-only, Android-safe).

**Tech Stack:** Swift 6.3 + Observation + swift-wirelet v0.2.2 (`Wirelet` + `WireletObservable` + `WireletObservableBridges` plugin) + swift-sheet-music (`SheetMusicMSCX`); Kotlin + Jetpack Compose (Material 3) + AndroidX Lifecycle/ViewModel + Navigation; Swift 6.3.2 Android SDK cross-compile.

**Reference implementations to mirror (read these first):**
- Observable bridge end-to-end: `~/Developer/Personal/swift-packages/swift-wirelet/examples/observable-counter/` — `swift/Package.swift`, `swift/Sources/ObservableCounterJNI/TodoListVM.swift`, `android-app/app/build.gradle.kts`, `android-app/app/src/main/kotlin/.../TodoScreen.kt` + `MainActivity.kt`, `build.sh`.
- Settings spike (Android module + cross-compile staging in *this* repo): `Android/FolinoSettingsAndroid/build.gradle.kts`, `Android/settings.gradle.kts`, `Android/app/build.gradle.kts`, `Android/app/src/main/kotlin/com/keynumber/folino/MainActivity.kt`, `Scripts/android-build-libs.sh`.
- mscz API: `~/Developer/Personal/swift-packages/swift-sheet-music/Sources/SheetMusicMSCX/MSCZReader.swift` → `MSCZReader.parse(_ data: Data) throws -> Score`; title via `score.metaTags["workTitle"]`, composer via `score.metaTags["composer"]`.

**Spec:** `docs/superpowers/specs/2026-06-01-library-android-pilot-design.md`

---

## Pinned coordinates (use these exact values)

| Thing | Value |
|---|---|
| swift-wirelet target version (Folino bump) | revision `cd0d148e9d4dddad1c6afc47d5ef0a8d6f4a4a13` (= `v0.2.2`), URL `https://github.com/jiyimeta/swift-wirelet.git` |
| wirelet Maven runtime | `io.github.jiyimeta:wirelet-runtime:0.2.2` |
| wirelet Maven observable runtime | `io.github.jiyimeta:wirelet-observable-runtime:0.2.2` |
| wirelet Gradle plugin | `id("io.github.jiyimeta.wirelet") version "0.2.2"` |
| swift-sheet-music current Folino pin | revision `5a9696da9dc5c9f5a85c0afadbbea40319cfcd91` (Domain, Infrastructure, Reader `Package.swift` + `project.yml`) |
| swift-sheet-music local HEAD (Android CI) | `7eda971d1c881bd84a54c79dd4e16ad7572847ea` |
| Android Swift SDK | `swift-6.3.2-RELEASE_android` (`TOOLCHAINS=org.swift.632202605101a`) |
| Android JNI cross triples | `aarch64-unknown-linux-android28` (arm64-v8a), `x86_64-unknown-linux-android28` (x86_64) |

---

## File structure

**Swift (in `Packages/Features/Library/`):**
- Modify `Package.swift` — add `isAndroid` flag + swift-wirelet/swift-sheet-music deps + the `FolinoLibraryJNI` dynamic target (Android-only).
- Create `Sources/FolinoLibraryJNI/ScoreRowWire.swift` — `@WireFormat` row type.
- Create `Sources/FolinoLibraryJNI/LibraryAndroidStore.swift` — `@WireletObservable @Observable` store.
- Create `Tests/FolinoLibraryJNITests/LibraryAndroidStoreTests.swift` — host-side Swift Testing.
- Create `Tests/FolinoLibraryJNITests/Resources/sample.mscz` — a real fixture `.mscz`.

**Android module (`Android/FolinoLibraryAndroid/`), mirroring `FolinoSettingsAndroid/`:**
- Create `build.gradle.kts` — wirelet plugin with `sources {}` + `observable {}` blocks.
- Create `proguard-consumer.pro`, `src/main/AndroidManifest.xml`.
- `src/main/jniLibs/{arm64-v8a,x86_64}/` — staged `.so`s (gitignored; produced by the script).

**Android app (`Android/app/`):**
- Create `src/main/kotlin/com/keynumber/folino/ui/library/LibraryScreen.kt`.
- Create `src/main/kotlin/com/keynumber/folino/ui/library/ReaderStubScreen.kt`.
- Modify `src/main/kotlin/com/keynumber/folino/MainActivity.kt` — bottom-nav scaffold (Library start + Settings).
- Modify `src/main/res/values/strings.xml` (create if absent) — new English strings.
- Modify `build.gradle.kts` — depend on `:FolinoLibraryAndroid` + observable/lifecycle deps.
- Modify `Android/settings.gradle.kts` — `include(":FolinoLibraryAndroid")`.

**Build:**
- Create `Scripts/android-build-library-libs.sh` — cross-compile + stage `libFolinoLibraryJNI.so`.

**Dependency reconciliation (sibling repo — confirm before editing):**
- Modify `~/Developer/Personal/swift-packages/swift-sheet-music/Package.swift` — swift-wirelet → v0.2.2, URL → https.

---

## Phase 0 — Dependency reconciliation (GATING)

> **Why first:** swift-sheet-music's `Package.resolved` pins swift-wirelet at `31be47c` (v0.1.0-alpha.2) via an SSH URL; the Library JNI target needs swift-wirelet v0.2.2 (for `WireletObservable`). SwiftPM cannot resolve two revisions of the same package identity in one graph, so swift-sheet-music must agree on v0.2.2 **before** anything else compiles. This touches the **sibling repo** `~/Developer/Personal/swift-packages/swift-sheet-music` — per the repo's autonomous ground rules, **stop and confirm with the user before editing it.**

### Task 0.1: Bump swift-sheet-music's swift-wirelet dependency (sibling repo)

**Files:**
- Modify: `~/Developer/Personal/swift-packages/swift-sheet-music/Package.swift:212` (the `swift-wirelet` dependency URL + revision)

- [ ] **Step 1: Confirm with the user** that editing the sibling swift-sheet-music repo is authorized. Do not proceed until confirmed.

- [ ] **Step 2: Edit the dependency** so swift-sheet-music pins the same swift-wirelet as Folino will. Change the `git@github.com:jiyimeta/swift-wirelet.git` dependency to:

```swift
.package(
    url: "https://github.com/jiyimeta/swift-wirelet.git",
    revision: "cd0d148e9d4dddad1c6afc47d5ef0a8d6f4a4a13"   // v0.2.2
),
```

- [ ] **Step 3: Resolve + build the affected sheet-music targets** to confirm the v0.1→v0.2.2 base-`Wirelet` bump is source-compatible.

Run: `swift build --package-path ~/Developer/Personal/swift-packages/swift-sheet-music --target SheetMusicMSCX`
Expected: builds clean (base `Wirelet` codec API is additive across this bump).

- [ ] **Step 4: Run swift-sheet-music's wirelet-touching tests** (audio/JNI codecs) to confirm no regression.

Run: `swift test --package-path ~/Developer/Personal/swift-packages/swift-sheet-music --filter Wire`
Expected: PASS (or, if these need the Android SDK, note it and rely on the SheetMusicMSCX build above).

- [ ] **Step 5: Commit in the sibling repo** (only after user confirmation in Step 1).

```bash
git -C ~/Developer/Personal/swift-packages/swift-sheet-music add Package.swift Package.resolved
git -C ~/Developer/Personal/swift-packages/swift-sheet-music commit -m "build(deps): bump swift-wirelet to v0.2.2 (https URL)"
```

Record the new swift-sheet-music HEAD SHA — Folino will pin to it in Task 0.2.

### Task 0.2: Bump Folino's swift-wirelet + swift-sheet-music pins

**Files:**
- Modify: `Packages/Features/Settings/Package.swift:49-51` (swift-wirelet revision)
- Modify: `Packages/Features/Domain/Package.swift` + `Packages/Infrastructure/Package.swift` + `Packages/Features/Reader/Package.swift` (swift-sheet-music revision → the Task 0.1 HEAD)
- Modify: `project.yml:46-48` (swift-sheet-music revision) and add a `swift-wirelet` entry if the App graph needs it
- Modify: `Android/FolinoSettingsAndroid/build.gradle.kts:4,38` (plugin + runtime → 0.2.2)

- [ ] **Step 1: Bump swift-wirelet in `Settings/Package.swift`** to revision `cd0d148e9d4dddad1c6afc47d5ef0a8d6f4a4a13` (keep the https URL it already uses).

- [ ] **Step 2: Bump swift-sheet-music** to the Task 0.1 HEAD SHA in `Domain/Package.swift`, `Infrastructure/Package.swift`, `Reader/Package.swift`, and `project.yml` (the repo's dual-update rule: every `Package.swift` pin **and** the `project.yml` `packages:` entry move together).

- [ ] **Step 3: Bump `FolinoSettingsAndroid/build.gradle.kts`** — plugin `version "0.2.2"` (line 4) and `api("io.github.jiyimeta:wirelet-runtime:0.2.2")` (line 38).

- [ ] **Step 4: Resolve the Settings package graph** to prove the bumped graph is conflict-free.

Run: `swift package resolve --package-path Packages/Features/Settings`
Expected: resolves with swift-wirelet at `cd0d148…`, no "conflicting requirements" error.

- [ ] **Step 5: Build Settings (iOS) to prove the v0.2.2 bump is source-compatible for the existing spike.**

Run: `xcodebuild build -scheme Settings -destination 'platform=iOS Simulator,name=iPhone 17' -skipPackagePluginValidation` (from `Packages/Features/Settings`, per the repo's package-test convention)
Expected: BUILD SUCCEEDED.

- [ ] **Step 6: Commit.**

```bash
git add Packages/Features/Settings/Package.swift Packages/Domain/Package.swift Packages/Infrastructure/Package.swift Packages/Features/Reader/Package.swift project.yml Android/FolinoSettingsAndroid/build.gradle.kts
git commit -m "build(deps): bump swift-wirelet to v0.2.2 and swift-sheet-music in lockstep"
```

---

## Phase 1 — Bridge de-risk spike

> Validate the two highest-risk bridge behaviors with the *smallest possible* store before building the real store + UI: (a) a stored `[@WireFormat]` array round-trips to a live `StateFlow<List<…>>` that re-emits on mutation, and (b) a `@WireletExpose` method with a `Data` parameter marshals as a `ByteArray` argument. If (b) fails, the fallback is a one-field `@WireFormat` wrapper struct argument (proven by the example's `add(TodoItem)` → `ByteArray`).

### Task 1.1: Minimal spike store + cross-compile smoke

**Files:**
- Create (temporary, in the JNI target dir): `Sources/FolinoLibraryJNI/_Spike.swift`

- [ ] **Step 1: Write a throwaway spike store** alongside where the real one will live:

```swift
import Foundation
import Observation
import Wirelet
import WireletObservable

@WireFormat
public struct SpikeRow: Equatable, Sendable {
    public var id: String
    public var label: String
}

@WireletObservable
@Observable
public final class SpikeStore {
    public private(set) var rows: [SpikeRow] = []
    public init() {}

    @WireletExpose
    public func addRaw(_ bytes: Data) {       // proves Data-param marshaling
        rows.append(SpikeRow(id: "\(rows.count)", label: "\(bytes.count) bytes"))
    }

    @WireletExpose
    public func remove(_ id: String) {        // proves String-param marshaling
        rows.removeAll { $0.id == id }
    }
}
```

- [ ] **Step 2: Cross-compile the JNI target** (after Task 2.1 wires the target into `Package.swift`; if running 1.1 first, temporarily add a minimal `FolinoLibraryJNI` target with just this file). Confirm the `@_cdecl` symbols appear.

Run: `FOLINO_ANDROID=1 TOOLCHAINS=org.swift.632202605101a swift build --package-path Packages/Features/Library --product FolinoLibraryJNI --swift-sdk aarch64-unknown-linux-android28 -c release`
Expected: builds `libFolinoLibraryJNI.so`.

Run: `nm -D Packages/Features/Library/.build/aarch64-unknown-linux-android28/release/libFolinoLibraryJNI.so | grep -i WireletObservable_SpikeStore`
Expected: lists `..._rows_track`, `..._addRaw`, `..._remove`, `..._new`, `..._release` symbols. If `addRaw`'s symbol is missing or the Kotlin generation later rejects the `Data` param, switch to the wrapper-struct fallback (Step 3).

- [ ] **Step 3 (fallback only): wrapper-struct variant** — if `Data` params are unsupported, define `@WireFormat struct MsczPayload { var bytes: Data }` and make the method `addRaw(_ payload: MsczPayload)`. Re-run Step 2.

- [ ] **Step 4: Generate the Kotlin ViewModel from the spike** to confirm the emitter accepts the surface.

Run (TestKit-style, via the Android module once Phase 3 scaffolds it, or via the CLI directly):
`swift run --package-path ~/Developer/Personal/swift-packages/swift-wirelet emit-wirelet-observable --schema Packages/Features/Library/Sources/FolinoLibraryJNI --output /tmp/spike-vm`
Expected: `/tmp/spike-vm/.../SpikeStoreViewModel.kt` exists, exposing `val rows: StateFlow<List<SpikeRow>>`, `fun addRaw(bytes: ByteArray)` (or `fun addRaw(payload: SpikeRow)` in the fallback), and `fun remove(id: String)`.

- [ ] **Step 5: Record the outcome** (Data-param supported? yes/no) in the plan's Open-items and **delete `_Spike.swift`** before Phase 2.

```bash
rm Packages/Features/Library/Sources/FolinoLibraryJNI/_Spike.swift
```

No commit — this is a throwaway spike. The learning carries into Phase 2.

---

## Phase 2 — Swift store + wire type + tests

### Task 2.1: Wire the `FolinoLibraryJNI` target into `Package.swift`

**Files:**
- Modify: `Packages/Features/Library/Package.swift`

- [ ] **Step 1: Replace the manifest** with the `isAndroid`-gated form (mirrors `Settings/Package.swift`, but uses the Observable bridge — `WireletObservable` + `WireletObservableBridges` plugin — instead of swift-java):

```swift
// swift-tools-version: 6.3
import Foundation
import PackageDescription

let isAndroid = ProcessInfo.processInfo.environment["FOLINO_ANDROID"] == "1"

let swiftLintPlugins: [Target.PluginUsage] = [
    .plugin(name: "SwiftLintBuildToolPlugin", package: "SwiftLintPlugins"),
]

var products: [Product] = [
    .library(name: "Library", targets: ["Library"]),
]

var targets: [Target] = [
    .target(
        name: "Library",
        dependencies: [
            "Domain",
            .product(name: "UtilityCore", package: "Utility"),
            .product(name: "UtilityUI", package: "Utility"),
        ],
        resources: [.process("Resources")],
        plugins: swiftLintPlugins,
    ),
    .testTarget(name: "LibraryTests", dependencies: ["Library"]),
]

var packageDependencies: [Package.Dependency] = [
    .package(url: "https://github.com/SimplyDanny/SwiftLintPlugins", from: "0.63.2"),
    .package(path: "../../Domain"),
    .package(path: "../../Utility"),
]

if isAndroid {
    packageDependencies += [
        // swiftlint:disable:next line_length
        .package(url: "https://github.com/jiyimeta/swift-wirelet.git", revision: "cd0d148e9d4dddad1c6afc47d5ef0a8d6f4a4a13"),
        .package(
            url: "https://github.com/jiyimeta/swift-sheet-music.git",
            revision: "<TASK-0.1-HEAD-SHA>",   // same pin as Domain/Infrastructure/Reader
        ),
    ]
    products += [
        .library(name: "FolinoLibraryJNI", type: .dynamic, targets: ["FolinoLibraryJNI"]),
    ]
    targets += [
        .target(
            name: "FolinoLibraryJNI",
            dependencies: [
                .product(name: "Wirelet", package: "swift-wirelet"),
                .product(name: "WireletObservable", package: "swift-wirelet"),
                .product(name: "SheetMusicMSCX", package: "swift-sheet-music"),
            ],
            plugins: [
                .plugin(name: "WireletObservableBridges", package: "swift-wirelet"),
            ],
        ),
        .testTarget(
            name: "FolinoLibraryJNITests",
            dependencies: ["FolinoLibraryJNI"],
            resources: [.process("Resources")],
        ),
    ]
}

let package = Package(
    name: "Library",
    defaultLocalization: "en",
    platforms: [.iOS(.v26)],
    products: products,
    dependencies: packageDependencies,
    targets: targets,
)
```

> Note: `FolinoLibraryJNI` does **not** depend on `Domain` — the store is self-contained (`ScoreRowWire` + swift-sheet-music only), keeping the Android `.so` lean and the graph minimal.

- [ ] **Step 2: Resolve to confirm the Android graph is conflict-free.**

Run: `FOLINO_ANDROID=1 swift package resolve --package-path Packages/Features/Library`
Expected: resolves; swift-wirelet at `cd0d148…`, swift-sheet-music at the Task 0.1 HEAD, no conflict.

- [ ] **Step 3: Commit.**

```bash
git add Packages/Features/Library/Package.swift
git commit -m "build(library): add Android FolinoLibraryJNI target gated by FOLINO_ANDROID"
```

### Task 2.2: `ScoreRowWire` wire type

**Files:**
- Create: `Packages/Features/Library/Sources/FolinoLibraryJNI/ScoreRowWire.swift`

- [ ] **Step 1: Write the type.**

```swift
import Wirelet

/// Display projection of a score row, marshaled across the JNI boundary
/// as a Kotlin `data class ScoreRowWire(id, title, composer)`.
@WireFormat
public struct ScoreRowWire: Equatable, Sendable {
    public var id: String
    public var title: String
    public var composer: String

    public init(id: String, title: String, composer: String) {
        self.id = id
        self.title = title
        self.composer = composer
    }
}
```

- [ ] **Step 2: Build (host) to confirm the macro expands.**

Run: `swift build --package-path Packages/Features/Library` (host build skips the Android target since `FOLINO_ANDROID` is unset — so also smoke the type under the flag:) `FOLINO_ANDROID=1 swift build --package-path Packages/Features/Library --target FolinoLibraryJNI` on the host (macOS) — the `@WireFormat` macro and `@WireletObservable` no-op extension must compile on Apple too.
Expected: builds.

### Task 2.3: `LibraryAndroidStore` (TDD)

**Files:**
- Create: `Packages/Features/Library/Tests/FolinoLibraryJNITests/LibraryAndroidStoreTests.swift`
- Create: `Packages/Features/Library/Tests/FolinoLibraryJNITests/Resources/sample.mscz`
- Create: `Packages/Features/Library/Sources/FolinoLibraryJNI/LibraryAndroidStore.swift`

- [ ] **Step 1: Add a real `.mscz` fixture.** Copy a small MuseScore file with a known `workTitle`/`composer` into the Resources dir (e.g. export "Gymnopédie No. 1" by "Erik Satie", or reuse an existing repo test fixture if one exists — check `Packages/Infrastructure/Tests` and `swift-sheet-music/Tests` for a reusable `.mscz`).

- [ ] **Step 2: Write the failing test.**

```swift
import Foundation
import Testing
@testable import FolinoLibraryJNI

@Suite struct LibraryAndroidStoreTests {
    private func sampleMSCZ() throws -> Data {
        let url = try #require(Bundle.module.url(forResource: "sample", withExtension: "mscz"))
        return try Data(contentsOf: url)
    }

    @Test func importParsesTitleAndComposer() throws {
        let store = LibraryAndroidStore()
        store.importScore(try sampleMSCZ())
        #expect(store.scores.count == 1)
        let row = try #require(store.scores.first)
        #expect(row.title == "Gymnopédie No. 1")   // adjust to the fixture's actual workTitle
        #expect(row.composer == "Erik Satie")       // adjust to the fixture's actual composer
        #expect(!row.id.isEmpty)
    }

    @Test func deleteRemovesById() throws {
        let store = LibraryAndroidStore()
        store.importScore(try sampleMSCZ())
        let id = try #require(store.scores.first?.id)
        store.delete(id)
        #expect(store.scores.isEmpty)
    }

    @Test func insertReAddsRow() {
        let store = LibraryAndroidStore()
        let row = ScoreRowWire(id: "x", title: "T", composer: "C")
        store.insert(row)
        #expect(store.scores == [row])
    }

    @Test func importOfGarbageIsIgnored() {
        let store = LibraryAndroidStore()
        store.importScore(Data([0, 1, 2, 3]))
        #expect(store.scores.isEmpty)
    }
}
```

- [ ] **Step 3: Run — expect failure** (`LibraryAndroidStore` undefined).

Run: `swift test --package-path Packages/Features/Library --filter LibraryAndroidStoreTests`
Expected: FAIL (cannot find `LibraryAndroidStore`). If the SwiftLint plugin breaks `swift test` (known repo issue), build the test target instead and note it; the macOS host build path is what matters here.

- [ ] **Step 4: Write the store.**

```swift
import Foundation
import Observation
import SheetMusicMSCX
import Wirelet
import WireletObservable

/// Android-facing Library store. The single screen consumes `scores`
/// as a Kotlin `StateFlow<List<ScoreRowWire>>`; `importScore`/`delete`/
/// `insert` cross the JNI boundary as synchronous methods.
///
/// `scores` is a *stored* property reassigned wholesale on every mutation
/// (the Observable-bridge's supported StateFlow path). No injected
/// `@Observable` repository, so the bridge's nested-observable limitation
/// never applies.
@WireletObservable
@Observable
public final class LibraryAndroidStore {
    public private(set) var scores: [ScoreRowWire] = []

    public init() {}

    /// Parse an `.mscz` (Foundation-only path: zlib + XMLParser) and append
    /// a row. Unparseable input is ignored (no crash, no row).
    @WireletExpose
    public func importScore(_ msczBytes: Data) {
        guard let score = try? MSCZReader.parse(msczBytes) else { return }
        let title = score.metaTags["workTitle"] ?? ""
        let composer = score.metaTags["composer"] ?? ""
        scores.append(ScoreRowWire(id: UUID().uuidString, title: title, composer: composer))
    }

    @WireletExpose
    public func delete(_ id: String) {
        scores.removeAll { $0.id == id }
    }

    /// Re-insert a previously-removed row (drives the Compose "Undo" Snackbar).
    @WireletExpose
    public func insert(_ row: ScoreRowWire) {
        scores.append(row)
    }
}
```

> If Phase 1 found `Data` params unsupported, change `importScore(_ msczBytes: Data)` to take the `MsczPayload` wrapper and unwrap `payload.bytes` here.

- [ ] **Step 5: Run — expect pass.** Adjust the expected title/composer in Step 2 to the fixture's real `metaTags` if they differ (read them once via a throwaway print or the diagnostics API).

Run: `swift test --package-path Packages/Features/Library --filter LibraryAndroidStoreTests`
Expected: PASS (4 tests).

- [ ] **Step 6: Commit.**

```bash
git add Packages/Features/Library/Sources/FolinoLibraryJNI Packages/Features/Library/Tests/FolinoLibraryJNITests
git commit -m "feat(library): add Android LibraryAndroidStore + ScoreRowWire"
```

---

## Phase 3 — Cross-compile + Gradle module

### Task 3.1: Cross-compile staging script

**Files:**
- Create: `Scripts/android-build-library-libs.sh`

- [ ] **Step 1: Write the script** (adapt `Scripts/android-build-libs.sh`; the Observable bridge uses `System.loadLibrary` + `external fun`, so there is **no** swift-java jextract `java-generated` staging step — drop that block).

```bash
#!/usr/bin/env bash
# Build FolinoLibraryJNI for each enabled Android ABI and stage .so files
# (plus Swift runtime + libc++_shared.so) into
# Android/FolinoLibraryAndroid/src/main/jniLibs/.
set -euo pipefail

: "${TOOLCHAINS:=org.swift.632202605101a}"
export TOOLCHAINS
export FOLINO_ANDROID=1

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
PKG_PATH="$ROOT/Packages/Features/Library"
JNI_DIR="$ROOT/Android/FolinoLibraryAndroid/src/main/jniLibs"
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

    echo "==> Building libFolinoLibraryJNI.so for $abi ($triple)"
    swift build --package-path "$PKG_PATH" \
                --product FolinoLibraryJNI \
                --swift-sdk "$triple" \
                -c release

    src_so="$PKG_PATH/.build/$triple/release/libFolinoLibraryJNI.so"
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

echo "Done. libFolinoLibraryJNI.so + runtime staged under $JNI_DIR/{arm64-v8a,x86_64}/"
```

- [ ] **Step 2: chmod + run.**

Run: `chmod +x Scripts/android-build-library-libs.sh && Scripts/android-build-library-libs.sh`
Expected: stages `.so`s under `Android/FolinoLibraryAndroid/src/main/jniLibs/{arm64-v8a,x86_64}/`, including `libFolinoLibraryJNI.so`, `libswiftCore.so`, `libc++_shared.so`, etc.

- [ ] **Step 3: Commit the script** (the `.so`s are gitignored like the Settings spike).

```bash
git add Scripts/android-build-library-libs.sh
git commit -m "build(android): cross-compile script for libFolinoLibraryJNI.so"
```

### Task 3.2: `FolinoLibraryAndroid` Gradle module

**Files:**
- Create: `Android/FolinoLibraryAndroid/build.gradle.kts`
- Create: `Android/FolinoLibraryAndroid/proguard-consumer.pro` (copy from `FolinoSettingsAndroid/`)
- Create: `Android/FolinoLibraryAndroid/src/main/AndroidManifest.xml` (empty lib manifest, copy from `FolinoSettingsAndroid/`)
- Modify: `Android/settings.gradle.kts:53` — add `include(":FolinoLibraryAndroid")`

- [ ] **Step 1: Write `build.gradle.kts`** (mirrors `FolinoSettingsAndroid/build.gradle.kts` but adds the `observable {}` block and the observable runtime dep; uses plugin 0.2.2):

```kotlin
plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
    id("io.github.jiyimeta.wirelet") version "0.2.2"
}

android {
    namespace = "com.keynumber.folino.library"
    compileSdk = 35

    defaultConfig {
        minSdk = 28
        consumerProguardFiles("proguard-consumer.pro")
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
    api("io.github.jiyimeta:wirelet-runtime:0.2.2")
    api("io.github.jiyimeta:wirelet-observable-runtime:0.2.2")
    api("androidx.lifecycle:lifecycle-viewmodel:2.8.7")
    api("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")
}

val packageRoot: File = rootProject.projectDir.resolve("..").canonicalFile

wirelet {
    val libCheckout = packageRoot.resolve("Packages/Features/Library/.build/checkouts/swift-wirelet")
    val rootCheckout = packageRoot.resolve(".build/checkouts/swift-wirelet")
    swiftPackagePath.set(if (libCheckout.exists()) libCheckout else rootCheckout)

    sources {
        register("main") {
            schemaPaths.from(packageRoot.resolve("Packages/Features/Library/Sources/FolinoLibraryJNI"))
            codecPackage.set("com.keynumber.folino.library")
            modelPackage.set("com.keynumber.folino.library")
            emitModels.set(true)
        }
    }
    observable {
        register("main") {
            schemaPaths.from(packageRoot.resolve("Packages/Features/Library/Sources/FolinoLibraryJNI"))
            viewModelPackage.set("com.keynumber.folino.library.generated")
            modelPackage.set("com.keynumber.folino.library")
            codecPackage.set("com.keynumber.folino.library")
            libraryName.set("FolinoLibraryJNI")
        }
    }
}

// kotlin.android needs the generated dirs wired manually (the plugin v1 only
// hooks kotlin.jvm). Mirror the Settings module's manual wiring for BOTH the
// codec task and the observable task.
val generateCodecs = tasks.named("generateWireletCodecsMain")
val generateViewModels = tasks.named("generateWireletObservableViewModelsMain")

android {
    sourceSets["main"].kotlin.srcDir(
        generateCodecs.flatMap { (it as io.github.jiyimeta.wirelet.gradle.GenerateWireletCodecs).outputDir }
    )
    sourceSets["main"].kotlin.srcDir(
        generateViewModels.flatMap { (it as io.github.jiyimeta.wirelet.gradle.GenerateWireletObservableViewModels).outputDir }
    )
}

tasks.matching { it.name.startsWith("compile") && it.name.endsWith("Kotlin") }
    .configureEach { dependsOn(generateCodecs, generateViewModels) }
```

> The exact task type for the observable task (`GenerateWireletObservableViewModels`) must match the plugin 0.2.2 API — verify the class name from the plugin's published sources or the example's generated `build/` dir; adjust the cast if the plugin auto-wires kotlin.android (in which case the manual `srcDir` block is unnecessary — confirm against a first `assembleDebug`).

- [ ] **Step 2: Copy `proguard-consumer.pro` and `AndroidManifest.xml`** from `FolinoSettingsAndroid/` (rename the manifest's `package`/namespace nothing — lib manifests are empty).

- [ ] **Step 3: Register the module** — add `include(":FolinoLibraryAndroid")` to `Android/settings.gradle.kts`.

- [ ] **Step 4: Build the module to confirm codegen + Kotlin compile.**

Run: `Android/gradlew -p Android :FolinoLibraryAndroid:assembleDebug`
Expected: BUILD SUCCESSFUL; `LibraryAndroidStoreViewModel.kt` + `ScoreRowWire.kt` + `ScoreRowWireCodec.kt` generated under `build/generated/...`.

- [ ] **Step 5: Commit.**

```bash
git add Android/FolinoLibraryAndroid Android/settings.gradle.kts
git commit -m "feat(android): add FolinoLibraryAndroid module with observable codegen"
```

---

## Phase 4 — Compose UI + app wiring

### Task 4.1: Strings

**Files:**
- Modify/Create: `Android/app/src/main/res/values/strings.xml`

- [ ] **Step 1: Add English strings** (iOS copy parity; `values-ja/` etc. are a tracked follow-up, out of scope):

```xml
<resources>
    <string name="library_title">Library</string>
    <string name="library_empty_title">No Scores Yet</string>
    <string name="library_empty_hint">Import your first score to get started</string>
    <string name="library_import">Import score</string>
    <string name="library_deleted">Score deleted</string>
    <string name="library_undo">Undo</string>
    <string name="nav_library">Library</string>
    <string name="nav_settings">Settings</string>
</resources>
```

### Task 4.2: `LibraryScreen` composable

**Files:**
- Create: `Android/app/src/main/kotlin/com/keynumber/folino/ui/library/LibraryScreen.kt`

- [ ] **Step 1: Write the screen** — Material 3 `Scaffold` with top app bar, FAB import (document picker), `LazyColumn` of `ListItem`s, swipe-to-dismiss + Undo Snackbar, empty state. Consumes `LibraryAndroidStoreViewModel` from `com.keynumber.folino.library.generated`.

```kotlin
package com.keynumber.folino.ui.library

import android.content.Context
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.MusicNote
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.stringResource
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.keynumber.folino.R
import com.keynumber.folino.library.ScoreRowWire
import com.keynumber.folino.library.generated.LibraryAndroidStoreViewModel
import kotlinx.coroutines.launch

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun LibraryScreen(
    viewModel: LibraryAndroidStoreViewModel,
    onOpenScore: (ScoreRowWire) -> Unit,
) {
    val scores by viewModel.scores.collectAsStateWithLifecycle()
    val context = LocalContext.current
    val snackbarHost = remember { SnackbarHostState() }
    val scope = rememberCoroutineScope()

    val picker = rememberLauncherForActivityResult(
        ActivityResultContracts.OpenDocument()
    ) { uri ->
        if (uri != null) {
            val bytes = context.contentResolver.openInputStream(uri)?.use { it.readBytes() }
            if (bytes != null) viewModel.importScore(bytes)
        }
    }

    Scaffold(
        topBar = { TopAppBar(title = { Text(stringResource(R.string.library_title)) }) },
        snackbarHost = { SnackbarHost(snackbarHost) },
        floatingActionButton = {
            FloatingActionButton(onClick = {
                // .mscz has no registered MIME on most devices; widen to */* and rely
                // on the parser to reject non-mscz input.
                picker.launch(arrayOf("*/*"))
            }) { Icon(Icons.Filled.Add, contentDescription = stringResource(R.string.library_import)) }
        },
    ) { padding ->
        if (scores.isEmpty()) {
            EmptyState(Modifier.padding(padding).fillMaxSize())
        } else {
            LazyColumn(Modifier.padding(padding).fillMaxSize()) {
                items(scores, key = { it.id }) { row ->
                    ScoreRow(
                        row = row,
                        onClick = { onOpenScore(row) },
                        onDelete = {
                            viewModel.delete(row.id)
                            scope.launch {
                                val result = snackbarHost.showSnackbar(
                                    message = context.getString(R.string.library_deleted),
                                    actionLabel = context.getString(R.string.library_undo),
                                )
                                if (result == SnackbarResult.ActionPerformed) viewModel.insert(row)
                            }
                        },
                    )
                }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ScoreRow(row: ScoreRowWire, onClick: () -> Unit, onDelete: () -> Unit) {
    val dismissState = rememberSwipeToDismissBoxState(
        confirmValueChange = {
            if (it == SwipeToDismissBoxValue.EndToStart) { onDelete(); true } else false
        }
    )
    SwipeToDismissBox(
        state = dismissState,
        enableDismissFromStartToEnd = false,
        backgroundContent = {
            Box(Modifier.fillMaxSize().padding(horizontal = 16.dp), contentAlignment = Alignment.CenterEnd) {
                Icon(Icons.Filled.Delete, contentDescription = null)
            }
        },
    ) {
        ListItem(
            headlineContent = { Text(row.title.ifEmpty { "Untitled" }) },
            supportingContent = { if (row.composer.isNotEmpty()) Text(row.composer) },
            leadingContent = { Icon(Icons.Filled.MusicNote, contentDescription = null) },
            modifier = Modifier.clickable(onClick = onClick),
        )
    }
}

@Composable
private fun EmptyState(modifier: Modifier) {
    Box(modifier, contentAlignment = Alignment.Center) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Text(stringResource(R.string.library_empty_title), style = MaterialTheme.typography.titleMedium)
            Text(stringResource(R.string.library_empty_hint), style = MaterialTheme.typography.bodyMedium)
        }
    }
}
```

> Add the missing imports flagged by the compiler (`androidx.compose.foundation.clickable`, `androidx.compose.foundation.layout.Column`, `androidx.compose.material.icons.filled.Delete`, `androidx.compose.ui.unit.dp`, `SwipeToDismissBoxValue`, etc.). The `SwipeToDismissBox` API is Material3 1.3+ (the app's compose-bom `2024.09.02` ships it — verify; bump the BOM if the symbol is missing).

### Task 4.3: `ReaderStubScreen`

**Files:**
- Create: `Android/app/src/main/kotlin/com/keynumber/folino/ui/library/ReaderStubScreen.kt`

- [ ] **Step 1: Write the stub** — top app bar with back, centered title text.

```kotlin
package com.keynumber.folino.ui.library

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ReaderStubScreen(title: String, onBack: () -> Unit) {
    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(title.ifEmpty { "Untitled" }) },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                    }
                },
            )
        },
    ) { padding ->
        Box(Modifier.padding(padding).fillMaxSize(), contentAlignment = Alignment.Center) {
            Text(title.ifEmpty { "Untitled" }, style = MaterialTheme.typography.headlineMedium)
        }
    }
}
```

### Task 4.4: Bottom-nav scaffold in `MainActivity`

**Files:**
- Modify: `Android/app/src/main/kotlin/com/keynumber/folino/MainActivity.kt`
- Modify: `Android/app/build.gradle.kts` — add `implementation(project(":FolinoLibraryAndroid"))` and lifecycle-viewmodel-compose / lifecycle-runtime-compose if absent.

- [ ] **Step 1: Add the app dependency.** In `Android/app/build.gradle.kts` dependencies, add:

```kotlin
implementation(project(":FolinoLibraryAndroid"))
implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.8.7")
implementation("androidx.lifecycle:lifecycle-runtime-compose:2.8.7")
```

- [ ] **Step 2: Rewrite `MainActivity`** with a bottom-nav `Scaffold` whose two destinations are Library (start) and Settings. Library hosts an inner NavHost for list → stub-reader. Mirror the Settings-spike `SettingsScreen(prefs, items, …)` construction for the Settings tab (keep the existing `VersionHistoryBridge.load` wiring).

```kotlin
package com.keynumber.folino

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.LibraryMusic
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import androidx.navigation.NavType
import androidx.navigation.navArgument
import com.keynumber.folino.library.generated.LibraryAndroidStoreViewModel
import com.keynumber.folino.settings.VersionHistoryBridge
import com.keynumber.folino.ui.library.LibraryScreen
import com.keynumber.folino.ui.library.ReaderStubScreen
import com.keynumber.folino.ui.settings.SettingsPrefs
import com.keynumber.folino.ui.settings.SettingsScreen
import com.keynumber.folino.ui.settings.VersionHistoryItem
import java.net.URLEncoder
import java.net.URLDecoder

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val prefs = SettingsPrefs(applicationContext)
        val json = assets.open("VersionHistory.json").readBytes()
        val versionItems = VersionHistoryBridge.load(json)
            .map { VersionHistoryItem(it.version, it.descriptions) }

        setContent {
            MaterialTheme {
                val rootNav = rememberNavController()
                Scaffold(
                    bottomBar = {
                        NavigationBar {
                            val current = rootNav.currentBackStackEntryAsState().value?.destination?.route
                            NavigationBarItem(
                                selected = current == "library",
                                onClick = { rootNav.navigate("library") { launchSingleTop = true } },
                                icon = { Icon(Icons.Filled.LibraryMusic, contentDescription = null) },
                                label = { Text(stringResource(R.string.nav_library)) },
                            )
                            NavigationBarItem(
                                selected = current == "settings",
                                onClick = { rootNav.navigate("settings") { launchSingleTop = true } },
                                icon = { Icon(Icons.Filled.Settings, contentDescription = null) },
                                label = { Text(stringResource(R.string.nav_settings)) },
                            )
                        }
                    },
                ) { padding ->
                    NavHost(rootNav, startDestination = "library", modifier = Modifier.padding(padding)) {
                        composable("library") { LibraryNavGraph() }
                        composable("settings") { SettingsScreen(prefs, versionItems) }
                    }
                }
            }
        }
    }
}

@Composable
private fun LibraryNavGraph() {
    val nav = rememberNavController()
    val vm: LibraryAndroidStoreViewModel = viewModel(factory = LibraryVMFactory)
    NavHost(nav, startDestination = "list") {
        composable("list") {
            LibraryScreen(vm, onOpenScore = { row ->
                nav.navigate("reader/${URLEncoder.encode(row.title, "UTF-8")}")
            })
        }
        composable(
            "reader/{title}",
            arguments = listOf(navArgument("title") { type = NavType.StringType }),
        ) { entry ->
            val title = URLDecoder.decode(entry.arguments?.getString("title") ?: "", "UTF-8")
            ReaderStubScreen(title = title, onBack = { nav.popBackStack() })
        }
    }
}

private object LibraryVMFactory : ViewModelProvider.Factory {
    @Suppress("UNCHECKED_CAST")
    override fun <T : ViewModel> create(modelClass: Class<T>): T =
        LibraryAndroidStoreViewModel.create() as T
}
```

> `SettingsScreen`'s existing signature takes `(prefs, items, onOpenLicenses)`; the licenses route was previously reachable from Settings. Preserve it — either keep `onOpenLicenses` wired through a nested Settings NavHost (as today) or pass `onOpenLicenses = {}` for the pilot and note licenses-nav as unchanged-but-deferred. Match the real `SettingsScreen` signature when implementing.

- [ ] **Step 3: Build the app.**

Run: `Android/gradlew -p Android :app:assembleDebug`
Expected: BUILD SUCCESSFUL; APK at `Android/app/build/outputs/apk/debug/app-debug.apk`.

- [ ] **Step 4: Commit.**

```bash
git add Android/app docs
git commit -m "feat(android): Library screen, stub Reader, and bottom-nav shell"
```

---

## Phase 5 — End-to-end smoke (user device verification)

### Task 5.1: Build the APK and hand off

**Files:** none

- [ ] **Step 1: Full rebuild** — re-run the cross-compile then assemble:

Run: `Scripts/android-build-library-libs.sh`
Run: `Android/gradlew -p Android :app:assembleDebug`
Expected: APK built, bundling both `libFolinoSettingsJNI.so` and `libFolinoLibraryJNI.so`.

- [ ] **Step 2: Verify two-`.so` coexistence didn't break packaging** — confirm `app/build.gradle.kts` `packaging.jniLibs.pickFirsts += "**/libc++_shared.so"` still resolves the (now duplicated) runtime `.so`s. If the assemble fails on duplicate Swift-runtime `.so`s, extend `pickFirsts` to cover `**/libswift*.so` and `**/lib_Foundation*.so` (byte-identical across the two modules).

- [ ] **Step 3: Hand to the user for device verification** (per repo convention — Claude builds, the user performs gestures). Script for the user:
  - Install: `adb install -r Android/app/build/outputs/apk/debug/app-debug.apk`
  - Launch; confirm the **Library** tab shows the empty state.
  - Tap the **FAB**, pick a real `.mscz`; confirm a row appears with the correct **title + composer**.
  - **Tap the row**; confirm the stub Reader shows the title; back-navigate.
  - **Swipe** the row away; confirm it disappears and a Snackbar offers **Undo**; tap Undo; confirm the row returns.
  - Switch to the **Settings** tab; confirm the existing Settings screen still works.

- [ ] **Step 4: Final commit** (any fixups from the smoke).

```bash
git add -A
git commit -m "chore(android): Library pilot end-to-end smoke fixups"
```

---

## Open items / decisions resolved during build

- **`Data` method-param support** — resolved by Phase 1 Task 1.1 (wrapper-struct fallback ready).
- **Undo mechanism** — chosen: `@WireletExpose func insert(_ row: ScoreRowWire)` on the Swift store (list stays authoritative in Swift).
- **swift-sheet-music revision** — pin Folino to the Task 0.1 HEAD (the commit that bumps its swift-wirelet to v0.2.2). The cross-repo edit is **confirm-gated** (sibling repo).
- **Observable Gradle task class name** — verify `GenerateWireletObservableViewModels` against plugin 0.2.2; the plugin may already auto-wire kotlin.android (making the manual `srcDir` block unnecessary).
- **compose-bom `SwipeToDismissBox`** — verify the symbol ships in `2024.09.02`; bump the BOM if missing.
- **Localization** — English-only this pass; `values-ja/` + the other four locales tracked as fast follow-up.

## Spec coverage check

| Spec requirement | Task |
|---|---|
| swift-wirelet → v0.2.2 bump (Package.swift + project.yml) | 0.2 |
| swift-sheet-music Android-ready pin | 0.1, 0.2 |
| `ScoreRowWire` `@WireFormat` | 2.2 |
| `LibraryAndroidStore` (stored array, importScore/delete) | 2.3 |
| Import via document picker → Swift parse | 4.2 + 2.3 |
| Soft delete | 2.3 + 4.2 |
| Stub Reader (title only) | 4.3 + 4.4 |
| FAB import | 4.2 |
| Swipe-to-delete + Undo | 4.2 (+ `insert` 2.3) |
| Bottom navigation (Library + Settings) | 4.4 |
| `FolinoLibraryJNI` target + cross-compile | 2.1, 3.1 |
| `FolinoLibraryAndroid` module + observable codegen | 3.2 |
| In-memory, no persistence | 2.3 (by construction) |
| English-first strings | 4.1 |
