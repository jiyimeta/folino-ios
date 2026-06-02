# Library Android pilot — design

**Status**: Spec (brainstorming complete, awaiting plan)
**Date**: 2026-06-01
**Author**: Kiichi Ito (with Claude)
**Branch**: `android-library-pilot`

## Purpose

Bring the Folino **Library** feature to Android for the first time, as a
deliberately minimal one-screen vertical slice that exercises the
**swift-wirelet Observable bridge** (`@WireletObservable @Observable` Swift
class → Kotlin `androidx.lifecycle.ViewModel` with `StateFlow` properties)
end-to-end against a real, reactive store.

This is the second Folino feature to reach Android after the Settings spike.
Settings was stateless and read-only; this pilot is the first to drive a
**mutable, reactive store** across the JNI boundary, and the first to
exercise the Swift `.mscz` parser on Android.

The UI/UX follows **Android idioms for placement** (where elements go) while
keeping **iOS parity for content** (what is shown).

## Background

### What already exists

- **`Android/`** — a Gradle + Jetpack Compose + Kotlin project with a JNI
  bridge to Swift via `swift-java` (jextract) and `swift-wirelet` for
  serialization. Modules: `app/` (Compose application) and
  `FolinoSettingsAndroid/` (JNI library module). See the Settings spike for
  the established pattern.
- **swift-wirelet v0.2.2** (local at `~/Developer/Personal/swift-packages/swift-wirelet`)
  ships the **Observable bridge**: a `@WireletObservable @Observable` Swift
  class is cross-compiled into a JNI `.so`, and the Gradle plugin's
  `observable { … }` block generates a `<Class>ViewModel.kt` whose stored
  properties are `StateFlow<T>` and whose `@WireletExpose` methods are
  regular `fun`s that cross JNI to mutate Swift state. Apple's Observation
  framework drives change propagation back to Kotlin collectors.
  - Folino currently resolves a **pre-observable** revision of swift-wirelet.
    Bumping the pin to **v0.2.2** (`cd0d148e…`) is part of this work.
- **swift-sheet-music** is already Android-ready (`SWIFT_SHEET_MUSIC_ANDROID=1`).
  Its `.mscz` reader path — `SheetMusic.loadScore(msczData:) -> Score`,
  exposing `score.metaTags["workTitle"]` / `["composer"]` — is **Foundation-only**
  (zip via system `zlib`, XML via Foundation `XMLParser`), so it parses an
  `.mscz` **on Android** with no Apple-only dependency.

### The iOS Library feature (for content parity reference)

The iOS Library is a large feature (list + search + sort + favorites +
playlists + tags + import + share + edit-info + soft-delete/trash + bulk
selection), all backed by `@Observable @MainActor` stores over Domain
protocols. This pilot ports **only a thin slice** of it; the rest is future
work.

## Observable-bridge constraints that shape this design

The bridge has documented limits (from its design spec) that directly
constrain how we port the Library store. The existing iOS `LibraryViewModel`
**cannot** be bridged as-is:

1. **No-arg construction.** The generated Kotlin `nativeNew()` takes no
   arguments, so the bridged class needs a `public init()` with no
   parameters. iOS `LibraryViewModel.init` injects five Domain protocols.
   → We write a **new, Android-facing store** that self-composes.
2. **Synchronous methods.** `@WireletExpose` methods are synchronous JNI
   calls. iOS Library methods are all `async`. → Bridged methods are
   fire-and-forget; any async work runs in a `Task` and the result reaches
   Kotlin through a subsequent state mutation.
3. **Property types are restricted** to primitives, `@WireFormat`
   structs/enums, or `Array`/`Optional` of those. `[ScoreItem]` (Domain)
   cannot cross directly. → We project to a `@WireFormat` row type.
4. **Nested-`@Observable` mutations do not propagate** to the parent's
   `StateFlow` (an explicit non-goal of the bridge). A computed property that
   reads an *injected* `@Observable` repository is therefore **not** a
   supported path. → The store holds its **own stored array** and rebuilds it
   on each mutation, staying entirely on the bridge's supported
   stored-property → `StateFlow` path.

## Scope

### In

One screen — **All Scores** — with exactly these interactions:

- **Import** an `.mscz` file. Picked via the Android document picker, parsed
  **in Swift** (swift-sheet-music) to extract title/composer, appended to the
  reactive list.
- **Delete** a row (soft delete — the row disappears from the list).
- **Tap** a row → navigate to a **stub Reader** screen that displays the
  score's **title only** (no rendering, no audio — the Reader feature is not
  ported).

Shell:

- **Bottom navigation** with two destinations: **Library** and **Settings**
  (Settings reuses the existing spike screen).

