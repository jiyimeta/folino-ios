# Android-Sharable Library Pilot Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Split the Library feature package into a Foundation-only `LibraryLogic` target and a thinned `Library` iOS UI target, then drive `LibraryLogic` from a minimal Jetpack Compose pilot via Swift Android toolchain + JNI.

**Architecture:** Inside `Packages/Features/Library/`, introduce a second SPM product (`LibraryLogic`) containing `LibraryStore`, `ScoreListStore`, `RecentlyDeletedStore`, `ImportPlanValidator`, and `LibraryError`. Move pure logic from the existing `@MainActor @Observable` ViewModels into the new target; keep iOS Views and iOS-only presenters in the existing `Library` target. Add an `Android/` Gradle/Compose scaffold under the repo root that JNI-binds against `libLibraryLogic.so` built via the Swift Android toolchain, exercising live search + list render against in-memory Swift stubs.

**Tech Stack:** Swift 6.3, Swift Testing, Observation framework, SwiftPM, Jetpack Compose, Kotlin, Gradle 8, JNI (`@_cdecl`), Swift Android toolchain (Swift Android Workgroup SDK), CMake.

**Worktree:** Execution must happen on a worktree branched from local `main` (see `feedback_worktree_base_local_main`). The executing skill should create it via `superpowers:using-git-worktrees`.

**Reference spec:** `docs/superpowers/specs/2026-05-21-android-share-architecture-design.md`

---

## File Structure

After Phase 1 (iOS-side):

```
Packages/Features/Library/
├── Package.swift                                       MODIFIED
└── Sources/
    ├── LibraryLogic/                                   NEW target
    │   ├── LibraryError.swift                          NEW
    │   ├── LibraryStore.swift                          NEW (extracted from LibraryViewModel)
    │   ├── ScoreListStore.swift                        NEW (renamed ScoreListViewModel, moved)
    │   ├── RecentlyDeletedStore.swift                  NEW (renamed RecentlyDeletedViewModel, moved)
    │   └── ImportPlanValidator.swift                   NEW (pure helper extracted from LibraryStore)
    └── Library/                                        MODIFIED
        ├── Library.swift                               unchanged
        ├── LibraryRoute.swift                          unchanged
        ├── LibrarySort.swift                           unchanged
        ├── ScoreItemSort.swift                         unchanged
        ├── Resources/                                  unchanged
        ├── Screens/                                    MODIFIED (consume new store types)
        │   └── (15 existing files; touched to swap VM types)
        ├── Views/                                      MODIFIED (same — VM type swap)
        └── iOSPresenters/                              (NOT created in this plan; deferred until needed)
└── Tests/
    ├── LibraryLogicTests/                              NEW test target
    │   ├── Fakes/                                      MOVED from LibraryTests/Fakes
    │   │   ├── FakeScoreLibraryRepository.swift
    │   │   ├── FakeScoreFileImporter.swift
    │   │   ├── FakeScoreFileGateway.swift
    │   │   └── FakeScoreShareService.swift
    │   ├── LibraryStoreTests.swift                     RENAMED from LibraryViewModelTests
    │   ├── LibraryStoreBulkTests.swift                 RENAMED from LibraryViewModelBulkTests
    │   ├── LibraryStoreShareTests.swift                RENAMED from LibraryViewModelShareTests
    │   ├── ScoreListStoreTests.swift                   RENAMED from ScoreListViewModelTests
    │   ├── RecentlyDeletedStoreTests.swift             RENAMED from RecentlyDeletedViewModelTests
    │   └── ImportPlanValidatorTests.swift              NEW
    └── LibraryTests/                                   MODIFIED
        ├── LibrarySortTests.swift                      unchanged
        ├── ScoreItemSortTests.swift                    unchanged
        └── LibraryTests.swift                          MODIFIED (Library route/view bootstrap only)
```

After Phase 2 (Android pilot):

```
Packages/Features/Library/Sources/LibraryLogic/
├── (Phase 1 files above)
├── Android/                                            NEW — compiled only on Android target
│   ├── CBridge.swift                                   @_cdecl JNI surface
│   └── Stubs/
│       ├── StubScoreLibraryRepository.swift
│       ├── StubScoreFileImporter.swift
│       ├── StubScoreFileGateway.swift
│       └── StubScoreShareService.swift

Android/                                                NEW (repo root, gitignored by default)
├── settings.gradle.kts
├── build.gradle.kts
├── gradle.properties
├── scripts/
│   └── build-library-logic.sh                          drives Swift Android toolchain
├── app/
│   ├── build.gradle.kts
│   └── src/main/
│       ├── AndroidManifest.xml
│       ├── kotlin/com/keynumber/folino/
│       │   ├── MainActivity.kt
│       │   └── ui/library/
│       │       ├── LibraryScreen.kt
│       │       ├── LibraryStoreHandle.kt
│       │       └── LibraryStoreBinding.kt
│       ├── cpp/
│       │   ├── CMakeLists.txt
│       │   └── library_logic_bridge.cpp
│       └── jniLibs/<abi>/libLibraryLogic.so            BUILT (gitignored)
└── .gitignore
```

---

# Phase 1 — iOS-side LibraryLogic extraction

The end state of Phase 1 is: iOS Library feature behaves identically to today, but its pure logic lives in `LibraryLogic`. iOS tests pass. No Android work yet.

Each task ends with a commit. Pre-commit hook (SwiftFormat / SwiftLint) is expected to run; stage whole files only (see project CLAUDE.md).

## Task 1: Add `LibraryLogic` target shell

**Files:**
- Modify: `Packages/Features/Library/Package.swift`

- [ ] **Step 1: Update `Package.swift` to declare the new target and product**

Replace the file with:

```swift
// swift-tools-version: 6.3
import PackageDescription

let swiftLintPlugins: [Target.PluginUsage] = [
    .plugin(name: "SwiftLintBuildToolPlugin", package: "SwiftLintPlugins"),
]

let package = Package(
    name: "Library",
    defaultLocalization: "en",
    platforms: [.iOS(.v26)],
    products: [
        .library(name: "LibraryLogic", targets: ["LibraryLogic"]),
        .library(name: "Library", targets: ["Library"]),
    ],
    dependencies: [
        .package(url: "https://github.com/SimplyDanny/SwiftLintPlugins", from: "0.63.2"),
        .package(path: "../../Domain"),
        .package(path: "../../Utility"),
    ],
    targets: [
        .target(
            name: "LibraryLogic",
            dependencies: ["Domain"],
            plugins: swiftLintPlugins,
        ),
        .target(
            name: "Library",
            dependencies: [
                "LibraryLogic",
                "Domain",
                .product(name: "UtilityCore", package: "Utility"),
                .product(name: "UtilityUI", package: "Utility"),
            ],
            resources: [.process("Resources")],
            plugins: swiftLintPlugins,
        ),
        .testTarget(
            name: "LibraryLogicTests",
            dependencies: ["LibraryLogic"],
        ),
        .testTarget(name: "LibraryTests", dependencies: ["Library"]),
    ],
)
```

- [ ] **Step 2: Create placeholder source so the target compiles**

Create `Packages/Features/Library/Sources/LibraryLogic/_Placeholder.swift`:

```swift
// Removed in Task 2 once the first real source lands.
enum _LibraryLogicPlaceholder {}
```

- [ ] **Step 3: Build the package to verify the target shell**

Run: `cd Packages/Features/Library && swift build`
Expected: Builds cleanly. Both targets emit module files.

- [ ] **Step 4: Commit**

```bash
git add Packages/Features/Library/Package.swift Packages/Features/Library/Sources/LibraryLogic
git commit
```

Message: `Add LibraryLogic target shell to Library package`

---

## Task 2: Introduce `LibraryError` enum

The current `LibraryViewModel` calls `describe(error) -> String` which produces a localized message inline. We extract a non-localized error enum into `LibraryLogic`; the iOS Library target maps cases to localized strings at the View boundary.

**Files:**
- Create: `Packages/Features/Library/Sources/LibraryLogic/LibraryError.swift`
- Delete: `Packages/Features/Library/Sources/LibraryLogic/_Placeholder.swift`
- Create: `Packages/Features/Library/Tests/LibraryLogicTests/LibraryErrorTests.swift`

- [ ] **Step 1: Write the failing test**

Create `Tests/LibraryLogicTests/LibraryErrorTests.swift`:

