# Shared SoundFont via App Group (`group.com.KeyNumber.shared`)

Date: 2026-06-26
Status: Approved (brainstorming)

## Goal

Stop Folino and VocalTuner from each downloading and storing their own private copy of the same ~206 MB
`MuseScore_General.sf2` high-quality SoundFont. Move the asset into a **shared App Group container** so whichever app
fetches it first, the other reuses it — saving ~206 MB of duplicated storage and one redundant ~206 MB download per
device.

This spec covers **soundfont sharing only**. Sharing the user's score files (`Scores/` subfolder, reconciling
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
- The download is already robust: it writes to a scratch temp, validates the HTTP status (rejects non-2xx), then
  atomically `moveItem`s into place and sets `isExcludedFromBackup = true`. `init` derives `downloadState` from a file
  existence check, and `startDownloadIfNeeded()` short-circuits to `.downloaded` when the file already exists.
- `GMSoundfontResolver` reads the file via the provider's `museScoreGeneralFileURLSync` (nonisolated, audio-thread
  safe); when absent it falls back to bundled split SF2s.
- `App/Folino.entitlements` already declares an App Group (`group.com.KeyNumber.Folino`, used by the Share Extension)
  plus iCloud/CloudKit.
- **Existing users already have the 206 MB file in the private sandbox location.** This is the hard constraint: the
  change must not strand that file or trigger a re-download.

### VocalTuner (soundfont feature NOT yet released)

- Stores the same asset at `Library/Application Support/Soundfonts/MuseScore_General_v1.sf2` via
  `SoundfontPaths.soundfontsDirectory(_:)` + `LiveSoundfontResolver` (`Live/Sources/LiveSheetMusic/`), opt-in via the
  `soundfont.museScoreGeneral.optedIn` UserDefault.
- Has **no** App Group / iCloud entitlement today (push only). Because the feature is unreleased, **no real user has the
  file yet** → VocalTuner is effectively greenfield and needs no migration for end users.
- Has a macOS target. Folino is iOS-only, so cross-app sharing is **iOS-only**; VocalTuner's macOS app is out of scope.

## Design

### 1. Shared App Group & container layout

A new App Group **`group.com.KeyNumber.shared`** is added to both apps' iOS targets. Both apps already share the team,
so this is purely an entitlement + provisioning addition.

Container layout (room reserved for the future score-sharing spec):

```
group.com.KeyNumber.shared container/
└── Soundfonts/
    └── MuseScore_General.sf2        ← the shared 206 MB asset (canonical name)
```

Rationale for a neutral, broadly-scoped group name (`shared` rather than `sheetmusic`/`music`): the group ID is the
root of the container path, so renaming it later forces another data migration. A vague-but-stable name avoids that
churn. Different data types live in **subfolders of one group**, not separate groups — a new App Group is warranted only
when a *different set of apps* needs to share something (membership change), since each new group costs an App ID
capability edit + provisioning regen + re-release of every participating app.

### 2. Canonical asset & naming

- Canonical filename in the shared container is **`MuseScore_General.sf2`** — identical to Folino's current name, so
  Folino's migration is a pure move with no rename. VocalTuner changes its constant from `MuseScore_General_v1.sf2` to
  this name. (Implementation note: confirm VocalTuner's `_v1` is just a local label, not a live versioning scheme; both
  apps fetch the same unsplit release, so the bytes are identical.)
- The group ID string and the `Soundfonts/MuseScore_General.sf2` relative path are duplicated as small constants in each
  repo (the two apps are different stacks — Folino SPM/GRDB, VocalTuner CocoaPods/Realm — so no shared Swift module is
  introduced for a single path string). Each repo's constant carries a comment pointing at the other.
- **Validity check** used throughout: a soundfont at a path is "valid" iff it exists **and** its file size is at least a
  conservative threshold (≥ 150 MB; `SoundfontPreset.highQuality.expectedSize` is 206 MB). This rejects truncated /
  partial / error-body files so the reconcile never moves or trusts a corrupt copy.

### 3. Folino — directory resolution (`AppPaths`)

`AppPaths` gains a shared-container resolver and keeps the legacy path as a named fallback:

```swift
// Shared App Group container's Soundfonts dir. nil when the container is unavailable
// (e.g. an entitlement/provisioning gap) — callers must degrade, never crash.
static var sharedSoundfontsDirectory: URL? {
    FileManager.default
        .containerURL(forSecurityApplicationGroupIdentifier: "group.com.KeyNumber.shared")?
        .appending(path: "Soundfonts")
}

// The pre-sharing private location (today's `soundfontsDirectory` body, renamed).
// Migration source + degraded fallback.
static var legacySoundfontsDirectory: URL {
    guard let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
        fatalError("Application Support directory unavailable — sandbox is broken")
    }
    return url.appending(path: "Soundfonts")
}

// Primary location used by the provider/resolver. Shared when available, else legacy.
static var soundfontsDirectory: URL {
    sharedSoundfontsDirectory ?? legacySoundfontsDirectory
}
```

