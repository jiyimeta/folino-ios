# Multi-measure rest collapse toggle

## Summary

Expose `swift-sheet-music`'s multi-measure-rest collapse behavior as a global
on/off preference that the user can flip from either the Reader's Visual
Inspector or the Settings sheet. When on, two or more consecutive empty-rest
measures render as a single H-bar with a count overlay; when off (default),
each measure is drawn individually as today.

The setting is **global, not per-score**: one user-level switch that applies
to every score in the library. It rides the same `@AppStorage` /
`ReaderGlobalSettingsKey` pattern that the existing metronome, layout-mode,
and Picture-in-Picture toggles already use.

## Motivation

`swift-sheet-music` already supports collapsing consecutive multi-measure
rests via `ScoreViewOptions.multiMeasureRest =
.collapse(minimumMeasures: Int)`, but Folino never sets that option, so the
behavior is unreachable from the app. Players reading scores with long tacit
sections (concertos, ensemble parts) currently scroll through dozens of
identical empty measures. The collapse option is the standard sheet-music
convention for that situation and is what these users expect.

The setting is global because the preference is a player-ergonomics choice,
not a property of any particular score. A user who wants compact rest blocks
wants them everywhere; a user who wants every measure visible wants that
everywhere too. Per-score storage would only add UI friction with no real
benefit.

## API surface (swift-sheet-music)

- Module: `SheetMusicLayout`
- Type: `enum MultiMeasureRestPolicy { case disabled; case collapse(minimumMeasures: Int) }`
- Carrier: `ScoreViewOptions.multiMeasureRest` (defaults to `.disabled`)
- Minimum threshold clamps to 2 inside the library

For this feature we fix the threshold at **2**. The Toggle controls only
on/off; the threshold is not user-tunable in this iteration. If a future
spec needs it, expose a stepper next to the toggle.

## Storage

Add one entry to `ReaderGlobalSettingsKey` in
`Packages/Domain/Sources/Domain/Models/ReaderLayoutMode.swift`:

```swift
/// Bool. When true, runs of `minimumMeasures` or more consecutive empty-rest
/// measures render as a single H-bar with a count, using
/// `MultiMeasureRestPolicy.collapse`. When false, measures render
/// individually.
public static let collapseMultiMeasureRests = "readerCollapseMultiMeasureRests"
```

Persistence is plain `@AppStorage` on this key, mirroring the PiP and
metronome toggles. No `Domain` protocol wrapper; no `UserDefaults` adapter.
Existing users have no value set, so the default-false initializer in each
`@AppStorage` declaration is what they see — matching the desired "off by
default" behavior. No migration.

A shared constant for the threshold lives next to the existing `staffSize`
constants on `ReaderPreferences`:

```swift
public static let multiMeasureRestThreshold = 2
```

so both `Horizontal`- and `VerticalScoreContainer` reference the same value.

## UI

### Settings sheet

`Packages/Features/Settings/Sources/Settings/Screens/SettingsSheet.swift`

Add an `@AppStorage` property and a `Toggle` in `readerSection`, placed
immediately after the existing Picture-in-Picture toggle and before the
layout-mode picker:

```swift
@AppStorage(ReaderGlobalSettingsKey.collapseMultiMeasureRests)
private var collapseMultiMeasureRests = false
```

```swift
Toggle(isOn: $collapseMultiMeasureRests) {
    Label {
        Text("settings.reader.collapseMultiMeasureRests", bundle: .module)
    } icon: {
        Image(systemName: "rectangle.compress.vertical")
    }
}
```

### Visual Inspector

`Packages/Features/Reader/Sources/Reader/Screens/VisualInspectorScreen.swift`

Add an `@AppStorage` property and a new row `collapseRow` placed
immediately after `breakPolicyRow` (the closest semantic neighbor — both
control layout-time behavior):

```swift
@AppStorage(ReaderGlobalSettingsKey.collapseMultiMeasureRests)
private var collapseMultiMeasureRests = false
```

```swift
@ViewBuilder
private var collapseRow: some View {
    Toggle(isOn: $collapseMultiMeasureRests) {
        Text("reader.preferences.collapseMultiMeasureRests", bundle: .module)
    }
}
```

Inspector body order becomes: `layoutRow` → `staffSizeRow` →
`breakPolicyRow` → `collapseRow` → parts section.

### Localization keys

Match the established `module.feature.thing` scheme:

- `settings.reader.collapseMultiMeasureRests` — Settings row label
- `reader.preferences.collapseMultiMeasureRests` — Inspector row label

Both default to English "Collapse multi-measure rests". The Japanese
translation is added as part of this work using the same
`Localizable.xcstrings` editing flow used for the PiP toggle.

## Plumbing into the score renderer

`ReaderRootScreen` reads the preference once and forwards it down, in the
same shape as the existing `honorLayoutBreaks` plumbing.

`ReaderRootScreen.swift`:

```swift
@AppStorage(ReaderGlobalSettingsKey.collapseMultiMeasureRests)
private var collapseMultiMeasureRests = false
```

