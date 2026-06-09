# Android Soundfont Download — Design Spec

**Date:** 2026-06-09
**Status:** Approved (design); ready for implementation planning
**Scope:** Port the iOS high-quality SoundFont download feature to Android at full behavioral parity, sharing the provider logic in Swift and injecting platform I/O from Kotlin.

## Goal

folino ships a bundled lightweight SoundFont (`GeneralUser-GS.sf2`, ~31 MB) and offers an optional high-quality upgrade (`MuseScore_General.sf2`, ~206 MB) downloaded on demand. iOS implements this end to end; Android currently only materializes the bundled asset and explicitly marks the download as out of scope. This spec brings Android to **full parity** with iOS: Wi-Fi-by-default auto-download, cellular override, in-flight progress, delete, failure handling with auto-retry on reachability, and hot-swap of the active SoundFont while the reader is paused.

## Constraints & guiding rules

- **iOS/Android parity policy:** behavior/logic matches iOS exactly and is *shared*; only the parts that can *only* be done on Android are written natively. UI placement follows Android idioms (Material `AlertDialog`, Settings row), but the content shown stays at iOS parity.
- **Layered SPM architecture:** Feature → Infrastructure and Feature → swift-sheet-music are forbidden. The shared provider is Infrastructure logic, so its JNI bridge lives in the Infrastructure package, not in a Feature.
- **No new third-party Swift dependency.** The Android download transport uses platform Android APIs (`DownloadManager` / `ConnectivityManager`) injected from Kotlin via swift-wirelet `@WireletProvided`.
- **iOS behavior must not regress.** The iOS refactor that extracts the transport is behavior-preserving and covered by the existing `LiveMuseScoreGeneralProviderTests`.

## Background — the iOS feature (reference)

- **Domain:** `MuseScoreGeneralProvider` (`@MainActor`, `Observable`) protocol; `SoundfontDownloadState` enum (`idle` / `downloading(progress:)` / `downloaded` / `failed(reason:)`); `SoundfontPreset` enum (`lightweight` / `highQuality`); `NetworkPathObserving` protocol (already abstracts reachability).
- **Infrastructure (`Sources/Soundfonts/`):** `LiveMuseScoreGeneralProvider` owns opt-in persistence (UserDefaults key `soundfont.museScoreGeneral.optedIn`, default `true`), the download state machine, Wi-Fi gating, auto-retry, and preset selection — but uses `URLSession`/`URLSessionDownloadTask` **directly inline**. `NWPathMonitorAdapter` implements `NetworkPathObserving`. `GMSoundfontResolver` adapts the provider to the audio engine.
- **UI (`Features/Settings`):** `SoundfontPresetRow` binds to the provider's observable state; toggle morphs into determinate progress / indeterminate "waiting for Wi-Fi" / switch; alerts for cellular override and delete confirmation.
- **Audio:** `GMSoundfontResolver.defaultGMSoundfontURL` returns the high-quality file when present + opted-in, else the bundled file. `ReaderPlaybackSession` observes `downloadState`; on `.downloaded` it hot-swaps (immediately if paused, else on next pause) via `LivePlaybackController.reloadSoundfont()` (engine teardown → re-prepare → restore prefs + cursor).
- **Download source (both platforms):** `https://github.com/jiyimeta/musescore-general-sf2-split/releases/download/unsplit/MuseScore_General.sf2`.

## Android current state

- `Android/FolinoReaderAndroid/.../FolinoSoundfontResolver.kt` lazily copies the bundled `GeneralUser-GS.sf2` from `assets/` to `cacheDir` and always returns it. No download, no Settings UI, no reachability, TODO comment marks high-quality as out of scope.
- Settings UI: `Android/app/.../ui/settings/SettingsScreen.kt` — a `LazyColumn` of `ToggleRow`s with a "Reader" section. Opt-in persistence convention is Jetpack **DataStore** (`SettingsPrefs`).
- Wirelet pattern precedent: `RoomLibraryStore` / `PdfScoreRenderer` implement Swift-declared `@WireletProvided` interfaces injected over JNI; Reader playback inspector streams Swift state to Compose via `@WireletObservable`. Per-feature JNI products (`FolinoReaderJNI`, `FolinoLibraryJNI`, `FolinoSettingsJNI`) build `.so` + JExtract Java bindings via `Scripts/android-build-*-libs.sh`.
- No `ConnectivityManager` / `NetworkCapabilities` usage exists yet.

## Architecture