The key property: **`LiveMuseScoreGeneralProvider` already takes its directory by injection**, so pointing
`installAudioStack()` at the (now shared-aware) `AppPaths.soundfontsDirectory` is the only wiring change. The provider,
resolver, download, and state machine are otherwise untouched. The fallback is at the *path-resolution* level, not
inside the provider, which keeps the provider single-directory and simple.

### 4. Folino — idempotent reconcile migration

A new bootstrap step runs **after `prepareDirectories()` and before `installAudioStack()`** (so the provider is
constructed already pointing at the reconciled directory). It is existence-driven (no "did I migrate" boolean) so it
self-heals and is safe to run every launch:

```
reconcileSoundfontToSharedContainerIfNeeded():
    guard let shared = AppPaths.sharedSoundfontsDirectory else { return }   // nil container → keep legacy, no-op
    create `shared` dir (withIntermediateDirectories) and set isExcludedFromBackup on it
    sharedFile = shared / "MuseScore_General.sf2"
    legacyFile = AppPaths.legacySoundfontsDirectory / "MuseScore_General.sf2"

    // ① Populate shared (only when shared is empty/invalid and legacy is a valid copy)
    if !isValid(sharedFile) && isValid(legacyFile):
        try? FileManager.moveItem(legacyFile → sharedFile)   // intra-volume rename: instant, atomic, no 206 MB copy
        reapply isExcludedFromBackup on sharedFile

    // ② Remove the redundant legacy copy (covers the "VocalTuner downloaded first" case)
    if isValid(sharedFile) && FileManager.fileExists(legacyFile):
        try? FileManager.removeItem(legacyFile)
```

- The move is a rename within the same data volume (the App Group container and the app sandbox live on the same
  volume on iOS), so it is an instant metadata operation, not a 206 MB copy, and is atomic (no half-moved state). Run it
  off the main thread regardless to avoid any chance of UI jank.
- Step ② is the fix for the order-dependent duplicate: if VocalTuner already populated `shared`, step ① is skipped, and
  step ② deletes the now-redundant legacy copy. Legacy is only ever deleted **after** `shared` is confirmed valid.
- Every filesystem call is `try?` — any failure leaves the legacy file in place, and the resolver still finds a working
  copy (see §6 nil-container / failure degradation). The migration retries next launch.

### 5. Folino — entitlements

Add `group.com.KeyNumber.shared` to `App/Folino.entitlements`, **keeping** the existing `group.com.KeyNumber.Folino`
(an app may belong to multiple groups). The Share Extension does not touch soundfonts, so its entitlement is unchanged.
Capability must be enabled on the App ID in the Developer portal / via automatic signing, and provisioning regenerated.

### 6. Folino — backup exclusion & nil-container degradation

- After every write/move into the shared location (`reconcile` step ①, and the existing download install path), set
  `isExcludedFromBackup = true`. App Group containers are backed up by default, so the 206 MB re-downloadable asset must
  be excluded just as it is in the private location today.
- If `containerURL(...)` returns `nil` (entitlement/provisioning gap in some build), `AppPaths.soundfontsDirectory`
  resolves to the legacy private path, the reconcile no-ops, and the existing legacy file (or a fresh download into the
  private path) keeps playback working. **A provisioning mistake degrades to today's behavior; it never crashes or
  bricks audio.**

### 7. VocalTuner — adoption (greenfield)

- Add the App Groups capability + `group.com.KeyNumber.shared` to VocalTuner's **iOS** target entitlements (it has none
  today). macOS target unchanged / out of scope.
- Change `SoundfontPaths.soundfontsDirectory(_:)` to resolve the shared container's `Soundfonts/` subfolder, with the
  same `nil`-container degradation to its current private Application Support path.
- Change the filename constant to the canonical `MuseScore_General.sf2`.
- Before downloading, check the shared path for a *valid* file (≥ 150 MB) and skip the download if present — this is how
  VocalTuner reuses a copy Folino already fetched. VocalTuner's existing download flow keeps its atomic temp→install +
  backup-exclusion behavior, now targeting the shared path.