`ReaderRootScreen` itself instantiates `HorizontalScoreContainer` and
`VerticalScoreContainer` directly based on `layoutModeRaw` (see the
`if/else` in the body around current line 141 / 149). Forward
`collapseMultiMeasureRests` to both init sites the same way
`honorLayoutBreaks` is forwarded today.

Both containers gain a new stored input next to `honorLayoutBreaks`:

```swift
let collapseMultiMeasureRests: Bool
```

`scoreOptions` becomes:

```swift
private var scoreOptions: ScoreViewOptions {
    ScoreViewOptions(
        staffSize: staffSize, systemGap: staffSize * 1.25,
        wrapToViewWidth: /* container-specific */,
        includeTitleFrame: /* container-specific */,
        breakPolicy: honorLayoutBreaks ? .honor : .ignoreAll,
        showBreakIndicators: false,
        multiMeasureRest: collapseMultiMeasureRests
            ? .collapse(minimumMeasures: ReaderPreferences.multiMeasureRestThreshold)
            : .disabled,
    )
}
```

Both containers already define a private `TaskKey` struct that drives
`.task(id:)` for `rebuildLayout`. Add `collapseMultiMeasureRests: Bool`
as a stored field on each `TaskKey` (next to `honorLayoutBreaks`) and
include it in the call site that constructs the key. Toggling the
preference then re-triggers the existing rebuild path with no further
wiring.

`HorizontalScoreContainer.TaskKey` already exposes `init(score:size:honorLayoutBreaks:)`;
extend to `init(score:size:honorLayoutBreaks:collapseMultiMeasureRests:)`.

`VerticalScoreContainer.TaskKey` already exposes
`init(score:size:width:honorLayoutBreaks:)`; extend to
`init(score:size:width:honorLayoutBreaks:collapseMultiMeasureRests:)`.

Previews (`VerticalScoreContainerPreviews.swift`, `PreviewSupport.swift`)
must pass a value for the new init parameter — default `false` is fine.

## Why not `LayoutSettingsModel`?

`LayoutSettingsModel` is per-score: its job is to mirror `ReaderPreferences`
fields that persist into the score's row in the DB. Routing a global
preference through it would either (a) duplicate the value in every
score's `ReaderPreferences` row, which is misleading because the setting
isn't actually per-score, or (b) bypass the model's persistence layer
entirely, leaving it as a pass-through. Neither helps. The PiP and
layout-mode toggles take the global path — collapse belongs with them.

## Testing

- **Domain**: extend `ReaderLayoutModeTests` with one `#expect` asserting
  `ReaderGlobalSettingsKey.collapseMultiMeasureRests ==
  "readerCollapseMultiMeasureRests"`. Same pattern as the existing
  metronome / layout-mode / PiP key assertions.
- **Reader / Settings**: no new unit tests. Existing toggles in both
  surfaces have no toggle-level unit tests; the verification is via
  preview render and a manual simulator pass — same standard the PiP
  toggle was held to in commits `5b490d2` / `1b51ddc` / `497e1ed`.
- **Manual verification**:
  1. Render a `#Preview` of `HorizontalScoreContainer` with a score that
     has 4+ consecutive empty-rest measures, both with the flag on and
     off, via `mcp__xcode__RenderPreview`.
  2. Build, launch in the simulator, flip the toggle from Settings while
     the Reader is open in another column / sheet, and confirm the
     score re-layouts immediately (TaskKey change → rebuild).
  3. Flip the toggle from the Visual Inspector and confirm the same
     re-layout. Confirm both surfaces stay in sync (they share the same
     `@AppStorage` key).

## Out of scope

- User-controllable `minimumMeasures` threshold (fixed at 2).
- Custom gap / spacing around collapsed bars.
- Editor-side exposure — Editor uses `ScoreView` differently and is a
  separate spec if/when needed.
- `swift-sheet-music` version bump — the current pinned version already
  ships `MultiMeasureRestPolicy`.

## Risks

- **Re-layout cost**: collapsing rebuilds the entire `LayoutDocument`
  whenever the user toggles. For very long scores this is the same cost
  as flipping `honorLayoutBreaks` today and is considered acceptable.
- **Cursor positioning across collapsed bars**: `swift-sheet-music`'s
  `LayoutDocument` already drives cursor math from the collapsed layout,
  so the existing tap-to-seek (`nearestCursor`) and auto-scroll paths
  inherit the correct positions automatically. We do **not** maintain a
  parallel cursor mapping in Folino. If a regression appears here it is
  a `swift-sheet-music` bug, not a Folino layering bug.
- **PiP renderer**: `ScorePiPFrameRenderer`
  (`Packages/Features/Reader/Sources/Reader/PiP/ScorePiPFrameRenderer.swift`)
  builds its own `ScoreViewOptions` for the off-screen PiP frames. To
  keep PiP and the on-screen score visually consistent, the renderer
  must also read the same `@AppStorage` key (or be passed the bool from
  whichever object owns its lifecycle — likely `ScorePiPCoordinator`)
  and forward `multiMeasureRest` through. Worth flagging in the
  implementation plan as an explicit step rather than an afterthought.