```
                 shared Swift core (platform-agnostic)
   ┌─────────────────────────────────────────────────────────┐
   │ MuseScoreGeneralProvider impl                            │
   │   • opt-in persistence + default                         │
   │   • download state machine                               │
   │   • Wi-Fi gating + auto-retry orchestration              │
   │   • preset selection (highQuality vs lightweight)        │
   │ depends on injected protocols:                           │
   │   • SoundfontDownloading   (transport)                   │
   │   • NetworkPathObserving   (reachability, existing)      │
   │   • key-value persistence + target directory            │
   └───────────────┬───────────────────────┬─────────────────┘
                   │                        │
        ┌──────────┴─────────┐   ┌──────────┴──────────────────────────┐
        │ iOS                │   │ Android: FolinoSoundfontJNI bridge   │
        │ URLSession         │   │ @WireletObservable → Compose state   │
        │  Downloader        │   │ @WireletExpose ← commands            │
        │ NWPathMonitor      │   │ @WireletProvided ← Kotlin services:  │
        │ UserDefaults       │   │   • AndroidSoundfontDownloader       │
        │                    │   │   • AndroidNetworkReachability       │
        │                    │   │   • DataStore-backed KV + filesDir   │
        └────────────────────┘   └──────────────────────────────────────┘
```

### Step 1 — iOS refactor (behavior-preserving)

Extract the download transport out of `LiveMuseScoreGeneralProvider` behind a new protocol:

```swift
protocol SoundfontDownloading: Sendable {
    /// Begin a download. Progress and terminal events are reported through the callbacks.
    func start(
        from remote: URL,
        to destination: URL,
        allowingCellular: Bool,
        onProgress: @escaping @Sendable (Double) -> Void,
        onFinished: @escaping @Sendable (Result<Void, Error>) -> Void
    )
    func cancel()
}
```

- Move the existing `URLSession` / `URLSessionDownloadTask` / delegate code into a new `URLSessionSoundfontDownloader` (Infrastructure, iOS). The Wi-Fi-only vs cellular session split is preserved inside this type (it receives `allowingCellular`).
- `LiveMuseScoreGeneralProvider.init` gains a `downloader: SoundfontDownloading` parameter (defaulting to `URLSessionSoundfontDownloader` on iOS) alongside the existing `NetworkPathObserving`. Persistence and `targetDirectory` are already injectable.
- Net effect: the provider becomes pure orchestration + state machine. **iOS runtime behavior is unchanged.**
- The existing `LiveMuseScoreGeneralProviderTests` are updated to inject a fake `SoundfontDownloading` (replacing the `ProviderStubURLProtocol` interception) and must stay green, proving the refactor is behavior-preserving.

### Step 2 — `FolinoSoundfontJNI` (new Infrastructure JNI product)

A new Swift product in the **Infrastructure** package (the only layer that may import the provider implementation). It composes the shared provider with Kotlin-injected services and exposes the wirelet surface. **This is a module-architecture addition — approved in brainstorming.**

Exposed surface:

- `@WireletObservable` state consumed by Compose:
  - `downloadState`: wire projection of `idle` / `downloading(progress: Double)` / `downloaded` / `failed(reason: String)`.
  - `isOptedIn: Bool`
  - `currentPreset`: `lightweight` / `highQuality`
- `@WireletExpose` commands (Kotlin → Swift): `setOptedIn(_:)`, `startDownloadIfNeeded()`, `startDownloadAllowingCellular()`, `cancelDownload()`, `deleteDownloaded()`.
- `@WireletExpose` progress ingestion (Kotlin downloader → Swift), so no Swift closures cross the bridge: `ingestProgress(_ fraction: Double)`, `ingestFinished(_ path: String)`, `ingestFailed(_ reason: String)`. The JNI bridge's `SoundfontDownloading` adapter forwards `start`/`cancel` to the injected Kotlin downloader and routes these ingest callbacks back into the shared provider's existing `onProgress` / `onFinished` plumbing.

Build integration mirrors the existing JNI targets: a `Scripts/android-build-soundfont-libs.sh` builds `libFolinoSoundfontJNI.so` for `arm64-v8a` + `x86_64`, stages runtime `.so`s, and copies JExtract Java bindings into the consuming Android module's `java-generated/`.

### Step 3 — Kotlin platform services (`@WireletProvided` implementations)

- **`AndroidSoundfontDownloader`** — implements the Swift-declared downloader-service interface. Uses Android **`DownloadManager`** (OS-managed, resilient for a 206 MB transfer; `setAllowedNetworkTypes(WIFI)` for Wi-Fi-only, `WIFI or MOBILE` for the cellular override). Polls/observes the download for progress and calls the bridge's `ingestProgress` / `ingestFinished(path)` / `ingestFailed(reason)`. On finish it places the file at the target path and reports completion.
- **`AndroidNetworkReachability`** — implements `NetworkPathObserving` over `ConnectivityManager` + `NetworkCapabilities` (`TRANSPORT_WIFI`). Registers a `NetworkCallback` so Wi-Fi return drives the provider's auto-retry. Requires `<uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />` in the manifest.
- **DataStore-backed key-value** for the opt-in flag: key `soundfont.museScoreGeneral.optedIn`, **default `true`** (parity: first launch auto-downloads over Wi-Fi). Exposed to the shared provider through the injected persistence abstraction.
- **Target directory:** `filesDir/Soundfonts/` (persistent app data, parity with iOS App Support). Downloaded file: `filesDir/Soundfonts/MuseScore_General.sf2`.

