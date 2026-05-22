# Reader View Model Split — Responsibility-Based Extraction

## Background

`Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift` is currently 604 lines and suppresses both `file_length` and `type_body_length` via `// swiftlint:disable`. The size is not the symptom — the underlying problem is that the type concentrates four loosely related responsibilities behind one façade. We want to extract responsibility-shaped classes (not file-shaped extensions) so the suppressions can be removed.

## Goal

Split `ReaderViewModel` so that:

- Each new class owns one clear responsibility, with state, lifecycle, and public methods that align with that responsibility.
- `ReaderViewModel` becomes a thin orchestrator that wires the subsystems together — comparable in role to the existing four sub-models (`RepeatModel`, `TempoModel`, `LayoutSettingsModel`, `PlaybackMixerModel`).
- The `// swiftlint:disable file_length` and `// swiftlint:disable:next type_body_length` directives on `ReaderViewModel.swift` are removed.
- Existing reader behavior is preserved exactly — no functional change to playback, PiP, persistence, or cursor handling.

## Non-goals

- Changing reader UX, copy, persistence schema, audio engine behavior, or any product spec.
- Touching the four existing sub-models (`Repeat/Tempo/LayoutSettings/PlaybackMixer`) — they keep their current shape.
- Reorganizing files outside `Packages/Features/Reader/Sources/Reader/`.
- Migrating off `@Observable` / Swift 6.3 concurrency patterns.

## Current shape

`ReaderViewModel` currently mixes:

| Responsibility | Approximate lines | Representative state / methods |
| --- | --- | --- |
| PiP session policy | ~150 | `pipCoordinator`, `isPiPActive`, `pendingArmTask`, `hasArmedPiP`, `pipArmIsDirty`, `collapseMultiMeasureRests`, `setPiPEnabled`, `armPiPIfReady`, `scheduleArm`, `flushPendingPiPArmIfDirty`, `performPiPArm`, `applyPiPAutoStart`, `dismissPiPOnForeground`, `notifyPiPCursor` |
| Playback engine bootstrap | ~100 | `isPlaying`, `playbackCursor`, `rawPlaybackCursor`, `hasLoadedIntoPlayback`, `preloadTask`, `pendingSoundfontSwap`, `soundfontDownloadObservationTask`, `prepareForPlayback`, `releaseEngine`, `togglePlayback`, `startObservingCursor`, `startObservingSoundfontDownload`, `setManualCursor` |
| Preferences persistence + sub-model wiring | ~150 | `preferences`, `wireRepeatModel`, `wireTempoModel`, `wireLayoutModel`, `wireMixerModel`, `loadOrSeedPreferences`, `mutatePreferences` |
| Score loading + ambient UI state | ~80 | `LoadState`, `load()`, `describe(error)`, `updateLastOpenedAtOnce`, `viewportZoom`, `resetZoom`, `isPlaybackInspectorPresented`, `isVisualInspectorPresented`, `scoreItem` |

## Design

### High-level structure

After the split:

```
ReaderViewModel  (orchestrator, target ~200 lines)
├── repeatModel:        RepeatModel                  (existing)
├── tempoModel:         TempoModel                   (existing)
├── layoutModel:        LayoutSettingsModel          (existing)
├── mixerModel:         PlaybackMixerModel           (existing)
├── pipSession:         ReaderPiPSession             (new)
├── playbackSession:    ReaderPlaybackSession        (new)
└── preferencesStore:   ReaderPreferencesStore       (new, @ObservationIgnored)
```

The three new classes follow the existing sub-model pattern: provider closures for cross-subsystem data, `onChange` / `onX` callbacks for outbound notification, and `@ObservationIgnored` for any state that the View doesn't bind to.

File layout inside `Packages/Features/Reader/Sources/Reader/`:

- `PiP/ReaderPiPSession.swift` — joins the existing PiP support files (`ScorePiPCoordinator.swift` etc.).
- `ReaderPlaybackSession.swift` — at source root, alongside the four existing sub-models.
- `ReaderPreferencesStore.swift` — at source root.

### `ReaderPiPSession`