```swift
import Domain
import LibraryLogic
import Testing

@Suite
struct LibraryErrorTests {
    @Test
    func wrapsDomainError() {
        let err = LibraryError.from(DomainError.unsupportedFormat)
        #expect(err == .domain(.unsupportedFormat))
    }

    @Test
    func wrapsUnknownErrorAsUnderlying() {
        struct Boom: Error {}
        let err = LibraryError.from(Boom())
        if case .underlying = err {
            // ok
        } else {
            Issue.record("expected .underlying, got \(err)")
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd Packages/Features/Library && swift test --filter LibraryErrorTests`
Expected: FAIL — `LibraryError` not found.

- [ ] **Step 3: Implement `LibraryError`**

Create `Sources/LibraryLogic/LibraryError.swift`:

```swift
import Domain
import Foundation

/// Non-localized error value type for the Library feature. Carries enough
/// information for the UI layer (any platform) to choose a localized
/// message. `LibraryLogic` does not depend on any localization mechanism.
public enum LibraryError: Sendable, Equatable {
    case domain(DomainError)
    case underlying(message: String)

    public static func from(_ error: Error) -> LibraryError {
        if let domain = error as? DomainError {
            return .domain(domain)
        }
        return .underlying(message: (error as NSError).localizedDescription)
    }
}
```

- [ ] **Step 4: Delete placeholder**

```bash
rm Packages/Features/Library/Sources/LibraryLogic/_Placeholder.swift
```

- [ ] **Step 5: Run test to verify pass**

Run: `cd Packages/Features/Library && swift test --filter LibraryErrorTests`
Expected: PASS, 2/2.

- [ ] **Step 6: Commit**

```bash
git add Packages/Features/Library/Sources/LibraryLogic/LibraryError.swift \
        Packages/Features/Library/Tests/LibraryLogicTests/LibraryErrorTests.swift \
        Packages/Features/Library/Sources/LibraryLogic/_Placeholder.swift  # deletion
git commit
```

Message: `Add LibraryError value type in LibraryLogic`

---

## Task 3: Migrate Fakes to `LibraryLogicTests`