### Step 4 — Compose UI (Android idiom, iOS-parity content)

Add a soundfont row to the "Reader" section of `SettingsScreen.kt`, driven by the `@WireletObservable` state. Accessory morphs by `downloadState` (same meanings as iOS):

- `downloading(p)` → circular **determinate** progress (0–100%) + stop button (cancels).
- opted-in & `idle` (waiting for Wi-Fi) → subtitle "waiting for Wi-Fi" + inline "Download now" action + **indeterminate** arc + stop (opts out of trying).
- otherwise → Material `Switch`.
- Toggle ON while not on Wi-Fi → `AlertDialog`: "Download over cellular" (`startDownloadAllowingCellular`) / "Wait for Wi-Fi" (`setOptedIn(true)`) / cancel (reverts).
- Toggle OFF while downloaded → `AlertDialog` delete confirmation → `setOptedIn(false)` (deletes the file) / cancel (reverts).
- `failed(reason)` → red error subtitle; re-tapping the toggle retries.

Copy is localized; user-facing brand stays lowercase `folino`.

### Step 5 — Engine integration & hot-swap (no swift-sheet-music change)

- **Resolver:** `FolinoSoundfontResolver` stops caching a single URI via `by lazy`. On each query it returns the downloaded high-quality file when present + opted-in, else the bundled `GeneralUser-GS.sf2` (materialized from assets as today).
- **Hot-swap:** `ReaderPlaybackService` observes the bridge's `downloadState`. On `downloaded`:
  - if paused → reload now: `engine.teardown()` → reconstruct `AndroidPlaybackEngine` (or its existing re-prepare path) → `prepare(score:)` (re-queries the resolver, picks up the new SF2) → re-apply user prefs (volumes/mutes/solos/tempo/metronome) → restore cursor position.
  - if playing → set a pending flag; perform the reload on the next pause.
  This reuses the existing Android engine lifecycle (`teardown` already exists, construction + prepare already exist); **no new sheet-music-audio API is required.**

## Data flow

1. First launch: DataStore opt-in defaults `true`. Provider sees not-downloaded + opted-in; if reachability reports Wi-Fi, `startDownloadIfNeeded()` kicks the Kotlin `DownloadManager` (Wi-Fi-only).
2. Progress events flow Kotlin → `ingestProgress` → shared provider → `@WireletObservable downloadState` → Compose progress UI.
3. On finish, file lands at `filesDir/Soundfonts/MuseScore_General.sf2`; `ingestFinished` → state `.downloaded`.
4. `ReaderPlaybackService` observes `.downloaded`; hot-swaps the resolver-backed engine on the next safe point (immediately if paused).
5. Failure → `ingestFailed(reason)` → state `.failed`; when `AndroidNetworkReachability` reports Wi-Fi return, the provider auto-retries.
6. Cellular override and delete are user gestures routed through the `@WireletExpose` commands.

## Error handling

- HTTP/transport errors and non-2xx responses → `failed(reason:)` with a localized message; auto-retry on Wi-Fi reachability return (parity with iOS).
- Download cancellation (user stop, opt-out) cleans up any partial file; no resume (parity with iOS — restarts).
- Missing bundled asset on Android already logs and returns silent-audio `null`; unchanged.
- Hot-swap reload failures must not crash playback; on failure the engine keeps the previously loaded SoundFont.

## Testing

- **Shared Swift core:** Swift Testing suites against a fake `SoundfontDownloading` and the existing `FakePathMonitor`: default opt-in, toggle cancels/deletes, Wi-Fi gating, progress reporting, success + file install, cellular override, failure → auto-retry on reachability change. The migrated `LiveMuseScoreGeneralProviderTests` must stay green.
- **Kotlin services:** thin unit tests for `AndroidSoundfontDownloader` network-type mapping and `AndroidNetworkReachability` Wi-Fi detection (with fakes/Robolectric as available).
- **Manual / device:** Pixel install + launch (Android changes are install+launch-complete per project convention): observe Wi-Fi auto-download, cellular override alert, progress, delete confirmation, failure retry, and a paused hot-swap producing audibly higher-fidelity playback.

## Out of scope

- A dynamic catalog of multiple downloadable SoundFonts (iOS is a single hard-coded high-quality URL; Android matches).
- Background/resumable download beyond what `DownloadManager` provides for free.
- Any swift-sheet-music engine API change (hot-swap reuses existing lifecycle).

## Open implementation details (resolved during planning)

- Exact placement of `FolinoSoundfontJNI` within the Infrastructure package and whether a dedicated Android consuming module (e.g. `FolinoSoundfontAndroid`) or the existing `app` module hosts the Kotlin services + generated bindings.
- Wire projection shapes for `SoundfontDownloadState` / `SoundfontPreset` (associated-value encoding for `downloading(progress:)` and `failed(reason:)`).
- Whether the hot-swap reconstructs `AndroidPlaybackEngine` wholesale or uses an in-place re-prepare, chosen to best preserve cursor + prefs.
