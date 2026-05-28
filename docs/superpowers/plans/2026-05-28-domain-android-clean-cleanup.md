# Domain / Feature ViewModel Android-clean cleanup — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the last three iOS-specific dependencies from `Domain/AppVersion` and from
`LibraryViewModel` / `ReaderViewModel` / `ScoreItemSort` so their file bodies are Foundation-only,
mirroring the Android Settings spike's Fix 1–4.

**Architecture:** Pure refactor in three independent commits. Move `Bundle.main` / `String(localized:)` /
`LocalizedStringResource` calls out of Logic-ish files into App or View-layer siblings. ViewModels
expose typed errors (`Error?` for Library, `case failed(error:)` for Reader); the SwiftUI sibling
resolves the localized message at render time. The `.xcstrings` keys do not change.

**Tech Stack:** Swift 6.3, iOS 26+, SwiftPM modules (Domain / Features / App), Swift Testing,
`xcodegen`, `xcodebuild` against `iPhone 17` simulator (per project memory `package-test-command`).

**Spec:** `docs/superpowers/specs/2026-05-28-domain-android-clean-cleanup-design.md`

---

## File Structure

### Created

- `App/AppVersion+Bundle.swift` — App-side extension providing `AppVersion.current`.
- `Packages/Features/Library/Sources/Library/Screens/LibraryRootScreen+ErrorDescription.swift` —
  top-level `func describeLibraryError(_:Error) -> String` (the switch moved from
  `LibraryViewModel.describe`).
- `Packages/Features/Reader/Sources/Reader/Screens/ReaderRootScreen+ErrorDescription.swift` —
  top-level `func describeReaderError(_:Error) -> String` (the switch moved from
  `ReaderViewModel.describe`).
- `Packages/Features/Library/Sources/Library/Views/ScoreItemSort+LabelKey.swift` — `extension
  ScoreItemSort { var labelKey: LocalizedStringResource }`.

### Modified

- `Packages/Domain/Sources/Domain/Models/AppVersion.swift` — delete `static let current`.
- `Packages/Features/Library/Sources/Library/ScoreItemSort.swift` — delete `var labelKey`.
- `Packages/Features/Library/Sources/Library/LibraryViewModel.swift` — rename
  `errorAlertMessage: String?` → `currentError: Error?`; delete `private func describe(_:)`;
  rewrite 18 assignment sites.
- `Packages/Features/Library/Sources/Library/Screens/{AddToPlaylist,BulkAddToPlaylist,BulkEditTags,PlaylistDetail,TagDetail,LibraryRoot}Screen.swift` —
  six files that assign `library.errorAlertMessage = …`; rewrite to `library.currentError = error`.
  `LibraryRootScreen.swift` additionally rewires the `.alert(presenting:)` to the new state shape.
- `Packages/Features/Library/Tests/LibraryTests/{LibraryViewModelTests,LibraryViewModelShareTests,LibraryViewModelBulkTests}.swift` —
  assertions on `errorAlertMessage` shape change.
- `Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift` — rename `LoadState` case
  `.failed(message: String)` → `.failed(error: Error)`; delete `private func describe(_:)`;
  rewrite assignment at line 204.
- `Packages/Features/Reader/Sources/Reader/Screens/ReaderRootScreen.swift:166` — pattern-match
  `.failed(error:)` and render via `describeReaderError(_:)`.

### Untouched (explicit)

- `Packages/Domain/Sources/Domain/Resources/` — already removed by `bf40189`. Nothing to do.
- All `.xcstrings` files — keys unchanged.
- `Packages/Features/Reader/Tests/ReaderTests/ReaderViewModelTests.swift` lines 54, 74 — they use
  `if case .failed = vm.loadState` without payload, so the case rename does not affect them.
- `Infrastructure/Audio/LivePlaybackController.swift` — out of scope (Infrastructure iOS adapter).

---

## Verification Commands

Used multiple times below. Always against the **iPhone 17** simulator (memory
`package-test-command`; iPhone 16 not installed).