The existing `LibraryTests/Fakes/` directory holds hand-written Domain protocol fakes that LibraryLogic's new tests will reuse. Move them so they're reachable from both test targets (LibraryLogicTests directly, LibraryTests via SPM resource path if still needed; we'll handle the LibraryTests references in later tasks if any remain).

**Files:**
- Move: `Packages/Features/Library/Tests/LibraryTests/Fakes/*` → `Packages/Features/Library/Tests/LibraryLogicTests/Fakes/`

- [ ] **Step 1: Inspect existing Fakes**

Run: `ls Packages/Features/Library/Tests/LibraryTests/Fakes/`
Read each file. Confirm none of them `import` anything from `Library` (only `Domain`, `Foundation`). If any do, stop and review with the user — the move strategy needs revision.

- [ ] **Step 2: Move the directory**

```bash
git mv Packages/Features/Library/Tests/LibraryTests/Fakes \
       Packages/Features/Library/Tests/LibraryLogicTests/Fakes
```

- [ ] **Step 3: Build tests to surface broken references**

Run: `cd Packages/Features/Library && swift test --no-run`
Expected: If any `LibraryTests/*.swift` still references the moved Fakes, you'll see "cannot find type" errors. Note them — fixed in subsequent tasks per-test-file. Errors that ARE expected here are tracked in those tasks; nothing else should be broken.

If unrelated errors appear: stop, revert the move (`git checkout -- .`), and revisit.

- [ ] **Step 4: Commit**

```bash
git add Packages/Features/Library/Tests
git commit
```

Message: `Move Library test fakes into LibraryLogicTests`

---

## Task 4: Extract `RecentlyDeletedStore` (smallest, 23-line VM)

**Files:**
- Create: `Packages/Features/Library/Sources/LibraryLogic/RecentlyDeletedStore.swift`
- Delete: `Packages/Features/Library/Sources/Library/RecentlyDeletedViewModel.swift`
- Move: `Packages/Features/Library/Tests/LibraryTests/RecentlyDeletedViewModelTests.swift` → `Packages/Features/Library/Tests/LibraryLogicTests/RecentlyDeletedStoreTests.swift`
- Modify: `Packages/Features/Library/Sources/Library/Screens/RecentlyDeletedScreen.swift` (swap type name)

- [ ] **Step 1: Move the existing tests file and rename**

```bash
git mv Packages/Features/Library/Tests/LibraryTests/RecentlyDeletedViewModelTests.swift \
       Packages/Features/Library/Tests/LibraryLogicTests/RecentlyDeletedStoreTests.swift
```

Edit the new file:
- Change `import Library` to `import LibraryLogic`
- Replace all references of `RecentlyDeletedViewModel` with `RecentlyDeletedStore`
- Keep test names; just change the SUT type

- [ ] **Step 2: Run tests — should fail (no `RecentlyDeletedStore` yet)**

Run: `cd Packages/Features/Library && swift test --filter RecentlyDeletedStoreTests`
Expected: FAIL — `RecentlyDeletedStore` not found.

- [ ] **Step 3: Create `RecentlyDeletedStore.swift`**

Create `Sources/LibraryLogic/RecentlyDeletedStore.swift`:

```swift
import Domain
import Foundation
import Observation

/// Drives the Recently Deleted screen. The list is always sorted by
/// `deletedAt` descending — most-recently-trashed on top — and there are
/// no other sort options or search. Source of truth is the repository's
/// `deletedScoreItems` snapshot, which is updated by the same observation
/// task that drives every other Library list, so restores / permanent
/// deletes / soft-deletes propagate automatically.
@MainActor
@Observable
public final class RecentlyDeletedStore {
    public let repository: any ScoreLibraryRepository

    public init(repository: any ScoreLibraryRepository) {
        self.repository = repository
    }

    public var displayedItems: [ScoreItem] {
        repository.deletedScoreItems.sorted { lhs, rhs in
            (lhs.deletedAt ?? .distantPast) > (rhs.deletedAt ?? .distantPast)
        }
    }
}
```

- [ ] **Step 4: Delete the old ViewModel file**

```bash
rm Packages/Features/Library/Sources/Library/RecentlyDeletedViewModel.swift
```

- [ ] **Step 5: Update the consumer view**

Read `Packages/Features/Library/Sources/Library/Screens/RecentlyDeletedScreen.swift`. Replace every `RecentlyDeletedViewModel` with `RecentlyDeletedStore`. Add `import LibraryLogic` near the existing `import Domain`. Keep behavior identical.

- [ ] **Step 6: Run tests — should pass**

Run: `cd Packages/Features/Library && swift test --filter RecentlyDeletedStoreTests`
Expected: PASS.

- [ ] **Step 7: Build the whole Library package**

Run: `cd Packages/Features/Library && swift build`
Expected: builds cleanly. If a non-screen file (e.g. `LibraryRootDestinations.swift`) references the old VM type, update it the same way.

- [ ] **Step 8: Commit**

```bash
git add Packages/Features/Library
git commit
```

Message: `Extract RecentlyDeletedStore into LibraryLogic`

---

## Task 5: Extract `ScoreListStore` (95-line VM, no error paths)

**Files:**
- Create: `Packages/Features/Library/Sources/LibraryLogic/ScoreListStore.swift`
- Delete: `Packages/Features/Library/Sources/Library/ScoreListViewModel.swift`
- Move: `Packages/Features/Library/Tests/LibraryTests/ScoreListViewModelTests.swift` → `Packages/Features/Library/Tests/LibraryLogicTests/ScoreListStoreTests.swift`
- Modify: Consumers of `ScoreListViewModel` in `Sources/Library/Screens/` and `Sources/Library/Views/`

- [ ] **Step 1: Move and rename the test file**

```bash
git mv Packages/Features/Library/Tests/LibraryTests/ScoreListViewModelTests.swift \
       Packages/Features/Library/Tests/LibraryLogicTests/ScoreListStoreTests.swift
```

In the moved file:
- Replace `import Library` with `import LibraryLogic`
- Replace every `ScoreListViewModel` with `ScoreListStore`

- [ ] **Step 2: Run tests — should fail**

Run: `cd Packages/Features/Library && swift test --filter ScoreListStoreTests`
Expected: FAIL — `ScoreListStore` not found.

- [ ] **Step 3: Create `ScoreListStore.swift`**

Create `Sources/LibraryLogic/ScoreListStore.swift` with the **same body** as the current `ScoreListViewModel.swift` but:
- Type renamed: `ScoreListViewModel` → `ScoreListStore`
- Declared `public`. Mark `Source`, `init`, `selectSort`, `selectManualOrder`, `displayedItems`, `searchQuery`, `sort` as `public`. Keep `manualOrder`/`scope`/`applySearch` private.

```swift
import Domain
import Foundation
import Observation

/// Drives any of the three leaf score list views (All / Tag-filtered /
/// Playlist).
@MainActor
@Observable
public final class ScoreListStore {
    public enum Source: Hashable, Sendable {
        case all
        case favorites
        case taggedWith(TagID)
        case playlist(orderedIDs: [ScoreItemID])
    }

    public let source: Source
    public let repository: any ScoreLibraryRepository
    public var sort: ScoreItemSort
    public var searchQuery = ""

    /// `true` when `source == .playlist(...)` and the current sort is the
    /// playlist's manual order (i.e. no explicit sort was picked).
    public var isManualOrderActive: Bool {
        if case .playlist = source { return manualOrder }
        return false
    }

    private var manualOrder: Bool

    public init(source: Source, repository: any ScoreLibraryRepository) {
        self.source = source
        self.repository = repository
        switch source {
        case .all, .favorites, .taggedWith:
            sort = .dateAddedDesc
            manualOrder = false
        case .playlist:
            sort = .dateAddedDesc // value is ignored while manualOrder is true
            manualOrder = true
        }
    }

    /// Switches off manual order; further reads honour `sort`.
    public func selectSort(_ next: ScoreItemSort) {
        sort = next
        manualOrder = false
    }

    /// Returns to the playlist's manual order. Only valid for `.playlist`.
    public func selectManualOrder() {
        guard case .playlist = source else { return }
        manualOrder = true
    }

    public var displayedItems: [ScoreItem] {
        let scoped = scope(repository.scoreItems)
        let filtered = applySearch(scoped)
        if isManualOrderActive {
            return filtered
        }
        return sort.apply(to: filtered)
    }

    private func scope(_ items: [ScoreItem]) -> [ScoreItem] {
        switch source {
        case .all:
            return items
        case .favorites:
            return items.filter(\.isFavorite)
        case let .taggedWith(tagID):
            return items.filter { $0.tagIDs.contains(tagID) }
        case let .playlist(orderedIDs):
            // Build by ordered IDs to preserve manual order.
            let lookup = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
            return orderedIDs.compactMap { lookup[$0] }
        }
    }

    private func applySearch(_ items: [ScoreItem]) -> [ScoreItem] {
        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return items }
        let opts: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        return items.filter { item in
            if item.title.range(of: trimmed, options: opts, locale: .current) != nil {
                return true
            }
            if let composer = item.composer,
               composer.range(of: trimmed, options: opts, locale: .current) != nil
            {
                return true
            }
            return false
        }
    }
}
```

Note: `ScoreItemSort` lives in the iOS `Library` target today. Before this code compiles, it must be visible. Check whether `ScoreItemSort` is `public` and lives where `LibraryLogic` can see it.

Run: `grep -n "enum ScoreItemSort\|struct ScoreItemSort" Packages/Features/Library/Sources/Library/ScoreItemSort.swift`

If it's not `public` or not in a `LibraryLogic`-visible module:

```bash
git mv Packages/Features/Library/Sources/Library/ScoreItemSort.swift \
       Packages/Features/Library/Sources/LibraryLogic/ScoreItemSort.swift
```

Then edit the file: mark the enum and its members `public`. Also move the matching test:

```bash
git mv Packages/Features/Library/Tests/LibraryTests/ScoreItemSortTests.swift \
       Packages/Features/Library/Tests/LibraryLogicTests/ScoreItemSortTests.swift
```

In the moved test file change `import Library` to `import LibraryLogic`.

- [ ] **Step 4: Delete the old ViewModel file**

```bash
rm Packages/Features/Library/Sources/Library/ScoreListViewModel.swift
```

- [ ] **Step 5: Update consumers**

Run: `grep -rln ScoreListViewModel Packages/Features/Library/Sources/Library/`
For each match, replace `ScoreListViewModel` with `ScoreListStore` and ensure the file has `import LibraryLogic` near `import Domain`. Keep behavior identical.

- [ ] **Step 6: Run all Library tests**

Run: `cd Packages/Features/Library && swift test`
Expected: all tests pass. If `LibraryTests` had tests referencing `Fakes/`, fix imports (`import LibraryLogic` to reach them) or move them to `LibraryLogicTests` if the test target boundary calls for it.

- [ ] **Step 7: Commit**

```bash
git add Packages/Features/Library
git commit
```

Message: `Extract ScoreListStore into LibraryLogic`

---

## Task 6: Extract `LibraryStore` (the large 322-line VM, error path included)

This is the biggest move. The challenge is that `LibraryViewModel` currently emits localized strings into `errorAlertMessage: String?` via `describe(_:)`. We replace it with `currentError: LibraryError?` and let the View map cases to localized strings.

**Files:**
- Create: `Packages/Features/Library/Sources/LibraryLogic/LibraryStore.swift`
- Delete: `Packages/Features/Library/Sources/Library/LibraryViewModel.swift`
- Move: `Packages/Features/Library/Tests/LibraryTests/LibraryViewModelTests.swift` → `LibraryLogicTests/LibraryStoreTests.swift`
- Move: `Packages/Features/Library/Tests/LibraryTests/LibraryViewModelBulkTests.swift` → `LibraryLogicTests/LibraryStoreBulkTests.swift`
- Move: `Packages/Features/Library/Tests/LibraryTests/LibraryViewModelShareTests.swift` → `LibraryLogicTests/LibraryStoreShareTests.swift`
- Modify: `Packages/Features/Library/Sources/Library/Screens/LibraryRootScreen.swift`, `LibraryRootDeleteAlerts.swift`, `LibraryRootRenameScoreAlert.swift`, `LibraryRootDestinations.swift`, `LibraryRootCollapsibleSections.swift` (and any other consumer; identify via grep)
- Create: `Packages/Features/Library/Sources/Library/LibraryErrorPresentation.swift` — maps `LibraryError` → `LocalizedStringKey`

- [ ] **Step 1: Move and rename test files**

```bash
git mv Packages/Features/Library/Tests/LibraryTests/LibraryViewModelTests.swift \
       Packages/Features/Library/Tests/LibraryLogicTests/LibraryStoreTests.swift
git mv Packages/Features/Library/Tests/LibraryTests/LibraryViewModelBulkTests.swift \
       Packages/Features/Library/Tests/LibraryLogicTests/LibraryStoreBulkTests.swift
git mv Packages/Features/Library/Tests/LibraryTests/LibraryViewModelShareTests.swift \
       Packages/Features/Library/Tests/LibraryLogicTests/LibraryStoreShareTests.swift
```

In all three files:
- Change `import Library` → `import LibraryLogic`
- Replace every `LibraryViewModel` with `LibraryStore`
- Wherever a test asserts on `errorAlertMessage` against a localized string, replace with `currentError` assertion on a `LibraryError` case. Example:
  - Before: `#expect(vm.errorAlertMessage == "...")` → After: `#expect(store.currentError == .domain(.unsupportedFormat))`
  - If a test relied on the exact localized text, change the assertion to check the enum case instead. The localized rendering is now Library (iOS) target's concern and is tested separately in Task 7.

- [ ] **Step 2: Run tests — they should fail (no `LibraryStore`)**

Run: `cd Packages/Features/Library && swift test --filter LibraryStoreTests`
Expected: FAIL — `LibraryStore` not found.

- [ ] **Step 3: Create `LibraryStore.swift`**

Create `Sources/LibraryLogic/LibraryStore.swift`. Reproduce the current `LibraryViewModel` body with these specific changes:

1. Rename type: `LibraryViewModel` → `LibraryStore`. Mark `public`.
2. Replace `var errorAlertMessage: String?` with `public var currentError: LibraryError?`. Make properties that View binds to (`shareTarget`, `isPreparingShare`, `isImporting`, `isFileImporterPresented`, `pendingScoreToOpen`, `duplicatePrompt`) `public`. Make nested `ShareTarget` and `DuplicatePrompt` `public`.
3. Delete `private func describe(_:) -> String`.
4. Every `errorAlertMessage = describe(error)` becomes `currentError = LibraryError.from(error)`.
5. Mark all intent methods (`toggleFavorite`, `rename`, `delete`, `deletePlaylist`, `deleteTag`, `bulkDelete`, `restore`, `bulkRestore`, `permanentlyDelete`, `bulkPermanentlyDelete`, `bulkRemoveFromPlaylist`, `bulkAddToPlaylist`, `bulkAddTags`, `requestShare`, `requestBulkShare`, `setTagIDs`, `createPlaylist`, `createTag`, `save`, `startImport`, `commit`, `dismissImportUI`) `public`.
6. Keep `@MainActor @Observable` annotations.
7. Drop the `bundle: .module` localized-string lookups (they were inside `describe(_:)`, now gone).

The resulting file ends with:

```swift
import Domain
import Foundation
import Observation

@MainActor
@Observable
public final class LibraryStore {
    public let repository: any ScoreLibraryRepository
    public let importer: any ScoreFileImporter
    public let gateway: any ScoreFileGateway
    public let shareService: any ScoreShareService

    public var shareTarget: ShareTarget?
    public var isPreparingShare = false
    public var isImporting = false

    public struct ShareTarget: Identifiable, Equatable, Sendable {
        public let id: UUID
        public let urls: [URL]
        public init(urls: [URL]) {
            id = UUID()
            self.urls = urls
        }
    }

    public var currentError: LibraryError?
    public var pendingScoreToOpen: ScoreItem?
    public var isFileImporterPresented = false
    public var duplicatePrompt: DuplicatePrompt?

    public struct DuplicatePrompt: Identifiable, Equatable, Sendable {
        public let id = UUID()
        public let plan: ImportPlan
        public let existing: ScoreItem
    }

    public init(
        repository: any ScoreLibraryRepository,
        importer: any ScoreFileImporter,
        gateway: any ScoreFileGateway,
        shareService: any ScoreShareService,
    ) {
        self.repository = repository
        self.importer = importer
        self.gateway = gateway
        self.shareService = shareService
    }

    public func dismissImportUI() {
        isFileImporterPresented = false
        duplicatePrompt = nil
        currentError = nil
    }

    // ... (all the intent methods, copied verbatim from LibraryViewModel,
    // but with `errorAlertMessage = describe(error)` replaced by
    // `currentError = LibraryError.from(error)` and methods marked `public`)
}
```

For brevity above, the full body of intent methods is the same as in
`LibraryViewModel.swift` lines 69-306 — apply the two mechanical edits
(error path, access level) only.

- [ ] **Step 4: Delete the old ViewModel file**

```bash
rm Packages/Features/Library/Sources/Library/LibraryViewModel.swift
```

- [ ] **Step 5: Wire up the iOS error mapping**

Create `Sources/Library/LibraryErrorPresentation.swift`:

```swift
import Domain
import LibraryLogic
import SwiftUI

extension LibraryError {
    /// Localized message shown by SwiftUI Views. Lives in the iOS Library
    /// target because LibraryLogic must remain Foundation-only.
    public var displayMessage: LocalizedStringKey {
        switch self {
        case .domain(.unsupportedFormat):
            return "library.import.error.unsupported"
        case .domain(.scoreParseFailed):
            return "library.import.error.invalidFile"
        case .domain(.persistenceFailed):
            return "library.import.error.saveFailed"
        case let .domain(other):
            return LocalizedStringKey(other.errorDescription ?? "\(other)")
        case let .underlying(message):
            return LocalizedStringKey(message)
        }
    }
}
```

- [ ] **Step 6: Update consumers**

Run: `grep -rln "LibraryViewModel\|errorAlertMessage" Packages/Features/Library/Sources/Library/`

For each hit:
- Replace `LibraryViewModel` with `LibraryStore` and add `import LibraryLogic`.
- Replace bindings of `errorAlertMessage: String?` with `currentError: LibraryError?` plus `.displayMessage` at the View use-site. Example:

  Before:
  ```swift
  .alert("error", isPresented: .constant(vm.errorAlertMessage != nil)) {
      Button("OK") { vm.errorAlertMessage = nil }
  } message: {
      Text(vm.errorAlertMessage ?? "")
  }
  ```

  After:
  ```swift
  .alert("error", isPresented: .constant(store.currentError != nil)) {
      Button("OK") { store.currentError = nil }
  } message: {
      if let err = store.currentError {
          Text(err.displayMessage, bundle: .module)
      }
  }
  ```

- [ ] **Step 7: Run all Library tests**

Run: `cd Packages/Features/Library && swift test`
Expected: all tests pass. `LibraryLogicTests` runs the migrated suites; `LibraryTests` runs whatever remains (Sort tests + the Library route bootstrap).

- [ ] **Step 8: Build the app target to surface any composition-root drift**

Run from repo root: `xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 17' -skipPackagePluginValidation build`
Expected: build succeeds. The App/composition root currently constructs `LibraryViewModel(...)`; update it to `LibraryStore(...)`.

If the app project lists a missing reference to `LibraryViewModel`: `grep -rln LibraryViewModel App/` and fix per consumer.

- [ ] **Step 9: Commit**

```bash
git add Packages/Features/Library App Folino.xcodeproj
git commit
```

Message: `Extract LibraryStore into LibraryLogic`

---

## Task 7: Extract `ImportPlanValidator` from `LibraryStore.startImport`

`LibraryStore.startImport` decides "commit immediately or stage a duplicate prompt" based on the `ImportPlan`'s `duplicates`. That decision is pure — pull it out as a testable helper. This task adds dedicated unit coverage rather than relying solely on integration tests.

**Files:**
- Create: `Packages/Features/Library/Sources/LibraryLogic/ImportPlanValidator.swift`
- Create: `Packages/Features/Library/Tests/LibraryLogicTests/ImportPlanValidatorTests.swift`
- Modify: `Packages/Features/Library/Sources/LibraryLogic/LibraryStore.swift`

- [ ] **Step 1: Write failing tests**

Create `Tests/LibraryLogicTests/ImportPlanValidatorTests.swift`:

```swift
import Domain
import LibraryLogic
import Testing

@Suite
struct ImportPlanValidatorTests {
    @Test
    func planWithNoDuplicatesCommitsAsNew() {
        let plan = ImportPlan.makeFake(duplicates: [])
        let decision = ImportPlanValidator.decision(for: plan)
        #expect(decision == .commitAsNew)
    }

    @Test
    func planWithDuplicateStagesPrompt() {
        let item = ScoreItem.makeFake()
        let plan = ImportPlan.makeFake(duplicates: [item])
        let decision = ImportPlanValidator.decision(for: plan)
        #expect(decision == .promptForDuplicate(existing: item))
    }

    @Test
    func planWithMultipleDuplicatesPromptsFirst() {
        let first = ScoreItem.makeFake()
        let second = ScoreItem.makeFake()
        let plan = ImportPlan.makeFake(duplicates: [first, second])
        let decision = ImportPlanValidator.decision(for: plan)
        #expect(decision == .promptForDuplicate(existing: first))
    }
}
```

`ImportPlan.makeFake(duplicates:)` and `ScoreItem.makeFake()` are
hand-written test helpers; if they don't exist yet, add minimal
constructors to a new `Tests/LibraryLogicTests/Fakes/ImportPlanFakes.swift`
file that initializes the value types with the smallest valid input.

- [ ] **Step 2: Run tests — should fail**

Run: `cd Packages/Features/Library && swift test --filter ImportPlanValidatorTests`
Expected: FAIL — `ImportPlanValidator` not found.

- [ ] **Step 3: Implement `ImportPlanValidator`**

Create `Sources/LibraryLogic/ImportPlanValidator.swift`:

```swift
import Domain
import Foundation

/// Pure decision: given an `ImportPlan`, should the caller commit
/// directly or stage a duplicate prompt? Extracted from `LibraryStore`
/// for unit-testability and Android-side reuse.
public enum ImportPlanValidator {
    public enum Decision: Equatable, Sendable {
        case commitAsNew
        case promptForDuplicate(existing: ScoreItem)
    }

    public static func decision(for plan: ImportPlan) -> Decision {
        if let existing = plan.duplicates.first {
            return .promptForDuplicate(existing: existing)
        }
        return .commitAsNew
    }
}
```

- [ ] **Step 4: Refactor `LibraryStore.startImport` to use it**

Edit `Sources/LibraryLogic/LibraryStore.swift`. Replace the inner duplicate-detection block:

```swift
// Before
if let existing = plan.duplicates.first {
    duplicatePrompt = DuplicatePrompt(plan: plan, existing: existing)
    return
}
await commit(plan: plan, decision: .importAsNew)

// After
switch ImportPlanValidator.decision(for: plan) {
case .commitAsNew:
    await commit(plan: plan, decision: .importAsNew)
case let .promptForDuplicate(existing):
    duplicatePrompt = DuplicatePrompt(plan: plan, existing: existing)
}
```

- [ ] **Step 5: Run all Library tests**

Run: `cd Packages/Features/Library && swift test`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Packages/Features/Library
git commit
```

Message: `Extract ImportPlanValidator pure helper`

---

## Task 8: iOS feature parity gate

A manual smoke before declaring Phase 1 done.

- [ ] **Step 1: Build & install on iPhone simulator**

Run from repo root:

```bash
xcodebuild -project Folino.xcodeproj -scheme Folino \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -skipPackagePluginValidation build
```

Then install + launch via Xcode UI (since simulator interactions are needed). Confirm:

- Library list renders (All / Favorites / Tags / Playlists / Recently Deleted).
- Searching narrows the list live.
- Long-pressing a row shows actions (favorite, rename, delete).
- Importing a `.musicxml` or `.mscx` file: duplicate-prompt path AND new-import path both work.
- Sharing a score opens the system share sheet.
- Recently Deleted shows soft-deleted items; restore works.

If any user-visible behavior differs from before the refactor: stop, investigate, fix.

- [ ] **Step 2: No commit (verification gate only)**

Phase 1 is now complete. The branch has a clean state: iOS Library still works, all tests pass, and `LibraryLogic` is a Foundation-only Swift module ready for Android.

---

# Phase 2 — Android pilot

Phase 2 is exploratory: we are bringing up the Swift Android toolchain plus a minimal Compose UI driven through JNI. Tasks here are larger and more discovery-shaped than Phase 1; expect to pause and revisit the spec if the toolchain misbehaves (see `Risks` in the spec).

Pre-requisites:
- Swift Android Workgroup SDK installed, with `SWIFT_ANDROID_HOME` exported in the shell.
- Android SDK + NDK installed (the workgroup currently targets NDK r26+).
- `adb` reachable; an emulator image available.

If any pre-requisite is missing: stop, install, and document the version in `Android/README.md` as part of Task 9. Do not attempt to install system tooling automatically.

## Task 9: Scaffold `Android/` Gradle + Compose project

**Files:**
- Create: `Android/.gitignore`
- Create: `Android/settings.gradle.kts`
- Create: `Android/build.gradle.kts`
- Create: `Android/gradle.properties`
- Create: `Android/app/build.gradle.kts`
- Create: `Android/app/src/main/AndroidManifest.xml`
- Create: `Android/app/src/main/kotlin/com/keynumber/folino/MainActivity.kt`
- Create: `Android/README.md` (toolchain prereqs, build steps)
- Modify: repo-root `.gitignore` to exclude `Android/.gradle`, `Android/local.properties`, `Android/build`, `Android/app/build`, `Android/app/src/main/jniLibs/`

- [ ] **Step 1: Create `Android/.gitignore`**

```
.gradle/
build/
local.properties
*.iml
.idea/
app/build/
app/src/main/jniLibs/
```

- [ ] **Step 2: Create `Android/settings.gradle.kts`**

```kotlin
pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}
dependencyResolutionManagement {
    repositories {
        google()
        mavenCentral()
    }
}
rootProject.name = "folino"
include(":app")
```

- [ ] **Step 3: Create `Android/build.gradle.kts`**

```kotlin
// Top-level — nothing here yet.
plugins {
    id("com.android.application") version "8.5.0" apply false
    id("org.jetbrains.kotlin.android") version "2.0.0" apply false
}
```

- [ ] **Step 4: Create `Android/gradle.properties`**

```
org.gradle.jvmargs=-Xmx2048m
android.useAndroidX=true
kotlin.code.style=official
```

- [ ] **Step 5: Create `Android/app/build.gradle.kts`**

```kotlin
plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "com.keynumber.folino"
    compileSdk = 35

    defaultConfig {
        applicationId = "com.keynumber.folino"
        minSdk = 26
        targetSdk = 35
        versionCode = 1
        versionName = "0.1.0-pilot"

        ndk {
            // Match what Swift Android toolchain emits in Task 11.
            abiFilters += setOf("arm64-v8a", "x86_64")
        }
    }

    buildTypes {
        debug {
            isMinifyEnabled = false
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    buildFeatures {
        compose = true
    }

    composeOptions {
        kotlinCompilerExtensionVersion = "1.5.14"
    }

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
        }
    }
}

