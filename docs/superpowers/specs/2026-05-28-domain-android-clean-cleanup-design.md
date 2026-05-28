# Domain / Feature ViewModel Android-clean cleanup — Design

Date: 2026-05-28
Branch (planned): `worktree-domain-android-clean-cleanup`
Driven by: `docs/superpowers/specs/2026-05-27-folino-android-settings-findings.md` §1.1, §6.3, §6.4

---

## 1. Summary

The Android Settings spike (commits `0f75ba4`, `bf40189`) replaced two spike-time `#if canImport` guards
in Domain with cleaner architectural fixes: `staffSize: CGFloat → Double` (Fix 1) and
`DomainError: LocalizedError` moved from Domain to App (Fix 2). Findings §6.3 codified the rule
"Domain stays a pure value-type / protocol layer with no platform-specific imports; localization belongs
in the UI tier (App or Feature)."

A targeted audit (2026-05-28) found three remaining spots in the same spirit that the spike did not
touch:

| # | Location | Pattern | Layer |
| --- | --- | --- | --- |
| 5 | `Domain/AppVersion.swift` | `Bundle.main.infoDictionary` in `static let current` | Domain |
| 6 | `Library/LibraryViewModel.describe(_:)`, `Reader/ReaderViewModel.describe(_:)` | `String(localized: …, bundle: .module)` in a ViewModel method | Feature ViewModel |
| 7 | `Library/ScoreItemSort.labelKey` | `LocalizedStringResource` on a Foundation-only enum | Feature ViewModel-adjacent |

This spec covers a pure refactor that removes these three patterns without changing user-visible
behavior, without splitting any Feature into `*Logic` / View products, and without resolving the
broader localization strategy question (findings §6.4 — deferred).

## 2. Goals / non-goals

### Goals

- Remove every `Bundle.main` / `String(localized:)` / `LocalizedStringResource` call from
  `Packages/Domain/Sources/Domain/` and from `LibraryViewModel.swift` / `ReaderViewModel.swift`
  themselves (the file bodies; not their sibling Screens/Views).
- Codify the Domain-clean rule from findings §6.3 one tier wider: a Feature's ViewModel file is
  Foundation-only and never calls `String(localized:)`; the SwiftUI sibling does the localization.
- Keep the `.xcstrings` keys and all user-visible strings byte-identical. No translation work, no key
  renames.

### Non-goals

- Splitting `Library` / `Reader` into `*Logic` SwiftPM products (findings §6.1). Separate PR.
- Deciding how `.xcstrings` content reaches Android (findings §6.4). Separate spec.
- Actually running an Android cross-compile of Library/Reader/Domain. The verification here is
  syntactic ("no forbidden symbols in these files"); cross-compile validation is a separate spike.
- Touching `Infrastructure/Audio/LivePlaybackController.swift:349` — its `Bundle.main.infoDictionary`
  use is an iOS-only adapter, expected and out of scope.
- Touching `Editor` / `ImportExport` Features. They have no logic-layer `describe()` today.

## 3. Fix 5 — `Domain/AppVersion.swift` `Bundle.main` removal

### Current shape

`Packages/Domain/Sources/Domain/Models/AppVersion.swift` defines a Foundation-only value type plus a
`static let current` that reads `Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")`
and `fatalError`s on missing/malformed input.

### Change

- Delete the `static let current = { … Bundle.main … }()` block from Domain.
- Add a new file `App/AppVersion+Bundle.swift` containing:

  ```swift
  import Domain
  import Foundation

  extension AppVersion {
      static let current: AppVersion = {
          let raw = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
          guard let v = AppVersion(raw) else {
              fatalError("CFBundleShortVersionString is missing or malformed: \(raw)")
          }
          return v
      }()
  }
  ```

- Domain `AppVersion` keeps `init(_:_:_:)`, `init?(String)`, `init?(rawValue:)`, `rawValue`,
  `description`, `<`, `.zero` — pure value type, no statics that read process state.

### Callers (unchanged)

- `App/VersionHistoryPresenter.swift` (lines 43, 49) — App target imports Domain + the new extension
  file; `AppVersion.current` resolves through the extension.
- `Tests/FolinoTests/VersionHistoryPresenterTests.swift` — same target visibility as App.

### Notes

- Domain after this change contains zero `Bundle.main`, zero `CGFloat`, zero `CoreGraphics`,
  zero `String(localized:)`, zero `LocalizedStringResource`, zero `#if canImport`. The
  findings §6.3 codified rule becomes mechanically verifiable.

## 4. Fix 6 — Move error description out of Library / Reader ViewModels

### Current shape

