# iOS / Android / macOS parity ledger

Folino ships on three platforms — iOS, Android, and (as of sub-project Ⅲa) macOS —
and they regularly land a feature unevenly. This file records what is
**deliberately** owed to whichever platform is behind, so a half-crossed feature
is a tracked debt rather than something rediscovered months later by a user.

It is not a TODO list. Only record a gap that is real and intended — an ordinary
"would be nice" belongs in the roadmap, and a bug belongs in an issue. A ledger
that collects everything stops being read, which is the failure this file exists
to avoid.

## How an entry is created

Leave a marker where the code diverges — not here:

```swift
// PARITY(android): measure-number policy — add the interval to LayoutOptionsWire
//   and surface a Compose toggle
public static let showAllMeasureNumbers = "readerShowAllMeasureNumbers"
```

Format: `PARITY(<android|ios|macos>): <title> — <what the other platform still needs>`,
where `<platform>` is the platform the work is **owed to** — `macos` is a valid
value alongside `android` and `ios`. The separator is an em dash (` -- ` also
works). A continuation line repeats the comment token and indents.

`Scripts/parity-report.py` collects the markers into the generated block below,
and the `parity-ledger` pre-commit hook rewrites it and fails if it had drifted —
so a commit that adds or removes a marker cannot land without this file moving
with it. **Do not hand-edit the generated block**; edit the marker instead.

The point of keeping the source of truth in the code is that finishing the work
deletes the entry: the other platform's implementation removes the marker it was
written next to, and the next commit drops the row. Nobody has to remember to
come back here.

## Gaps with no single code site

Hand-maintained — for whole capabilities one platform simply lacks, which no one
line of source represents. Keep each to a sentence and delete it when it closes.

- _(none recorded yet)_

## Marked in code

<!-- generated:parity — written by Scripts/parity-report.py; do not edit by hand -->

### Owed to Android