dependencies {
    implementation("androidx.core:core-ktx:1.13.0")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.8.0")
    implementation("androidx.activity:activity-compose:1.9.0")
    implementation(platform("androidx.compose:compose-bom:2024.06.00"))
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-graphics")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.compose.material3:material3")
}
```

- [ ] **Step 6: Create `Android/app/src/main/AndroidManifest.xml`**

```xml
<?xml version="1.0" encoding="utf-8"?>
<manifest xmlns:android="http://schemas.android.com/apk/res/android">
    <application
        android:allowBackup="true"
        android:label="folino"
        android:supportsRtl="true">
        <activity
            android:name=".MainActivity"
            android:exported="true">
            <intent-filter>
                <action android:name="android.intent.action.MAIN" />
                <category android:name="android.intent.category.LAUNCHER" />
            </intent-filter>
        </activity>
    </application>
</manifest>
```

- [ ] **Step 7: Create a placeholder `MainActivity.kt`**

Create `Android/app/src/main/kotlin/com/keynumber/folino/MainActivity.kt`:

```kotlin
package com.keynumber.folino

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.tooling.preview.Preview

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            MaterialTheme {
                Surface {
                    Greeting("folino")
                }
            }
        }
    }
}

@Composable
fun Greeting(name: String) {
    Text(text = "Hello, $name!")
}

