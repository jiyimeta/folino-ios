# "VocalTunerで音程確認" — folino-side design

**Scope:** the sending side only. The cross-app wire contract and everything VocalTuner has to build live in
`~/Desktop/vocaltuner-open-score-handoff.md` — deliberately outside both repos, since it belongs to neither and
is handed to a separate VocalTuner session (same convention as `folino-open-score-companion-handoff.md`, the
brief for the inbound direction). This document covers what changes inside this repo.

## Goal

The share menu — reachable from a library row's ellipsis/context menu and from the reader toolbar — gains one row
above the file formats, separated by a divider:

```
  VocalTunerで音程確認
  ─────────────────────
  MuseScore 4
  MuseScore 3
  PDF
  MIDI
  M4A
```

Tapping it hands the score to VocalTuner so the user can check their pitch against it. VocalTuner already sends
scores the other way; this closes the loop.

The label is **fixed in every state**. It never changes to "Get VocalTuner" or similar — the row always reads as
the thing the user wants to do, and folino picks the best available way to get there.

## Behavior

Three states, mirroring VocalTuner's shipped `FolinoAvailability`:

| State | How it's detected | Tap behavior |
| --- | --- | --- |
| `notInstalled` | `canOpenURL("vocaltuner://")` is false | Presents VocalTuner's App Store page in-app (`SKStoreProductViewController`, app id `1505735245`, campaign token `folino-share-menu`) |
| `installedLegacy` | Opens, but `vocaltuner/capabilities.json` is missing or `protocolVersion < 1` | Prepares the `.mscz` and presents the ordinary system share sheet, from which the user picks VocalTuner |
| `installedHandoffCapable` | Stamp present with `protocolVersion >= 1` | Stages the `.mscz` in the shared App Group and opens `vocaltuner://open-score?token=…` — one tap |

`installedLegacy` is not a hypothetical: it is every VocalTuner build shipped today, and it is the state folino
lives in until the VocalTuner side lands. The share-sheet fallback is what makes shipping folino's half first
safe.

The file sent is **always `.mscz` (MuseScore 4)**, for every item including PDF-sourced ones. It carries full
pitch information and is in VocalTuner's accepted extension set. Items whose only real content is a PDF will
produce a thin `.mscz` — that is the same behavior the MuseScore rows in this very menu already have, so the row
is not special-cased.

## Structure

The interesting constraint is that the menu lives in `ScoreUI` (Domain + Utility only) while the hand-off needs
UIKit, StoreKit, and the App Group container. Nothing new is needed to bridge that — the existing layering
already has the right shapes:

**`Packages/Domain`** — `VocalTunerHandoff` protocol plus `VocalTunerAvailability` and its pure
`resolve(canOpenVocalTuner:capabilities:)`. This is all the Feature packages ever see, and the resolve function
is the part worth unit-testing.

**`Packages/Features/ImportExport/Sources/ImportExportAppGroup`** — already the home of the cross-app contract
(`SharedScorePaths`, `IncomingScoreIntent`, `FolinoCapabilities`). It gains the outbound half: the
`IncomingScoresVT/` paths, `VocalTunerCapabilities` (decode side), and `OutgoingScoreStager` — a pure-FileManager
mirror of VocalTuner's `FolinoHandoffStager`, so the write path is testable without a device.

**`App/`** — `LiveVocalTunerHandoff`, the only place that touches `UIApplication.canOpenURL`,
`UIApplication.open`, and `SKStoreProductViewController`. The composition root already wires every other adapter
and already lists `vocaltuner` in `LSApplicationQueriesSchemes`.

**`Packages/ScoreUI`** — `ShareFormatMenuItems` and `ShareSubmenu` take a new
`companionAction: (() -> Void)? = nil`. When non-nil the row and a `Divider()` render above the formats. Because
both Library and Reader already build their menus from these two views, one change puts the row in both places
with no Feature → Feature dependency.

**View models** — `LibraryViewModel` and `ReaderViewModel` take `VocalTunerHandoff` by constructor injection
(Reader keeps its `NoopScoreServices` default so previews and tests need no extra argument). Both run the same
three-branch logic, and the `installedLegacy` fallback reuses the existing `shareTarget = ScoreShareTarget(...)`
path rather than introducing a second share presentation.

## Analytics

One new event in the Domain catalog:

```
companion_handoff
  target  = "vocaltuner"
  outcome = "deep_link" | "share_fallback" | "app_store" | "failed"
  source  = AnalyticsSource   // score_row_menu | reader_overlay
```

Logged on outcome rather than on tap, matching how `share` is instrumented today (logged once the URL is actually
prepared, not on intent). `outcome` is what makes the event worth having: it separates "the user wants this"
from "the user could actually have it", which is the number that decides whether the VocalTuner side was worth
building.

## Testing

- `VocalTunerAvailability.resolve` — the three states, plus a stamp with a too-low `protocolVersion`, as pure
  value tests.
- `OutgoingScoreStager` — directory layout, `originalName` derivation from a title needing sanitization, and
  re-staging over an existing token directory.
- `LibraryViewModel` / `ReaderViewModel` against a fake `VocalTunerHandoff` — each of the three branches reaches
  the right effect (App Store presented / deep link taken / `shareTarget` populated) and emits the matching
  `companion_handoff` outcome.

Feature tests use hand-written fakes as usual; nothing here touches a real App Group or UIKit in test.

## Out of scope

- The VocalTuner receiving side (separate session, see the contract document).
- Android. The share sheet there is a different surface and VocalTuner is iOS-only.
- Any change to folino's existing inbound `IncomingScores/` path.
