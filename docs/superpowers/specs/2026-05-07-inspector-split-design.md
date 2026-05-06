# Inspector Split (Playback / Visual)

Reorganize the Reader's inspector pane so that playback-shaped controls and view-shaped controls live in dedicated areas. Renames `MixerView` to `InspectorView` to match the container that already hosts it (`.inspector(isPresented:)` in `ReaderView`), and pulls the staff-size buttons out of the toolbar into the new Visual area.

## Goals

- Cleanly separate **Playback** (tempo, metronome, per-staff volume / mute / solo / instrument / visibility) from **Visual** (layout direction, staff size) inside the inspector.
- Compact horizontal size class (iPhone, iPad slide-over) shows the two areas under a top segmented `Picker`.
- Regular horizontal size class (iPad) shows both areas as stacked `Section`s in a single scrolling `List` — no tab switching.
- Free up toolbar real estate by moving the `+/-` magnifying-glass buttons into Visual.

## Non-Goals

- No `ReaderViewModel` API changes. All controls bind to existing state and methods.
- No new persistence. Tab selection is session-only `@State`.
- No "system / page break-follow" UI yet — that's tracked separately. Visual stays small initially (layout + staff size).
- No file split. `InspectorView` stays one file with private `@ViewBuilder` properties for each area.
- The bottom `ReaderBottomOverlay` reset-zoom pill is unaffected — viewport zoom (pinch) is a separate axis from staff size and stays as a floating overlay.

## File / Symbol Renames

| Before | After |
| --- | --- |
| `Packages/Features/Reader/Sources/Reader/MixerView.swift` | `Packages/Features/Reader/Sources/Reader/InspectorView.swift` |
| `struct MixerView` | `struct InspectorView` |
| `MixerView(viewModel:score:)` call site in `ReaderView.swift` | `InspectorView(viewModel:score:)` |
| Doc comments referencing "MixerView" in `PreviewSupport.swift` | "InspectorView" |

## Layout

```
InspectorView
├── compact hsc:
│   VStack {
│     Picker("", selection: $selectedTab).pickerStyle(.segmented)   // Playback | Visual
│     switch selectedTab { … List(.plain) of selected tab content }
│   }
└── regular hsc:
    List(.plain) {
      Section("Playback") { playbackContent }
      Section("Visual")   { visualContent }
    }
```

- `enum InspectorTab { case playback, visual }` — view-local; `@State private var selectedTab: InspectorTab = .playback`.
- `@Environment(\.horizontalSizeClass) private var hsc` drives the branching.
- `@ViewBuilder private var playbackContent: some View` — produces the rows that go into a `List` (no surrounding `List` itself, so the same content can be embedded in either branch).
- Same for `visualContent`.
- Existing `.task(id: viewModel.effectiveTempoMultiplier)` (slider sync) and `.task { await viewModel.setMetronomeEnabled(...) }` are attached to the **outermost** container of `InspectorView` so the engine state stays in sync regardless of which tab is currently visible.

## Content Allocation

### Playback area

Unchanged from current `MixerView`, minus the layout `Picker`:

1. Master tempo + metronome row (current `tempoRow` / `tempoControls`).
2. Per-part `Section`s, each containing staff rows with: volume slider, solo (`s.circle`), mute (`m.circle`), visibility eye, instrument program picker.

The visibility eye stays on the staff row. Rationale: it's logically a visual control, but having every per-staff knob (including show/hide) on a single row is the prevailing pattern in mixer UIs and keeps the operation a single tap from the slider. The Playback / Visual divide is operational, not strictly logical.

### Visual area

1. **Layout** segmented `Picker` (`.vertical` / `.horizontal`) — moved from current `MixerView` middle.
2. **Staff size** — a `Stepper` bound to a derived `Binding<CGFloat>` (note: `ReaderPreferences.staffSize` is `CGFloat`, with `min/maxStaffSize` of 8 / 28 stepped by 1.0):

   ```swift
   let staffSize = Binding<CGFloat>(
       get: { viewModel.preferences.staffSize },
       set: { newValue in
           let current = viewModel.preferences.staffSize
           if newValue > current { Task { await viewModel.incrementStaffSize() } }
           else if newValue < current { Task { await viewModel.decrementStaffSize() } }
       }
   )
   Stepper(
       "Staff size \(Int(viewModel.preferences.staffSize))",
       value: staffSize,
       in: ReaderPreferences.minStaffSize ... ReaderPreferences.maxStaffSize,
       step: 1
   )
   ```

   The `value:in:step:` form auto-disables `+`/`-` at the bounds. `incrementStaffSize` / `decrementStaffSize` step by 1.0 and clamp internally, matching the `step: 1`, so the binding never desyncs. The label uses `Int(...)` to avoid rendering a trailing `.0`.

That's the entire Visual area for this change. It is intentionally short — break-follow lands later.

## Toolbar Diff

`Packages/Features/Reader/Sources/Reader/ReaderToolbar.swift`:

- **Remove**: `minus.magnifyingglass` button, `plus.magnifyingglass` button.
- **Keep**: play/pause, inspector toggle (`slider.horizontal.3`).
- `ReaderBottomOverlay` is unchanged.

## Tests

- No `ReaderViewModel` test changes — surface area is unchanged.
- No new view-level tests (the project doesn't have ViewInspector or snapshot tests for Reader views).
- `#Preview` in `InspectorView.swift` is updated to reflect the rename. Single preview targeting compact size class is enough; iPad regular layout is verified manually.

## Manual Verification

Run on both an iPhone simulator and an iPad simulator after the change:

- **iPhone**: open inspector, see segmented picker at top. Switching tabs preserves playback state (tempo doesn't reset, metronome doesn't toggle off, per-staff overrides remain).
- **iPad**: open inspector, see Playback section stacked above Visual section in one scrolling list — no segmented picker.
- **Staff size**: `Stepper` increments/decrements re-render the score at the new size and become disabled at `minStaffSize` / `maxStaffSize`.
- **Toolbar**: `±` magnifying-glass buttons are gone; play/pause and inspector toggle still present and functional.
- **Reset-zoom pill**: unchanged — appears at the bottom only after a pinch-zoom and dismisses to 1.0 on tap.

## Risks

- `.listStyle(.plain)` and `.environment(\.defaultMinListRowHeight, 28)` need to apply equivalently in both the compact (per-tab `List`) and regular (single combined `List`) branches. If the visual rhythm differs across branches, normalize by hoisting these modifiers onto each `List` instance.
- `Stepper` styling inside a `.plain` `List` row may look heavier than the toolbar's icon buttons. Acceptable cost for the affordance; revisit only if user testing flags it.