**App build:**

```sh
xcodebuild -project Folino.xcodeproj -scheme Folino \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -skipPackagePluginValidation build
```

**App + UI tests:**

```sh
xcodebuild test -project Folino.xcodeproj -scheme Folino \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -skipPackagePluginValidation
```

**Package-level tests (substitute `<Pkg>-Package`):**

```sh
xcodebuild test -scheme Domain-Package \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -skipPackagePluginValidation

xcodebuild test -scheme Library-Package \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -skipPackagePluginValidation

xcodebuild test -scheme Reader-Package \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -skipPackagePluginValidation
```

---

## Task 0: Create worktree and prep the build

**Files:**
- Create: worktree at `.claude/worktrees/worktree-domain-android-clean-cleanup` (or whatever the
  using-git-worktrees skill picks)
- Symlink: `Config/Local.xcconfig` from main checkout (gitignored, needed by xcodegen)
- Generate: `Folino.xcodeproj` via xcodegen

- [ ] **Step 1: Create worktree off local `main` HEAD**

Use the superpowers:using-git-worktrees skill. Base = local `main` HEAD (per memory
`worktree-base-local-main`). Branch name `worktree-domain-android-clean-cleanup`.

- [ ] **Step 2: Symlink Local.xcconfig**

Per memory `worktree-local-xcconfig`. From the new worktree root:

```sh
ln -sf <MAIN_REPO_ABS_PATH>/Config/Local.xcconfig Config/Local.xcconfig
```

Where `<MAIN_REPO_ABS_PATH>` is the absolute path of the original checkout. The file is gitignored;
without it xcodegen prompts for the Apple Developer Team ID.

- [ ] **Step 3: Generate Xcode project**

```sh
xcodegen generate
```

Expected: `Created project at /…/Folino.xcodeproj`.

- [ ] **Step 4: Baseline build to confirm worktree is healthy**

Run the App build command. Expected: `** BUILD SUCCEEDED **`.

If the build fails here, do **not** continue — the worktree is not in a known-good state and any
later failures would be ambiguous. Fix or recreate first.

- [ ] **Step 5: Capture baseline grep counts**

The final verification (Task 5) expects these grep counts to drop to zero. Capture the
"before" values so the agent can see the work landing.

```sh
rg -c 'Bundle\.main|CGFloat|CoreGraphics|String\(localized:|LocalizedStringResource|#if canImport' \
   Packages/Domain/Sources/ || echo 'Domain: 0'

rg -c 'String\(localized:|bundle: \.module|LocalizedStringResource' \
   Packages/Features/Library/Sources/Library/LibraryViewModel.swift \
   Packages/Features/Library/Sources/Library/ScoreItemSort.swift \
   Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift
```

Expected (before refactor): Domain hits in `AppVersion.swift` (`Bundle.main`); Library/Reader files
each show several `String(localized:` / `bundle: .module` / `LocalizedStringResource` hits.

Record these counts in a scratch note. No commit yet — Task 0 is environment prep, not a code
change.

---

## Task 1: Fix 5 — Move `AppVersion.current` from Domain to App

**Files:**
- Modify: `Packages/Domain/Sources/Domain/Models/AppVersion.swift:37-43`
- Create: `App/AppVersion+Bundle.swift`

- [ ] **Step 1: Confirm existing tests pass before changing anything**

Run the App test command. Expected: green (especially
`Tests/FolinoTests/VersionHistoryPresenterTests.swift`, which uses `AppVersion.current` from many
points). This is the safety net — the refactor must keep it green at the end.

- [ ] **Step 2: Delete `static let current` from Domain**

Edit `Packages/Domain/Sources/Domain/Models/AppVersion.swift`. Remove these lines:

```swift
    public static let current: AppVersion = {
        let raw = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        guard let v = AppVersion(raw) else {
            fatalError("CFBundleShortVersionString is missing or malformed: \(raw)")
        }
        return v
    }()
```