### Out (future phases)

- Search, sort, favorite-toggle.
- Playlists, Tags, their list/detail screens.
- Recently Deleted (Trash) screen + restore. (Delete here just removes from
  the in-memory list; "Undo" via Snackbar is the only recovery.)
- Share / export, Edit Info, bulk selection.
- A real Reader (score rendering / audio).
- **Persistence across launches.** The store is in-memory; imported scores
  do not survive an app restart. The imported `.mscz` file itself is not
  retained (the stub Reader needs only the title).
- Full localization of new Android strings (English-first; matches the
  Settings-spike precedent — see Localization below).

## Architecture

```
  Android document picker (.mscz)  ──ByteArray──▶  LibraryAndroidStoreViewModel (Kotlin, generated)
                                                        │  vm.importScore(bytes)   [external fun → JNI]
                                                        ▼
                                   ┌───────────────────────────────────────────┐
                                   │ LibraryAndroidStore (Swift)               │
                                   │ @WireletObservable @Observable, final     │
                                   │  • var scores: [ScoreRowWire]  (stored)   │
                                   │  • @WireletExpose importScore(_:Data)     │
                                   │       → SheetMusic.loadScore(msczData:)   │
                                   │       → append ScoreRowWire, rebuild      │
                                   │  • @WireletExpose delete(_ id: String)    │
                                   └───────────────────────────────────────────┘
                                                        │  Observation onChange
                                                        ▼
                                   StateFlow<List<ScoreRowWire>>  ──collect──▶  Compose LibraryScreen
```

### Swift side

