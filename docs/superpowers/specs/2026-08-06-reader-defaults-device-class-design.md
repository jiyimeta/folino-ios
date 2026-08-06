# Device-class Reader defaults, and two untouched-preference divergences

Date: 2026-08-06
Status: approved, ready for an implementation plan

## Problem

Two unrelated-looking things land together because they touch the same seam — what an untouched
(`nil`) per-score Reader preference resolves to.

**1. The defaults are wrong for narrow devices.** The Reader honors a score's authored
`<LayoutBreak>` markup by default, which reproduces the engraver's system and page boundaries. On a
phone that is the wrong call: the score was engraved for a page far wider than the viewport, so
honoring its breaks leaves the staves cramped and the right margin empty. The staff-size defaults
are also inherited from the era before the two platforms were tuned against real devices — iOS
seeds 14 everywhere, Android seeds 28 (which is `ReaderPreferences.maxStaffSize`, the ceiling).

**2. Two resets still persist an explicit default instead of clearing.** The 2026-08-05
"untouched is `nil`" work (`ee82e03f`) made `staffSize` / `honorLayoutBreaks` / `masterVolume` /
`transposeSemitones` Optional, and converted the master-volume, transpose and A4 reset affordances
to write `nil`. Two were missed:

- **Tempo.** `PlaybackInspectorSheet.kt:420` (tap the BPM readout) and `:452` (double-tap the rate
  slider) both call `onRate(1.0f)`, which persists an explicit `1.0`. iOS's
  `TempoModel.resetMultiplier()` writes `nil`, and iOS's `commitMultiplier` additionally snaps
  `|v − 1| < 0.005` to `nil` so a slider that stops just shy of centre doesn't leave an override
  behind. Android has neither. No user-visible effect (both resolve to 1.0), but `score_prefs`
  reports `tempo_multiplier_pct: 100` for scores the user reset — the same over-reporting that
  `d67732de` fixed for A4.
- **Staff size on Android.** `DisplayInspectorSheet.kt:386` resets to a hardcoded `28.0`. That is
  not just "explicit instead of untouched": it ignores the global default entirely, so once the
  global moves (which this spec does), double-tapping the slider jumps to a number nothing else in
  the app uses. That one *is* user-visible.

## Values

| | phone | tablet |
|---|---|---|
| iOS `staffSize` | **12** | **14** (unchanged) |
| Android `staffSize` | **21** | **24** |
| `honorLayoutBreaks` (both platforms) | **false** | **true** (unchanged) |

The staff-size numbers are not comparable across platforms: Android renders at a fixed layout
density (`LAYOUT_DP_PER_MM`), so the same millimetre value engraves at a different apparent size.
Each platform's pair was chosen by eye on that platform.

### Device class

Fixed per device, not per window:

- **iOS** — `UIDevice.current.userInterfaceIdiom == .pad` is a tablet; everything else is a phone.
- **Android** — `Configuration.smallestScreenWidthDp >= 600` is a tablet.

Deliberately *not* the live window width (`horizontalSizeClass`, current `windowWidthDp`). A
default resolved from live width flips as the user rotates the device or resizes a Split View, and
because it is what `nil` resolves to, every untouched score would re-engrave underneath them. The
cost of the fixed rule is that a genuinely narrow window on a tablet (iPad Slide Over, a 1/3 Split
View) still gets the tablet defaults. That is the accepted trade-off: a default that is
occasionally too generous beats one that moves while the user is reading.

## Design

### Domain (shared)

`effectiveHonorLayoutBreaks` becomes caller-resolved, matching the shape `staffSize` already has:

```swift
// before
public var effectiveHonorLayoutBreaks: Bool { honorLayoutBreaks ?? Self.defaultHonorLayoutBreaks }
// after
public func effectiveHonorLayoutBreaks(default defaultValue: Bool) -> Bool {
    honorLayoutBreaks ?? defaultValue
}
```

`ReaderPreferences.defaultHonorLayoutBreaks` is **deleted**. Leaving it would leave a live path that
resolves an untouched value against a static default — exactly the mistake this change exists to
remove, and one that compiles silently.

