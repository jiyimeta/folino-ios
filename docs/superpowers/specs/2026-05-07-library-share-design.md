# Library Share — Design

Add per-row share support to the Library, exposing every export format
`swift-sheet-music` can produce. The same menu is reachable from the
existing context menu (long-press) and from a new trailing ellipsis
button on each row.

## Goals

- Each library row can be shared from a context menu and from a
  trailing ellipsis button — both surface the **same** menu.
- Available share formats per row:
  - **Source format** (the file as imported, with one rule):
    `.mscx` is wrapped via `MSCZWriter` and shared as `.mscz`.
    `.mscz` / `.musicxml` / `.mxl` are shared as-is. Raw `.mscx`
    is never offered.
  - **PDF** — rendered via `PDFExporter`.
  - **MIDI** — rendered via `SheetMusic.exportMIDI` /
    `MidiWriter`.
- Sharing uses the standard iOS share sheet (AirDrop, Files, Mail,
  Messages, etc.), so destinations are not Folino's concern.

## Non-goals

- macOS support (Folino ships iOS only).
- Multi-select + bulk share.
- User-tunable export options (PDF page size, staff size, etc.) —
  defaults from the score's `<Style>` block / library defaults are
  used. v2 may add this.
- `MusicXML` / `mxl` rendered export — `swift-sheet-music` has no
  `Score → MusicXML` serializer today.
- Solving the `PDFExporter` `@MainActor` blocking concern for very
  large scores. See Risks below.
- `ScoreFileGateway.saveScore` implementation — that belongs to the
  Editor work stream.

## Architecture

Strict layered. New code lands in three places.

```
Domain                Infrastructure                Features/Library
──────                ──────────────                ────────────────
ScoreShareService ◀── LiveScoreShareService ──┐
ScoreShareFormat                               │
                                               │
                           App  ──── injects ──┴──▶ LibraryViewModel ──▶ scoreRowMenu
                                                                          │
                                                                          ├─ contextMenu
                                                                          └─ ellipsis Menu
```

`Utility/UtilityUI` gains an iOS-only `ActivityViewControllerRepresentable`
(reusable share-sheet wrapper). No layer violations.

## Domain

New file: `Packages/Domain/Sources/Domain/Protocols/ScoreShareService.swift`.

```swift
public enum ScoreShareFormat: Hashable, Sendable {
    case sourceFormat   // resolves dynamically per item
    case pdf
    case midi
}

public protocol ScoreShareService: Sendable {
    /// Selectable formats for this item, in display order.
    /// All current items return `[.sourceFormat, .pdf, .midi]`.
    func availableFormats(for item: ScoreItem) -> [ScoreShareFormat]

    /// What the source-format entry resolves to for this item.
    /// `.mscx` resolves to `.mscz` (wrapped via `MSCZWriter`).
    /// Other source formats resolve to themselves.
    /// The Library uses this to build the menu label.
    func resolvedSourceFormat(for item: ScoreItem) -> ScoreFormat

    /// Materialize the chosen format as a temporary file and return
    /// its URL. The Infrastructure implementation manages the temp
    /// directory; callers must not delete the returned file.
    func prepareShare(
        item: ScoreItem,
        format: ScoreShareFormat
    ) async throws -> URL
}
```

Domain stays I/O- and locale-free: no labels, no UTType, no UIKit.

## Infrastructure

New file: `Packages/Infrastructure/Sources/ScoreFiles/LiveScoreShareService.swift`
(joins `LiveScoreFileGateway` in the same module — no `Package.swift`
changes).

```swift
public struct LiveScoreShareService: ScoreShareService {
    private let scoresDirectory: URL
    private let shareTempDirectory: URL
    private let gateway: any ScoreFileGateway

    public init(
        scoresDirectory: URL,
        shareTempDirectory: URL,
        gateway: any ScoreFileGateway
    )

    public func availableFormats(for item: ScoreItem) -> [ScoreShareFormat] {
        // [.sourceFormat, .pdf, .midi]
    }

    public func resolvedSourceFormat(for item: ScoreItem) -> ScoreFormat {
        // localFileName follows the import-time invariant
        // "<id>.<canonical-extension>", so detect() is total here.
        // .midi is unreachable today (import gateway blocks it).
        switch ScoreFormat.detect(filename: item.localFileName)! {
        case .mscx, .mscz: return .mscz
        case .musicXML:    return .musicXML
        case .mxl:         return .mxl
        case .midi:        return .midi
        }
    }

    public func prepareShare(
        item: ScoreItem,
        format: ScoreShareFormat
    ) async throws -> URL { ... }
}
```