```swift
@MainActor
@Observable
final class ReaderPiPSession {
    private(set) var isActive = false

    @ObservationIgnored private var coordinatorBacking: ScorePiPCoordinator?
    @ObservationIgnored private var isEnabled = false
    @ObservationIgnored private var collapseMultiMeasureRests = false
    @ObservationIgnored private var pendingArmTask: Task<Void, Never>?
    @ObservationIgnored private var hasArmed = false
    @ObservationIgnored private var isDirty = false

    var scoreProvider:          () -> Score?              = { nil }
    var isPlayingProvider:      () -> Bool                = { false }
    var playbackCursorProvider: () -> ScoreCursor?        = { nil }
    var layoutSnapshotProvider: () -> PiPLayoutSnapshot?  = { nil }
    var playbackController:     (any PlaybackController)?
    var onTogglePlayback:       () async -> Void          = {}

    static var isSupported: Bool { ScorePiPCoordinator.isSupported }
    var coordinator: ScorePiPCoordinator { /* lazy build + closure wiring */ }

    func setEnabled(_ enabled: Bool)
    func setCollapseMultiMeasureRests(_ enabled: Bool)
    func dismissOnForeground()
    func dismissIfActive()
    func notifyCursorChanged()
    func onPlayingChanged(to playing: Bool)
    func armIfReady()

    private func scheduleArm()
    private func flushDirtyIfNeeded()
    private func performArm() async
    private func applyAutoStart()
}

struct PiPLayoutSnapshot {
    let staffSize: CGFloat
    let hiddenStaves: Set<StaffIndex>
    let clefOverrides: [StaffIndex: ClefSign]
}
```

- Existing `isPlaying.didSet` behavior (apply autostart + flush dirty arm) collapses into `onPlayingChanged(to:)`, called once per `isPlaying` transition from `ReaderPlaybackSession`.
- `PiPLayoutSnapshot` keeps the three layout inputs (`staffSize`, `hiddenStaves`, `clefOverrides`) consistent at arm time — VM provides one snapshot per arm rather than three separate providers that could drift across closures.
- The lazy `coordinator` constructor wires `onPiPStarted` / `onPiPStopped` / `isAppPlayingProvider` / `onSetPlaying` / `currentTimeProvider` / `totalTimeProvider` / `onSkip` against the session's providers + `onTogglePlayback`. The View Model no longer touches `ScorePiPCoordinator` directly.
- `dismissOnForeground()` no-ops when not active; `dismissIfActive()` dismisses unconditionally when active. They are not merged because the call sites communicate different intents (foreground-return policy vs. layout-change forced refresh).

### `ReaderPlaybackSession`

```swift
@MainActor
@Observable
final class ReaderPlaybackSession {
    private(set) var isPlaying = false
    private(set) var playbackCursor: ScoreCursor?    // translated for hidden staves

    @ObservationIgnored private(set) var rawPlaybackCursor: ScoreCursor?
    @ObservationIgnored let controller: (any PlaybackController)?

    @ObservationIgnored private let museScoreGeneralProvider: (any MuseScoreGeneralProvider)?
    @ObservationIgnored private var hasLoadedIntoPlayback = false
    @ObservationIgnored private var preloadTask: Task<Void, Error>?
    @ObservationIgnored private var pendingSoundfontSwap = false
    @ObservationIgnored private var soundfontDownloadTask: Task<Void, Never>?

    var scoreProvider:        () -> Score?              = { nil }
    var hiddenStavesProvider: () -> Set<StaffIndex>     = { [] }
    var preferencesProvider:  () -> ReaderPreferences?  = { nil }
    var scoreItemProvider:    () -> ScoreItem?          = { nil }

    var onPlayingChanged:      (Bool) -> Void           = { _ in }
    var onCursorChanged:       () -> Void              = {}
    var onReadyForLoopForward: () async -> Void        = {}

    init(controller: (any PlaybackController)?,
         museScoreGeneralProvider: (any MuseScoreGeneralProvider)?)

    func prepareForPlayback() async
    func releaseEngine() async
    func togglePlayback() async
    func startObservingCursor()
    func startObservingSoundfontDownload()
    func setManualCursor(_ cursor: ScoreCursor)
    func refreshTranslation()

    deinit { soundfontDownloadTask?.cancel() }
}
```