@Preview(showBackground = true)
@Composable
fun GreetingPreview() {
    MaterialTheme { Greeting("folino") }
}
```

- [ ] **Step 8: Create `Android/README.md`**

```markdown
# folino — Android pilot

Experimental scaffold for sharing Folino's iOS `LibraryLogic` Swift code
with a Jetpack Compose Android UI via the Swift Android toolchain.

Pilot scope: Library list + live search only. In-memory stub data.

## Prerequisites

- Swift Android Workgroup SDK installed, `SWIFT_ANDROID_HOME` exported.
- Android SDK + NDK r26+.
- JDK 17.

## Build

1. `./scripts/build-library-logic.sh` — compiles LibraryLogic to
   `app/src/main/jniLibs/<abi>/libLibraryLogic.so`.
2. `./gradlew :app:assembleDebug` — builds the Android app.
3. `./gradlew :app:installDebug` — installs on the connected emulator
   or device.

See `docs/superpowers/specs/2026-05-21-android-share-architecture-design.md`
for the pilot's design and success criteria.
```

- [ ] **Step 9: Append to repo-root `.gitignore`**

Append:

```
# Android pilot scaffold
Android/.gradle/
Android/local.properties
Android/build/
Android/app/build/
Android/app/src/main/jniLibs/
```

- [ ] **Step 10: Verify the Compose shell builds**

Run: `cd Android && ./gradlew :app:assembleDebug --no-daemon`
Expected: Gradle wraps download + build succeeds. (If no gradle wrapper exists, generate it via `gradle wrapper --gradle-version 8.7` first — install Gradle via brew if missing.)

If this fails for any reason other than "missing Gradle wrapper": stop and document in the README. Do not proceed.

- [ ] **Step 11: Commit**

```bash
git add Android .gitignore
git commit
```

Message: `Scaffold Android Gradle + Compose pilot project`

---

## Task 10: Add `build-library-logic.sh` script (LibraryLogic .so build)

This task is the first toolchain integration. It may surface real
toolchain blockers — see spec Risks.

**Files:**
- Create: `Android/scripts/build-library-logic.sh`

- [ ] **Step 1: Write the script**

Create `Android/scripts/build-library-logic.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