### Output paths

Inside `shareTempDirectory`:

```
<sanitized-title>.<ext>
```

- `<sanitized-title>` replaces `/`, `:`, `\`, NUL with `_`, trims to
  ≤100 characters, falls back to `"score"` if empty after sanitizing.
- `<ext>` is `format.canonicalExtension`.
- Repeated shares of the same item overwrite the previous file (the
  freshest content always wins).

`shareTempDirectory` is recreated empty on app launch (see App
section). Files within it are not deleted between presentations of
the share sheet — iOS may still be uploading.

### Format dispatch

| Requested `ScoreShareFormat` | Source on disk | Action |
| --- | --- | --- |
| `.sourceFormat` | `.mscx` | `Data(contentsOf:)` → `MSCZWriter.write(mscxData:)` → write `.mscz` |
| `.sourceFormat` | `.mscz` / `.musicxml` / `.mxl` | `FileManager.copyItem` |
| `.pdf` | any | `gateway.loadScore` → `PDFExporter.export(score:)` (on main) → write |
| `.midi` | any | `gateway.loadScore` → `SheetMusic.exportMIDI` → write |

`PDFExporter` is `@MainActor`; the call hops via `await MainActor.run`.
The score load via `gateway.loadScore` already runs detached.

### Errors

Throws `DomainError` (`scoreFileNotFound`, `scoreParseFailed`,
`scoreWriteFailed`, `unsupportedFormat`). Existing
`LibraryViewModel.describe(_:)` already covers these — no new error
strings needed.

## Library feature

### View-model additions

`LibraryViewModel`:

- New stored property `let shareService: any ScoreShareService`,
  injected via `init`.
- New `@Observable` state:
  - `var shareTarget: ShareTarget?` — drives `.sheet`.
  - `var isPreparingShare: Bool = false` — drives a small overlay
    while the temp file is being written.
- Method:
  ```swift
  public func requestShare(
      _ item: ScoreItem,
      format: ScoreShareFormat
  ) async {
      isPreparingShare = true
      defer { isPreparingShare = false }
      do {
          let url = try await shareService.prepareShare(item: item, format: format)
          shareTarget = ShareTarget(url: url)
      } catch {
          errorAlertMessage = describe(error)
      }
  }
  ```
- `ShareTarget: Identifiable, Equatable { let id = UUID(); let url: URL }`.

### Menu unification

The current duplication between `ScoreListView.contextMenuButtons`
and `LibraryRootView.rowContextMenu` is removed. A new internal
`@ViewBuilder` `scoreRowMenu(item:library:onOpen:onEditTags:onAddToPlaylist:onRequestDelete:onRequestShare:)`
in `Packages/Features/Library/Sources/Library/ScoreRowMenu.swift`
becomes the single source of truth.

- `LibraryRootView` calls it from Favorites / Recents sections without
  `onRequestDelete` (matches today's behavior — those sections offer
  no Delete).
- `ScoreListView` calls it with `onRequestDelete` (matches today's
  behavior).

### Share submenu

The menu gains a `Share…` entry implemented as a SwiftUI `Menu` with
one row per `availableFormats(for:)` entry:

| Format | Label | SF Symbol |
| --- | --- | --- |
| `.sourceFormat`, resolved `.mscz` | `MuseScore (.mscz)` | `doc.zipper` |
| `.sourceFormat`, resolved `.musicXML` | `MusicXML (.musicxml)` | `doc.text` |
| `.sourceFormat`, resolved `.mxl` | `MusicXML (.mxl)` | `doc.zipper` |
| `.pdf` | `PDF` | `doc.richtext` |
| `.midi` | `MIDI` | `pianokeys` |

Tap → `Task { await library.requestShare(item, format: fmt) }`.

### Trailing ellipsis button

Each row gains a trailing `Menu` whose label is
`Image(systemName: "ellipsis.circle")` with a 44×44 hit target. The
row layout becomes:

```swift
HStack(spacing: 0) {
    ScoreRow(scoreItem: item)
        .contentShape(Rectangle())
        .onTapGesture { onOpen(item) }
    Menu {
        scoreRowMenu(item: item, ...)
    } label: {
        Image(systemName: "ellipsis.circle")
            .font(.title3)
            .foregroundStyle(.secondary)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(Text("More"))
}
.swipeActions(...) { ... }
.contextMenu { scoreRowMenu(item: item, ...) }
```

This pattern is applied to:

- `ScoreListView.row(for:)`
- `LibraryRootView.favoritesSection`
- `LibraryRootView.recentsSection`

### Share sheet presentation

`LibraryRootView.body` gets two new modifiers:

```swift
.sheet(item: $viewModel.shareTarget) { target in
    ActivityViewControllerRepresentable(items: [target.url])
}
.overlay {
    if viewModel.isPreparingShare {
        ProgressView("Preparing…")
            .padding()
            .background(.regularMaterial, in: .rect(cornerRadius: 12))
    }
}
```

`ActivityViewControllerRepresentable` is a new ~25-line wrapper in
`Packages/Utility/Sources/UtilityUI/` (iOS-only via `#if os(iOS)`),
re-exported from `UtilityUI`. `Packages/Features/Library/Package.swift`
adds `UtilityUI` as a target dependency (currently it depends only on
`Domain`).

## App

Composition root changes in `App/AppBootstrap.swift` and
`App/AppShellView.swift`:

- `AppPaths` gains `static var shareTempDirectory: URL` (sibling of
  `scoresDirectory`).
- `AppBootstrap`:
  - On startup, after creating `scoresDirectory`:
    ```swift
    try? FileManager.default.removeItem(at: AppPaths.shareTempDirectory)
    try FileManager.default.createDirectory(
        at: AppPaths.shareTempDirectory,
        withIntermediateDirectories: true
    )
    ```
  - Build `LiveScoreShareService(scoresDirectory:, shareTempDirectory:, gateway:)`.
- `AppShellView` passes `shareService` into `LibraryViewModel.init`.

## Localization

`Packages/Features/Library/Sources/Library/Resources/Localizable.xcstrings`
gains the user-visible strings introduced here: `"Share…"`,
`"Preparing…"`, `"More"`. Format labels (`PDF`, `MIDI`,
`MuseScore (.mscz)`, etc.) are stable across locales and pass
through as plain strings.

## Tests

### Infrastructure

`Packages/Infrastructure/Tests/ScoreFilesTests/LiveScoreShareServiceTests.swift`:

- mscx input → produced bytes round-trip via
  `SheetMusic.loadScore(msczData:)`.
- mscz / musicxml / mxl inputs → produced bytes byte-equal to the
  source file.
- PDF output starts with the `%PDF` magic.
- MIDI output starts with the `MThd` magic.
- Title-sanitization cases: contains `/`, contains NUL, empty title,
  >100 chars.
- Calling `prepareShare` twice for the same item overwrites without
  error.
- Output lands inside the configured `shareTempDirectory`.

Fixtures: reuse the existing fixtures the parser tests already use,
plus a known-small mscx for the wrap test.

### Library

`Packages/Features/Library/Tests/LibraryTests/LibraryViewModelShareTests.swift`:

- `FakeShareService` injected.
- `requestShare` success → `shareTarget` set, `errorAlertMessage` nil.
- `requestShare` failure → `errorAlertMessage` set, `shareTarget`
  nil.
- `isPreparingShare` toggles around the call.

UI behavior (tap on row vs tap on ellipsis) is verified manually in
the simulator — context menus and swipe interactions are notoriously
brittle to snapshot test on iOS.

### Domain

`ScoreShareFormat` is a plain enum; no tests added.

## Risks / open questions

- **`PDFExporter` blocks the main thread.** swift-sheet-music marks it
  `@MainActor`, so the `Preparing…` overlay accurately reports status
  but cannot prevent UI hitches on very large scores. v2 work item:
  push the export off-main once swift-sheet-music supports it.
- **iOS share sheet retains the URL during upload.** We never delete
  files between presentations; the next-launch sweep cleans up.
- **MIDI imports** are blocked by `LiveScoreFileGateway` today. If
  that ever changes, `prepareShare(.pdf)` and `prepareShare(.midi)`
  for a MIDI item will fail with `scoreParseFailed` — the menu would
  need to drop those entries via `availableFormats`. Out of scope
  here; flag in code as a TODO.
- **Title collisions in `shareTempDirectory`.** Two items sharing the
  same sanitized title would overwrite each other if shared in quick
  succession. In practice each share is presented modally, so the
  user is not sharing two at once. If we ever add multi-select, the
  filename scheme needs UUID disambiguation.

## Out-of-scope follow-ups

- v2: PDF/MIDI options sheet (paper size, staff size, transpose).
- v2: detached PDF export.
- v2: multi-select share.
- Editor task: implement `ScoreFileGateway.saveScore` for native
  saves; `LiveScoreShareService` will not reuse it (different
  responsibility).
