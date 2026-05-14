# Share Extension — Design

Add a Share Extension target so Folino appears prominently in the iOS share sheet of any host app (Files, Mail, Discord, AirDrop receivers, etc.) when sharing score files. The extension lets the user pick a destination playlist and either save quietly or save-and-open in the Reader.

## Goals

- Folino shows up in the system share sheet's top-row "Suggestions" / app grid for `.mscz`, `.mscx`, `.musicxml`, `.mxl`, `.xml`, `.midi` items shared from any host app.
- The share UI lets the user:
  - See a summary of which files are being shared.
  - Pick a destination: `Library only` (default), an existing playlist, or create a new playlist inline.
  - Confirm via two distinct primary actions: `Save` (stay in host app) and `Save & Open` (launch Folino into Reader after import).
- Multi-file shares are accepted; the same playlist target applies to every file in the batch.
- The Reader-push behavior of the existing `.onOpenURL` path is preserved unchanged; the new flow is parallel to (not replacing) the Files-app `Open in Folino` path.

## Non-goals

- A separate "send Folino files to other devices" share-out flow. The Library row share menu already covers that (`docs/superpowers/specs/2026-05-07-library-share-design.md`).
- Per-file playlist selection. v1 applies the same playlist to all files in the batch.
- Migrating the existing `.onOpenURL` (file-URL) path into the new share extension. The two paths coexist.
- An in-extension duplicate confirmation dialog. Share-extension duplicates are silently resolved by reusing the existing `ScoreItem` (see "Dedupe policy" below). The existing `.onOpenURL` path keeps its dedupe alert.
- Moving the Library SQLite DB into the App Group container. The DB stays in the main app's `Documents/` (this would be Approach B/C, deferred — see "Future work").
- `UTExportedTypeDeclarations` reshuffling (kept as `Imported` — owner remains MuseScore). Tracked separately.

## Architecture

### Module placement

Extend the existing (currently empty) `Packages/Features/ImportExport/` SPM package with two library products:

| Product | Sources path | Role | Depends on |
|---|---|---|---|
| `ImportExport` | `Sources/ImportExport/` | Main-app side: URL routing, drain coordinator, playlists.json writer | `Domain`, `UtilityCore` |
| `ImportExportShareUI` | `Sources/ImportExportShareUI/` | Share-extension side: SwiftUI views, ShareSession, intent.json writer | `Domain`, `UtilityCore`, `UtilityUI` |

A shared submodule `Sources/ImportExportAppGroup/` (third library product, dependency of both above) holds App-Group container path helpers and the shared `IncomingShareIntent` / `PlaylistsIndex` codable types. This avoids cross-product file duplication while keeping the extension-side product surface minimal.

Both products live in the Features layer and depend only on Domain. No Infrastructure imports — file I/O against the App Group container is plain `FileManager`, not `Persistence`.

### Targets (project.yml)

- New target `FolinoShareExtension`:
  - `type: app-extension`
  - `platform: iOS 26`
  - `App/ShareExtension/Info.plist` with `NSExtension` configuration (Activation rule on `org.musescore.mscz`, `org.musescore.mscx`, `com.recordare.musicxml`, `com.recordare.musicxml.zipped`, `public.midi-audio`)
  - App Group entitlement: `group.com.KeyNumber.Folino`
  - Dependencies: `ImportExportShareUI`, `ImportExportAppGroup`
  - Bundle ID: `com.KeyNumber.Folino.ShareExtension`
- Existing `Folino` target:
  - Embeds the extension (`embed: true`)
  - App Group entitlement added
  - Dependency on `ImportExport` (replaces the current placeholder dependency, if any)
- `CFBundleURLTypes` added to `App/Info.plist` registering the `folino://` scheme

### App Group container layout

```
group.com.KeyNumber.Folino/
├── playlists.json             ← main app writes, extension reads
└── IncomingImports/
    └── <token-uuid>/
        ├── intent.json        ← extension writes, main app reads
        └── files/
            ├── <original-name-1>.mscz
            └── <original-name-2>.musicxml
```

- `playlists.json` is atomically rewritten by `PlaylistsIndexWriter` whenever `LiveScoreLibraryRepository.savePlaylist` / `deletePlaylist` succeeds and once at `AppBootstrap.start` completion.
- `IncomingImports/<token>/files/` holds raw byte copies pulled out of `NSItemProvider`; the extension copies before `completeRequest` so it does not rely on temporary security-scoped URLs the host gave it.
- Each token directory is deleted by `IncomingShareCoordinator` after drain (success or partial-failure).