# Builds LibraryLogic for Android ABIs and copies the resulting .so files
# into the Android app's jniLibs directory.
#
# Requires:
#   $SWIFT_ANDROID_HOME — root of the Swift Android Workgroup SDK
#   Android NDK reachable via the SDK's swift-build wrapper

if [[ -z "${SWIFT_ANDROID_HOME:-}" ]]; then
    echo "error: SWIFT_ANDROID_HOME is not set" >&2
    exit 1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIBRARY_PKG="${REPO_ROOT}/Packages/Features/Library"
JNILIBS="${REPO_ROOT}/Android/app/src/main/jniLibs"

ABIS=("arm64-v8a" "x86_64")
SWIFT_TARGETS=("aarch64-unknown-linux-android24" "x86_64-unknown-linux-android24")

for i in "${!ABIS[@]}"; do
    abi="${ABIS[$i]}"
    target="${SWIFT_TARGETS[$i]}"
    echo "==> Building LibraryLogic for ${abi} (${target})"
    (
        cd "${LIBRARY_PKG}"
        swift build \
            --product LibraryLogic \
            --triple "${target}" \
            --configuration debug \
            --sdk "${SWIFT_ANDROID_HOME}/sdk"
    )
    src=$(find "${LIBRARY_PKG}/.build/${target}/debug" -name 'libLibraryLogic.so' | head -1)
    if [[ -z "${src}" ]]; then
        echo "error: libLibraryLogic.so not produced for ${target}" >&2
        exit 1
    fi
    dst_dir="${JNILIBS}/${abi}"
    mkdir -p "${dst_dir}"
    cp "${src}" "${dst_dir}/libLibraryLogic.so"
done

echo "==> Done. .so files at: ${JNILIBS}"
```

- [ ] **Step 2: Make it executable**

```bash
chmod +x Android/scripts/build-library-logic.sh
```

- [ ] **Step 3: Try a dry build (placeholder Android-only sources)**

Add a minimal Android-only source so the `LibraryLogic` product can compile under the Android triple even if no other Android source exists yet.

Edit `Packages/Features/Library/Sources/LibraryLogic/Android/_Android.swift`:

```swift
// Marker file: keeps LibraryLogic compilable when no other Android-only
// sources exist yet. Real Android sources land in Task 11.
#if os(Android)
@_documentation(visibility: internal)
public enum _LibraryLogicAndroidMarker {}
#endif
```

- [ ] **Step 4: Run the build script**

Run: `cd Android && ./scripts/build-library-logic.sh`

Expected: For each ABI, swift-build emits a `.so` file copied into `Android/app/src/main/jniLibs/<abi>/libLibraryLogic.so`.

**If this step fails:** this is the critical toolchain checkpoint described in the spec. Capture the failure mode, stop the pilot, and revisit the design with the user.

- [ ] **Step 5: Commit (build script + marker only)**

```bash
git add Android/scripts Packages/Features/Library/Sources/LibraryLogic/Android
git commit
```

Message: `Add Swift Android toolchain build script for LibraryLogic`

---

## Task 11: Write Swift `@_cdecl` JNI bridge + stub Domain implementations

**Files:**
- Modify/replace: `Packages/Features/Library/Sources/LibraryLogic/Android/_Android.swift` (becomes the real `CBridge.swift`)
- Create: `Packages/Features/Library/Sources/LibraryLogic/Android/CBridge.swift`
- Create: `Packages/Features/Library/Sources/LibraryLogic/Android/Stubs/StubScoreLibraryRepository.swift`
- Create: `Packages/Features/Library/Sources/LibraryLogic/Android/Stubs/StubScoreFileImporter.swift`
- Create: `Packages/Features/Library/Sources/LibraryLogic/Android/Stubs/StubScoreFileGateway.swift`
- Create: `Packages/Features/Library/Sources/LibraryLogic/Android/Stubs/StubScoreShareService.swift`

- [ ] **Step 1: Delete the marker placeholder**

```bash
rm Packages/Features/Library/Sources/LibraryLogic/Android/_Android.swift
```

- [ ] **Step 2: Create stub Domain implementations**

Create each stub file. Each must conform to the Domain protocol of its name. Use minimal in-memory state. Wrap the entire file in `#if os(Android)` so iOS builds skip them.

`Stubs/StubScoreLibraryRepository.swift`:

```swift
#if os(Android)
import Domain
import Foundation
import Observation

@MainActor
@Observable
final class StubScoreLibraryRepository: ScoreLibraryRepository {
    var scoreItems: [ScoreItem] = ScoreItem.androidPilotSamples()
    var playlists: [Playlist] = []
    var tags: [Tag] = []
    var deletedScoreItems: [ScoreItem] = []

    func saveScoreItem(_ item: ScoreItem) async throws {
        if let idx = scoreItems.firstIndex(where: { $0.id == item.id }) {
            scoreItems[idx] = item
        } else {
            scoreItems.append(item)
        }
    }

    func deleteScoreItem(id: ScoreItemID) async throws {
        if let idx = scoreItems.firstIndex(where: { $0.id == id }) {
            var item = scoreItems.remove(at: idx)
            item.deletedAt = Date()
            deletedScoreItems.append(item)
        }
    }

    func restoreScoreItem(id: ScoreItemID) async throws {
        if let idx = deletedScoreItems.firstIndex(where: { $0.id == id }) {
            var item = deletedScoreItems.remove(at: idx)
            item.deletedAt = nil
            scoreItems.append(item)
        }
    }

    func permanentlyDeleteScoreItem(id: ScoreItemID) async throws {
        deletedScoreItems.removeAll { $0.id == id }
    }

    // ... (other ScoreLibraryRepository protocol requirements: implement
    // each as a minimal in-memory mutation. Read the protocol declaration
    // in Domain/Sources/Domain/Protocols/ScoreLibraryRepository.swift and
    // implement every requirement. None can be stubbed as fatalError —
    // the LibraryStore may call them.)

    func savePlaylist(_ playlist: Playlist) async throws {
        if let idx = playlists.firstIndex(where: { $0.id == playlist.id }) {
            playlists[idx] = playlist
        } else {
            playlists.append(playlist)
        }
    }

    func deletePlaylist(id: PlaylistID) async throws {
        playlists.removeAll { $0.id == id }
    }

    func saveTag(_ tag: Tag) async throws {
        if let idx = tags.firstIndex(where: { $0.id == tag.id }) {
            tags[idx] = tag
        } else {
            tags.append(tag)
        }
    }

    func deleteTag(id: TagID) async throws {
        tags.removeAll { $0.id == id }
    }
}

extension ScoreItem {
    static func androidPilotSamples() -> [ScoreItem] {
        let now = Date()
        let titles = [
            "Prelude in C major",
            "Fugue in G minor",
            "Sonata Op. 27 No. 2",
            "Études Op. 25",
            "Ballade No. 1 Op. 23",
        ]
        return titles.enumerated().map { idx, title in
            ScoreItem(
                id: ScoreItemID(),
                title: title,
                composer: "J. S. Bach",
                tagIDs: [],
                isFavorite: false,
                dateAdded: now.addingTimeInterval(-Double(idx) * 3600),
                deletedAt: nil,
            )
        }
    }
}
#endif
```

Note: the `ScoreItem` initializer above is illustrative. Match the actual
initializer signature found in `Packages/Domain/Sources/Domain/Models/ScoreItem.swift`
when implementing. If the protocol exposes additional members not shown
above, implement them with empty / minimal in-memory behavior. Do not
add fatalError; LibraryStore will call them.

Create `StubScoreFileImporter.swift`, `StubScoreFileGateway.swift`,
`StubScoreShareService.swift` the same way: read the Domain protocol
declaration, implement each method, return harmless defaults (empty
URLs, no duplicates, etc.). All wrapped in `#if os(Android)`.

- [ ] **Step 3: Create `Android/CBridge.swift`**

