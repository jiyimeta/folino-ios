# Version History Sheet

Adds an in-app "What's new / version history" sheet. The list is sourced from a hand-edited `VersionHistory.yml` in the App bundle, surfaced both from Settings (full list) and auto-presented at cold launch when the user has updated to a version they haven't seen the history of yet (recent versions expanded, older versions collapsed behind a "See more" button).

Reference implementation: `~/Developer/Personal/ios-apps/VocalTuner`. Folino follows the same overall shape but tightens the architecture (loader implementation lives in `Settings`, Domain stays Foundation-only, `AppVersion` is `RawRepresentable<String>` so persistence is a trivial round-trip), supports only en + ja (no zh/ko), and coordinates with the existing `ReviewPromptCoordinator` so the two cold-launch prompts never collide.

## Goals

- Parse `App/Resources/VersionHistory.yml` and render it inside a SwiftUI sheet.
- Add a Settings entry that pushes a full, uncollapsed list.
- Auto-present the sheet on the first cold launch after an update, with versions newer than the last-seen version shown by default and older versions hidden behind a "See more" button.
- Persist "last seen app version of version history" so that a failed-to-display launch (YAML load error, etc.) gets another chance next time.
- When the auto-sheet would collide with the review pre-prompt on the same cold launch, version history wins and the review prompt is suppressed for this launch (the review counter still ticks, so the next eligible launch is 40 cold-launches later).

## Non-Goals

- Localizations beyond en + ja. (YAML schema is `{ en, ja }`; zh/ko deliberately deferred.)
- Search, filtering, deep-linking, or "what changed in version X" jumping.
- Rich text / Markdown / images inside entries — descriptions are plain strings.
- A welcome / onboarding screen for first installs. First install is silent: `lastOpenedVersionHistory` is bumped to `.current` without showing the sheet.
- Tracking when the user last viewed history per-entry / "new since last viewed" badges anywhere outside this sheet.
- Editor-side UI to manage the YAML; it's a hand-edited resource.

## Architecture

Strict layered SPM rules apply (`docs/engineering/module-architecture.md`). Mapping each piece to a layer:

| Piece | Layer | Why |
|---|---|---|
| `AppVersion` value type | `Domain` | Pure value type, Foundation-only, Comparable. Already a natural domain concept. |
| `VersionHistoryEntry` value type | `Domain` | Pure Codable struct with `[String]` descriptions. Locale-resolution happens inside its `Decodable` impl using `Foundation.Locale`. |
| `VersionHistoryLoader` protocol + `DefaultVersionHistoryLoader` | `Settings` | Loader brings in Yams. Domain stays Foundation-only; Yams lives in `Settings` only. |
| `VersionHistoryViewModel` / `VersionHistoryScreen` | `Settings` | The screen is "settings-adjacent" content and is also entered from Settings, mirroring VocalTuner's placement next to the Info screen. |
| `VersionHistory.yml` | `App/Resources/` | Bundle resource, shipped with the app target. |
| `VersionHistoryPresenter` | `App/` | Owns the cold-launch decision + the `isSheetPresented` flag, alongside `ReviewPromptCoordinator`. Also owns the `UserDefaults` key — Settings reaches `markCurrentVersionAsSeen()` via an injected closure, never via the key directly. |

Yams dependency: added to `Packages/Features/Settings/Package.swift` only. Also bumped under `packages:` in `project.yml` per repo policy.

## Domain types

### `AppVersion`

```swift
public struct AppVersion: Hashable, Sendable, Comparable, CustomStringConvertible, RawRepresentable {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(_ major: Int, _ minor: Int, _ patch: Int) { ... }
    public init?(_ string: String)                  // "1.2.3" -> AppVersion(1, 2, 3)
    public init?(rawValue: String) { self.init(rawValue) }
    public var rawValue: String { description }
    public var description: String { "\(major).\(minor).\(patch)" }

    public static let zero = AppVersion(0, 0, 0)
    public static let current: AppVersion          // from Bundle.main "CFBundleShortVersionString"
}
```