The values themselves stay out of Domain. Domain is compiled for both platforms, and the two
platforms disagree on the numbers; the composition root of each supplies them, which is already how
`effectiveStaffSize(default:)` works.

**Frozen, and not touched by this change:**

- `ReaderPreferences.LegacyStoredDefaults` (`staffSize: 14`, `honorLayoutBreaks: true`,
  `masterVolume: 1`, `transposeSemitones: 0`)
- the v16 SQL migration's literals (`CASE WHEN staff_size = 14 …`, `CASE WHEN
  honor_layout_breaks = 1 …`)

Both describe *what the data was when it was written*. A migration that chases the live defaults
stops describing its own input.

### iOS

- New internal `ReaderDeviceDefaults` in the Reader package: `staffSize` and `honorLayoutBreaks`
  derived from the idiom. It is a screen-level concern, so it lives beside `ReaderRootScreen`, not
  in Domain.
- `ReaderRootScreen.init` resolves both and injects them into `ReaderViewModel`. This retires the
  `let initialDefault: Double = 14 // TBD: device-class override (follow-up)` placeholder.
- `ReaderViewModel` gains `defaultHonorLayoutBreaks` alongside `defaultStaffSize` and assigns it
  into `LayoutSettingsModel` at wiring time (`ReaderViewModel.swift:245`).
- `LayoutSettingsModel.effectiveHonorLayoutBreaks` reads the injected value instead of the deleted
  Domain constant.

Default parameter values on `ReaderViewModel.init` and `LayoutSettingsModel` move from `14` to the
phone pair (`12` / `false`) so an un-updated call site (tests, previews) gets the narrower layout
rather than a stale one.

### Android

The wire gains two things, so this requires the usual Gradle wirelet codegen → `.so` rebuild →
`assembleDebug` ordering.

- New `ReaderDeviceDefaults.kt` reading `smallestScreenWidthDp`.
- `SettingsPrefs.staffSize`'s `?: 28.0` fallback and `MainActivity.kt:577`'s
  `collectAsState(initial = 28.0)` both become the device default.
- **`open(scoreId:defaultStaffSize:defaultHonorLayoutBreaks:)`** — the bridge retains the new
  argument and uses it in `republish()`, exactly as it already retains `openDefaultStaffSize`. The
  wire stays a resolved scalar projection; Compose still never sees an Optional.
- **`clearStaffSize()`** — a new verb next to `clearMasterVolume` / `clearTranspose`, wired to the
  staff-size slider's double-tap in `DisplayInspectorSheet.kt:386`. An explicit verb (rather than a
  `0` sentinel through `setStaffSize`) matches the two verbs already there.
- `LayoutOptions.DEFAULT` keeps `28.0` / `true`. It is not the preference default — it is the
  placeholder `ReaderViewModel._layoutOptions` starts from, the layout `PdfScoreRenderer` exports
  with, and the base the screenshot scenes `.copy()` from. PDF export should not re-engrave
  according to the phone it was triggered from. Its doc comment currently claims it matches the
  SettingsPrefs defaults and must be rewritten to say what it actually is. `_layoutOptions`'s
  initial value is seeded from the device default instead, so the Reader doesn't render one frame
  at 28 before settling.
- `SettingsKeys.honorBreaks` and `SettingsPrefs.setHonorBreaks` are deleted. They were added in
  `db9ca50e` and have never been written or collected; leaving a dead global next to a real
  device-class default invites someone to wire the wrong one.

### Fix 1 — tempo reset

`ReaderPreferencesReducer.setTempoMultiplier` gains iOS's snap:

```swift
c.tempoMultiplier = (v == 0 || abs(v - 1.0) < 0.005) ? nil : v
```

`0` stays the wire's "no override" sentinel; the new clause is the parity with
`TempoModel.commitMultiplier`. Because both Android reset affordances already route through
`onRate(1.0f)` → `setTempoMultiplier(1.0)`, the snap makes them clear the override with **no new
wire verb** — and it simultaneously fixes a slider that stops at 0.9999 leaving an override behind.

This makes an explicit `1.0` unrepresentable on Android. That is correct parity: it is
unrepresentable on iOS too.

