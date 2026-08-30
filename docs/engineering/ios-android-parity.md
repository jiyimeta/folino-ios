# iOS / Android parity ledger

Folino ships on two platforms, and one of them regularly lands a feature first.
This file records what is **deliberately** owed to the other platform, so a
half-crossed feature is a tracked debt rather than something rediscovered months
later by a user.

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

Format: `PARITY(<platform>): <title> — <what the other platform still needs>`,
where `<platform>` is the platform the work is **owed to**. The separator is an
em dash (` -- ` also works). A continuation line repeats the comment token and
indents.

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
| note editing in page mode | `Android/FolinoReaderAndroid/src/main/kotlin/com/keynumber/folino/reader/ReaderScreen.kt:1195` | editing is offered on the vertical surface only. iOS edits in every layout mode (`ReaderRootScreen` has no mode gate); Android's horizontal/page surface routes its taps through a separate paged-fetch path that would need its own hit-test, caret and tint wiring. Entering edit mode from page mode is refused rather than silently doing nothing. |
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
| A–B repeat row glyph | `Packages/Features/Settings/Sources/Settings/Screens/ReaderModeSettingRows.swift:52` | iOS rasterizes because a Menu row will not draw a custom View; the Mac menu has no such restriction, so the two branches are expected to stay different. |
| version-history row background | `Packages/Features/Settings/Sources/Settings/VersionHistory/VersionHistoryScreen.swift:93` | iOS uses the grouped-list "secondary system background" gray; macOS substitutes the window background color, the platform's closest system-provided neutral fill. |
| feedback mail composer | `Packages/Features/Settings/Sources/Settings/Views/FeedbackMailView.swift:3` | macOS has no MessageUI. The Mac path is an `NSWorkspace.open` of a `mailto:` URL built from the same subject and body; until then `canSendMail` is false and the row disables itself, exactly as on an iPhone with no mail account configured. |
| loop-bounds mapping | `Packages/Infrastructure/Sources/Audio/LivePlaybackController+LoopBounds.swift:1` | depends on the gated LivePlaybackController; ports once that type does. |
| note preview forwarding | `Packages/Infrastructure/Sources/Audio/LivePlaybackController+Preview.swift:1` | depends on the gated LivePlaybackController; ports once that type does. |
| soundfont-reload rebuild | `Packages/Infrastructure/Sources/Audio/LivePlaybackController+Reload.swift:1` | depends on the gated LivePlaybackController; ports once that type does. |
| transpose forwarding | `Packages/Infrastructure/Sources/Audio/LivePlaybackController+Transpose.swift:1` | depends on the gated LivePlaybackController; ports once that type does. |
| live playback controller | `Packages/Infrastructure/Sources/Audio/LivePlaybackController.swift:1` | macOS needs the AVAudioSession-free equivalent (no session category, NSImage-backed now-playing artwork, and CoreAudio default-device observation in place of route notifications). |
| offline audio export | `Packages/Infrastructure/Sources/Audio/LiveScoreAudioExporter.swift:1` | macOS needs the AVAudioSession-free equivalent of `.hostManaged` export. |
| output-route disconnect watcher | `Packages/Infrastructure/Sources/Audio/OutputRouteDisconnectWatcher.swift:1` | macOS needs CoreAudio default-device-change observation in place of `AVAudioSession.routeChangeNotification`. |
| edit-info sheet title display mode | `Packages/ScoreUI/Sources/ScoreUI/EditScoreInfoSheet.swift:47` | no macOS analogue; navigationTitle alone sets the sheet title there. Revisit only if a Mac port wants inline-vs-large-title parity with the iOS sheet. |
| system share sheet | `Packages/Utility/Sources/UtilityUI/ActivityViewControllerRepresentable.swift:1` | macOS needs an NSSharingServicePicker equivalent, wired into ScoreShareTarget's call sites. |
| screen corner radius | `Packages/Utility/Sources/UtilityUI/Device+CornerRadius.swift:21` | DeviceKit has no macOS device geometry to read, so `screenCornerRadius` returns 0 there. Revisit only if a Mac window ever needs concentric corner nesting against real display bezel geometry. |
| per-screen light/dark scoping | `Packages/Utility/Sources/UtilityUI/HostingAppearance.swift:53` | macOS would set NSAppearance on the hosting view instead of UITraitOverrides. |
| interactive pop gesture | `Packages/Utility/Sources/UtilityUI/InteractivePopGestureEnabler.swift:3` | no macOS analogue; the modifier is a no-op there. Revisit only if the Mac shell ever adopts a navigation stack with a swipe-back affordance. |
| toolbar placement and title display mode | `Packages/Utility/Sources/UtilityUI/PlatformToolbarCompat.swift:3` | these substitute neutral macOS behavior so shared screens compile. Ⅲb migrates each call site to a semantic placement (.cancellationAction / .confirmationAction), which is what actually earns Esc / Return key equivalents on a Mac sheet. |
| window-coordinate frame probe | `Packages/Utility/Sources/UtilityUI/WindowFrameReader.swift:35` | macOS needs the NSView equivalent before any Mac code can measure across view trees. |
| window top safe-area probe | `Packages/Utility/Sources/UtilityUI/WindowSafeAreaReader.swift:47` | macOS needs an NSView/NSWindow-backed equivalent that reads `NSWindow.contentView?.safeAreaInsets.top` before any Mac screen can report it. |

<!-- /generated:parity -->