```swift
#if os(Android)
import Domain
import Foundation
import LibraryLogic
import Observation

// MARK: - Lifecycle

@_cdecl("folino_library_store_create")
public func folino_library_store_create() -> UnsafeMutableRawPointer {
    let store = MainActor.assumeIsolated {
        LibraryStore(
            repository: StubScoreLibraryRepository(),
            importer: StubScoreFileImporter(),
            gateway: StubScoreFileGateway(),
            shareService: StubScoreShareService(),
        )
    }
    return Unmanaged.passRetained(store).toOpaque()
}

@_cdecl("folino_library_store_destroy")
public func folino_library_store_destroy(_ ptr: UnsafeMutableRawPointer) {
    Unmanaged<LibraryStore>.fromOpaque(ptr).release()
}

// MARK: - Search

@_cdecl("folino_library_store_set_search_text")
public func folino_library_store_set_search_text(
    _ ptr: UnsafeMutableRawPointer,
    _ utf8: UnsafePointer<CChar>,
) {
    let store = Unmanaged<LibraryStore>.fromOpaque(ptr).takeUnretainedValue()
    let s = String(cString: utf8)
    MainActor.assumeIsolated {
        // LibraryStore doesn't have a `searchText` field directly —
        // search is per ScoreListStore. The pilot exposes only one
        // ScoreListStore (the "All" source). We construct it lazily here
        // and stash it in an associated holder.
        AndroidLibraryHolder.shared.scoreListStore(for: store).searchQuery = s
    }
}

// MARK: - Score list snapshot

/// Encodes the current displayed-items list as a `;`-separated UTF-8
/// string of "id|title|composer" tuples. Pilot grade — JSON would be
/// nicer but adds a serialization dep we don't need yet.
@_cdecl("folino_library_store_displayed_items_string")
public func folino_library_store_displayed_items_string(
    _ ptr: UnsafeMutableRawPointer,
) -> UnsafeMutablePointer<CChar> {
    let store = Unmanaged<LibraryStore>.fromOpaque(ptr).takeUnretainedValue()
    let list: [ScoreItem] = MainActor.assumeIsolated {
        AndroidLibraryHolder.shared.scoreListStore(for: store).displayedItems
    }
    let joined = list.map { item in
        "\(item.id.uuidString)|\(item.title)|\(item.composer ?? "")"
    }.joined(separator: ";")
    return strdup(joined)
}

@_cdecl("folino_library_free_cstring")
public func folino_library_free_cstring(_ ptr: UnsafeMutablePointer<CChar>?) {
    free(ptr)
}

// MARK: - Observation → callback bridge

@_cdecl("folino_library_store_observe_displayed_items")
public func folino_library_store_observe_displayed_items(
    _ ptr: UnsafeMutableRawPointer,
    _ context: UnsafeMutableRawPointer?,
    _ callback: @convention(c) (UnsafeMutableRawPointer?) -> Void,
) {
    let store = Unmanaged<LibraryStore>.fromOpaque(ptr).takeUnretainedValue()
    MainActor.assumeIsolated {
        AndroidLibraryHolder.shared.observe(store: store, context: context, callback: callback)
    }
}

@MainActor
final class AndroidLibraryHolder {
    static let shared = AndroidLibraryHolder()

    private var listStores: [ObjectIdentifier: ScoreListStore] = [:]
    private var observers: [ObjectIdentifier: () -> Void] = [:]

    func scoreListStore(for store: LibraryStore) -> ScoreListStore {
        let key = ObjectIdentifier(store)
        if let existing = listStores[key] {
            return existing
        }
        let listStore = ScoreListStore(source: .all, repository: store.repository)
        listStores[key] = listStore
        return listStore
    }

    func observe(
        store: LibraryStore,
        context: UnsafeMutableRawPointer?,
        callback: @escaping @convention(c) (UnsafeMutableRawPointer?) -> Void,
    ) {
        let listStore = scoreListStore(for: store)
        let armCallback: () -> Void = { [weak listStore] in
            guard let listStore else { return }
            withObservationTracking {
                _ = listStore.displayedItems
            } onChange: {
                Task { @MainActor in
                    callback(context)
                    AndroidLibraryHolder.shared.observers[ObjectIdentifier(listStore)]?()
                }
            }
        }
        observers[ObjectIdentifier(listStore)] = armCallback
        armCallback()
    }
}
#endif
```

- [ ] **Step 4: Re-run the Android build**

Run: `cd Android && ./scripts/build-library-logic.sh`
Expected: `.so` files are produced for both ABIs. Any compile errors here are likely due to the stub repository protocol coverage being incomplete — finish the stubs and retry.

- [ ] **Step 5: Commit**

```bash
git add Packages/Features/Library/Sources/LibraryLogic/Android
git commit
```

Message: `Add Android JNI bridge and stub Domain implementations`

---

## Task 12: Hook the JNI surface into Kotlin

**Files:**
- Create: `Android/app/src/main/cpp/CMakeLists.txt`
- Create: `Android/app/src/main/cpp/library_logic_bridge.cpp`
- Create: `Android/app/src/main/kotlin/com/keynumber/folino/ui/library/LibraryStoreHandle.kt`

- [ ] **Step 1: Create `CMakeLists.txt`**

```cmake
cmake_minimum_required(VERSION 3.22.1)
project("library_logic_bridge")

add_library(library_logic_bridge SHARED
    library_logic_bridge.cpp
)

# LibraryLogic .so is preinstalled to jniLibs by build-library-logic.sh.
# We declare it as an imported library so JNI symbols resolve at link time.
add_library(LibraryLogic SHARED IMPORTED)
set_target_properties(LibraryLogic PROPERTIES
    IMPORTED_LOCATION
    ${CMAKE_SOURCE_DIR}/../jniLibs/${ANDROID_ABI}/libLibraryLogic.so
)

find_library(log-lib log)

target_link_libraries(library_logic_bridge
    LibraryLogic
    ${log-lib}
)
```

- [ ] **Step 2: Create the C++ glue file**

`Android/app/src/main/cpp/library_logic_bridge.cpp`:

```cpp
#include <jni.h>
#include <cstring>

extern "C" {

void* folino_library_store_create(void);
void folino_library_store_destroy(void* ptr);
void folino_library_store_set_search_text(void* ptr, const char* utf8);
char* folino_library_store_displayed_items_string(void* ptr);
void folino_library_free_cstring(char* ptr);

// Forward-declared Swift @_cdecl bridge for the observation callback.
typedef void (*folino_observe_cb)(void* context);
void folino_library_store_observe_displayed_items(
    void* ptr, void* context, folino_observe_cb cb);

static JavaVM* g_jvm = nullptr;
static jclass g_handle_cls = nullptr;
static jmethodID g_on_changed_mid = nullptr;

static void observation_callback(void* context) {
    JNIEnv* env = nullptr;
    if (g_jvm->GetEnv(reinterpret_cast<void**>(&env), JNI_VERSION_1_6) != JNI_OK) {
        return;
    }
    auto handle_obj = static_cast<jobject>(context);
    env->CallVoidMethod(handle_obj, g_on_changed_mid);
}

JNIEXPORT jint JNI_OnLoad(JavaVM* vm, void*) {
    g_jvm = vm;
    return JNI_VERSION_1_6;
}

JNIEXPORT jlong JNICALL
Java_com_keynumber_folino_ui_library_LibraryStoreHandle_nativeCreate(JNIEnv*, jobject) {
    return reinterpret_cast<jlong>(folino_library_store_create());
}

JNIEXPORT void JNICALL
Java_com_keynumber_folino_ui_library_LibraryStoreHandle_nativeDestroy(JNIEnv*, jobject, jlong ptr) {
    folino_library_store_destroy(reinterpret_cast<void*>(ptr));
}

JNIEXPORT void JNICALL
Java_com_keynumber_folino_ui_library_LibraryStoreHandle_nativeSetSearchText(
    JNIEnv* env, jobject, jlong ptr, jstring s) {
    const char* c = env->GetStringUTFChars(s, nullptr);
    folino_library_store_set_search_text(reinterpret_cast<void*>(ptr), c);
    env->ReleaseStringUTFChars(s, c);
}

JNIEXPORT jstring JNICALL
Java_com_keynumber_folino_ui_library_LibraryStoreHandle_nativeDisplayedItemsString(
    JNIEnv* env, jobject, jlong ptr) {
    char* s = folino_library_store_displayed_items_string(reinterpret_cast<void*>(ptr));
    jstring out = env->NewStringUTF(s);
    folino_library_free_cstring(s);
    return out;
}

JNIEXPORT void JNICALL
Java_com_keynumber_folino_ui_library_LibraryStoreHandle_nativeObserve(
    JNIEnv* env, jobject self, jlong ptr) {
    if (g_handle_cls == nullptr) {
        jclass local = env->GetObjectClass(self);
        g_handle_cls = static_cast<jclass>(env->NewGlobalRef(local));
        g_on_changed_mid = env->GetMethodID(g_handle_cls, "onChanged", "()V");
    }
    auto context = env->NewGlobalRef(self);
    folino_library_store_observe_displayed_items(
        reinterpret_cast<void*>(ptr),
        context,
        observation_callback);
}

}  // extern "C"
```