Both `LibraryViewModel.swift` and `ReaderViewModel.swift` carry a `private func describe(_ error: Error) -> String`
that switches on `DomainError` and calls `String(localized: "<key>", bundle: .module)` (with
`defaultValue:` for the fallback keys introduced by `bf40189`). The ViewModel stores the localized
string in `errorAlertMessage: String?`, and the View binds an alert to it.

### Change — Library

1. `LibraryViewModel`: rename `var errorAlertMessage: String?` → `var currentError: Error?`.
2. Delete the `private func describe(_ error: Error) -> String` method from `LibraryViewModel.swift`.
3. Replace every `errorAlertMessage = describe(error)` (19 call sites) with `currentError = error`.
4. In the 4 Screens that assigned `library.errorAlertMessage = (error as? LocalizedError)?.errorDescription`
   (`AddToPlaylistScreen`, `BulkAddToPlaylistScreen`, `BulkEditTagsScreen`, `PlaylistDetailScreen`,
   `TagDetailScreen`), change to `library.currentError = error`.
5. Move the deleted `describe(_:)` switch verbatim into a new file
   `Packages/Features/Library/Sources/Library/Screens/LibraryRootScreen+ErrorDescription.swift`
   as a top-level `func describeLibraryError(_:Error) -> String` (or a `LibraryRootScreen` extension —
   implementation detail, pick whichever yields the smallest diff at the call site).
6. Update the alert at `LibraryRootScreen.swift:90`
   (`presenting: viewModel.errorAlertMessage`) to bind on `viewModel.currentError` and render
   the message via the new helper.

### Change — Reader

Reader is shaped differently: there is no `errorAlertMessage` state. The error rides inside the
`LoadState` enum as `case failed(message: String)` (line 13), assigned at line 204 via
`loadState = .failed(message: describe(error))`. So the refactor is:

1. `enum LoadState`: `case failed(message: String)` → `case failed(error: Error)`.
2. Delete the `private func describe(_ error: Error) -> String` from `ReaderViewModel.swift`.
3. Line 203-204 becomes: `loadState = .failed(error: error)` (drop the `describe` round-trip).
4. Move the deleted switch into
   `Packages/Features/Reader/Sources/Reader/Screens/ReaderRootScreen+ErrorDescription.swift` (or
   wherever the View that consumes `case failed` lives — locate it during implementation and
   place the helper next to it). Call sites that previously displayed `message` now call the
   helper on the associated `error`.

### Localization keys

The `.xcstrings` keys (`library.import.error.*`, `library.error.fallback.*`,
`reader.error.*`, `reader.error.fallback.*`) stay in the existing Feature `Resources/Localizable.xcstrings`
files. No additions, no removals.

### Tests

- `Packages/Features/Library/Tests/LibraryTests/LibraryViewModelShareTests.swift:46`
  asserts on a literal string ("This file looks corrupted or isn't a valid score."). Rewrite to
  assert on the typed error: `#expect(vm.currentError as? DomainError == .scoreParseFailed)`.
  Apply the same transformation to every test that checked `errorAlertMessage == "<literal>"`.
- Tests that only checked `errorAlertMessage == nil` or `errorAlertMessage != nil` become
  `currentError == nil` / `!= nil`.
- Reader test suite mirrors the same change.

### Outcome

- `LibraryViewModel.swift` body contains zero `String(localized:)`, zero `bundle: .module`,
  zero `LocalizedStringResource`. Same for `ReaderViewModel.swift`.
- The localization stays on the iOS path (Screens), unchanged for users.
- ViewModels now expose the typed error directly, which is also closer to the bf40189 pattern
  ("UI tier owns localization") and makes future per-platform error rendering trivial.

## 5. Fix 7 — `ScoreItemSort.labelKey` move

### Current shape

`Packages/Features/Library/Sources/Library/ScoreItemSort.swift` is a Foundation-only `enum
ScoreItemSort` with sort comparators plus a `var labelKey: LocalizedStringResource` returning a
`LocalizedStringResource(<key>, bundle: .atURL(Bundle.module.bundleURL))`.

The only use of `labelKey` is `Views/ScoreListView.swift:204` — `Text(option.labelKey)`.

### Change

- Delete `var labelKey` (and the `LocalizedStringResource` symbol) from `ScoreItemSort.swift`.
- Create `Packages/Features/Library/Sources/Library/Views/ScoreItemSort+LabelKey.swift` containing
  exactly the deleted property as an extension:

  ```swift
  import Foundation

  extension ScoreItemSort {
      var labelKey: LocalizedStringResource {
          switch self {
          case .dateAddedDesc:
              LocalizedStringResource("library.sort.byDateAdded", bundle: .atURL(Bundle.module.bundleURL))
          // … 4 cases verbatim …
          }
      }
  }
  ```