- No end-user migration is required (feature unreleased). Optionally, for symmetry/hygiene on dev & TestFlight devices,
  VocalTuner deletes its own legacy private `MuseScore_General_v1.sf2` once a valid shared copy exists (same condition
  as Folino's step ②).

### 8. Download coordination & atomicity

Both apps can independently trigger a download; neither "owns" the file. Coordination relies on atomic writes rather
than cross-process locks:

- Each app downloads to its **own** scratch temp (UUID in `temporaryDirectory`) and only then installs into the shared
  canonical path. A partial/interrupted download never appears at the canonical path.
- Concurrent downloads (rare — user-initiated opt-in in two apps at once) resolve as "last writer wins"; both wrote
  complete, byte-identical files, so there is no corruption.
- **Hardening (recommended):** change the install step from `removeItem` + `moveItem` to an atomic
  `FileManager.replaceItemAt(...)` (or wrap the install in `NSFileCoordinator`), eliminating the tiny remove→move
  window during which a concurrent reader in the other app could observe a missing file. Heavier cross-process file
  coordination is deliberately *not* added — the asset is write-once and re-downloadable, so the cost isn't justified.

### 9. Cross-app download-state awareness

App Groups provide no cross-process change notification, so each app re-derives "is it downloaded?" from a fresh
existence+size check of the shared path:

- Folino's `LiveMuseScoreGeneralProvider` already checks the file at `init` and in `startDownloadIfNeeded()`. Add a
  re-check on app **foreground** so that if VocalTuner downloaded the file while Folino was backgrounded, Folino's
  Settings reflects "downloaded" without re-fetching. (A file watcher / `NSFilePresenter` for live updates is YAGNI.)
- VocalTuner performs the equivalent existence check before downloading and when its soundfont settings appear.

## Invariants (the no-duplicate guarantee)

After Folino's reconcile runs:

- **If a valid shared copy exists → exactly one copy on device, in the shared container; the legacy private copy is
  deleted** — regardless of which app downloaded first.
- **If no valid shared copy can be produced** (nothing to migrate, or the container is unavailable, or a move failed)
  → the legacy private copy (if any) remains and is used; because no shared copy exists in that state, there is no
  duplicate. The reconcile retries on the next launch.

There is no reachable state in which both a shared copy and a legacy copy persist.

## Rollout sequencing

1. **Folino update ships first.** Existing Folino users' private soundfont migrates into the shared container on first
   launch; new/changed wiring points playback at the shared location. This pre-populates the shared file for the large
   existing Folino install base.
2. **VocalTuner soundfont feature ships** with the shared group + shared-path resolver. On devices that already have
   Folino's migrated file, VocalTuner reuses it (no 206 MB download). On VocalTuner-only devices, it downloads into the
   shared container; a later Folino install/update reuses it.

Because every path is existence-driven, the order does not affect correctness — shipping Folino first only maximizes
immediate reuse. Folino's legacy-path fallback in `AppPaths.soundfontsDirectory` and the reconcile can be retired in a
later Folino version once telemetry/confidence says all users have migrated (optional cleanup, low priority).

## Tests

**Folino** — reconcile logic unit-tested with an injected `FileManager` / temp directories (no real container needed),
Swift Testing (`@Suite`/`@Test`/`#expect`):

- Folino-first: shared invalid + legacy valid → file ends up in shared, legacy gone (move path).
- VocalTuner-first: shared valid + legacy valid → legacy deleted, shared untouched (step ②).
- Fresh install: shared invalid + no legacy → no-op, no crash.
- Neither present: no-op; subsequent download targets shared.
- Corrupt/partial legacy (< 150 MB) → not moved, not counted valid; left for re-download.
- `nil` container → reconcile no-ops; `soundfontsDirectory` resolves to legacy.
- Idempotency: running reconcile twice is a no-op the second time.

**VocalTuner** — unit tests that the resolver targets the shared path and that a present valid shared file skips the
download.

**Device/simulator smoke** (real container needs the entitlement, so this can't be a pure unit test): simulate an
existing Folino user by pre-seeding the legacy path, launch the updated build, verify the file moved to the shared
container, playback works, and no re-download occurs; then confirm VocalTuner sees the shared file.

## Out of scope

- **Score / sheet-music file sharing** (`Scores/` subfolder; reconciling Folino's GRDB library and annotations against
  VocalTuner's Realm `RealmScore`/`RealmSong`; import/dedup semantics). This is the planned next spec; the container
  layout reserves the subfolder for it.
- Sharing the small **bundled** fallback SoundFonts (each app bundles its own; in-bundle, nothing to share).
- VocalTuner's **macOS** target (different platform sandbox; cannot share with iOS-only Folino).
- Cross-device sync (iCloud/CloudKit). This is on-device App Group sharing only.
- Any change to the opt-in *preference* model — opt-in stays per-app UserDefaults; only the *file* is shared.

## Open questions / implementation confirmations

1. Confirm `SoundfontPreset.highQuality.fileName == "MuseScore_General.sf2"` (verified at spec time) stays the single
   source of truth for Folino's name; VocalTuner adopts the same literal.
2. Confirm VocalTuner's `_v1` suffix is not a live versioning token before standardizing on the unversioned name.
3. Decide whether to adopt the §8 atomic-`replaceItemAt` hardening now or defer (recommended: adopt now, since the file
   moves into a multi-reader shared container).

## Cross-repo note

This work spans **two repositories**: Folino (`/Users/kiichi/Developer/Personal/ios-apps/Folino-iOS`) and VocalTuner
(`/Users/kiichi/Developer/Personal/ios-apps/VocalTuner`). The implementation plan(s) must label each task by repo and
respect each repo's own conventions (XcodeGen `project.yml` + entitlements on both sides; Folino's SPM/GRDB stack vs
VocalTuner's CocoaPods/Realm stack). Entitlement/provisioning changes and adding a capability are "stop and confirm"
items under Folino's autonomous ground rules — they are handled here at the planning stage and during implementation
will be surfaced before any portal/signing change.