### URL scheme

New scheme `folino://import?token=<uuid>&open=<true|false>`. Registered in `CFBundleURLTypes`. The existing `.onOpenURL` handler in `FolinoApp` already runs for any incoming URL; `AppBootstrap.acceptIncomingURL` is extended to branch on `scheme == "folino"` and route share tokens to a dedicated slot (`pendingShareToken`) separate from the file-URL slot (`pendingIncomingURL`).

The extension fires the URL via a responder-chain walk to `UIApplication.shared.open(_:options:completionHandler:)`. Failure is non-fatal: drain-on-launch will still pick up the token at the next cold launch.

### Data flow

1. User invokes share from a host app and taps Folino.
2. iOS launches `FolinoShareExtension`, presenting `ShareViewController` (which hosts the SwiftUI root from `ImportExportShareUI`).
3. The extension:
   1. Reads each `NSItemProvider` (`loadFileRepresentation(forTypeIdentifier:)`) and copies bytes to `IncomingImports/<token>/files/<original-name>`.
   2. Reads `playlists.json` and renders the picker.
   3. On confirm: writes `intent.json` atomically (`<token>/intent.json.tmp` then rename), calls `completeRequest`, walks the responder chain to call `open(_:options:completionHandler:)` with `folino://import?token=<token>&open=<bool>`.
4. The main app's `FolinoApp.onOpenURL` receives the URL → `AppBootstrap.acceptIncomingURL` stores `pendingShareToken`.
5. `ReadyShell` observes `pendingShareToken` and invokes `IncomingShareCoordinator.drain(token:)`.
6. Coordinator:
   1. Reads `intent.json`.
   2. If `newPlaylistName` is set: creates a `Playlist` via `repository.savePlaylist`.
   3. For each file: `importer.prepareImport(sourceURL:)` → `importer.commitImport(_:decision:)` (decision = `openExisting` if `duplicates.first` exists, else `importAsNew`).
   4. If a target playlist exists (existing or newly created): appends imported `ScoreItemID`s to its `orderedScoreItemIDs` and saves.
   5. Deletes `IncomingImports/<token>/`.
   6. Returns `DrainResult`.
7. `AppShellView` renders banner / HUD based on `DrainResult`, and pushes the last imported `ScoreItem` into Reader iff `openAfter == true && imported.last != nil`.

### Drain-on-launch fallback

`AppBootstrap.start` invokes `incomingShareCoordinator.drain(token: nil)` after `repository.refresh()` succeeds. `drain(token: nil)` enumerates every subdirectory of `IncomingImports/`, sorts by `intent.createdAt`, and processes them sequentially. This guarantees no token is ever lost even if the extension's `openURL` call was rejected or the main app was force-killed mid-flight.

A concurrency guard (an actor or `MainActor`-isolated `inFlight` flag) prevents drain-on-launch and drain-from-URL from racing.

### Dedupe policy

Share-extension imports always silently resolve duplicates by reusing the existing `ScoreItem` (`ImportDecision.openExisting`). Rationale:

- Re-sharing a file the user already has is the dominant misuse case; an alert would be noise.
- The existing record (with its annotations, reader preferences, playlist memberships) is what the user actually wants to act on.
- `DrainResult.skipped` surfaces the duplicate with `SkipReason.duplicate(existingID:)` so the banner can read `Already in Library: <title>` and `openAfter == true` opens the existing item in Reader.

