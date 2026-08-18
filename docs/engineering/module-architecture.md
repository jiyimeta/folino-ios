# Module Architecture

folino follows the same strict layered SPM-module shape as the reference project for this codebase, with adjustments for the score-engine dependency. **Read this before making structural changes.**

## Layers

```
App ──▶ Features ──┬─▶ Domain ◀── swift-sheet-music
 │                 └─▶ ScoreUI ──▶ Domain
 │                          └────▶ Utility
 └──▶ Infrastructure ─▶ Domain         Utility is reachable from any layer.
```

- **`Packages/Utility/`** — app-agnostic building blocks (`UtilityCore`, `UtilityUI`, `Navigation`). Must not import Domain / Infrastructure / Features / App. Designed to be lifted into OSS later.
- **`Packages/Domain/`** — value types + protocols. folino-specific types (`LibraryItem`, `Playlist`, `Tag`, `AnnotationLayer`, `PlaybackPreferences`, `SoundfontPatch`) and protocols (`ScoreLibraryRepository`, `AnnotationStore`, `PlaybackController`, `SoundfontResolver`, `CloudSync`, `ScoreFileGateway`). Re-exports `SheetMusicCore` so Features see a single notation model. Foundation-only otherwise — no SwiftUI, no AVFoundation, no SDKs.
- **`Packages/Infrastructure/`** — concrete adapters split into products: `Persistence` (GRDB / SQLite), `CloudSync` (CloudKit Private DB), `Soundfonts` (HTTPS download + cache), `Audio` (`SheetMusicAudio` adapter), `ScoreFiles` (wraps `SheetMusicMSCX` / `SheetMusicMusicXML` / `SheetMusicMIDI` behind `ScoreFileGateway`). Depends on Domain only.
- **`Packages/Features/<Name>/`** — one package per feature: `Library`, `Reader`, `Editor`, `ImportExport`, `Settings`. Owns its views, view models, and navigation. Depends on Domain and the shared `ScoreUI` layer only.
- **`Packages/ScoreUI/`** — shared, score-aware SwiftUI components reused across Features (e.g. the share-format menu `ShareSubmenu` and the `EditScoreInfoSheet` edit-info sheet, decoupled from any feature via the `ScoreInfoEditing` protocol). Depends on Domain + Utility only; must not depend on any Feature, Infrastructure, or App. Exists because such components need Domain types yet must be shared across Features without a `Feature → Feature` edge — which neither Domain (Foundation-only, no SwiftUI) nor Utility (Domain-free) can host. Keep it narrowly scoped to score-item presentation reused by ≥2 features; feature-specific UI stays in the feature.
- **`App/`** — composition root. The only place that wires Infrastructure adapters into Feature view models.

`swift-sheet-music` sits **outside** folino's layer graph as a SwiftPM dependency. It is consumed by Domain (for the model) and Infrastructure (for adapters). Features never import it directly.

**Forbidden** (will be flagged in review):

- Feature → Feature (lift shared code into Domain, the shared `ScoreUI` layer, or compose at App).
- Feature → Infrastructure (always go through a Domain protocol).
- Feature → `swift-sheet-music` model / I/O modules directly (go through Domain re-exports for `SheetMusicCore`; route format I/O through `ScoreFileGateway`).

  *Carve-out:* Feature packages **may** depend directly on `SheetMusicUI`
  (and, when wired up later, `SheetMusicAudio`). These are view- and runtime-
  layer libraries whose entire purpose is to be composed inside an iOS shell.
  Wrapping them behind a Domain protocol would add a layer with no testable
  benefit. The Reader package consumes `ScoreView`, `PagedScoreView`, and
  `PlaybackCursorView` from `SheetMusicUI` directly.
- Domain → Infrastructure / Features / App.
- ScoreUI → Feature / Infrastructure / App (ScoreUI sits below Features; it may depend on Domain + Utility only).
- Utility → anything else in this repo.

## Dependency Injection

Pure constructor injection. No DI library (no swift-dependencies, Factory, Resolver, Swinject, Needle). View models take Domain protocols via `init`. SwiftUI `EnvironmentValues` is reserved for view-tree-scoped concerns (theme, navigation, feature flags) — never used as a service locator for view models.

Ambient services (`Clock`, `UUIDProvider`, `DateProvider`, `Logger`) live as small Utility-layer protocols, also passed via `init`.

## View Layout inside a Feature package — `Screens/` and `Views/`

Inside `Features/<Name>/Sources/<Name>/`, SwiftUI views are split by whether they hold a view model. `Library` is the reference implementation.

```
Features/<Name>/Sources/<Name>/
  <Name>.swift, <Name>Route.swift, <Name>ViewModel.swift   ← root: VM + module entry points
  Screens/   ← holds the VM (@Bindable / @StateObject). Task launch, alert ↔ error wiring, sheet wiring
    <Name>RootScreen.swift    ← public API, called from App
  Views/     ← pure views taking Domain values + closures / @Binding only. Always ship a #Preview
```