| Item | Where it diverges | What Android still needs |
| --- | --- | --- |
| note-input pad coach marks | `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/hints/ReaderHints.kt:66` | the engine already sequences padHide / padRestore / padMove (they are cases of `ReaderInteractionCore.ReaderFeatureHint` and covered by ReaderHintEngineTests), but Android never reports the `noteInputPad` / `noteInputPadHandle` anchors, so they are never offered. Report those two frames from the Compose editing chrome and add the six strings; no engine change is needed — a hint whose control has no anchor is skipped by the same rule that skips the note-editing hint on a PDF. |
| exported audio ignores tuning | `Android/app/src/main/kotlin/com/keynumber/folino/export/AudioScoreExporter.kt:32` | neither the A4 calibration nor the transpose reaches this path, so an export sounds different from what the Reader played. Carry the engine's tuning state into the export snapshot the way playback already does |
| settings_snapshot.show_all_measure_numbers | `Packages/Domain/Sources/Domain/Analytics/AnalyticsEvent+Factories.swift:269` | pass it from the AnalyticsBridge and drop the default here, so the parameter stops reading as "off" for every Android launch |
| PDF-to-score conversion follow-up | `Packages/Domain/Sources/Domain/Models/PDFOriginState.swift:3` | consume this state on Android for the display-source switch, re-read-the-PDF action and the `readerPdfSourceNoticeDismissed` key (Android still reads the older `readerPdfPlaybackNoticeDismissed`). The decisions are all in Domain pure functions already, so Android wires UI and persistence only |
| number every measure | `Packages/Domain/Sources/Domain/Models/ReaderLayoutMode.swift:44` | carry the policy on LayoutOptionsWire (the layout half is shared, so Android needs only the wire field, the SettingsPrefs key and a Compose toggle) |
| drum note entry pad | `Packages/Features/Editor/Sources/Editor/Views/EditorDrumPadRows.swift:1` | Android needs a Compose pad over the same `EditorCore` ops (`pressDrumKey`, `DrumPadLayout`, `litDrumPitches`, the column caret). Only this view is iOS-only; every decision behind it is in `EditorCore`, which `FolinoEditorJNI` already links, so implementing the Compose half moves no logic. |
| M2 instruments sheet | `Packages/Features/Editor/Sources/Editor/Views/EditorInstrumentsSheet.swift:7` | part add/remove/reorder UI, plus the remap wiring for BOTH part-indexed stores: the preferences row and the annotation layer's per-stroke anchors (`AnnotationLayers.remappingParts`, which is shared Domain, so Android inherits the rule) |
| M4 rehearsal mark editing | `Packages/Features/Editor/Sources/Editor/Views/EditorRehearsalMarkSheet.swift:5` | Android needs the sheet UI; ssm logic is shared |
| M3 signature editing | `Packages/Features/Editor/Sources/Editor/Views/EditorSignatureSheet.swift:5` | Android needs the sheet UI; ssm logic is shared |
| letter input on a chord's upper notehead | `Packages/Features/Editor/Sources/EditorCore/EditorSessionCore+Input.swift:295` | Android's `.writeNote` path re-pitches notehead 0; Android still needs the caret-notehead `.setNotePitch` branch iOS keeps here. |
| revert to original | `Packages/Features/Editor/Sources/FolinoEditorJNI/EditorBridge.swift:579` | needs an Android `ScoreOriginalStore` (sidecar copy + restore), the `original*` Room columns and a migration, and `RevertPolicy`'s warnings bridged across. The writer it would restore through exists (`AndroidScoreWriter`); what is missing is the original to restore. Delete this marker when that lands. |
| M2 ensemble wizard | `Packages/Features/Library/Sources/Library/NewScore/NewScoreSheet.swift:7` | instrumentation list, templates, clone-from-existing on Android's creation flow |
| annotation ink vs. hidden staves | `Packages/Features/Reader/Sources/Reader/Annotation/AnnotationStaffFilter.swift:5` | Android renders the same `filtered(hidingStaves:)` score but still resolves anchors against it in display addressing, so ink drifts (and new strokes are stamped in display numbering) while a staff is hidden. Kotlin holds the score, so the fix belongs where it seeds `PrefetchedAnchorResolver`: translate through ssm's `filterStaffAddress` / `unfilterStaffAddress` — the same pair `AnnotationStaffFilter` uses here — before/after calling the shared `AnnotationAnchoringCore`. |
| M2 written-pitch view | `Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift:497` | Android's render pipeline still needs writtenPitchView() between clef overrides and transpose |
| Revert to original | `Packages/ScoreUI/Sources/ScoreUI/RevertToOriginalSection.swift:4` | Android needs the same two entry points and confirmations, plus the three `original_*` columns in its Room schema and the v18 pre-stamp rule. Every decision is already a Domain pure function (OriginalCapture, RevertPolicy, ScoreItem+Original) and the seam is ScoreOriginalStore, so Android wires UI, persistence, and a Kotlin-side implementation of that protocol. The save choke point the capture call goes at now exists on Android too — `EditorSessionCore.performSave` behind `AndroidScoreWriter` — and it already calls `originals?.captureOriginalIfNeeded`, which is nil there for want of a store. |

### Owed to iOS

Nothing is currently owed to iOS.

### Owed to macOS