The existing `.onOpenURL` (file://) path's duplicate alert is untouched.

### Playlist creation inline

If the user picks `+ New playlist…` and types a name:

- The extension does **not** generate the `PlaylistID` (Approach A: the extension never writes to the DB).
- `intent.json.newPlaylistName` carries the name string; `playlistID` is nil.
- The coordinator creates the `Playlist` in main-app DB before importing.
- If `newPlaylistName` collides with an existing playlist name, a duplicate-named playlist is created (matches the main app's current allow-duplicate-names behavior).

## UI / UX

### Share Extension UI

Single-screen SwiftUI layout, hosted from `ShareViewController`. iPhone and iPad both render the same view; iPad displays it in the system-provided popover sheet, no per-device adaptation needed.

```
┌─────────────────────────────────────┐
│ Cancel         Folino               │  Nav bar
├─────────────────────────────────────┤
│  3 scores                           │  Summary
│  ▾ Show files                       │
│                                     │
│  Add to playlist                    │
│  ◉ Library only                     │  Default
│  ○ Practice queue                   │
│  ○ Jazz studies                     │
│  ○ Beethoven sonatas                │
│  ⊕ New playlist…                    │  Inline create
│                                     │
├─────────────────────────────────────┤
│  [Save]    [ Save & Open ]          │  Action footer
└─────────────────────────────────────┘
```

- Summary row: `<N> score(s)` plus an expandable `▾ Show files` disclosure listing original filenames. If any items are unsupported (their type ID does not appear in the activation rule but somehow arrived), an inline warning `<K> unsupported file(s) will be skipped` is shown.
- Playlist picker: single-select list. `Library only` is selected by default. Existing playlists are listed in `createdAt` ascending order (matches the Library tab). The last row, `⊕ New playlist…`, expands into an inline text field with a `Create` button (disabled while the trimmed name is empty).
- Action footer: two buttons. `Save` is secondary (outlined), `Save & Open` is primary (accent-filled). They are horizontal on iPhone; if the localized labels overflow, they wrap to vertical stack.
- Cancel button (top-left) discards the staged token directory (`IncomingImports/<token>/` is removed) before calling `completeRequest(returningItems: [], completionHandler: nil)`.

### Main-app drain UI

The existing `IncomingURLLoadingHUD` (defined in `docs/superpowers/specs/2026-05-09-incoming-url-loading-hud-design.md`) is extended to display `<N> / <M> imported` for multi-file drains. After drain completes:

| Result | Behavior |
|---|---|
| All succeeded, `openAfter == false` | HUD dismisses; banner shows `<N> score(s) added to "<playlist-name>"` for 2 s (or `<N> score(s) added to Library` when `targetPlaylistID == nil`). |
| All succeeded, `openAfter == true` | HUD dismisses; last imported item is pushed into Reader. |
| Partial success | HUD dismisses; banner shows `<N of M> imported. <reason> for <K> file(s)`. |
| Silent dedupe hit (`openAfter == true`, all duplicates) | Existing item opens in Reader; banner: `Already in Library: <title>`. |

### Localization

Share Extension UI strings live in a new bundle-local `App/ShareExtension/ShareExtension.xcstrings`. Keys follow the existing `module.feature.thing` convention with prefix `share_extension.*`. Common terms (`Cancel`, `Save`) reuse `UtilityUI.L10n.Common` where possible.

## Data flow / Public API

### Shared (`ImportExportAppGroup` library)

```swift
public enum AppGroupIDs {
    public static let identifier = "group.com.KeyNumber.Folino"
}

public enum AppGroupPaths {
    public static let playlistsIndexFilename = "playlists.json"
    public static let incomingImportsDirname = "IncomingImports"
    public static let intentFilename = "intent.json"
    public static let filesDirname = "files"

    public static func container() -> URL?  // FileManager.default.containerURL(forSecurityApplicationGroupIdentifier:)
}

public struct PlaylistsIndex: Codable, Sendable {
    public let schemaVersion: Int   // = 1
    public let playlists: [Entry]

    public struct Entry: Codable, Sendable {
        public let id: PlaylistID
        public let name: String
    }
}

public struct IncomingShareIntent: Codable, Sendable {
    public let schemaVersion: Int   // = 1
    public let token: UUID
    public let createdAt: Date
    public let playlistID: PlaylistID?       // nil = Library only
    public let newPlaylistName: String?      // mutually exclusive with playlistID
    public let openAfter: Bool
    public let files: [File]

    public struct File: Codable, Sendable {
        public let relativePath: String      // "files/<original-name>"
        public let originalName: String
    }
}
```

### Main-app side (`ImportExport` library)

```swift
@MainActor
public final class IncomingShareCoordinator {
    public init(
        importer: ScoreFileImporter,
        repository: ScoreLibraryRepository,
        appGroupContainer: URL,
        clock: any Clock,
    )

    /// `token == nil` → drain every token in IncomingImports/ in createdAt order.
    public func drain(token: UUID?) async -> DrainResult
}

public struct DrainResult: Sendable {
    public let imported: [ScoreItemID]
    public let skipped: [Skip]
    public let openAfter: ScoreItemID?
    public let createdPlaylistID: PlaylistID?
    public let targetPlaylistID: PlaylistID?
    public let targetPlaylistName: String?
}

public struct Skip: Sendable {
    public let originalName: String
    public let reason: SkipReason
}

public enum SkipReason: Sendable {
    case unsupportedFormat
    case unreadable(Error)
    case parseFailed(Error)
    case persistenceFailed(Error)
    case duplicate(existingID: ScoreItemID, existingTitle: String)
}

@MainActor
public final class PlaylistsIndexWriter {
    public init(appGroupContainer: URL)
    public func rewrite(playlists: [Playlist])   // atomic via tmp + rename
}
```

`LiveScoreLibraryRepository` is modified to take a `PlaylistsIndexWriter` (or a closure / protocol) and invoke its rewrite after each `savePlaylist` / `deletePlaylist`. To keep `Persistence` free of `ImportExport`, the dependency is inverted via a small protocol declared in Domain:

```swift
// Packages/Domain/Sources/Domain/Protocols/PlaylistsIndexPublisher.swift
public protocol PlaylistsIndexPublisher: Sendable {
    func publish(playlists: [Playlist]) async
}
```

`PlaylistsIndexWriter` conforms; `LiveScoreLibraryRepository` accepts a `PlaylistsIndexPublisher?` (nil-safe for tests) and calls it after each playlist mutation.

### Extension side (`ImportExportShareUI` library)

```swift
@MainActor
public final class ShareSession {
    public init(appGroupContainer: URL, clock: any Clock)

    public func loadPlaylists() -> [PlaylistsIndex.Entry]

    public func ingest(items: [NSItemProvider]) async -> IngestSummary

    /// Writes intent.json atomically and returns the URL the host should open.
    public func finalize(
        token: UUID,
        decision: ShareDecision,
    ) throws -> URL

    /// Removes the staged token directory; called on Cancel.
    public func discard(token: UUID)
}

public struct IngestSummary: Sendable {
    public let token: UUID
    public let acceptedFiles: [IncomingShareIntent.File]
    public let unsupportedCount: Int
}

public enum ShareDecision: Sendable {
    case save(PlaylistChoice)
    case saveAndOpen(PlaylistChoice)
}

public enum PlaylistChoice: Sendable {
    case libraryOnly
    case existing(PlaylistID)
    case createNew(name: String)
}
```

The SwiftUI root is `ShareRootView(session:onComplete:)` with `onComplete: (ShareCompletion) -> Void` so `ShareViewController` can react (call `completeRequest`, invoke `openURL`).

### `AppBootstrap` / routing changes

```swift
final class AppBootstrap {
    private(set) var pendingShareToken: UUID?    // new slot
    private(set) var pendingShareOpenAfter: Bool // tied to pendingShareToken

    func acceptIncomingURL(_ url: URL) {
        if url.scheme == "folino", url.host == "import",
           let token = url.shareToken() {
            pendingShareToken = token
            pendingShareOpenAfter = url.shareOpenAfter()
            return
        }
        pendingIncomingURL = url   // existing file:// path unchanged
    }

    func consumePendingShareToken() -> (UUID, Bool)? { ... }
}
```

`AppShellView` adds a `.task(id: bootstrap.pendingShareToken)` modifier that consumes the token, invokes `IncomingShareCoordinator.drain(token:)`, and routes the `DrainResult` through HUD / banner / Reader push.

## Error handling

### Extension

| Failure | Behavior |
|---|---|
| `NSItemProvider.loadFileRepresentation` failure for one item | Skip that item, increment `unsupportedCount`, continue. |
| All items fail to copy | Show inline error view (`No supported scores were shared.`), only `Cancel` enabled. |
| App Group container unavailable (entitlement bug) | Show error view (`Folino sharing isn't configured. Please reinstall the app.`), only `Cancel` enabled. Log via `os_log`. |
| Disk full during file copy | Treated as "all items fail" path above; staged dir is removed. |
| `playlists.json` missing or unreadable | Picker shows `Library only` + `New playlist…` only. Save still works. |
| `intent.json` write fails | Show error toast; user can retry via `Save` again or `Cancel`. Staged files remain until cancel cleans up. |
| `UIApplication.open(_:options:)` returns false / responder chain walk fails | Non-fatal: extension still closes; drain-on-launch picks up the token next time. |

### Main app

| Failure | Behavior |
|---|---|
| `intent.json` missing / corrupt | Delete the token directory, log the error; do not retry. |
| File listed in intent but missing in `files/` | Skip with `SkipReason.unreadable`. |
| `prepareImport` throws | Skip with `SkipReason.parseFailed`. |
| `commitImport` throws | Skip with `SkipReason.persistenceFailed`. |
| `savePlaylist` (new playlist) throws | Abort the token: nothing is imported, the token dir is preserved for the next attempt, and a banner reports `Couldn't create playlist "<name>". Try again later.` |
| `repository.refresh` has not yet succeeded when a token URL arrives | URL is queued in `pendingShareToken`; the drain task waits for `isReady`. |
| Concurrent token drains | Serialized via `MainActor`-isolated `inFlightDrain: Task<Void, Never>?`; second drain await the first. |
| Duplicate detection finds an existing `ScoreItem` | Silent dedupe (see "Dedupe policy"). `SkipReason.duplicate` surfaces it in the banner. |

After drain completes (success or partial failure), the token directory is removed unconditionally except for the new-playlist-creation-failure case noted above.

## Testing

### `ImportExportAppGroup` tests (`Tests/ImportExportAppGroupTests/`)

- `IncomingShareIntent` / `PlaylistsIndex` codable round-trip (`schemaVersion` preserved, `playlistID` vs `newPlaylistName` mutually exclusive).
- `AppGroupPaths.container()` returns nil gracefully when the test process lacks the entitlement (skips dependent tests).

### `ImportExportShareUI` tests (`Tests/ImportExportShareUITests/`)

- `ShareSession.ingest` with fake `NSItemProvider` doubles:
  - Single file → one `File` entry, no `unsupportedCount`.
  - Mixed supported / unsupported → only supported ones in `acceptedFiles`.
  - All failures → empty `acceptedFiles`, full `unsupportedCount`.
- `ShareSession.finalize` writes a parseable `intent.json` at the expected path; subsequent reads decode equal values.
- `ShareSession.discard` removes the entire token directory.
- `ShareRootView` SwiftUI previews:
  - Empty playlists.
  - Three playlists + one selected.
  - `New playlist…` inline-expanded with text entered.
  - Multi-file summary, `Show files` expanded.

### `ImportExport` tests (`Tests/ImportExportTests/`)

- `IncomingShareCoordinator.drain(token:)` with a fake importer + repository:
  - Single file, `Library only`, success → `imported.count == 1`, no playlist mutation.
  - Two files, existing playlist → both `ScoreItemID`s appended to that playlist's `orderedScoreItemIDs`.
  - Two files, new playlist → repository receives one `savePlaylist` before any `commitImport`; both items belong to the new playlist.
  - Duplicate path → `imported` empty, `skipped` carries `duplicate(existingID:)`, token dir is gone after.
  - `prepareImport` throws on second of three files → `imported.count == 2`, `skipped.count == 1`.
  - `drain(token: nil)` with two staged tokens → drained in `createdAt` ascending order.
- `PlaylistsIndexWriter.rewrite` round-trip: write then read returns identical content; concurrent writes (simulated) leave the file readable (atomic rename invariant).
- `AppBootstrap.acceptIncomingURL` routing: `folino://import?token=…` populates `pendingShareToken`; `file://…/foo.mscz` populates `pendingIncomingURL`.

### Manual / integration

- Cold launch via share: kill Folino, share `.mscz` from Files → verify the extension UI renders, `Save & Open` lands in Reader.
- Warm launch via share: foreground Folino, share from Discord → verify same.
- Cancel: open extension, tap `Cancel` → verify `IncomingImports/` is empty afterwards.
- Multi-file: select 3 `.mscz` in Files → share → verify all imported, banner shows the playlist name, last opens in Reader.
- New playlist creation: in extension, tap `+ New playlist…`, type `Smoke test`, save → verify the playlist appears in the Library tab with the shared scores.
- Force-quit during drain: share two files with Save, immediately force-quit while HUD is visible → cold-launch and verify drain-on-launch resumes them.

## Risks / Open questions

- **Apple review around responder-chain `UIApplication.open`**: the technique is widely used (Bear, Things, Readwise, Drafts) and has not historically drawn rejections, but it relies on `UIApplication` being reachable via `responder.next` from inside an extension. If a future iOS makes this unreachable, the drain-on-launch fallback already covers the case — the extension just becomes "silent stage, picks up on next launch", which is degraded but functional.
- **App Group migration of existing users**: this is a new container; there is no data to migrate. The first install of the updated app simply creates it.
- **iCloud sync and the App Group container**: the App Group container is not iCloud-synced and never should be — it is a transient staging area. CloudKit sync continues to operate against the main-app SQLite DB only, untouched by this design.

## Future work

- Approach C (silent dedupe with hash index) if real usage shows users frequently re-share files and want inline feedback.
- Per-file playlist selection if real usage shows users sharing heterogeneous batches.
- Action Extension (separate from Share Extension) for one-tap workflows like "preview without saving".
- Share-out flow (Folino → other apps) for an entire playlist as a batch.