New Android-only target in the **Library** package, gated by an `isAndroid`
env flag (mirrors swift-sheet-music's `SWIFT_SHEET_MUSIC_ANDROID` and the
Settings package's `FOLINO_ANDROID` pattern). It contains the bridged store
and the wire type, and applies the `WireletObservableBridges` SwiftPM
build-tool plugin (which emits the `@_cdecl` JNI bridges on the Android
compile).

```swift
import Wirelet

@WireFormat
public struct ScoreRowWire: Equatable, Sendable {
    public var id: String        // ScoreItemID string form
    public var title: String     // metaTags["workTitle"] (subtitle appended if present)
    public var composer: String  // metaTags["composer"] ("" when absent)
}
```

```swift
import Observation
import WireletObservable
import SheetMusicMSCX   // SheetMusic.loadScore(msczData:)

@WireletObservable
@Observable
public final class LibraryAndroidStore {
    public private(set) var scores: [ScoreRowWire] = []   // → StateFlow<List<ScoreRowWire>>

    public init() {}   // no-arg — bridge requirement

    @WireletExpose
    public func importScore(_ msczBytes: Data) {
        // Synchronous parse is fine (Foundation-only, fast); no Task needed.
        guard let score = try? SheetMusic.loadScore(msczData: msczBytes) else { return }
        let title = score.metaTags["workTitle"] ?? ""
        let composer = score.metaTags["composer"] ?? ""
        let id = UUID().uuidString
        scores.append(ScoreRowWire(id: id, title: title, composer: composer))
    }

    @WireletExpose
    public func delete(_ id: String) {
        scores.removeAll { $0.id == id }
    }
}
```

Notes:

- `scores` is a **stored** property reassigned wholesale on each mutation —
  the supported `StateFlow` path. No injected `@Observable` repository, so the
  nested-observable non-goal never applies.
- `importScore` parses synchronously. swift-sheet-music's mscz path is
  Foundation-only and fast for a single score; if profiling later shows jank,
  it can move to a `Task` with the store reassigning `scores` on the main
  actor — but the v1 contract is synchronous.
- **Open verification item:** confirm `@WireletExpose` supports a `Data`
  parameter (the bridge marshals `Data`/`[UInt8]` ↔ `jbyteArray` for
  properties; method-parameter support is asserted by the multi-arg-methods
  work but must be smoke-tested in Phase 0). Fallback if not: wrap the bytes
  in a one-field `@WireFormat` struct argument.

### Android side

Mirror `FolinoSettingsAndroid` with a new **`FolinoLibraryAndroid`** Gradle
library module:

- Applies `id("io.github.jiyimeta.wirelet") version "0.2.2"`.
- `wirelet { sources { register("main") { … } } }` emits `ScoreRowWireCodec.kt`
  (+ the `ScoreRowWire` model when `emitModels = true`).
- `wirelet { observable { register("main") { … } } }` emits
  `LibraryAndroidStoreViewModel.kt` — a `ViewModel` exposing
  `val scores: StateFlow<List<ScoreRowWire>>`, `fun importScore(bytes: ByteArray)`,
  and `fun delete(id: String)`.
- Bundles the cross-compiled `libFolinoLibraryJNI.so` (+ Swift runtime `.so`s)
  under `src/main/jniLibs/{arm64-v8a,x86_64}/`.
- Depends on `io.github.jiyimeta:wirelet-runtime:0.2.2` and
  `io.github.jiyimeta:wirelet-observable-runtime:0.2.2`.

`Android/app` gains:

- `ui/library/LibraryScreen.kt` — the one screen (details below).
- `ui/library/ReaderStubScreen.kt` — shows the tapped title.
- A **bottom-navigation** scaffold in `MainActivity` with Library (start) and
  Settings destinations; Settings reuses the existing `SettingsScreen`.

### Bridge data contract

| Swift | Kotlin (generated) |
|---|---|
| `var scores: [ScoreRowWire]` | `val scores: StateFlow<List<ScoreRowWire>>` |
| `func importScore(_ b: Data)` | `fun importScore(bytes: ByteArray)` |
| `func delete(_ id: String)` | `fun delete(id: String)` |
| `struct ScoreRowWire` | `data class ScoreRowWire(id, title, composer)` |

One-way observation only (Swift → Kotlin). Mutations cross Kotlin → Swift via
the two methods.

## UI / UX (Android idioms; iOS content)

Single screen, Material 3:

```
┌────────────────────────────┐
│ Library                    │  ← top app bar, title "Library"
├────────────────────────────┤
│ ♪  Gymnopédie No. 1        │  ← ListItem: leading music-note icon,
│    Erik Satie              │     headline = title, supporting = composer
│ ♪  Clair de Lune           │
│    Claude Debussy          │
│                     ╭────╮ │
│                     │ +  │ │  ← FAB: import (.mscz document picker)
│                     ╰────╯ │
├────────────────────────────┤
│  [ ♪ Library ] [ ⚙ Settings ] │  ← bottom navigation
└────────────────────────────┘
```

- **Import** → **FAB** (bottom-right). iOS uses a toolbar `+` menu; the single
  primary action maps to a FAB on Android. Tapping launches
  `ActivityResultContracts.OpenDocument` filtered to `.mscz`
  (`application/octet-stream` + extension check). The picked `Uri` is read to
  a `ByteArray` and passed to `vm.importScore(bytes)`.
- **Delete** → **swipe-to-dismiss** (`SwipeToDismissBox`) revealing a trash
  affordance, calling `vm.delete(id)`, followed by a **Snackbar** "Score
  deleted · UNDO". Undo re-inserts by re-importing the retained
  `ScoreRowWire` (kept in Kotlin memory until the Snackbar dismisses) — since
  there is no Trash screen, the Snackbar is the only recovery.
  - *Open item:* "Undo via re-insert" needs a Swift entry point that takes a
    full `ScoreRowWire` (not just a freshly-parsed file). Either add a
    `@WireletExpose func insert(_ row: ScoreRowWire)` to the store, or scope
    Undo to a pure-Kotlin optimistic-list overlay. Resolve in the plan; the
    simplest is the extra `insert` method (keeps the list authoritative in
    Swift).
- **Row content** mirrors iOS `ScoreRow`: title (with subtitle folded in) as
  the headline, composer as the supporting line. The favorite star is **out
  of scope** this pass. Leading icon: Material `Icons.Filled.MusicNote`.
- **Tap** a row → Navigation to `ReaderStubScreen`, passing the title as a nav
  argument (no Swift round-trip needed — the row already carries it).
- **Empty state** mirrors iOS copy: centered "No Scores Yet" + "Import your
  first score to get started".

### Localization

The Android strings for this screen ("Library", "No Scores Yet", the import
hint, "Score deleted", "UNDO") are authored in `res/values/strings.xml` with
**English first**, matching the iOS copy and the Settings-spike precedent
(the spike hardcoded English). Adding `values-ja/` and the other four locales
to match the iOS `xcstrings` set is a fast follow-up, tracked but **out of
scope** for the pilot.

## Build / codegen wiring

- **Library package** (`Packages/Features/Library/Package.swift`): add the
  `isAndroid` flag; when set, add the `FolinoLibraryJNI` dynamic-library
  target (containing `LibraryAndroidStore` + `ScoreRowWire`), with deps on
  `Wirelet`, `WireletObservable`, `SwiftJava`, and swift-sheet-music's
  `SheetMusicMSCX` (or the umbrella `SheetMusic`), plus the
  `WireletObservableBridges` build-tool plugin. Apple builds are untouched
  (the target only exists under `isAndroid`).
- **Cross-compile script**: extend the existing Settings `.so` build
  (`Scripts/android-build-libs.sh` or a sibling) to also build
  `libFolinoLibraryJNI.so` for `aarch64-unknown-linux-android28` (+ `x86_64`)
  and stage it (plus the Swift runtime + swift-sheet-music `.so`s) into
  `Android/FolinoLibraryAndroid/src/main/jniLibs/`.
- **Gradle**: register `FolinoLibraryAndroid` in `Android/settings.gradle.kts`;
  `app` depends on it; `MainActivity` wires the bottom-nav scaffold.

## Dependency bumps

- **swift-wirelet** → **v0.2.2** (`revision cd0d148e9d4dddad1c6afc47d5ef0a8d6f4a4a13`)
  everywhere Folino pins it (the relevant `Package.swift` files **and**
  `project.yml`'s `packages:` entry, per the repo's dual-update rule). Verify
  the Settings spike still builds against v0.2.2 (additive, source-compatible
  minor bump — expected clean).
- **swift-sheet-music** → the Android-ready revision that exposes the
  Foundation-only mscz path and consumes swift-wirelet Phase 5 (pin to the
  current `main` SHA used by its Android CI). Update `Package.swift` +
  `project.yml` in lockstep.

Both are existing dependencies, so these are **version bumps** (auto-approved
per the repo's autonomous ground rules), not additions.

## Risks & validation order

1. **Bridge reactive path (highest value).** Confirm a stored
   `[@WireFormat]` array on a `@WireletObservable` class round-trips to a live
   `StateFlow<List<…>>` that re-emits on mutation. Validate with the smallest
   possible store **before** wiring mscz or the real UI.
2. **`Data` method parameter** across `@WireletExpose` (see Swift-side open
   item). Smoke-test in Phase 0; fall back to a `@WireFormat` wrapper arg if
   unsupported.
3. **mscz parse on Android.** Confirm `SheetMusic.loadScore(msczData:)` links
   and runs inside `libFolinoLibraryJNI.so` (zlib + XMLParser availability in
   the Android `.so`).
4. **Two `.so`s, one app.** `libFolinoSettingsJNI.so` and
   `libFolinoLibraryJNI.so` coexisting — Swift-runtime `.so` dedup and
   `JNI_OnLoad` registration must not collide.

## Testing strategy

| Layer | Location | Coverage |
|---|---|---|
| Swift store logic | `Packages/Features/Library/Tests/…` (Swift Testing) | `importScore` parses a fixture `.mscz` → correct title/composer row; `delete` removes by id; both mutate `scores`. Host-side (macOS) test against the same Foundation-only code path. |
| Wire type | same | `ScoreRowWire` encode/decode round-trip (parity with the Kotlin codec). |
| Kotlin VM generation | Gradle build | `LibraryAndroidStoreViewModel.kt` is generated with the expected `StateFlow`/`fun` surface (build succeeds + golden check optional). |
| Android smoke | manual (user, clean build) | Install APK, import a real `.mscz`, see the row appear, tap → stub Reader shows title, swipe → row removed + Undo restores. Per repo convention, Claude builds; the user performs the device gestures. |

## Phasing (for the implementation plan)

0. **De-risk spikes** — minimal `@WireletObservable` store with a stored
   `[@WireFormat]` array + a `Data`-param method; cross-compile, confirm
   `StateFlow` re-emits and the `Data` arg path works. Bump swift-wirelet to
   v0.2.2 and confirm Settings still builds.
1. **Swift store + wire type** — `ScoreRowWire`, `LibraryAndroidStore`,
   `importScore`/`delete`, the `FolinoLibraryJNI` target, host-side tests.
2. **Cross-compile + Gradle module** — `libFolinoLibraryJNI.so`,
   `FolinoLibraryAndroid` module, generated ViewModel compiles.
3. **Compose UI** — `LibraryScreen` (list, FAB import, swipe-delete + Undo,
   empty state), `ReaderStubScreen`, bottom-nav scaffold.
4. **End-to-end smoke** — build the APK; hand to the user for device
   verification.

## Open questions (resolve during planning)

- **Undo mechanism** — extra `@WireletExpose func insert(_ row: ScoreRowWire)`
  vs. pure-Kotlin optimistic overlay. Leaning toward the Swift `insert` to
  keep the list authoritative in Swift.
- **`Data` method-parameter support** — verify in Phase 0; wrapper-struct
  fallback ready.
- **mscz file retention** — pilot keeps title only (no file copy). If a later
  phase needs the real Reader, persistence + a ScoreFiles-on-Android story is
  required (separate spec).
- **Exact swift-sheet-music revision** — pin to its current Android-CI `main`
  SHA when writing the plan.