- `init?(String)` accepts dotted semver only — three components, all integers. Anything else returns `nil`.
- `Comparable` is component-wise lexicographic (major > minor > patch).
- `RawRepresentable<String>` is what makes UserDefaults storage trivial — round-trip is just `description` ⇄ `init?(String)`. No packing scheme, no separate persistence format. `@AppStorage` would accept this directly if a call site ever wanted it.

Lives in `Packages/Domain/Sources/Domain/Models/AppVersion.swift`.

### `VersionHistoryEntry`

```swift
public struct VersionHistoryEntry: Equatable, Identifiable, Sendable, Decodable {
    public let version: AppVersion
    public let descriptions: [String]
    public var id: AppVersion { version }
}
```

- `descriptions` are already-localized plain strings — locale resolution happens in the custom `Decodable` init by switching on `Locale.current.language.languageCode?.identifier == "ja"` → `ja`, else `en`. The on-disk YAML stores `{ en, ja }` per description; the decoder picks one and discards the other.
- A YAML entry with a malformed `version` is skipped at the loader level (entry-level `try?`), not at the array level — one bad entry doesn't poison the rest of the list.

Lives in `Packages/Domain/Sources/Domain/Models/VersionHistoryEntry.swift`.

## YAML schema

`App/Resources/VersionHistory.yml`:

```yaml
- version: 1.5.0
  descriptions:
    - en: Added per-staff clef override in the Reader inspector
      ja: Reader インスペクタにスタッフごとの clef 上書きを追加
    - en: Fixed playback after tapping a far-off measure
      ja: 遠く離れた小節をタップした際の再生位置を修正
- version: 1.4.0
  descriptions:
    - en: ...
      ja: ...
```