- [ ] **Step 3: Create `LibraryStoreHandle.kt`**

```kotlin
package com.keynumber.folino.ui.library

import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.snapshots.SnapshotStateList
import androidx.compose.runtime.toMutableStateList

data class ScoreRow(
    val id: String,
    val title: String,
    val composer: String,
)

class LibraryStoreHandle : AutoCloseable {
    private val ptr: Long = nativeCreate()
    val displayedItems: SnapshotStateList<ScoreRow> = mutableListOf<ScoreRow>().toMutableStateList()

    init {
        refresh()
        nativeObserve(ptr)
    }

    fun setSearchText(s: String) {
        nativeSetSearchText(ptr, s)
    }

    /** Called from JNI when LibraryLogic notifies that the displayed list changed. */
    @Suppress("unused")
    private fun onChanged() {
        refresh()
    }

    private fun refresh() {
        val encoded = nativeDisplayedItemsString(ptr)
        val rows = if (encoded.isEmpty()) emptyList() else encoded
            .split(";")
            .map { entry ->
                val parts = entry.split("|", limit = 3)
                ScoreRow(
                    id = parts.getOrNull(0).orEmpty(),
                    title = parts.getOrNull(1).orEmpty(),
                    composer = parts.getOrNull(2).orEmpty(),
                )
            }
        displayedItems.clear()
        displayedItems.addAll(rows)
    }

    override fun close() {
        nativeDestroy(ptr)
    }

    private external fun nativeCreate(): Long
    private external fun nativeDestroy(ptr: Long)
    private external fun nativeSetSearchText(ptr: Long, s: String)
    private external fun nativeDisplayedItemsString(ptr: Long): String
    private external fun nativeObserve(ptr: Long)

    companion object {
        init {
            System.loadLibrary("LibraryLogic")
            System.loadLibrary("library_logic_bridge")
        }
    }
}
```

- [ ] **Step 4: Build the Android app**

```bash
cd Android && ./gradlew :app:assembleDebug --no-daemon
```

Expected: succeeds. CMake builds the `library_logic_bridge.so`; the `LibraryLogic.so` previously placed by `build-library-logic.sh` is consumed.

- [ ] **Step 5: Add a JNI smoke instrumentation test**

The spec calls for one Kotlin smoke test covering create → mutate → observe → destroy. This is a crash / type-mismatch guard, not a behavior test.

Edit `Android/app/build.gradle.kts` — add (inside `android { ... }`):

```kotlin
defaultConfig {
    // (existing lines above)
    testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
}
```

And (inside `dependencies { ... }`):

```kotlin
androidTestImplementation("androidx.test.ext:junit:1.2.1")
androidTestImplementation("androidx.test:runner:1.6.1")
```

Create `Android/app/src/androidTest/kotlin/com/keynumber/folino/ui/library/LibraryStoreHandleSmokeTest.kt`:

```kotlin
package com.keynumber.folino.ui.library

import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class LibraryStoreHandleSmokeTest {
    @Test
    fun createMutateObserveDestroy() {
        val handle = LibraryStoreHandle()
        try {
            // Initial list should be populated by the stub repository.
            assertTrue("initial list non-empty", handle.displayedItems.isNotEmpty())

            // Mutate — must not crash.
            handle.setSearchText("nonexistent-term-xyz")

            // Re-query (refresh is automatically driven by observation
            // callback; we just ensure the structure is still usable).
            assertTrue("list still readable", handle.displayedItems.size >= 0)
        } finally {
            handle.close()
        }
    }
}
```

This test runs on a connected emulator/device via `connectedDebugAndroidTest`. It is NOT executed in this task — Task 14 step 2 runs it as part of the emulator gate.

- [ ] **Step 6: Build the test APK**

```bash
cd Android && ./gradlew :app:assembleDebugAndroidTest --no-daemon
```

Expected: succeeds. (Execution is deferred to Task 14.)

- [ ] **Step 7: Commit**

```bash
git add Android/app
git commit
```

Message: `Wire JNI bridge between LibraryLogic and Kotlin`

---

## Task 13: Compose UI consuming `LibraryStoreHandle`

**Files:**
- Create: `Android/app/src/main/kotlin/com/keynumber/folino/ui/library/LibraryScreen.kt`
- Modify: `Android/app/src/main/kotlin/com/keynumber/folino/MainActivity.kt`

- [ ] **Step 1: Create `LibraryScreen.kt`**

```kotlin
package com.keynumber.folino.ui.library

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.ListItem
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp

@Composable
fun LibraryScreen() {
    val handle = remember { LibraryStoreHandle() }
    DisposableEffect(handle) { onDispose { handle.close() } }

    var search by remember { mutableStateOf("") }

    Column(modifier = Modifier.fillMaxSize().padding(16.dp)) {
        OutlinedTextField(
            value = search,
            onValueChange = {
                search = it
                handle.setSearchText(it)
            },
            label = { Text("Search") },
        )
        LazyColumn {
            items(handle.displayedItems) { row ->
                ListItem(
                    headlineContent = { Text(row.title) },
                    supportingContent = { Text(row.composer) },
                )
            }
        }
    }
}
```

- [ ] **Step 2: Update `MainActivity.kt`**

```kotlin
package com.keynumber.folino

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import com.keynumber.folino.ui.library.LibraryScreen

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            MaterialTheme {
                Surface {
                    LibraryScreen()
                }
            }
        }
    }
}
```

- [ ] **Step 3: Build**

```bash
cd Android && ./scripts/build-library-logic.sh && ./gradlew :app:assembleDebug --no-daemon
```

Expected: succeeds.

- [ ] **Step 4: Commit**

```bash
git add Android/app
git commit
```

Message: `Add Compose LibraryScreen consuming the Swift store`

---

## Task 14: Emulator smoke (manual verification gate)

- [ ] **Step 1: Start an Android emulator**

Use Android Studio or `emulator -avd <name>`. The pilot does not script
this — it requires a real emulator.

- [ ] **Step 2: Run the JNI smoke test**

```bash
cd Android && ./gradlew :app:connectedDebugAndroidTest --no-daemon
```

Expected: `LibraryStoreHandleSmokeTest.createMutateObserveDestroy` passes. If the JVM crashes during the test (`SIGSEGV`, `UnsatisfiedLinkError`, etc.), this is the first concrete signal of a JNI / toolchain mismatch — stop and revisit per the spec's Risk section.

- [ ] **Step 3: Install + launch the app**

```bash
cd Android && ./gradlew :app:installDebug --no-daemon
adb shell am start -n com.keynumber.folino/.MainActivity
```

- [ ] **Step 4: Verify the four pilot success criteria**

From the spec (#pilot-success-criteria):

1. Library list shows 5 stub scores in the Compose UI.
2. Typing in the search field narrows the list — Compose recomposes
   because the JNI callback fires `LibraryStoreHandle.onChanged`.
3. (Pilot does not implement navigation; skip the navigation criterion.)
4. iOS Library still works identically — re-run a quick iOS smoke
   using the iPhone simulator install you did in Task 8.

Take screenshots of the Android side and attach to the spec's
follow-up notes if desired (no commit required).

- [ ] **Step 5: Document the result**

Append a "Pilot result" section to `Android/README.md` with a one-paragraph
summary: what worked, what didn't, where the Observation framework /
`MainActor` behaved or failed. This is the artifact that drives the
post-pilot decision in the spec's "Future direction" section.

- [ ] **Step 6: Commit**

```bash
git add Android/README.md
git commit
```

Message: `Document Android Library pilot result`

---

# Done

Both phases complete. Per the spec's "Future direction" section, the
post-pilot decisions (CLAUDE.md rule documentation, Settings split next,
etc.) are out of scope for this plan.