Leave the surrounding `static let zero` and `static func <` as-is.

- [ ] **Step 3: Verify the deletion broke App (build error) — proves callers needed `.current`**

Run the App build command. Expected: **BUILD FAILED** with errors at `App/VersionHistoryPresenter.swift`
lines 43 and 49 ("type 'AppVersion' has no member 'current'"). This proves the symbol was actually
used by App, validating that re-introducing it via extension is the right move.

- [ ] **Step 4: Create the App-side extension**

Create `App/AppVersion+Bundle.swift` with this exact content:

```swift
import Domain
import Foundation

extension AppVersion {
    /// Reads the host bundle's `CFBundleShortVersionString` at first access. App-only because Domain
    /// must not depend on `Bundle.main`. Crashes deliberately if the value is missing or malformed —
    /// a misconfigured Info.plist is a build bug, not a runtime condition to recover from.
    public static let current: AppVersion = {
        let raw = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        guard let v = AppVersion(raw) else {
            fatalError("CFBundleShortVersionString is missing or malformed: \(raw)")
        }
        return v
    }()
}
```

Note: `public` here is App-target-internal in practice (App doesn't expose a module), so the
modifier is harmless. Matches the deleted Domain declaration's visibility.

- [ ] **Step 5: Regenerate Xcode project to pick up the new file**

```sh
xcodegen generate
```

`project.yml` globs `App/**/*.swift`, so the new file lands in the App target automatically.

- [ ] **Step 6: Build and run all tests**

Run the App test command. Expected: green. `VersionHistoryPresenterTests` should pass without any
test-side changes — `AppVersion.current` resolves through the extension.

- [ ] **Step 7: Spot-check Domain is Bundle.main-free**

```sh
rg 'Bundle\.main' Packages/Domain/Sources/
```

Expected: no output.

- [ ] **Step 8: Commit**

```sh
git add Packages/Domain/Sources/Domain/Models/AppVersion.swift App/AppVersion+Bundle.swift project.yml
git -c commit.gpgsign=false commit -m "Move AppVersion.current to App; drop Bundle.main from Domain

Fix 5 from the Android-clean cleanup. AppVersion stays a pure value type;
the Info.plist read lives in App where it belongs.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

Note: only commit `project.yml` if `xcodegen` modified it (typically not, since the file is matched
by an existing glob). The pre-commit hook may run SwiftFormat/SwiftLint and amend; re-stage and
retry if it does.

---

## Task 2: Fix 7 — Move `ScoreItemSort.labelKey` to a View extension

**Files:**
- Modify: `Packages/Features/Library/Sources/Library/ScoreItemSort.swift:15-26`
- Create: `Packages/Features/Library/Sources/Library/Views/ScoreItemSort+LabelKey.swift`

- [ ] **Step 1: Confirm tests pass before changing anything**

Run the Library package test command. Expected: green.

- [ ] **Step 2: Delete `var labelKey` from `ScoreItemSort.swift`**

Edit `Packages/Features/Library/Sources/Library/ScoreItemSort.swift`. Remove lines 15–26 (the
`var labelKey: LocalizedStringResource { switch self { … } }` block). Leave the `import Foundation`,
`enum ScoreItemSort` declaration, `var id`, `func apply(to:)`, and the four private static
comparators intact.

- [ ] **Step 3: Build to confirm the deletion broke the View**

Run the App build command. Expected: **BUILD FAILED** at
`Packages/Features/Library/Sources/Library/Views/ScoreListView.swift:204`
("value of type 'ScoreItemSort' has no member 'labelKey'").

- [ ] **Step 4: Create the View-layer extension**

Create `Packages/Features/Library/Sources/Library/Views/ScoreItemSort+LabelKey.swift` with this
exact content (copy of the deleted block, plus its surrounding imports):

```swift
import Foundation

extension ScoreItemSort {
    var labelKey: LocalizedStringResource {
        switch self {
        case .dateAddedDesc:
            LocalizedStringResource("library.sort.byDateAdded", bundle: .atURL(Bundle.module.bundleURL))
        case .titleAsc:
            LocalizedStringResource("library.sort.byTitle", bundle: .atURL(Bundle.module.bundleURL))
        case .composerAsc:
            LocalizedStringResource("library.sort.byComposer", bundle: .atURL(Bundle.module.bundleURL))
        case .lastOpenedDesc:
            LocalizedStringResource("library.sort.byLastOpened", bundle: .atURL(Bundle.module.bundleURL))
        }
    }
}
```

- [ ] **Step 5: Build and run all tests**

Run the App test command. Expected: green. No tests exercise `labelKey`, so coverage is unchanged.

- [ ] **Step 6: Spot-check `ScoreItemSort.swift` body is SwiftUI-clean**

```sh
rg 'LocalizedStringResource|Bundle\.module' \
   Packages/Features/Library/Sources/Library/ScoreItemSort.swift
```

Expected: no output.

- [ ] **Step 7: Commit**

```sh
git add Packages/Features/Library/Sources/Library/ScoreItemSort.swift \
        Packages/Features/Library/Sources/Library/Views/ScoreItemSort+LabelKey.swift
git -c commit.gpgsign=false commit -m "Move ScoreItemSort.labelKey to a Views/ extension

Fix 7 from the Android-clean cleanup. The enum body is Foundation-only;
the SwiftUI-typed labelKey lives next to the View that consumes it.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Fix 6 — Move error description out of Library / Reader ViewModels

This task lands two parallel changes (Library and Reader) in a single commit, matching spec §6's
commit-order list (Fix 6 = one commit). The intermediate states are each individually green.

**Files (Library):**
- Modify: `Packages/Features/Library/Sources/Library/LibraryViewModel.swift`
- Modify: `Packages/Features/Library/Sources/Library/Screens/LibraryRootScreen.swift`
- Modify: `Packages/Features/Library/Sources/Library/Screens/AddToPlaylistScreen.swift`
- Modify: `Packages/Features/Library/Sources/Library/Screens/BulkAddToPlaylistScreen.swift`
- Modify: `Packages/Features/Library/Sources/Library/Screens/BulkEditTagsScreen.swift`
- Modify: `Packages/Features/Library/Sources/Library/Screens/PlaylistDetailScreen.swift`
- Modify: `Packages/Features/Library/Sources/Library/Screens/TagDetailScreen.swift`
- Create: `Packages/Features/Library/Sources/Library/Screens/LibraryRootScreen+ErrorDescription.swift`
- Modify: `Packages/Features/Library/Tests/LibraryTests/LibraryViewModelTests.swift`
- Modify: `Packages/Features/Library/Tests/LibraryTests/LibraryViewModelShareTests.swift`
- Modify: `Packages/Features/Library/Tests/LibraryTests/LibraryViewModelBulkTests.swift`

**Files (Reader):**
- Modify: `Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift`
- Modify: `Packages/Features/Reader/Sources/Reader/Screens/ReaderRootScreen.swift`
- Create: `Packages/Features/Reader/Sources/Reader/Screens/ReaderRootScreen+ErrorDescription.swift`

### Part A — Library

- [ ] **Step A1: Update tests first (TDD — fail, then make pass)**

Open each Library test file and convert assertions on `errorAlertMessage` to assertions on
`currentError`. Examples — apply the same transformation everywhere the literal pattern occurs:

```diff
-#expect(vm.errorAlertMessage == nil)
+#expect(vm.currentError == nil)

-#expect(vm.errorAlertMessage != nil)
+#expect(vm.currentError != nil)

-#expect(vm.errorAlertMessage == "This file looks corrupted or isn't a valid score.")
+#expect(vm.currentError as? DomainError == .scoreParseFailed)
```

For the third pattern (string equality), look up the corresponding `case` in
`LibraryViewModel.describe` and use the matching `DomainError` value. The mapping is:

| Old literal (or `defaultValue`) | DomainError case |
| --- | --- |
| "This file's format isn't supported." | `.unsupportedFormat` |
| "This file looks corrupted or isn't a valid score." | `.scoreParseFailed` |
| "Couldn't save the imported score." | `.persistenceFailed` (note: associated value ignored — use `if case .persistenceFailed = …`) |
| "Score file not found: \(name)" | `.scoreFileNotFound` (same — pattern-match) |
| "Could not write score file: \(reason)" | `.scoreWriteFailed` |
| "Sync failed: \(reason)" | `.syncFailed` |
| "Audio engine error: \(reason)" | `.audioEngineFailed` |

For cases with associated values, use `if case let .xxx(reason) = vm.currentError as? DomainError`
instead of `==`. If a test currently checks only "non-nil error happened", `vm.currentError != nil`
is enough.

Look at each test file (`LibraryViewModelTests.swift`, `LibraryViewModelShareTests.swift`,
`LibraryViewModelBulkTests.swift`) and apply systematically.

- [ ] **Step A2: Run the Library tests — expect compile errors**

Run the Library package test command. Expected: build error
("type 'LibraryViewModel' has no member 'currentError'"). This proves the test rewrites are seeing
the old VM shape.

- [ ] **Step A3: Rename `errorAlertMessage` → `currentError` in `LibraryViewModel.swift`**

In `Packages/Features/Library/Sources/Library/LibraryViewModel.swift`:

1. Line ~30: change
   ```swift
   var errorAlertMessage: String?
   ```
   to
   ```swift
   var currentError: Error?
   ```

2. Line ~44 (the `clearError` or similar reset): change
   ```swift
   errorAlertMessage = nil
   ```
   to
   ```swift
   currentError = nil
   ```

3. **Every** `errorAlertMessage = describe(error)` (18 sites total in the VM): change to
   ```swift
   currentError = error
   ```

4. Delete the whole `private func describe(_ error: Error) -> String { … }` block (lines 307–343).

After this step, `LibraryViewModel.swift` should have **zero** occurrences of
`errorAlertMessage`, `describe`, `String(localized:`, or `bundle: .module`. Verify with:

```sh
rg 'errorAlertMessage|describe\(|String\(localized:|bundle: \.module' \
   Packages/Features/Library/Sources/Library/LibraryViewModel.swift
```

Expected: no output.

- [ ] **Step A4: Update the 6 Library Screens that assign the old state**

For each Screen file, swap the assignment pattern.

`AddToPlaylistScreen.swift`, `BulkAddToPlaylistScreen.swift`, `BulkEditTagsScreen.swift`,
`PlaylistDetailScreen.swift`, `TagDetailScreen.swift` — find this exact pattern:

```swift
library.errorAlertMessage = (error as? LocalizedError)?.errorDescription
```

Replace with:

```swift
library.currentError = error
```

`LibraryRootScreen.swift` has these distinct rewrites:

```diff
-viewModel.errorAlertMessage = error.localizedDescription
+viewModel.currentError = error
```

```diff
-Button { viewModel.errorAlertMessage = nil } label: {
+Button { viewModel.currentError = nil } label: {
```

```diff
-    get: { viewModel.errorAlertMessage != nil },
-    set: { isPresented in if !isPresented { viewModel.errorAlertMessage = nil } },
+    get: { viewModel.currentError != nil },
+    set: { isPresented in if !isPresented { viewModel.currentError = nil } },
```

And rewire the alert block at lines 87–97. The current block:

```swift
.alert(
    Text("library.title", bundle: .module),
    isPresented: errorAlertBinding,
    presenting: viewModel.errorAlertMessage,
) { _ in
    Button { viewModel.errorAlertMessage = nil } label: {
        L10n.Common.ok
    }
} message: { msg in
    Text(msg)
}
```

becomes:

```swift
.alert(
    Text("library.title", bundle: .module),
    isPresented: errorAlertBinding,
    presenting: viewModel.currentError,
) { _ in
    Button { viewModel.currentError = nil } label: {
        L10n.Common.ok
    }
} message: { error in
    Text(describeLibraryError(error))
}
```

Only the `presenting:` payload, the Button action, and the trailing `message:` closure change.
The title literal `Text("library.title", bundle: .module)` and `L10n.Common.ok` stay verbatim.

- [ ] **Step A5: Create `LibraryRootScreen+ErrorDescription.swift`**

Path: `Packages/Features/Library/Sources/Library/Screens/LibraryRootScreen+ErrorDescription.swift`.
Content:

```swift
import Domain
import Foundation

/// Verbatim move of the switch that used to live in `LibraryViewModel.describe(_:)`. Kept as a
/// top-level helper so it stays accessible from any Screen that surfaces a `LibraryViewModel`
/// error. The localization keys and `defaultValue` fallbacks match the originals byte-for-byte.
func describeLibraryError(_ error: Error) -> String {
    if let domain = error as? DomainError {
        switch domain {
        case .unsupportedFormat:
            return String(localized: "library.import.error.unsupported", bundle: .module)
        case .scoreParseFailed:
            return String(localized: "library.import.error.invalidFile", bundle: .module)
        case .persistenceFailed:
            return String(localized: "library.import.error.saveFailed", bundle: .module)
        case let .scoreFileNotFound(name):
            return String(
                localized: "library.error.fallback.scoreFileNotFound",
                defaultValue: "Score file not found: \(name)",
                bundle: .module,
            )
        case let .scoreWriteFailed(reason):
            return String(
                localized: "library.error.fallback.scoreWriteFailed",
                defaultValue: "Could not write score file: \(reason)",
                bundle: .module,
            )
        case let .syncFailed(reason):
            return String(
                localized: "library.error.fallback.syncFailed",
                defaultValue: "Sync failed: \(reason)",
                bundle: .module,
            )
        case let .audioEngineFailed(reason):
            return String(
                localized: "library.error.fallback.audioEngineFailed",
                defaultValue: "Audio engine error: \(reason)",
                bundle: .module,
            )
        }
    }
    return (error as NSError).localizedDescription
}
```

Cross-check the switch arms against the original `LibraryViewModel.describe` (the version captured
before deletion in Step A3) and confirm every case maps verbatim.

- [ ] **Step A6: Build and run all Library tests**

Run the Library package test command. Expected: green. The test rewrites from Step A1 should now
match the new VM shape.

If a test still fails, it's almost certainly an assertion that needed a different
`DomainError` case in Step A1 — re-check the mapping table.

### Part B — Reader

- [ ] **Step B1: Rewrite Reader tests to use the new `case .failed(error:)` payload (if any check payload)**

Open the Reader test files:

- `Packages/Features/Reader/Tests/ReaderTests/ReaderViewModelTests.swift` — lines 54, 74 use
  `if case .failed = vm.loadState { … }` **without** binding the payload. These do **not** need
  changes (pattern is payload-less).
- `Packages/Features/Reader/Tests/ReaderTests/ReaderViewModelSoundfontSwapTests.swift` — check for
  `.failed(message:` patterns; if any exist, rewrite them. As of the audit, none do.
- `Packages/Features/Reader/Tests/ReaderTests/Fakes/FakeMuseScoreGeneralProvider.swift` — its
  `.failed` reference is to a different enum (a download state, not LoadState). Leave untouched.

If no test changes are needed, skip ahead — the existing tests are coverage enough for the case
rename.

- [ ] **Step B2: Update `ReaderViewModel.swift` — rename case + drop describe**

In `Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift`:

1. Line 13: change
   ```swift
   case failed(message: String)
   ```
   to
   ```swift
   case failed(error: Error)
   ```

2. Lines 202–204 (the catch block):
   ```diff
   -        } catch {
   -            let message = describe(error)
   -            loadState = .failed(message: message)
   -        }
   +        } catch {
   +            loadState = .failed(error: error)
   +        }
   ```

3. Delete the whole `private func describe(_ error: Error) -> String { … }` block (starts at
   line 232).

After this step, `ReaderViewModel.swift` should have zero occurrences of `describe(`,
`String(localized:`, or `bundle: .module`. Verify:

```sh
rg 'describe\(|String\(localized:|bundle: \.module' \
   Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift
```

Expected: no output.

- [ ] **Step B3: Update `ReaderRootScreen.swift` pattern match**

`Packages/Features/Reader/Sources/Reader/Screens/ReaderRootScreen.swift` lines 166–174. The current
block:

```swift
case let .failed(message):
    ContentUnavailableView {
        Label {
            Text("reader.error.cannotOpen.title", bundle: .module)
        } icon: {
            Image(systemName: "exclamationmark.triangle")
        }
    } description: {
        Text(message)
    } actions: {
```

becomes:

```swift
case let .failed(error):
    ContentUnavailableView {
        Label {
            Text("reader.error.cannotOpen.title", bundle: .module)
        } icon: {
            Image(systemName: "exclamationmark.triangle")
        }
    } description: {
        Text(describeReaderError(error))
    } actions: {
```

Only the binding name (`message` → `error`) and the description body change. The `actions:` block
(lines 175+) is untouched.

- [ ] **Step B4: Create `ReaderRootScreen+ErrorDescription.swift`**

Path: `Packages/Features/Reader/Sources/Reader/Screens/ReaderRootScreen+ErrorDescription.swift`.
Content:

```swift
import Domain
import Foundation

/// Verbatim move of the switch that used to live in `ReaderViewModel.describe(_:)`. Kept as a
/// top-level helper so it stays accessible from any Screen that surfaces a Reader load error.
/// The localization keys and `defaultValue` fallbacks match the originals byte-for-byte.
func describeReaderError(_ error: Error) -> String {
    if let domain = error as? DomainError {
        switch domain {
        case .scoreFileNotFound:
            return String(localized: "reader.error.fileMissing", bundle: .module)
        case .scoreParseFailed:
            return String(localized: "reader.error.corrupted", bundle: .module)
        case .unsupportedFormat:
            return String(localized: "reader.error.cannotOpen.unsupportedType", bundle: .module)
        case let .scoreWriteFailed(reason):
            return String(
                localized: "reader.error.fallback.scoreWriteFailed",
                defaultValue: "Could not write score file: \(reason)",
                bundle: .module,
            )
        case let .persistenceFailed(reason):
            return String(
                localized: "reader.error.fallback.persistenceFailed",
                defaultValue: "Library save failed: \(reason)",
                bundle: .module,
            )
        case let .syncFailed(reason):
            return String(
                localized: "reader.error.fallback.syncFailed",
                defaultValue: "Sync failed: \(reason)",
                bundle: .module,
            )
        case let .audioEngineFailed(reason):
            return String(
                localized: "reader.error.fallback.audioEngineFailed",
                defaultValue: "Audio engine error: \(reason)",
                bundle: .module,
            )
        }
    }
    return (error as NSError).localizedDescription
}
```

Cross-check the switch arms against the original `ReaderViewModel.describe` before deletion. The
case order and the localization keys must match. (Note: Reader's switch ordered cases differently
from Library's; the keys are Reader-specific, e.g. `reader.error.fileMissing` not
`library.import.error.unsupported`.)

Important: the original Reader `describe` switch may have had more or fewer cases than the seven
shown above — read the original carefully and copy verbatim. If a case present in `DomainError` is
missing from the original Reader switch, leave it missing (the `(error as NSError).localizedDescription`
fallback covers it).

- [ ] **Step B5: Build and run all Reader tests**

Run the Reader package test command. Expected: green.

### Part C — Wrap up

- [ ] **Step C1: Build the app and run the full test suite**

Run the App build command, then the App test command. Expected: both green.

- [ ] **Step C2: Spot-check the post-state**

```sh
rg 'String\(localized:|bundle: \.module' \
   Packages/Features/Library/Sources/Library/LibraryViewModel.swift \
   Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift
```

Expected: no output.

- [ ] **Step C3: Commit (single commit for Library + Reader)**

```sh
git add Packages/Features/Library/Sources/Library/LibraryViewModel.swift \
        Packages/Features/Library/Sources/Library/Screens/*.swift \
        Packages/Features/Library/Tests/LibraryTests/*.swift \
        Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift \
        Packages/Features/Reader/Sources/Reader/Screens/ReaderRootScreen.swift \
        Packages/Features/Reader/Sources/Reader/Screens/ReaderRootScreen+ErrorDescription.swift
git -c commit.gpgsign=false commit -m "Move error description out of Library/Reader ViewModels to View layer

Fix 6 from the Android-clean cleanup. LibraryViewModel exposes currentError: Error?
and ReaderViewModel's LoadState carries the typed error directly. The describe()
switches moved verbatim into Screen-level helpers that own the String(localized:)
calls. xcstrings keys unchanged.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: Final mechanical verification

**Files:** none — read-only checks.

- [ ] **Step 1: Final Domain-clean grep — must be empty**

```sh
rg 'Bundle\.main|CGFloat|CoreGraphics|String\(localized:|LocalizedStringResource|#if canImport' \
   Packages/Domain/Sources/
```

Expected: no output. Codifies findings doc §6.3 ("Domain stays a pure value-type / protocol layer
with no platform-specific imports").

- [ ] **Step 2: Final Feature ViewModel + ScoreItemSort grep — must be empty**

```sh
rg 'String\(localized:|bundle: \.module|LocalizedStringResource' \
   Packages/Features/Library/Sources/Library/LibraryViewModel.swift \
   Packages/Features/Library/Sources/Library/ScoreItemSort.swift \
   Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift
```

Expected: no output.

- [ ] **Step 3: Confirm Screens still localize (sanity — these greps should still find calls)**

```sh
rg -l 'String\(localized:' Packages/Features/Library/Sources/Library/Screens/ \
                            Packages/Features/Reader/Sources/Reader/Screens/
```

Expected: at minimum `LibraryRootScreen+ErrorDescription.swift` and
`ReaderRootScreen+ErrorDescription.swift` appear (because they now host the localization). This
is a positive control — proves the localization didn't accidentally evaporate, it moved.

- [ ] **Step 4: Final whole-suite test**

Run the App test command (full UI + unit). Expected: green.

- [ ] **Step 5: Diff summary for review**

```sh
git log --oneline main..HEAD
git diff --stat main..HEAD
```

Expected: three commits on this branch (Fix 5, Fix 7, Fix 6), `~15-20 files changed` with a
roughly even insert/delete count (it's a refactor — code is moving, not growing).

- [ ] **Step 6: Push? — STOP and ask the user**

Do **not** push or merge automatically. Per project CLAUDE.md "Autonomous-task ground rules",
`git push` is a stop-and-confirm action. Surface the three-commit branch to the user with a
short summary and let them choose to push, open a PR, or amend further.

---

## Notes on memory-resident gotchas

- **Worktree cleanup** (memory `worktree-cleanup-claude-dir`): if abandoning this work mid-flight,
  remember to also clear any `.claude/worktrees/worktree-domain-android-clean-cleanup` directory.
- **Worktree base** (memory `worktree-base-local-main`): use local `main`, not `origin/main`.
- **Local.xcconfig symlink** (memory `worktree-local-xcconfig`): mandatory after creating the
  worktree.
- **Package test command** (memory `package-test-command`): `xcodebuild test -scheme <Pkg>-Package
  -destination 'platform=iOS Simulator,name=iPhone 17'`. Do **not** use `swift test`.
- **xcstrings refactor pitfall** (memory `xcstrings-refactor`): the localization keys here are
  unchanged on purpose — do not let xcstringstool auto-prune them in a side commit. If any key
  ends up "stale" after build, it's a bug in this plan (a forgotten reference), not a cleanup
  opportunity.