- `isPlaying` is now session-owned. Internal `didSet` analogue: any place that flips `isPlaying` calls `onPlayingChanged(playing)` after the assignment, which the View Model bridges to `pipSession.onPlayingChanged(to:)`.
- Cursor handling lives entirely in the session: the raw stream comes from `controller.observeCursor`, the session translates via `Score.translateCursorForHiddenStaves(_:hiddenStaves:)` (using the providers), and `setManualCursor` performs the inverse translation via `Score.engineCursorForFilteredTap(_:hiddenStaves:)` before calling `controller.setCursor(to:)`.
- `refreshTranslation()` is invoked by the View Model when `LayoutSettingsModel.onHiddenStavesChanged` fires; it re-runs the translation against the latest `rawPlaybackCursor` and emits `onCursorChanged`.
- `onReadyForLoopForward` is fired after the first successful `controller.load` so the View Model can call `repeatModel.forwardLoopRangeToController()` — the session does not depend on `RepeatModel` directly.
- The "stop on natural end of score" behavior (engine emits a nil cursor at end) lives inside `startObservingCursor` — flipping `isPlaying = false` and firing `onPlayingChanged(false)`.

### `ReaderPreferencesStore`

```swift
@MainActor
final class ReaderPreferencesStore {
    private(set) var preferences: ReaderPreferences

    private let repository: any ScoreLibraryRepository
    private let scoreItemID: ScoreItem.ID
    private let defaultStaffSize: CGFloat

    init(scoreItemID: ScoreItem.ID,
         defaultStaffSize: CGFloat,
         repository: any ScoreLibraryRepository)

    @discardableResult
    func loadOrSeed() async -> ReaderPreferences

    func mutate(_ apply: (inout ReaderPreferences) -> Void) async
}
```

- Not `@Observable`. Views never read `viewModel.preferences` directly; the four sub-models observe their own state and the store is purely a load/save backstop.
- `loadOrSeed()` returns the resolved `ReaderPreferences` so the View Model can run `repeatModel.sync(from:)` / `tempoModel.sync(from:)` / `layoutModel.sync(from:)` / `mixerModel.sync(from:)` at the call site — the store has no opinion on which sub-models exist.
- `mutate` re-runs `ReaderPreferences.init` after applying the closure to preserve the existing clamping behavior, then persists via `repository.saveReaderPreferences`.

### Updated `ReaderViewModel`

```swift
@MainActor
@Observable
final class ReaderViewModel {
    enum LoadState {
        case loading
        case loaded(Score)
        case failed(message: String)
        var score: Score? { /* unchanged */ }
    }

    static let defaultStaffVolume = 1.0

    var repeatModel      = RepeatModel()
    var tempoModel       = TempoModel()
    var layoutModel      = LayoutSettingsModel()
    var mixerModel       = PlaybackMixerModel()
    var pipSession:      ReaderPiPSession
    var playbackSession: ReaderPlaybackSession

    @ObservationIgnored private let preferencesStore: ReaderPreferencesStore

    private(set) var loadState: LoadState = .loading
    private(set) var scoreItem: ScoreItem

    var viewportZoom: CGFloat = 1.0
    var isPlaybackInspectorPresented = false
    var isVisualInspectorPresented = false

    @ObservationIgnored private let repository: any ScoreLibraryRepository
    @ObservationIgnored private let gateway: any ScoreFileGateway
    @ObservationIgnored private let scoresDirectory: URL
    @ObservationIgnored private let defaultStaffSize: CGFloat
    @ObservationIgnored private var hasUpdatedLastOpened = false

    init(scoreItem:, repository:, gateway:, scoresDirectory:,
         defaultStaffSize: CGFloat = 14,
         playbackController: (any PlaybackController)? = nil,
         museScoreGeneralProvider: (any MuseScoreGeneralProvider)? = nil)

    func load() async
    func resetZoom()
}

extension ReaderViewModel: PlaybackMixerHost {}
```

The View Model's `init` is the central wiring point. It:

1. Constructs `playbackSession`, `pipSession`, and `preferencesStore`.
2. Wires the four existing sub-models (`wireRepeatModel`/`wireTempoModel`/`wireLayoutModel`/`wireMixerModel`) — their `onChange` callbacks now call `preferencesStore.mutate { ... }` instead of an inline `mutatePreferences`.
3. Wires the session providers and callbacks:
    - `playbackSession.scoreProvider = { [weak self] in self?.loadState.score }`
    - `playbackSession.hiddenStavesProvider = { [weak self] in self?.layoutModel.hiddenStaves ?? [] }`
    - `playbackSession.preferencesProvider = { [weak self] in self?.preferencesStore.preferences }`
    - `playbackSession.scoreItemProvider = { [weak self] in self?.scoreItem }`
    - `playbackSession.onPlayingChanged = { [weak self] playing in self?.pipSession.onPlayingChanged(to: playing) }`
    - `playbackSession.onCursorChanged = { [weak self] in self?.pipSession.notifyCursorChanged() }`
    - `playbackSession.onReadyForLoopForward = { [weak self] in await self?.repeatModel.forwardLoopRangeToController() }`
    - `pipSession.scoreProvider = { [weak self] in self?.loadState.score }`
    - `pipSession.isPlayingProvider = { [weak self] in self?.playbackSession.isPlaying ?? false }`
    - `pipSession.playbackCursorProvider = { [weak self] in self?.playbackSession.playbackCursor }`
    - `pipSession.layoutSnapshotProvider = { [weak self] in self?.currentPiPLayoutSnapshot() }`
    - `pipSession.playbackController = playbackController`
    - `pipSession.onTogglePlayback = { [weak self] in await self?.playbackSession.togglePlayback() }`
4. Extends `LayoutSettingsModel.onHiddenStavesChanged` to call `playbackSession.refreshTranslation()` and, if `pipSession.isActive`, `pipSession.dismissIfActive()`.
5. Extends the four `wire*Model` closures (where appropriate) to call `pipSession.armIfReady()` after persistence — currently only `wireLayoutModel` does this for clef override edits.

`load()` shape:

```swift
func load() async {
    loadState = .loading
    let url = scoresDirectory.appending(path: scoreItem.localFileName)
    do {
        let (score, _) = try await gateway.loadScore(fileURL: url)
        let prefs = await preferencesStore.loadOrSeed()
        repeatModel.sync(from: prefs)
        tempoModel.sync(from: prefs)
        layoutModel.sync(from: prefs)
        mixerModel.sync(from: prefs)
        loadState = .loaded(score)
        pipSession.armIfReady()
        await updateLastOpenedAtOnce()
    } catch {
        loadState = .failed(message: describe(error))
    }
}
```

Two private helpers remain on the View Model:

- `describe(_ error: Error) -> String` — error-to-localized-message mapping (used only by `load`).
- `updateLastOpenedAtOnce()` — one-shot timestamp save (touches `scoreItem` and `repository`, neither of which the new classes own).
- `currentPiPLayoutSnapshot() -> PiPLayoutSnapshot?` — reads `layoutModel.staffSize` / `layoutModel.hiddenStaves` / `layoutModel.staffClefOverrides`, used by `pipSession.layoutSnapshotProvider`.

### View-side call sites

Per agreed decision: views are migrated to call into the sub-objects directly. No forwarder methods are kept on `ReaderViewModel`.

| Before | After |
| --- | --- |
| `viewModel.isPlaying` | `viewModel.playbackSession.isPlaying` |
| `viewModel.playbackCursor` | `viewModel.playbackSession.playbackCursor` |
| `viewModel.togglePlayback()` | `viewModel.playbackSession.togglePlayback()` |
| `viewModel.setManualCursor(_:)` | `viewModel.playbackSession.setManualCursor(_:)` |
| `viewModel.prepareForPlayback()` | `viewModel.playbackSession.prepareForPlayback()` |
| `viewModel.releaseEngine()` | `viewModel.playbackSession.releaseEngine()` |
| `viewModel.startObservingCursor()` | `viewModel.playbackSession.startObservingCursor()` |
| `viewModel.startObservingSoundfontDownload()` | `viewModel.playbackSession.startObservingSoundfontDownload()` |
| `viewModel.isPiPActive` | `viewModel.pipSession.isActive` |
| `viewModel.isPiPSupported` | `ReaderPiPSession.isSupported` |
| `viewModel.setPiPEnabled(_:)` | `viewModel.pipSession.setEnabled(_:)` |
| `viewModel.setCollapseMultiMeasureRests(_:)` | `viewModel.pipSession.setCollapseMultiMeasureRests(_:)` |
| `viewModel.dismissPiPOnForeground()` | `viewModel.pipSession.dismissOnForeground()` |

