# Shared SoundFont via App Group (`group.com.KeyNumber.shared`)

Date: 2026-06-26
Status: Approved (brainstorming)

## Goal

Stop Folino and VocalTuner from each downloading and storing their own private copy of the same ~206 MB
`MuseScore_General.sf2` high-quality SoundFont. Move the asset into a **shared App Group container** so whichever app
fetches it first, the other reuses it — saving ~206 MB of duplicated storage and one redundant ~206 MB download per
device. Because the file is now shared, reclaiming it on opt-out is **reference-counted** so one app's opt-out never
strands the other.

This spec covers **soundfont sharing only**. Sharing the user's score files (a `Scores/` subfolder; reconciling
GRDB vs Realm metadata) is explicitly a later, separate spec (see [Out of scope](#out-of-scope)).

## Background — current state

Both apps are built by the same developer, ship under the same Apple Developer Team (`944L8NCGUH`), and pull the
**identical** file from the same URL:

```
https://github.com/jiyimeta/musescore-general-sf2-split/releases/download/unsplit/MuseScore_General.sf2
```

### Folino (already released with the soundfont feature)

- `LiveMuseScoreGeneralProvider` (`Packages/Infrastructure/Sources/Soundfonts/`) owns the opt-in download. It takes its
  destination as an injected `targetDirectory` (constructed in `AppBootstrap.installAudioStack()` with
  `AppPaths.soundfontsDirectory`).
- `AppPaths.soundfontsDirectory` resolves to the app's **private sandbox**: `Library/Application
  Support/Soundfonts/`. The file lands at `Library/Application Support/Soundfonts/MuseScore_General.sf2`
  (`SoundfontPreset.highQuality.fileName`).
- The download is robust: scratch temp → HTTP-status check → atomic `moveItem` into place → `isExcludedFromBackup`.
  `init` derives `downloadState` from a file existence check; `startDownloadIfNeeded()` short-circuits to `.downloaded`
  when the file already exists.
- **Opt-out deletes the file**: `setOptedIn(false)` → `deleteDownloaded()` → `removeItem(targetFileURL)`.
- `GMSoundfontResolver` reads the file via the provider's `museScoreGeneralFileURLSync` (nonisolated, audio-thread
  safe); when absent it falls back to bundled split SF2s.
- `App/Folino.entitlements` already declares an App Group (`group.com.KeyNumber.Folino`, used by the Share Extension)
  plus iCloud/CloudKit. `App/Info.plist` already declares a custom URL scheme **`folino`** (`CFBundleURLTypes`).
- **Existing users already have the 206 MB file in the private sandbox location.** Hard constraint: the change must not
  strand that file or trigger a re-download.

### VocalTuner (soundfont feature NOT yet released)

- `Domain/Sources/Domain/Soundfont/SoundfontPaths.swift` is a single source of truth (`enum SoundfontPaths`) for the
  filename, directory, opt-in key, and validation. The file lands at `Library/Application
  Support/Soundfonts/MuseScore_General_v1.sf2`. The `_v1` suffix is a **deliberate** cache-invalidation token (comment:
  "bump the suffix to invalidate old copies").
- `LiveMuseScoreGeneralProvider` (`Features/.../Helper/`, singleton `.shared`) mirrors Folino's provider but uses a
  **background** `URLSession` (survives app kill), already validates `minimumValidByteSize` (150 MB), atomic-moves, and
  sets `isExcludedFromBackup`. `LiveSoundfontResolver` reads `SoundfontPaths.highQualityFileURL` / `highQualityFileExists`.
- **Opt-out deletes the file** after a 90 s grace window (`scheduleGraceDelete()` → `deleteDownloaded()`), with a
  launch cleanup for a marker that survived a kill.
- Has **no** App Group / iCloud entitlement today (push only) and **no** custom URL scheme. Because the feature is
  unreleased, **no real user has the file yet** → effectively greenfield, no end-user migration.
- Has a macOS target. Folino is iOS-only, so cross-app sharing is **iOS-only**; VocalTuner's macOS app is out of scope.

## Design

### 1. Shared App Group & container layout

A new App Group **`group.com.KeyNumber.shared`** is added to both apps' iOS targets (same team → entitlement +
provisioning addition only).

```
group.com.KeyNumber.shared container/
└── Soundfonts/
    ├── MuseScore_General.sf2          ← the shared 206 MB asset (canonical, unversioned name)
    └── consumers/
        ├── com.KeyNumber.Folino       ← opt-in marker (present ⇔ Folino is opted in)
        └── com.KeyNumber.VocalTuner    ← opt-in marker (present ⇔ VocalTuner is opted in)
```

`Scores/` is reserved for the future score-sharing spec. Rationale for the neutral, broadly-scoped group name
`shared` (chosen over `sheetmusic`/`music`): the group ID roots the container path, so renaming forces another data
migration; a vague-but-stable name avoids that churn. Different data types live in **subfolders of one group**, not
separate groups — a new App Group is warranted only when a *different set of apps* needs to share something.

### 2. Canonical asset & naming

- Canonical filename is **`MuseScore_General.sf2`** (unversioned) — identical to Folino's current name, so Folino's
  migration is a pure move with no rename. VocalTuner changes its `SoundfontPaths.highQualityFileName` from
  `MuseScore_General_v1.sf2` to this name and drops the `_v1` versioning comment. Per-app filename versioning is
  meaningless for a shared asset; a future SF2 swap is invalidated by **both apps coordinating a rename** of the shared
  canonical name together (the cross-app analogue of the old suffix bump). Both apps fetch the same unsplit release
  today, so the bytes are identical.
- The group ID string and the `Soundfonts/…` relative paths are duplicated as small constants in each repo (the two
  apps are different stacks — Folino SPM/GRDB, VocalTuner CocoaPods/Realm — so no shared Swift module is introduced).
  Each repo's constant carries a comment pointing at the other.
- **Validity check** used throughout: a soundfont at a path is "valid" iff it exists **and** its file size is ≥ 150 MB
  (`SoundfontPreset.highQuality.expectedSize` is 206 MB; VocalTuner's `SoundfontPaths.minimumValidByteSize` is 150 MB).
  This rejects truncated / partial / error-body files so nothing trusts or moves a corrupt copy.

### 3. Folino — directory resolution (`AppPaths`)

```swift
static var sharedSoundfontsDirectory: URL? {           // nil when the container is unavailable
    FileManager.default
        .containerURL(forSecurityApplicationGroupIdentifier: "group.com.KeyNumber.shared")?
        .appending(path: "Soundfonts")
}
static var legacySoundfontsDirectory: URL {            // today's `soundfontsDirectory` body, renamed
    guard let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
        fatalError("Application Support directory unavailable — sandbox is broken")
    }
    return url.appending(path: "Soundfonts")
}
static var soundfontsDirectory: URL {                  // shared when available, else legacy
    sharedSoundfontsDirectory ?? legacySoundfontsDirectory
}
```

`LiveMuseScoreGeneralProvider` already takes its directory by injection, so pointing `installAudioStack()` at the
(now shared-aware) `AppPaths.soundfontsDirectory` is the only wiring change for playback. The fallback is at the
path-resolution level, keeping the provider single-directory and simple.

### 4. Folino — idempotent reconcile migration

Runs in `AppBootstrap.start()` **after `prepareDirectories()` / `cleanupLegacySoundfontCacheIfNeeded()` and before
`installAudioStack()`**. Existence-driven (no "did I migrate" boolean) so it self-heals and is safe every launch:

```
reconcileSoundfontToSharedContainerIfNeeded():
    guard let shared = AppPaths.sharedSoundfontsDirectory else { return }   // nil container → keep legacy, no-op
    create `shared`, set isExcludedFromBackup on it
    sharedFile = shared / "MuseScore_General.sf2"
    legacyFile = AppPaths.legacySoundfontsDirectory / "MuseScore_General.sf2"

    // ① Populate shared only when shared is empty/invalid and legacy is a valid copy
    if !isValid(sharedFile) && isValid(legacyFile):
        try? moveItem(legacyFile → sharedFile)      // intra-volume rename: instant, atomic, no 206 MB copy
        reapply isExcludedFromBackup on sharedFile

    // ② Remove the redundant legacy copy (covers "VocalTuner downloaded first")
    if isValid(sharedFile) && fileExists(legacyFile):
        try? removeItem(legacyFile)
```

The move is an intra-volume rename (container and sandbox share the data volume on iOS) — instant, atomic, no
206 MB copy; run it off the main thread regardless. Step ② is the duplicate fix: if VocalTuner already populated
`shared`, ① is skipped and ② deletes the redundant legacy copy. Legacy is deleted only **after** `shared` is confirmed
valid. Every call is `try?`; any failure leaves the legacy file in place and the resolver still finds a working copy.

Implemented as a pure, testable type `SoundfontContainerMigration` in the Soundfonts Infrastructure module (takes
`fileName`, `sharedDirectory`, `legacyDirectory`, `minimumValidByteSize`, `fileManager`); `AppBootstrap` resolves the
real directories via `AppPaths` and calls it.

### 5. Reference-counted reclaim & cross-app opt-out (the shared-file core)

Opt-in stays a **per-app** UserDefaults preference; only the *file* is shared. To stop one app's opt-out from deleting a
file the other app is using, deletion is gated by a reference count built from two signals:

- **Opt-in markers** (publishes each app's opt-in into the shared container): an app owns one file
  `Soundfonts/consumers/<its-bundle-id>`. **Presence ⇔ that app is opted in.** Content is a small JSON
  `{ "displayName": "<the app's user-facing brand>" }` so a reader can name the using app without hardcoding it
  (Folino publishes the lowercase brand `folino`; VocalTuner publishes its own brand).
- **Liveness via `canOpenURL`** (distinguishes "installed" from "deleted", since iOS has no uninstall hook to remove a
  deleted app's marker): each app holds a static table of its sibling(s) → `(bundleId, urlScheme)` and treats a foreign
  marker as a live "wanter" only if `UIApplication.canOpenURL("<scheme>://")` is true. Folino's sibling is
  `(com.KeyNumber.VocalTuner, "vocaltuner")`; VocalTuner's is `(com.KeyNumber.Folino, "folino")`.

Two operations, mirrored in both apps:

```
syncOwnMarker():                       // on launch, and whenever this app's opt-in changes
    if isOptedIn: write consumers/<ownBundleId> = {displayName: <ownBrand>}
    else:         remove consumers/<ownBundleId>

reclaimIfUnused():                      // on launch, and immediately after this app opts out
    guard isValid(sharedFile) else { return }
    foreignWanters = consumers markers (excluding own) whose app is INSTALLED per canOpenURL(siblingScheme)
    if !isOptedIn(self) && foreignWanters.isEmpty:
        delete sharedFile               // last interested party left → reclaim now
    prune markers whose app is neither self nor installed   // housekeeping for deleted apps
```

This **replaces** each app's current unconditional `deleteDownloaded()` on opt-out: opt-out now calls
`syncOwnMarker()` then `reclaimIfUnused()`. (VocalTuner's grace-delete timer is repurposed to run `reclaimIfUnused()`
after the grace window instead of an unconditional delete.)

**Deletion timing** (the storage-reclaim goal): the file is deleted the instant any app's `reclaimIfUnused()` finds
"self opted out AND no *installed* sibling is opted in". That runs on opt-out and on launch/foreground. Outcomes:

1. You opt out and no installed sibling wants it → **deleted immediately**.
2. You opt out while a sibling is installed & opted in → kept (genuinely in use); freed the instant the *last*
   interested app opts out.
3. A sibling was opted in then **deleted** → `canOpenURL` is false at once, so the next opt-out / next launch deletes —
   **no lingering window**.
4. All sibling apps uninstalled → iOS auto-reclaims the whole container.

Inherent caveat (surfaced in UI, see §6): opting out in only one of two opted-in apps does **not** free the 206 MB,
because the other app is using it; it frees when the second app opts out.

On upgrade, existing opted-in Folino users get their marker created by the first `syncOwnMarker()` on launch (idempotent,
reconciles markers to actual opt-in state every launch).

### 6. Folino Settings — "in use by sibling" message

When Folino is **opted out** but the shared file still exists **and** `reclaimIfUnused()`'s `foreignWanters` is
non-empty (a sibling is installed and opted in), Folino's Settings → Soundfonts area shows an informational note naming
the using app via the marker's `displayName`, e.g. *"The high-quality soundfont is kept because <VocalTuner> is using
it."* (**Exact copy TBD** — must obey the lowercase-brand rule for `folino`, use the sibling's published `displayName`,
and avoid internal feature names.) The note explains why opt-out did not free storage. The data is already computed for
the reference count, so this is a presentation-only addition. A symmetric note in VocalTuner ("kept because folino is
using it") is an **optional** parallel add (see Out of scope).

### 7. Entitlements & Info.plist

- **Folino**: add `group.com.KeyNumber.shared` to `App/Folino.entitlements` (keep `group.com.KeyNumber.Folino`); add
  `LSApplicationQueriesSchemes = ["vocaltuner"]` to `App/Info.plist` (the `folino` scheme already exists). The Share
  Extension is unchanged (does not touch soundfonts).
- **VocalTuner**: add the App Groups capability + `group.com.KeyNumber.shared` to `VocalTuner.entitlements` (iOS
  target); add a `CFBundleURLTypes` entry declaring scheme **`vocaltuner`** (declaration only — no incoming-URL
  handling needed for `canOpenURL` detection) and `LSApplicationQueriesSchemes = ["folino"]` to its iOS `Info.plist`.
  macOS target unchanged / out of scope.
- Capabilities must be enabled on each App ID in the Developer portal / via automatic signing, and provisioning
  regenerated.

### 8. VocalTuner — adoption (greenfield)

- Change `SoundfontPaths.soundfontsDirectory(_:)` to resolve the shared container's `Soundfonts/` subfolder, with the
  same `nil`-container degradation to its current private Application Support path. Change `highQualityFileName` to the
  canonical `MuseScore_General.sf2`. Because `SoundfontPaths` is the single source of truth, the provider and
  `LiveSoundfontResolver` follow automatically; the existing init/`startDownloadIfNeeded` existence checks already make
  it **reuse** a copy Folino fetched.
- Implement `syncOwnMarker()` / `reclaimIfUnused()` (§5) in VocalTuner's `LiveMuseScoreGeneralProvider`, replacing the
  unconditional grace-delete with a grace-delayed `reclaimIfUnused()`.
- No end-user migration (feature unreleased). Optionally, for dev/TestFlight hygiene, delete a leftover private
  `MuseScore_General_v1.sf2` once a valid shared copy exists.

### 9. Download coordination, atomicity, awareness, degradation

- **Atomicity**: both providers already download to their own UUID scratch temp, validate size, then `removeItem` +
  `moveItem` into the canonical path — a partial/interrupted download never appears at the canonical path. Concurrent
  downloads resolve as "last complete writer wins" (no corruption). The tiny remove→move window is accepted; an atomic
  `replaceItemAt` upgrade is **deferred** (the asset is write-once and re-downloadable, concurrent opt-in in two apps
  is rare). See Open questions #3.
- **Cross-app download-state awareness**: each app re-derives "downloaded?" from a fresh existence+size check on
  **foreground** (App Groups give no change notification), so a file the sibling downloaded is reflected without a
  re-fetch. Folino adds a `refreshDownloadStateFromDisk()` on the provider, called on scene-phase `.active`.
- **Backup exclusion**: re-apply `isExcludedFromBackup` after every move/download into the shared location (App Group
  containers are backed up by default).
- **`nil`-container degradation**: if `containerURL(...)` is nil (entitlement/provisioning gap), the path resolvers fall
  back to the private location, the reconcile no-ops, markers/reclaim operate on the private dir, and playback keeps
  working. A provisioning mistake degrades to today's behavior; it never crashes.

## Invariants

- **No duplicate**: after Folino's reconcile, if a valid shared copy exists → exactly one copy on device (shared);
  the legacy private copy is deleted, regardless of download order. If no valid shared copy can be produced, the legacy
  copy (if any) remains and is used; no shared copy exists in that state, so there is no duplicate.
- **Reference-count safety**: the shared file is deleted only when the deleting app is opted out **and** no installed
  sibling is opted in. A deleted sibling's stale marker cannot pin the file (filtered by `canOpenURL`); the OS reclaims
  the whole container when the last member is uninstalled.

## Rollout sequencing

1. **Folino update ships first** with the full machinery (migration, shared path, markers, `reclaimIfUnused`,
   `canOpenURL`, the §6 note). Until VocalTuner ships, `canOpenURL("vocaltuner://")` is false, so Folino is the sole
   consumer and opt-out deletes immediately — **identical to today's behavior**. Existing users' private file migrates
   to the shared container on first launch.
2. **VocalTuner soundfont feature ships** with the mirrored machinery. From then on the reference count spans both apps,
   and either app reuses a copy the other fetched.

Order does not affect correctness (everything is existence/marker-driven); Folino-first maximizes immediate reuse for
its large install base. Folino's legacy-path fallback and reconcile can be retired in a later version once all users
have migrated (optional, low priority).

## Tests

**Folino** (Swift Testing, `InfrastructureTests/Soundfonts/`, injected `FileManager` + temp dirs from
`TestSupport/TempDirectory.swift`):

- `SoundfontContainerMigration`: Folino-first (move), VocalTuner-first (legacy deleted), fresh install (no-op), neither
  present (no-op), corrupt/partial legacy < 150 MB (not moved), `nil`/equal dirs (no-op), idempotency (second run
  no-op).
- Reference count: `syncOwnMarker` writes on opt-in / removes on opt-out; `reclaimIfUnused` deletes when self opted out
  & no foreign wanter; keeps when a foreign wanter is "installed"; deletes when the only foreign marker's app is "not
  installed" (stale); prunes stale markers. `canOpenURL` is injected behind a tiny `InstalledAppChecking` protocol so
  tests control installed-ness without UIKit.
- "In use" message logic: returns the sibling `displayName` when self opted out + file present + installed foreign
  wanter; nil otherwise.

**VocalTuner** (its test target): `SoundfontPaths.soundfontsDirectory` resolves the shared container and degrades on
nil; a present valid shared file skips the download; the mirrored `reclaimIfUnused` behaves identically.

**Device/simulator smoke** (real container needs the entitlement): pre-seed the legacy path (simulate an existing
Folino user), launch the updated build, verify the file moved to the shared container, playback works, no re-download;
then confirm VocalTuner sees the shared file, and that opt-out reference-counting frees space only when no sibling is
opted in.

## Out of scope

- **Score / sheet-music file sharing** (`Scores/`; reconciling GRDB vs Realm metadata) — the planned next spec; the
  container layout reserves the subfolder.
- The **symmetric** "in use by folino" note inside VocalTuner Settings — optional parallel of §6; include only if cheap.
- VocalTuner's **macOS** target (different platform sandbox; cannot share with iOS-only Folino).
- Cross-device sync (iCloud/CloudKit). On-device App Group sharing only.
- The atomic-`replaceItemAt` install hardening (deferred; remove+move retained).
- Changing the per-app opt-in *preference model* itself (still UserDefaults; only the file + reclaim is shared).

## Open questions / resolutions

1. Confirm `SoundfontPreset.highQuality.fileName == "MuseScore_General.sf2"` (verified) stays Folino's single source of
   truth for the name; VocalTuner adopts the same literal.
2. **RESOLVED**: VocalTuner's `_v1` suffix is a deliberate per-app invalidation token, but the shared file standardizes
   on unversioned `MuseScore_General.sf2`; future invalidation is a coordinated cross-app rename.
3. **RESOLVED**: defer the atomic-`replaceItemAt` hardening; keep the existing remove+move (benign, rare race).
4. **RESOLVED**: reference-counted reclaim uses opt-in markers + `canOpenURL` liveness (no heartbeat window); deletion is
   immediate when the last interested app leaves, caught on opt-out or next launch.
5. Finalize the §6 "in use" copy (and decide whether to add the symmetric VocalTuner note) during implementation.

## Cross-repo note

This work spans **two repositories**: Folino (`/Users/kiichi/Developer/Personal/ios-apps/Folino-iOS`) and VocalTuner
(`/Users/kiichi/Developer/Personal/ios-apps/VocalTuner`). The implementation plan labels each task by repo and respects
each repo's conventions (XcodeGen `project.yml`, entitlements, and `Info.plist` on both sides; Folino SPM/GRDB vs
VocalTuner CocoaPods/Realm; VocalTuner's background `URLSession` provider vs Folino's foreground one). The
reference-count/marker contract (file layout, marker filename = bundle id, `{displayName}` JSON, `canOpenURL` liveness,
the reclaim algorithm) is defined once here and implemented identically in both. Entitlement/provisioning/capability
changes are "stop and confirm" under Folino's autonomous ground rules — planned here, surfaced before any portal/signing
change during implementation.
