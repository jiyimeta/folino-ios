# iOS 18 Support — Design

**Date:** 2026-07-21
**Status:** Approved for implementation (autonomous directive; worktree `worktree-ios18-support`)

## Goal

Lower Folino's minimum deployment target from **iOS 26.0** to **iOS 18.0** so the app installs and
runs on iOS 18 devices, while preserving the existing Liquid Glass experience unchanged on iOS 26+.

## Constraints & context

- The codebase is written for iOS 26 with **zero** existing availability guards
  (`#available(iOS 26)` / `@available(iOS 26)` count = 0). The deployment target alone gates every
  iOS 26 API today.
- All current users run iOS 26 (the app is iOS 26+ today). Stripping Liquid Glass would be a visible
  regression for every existing user, so the design keeps glass on 26 and only substitutes on 18.
- Dependency floor is clear: `swift-sheet-music` targets `.iOS(.v17)`; GRDB, Firebase, LicenseList,
  SwiftLintPlugins all support iOS 18 or lower. **No dependency blocks iOS 18.**
- `App/`, `Domain`, `Utility`, `Infrastructure`, `ScoreUI`, `Editor`, `Settings` contain **no**
  iOS 26-only API calls. The app shell (`NavigationSplitView` / `NavigationStack` / `.topBarTrailing`
  toolbars) is already iOS-18-clean.

## iOS 26-only API inventory (ground truth)

15 call sites across 7 files — all in Reader / Library / ImportExport:

| # | File:line | API | iOS 18 fallback |
|---|---|---|---|
| 1–6 | `Reader/Screens/ReaderTopOverlay.swift` :46,61,63,80,82,117 | `.glassEffect(.regular.interactive())` | `.background(.regularMaterial, in: Capsule())` |
| 7 | `Reader/Screens/ReaderTransportControl.swift:151` | `.glassEffect(.regular, in: shape)` (UnevenRoundedRectangle) | `.background(.regularMaterial, in: shape)` |
| 8 | `Reader/Screens/ReaderTransportControl.swift:209` | `.glassEffect(.regular.interactive())` | `.background(.regularMaterial, in: Capsule())` |
| 9 | `Reader/Views/ABEndpointPill.swift:35` | `.glassEffect(.regular.interactive(), in: .capsule)` | `.background(.regularMaterial, in: .capsule)` |
| 10–11 | `Library/Views/BulkActionBar.swift:25,35` | `.glassEffect(.regular.interactive())` | `.background(.regularMaterial, in: Capsule())` |
| 12–13 | `ImportExport/…/ShareRootView.swift:61,245` | `.buttonStyle(.glassProminent)` | `.buttonStyle(.borderedProminent)` |
| 14 | `Library/Views/ScoreListView.swift:118` | `ToolbarSpacer(.fixed, placement:)` | omit (guard out) |
| 15 | `Reader/Screens/PDF/PDFPlaybackNotice.swift:29` | `Button(role: .confirm)` | `Button(role: nil)` (default) |

No `GlassEffectContainer` / `glassEffectID` / morphing anywhere → every glass site is standalone and
can be substituted independently. The codebase already uses `.background(.regularMaterial, in: …)` and
`.background(.quaternary, in: .capsule)` fallbacks elsewhere, so the substitute is idiomatic.

## Approach: availability-guarded compat helpers in `UtilityUI`

Centralize the `if #available(iOS 26, *)` branching in a small set of `View` extensions in
`Packages/Utility/Sources/UtilityUI/` (reachable from every layer; Reader/Library/ImportExport already
`import UtilityUI`). Call sites become one-liner helper calls instead of inline `#available` ladders.

Helpers (final signatures decided during implementation with the fable advisor's cheat-sheet):

```swift
public extension View {
    // .glassEffect(.regular.interactive())  — default Capsule, matching glassEffect's default shape
    @ViewBuilder func interactiveGlassCompat() -> some View
    @ViewBuilder func interactiveGlassCompat<S: Shape>(in shape: S) -> some View

    // .glassEffect(.regular, in: shape)  — non-interactive, explicit shape
    @ViewBuilder func regularGlassCompat<S: Shape>(in shape: S) -> some View

    // .buttonStyle(.glassProminent)
    @ViewBuilder func glassProminentButtonStyleCompat() -> some View
}
```

Each helper: iOS 26+ branch calls the real Liquid Glass API; else branch applies the material fallback.
The `Glass` value type and `GlassProminentButtonStyle` (both iOS 26-only) appear **only inside** the
`if #available(iOS 26, *)` branch, so the helper itself compiles at the iOS 18 floor.

Two sites are guarded inline rather than via a `View` helper because they aren't `View` modifiers:
- `ToolbarSpacer` lives in a `@ToolbarContentBuilder` → `if #available(iOS 26, *) { ToolbarSpacer(…) }`.
- `Button(role: .confirm)` lives in an `.alert { }` action builder → `if #available(iOS 26, *) { … }
  else { Button { … } label: { … } }`.

**Fallback material choice:** `.regularMaterial` for the floating pills/bars/cards (frosted, reads as
"floating over the score", matching the glass intent). The transport card at
`ReaderTransportControl.swift:151` keeps its existing shadow. The `ABEndpointPill` `flat` branch already
uses `.quaternary` and is unchanged. Exact per-site material is confirmed against the fable advisor's
cheat-sheet and reviewed on the iOS 18 simulator; iOS 26 rendering is untouched.

## Deployment target changes

- `project.yml`: `deploymentTarget.iOS: 26.0` → `18.0`.
- 9 `Package.swift` files: `.iOS(.v26)` → `.iOS(.v18)` (leave `.macOS(.v14)` entries as-is in Domain
  and Library).
- Regenerate `Folino.xcodeproj` via `xcodegen generate`.

## Verification

1. **Availability sweep (no iOS 18 sim needed):** build the app with the iOS 26 simulator destination
   after lowering the target — availability errors are emitted from the *deployment target*, not the
   SDK/sim OS, so every iOS 26 API misuse surfaces here. Iterate edit → build until the build is clean.
2. **Per-package build:** the app build increment-skips unchanged packages and can report a false
   SUCCEEDED, so additionally build the edited feature/utility package schemes directly (Utility,
   Reader, Library, ImportExport) and confirm real recompilation.
3. **iOS 26 regression:** the same build proves the iOS 26 path still compiles; the `#available` true
   branch preserves the original glass calls verbatim.
4. **iOS 18 runtime smoke (needs the iOS 18 sim the user is creating):** install on the iOS 18
   simulator, launch, open a score in Reader, toggle annotation, open the bulk-action bar, open the
   share sheet — confirm the material fallbacks render and nothing crashes on the missing iOS 26 APIs.

## Out of scope

- No release / App Store submission — this only adds iOS 18 support and installs on a sim.
- No visual redesign of the iOS 18 fallbacks beyond a faithful material substitute.
- No change to the iOS 26 experience.

## Risks & de-risk

- **Unknown iOS 26 API surface beyond the inventory:** the min-18 compile is ground truth — any missed
  site fails the build and gets guarded in the same loop. Low risk given the thorough inventory (15
  sites, all glass/toolbar/role, no morphing).
- **Fallback taste on iOS 18:** confined to iOS 18; iOS 26 unaffected; reviewed on-sim before finishing.
- **Subagent worktree-path hazard:** implementation runs in the worktree with absolute paths; commits
  are made by the orchestrator, not the implementer subagent.
