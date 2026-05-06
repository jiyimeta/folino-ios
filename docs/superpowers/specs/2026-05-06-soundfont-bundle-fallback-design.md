# SoundFont Bundle Fallback (split-SF2 first, drum/flute bundled)

Date: 2026-05-06
Status: Approved (brainstorming)

## Goal

Stop shipping the ~206 MB `MuseScore_General.sf2` as the bundled fallback. Instead, source every patch on demand from `jiyimeta/musescore-general-sf2-split` (already wired up via `MuseScoreSF2Resolver`), and bundle only two split SF2 files — Flute (`000_073.sf2`, ~624 KB) and Standard Drum Kit (`128_000.sf2`, ~6.15 MB) — as the offline / load-cancelled fallback.

## Background

Today the app uses two resolvers stacked at `App/AppBootstrap.swift:50–56`:

- **`MuseScoreSF2Resolver`** (Soundfonts module) — async `Domain.SoundfontResolver`. Walks the score's `(channel.bank, channel.program)` pairs, downloads each `BBB_PPP.sf2` from the GitHub release, caches under `AppPaths.soundfontCacheDirectory`. Called via `LivePlaybackController.prefetchSoundfonts(score:resolver:)` before `engine.prepare(score:)`.
- **`BundleSoundfontResolver`** (Audio module) — synchronous `SheetMusicAudio.SoundfontResolver`. Returns `nil` for every per-program lookup and only exposes `defaultGMSoundfontURL` pointing at the manually-dropped `App/Resources/Sounds/MuseScore_General.sf2`. The engine then falls back to that single file for every voice.

The 206 MB GM file is gitignored and the developer must copy it after `git clone` (see `CLAUDE.md` "First-Time Setup"). On end-user devices it ships baked into the app bundle, dominating the app's footprint.

### The drum vs pitched collision

`SheetMusicAudio.SoundfontResolver.soundfontURL(forBank:program:)` only sees `(bank, program)`. For MSCX drumset staves the engine passes `(channel.bank, channel.program) = (0, 0)`, then loads with `bankMSB = kAUSampler_DefaultPercussionBankMSB`. For a pitched piano staff the same `(0, 0)` is passed but loaded with `bankMSB = 0` (melodic). The resolver cannot distinguish them. Today this works only because the GM bundle contains both melodic and percussion banks in one file. With per-patch split SF2s this collision is fatal: drum lookups would receive `000_000.sf2` (Acoustic Grand Piano) and silently fail to load under the percussion bankMSB. The existing comment in `BundleSoundfontResolver.swift:12–21` documents exactly this trap.

## Design

### 1. `swift-sheet-music` protocol change

`Sources/SheetMusicAudio/SoundfontResolver.swift` gains an `isDrums: Bool` parameter:

```swift
public protocol SoundfontResolver: Sendable {
    func soundfontURL(forBank bank: UInt8, program: UInt8, isDrums: Bool) -> URL?
    var defaultGMSoundfontURL: URL? { get }
}
```

`PlaybackEngine` passes `params.isDrums` (already known at the call site — used to pick `bankMSB`) into both resolver call sites. This is a breaking change to the package, justified because Folino is the only consumer and the package is owned by the same author.

The `defaultGMSoundfontURL` getter is retained for now but Folino's resolver will return `nil` (no GM file shipped). Voices whose split file is unavailable AND not covered by the bundled fallbacks play silent.

### 2. Bundled fallback SF2 files

Two files committed to git under `App/Resources/Soundfonts/`:

| File | Source | Size | Role |
| --- | --- | --- | --- |
| `000_073.sf2` | jiyimeta/musescore-general-sf2-split release 1.0.0 | ~624 KB | pitched fallback (GM Flute) |
| `128_000.sf2` | jiyimeta/musescore-general-sf2-split release 1.0.0 | ~6.15 MB | drum fallback (Standard Drum Kit) |

These are **committed to the repo** (~6.8 MB total), replacing the manual-drop-in step for `MuseScore_General.sf2`. The CLAUDE.md "First-Time Setup" block loses the SoundFont copy step; xcodegen + open-and-run is enough.

`project.yml` resource group `App/Resources/Sounds` (folder reference, `buildPhase: resources`) is renamed / updated to `App/Resources/Soundfonts` so the bundled files land under `Soundfonts/<name>.sf2` inside `Bundle.main`.

### 3. Resolver consolidation

`BundleSoundfontResolver` is **deleted**. `MuseScoreSF2Resolver` (in the Soundfonts module) becomes the single resolver and conforms to **both** `Domain.SoundfontResolver` and `SheetMusicAudio.SoundfontResolver`.

Lookup order:

**Synchronous path** — `soundfontURL(forBank:program:isDrums:)`:
1. Compute file name: `isDrums ? "128_<PPP>.sf2" : "<BBB>_<PPP>.sf2"` (zero-padded decimals; `BBB` = `bank` arg).
2. If exists in `cacheDirectory` → return that URL.
3. If exists in `Bundle.main` under `Soundfonts/<name>` → return that URL.
4. Else if `isDrums` → return bundled `Soundfonts/128_000.sf2` (drum fallback).
5. Else → return bundled `Soundfonts/000_073.sf2` (flute fallback).
6. If even those bundles are missing (shouldn't happen in shipped builds) → `nil`.

`defaultGMSoundfontURL` returns `nil`.

**Asynchronous path** — `resolveSoundfont(bank:program:isDrums:)`:
1. cache hit → return.
2. bundle hit → return (no copy; bundle URL is fine).
3. download from `<baseURL>/<name>` → write to cache atomically → return.
4. download fails → throw `DomainError.soundfontDownloadFailed(...)`.

The `Domain.SoundfontResolver` protocol gains `isDrums: Bool` on `resolveSoundfont` and `deletePatch`. `SoundfontPatchKey` gains `isDrums: Bool` so `cachedPatches()` and the Settings UI can disambiguate. Migration: existing call sites pass `isDrums: false` (none are drum-aware today).

### 4. Score channel rewrite for fallback hits

`LivePlaybackController.load(score: Score, preferences:)`:

1. Run `prefetchSoundfonts(...)` as today (parallel `try?` downloads).
2. After prefetch, walk every staff. For each, ask the resolver synchronously: is `(bank, program, isDrums)` resolvable from cache or bundle (without falling through to the flute/drum default)?
3. For every staff that misses the precise file:
   - pitched → rewrite that staff's channel to `(bank: 0, program: 73)` (Flute bundle).
   - drum → rewrite to `(bank: 0, program: 0)` (Drum bundle; standard kit, matching the file's internal preset of `bankMSB=0x78, bankLSB=0, program=0`).
4. Pass the rewritten Score to `engine.prepare(score:)`. The persisted Score in `loadedScore` should also be the rewritten copy so `play(in:)` and seek calls remain consistent with the engine.

Add a precise-vs-fallback distinction to the resolver: a private helper like `precisePath(forBank:program:isDrums:) -> URL?` that returns nil instead of falling through, used by the controller's rewrite step.

### 5. AppBootstrap wiring

```swift
let resolver = MuseScoreSF2Resolver(cacheDirectory: AppPaths.soundfontCacheDirectory)
playbackController = LivePlaybackController(
    soundfontResolver: resolver,
    domainResolver: resolver  // same instance, both protocols
)
```

The two-resolver argument shape on `LivePlaybackController` stays — it's still useful for tests with separate fakes — but the App passes one instance for both.

### 6. Tests

Under `Packages/Infrastructure/Tests/SoundfontsTests/MuseScoreSF2ResolverTests.swift` (new):

- cache hit beats bundle hit beats fallback (sync path, all three permutations).
- precise miss + flute fallback for pitched.
- precise miss + drum fallback for drum lookup.
- async path: cache → bundle → download (mock URLSession via injected `URLProtocol`).
- file naming: `BBB_PPP.sf2` for melodic, `128_PPP.sf2` for drums.

Under `Packages/Infrastructure/Tests/AudioTests/LivePlaybackControllerTests.swift` (extend if exists, else new):

- Score with one staff whose file is unavailable → channel rewritten to `(0, 73)` before `engine.prepare`.
- Score with drumset staff whose file is unavailable → channel rewritten to `(0, 0)`.
- Score where every patch is in cache → no rewrite, original channels preserved.

`swift-sheet-music`'s own tests get a small update to cover the `isDrums` parameter being threaded through `PlaybackEngine`.

## Out of scope

- Surfacing fallback usage in the UI (no toast / banner). Voices play, possibly with substituted timbre, and the user discovers it audibly. A future iteration can wire status into the Settings → Soundfonts screen.
- Pre-warming downloads at app launch.
- Pruning / size limits on the cache directory.
- Re-introducing a full GM file as an opt-in advanced fallback.

## Migration / one-time tasks

- Delete `App/Resources/Sounds/MuseScore_General.sf2` (gitignored, dev-machine only — already missing in CI).
- Drop the `Sounds` folder reference from `project.yml`.
- Remove the GM-copy step from `CLAUDE.md` "First-Time Setup".
- Add `App/Resources/Soundfonts/` (committed) with the two bundled files.
- `xcodegen generate` after `project.yml` edits.