- `ScoreListView.swift:204` `Text(option.labelKey)` keeps working unchanged.
- `ScoreItemSort.swift` now contains: `enum ScoreItemSort`, `var id`, `func apply(to:)`, 4 private
  static comparators. No SwiftUI / Apple-only types.

### Tests

- `ScoreItemSortTests` does not exercise `labelKey`, so no test changes.

## 6. Worktree, commits, and verification

### Worktree

- Create with native `EnterWorktree` tool, base `main` HEAD (local), branch
  `worktree-domain-android-clean-cleanup`.
- Immediately after: symlink `Config/Local.xcconfig` from the main checkout into the worktree
  (gitignored file required by `xcodegen` for team id).
- Run `xcodegen generate` once before any build (`.xcodeproj` is also gitignored).

### Commit order (each one builds + tests green on its own)

1. **Fix 5** — `Move AppVersion.current to App; drop Bundle.main from Domain`
2. **Fix 7** — `Move ScoreItemSort.labelKey to a Views/ extension`
3. **Fix 6** — `Move error description out of Library/Reader ViewModels to View layer`

Fix 5 → 7 → 6 puts the biggest diff last; if review wants to split further, 6 is the natural seam.

### Verification commands

Per commit, in order:

- App build (catches xcodegen + main target regressions):
  ```sh
  xcodebuild -project Folino.xcodeproj -scheme Folino \
    -destination 'platform=iOS Simulator,name=iPhone 17' \
    -skipPackagePluginValidation build
  ```
- App + UI tests:
  ```sh
  xcodebuild test -project Folino.xcodeproj -scheme Folino \
    -destination 'platform=iOS Simulator,name=iPhone 17' \
    -skipPackagePluginValidation
  ```
- Domain isolated: `xcodebuild test -scheme Domain-Package -destination 'platform=iOS Simulator,name=iPhone 17' -skipPackagePluginValidation` (per project memory: `swift test` is broken by SwiftLint plugin's macOS requirement).
- Library / Reader isolated: same pattern with `Library-Package` / `Reader-Package` schemes.

### Mechanical "Android-clean" assertions after Fix 5 + 6 + 7

The following ripgreps must return zero matches at the end of the work:

```sh
rg 'Bundle\.main|CGFloat|CoreGraphics|String\(localized:|LocalizedStringResource|#if canImport' \
   Packages/Domain/Sources/

rg 'String\(localized:|bundle: \.module|LocalizedStringResource' \
   Packages/Features/Library/Sources/Library/LibraryViewModel.swift \
   Packages/Features/Library/Sources/Library/ScoreItemSort.swift \
   Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift
```

These checks formalize the §6.3 rule for the files in scope; future audits can run them verbatim.

## 7. Out of scope (explicit)

| Item | Why deferred |
| --- | --- |
| `*Logic` product split for Library / Reader | Findings §6.1 — separate spec; bigger architectural commit |
| Localization delivery to Android (`.xcstrings` → strings.xml etc.) | Findings §6.4 — strategy spec needed first |
| Other Features (Editor, ImportExport) | No `describe()` / `labelKey` patterns there today |
| `LivePlaybackController.swift` `Bundle.main` | Infrastructure iOS adapter — expected, not a violation |
| Cross-compile of Library/Reader/Domain to Android | Separate spike; this spec only proves syntactic cleanliness |
| `xcstrings` key cleanup (memory `xcstrings_refactor`) | Independent maintenance task |

## 8. Risks

- The Library `describe()` switch is large enough that mechanical replacement (delete from VM,
  paste into View sibling) is the safe path. The translation here is mechanical; no behavior
  change. Risk: missing one `errorAlertMessage = describe(error)` call site. Mitigation: ripgrep
  for `errorAlertMessage =` and `describe(error)` after the change should both return zero in the
  ViewModel file.
- `currentError: Error?` is a non-`Equatable`, non-`Sendable` existential. SwiftUI's `.alert(…,
  presenting:)` accepts `Optional<some Sendable>` — to keep the binding straightforward, the alert
  may need to be reworked into the `isPresented + Text(describe(currentError))` form. Mitigation:
  if SwiftUI's API needs an `Identifiable` or `Hashable` payload, wrap the error in a lightweight
  `IdentifiableError { id = UUID(); error: Error }`. Decision deferred to implementation if the
  refactor surfaces it.
- Test rewrites change assertion shape from "string equals literal" to "error type matches".
  The localized literal in the old assertion was incidentally a regression test for the
  English string content; the new assertion no longer checks the rendered string. Mitigation:
  add one end-to-end smoke that exercises the SwiftUI `describe(_:)` for a representative
  `DomainError` case to keep coverage of the localization mapping.