Properties left on the View Model (no rename): `loadState`, `scoreItem`, `viewportZoom`, `isPlaybackInspectorPresented`, `isVisualInspectorPresented`, `repeatModel`, `tempoModel`, `layoutModel`, `mixerModel`, `load()`, `resetZoom()`.

## Behavior preservation

The split must keep these observable behaviors exactly:

- PiP arm coalescing — back-to-back triggers (e.g. `onHiddenStavesChanged` followed by `onChange`) collapse to one `LayoutEngine.layout` against the latest state. Implemented via `pendingArmTask` cancellation inside `scheduleArm`, unchanged in semantics.
- "Postpone arm when no observer" — when paused in foreground without active PiP, `armIfReady` sets `isDirty = true` instead of arming. `onPlayingChanged(to: true)` flushes via `flushDirtyIfNeeded()`.
- First-arm-per-enable always proceeds (so a manual PiP start still finds a renderer attached). Implemented by `hasArmed == false` short-circuiting the dirty path.
- Auto-start permission gated on `isEnabled && isPlaying` — fires from `setEnabled`, `onPlayingChanged`, and any state transition that changes either input.
- Soundfont hot-swap: download finishing while playing queues `pendingSoundfontSwap = true`; the next `isPlaying = false` transition drains it via `controller.reloadSoundfont()`.
- Engine emits nil cursor at natural end of score → session flips `isPlaying = false`. Explicit `pause()` does not emit nil.
- `setManualCursor(_:)` translation: visible-tap cursor is converted to engine cursor via `engineCursorForFilteredTap(_:hiddenStaves:)` before reaching the controller; the visible cursor is set to the input value directly.
- `onHiddenStavesChanged` dismisses the active PiP session (so AVKit renegotiates aspect ratio) but does not re-arm — the subsequent `LayoutSettingsModel.onChange` calls `armIfReady` for us. The dismiss path lives in the View Model's `layoutModel.onHiddenStavesChanged` handler (alongside `refreshTranslation`).
- `startObservingCursor` and `startObservingSoundfontDownload` must be called from a view-lifecycle hook (`.task` / `.onAppear`) — never from `init`. This constraint is preserved by exposing them as session methods that views call explicitly.
- `deinit` must cancel `soundfontDownloadTask` — moves from View Model `deinit` to `ReaderPlaybackSession.deinit`.

## Testing strategy

Existing reader tests run against the public View Model surface. Migration:

- Tests that currently read `viewModel.isPlaying` / `viewModel.playbackCursor` / call `viewModel.togglePlayback()` etc. switch to the new nested addresses (`viewModel.playbackSession.*`) — same value, same semantics.
- No new unit tests are required for the extracted classes if their behavior is fully exercised through `ReaderViewModel`. If a behavior gap is found (e.g. PiP arm coalescing logic was previously only smoke-tested), it can be addressed in a follow-up.
- Manual verification path (post-implementation): open a score, toggle play/pause, enable PiP from Settings, background the app while playing, hide a staff mid-playback, change a clef override, let the high-quality soundfont download finish mid-session, hit AB-repeat. All must behave exactly as before.

## Risks

- **Closure capture cycles.** Every new provider/callback captures `[weak self]` to the View Model. Because the View Model owns the sessions, this is the natural direction — but every closure must use `[weak self]` to keep the session from retaining the VM transitively. Verified by leak checks in the implementation plan.
- **Observation chain depth.** Views now bind through `viewModel.playbackSession.isPlaying`. Swift Observation tracks through `@Observable` chains, so this should work, but a regression where SwiftUI fails to update after the rename is the most likely surprise. Smoke-test in a preview before considering implementation complete.
- **Provider freshness on `armIfReady` race.** `pipSession.armIfReady()` is fired from multiple call sites (load completion, hidden-staves change, clef override change, `onPlayingChanged`). `layoutSnapshotProvider` reads the current `layoutModel` state at arm time — make sure `performArm` always re-reads the snapshot inside the task (after cancellation), not at scheduling time.

## Out-of-scope follow-ups

- Removing the `[weak self]` boilerplate in every wire site by switching to a different ownership shape (e.g., sessions being structs / closures-only). Not pursued — would diverge from the existing sub-model pattern.
- Migrating cursor translation off `Score.translateCursorForHiddenStaves` / `Score.engineCursorForFilteredTap`. Out of scope.
- Splitting `LayoutSettingsModel` further — it is currently within budget.