The reducer's header comment states that `set…` verbs always record an explicit choice and only
`clear…` verbs write untouched. The snap is a deliberate exception and must be documented as such
at the call site, or the next reader will "fix" it back.

### Fix 2 — Android legacy blob staff-size demotion

`ReaderPreferencesReducer.decode(_:defaultStaffSize:)` demotes a legacy (pre-`schemaVersion`) blob's
`staffSize` to untouched when it equals the *live* global default. That was written when the live
global was the only value a legacy seed could hold. Once the global becomes 21/24, the comparison is
wrong in both directions:

- A legacy blob holding `28` no longer matches, so **every score an existing Android user has ever
  opened stays pinned at an explicit 28 forever** — the precise outcome the demotion exists to
  prevent.
- On a tablet the live default becomes `24`, so a user who *deliberately* dragged a score to 24
  before this release gets it silently reclassified as untouched. That is a new data loss the
  current code does not have.

So the comparison moves to a frozen constant:

```swift
/// What Android's since-removed eager seed wrote for an untouched staff size. `SettingsPrefs`'
/// `staffSize` key has existed since `db9ca50e` but `setStaffSize` has never been called, so the
/// global was 28.0 for every build that wrote a legacy blob. Frozen for the same reason
/// `LegacyStoredDefaults` is.
private enum LegacyAndroidSeed { static let staffSize: Double = 28 }
```

The two `decode` overloads merge into a single `decode(_:)` that applies the frozen correction —
there is no longer a caller that knows something the function doesn't, which is the only reason the
parameterized overload existed. `AnalyticsBridge.scorePrefs` drops its
now-unused `defaultStaffSize` parameter (`AnalyticsBridge.swift:322`), which also drops the
`prefs.staffSize.first()` read at `MainActivity.kt:350`.

The accepted trade-off is unchanged from the shipped behavior: a user who deliberately chose 28 (the
slider maximum) on a legacy blob is reclassified as untouched. That was already true when 28 was the
live default, so this is not a regression.

## What existing users see

All of this is intended.

- **iPhone** — untouched scores drop from staff size 14 to 12, and stop honoring authored line and
  page breaks: measures now wrap to the viewport width. This is a visible re-engraving for every
  iPhone user who never opened the Display inspector.
- **Android phone** — 28 → 21, plus the same break-policy change.
- **Android tablet** — 28 → 24. Break policy unchanged.
- **iPad** — nothing changes.

A user who explicitly set either value keeps it: that is what the 2026-08-05 Optional work bought,
and it is why this change can move the defaults at all.

## Testing

- **Domain** — `effectiveHonorLayoutBreaks(default:)` returns the injected default when `nil` and
  the stored value (including one equal to the default) when set.
- **Reducer** — tempo snap boundaries (`1.0`, `0.9999`, `1.004` → `nil`; `1.01`, `0.5` → explicit;
  `0` still → `nil`); `clearStaffSize` writes `nil` and survives the `reseat` round-trip; legacy
  decode demotes `28.0` and leaves `21` / `24` / any v2 blob alone.
- **Bridge** — `open(defaultHonorLayoutBreaks:)` reaches `republish()`; an untouched row projects
  the injected defaults for both fields; an explicit row projects its own values.
- **iOS Reader** — extend `ReaderUntouchedPreferencesTests` so injecting a phone default and a
  tablet default produces different `effectiveHonorLayoutBreaks` from the same untouched row, and
  neither marks the row touched on the next save.
- **Manual** — open a score on an Android phone and on a tablet (or an emulator pinned to
  `sw600dp`) and confirm each gets its own defaults; confirm the staff-size double-tap lands on the
  device default rather than 28.

## Out of scope

- `hasStaffBoundOverrides` reading raw `hiddenStaves` (an authored-hidden-only score reads as
  staff-bound and triggers the PDF re-read warning). Still open, still needs a product call.
- Making the Android global staff size user-settable. `SettingsPrefs.staffSize` stays a
  device-derived constant with no UI.
- Any change to `LayoutOptions.DEFAULT`'s values, and therefore to PDF export or the screenshot
  scenes.

No `PARITY(android)` marker is warranted: both platforms land together.