| Item | Where it diverges | What macOS still needs |
| --- | --- | --- |
| offline audio export | `App/Mac/AudioStackFactory.swift:15` | `LiveScoreAudioExporter` (Infrastructure/Audio) is `#if os(iOS)`-gated until a later task builds the AVAudioSession-free equivalent. Until then the Mac share service is handed this stub, which fails the m4a export path loudly instead of writing a silent zero-length file. |
| score playback | `App/Mac/AudioStackFactory.swift:26` | `LivePlaybackController` (Infrastructure/Audio) is `#if os(iOS)`-gated and does not exist as a nominal type on macOS at all, until a later task builds the AVAudioSession-free equivalent. Until then `AudioStack.playbackController` is `nil` on macOS, and every Mac screen that would drive playback has nothing to call. |
| App Group–backed share drain and playlist index | `App/Mac/SharedContainerTasks.swift:1` | macOS has no Share Extension and its App Group container is team-ID-prefixed, so the Mac bootstrap schedules neither. Revisit if a Mac share destination or a sibling-app hand-off ever needs the shared container. |
| Firebase registration | `App/Shared/AppBootstrap.swift:105` | FirebaseAnalytics ships a macOS slice and Crashlytics is a source target, so neither is a platform blocker. What is missing is a console registration for a Mac app sharing com.KeyNumber.Folino, its own GoogleService-Info.plist, and a decision on attaching the upload-symbols post-build script (project.yml:110). Until then the Mac composes the no-ops. |
| document root | `App/Shared/AppPaths.swift:6` | this is the pre-sandbox location (`~/Library/Application Support/folino/`), not the App Sandbox container. Sub-project Ⅷ moves it into the sandbox with a security-scoped bookmark; Application Support is already where that container's equivalent maps, so nothing here has to move twice in spirit. |
| memory-pressure eviction | `App/Shared/ProcessScoreEditHistoryStore.swift:30` | iOS empties this store on `UIApplication.didReceiveMemoryWarningNotification`; macOS has no equivalent trigger yet. A `DispatchSource.makeMemoryPressureSource` listener would restore parity if the Mac Editor's process footprint ever needs the same defense; until then the LRU cap alone bounds the store there. |
| drum icon ink | `Packages/Features/Editor/Sources/Editor/Views/DrumInstrumentIcon.swift:184` | AppKit's labelColor / tertiaryLabelColor are the same two semantic colours, and the reason for naming a concrete colour rather than `.primary` holds on both platforms. A provisional pairing until a Mac pad exists to look at. |
| dotted-duration menu glyph | `Packages/Features/Editor/Sources/Editor/Views/EditorPadButtons.swift:8` | iOS rasterizes because a UIKit `Menu` row will not draw a custom View or apply a custom font. AppKit menus have no such restriction, so the Mac pad should draw the glyph as a View rather than port the rasterizer. |
| pad-tuck-handle preview background | `Packages/Features/Editor/Sources/Editor/Views/EditorPadTuckHandle.swift:65` | `.systemGroupedBackground` has no macOS analogue, so the preview stands in with `.windowBackgroundColor`, a provisional pick until Reader's own port settles what a Mac grouped surface should read as. |
| bulk-selection chrome | `Packages/Features/Library/Sources/Library/Screens/RecentlyDeletedScreen.swift:71` | iOS needs an explicit Select mode because a touch list cannot distinguish a tap-to-open from a tap-to-select. AppKit's List multi-selects natively with ⌘/⇧-click, so the Mac has no mode and reaches the same bulk actions from the selection's context menu (and, in sub-project Ⅳ, the menu bar). |
| bulk-selection chrome | `Packages/Features/Library/Sources/Library/Views/PlaylistDetailView.swift:67` | iOS needs an explicit Select mode because a touch list cannot distinguish a tap-to-open from a tap-to-select. AppKit's List multi-selects natively with ⌘/⇧-click, so the Mac has no mode and reaches the same bulk actions from the selection's context menu (and, in sub-project Ⅳ, the menu bar). |
| bulk-selection chrome | `Packages/Features/Library/Sources/Library/Views/RecentlyDeletedView.swift:23` | iOS needs an explicit Select mode because a touch list cannot distinguish a tap-to-open from a tap-to-select. AppKit's List multi-selects natively with ⌘/⇧-click, so the Mac has no mode and reaches the same bulk actions from the selection's context menu (and, in sub-project Ⅳ, the menu bar). |
| bulk-selection chrome | `Packages/Features/Library/Sources/Library/Views/ScoreListView.swift:61` | iOS needs an explicit Select mode because a touch list cannot distinguish a tap-to-open from a tap-to-select. AppKit's List multi-selects natively with ⌘/⇧-click, so the Mac has no mode and reaches the same bulk actions from the selection's context menu (and, in sub-project Ⅳ, the menu bar). |
| anchored feature-hint bubble UI | `Packages/Features/Reader/Sources/Reader/Hints/ReaderHintBubble.swift:22` | the window-level tap-through dismiss (`UITapGestureRecognizer`) and the `UIViewRepresentable`-hosted overlay below are iOS-only. Ⅳ's Mac reading surface needs its own coach-mark presentation; until then `readerHintAnchor` / `readerHintOverlay` are no-ops on macOS, so the widely shared `ReaderTopBarControls` / `ReaderTransportControl` / `ReaderDisplayInspectorButton` / `ReaderHintWiring` call sites keep compiling unchanged and simply never show a hint. |
| per-hint copy | `Packages/Features/Reader/Sources/Reader/Hints/ReaderHintCopy.swift:1` | only consumed by the iOS-only `ReaderHintBubble` display struct (see the marker on that file). Ⅳ's Mac reading surface will need this copy again once it builds its own hint presentation. |
| PiP session's coordinator dependency | `Packages/Features/Reader/Sources/Reader/PiP/ReaderPiPSession.swift:48` | `ScorePiPCoordinator` is iOS/tvOS-only AVKit PiP machinery (see the marker on that file), and Ⅳ's Mac reading surfaces have no PiP host, so `isSupported` always reports `false` here and every method below becomes a no-op through the existing `guard Self.isSupported` gates, letting `ReaderViewModel` keep calling this session unconditionally on both platforms. |
| AVKit picture-in-picture | `Packages/Features/Reader/Sources/Reader/PiP/ScorePiPCoordinator.swift:1` | sample-buffer-based PiP (`AVPictureInPictureSampleBufferPlaybackDelegate`) is an iOS/tvOS mechanism with no macOS equivalent. Ⅳ's reading surfaces have no PiP host to arm; until one exists (if ever), `ReaderPiPSession.isSupported` reports `false` on macOS and this whole coordinator is unused. |
| PiP frame renderer | `Packages/Features/Reader/Sources/Reader/PiP/ScorePiPFrameRenderer.swift:1` | renders video frames for `ScorePiPCoordinator`, which is itself iOS/tvOS-only AVKit machinery (see the marker on that file). No macOS reading surface (Ⅳ) needs a pixel-buffer frame renderer. |
| the `UIViewRepresentable` host for `ScorePiPCoordinator`'s display layer | `Packages/Features/Reader/Sources/Reader/PiP/ScorePiPHostView.swift:1` | iOS/tvOS-only AVKit PiP, see the marker on that file. `ReaderRootScreen` only mounts this when `ReaderPiPSession.isSupported`, which is `false` on macOS. |
| implements `AVPictureInPictureSampleBufferPlaybackDelegate`, which is iOS/tvOS-only | `Packages/Features/Reader/Sources/Reader/PiP/ScorePiPPlaybackDelegate.swift:1` | see the marker on `ScorePiPCoordinator.swift`. |
| untouched-preference device default | `Packages/Features/Reader/Sources/Reader/ReaderDeviceDefaults.swift:27` | there is no "tablet" idiom on macOS, so Ⅳ's Mac reading surface needs its own choice here (iPad-like generous defaults are the natural fit for a large screen); `isTablet` and the properties below it are unavailable until then. `staffSize(isTablet:)` / `honorLayoutBreaks(isTablet:)` above stay portable so a macOS caller can already invoke them with its own idiom decision. |
| one of the Reader's iOS-only layout-mode screens, built on `ScoreScrollHost` / `PinchState`. Ⅳ's Mac reading surface needs its own layout, not a port of this one | `Packages/Features/Reader/Sources/Reader/Screens/Horizontal/HorizontalScoreContainer.swift:5` | see the markers on those files. |
| the hosted score subtree for `HorizontalScoreContainer` | `Packages/Features/Reader/Sources/Reader/Screens/Horizontal/HorizontalZoomedSurface.swift:1` | see the marker on that file for what Ⅳ's Mac reading surface needs. |
| extends `PagedPDFContainer` | `Packages/Features/Reader/Sources/Reader/Screens/PDF/PagedPDFContainer+Navigation.swift:1` | see the marker on that file for what Ⅳ's Mac reading surface needs. |
| one of the Reader's iOS-only layout-mode screens, built on `ScoreScrollHost` / `PinchState`. Ⅳ's Mac reading surface needs its own layout, not a port of this one | `Packages/Features/Reader/Sources/Reader/Screens/PDF/PagedPDFContainer.swift:5` | see the markers on those files. |
| one of the Reader's iOS-only layout-mode screens, built on `VerticalReaderShell` / `PinchState`. Ⅳ's Mac reading surface needs its own layout, not a port of this one | `Packages/Features/Reader/Sources/Reader/Screens/PDF/VerticalPDFContainer.swift:1` | see the markers on those files. |
| the hosted PDF page stack for `VerticalPDFContainer` | `Packages/Features/Reader/Sources/Reader/Screens/PDF/VerticalPDFSurface.swift:1` | see the marker on that file for what Ⅳ's Mac reading surface needs. Also reaches `Color(.secondarySystemBackground)`, an iOS-only dynamic color. |
| the page-turn tap-zone overlay for `PagedReaderSurface`'s touch-based page turning | `Packages/Features/Reader/Sources/Reader/Screens/Paged/PageTapOverlay.swift:1` | see the marker on `PagedScoreContainer.swift` for what Ⅳ's Mac reading surface needs. |
| extends `PagedScoreContainer` | `Packages/Features/Reader/Sources/Reader/Screens/Paged/PagedScoreContainer+PageNavigation.swift:1` | see the marker on that file for what Ⅳ's Mac reading surface needs. |
| one of the Reader's iOS-only layout-mode screens, built on `ScoreScrollHost` / `PinchState`. Ⅳ's Mac reading surface needs its own layout, not a port of this one | `Packages/Features/Reader/Sources/Reader/Screens/Paged/PagedScoreContainer.swift:5` | see the markers on those files. |
| previews of `PagedScoreContainer` | `Packages/Features/Reader/Sources/Reader/Screens/Paged/PagedScoreContainerPreviews.swift:1` | see the marker on that file for what Ⅳ's Mac reading surface needs. |
| score-specific adapter over `PagedReaderSurface` for `PagedScoreContainer` | `Packages/Features/Reader/Sources/Reader/Screens/Paged/PagedZoomedSurface.swift:1` | see the marker on that file for what Ⅳ's Mac reading surface needs. |
| pinch-gesture-driven zoom state | `Packages/Features/Reader/Sources/Reader/Screens/PinchState.swift:1` | shared by the score/PDF containers, whose `UIScrollView` / `UIPinchGestureRecognizer` / PencilKit-canvas-overlay world is iOS-only. Ⅳ's Mac reading surface will drive zoom through trackpad/scroll-wheel gestures against a new (AppKit-based) surface instead of reusing this. |
| part-remap hold/drain/release wiring | `Packages/Features/Reader/Sources/Reader/Screens/ReaderRootScreen+PartRemapWiring.swift:1` | the orchestration inside (`setPartMigrationPendingProvider` / `prepareForPartMigration` / `requestReloadAfterPartRemap`) is platform-neutral logic, not UI; it lives in this `ReaderRootScreen` extension only because iOS wires it from that screen's `.task`. Ⅳ's Mac reading surface should lift this wiring, not re-author it, into its own equivalent wiring point. |
| revert-reload wiring | `Packages/Features/Reader/Sources/Reader/Screens/ReaderRootScreen+RevertWiring.swift:1` | the reload ordering inside (`releaseEngine()` → `scoreItem` → `pdfPlayback = .idle` → `load()`) is platform-neutral logic, not UI; it lives in this `ReaderRootScreen` extension only because iOS wires it from that screen's `.task`. Ⅳ's Mac reading surface should lift this wiring, not re-author it, into its own equivalent wiring point. |
| the Reader's top-level iOS screen | `Packages/Features/Reader/Sources/Reader/Screens/ReaderRootScreen.swift:7` | self-drawn top strip, transport control, PiP host, and the note-editing chrome all assume a `UIKit`-hosted `ScoreScrollHost` subtree underneath. Ⅳ's Mac reading surface is a new screen built directly for `NSWindow` / AppKit, not a port of this one. |
| score/PDF container selection | `Packages/Features/Reader/Sources/Reader/Screens/ScoreContentView.swift:1` | exclusively picks between the iOS-only score/PDF containers (`VerticalScoreContainer`, `HorizontalScoreContainer`, `PagedScoreContainer`, `PagedPDFContainer`, `VerticalPDFContainer`) and is itself only called from the gated `ReaderRootScreen`. See the marker on that file for what Ⅳ's Mac reading surface needs. |
| UIKit scroll host | `Packages/Features/Reader/Sources/Reader/Screens/ScoreScrollHost.swift:1` | the `UIViewRepresentable` wrapper (`UIScrollView` + `UIHostingController`) every reader mode is built on. Ⅳ's Mac reading surface needs an `NSScrollView`-based host of its own instead of a port of this. |
| content-agnostic page-band surface shared by `PagedScoreContainer` and `PagedPDFContainer` | `Packages/Features/Reader/Sources/Reader/Screens/Shared/PagedReaderSurface.swift:1` | see the marker on those files for what Ⅳ's Mac reading surface needs. |
| shared scroll + pinch shell for the vertical readers, built on `ScoreScrollHost` (`UIKit`-hosted) and `PinchState` | `Packages/Features/Reader/Sources/Reader/Screens/Shared/VerticalReaderShell.swift:1` | see the markers on those files for what Ⅳ's Mac reading surface needs instead. |
| the live `PKCanvasView` / `PKToolPicker` annotation input surface | `Packages/Features/Reader/Sources/Reader/Screens/Vertical/AnnotationCanvasView.swift:1` | Ⅴ (annotation input) needs a macOS ink-input surface of its own; this iOS `UIViewRepresentable` overlay is not it. |
| one of the Reader's iOS-only layout-mode screens, built on `ScoreScrollHost` / `PinchState`. Ⅳ's Mac reading surface needs its own layout, not a port of this one | `Packages/Features/Reader/Sources/Reader/Screens/Vertical/VerticalScoreContainer.swift:5` | see the markers on those files. |
| previews of `VerticalScoreContainer` | `Packages/Features/Reader/Sources/Reader/Screens/Vertical/VerticalScoreContainerPreviews.swift:1` | see the marker on that file for what Ⅳ's Mac reading surface needs. |
| the hosted score subtree for `VerticalScoreContainer` | `Packages/Features/Reader/Sources/Reader/Screens/Vertical/VerticalZoomedSurface.swift:1` | see the marker on that file for what Ⅳ's Mac reading surface needs. |
| `repeatAB` A–B icon asset | `Packages/Features/Reader/Sources/Reader/Views/RepeatModePicker.swift:51` | iOS-only in the catalog (no SF Symbol matches it either), so this falls back to a stand-in system symbol on macOS. Ⅳ's Mac reading surface should add a macOS-enabled asset when it builds this control for real. |
| A–B repeat row glyph | `Packages/Features/Settings/Sources/Settings/Screens/ReaderModeSettingRows.swift:52` | iOS rasterizes because a Menu row will not draw a custom View; the Mac menu has no such restriction, so the two branches are expected to stay different. |
| version-history row background | `Packages/Features/Settings/Sources/Settings/VersionHistory/VersionHistoryScreen.swift:97` | iOS uses the grouped-list "secondary system background" gray, a raised card on top of the grouped-list base. macOS substitutes `.underPageBackgroundColor`, a provisional pick until Reader's own port settles what a Mac grouped surface should read as. |
| feedback mail composer | `Packages/Features/Settings/Sources/Settings/Views/FeedbackMailView.swift:3` | macOS has no MessageUI. The Mac path is an `NSWorkspace.open` of a `mailto:` URL built from the same subject and body; until then `canSendMail` is false and the row disables itself, exactly as on an iPhone with no mail account configured. |
| loop-bounds mapping | `Packages/Infrastructure/Sources/Audio/LivePlaybackController+LoopBounds.swift:1` | depends on the gated LivePlaybackController; ports once that type does. |
| note preview forwarding | `Packages/Infrastructure/Sources/Audio/LivePlaybackController+Preview.swift:1` | depends on the gated LivePlaybackController; ports once that type does. |
| soundfont-reload rebuild | `Packages/Infrastructure/Sources/Audio/LivePlaybackController+Reload.swift:1` | depends on the gated LivePlaybackController; ports once that type does. |
| transpose forwarding | `Packages/Infrastructure/Sources/Audio/LivePlaybackController+Transpose.swift:1` | depends on the gated LivePlaybackController; ports once that type does. |
| live playback controller | `Packages/Infrastructure/Sources/Audio/LivePlaybackController.swift:1` | macOS needs the AVAudioSession-free equivalent (no session category, NSImage-backed now-playing artwork, and CoreAudio default-device observation in place of route notifications). |
| offline audio export | `Packages/Infrastructure/Sources/Audio/LiveScoreAudioExporter.swift:1` | macOS needs the AVAudioSession-free equivalent of `.hostManaged` export. |
| output-route disconnect watcher | `Packages/Infrastructure/Sources/Audio/OutputRouteDisconnectWatcher.swift:1` | macOS needs CoreAudio default-device-change observation in place of `AVAudioSession.routeChangeNotification`. |
| system share sheet | `Packages/Utility/Sources/UtilityUI/ActivityViewControllerRepresentable.swift:1` | macOS needs an NSSharingServicePicker equivalent, wired into ScoreShareTarget's call sites. |
| screen corner radius | `Packages/Utility/Sources/UtilityUI/Device+CornerRadius.swift:21` | DeviceKit has no macOS device geometry to read, so `screenCornerRadius` returns 0 there. Revisit only if a Mac window ever needs concentric corner nesting against real display bezel geometry. |
| per-screen light/dark scoping | `Packages/Utility/Sources/UtilityUI/HostingAppearance.swift:53` | macOS would set NSAppearance on the hosting view instead of UITraitOverrides. |
| interactive pop gesture | `Packages/Utility/Sources/UtilityUI/InteractivePopGestureEnabler.swift:3` | no macOS analogue; the modifier is a no-op there. Revisit only if the Mac shell ever adopts a navigation stack with a swipe-back affordance. |
| toolbar placement and title display mode | `Packages/Utility/Sources/UtilityUI/PlatformToolbarCompat.swift:3` | these substitute neutral macOS behavior so shared screens compile. Ⅲb migrates each call site to a semantic placement (.cancellationAction / .confirmationAction), which is what actually earns Esc / Return key equivalents on a Mac sheet. |
| list reordering and deletion | `Packages/Utility/Sources/UtilityUI/PlatformToolbarCompat.swift:65` | the sheets that call this show no reorder handle and no delete minus on macOS. AppKit reorders by drag with no edit mode at all, so the fix is an affordance, not a port. |
| window-coordinate frame probe | `Packages/Utility/Sources/UtilityUI/WindowFrameReader.swift:35` | macOS needs the NSView equivalent before any Mac code can measure across view trees. |
| window top safe-area probe | `Packages/Utility/Sources/UtilityUI/WindowSafeAreaReader.swift:47` | macOS needs an NSView/NSWindow-backed equivalent that reads `NSWindow.contentView?.safeAreaInsets.top` before any Mac screen can report it. |

<!-- /generated:parity -->