- Entries listed newest-first (matches VocalTuner; the loader does not sort).
- `version` is a dotted string. `descriptions` is an array of `{ en, ja }` dictionaries.
- Empty `descriptions: []` allowed (the loader returns an empty array; the view shows just the version header — kept for consistency with VocalTuner's `1.0.0` entry).

## Settings module

### `VersionHistoryLoader`

```swift
public protocol VersionHistoryLoader: Sendable {
    func load() throws -> [VersionHistoryEntry]
}

public struct DefaultVersionHistoryLoader: VersionHistoryLoader {
    public init(bundle: Bundle = .main, resourceName: String = "VersionHistory")
    public func load() throws -> [VersionHistoryEntry]   // uses Yams.YAMLDecoder
}
```

- Constructor injection so tests can pass a `Bundle` pointing at a tmpdir YAML.
- `load()` throws if the resource is missing or the YAML is unparseable. Callers translate this into "skip" (auto-presenter) or empty-state (Settings push).

Lives in `Packages/Features/Settings/Sources/Settings/VersionHistory/VersionHistoryLoader.swift`.

### `VersionHistoryViewModel`

```swift
@Observable @MainActor
public final class VersionHistoryViewModel {
    public let isHistorySplit: Bool
    public let recentChanges: [VersionHistoryEntry]
    public let pastChanges: [VersionHistoryEntry]
    public var isPastChangesShown: Bool = false

    public init(entries: [VersionHistoryEntry], baseline: AppVersion, isHistorySplit: Bool)
    public func showMoreButtonDidTap() { isPastChangesShown = true }
}
```

- Splitting happens in `init`: `recent = entries.filter { $0.version > baseline }`, `past = entries.filter { $0.version <= baseline }`.
- For the Settings push, callers pass `baseline: .zero, isHistorySplit: false` → everything ends up in `recentChanges`, rendered as one flat list.
- For the auto-sheet, callers pass `baseline: lastSeen, isHistorySplit: true` → the view renders the split / "See more" UI.
- The model does **not** load YAML or touch `UserDefaults`; both are caller concerns. This keeps the model trivially testable.

Lives in `Packages/Features/Settings/Sources/Settings/VersionHistory/VersionHistoryViewModel.swift`.

### `VersionHistoryScreen`

```swift
public struct VersionHistoryScreen: View {
    public init(viewModel: VersionHistoryViewModel, onAppear: @escaping @MainActor () -> Void)
}
```

- The `onAppear` closure is how the App layer / Settings injects "save `lastOpenedVersionHistory = .current.rawValue`". The view itself never reads or writes `UserDefaults` — it stays inside the Settings module's allowed boundaries.
- Rendering rules:
  - `!isHistorySplit` → one `ForEach` over `recentChanges + pastChanges` (they were partitioned by `baseline = .zero`, so everything is in `recentChanges`; we still concat for symmetry / robustness).
  - `isHistorySplit && past.isEmpty` → only the "Recent updates" section, no "See more" button.
  - `isHistorySplit && !past.isEmpty && !isPastChangesShown` → "Recent updates" section + Divider + "See more" button.
  - `isHistorySplit && !past.isEmpty && isPastChangesShown` → "Recent updates" section + Divider + "Past changes" section.
- Each version row: bold `version.description` header, bulleted descriptions. Major-release rows (`minor == 0 && patch == 0`) get a tinted background (blue in light mode, yellow in dark mode), copying VocalTuner's flourish.
- Localization keys (in `Settings/Resources/Localizable.xcstrings`):
  - `settings.versionHistory.title` — "Version History" / "アップデート履歴"
  - `settings.versionHistory.recentUpdates` — "Recent updates" / "最近の更新"
  - `settings.versionHistory.pastChanges` — "Past changes" / "過去の更新"
  - `settings.versionHistory.showMore` — "See more" / "もっと見る"
  - `settings.versionHistory.empty` — "Version history is unavailable." / "アップデート履歴を読み込めませんでした。"

Lives in `Packages/Features/Settings/Sources/Settings/VersionHistory/VersionHistoryScreen.swift`.

### `SettingsSheet` integration

`SettingsSheet`'s initializer gains two new parameters injected from `App`:

```swift
public init(
    soundfontResolver: (any SoundfontResolver)? = nil,
    presetCatalog: (any SoundfontPresetCatalog)? = nil,
    versionHistoryLoader: any VersionHistoryLoader = DefaultVersionHistoryLoader(),
    onVersionHistoryViewed: @escaping @MainActor () -> Void = {},
    @ViewBuilder licenseContent: @escaping () -> LicenseContent
)
```

- `onVersionHistoryViewed` is wired by `App` to `versionHistoryPresenter.markCurrentVersionAsSeen()`. SettingsSheet (Settings module) never touches `UserDefaults` directly — the key stays an App-layer secret.
- Default arg `{}` keeps previews and standalone callers compiling.

In the `aboutSection`, insert a `NavigationLink` above the existing "Licenses" link:

```swift
NavigationLink {
    versionHistoryDestination()
} label: {
    Label {
        Text("settings.versionHistory.title", bundle: .module)
    } icon: {
        Image(systemName: "clock.arrow.circlepath")
    }
}
```

`versionHistoryDestination()`:

1. Tries `versionHistoryLoader.load()`.
2. On success: `VersionHistoryScreen(viewModel: .init(entries:, baseline: .zero, isHistorySplit: false), onAppear: onVersionHistoryViewed)` wrapped in `.navigationTitle(...)`.
3. On failure: `ContentUnavailableView` with `settings.versionHistory.empty`. **Does not** invoke `onVersionHistoryViewed` (the user got an error, not the actual list).

## App module

### Persistence key

```swift
// App/VersionHistoryPresenter.swift (file-private)
private enum DefaultsKey {
    static let lastOpenedVersionHistory = "app.global.lastOpenedVersionHistory"
}
```

- Value type: `String` — `AppVersion.rawValue` (e.g. `"1.2.3"`). Human-readable in `xcrun defaults read` / debugger.
- Read: `defaults.string(forKey:).flatMap(AppVersion.init(rawValue:)) ?? .zero`. Missing key or unparseable value both collapse to `.zero`.
- Write: `defaults.set(AppVersion.current.rawValue, forKey: ...)`.
- Scope: file-private to `VersionHistoryPresenter.swift`. Only the presenter reads / writes it; the Settings flow goes through the injected `onVersionHistoryViewed` closure.

### `VersionHistoryPresenter`

```swift
@MainActor @Observable
final class VersionHistoryPresenter {
    private let defaults: UserDefaults
    private let loader: any VersionHistoryLoader
    private var hasRegistered = false

    var isSheetPresented = false
    var sheetViewModel: VersionHistoryViewModel?

    init(defaults: UserDefaults = .standard,
         loader: any VersionHistoryLoader = DefaultVersionHistoryLoader())

    func registerColdLaunchIfNeeded() {
        guard !hasRegistered else { return }
        hasRegistered = true
        decideAndPresent()
    }

    func markCurrentVersionAsSeen() {
        defaults.set(AppVersion.current.rawValue, forKey: DefaultsKey.lastOpenedVersionHistory)
    }

    private func decideAndPresent() {
        let loaded = defaults.string(forKey: DefaultsKey.lastOpenedVersionHistory)
            .flatMap(AppVersion.init(rawValue:)) ?? .zero
        let current = AppVersion.current

        if loaded == .zero {                 // First install
            markCurrentVersionAsSeen()
            return
        }
        if loaded >= current { return }      // Already up to date (or downgrade)

        let entries: [VersionHistoryEntry]
        do { entries = try loader.load() }
        catch { return }                     // Silent retry next cold launch

        let recent = entries.filter { $0.version > loaded }
        guard !recent.isEmpty else {         // YAML missing entries for newer versions
            markCurrentVersionAsSeen()
            return
        }

        sheetViewModel = VersionHistoryViewModel(
            entries: entries,
            baseline: loaded,
            isHistorySplit: true
        )
        isSheetPresented = true
    }
}
```

- `hasRegistered` makes it idempotent per process, matching `ReviewPromptCoordinator`'s flow for iPad multi-window scenes.
- `markCurrentVersionAsSeen()` is also what the sheet's `onAppear` calls (passed in from `AppShellView`).

### `ReviewPromptCoordinator` change

Add an opt-out for display while still ticking the counter:

```swift
func registerColdLaunchIfNeeded(suppressDisplay: Bool = false) {
    guard !hasRegistered else { return }
    hasRegistered = true

    let count = defaults.integer(forKey: Self.coldLaunchCountKey) + 1
    defaults.set(count, forKey: Self.coldLaunchCountKey)
    if !suppressDisplay && shouldPrompt(at: count) {
        isPrePromptPresented = true
    }
}
```

- Counter still increments → if both prompts collide, the user waits 40 more cold launches for the next review prompt opportunity. This matches the user's stated preference: collision is rare enough that losing one chance is fine.
- Default arg keeps existing call sites unchanged.

### `FolinoApp` wiring

```swift
@main
struct FolinoApp: App {
    @State private var bootstrap = AppBootstrap()
    @State private var reviewPrompt = ReviewPromptCoordinator()
    @State private var versionHistoryPresenter = VersionHistoryPresenter()
    // ...

    var body: some Scene {
        WindowGroup {
            AppShellView(
                bootstrap: bootstrap,
                reviewPrompt: reviewPrompt,
                versionHistoryPresenter: versionHistoryPresenter
            )
            .task {
                bootstrap.start()
                versionHistoryPresenter.registerColdLaunchIfNeeded()
                reviewPrompt.registerColdLaunchIfNeeded(
                    suppressDisplay: versionHistoryPresenter.isSheetPresented
                )
            }
            .onOpenURL { bootstrap.acceptIncomingURL($0) }
        }
    }
}
```

- Order matters: version history decides first, review consults the result.
- Both are registered inside the same `.task` so the suppression is consistent across iPad multi-window re-entries (each has its own task; the first one to run wins, the rest are no-ops thanks to `hasRegistered`).

### `AppShellView` sheet wiring

The existing `SettingsSheet` call site gains the new closure:

```swift
.sheet(isPresented: $isSettingsPresented) {
    SettingsSheet(
        soundfontResolver: bootstrap.soundfontResolver,
        presetCatalog: bootstrap.presetCatalog,
        onVersionHistoryViewed: { versionHistoryPresenter.markCurrentVersionAsSeen() }
    ) {
        LicenseListView()
    }
}
```

And the auto-sheet binding is added alongside it:

```swift
.sheet(isPresented: $versionHistoryPresenter.isSheetPresented) {
    if let vm = versionHistoryPresenter.sheetViewModel {
        NavigationStack {
            VersionHistoryScreen(
                viewModel: vm,
                onAppear: { versionHistoryPresenter.markCurrentVersionAsSeen() }
            )
            .navigationTitle(Text("settings.versionHistory.title", bundle: .module))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { versionHistoryPresenter.isSheetPresented = false } label: { L10n.Common.done }
                }
            }
        }
    }
}
```

- `App` imports `Settings`, so referencing `VersionHistoryScreen` directly is fine.
- The bundle for the navigation title is `Settings` module's `.module` bundle, which is OK because `App` imports `Settings`.

## Data flow

```
Cold launch
  └─ FolinoApp.task
       ├─ bootstrap.start()
       ├─ versionHistoryPresenter.registerColdLaunchIfNeeded()
       │    ├─ read lastOpenedVersionHistory (Int -> AppVersion)
       │    ├─ .zero    → write .current, done (no sheet)
       │    ├─ >= .current → done (no sheet)
       │    └─ < .current →
       │         ├─ loader.load() failed → done (no sheet, no write)
       │         ├─ recent empty       → write .current, done (no sheet)
       │         └─ recent non-empty   → build viewModel, isSheetPresented = true
       └─ reviewPrompt.registerColdLaunchIfNeeded(
              suppressDisplay: versionHistoryPresenter.isSheetPresented
          )

AppShellView .sheet binds to presenter.isSheetPresented
  └─ VersionHistoryScreen.onAppear → presenter.markCurrentVersionAsSeen()

Settings flow
  └─ SettingsSheet aboutSection NavigationLink → versionHistoryDestination()
       ├─ loader.load() failed → ContentUnavailableView (no write)
       └─ loader.load() ok     → VersionHistoryScreen(baseline: .zero, isHistorySplit: false,
                                       onAppear: writes lastOpenedVersionHistory = .current)
```

## Error handling

| Failure | Auto-sheet | Settings push |
|---|---|---|
| `VersionHistory.yml` missing from bundle | Silent skip, no write → retry next cold launch | `ContentUnavailableView` with `settings.versionHistory.empty` |
| YAML unparseable | Silent skip, no write → retry next cold launch | Same as above |
| Single entry malformed (bad `version` string, missing `descriptions`) | Skipped at entry level; remaining entries shown | Same |
| `recent` empty after filtering | Write `.current`, no sheet | N/A (Settings always shows everything) |
| `Bundle.main`'s `CFBundleShortVersionString` malformed | `AppVersion.current` would crash on force-unwrap | The `AppVersion.current` initializer should be a `fatalError`-on-failure (treat malformed app version as a build-time bug). Matches VocalTuner. |

Logging: failures use `Logger(subsystem: "com.KeyNumber.Folino", category: "VersionHistory")` so we can grep Console for "version history failed to load" during QA.

## Testing

### Domain (`Packages/Domain/Tests/DomainTests/`)

`AppVersionTests` (Swift Testing):
- `init?(String)` valid: `"1.2.3"` → `AppVersion(1, 2, 3)`.
- `init?(String)` invalid: `"1.2"`, `"1.2.3.4"`, `"abc"`, `""` → nil.
- `Comparable`: 1.0.0 < 1.0.1 < 1.1.0 < 2.0.0 (table-driven).
- `rawValue` round-trip: for several versions, `AppVersion(rawValue: v.rawValue) == v`.
- `.zero.rawValue == "0.0.0"`; `AppVersion(rawValue: "0.0.0") == .zero`.

`VersionHistoryEntryTests`:
- Decodable round-trip with locale forced to `ja` → `descriptions` are the `ja` strings.
- Decodable round-trip with locale forced to `en` → `descriptions` are the `en` strings.
- Decodable round-trip with empty `descriptions: []`.
- Decoding fails when `version` string is malformed (asserted via `#expect(throws:)`).

### Settings (`Packages/Features/Settings/Tests/SettingsTests/`)

`DefaultVersionHistoryLoaderTests`:
- Writes a known-good YAML to `tmpdir`, builds a `Bundle` pointing at it, asserts entries decode correctly.
- Missing file → throws.
- Garbage YAML → throws.
- Mixed valid + invalid entries: invalid ones are skipped, valid ones are returned. (Decision: do this at the loader level by decoding each top-level array element with `try?`, then `compactMap`.)

`VersionHistoryViewModelTests`:
- `baseline = .zero` → all entries land in `recentChanges`, `pastChanges` empty.
- `baseline = 1.2.0`, entries spanning 1.0.0 .. 1.5.0 → recent contains > 1.2.0, past contains <= 1.2.0.
- `showMoreButtonDidTap()` flips `isPastChangesShown` from false to true.

### App (`Folino` xctest target)

`VersionHistoryPresenterTests` (uses an in-memory `UserDefaults` and a fake loader):
- First install (no key set / unparseable value): no sheet, `lastOpenedVersionHistory` is bumped to `.current.rawValue`.
- Stored == current: no sheet, no write.
- Stored > current (downgrade): no sheet, no write.
- Stored < current + loader throws: no sheet, no write (retry-friendly).
- Stored < current + loader returns no entries newer: no sheet, write performed.
- Stored < current + loader returns newer entries: sheet shown with the right `baseline`, write **not** performed by `registerColdLaunchIfNeeded` itself (write happens via `markCurrentVersionAsSeen()` called from the view's `onAppear`).
- `registerColdLaunchIfNeeded()` is idempotent: calling twice has the same observable effect as calling once.

`ReviewPromptCoordinatorTests` additions:
- `suppressDisplay: true` still increments counter but never sets `isPrePromptPresented`.
- `suppressDisplay: false` (existing behavior) unchanged.

UI verification: manual. Cold launch with a seeded `lastOpenedVersionHistory` is hard to script via XCUITest reliably; testing the presenter in isolation covers the logic.

## Project / build wiring

- `project.yml`:
  - Add `Yams` to the `packages:` block (matching the version Settings uses).
  - `App/Resources/VersionHistory.yml` is picked up by the existing `App/Resources/**` glob; verify after generating.
- `Packages/Features/Settings/Package.swift`:
  - Add `.package(url: "https://github.com/jpsim/Yams", from: "<version>")`.
  - Add `.product(name: "Yams", package: "Yams")` to the `Settings` target dependencies.
- No changes to `Domain`'s package — it stays Foundation-only.

## Migration / rollout

- Existing installs: `lastOpenedVersionHistory` key is absent on first launch after the update → `defaults.string(forKey:)` returns `nil` → flatMap collapses to `.zero` → presenter treats this as "first install" → silently bumps to current. No sheet on the very first launch after this feature ships, by design (we don't have a history of where they came from). Subsequent updates will trigger the sheet normally.
- If we want the *first* post-feature-ship launch to also show the sheet for existing users, we'd need a separate "migrate from no-key" branch — explicitly out of scope. The trade-off is a one-time miss for existing users, in exchange for a much simpler model.

## Open points the implementation plan should make explicit

- Exact Yams version pin (depends on what's already used elsewhere; pick one when wiring `project.yml`).
- Exact SF Symbol for the Settings entry icon (`clock.arrow.circlepath` is the working choice; reconsider during UI review).
- Whether the auto-sheet should set `.presentationDetents` (e.g., `[.medium, .large]`) — default to `.large` only for v1.
- Whether the YAML resource ships with a placeholder `1.0.0` entry (matches VocalTuner) or starts empty for the first release where this lands.
