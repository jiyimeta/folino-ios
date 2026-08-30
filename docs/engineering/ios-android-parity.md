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
| system share sheet | `Packages/Utility/Sources/UtilityUI/ActivityViewControllerRepresentable.swift:5` | macOS needs an NSSharingServicePicker equivalent, wired into |
| screen corner radius | `Packages/Utility/Sources/UtilityUI/Device+CornerRadius.swift:21` | DeviceKit has no macOS device geometry to read, so |
| per-screen light/dark scoping | `Packages/Utility/Sources/UtilityUI/HostingAppearance.swift:53` | macOS would set NSAppearance on the hosting view instead of |
| interactive pop gesture | `Packages/Utility/Sources/UtilityUI/InteractivePopGestureEnabler.swift:6` | no macOS analogue; the modifier is a no-op there. Revisit only if the |
| window-coordinate frame probe | `Packages/Utility/Sources/UtilityUI/WindowFrameReader.swift:35` | macOS needs the NSView equivalent before any Mac code can measure |

<!-- /generated:parity -->