- A pure view imports `Domain` and SwiftUI only — never Infrastructure, never a VM type. This is what makes preview-driven iteration possible without standing up Infrastructure.
- To embed one view inside another (a detail screen containing a score list), open a `@ViewBuilder content: () -> Content` slot and pass the `Screen` in from the parent.
- **Pure extraction is not mandatory.** When the binding to the VM is deep enough that going pure means a wall of closure parameters, put the whole file in `Screens/`. "Needs a VM → `Screens/`, doesn't → `Views/`" is the whole rule. Library went all the way to pure extraction; Reader's inspector, score containers and toolbar deliberately stayed in `Screens/`.
- A sheet's pure view keeps the `XxxSheet` name; the `.sheet` modifier itself belongs to the parent Screen.
- For a VM-dependent builder like `scoreRowMenu`, write a **same-named overload** — the pure one in `Views/`, the VM-taking one in `Screens/<Name>+<Feature>.swift`. Call sites don't change.
- Use `git mv` so history follows the file.

Applied to Library, Reader and Settings. Editor and ImportExport predate the convention — apply it as those packages grow.

## Localization

- Key shape is `module.feature.thing` (`library.score.delete.title`); collapse to two levels only when the context is unambiguous (`library.allScores`). This was chosen over flat two-level keys for the balance between scoping and greppability.
- Shared action words (Cancel / OK / Done / Save / Delete / Add / Open / More / Select / Share… / Rename… / Create) live in `Packages/Utility/Sources/UtilityUI/Resources/Localizable.xcstrings` as `common.action.*`, read through the `L10n.Common.*` accessors.
- In Feature and Domain packages, **`String(localized:)` needs `bundle: .module`** — omitting it silently resolves against the main bundle and falls back to the default value. With a format argument, keep key and value separate: `String(localized: "key", defaultValue: "Add \(n) items", bundle: .module)`. The App target reads `Bundle.main`, so `Text("app.foo")` needs no `bundle:`.
- `Info.plist` localized strings are the exception — see Project Generation below.

## Engine Boundary — the `swift-sheet-music` rule

The most important architectural decision in folino is **what goes upstream into `swift-sheet-music` versus what stays inside this repo.** Restated from `docs/product/feasibility.md`:

- **Upstream to `swift-sheet-music`** if any other score app would want it: format read / write, layout math, audio engine features, score model mutation primitives, an iOS-capable view target.
- **Inside folino** if it is bound to folino's UX, sync model, library, settings: page-turn gestures, the PencilKit overlay, the library DB, CloudKit sync, the SoundFont cache UI, the settings screen.

Upstream PRs land first; folino consumes a tagged version. folino does not fork `swift-sheet-music`.

## Testing

- **New tests use Swift Testing** (`import Testing`, `@Suite`, `@Test`, `#expect`). UI tests still need `import XCTest` for `XCUIApplication`.
- **Domain tests** are pure value-type unit tests.
- **Feature tests** run against hand-written fakes that implement Domain protocols — no real CloudKit, no real network, no real audio engine. SwiftUI Preview snapshots cover view-level visual checks where useful.
- **Infrastructure tests** can hit real SQLite / tmpdir file I/O. CloudKit, audio, and HTTPS adapters use fakes that satisfy the Domain protocol surface.
- **Engine-side** behavior (notation parsing, layout, audio synthesis correctness) is the responsibility of `swift-sheet-music`'s own tests, not folino's.

## Build-Time Tooling

- **SwiftLintBuildToolPlugin** (`SimplyDanny/SwiftLintPlugins`) — applied to every Package source target and the App target. Config is the repo-root `.swiftlint.yml`; the plugin walks upward to find it.
- **PrepareLicenseList** (`cybozu/LicenseList`) — extracts third-party license texts at App build time. Surface them via `LicenseListView()` from `import LicenseList`. SoundFont licenses (MIT, attributing MuseScore_General authors) are added as a manual entry because they cover bundled and downloaded resources, not SwiftPM packages.

## Project Generation

- `xcodegen generate` from `project.yml` regenerates `Folino.xcodeproj` (gitignored).
- `Config/Local.xcconfig` is gitignored and holds the developer team ID.
- Bumping a SwiftPM dependency means updating both the relevant `Package.swift` AND the `from:` entry under `packages:` in `project.yml` to the same version.
- `Info.plist` localized strings live in `App/Resources/InfoPlist.xcstrings`; the `Info.plist` value is the development-language fallback.

## Constraints

- **No AudioKit.** folino uses AVFoundation directly via `swift-sheet-music`'s `SheetMusicAudio`, which is built on `AVAudioEngine` + `AVAudioUnitSampler`.
- **No GPL dependencies.** This is a hard constraint and excludes GPL-licensed notation-engine libraries.
- **No web-based notation rendering** (e.g., embedded JavaScript renderers). Native rendering only.
