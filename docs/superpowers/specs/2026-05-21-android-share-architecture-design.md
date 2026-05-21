# Android-Sharable Architecture: Library pilot

Date: 2026-05-21

## Goal

Establish an architectural split inside Folino's Feature packages that lets
the same Swift logic compile for both iOS (SwiftUI) and Android (Jetpack
Compose via Swift Android toolchain). Validate the approach with a
**single pilot scoped to the Library feature**, on a worktree branched
from local `main`. Do not regress iOS behavior.

The pilot deliberately stops at "Library list renders in Compose, driven
by Swift logic." Reader / Editor / Audio / Layout sharing are out of scope
here; they are addressed in follow-up specs after this pilot validates the
core idea.

## Non-goals

- Porting Domain protocol implementations (SQLite, CloudKit, file I/O) to
  Android. The pilot uses in-memory stubs.
- Touching the Reader, Editor, ImportExport, or Settings feature packages
  in this spec.
- Adding `.android` to `swift-sheet-music`'s `platforms` declaration.
  LibraryLogic does not depend on swift-sheet-music's Apple-only targets.
- A standalone `folino-android` repository. The Android scaffold lives
  inside the iOS repo's worktree for the duration of the pilot.

## Background

### Current state

- `Domain` is already Foundation-only (`@_exported import SheetMusicCore`
  is its only external surface). Android-portable in principle.
- ViewModels under `Packages/Features/*/Sources/` are uniformly
  `@MainActor @Observable` classes. Pure-logic content per ViewModel is
  uneven: Library / RecentlyDeleted / Settings VMs are predominantly
  Domain-protocol orchestration (good extraction candidates); Reader and
  PlaybackMixer are tangled with Apple frameworks (AVFoundation, PiP,
  CoreGraphics).
- There is no existing reducer / store / usecase layer between ViewModel
  and Domain. State lives directly in the VM.

### What changes & what does not

The Domain layer, Infrastructure layer, and the rules in
`docs/engineering/module-architecture.md` (Feature ↛ Feature, Feature ↛
Infrastructure, constructor DI only, etc.) do not change. The only
structural change is **inside the Library feature package**: it gains a
second SPM product, `LibraryLogic`, alongside the existing `Library`
product.

## Architecture

### Module graph after the change

```
Packages/
  Utility/                  (no change)
  Domain/                   (no change — Foundation only, @_exported SheetMusicCore)
  Infrastructure/           (no change — iOS-only adapters)
  Features/
    Library/                Package.swift now exposes TWO products:
      ├─ LibraryLogic       NEW: Foundation + Observation only
      │                       Depends on: Domain
      │                       Builds for: iOS, macOS, (Android via Swift toolchain)
      └─ Library            Thinned: iOS SwiftUI Views + iOS-only presenters
                              Depends on: LibraryLogic, Domain
    Reader/                 (no change in this spec)
    Editor/                 (no change)
    ImportExport/           (no change)
    Settings/               (no change in this spec)
  App/                      depends on Library — unchanged
```

