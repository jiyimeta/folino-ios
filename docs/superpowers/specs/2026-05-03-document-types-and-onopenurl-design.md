# Document Types + onOpenURL — Design

## Goal

Make Folino a valid "Open in" target for score files coming from Files.app, AirDrop, Mail attachments, Safari downloads, and similar system-mediated sharing surfaces. The user opens (or shares) a `.mscx` / `.mscz` / `.musicxml` / `.mxl` / `.xml` / `.midi` file → iOS launches or foregrounds Folino → the file flows through the existing import pipeline (dedupe alert + auto-push to Reader on success).

This is a v1 follow-up tracked in `docs/superpowers/specs/2026-05-02-library-and-minimum-reader-design.md` ("Out-of-Scope" section).

## Scope

In:

- `CFBundleDocumentTypes` + `UTImportedTypeDeclarations` registration for the five `ScoreFormat` cases plus bare `.xml` (`xml` is registered as an additional filename extension on the MusicXML UTType, not a separate type — this matches `swift-sheet-music`'s `Example/Info.plist`).
- `LSSupportsOpeningDocumentsInPlace = YES` so Folino appears in the Files.app share sheet without iOS forcing a copy upfront.
- `.onOpenURL` handler on the WindowGroup that funnels into the existing `LibraryViewModel.startImport(from:)`.
- Cold-launch buffering: if `AppBootstrap` hasn't finished initializing when the URL arrives, hold the URL and dispatch once `isReady` flips true.
- `startAccessingSecurityScopedResource()` / `stopAccessingSecurityScopedResource()` discipline inside the importer entry point so URLs from Files.app / iCloud Drive / share sheets are readable.

Out:

- Multi-file import (queueing several URLs in one shot). Single-URL only in v1.
- Custom document icons (`UTTypeIconFiles` is left empty, matching `swift-sheet-music`'s example).
- A "remove from Inbox" cleanup step. With `LSSupportsOpeningDocumentsInPlace = YES` modern iOS doesn't typically copy to `Documents/Inbox` for share-sheet opens; if it does (e.g., Mail attachment), the file will live in `Inbox/` until the OS reaps it. Importer copies bytes into `Documents/Scores/<uuid>.<ext>` regardless, so leaving Inbox alone is acceptable for v1.
- MIDI parsing — `swift-sheet-music` does not implement SMF → `Score`. `.midi` is registered for parity with the existing `.fileImporter` set, but opening a MIDI file produces the same `DomainError.scoreParseFailed("MIDI parsing not yet supported")` alert that the existing import path produces. When `swift-sheet-music` adds an SMF reader, this design needs no further change.

## Non-Goals (deferred to later plans)

- AirDrop send (Folino → other device). This design covers receiving only.
- URL-scheme deeplinks (`folino://...`). The handler routes file URLs only.
- Share Extension (system share sheet from inside other apps).

## Architecture

### Info.plist (managed by `project.yml`)

The plist content is appended to `App/Info.plist`. It is generated/written manually (no `xcodegen` plugin needed). Identifiers and `LSHandlerRank` values match `swift-sheet-music/Example/Info.plist` so a future user with both apps installed sees a coherent "Open in" sheet.

`CFBundleDocumentTypes` (5 entries):

| `CFBundleTypeName` | `LSItemContentTypes` | `LSHandlerRank` |
|---|---|---|
| MuseScore Score (mscx) | `org.musescore.mscx` | `Default` |
| MuseScore Score (mscz) | `org.musescore.mscz` | `Default` |
| MusicXML | `com.recordare.musicxml` | `Default` |
| Compressed MusicXML | `com.recordare.musicxml.zipped` | `Default` |
| Standard MIDI File | `public.midi-audio` | `Alternate` |

`UTImportedTypeDeclarations` (4 entries — MIDI is a system UTI, no declaration needed):

| `UTTypeIdentifier` | conformsTo | filename-extension(s) | mime-type |
|---|---|---|---|
| `org.musescore.mscx` | `public.xml` | `mscx` | — |
| `org.musescore.mscz` | `public.zip-archive` | `mscz` | — |
| `com.recordare.musicxml` | `public.xml` | `musicxml`, `xml` | `application/vnd.recordare.musicxml+xml` |
| `com.recordare.musicxml.zipped` | `public.zip-archive` | `mxl` | `application/vnd.recordare.musicxml` |

Top-level keys:

- `LSSupportsOpeningDocumentsInPlace = true`

### `AppBootstrap` URL queue

`AppBootstrap` gains:

```swift
private(set) var pendingIncomingURL: URL?

func acceptIncomingURL(_ url: URL) {
    pendingIncomingURL = url
}

func consumePendingIncomingURL() -> URL? {
    let url = pendingIncomingURL
    pendingIncomingURL = nil
    return url
}
```

Why store on the bootstrap rather than directly on `LibraryViewModel`: `LibraryViewModel` only exists once `AppBootstrap.isReady` is true (it's constructed inside `ReadyShell`). A URL received during the few hundred milliseconds of cold-launch initialization needs to live somewhere that survives until the view model is wired up.

### `FolinoApp` modifier

```swift
WindowGroup {
    AppShellView(bootstrap: bootstrap)
        .task { bootstrap.start() }
        .onOpenURL { bootstrap.acceptIncomingURL($0) }
}
```

`onOpenURL` fires after the View is mounted, including for cold launches that result from a tap on a file. SwiftUI guarantees this fires after `body` runs at least once, so `bootstrap` exists.

### `AppShellView` / `ReadyShell` consumer

Inside `ReadyShell` (the branch that has the `LibraryViewModel` and is mounted only when `isReady == true`):

```swift
.task(id: bootstrap.pendingIncomingURL) {
    guard let url = bootstrap.consumePendingIncomingURL() else { return }
    await libraryVM.startImport(from: url)
}
```

The `.task(id:)` re-runs whenever the URL changes (including from `nil` → URL). Both cold-launch (URL set before `isReady`, view appears, task fires) and warm-foreground (URL set after `isReady`, task fires immediately) flow through the same handler.

### `LiveScoreFileImporter.prepareImport` security-scoped resource

The fix lives in the importer rather than the view model because security-scoped access is a property of the URL itself; the importer is the only place that opens the bytes.

```swift
public func prepareImport(sourceURL: URL) async throws -> ImportPlan {
    let didStart = sourceURL.startAccessingSecurityScopedResource()
    defer { if didStart { sourceURL.stopAccessingSecurityScopedResource() } }
    // ... existing logic (detectFormat, gateway.loadFileMetadata, dup query)
}
```

`startAccessingSecurityScopedResource()` returns `false` for URLs that don't need / support the call (e.g., URLs to our own Documents directory), in which case `defer` skips the `stop` call. URLs from `.fileImporter` are already wrapped in security scope, but the call is idempotent — calling it twice is harmless.

## Data Flow

```
User taps a .mscz in Files.app → "Open in Folino"
  iOS launches Folino (cold) or foregrounds it
  SwiftUI calls onOpenURL(url) on WindowGroup
    bootstrap.acceptIncomingURL(url)            // pendingIncomingURL = url
  bootstrap.start() finishes (already running or just-fired)
    isReady = true                              // AppBootstrap is observable
  AppShellView re-evaluates body → ReadyShell appears (if cold launch)
    .task(id: pendingIncomingURL) fires:
      consumePendingIncomingURL() returns url   // clears the slot
      await libraryVM.startImport(from: url)
        prepareImport(sourceURL:) acquires security-scoped access
          → detectFormat → loadFileMetadata → dup query
        no dup    → commit → pendingScoreToOpen = item
        has dup   → duplicatePrompt = (plan, existing)
        error     → errorAlertMessage = describe(error)
  Existing AppShellView .onChange(pendingScoreToOpen) pushes the Reader.
```

For warm-foreground re-entry (Folino is already running), iOS skips the "launch" step but everything else runs identically. `bootstrap.isReady` is already `true`, so `.task(id:)` fires the same iteration.

## Error Handling

All error surfaces use the existing `LibraryViewModel.errorAlertMessage` alert. The four observable failure modes:

| Cause | Surfaces As |
|---|---|
| `.midi` URL | `DomainError.scoreParseFailed("MIDI parsing not yet supported")` (existing) |
| Unknown extension (e.g. plain `.zip`, `.txt`) | `DomainError.unsupportedFormat(ext)` (existing) |
| File unreadable / disappeared between Files.app pick and import | `DomainError.scoreFileNotFound(name:)` (existing) |
| Parse fails (corrupt mscx, etc.) | `DomainError.scoreParseFailed(reason:)` (existing) |

No new error type is introduced. The existing localized strings in `Library/Resources/Localizable.xcstrings` cover all four.

If `acceptIncomingURL` is invoked while `bootstrap.failure` is set (the bootstrap couldn't finish), the URL is still queued. When the user dismisses the bootstrap-failure screen and a future re-launch succeeds, the queued URL fires. This is acceptable degenerate behavior (better than dropping the URL silently). v1 doesn't surface a separate "incoming file received but app couldn't start" alert.

## Testing Strategy

### `AppBootstrap` URL queue

The project has no App-level test target (only SPM-package tests). The URL queue's logic is two trivial accessors over a single optional — risk of regression is negligible — and adding an App-level XCTest target only to cover this would be disproportionate. No automated tests for the queue in v1; behavior is exercised by the manual verification matrix below. If the queue grows additional logic later (debouncing, multi-URL queue, deeplink routing), at that point we extract the queue into a Domain protocol + Infrastructure adapter and gain unit-testability for free.

### `LiveScoreFileImporter` security-scoped (`Packages/Infrastructure/Tests`)

The existing tests construct URLs from `tmpdir` paths, which return `false` from `startAccessingSecurityScopedResource()`. Adding the start/stop calls does not regress those tests. No new test is added — the bracket is small and Apple-API-shaped, and the integration tests already exercise the full prepare → commit cycle from a `tmpdir` URL.

### Manual verification (no commit; documented in plan task)

1. AirDrop a `君とParadiso.mscz` from Mac → iPhone → tap "Open with Folino" → Reader opens at the score (or duplicate alert if already imported).
2. Mail attachment: send a `.musicxml` to a test account → tap attachment → "Share" → Folino → same.
3. Files.app → long-press a `.mscx` → Share → Folino → same.
4. iCloud Drive → tap a `.mscx` → "Open in Folino" → same.
5. Tap a `.mid` from Files.app → Folino opens → error alert "Folino can't open this file type." (Existing localized string covers it.)
6. Cold launch (force-quit Folino, then tap a file) — verify the URL is processed correctly after bootstrap finishes.

## Implementation Surface

Files added or modified:

- `App/Info.plist` — append `CFBundleDocumentTypes`, `UTImportedTypeDeclarations`, `LSSupportsOpeningDocumentsInPlace`.
- `App/AppBootstrap.swift` — add `pendingIncomingURL` + `acceptIncomingURL` + `consumePendingIncomingURL`.
- `App/FolinoApp.swift` — add `.onOpenURL` modifier.
- `App/AppShellView.swift` — add `.task(id: bootstrap.pendingIncomingURL)` inside `ReadyShell`.
- `Packages/Infrastructure/Sources/ScoreFiles/LiveScoreFileImporter.swift` — wrap `prepareImport` body in security-scoped access.
- `docs/superpowers/specs/2026-05-02-library-and-minimum-reader-design.md` — strike "Document Types / `onOpenURL`" from the v1 follow-up list. Bookkeeping only; the implementation plan handles this in the wrap-up commit.

No package modules change. No new types. No new error cases.