Android side (out-of-tree, lives under the worktree's repo root):

```
Android/                                Swift Android toolchain build target
  settings.gradle.kts
  build.gradle.kts
  app/
    src/main/
      kotlin/com/keynumber/folino/
        MainActivity.kt
        ui/library/
          LibraryScreen.kt              Compose UI
          LibraryViewModel.kt           Compose-side wrapper over Swift LibraryStore
          LibraryStoreBinding.kt        Observation → Compose State bridge
        stub/
          InMemoryRepository.kt         ScoreLibraryRepository stub
      cpp/                              JNI glue
        CMakeLists.txt
        library_logic_bridge.cpp
      jniLibs/<abi>/libLibraryLogic.so  Built by scripts/build-library-logic.sh
  scripts/
    build-library-logic.sh              Drives Swift Android toolchain build
```

### LibraryLogic target shape

Files moving into `LibraryLogic`:

```
Packages/Features/Library/Sources/LibraryLogic/
  LibraryStore.swift            Extracted from LibraryViewModel (pure portion)
  ScoreListStore.swift          From ScoreListViewModel
  RecentlyDeletedStore.swift    From RecentlyDeletedViewModel
  ImportPlanValidator.swift     Pure validation function extracted from LibraryViewModel
  LibraryError.swift            enum; carries no localized strings
```

What does NOT move into `LibraryLogic` (stays in iOS UI side):

- Localized error strings — `LibraryError` is an enum with no message
  payload; SwiftUI Views translate cases to `LocalizedStringKey`.
- `UIActivityViewController` / `UIDocumentPicker` glue — Stores expose
  intent (e.g. `shareRequest`); the iOS View captures and presents.
- Any `UIImage` / `UIColor` / SwiftUI binding helper.

Observability and threading:

- Stores are `@Observable` (Observation framework). Android runtime
  support is unproven; see Risks.
- Stores are `@MainActor`. SwiftUI binding and Compose State both require
  main-thread mutation; we start with the simple assumption that the
  Swift Android toolchain's `MainActor` maps to the Android main looper.
  If it does not, see Risks.

DI is unchanged: constructor takes Domain protocols.

```swift
@MainActor
@Observable
public final class LibraryStore {
    private let repository: any ScoreLibraryRepository
    private let importer: any ScoreFileImporter
    private let shareService: any ScoreShareService

    public init(
        repository: any ScoreLibraryRepository,
        importer: any ScoreFileImporter,
        shareService: any ScoreShareService
    ) { ... }

    public func search(_ query: String) { ... }
    public func startImport(urls: [URL]) async { ... }
    // intent surface only — no UIKit, no SwiftUI binding helpers
}
```

`Package.swift` shape (abridged):

```swift
products: [
    .library(name: "LibraryLogic", targets: ["LibraryLogic"]),
    .library(name: "Library", targets: ["Library"]),
],
targets: [
    .target(
        name: "LibraryLogic",
        dependencies: [.product(name: "Domain", package: "Domain")],
    ),
    .target(
        name: "Library",
        dependencies: ["LibraryLogic", .product(name: "Domain", package: "Domain"), ...],
    ),
    .testTarget(name: "LibraryLogicTests", dependencies: ["LibraryLogic"]),
    .testTarget(name: "LibraryTests",      dependencies: ["Library"]),
],
```

### iOS Library target after thinning

Existing `Screens/` + `Views/` split is preserved (see
`memory/project_screen_view_split.md`). New surface added only where
iOS-specific presentation is needed.

```
Packages/Features/Library/Sources/Library/
  Screens/
    LibraryScreen.swift             @Bindable var store: LibraryStore
    RecentlyDeletedScreen.swift
  Views/                            (existing small SwiftUI pieces)
  iOSPresenters/                    New if needed
    ShareSheet.swift                UIActivityViewController wrapper
    DocumentPicker.swift            UIDocumentPicker wrapper
  Localizable/                      Existing localized catalogs unchanged
```

App composition root constructs the `LibraryStore` with Infrastructure
implementations and hands it to `LibraryScreen` — same pattern as today,
just with a different concrete type at the boundary.

Responsibilities split:

| Concern                                | LibraryLogic | Library (iOS) |
| -------------------------------------- | ------------ | ------------- |
| Observable state                       | ✓            | —             |
| Domain protocol orchestration          | ✓            | —             |
| Error value representation (`enum`)    | ✓            | —             |
| Localized message string               | —            | ✓             |
| Share sheet / file picker presentation | —            | ✓             |
| Navigation stack                       | —            | ✓             |

User-visible behavior on iOS at the end of the pilot must be identical
to today. This refactor introduces no new features and changes no copy.

### Android pilot side

Pilot scope is intentionally narrow:

- Domain protocol implementations on Android are **in-memory stubs**.
  SQLite / CloudKit / file I/O on Android is out of scope.
- Of the LibraryStore surface, the pilot exercises: list rendering, live
  search, sort/filter, single-item selection (navigating to a stub
  detail screen), and delete (mutating the in-memory stub). Import,
  share, and recently-deleted compile-clean but are not driven from the
  Compose UI in the pilot.

The Swift Android toolchain ships `LibraryLogic` as a `.so` placed under
`Android/app/src/main/jniLibs/<abi>/`. The build script lives at
`Android/scripts/build-library-logic.sh` and is invoked manually (not
wired into the Gradle build for the pilot — keep iteration explicit).

#### JNI surface

Hand-written, intentionally minimal. Use `@_cdecl` C-callable Swift
wrappers, not `swift-java` interop (the latter is too young to depend on
for this pilot).

```swift
// LibraryLogic/JNI/CBridge.swift  (compiled only on Android target)
@_cdecl("folino_library_store_create")
public func folino_library_store_create(...) -> UnsafeMutableRawPointer { ... }

@_cdecl("folino_library_store_set_search_text")
public func folino_library_store_set_search_text(
    _ ptr: UnsafeMutableRawPointer,
    _ cstr: UnsafePointer<CChar>
) { ... }
// ~5 functions in total
```

Kotlin side:

```kotlin
class LibraryStoreHandle {
    private val ptr: Long = nativeCreate(...)
    fun setSearchText(s: String) = nativeSetSearchText(ptr, s)
    external fun nativeCreate(...): Long
    external fun nativeSetSearchText(ptr: Long, s: String)
}
```

#### Observation → Compose State bridge

```swift
@_cdecl("folino_library_store_observe_search_results")
public func observe(
    _ ptr: UnsafeMutableRawPointer,
    _ callback: @convention(c) (UnsafeRawPointer) -> Void
) {
    // Internal: withObservationTracking { _ = store.searchResults } onChange: { fire & re-arm }
}
```

On the Kotlin side, a small helper holds a `mutableStateOf(...)` and
updates it from the JNI callback so that Compose recomposes. The helper
is pilot-local; promoting it to a reusable library is a follow-up
decision.

#### Pilot success criteria

- Android emulator shows a Compose screen listing 5 in-memory stub
  scores.
- Typing in the search field mutates `LibraryStore.searchText` through
  JNI and the visible list recomposes.
- Tapping a row navigates to a stub detail screen.
- iOS Library screen behaves identically to today (feature parity).

## Testing

### iOS tests

```
Packages/Features/Library/Tests/
  LibraryLogicTests/        NEW — Swift Testing, Foundation only
    LibraryStoreTests.swift
    ScoreListStoreTests.swift
    RecentlyDeletedStoreTests.swift
    ImportPlanValidatorTests.swift
    Fakes/
      FakeScoreLibraryRepository.swift   moved from LibraryTests
      FakeScoreFileImporter.swift
      FakeScoreShareService.swift
  LibraryTests/             Existing tests; logic-only ones migrated out
```

Invariants for `LibraryLogicTests`:

- Imports are restricted to `Domain` and `LibraryLogic`. No `SwiftUI`,
  no `UIKit`, no `XCTest` (Swift Testing only).
- `swift test --package-path Packages/Features/Library --filter LibraryLogicTests`
  runs from the CLI without Xcode.

### Android tests

Pilot scope is intentionally low:

- The JNI bridge gets one Kotlin smoke test
  (`LibraryStoreHandleSmokeTest`) covering create → mutate → observe →
  destroy. This is purely a crash / type-mismatch guard.
- No Compose unit tests. UI validation is manual on the emulator
  (screenshots if the pilot needs a record).
- Re-running `LibraryLogicTests` under the Android Swift toolchain is
  out of scope; revisit once toolchain test-bundle support is mature.

## Risks & fallbacks

| Risk                                                                  | Detection                                                                                  | Response                                                                                                                                                                                                |
| --------------------------------------------------------------------- | ------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Observation framework does not work under Android Swift runtime       | `@Observable` property changes do not propagate through `withObservationTracking` callback | **Plan B**: replace `@Observable` macro usage in LibraryLogic with a hand-rolled callback-registration wrapper. The Store API surface is preserved; only the observation mechanism changes.             |
| `@MainActor` does not behave as expected under Android Swift runtime  | Crashes, data races, or unreachable code paths during pilot                                | **Pause the pilot and re-evaluate in a new spec**. Worktree changes are kept (no revert). The next spec compares options like dropping `@MainActor` from Logic and hopping to MainActor at the UI edge. |
| Swift Android toolchain itself is a blocker (linker, stdlib, ABI)     | `scripts/build-library-logic.sh` cannot produce a usable `.so`                             | Pause the pilot. Wait for toolchain updates, or pivot to KMP in a separate spec.                                                                                                                        |
| `withObservationTracking` re-arm interacts poorly with JNI callbacks  | Compose updates drop or fire recursively                                                   | Add diff / debounce in the bridge helper. No spec revision needed.                                                                                                                                      |
| iOS Library regressions during the refactor                           | Existing LibraryTests, manual smoke                                                        | Keep the LibraryViewModel → LibraryStore migration a behavior-preserving refactor. No new user-facing behavior in the same commit / PR.                                                                 |

## Out of scope (deferred)

- Applying the `*Logic` / `*` (UI) split to other Feature packages
  (Reader, Editor, ImportExport, Settings).
- Audio / Layout abstractions (PlaybackController, SheetMusicLayout
  Android equivalents). Required before any Reader pilot.
- Android-side production implementations of Domain protocols
  (persistence, file I/O, sync, share).
- swift-sheet-music's Android platform declaration.
- `folino-android` as an independent repository / its release pipeline.

## Future direction (post-pilot)

If the pilot succeeds:

1. Codify the rule in `CLAUDE.md`: "Feature packages split into
   `*Logic` (Foundation + Observation only) and `*` (iOS UI) products."
2. Apply the same split to Settings next (smallest VMs, fastest payoff).
3. Continue with Editor, then ImportExport, then Reader. Reader requires
   a separate spec for Audio / Layout abstraction.
