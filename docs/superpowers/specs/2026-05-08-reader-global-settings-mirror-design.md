# Reader global settings — mirror in Settings sheet

## Problem

Reader's Inspector panel exposes a mix of per-document settings (tempo, staff
size, layout breaks, etc.) and global settings (settings that persist across
sessions and apply to every score). Today only **metronome on/off** is wired
through `@AppStorage("readerMetronomeEnabled")`. **Layout direction
(vertical / horizontal)** is conceptually global but currently lives as a
transient `ReaderViewModel.layoutMode` property that resets to `.vertical`
each time the Reader is opened.

These two settings should also be reachable from the Settings sheet that
opens from the Library root, so users can adjust them without first opening
a score.

## Scope

In scope (mirror in Settings):

1. **Metronome on/off** — already global; add a toggle in Settings.
2. **Layout direction** — promote to global by switching to
   `@AppStorage("readerLayoutMode")`; add a picker in Settings.

Out of scope:

- Per-document settings (tempo multiplier, staff size, honor breaks, staff
  volumes, instrument programs, mute / solo).
- New "default value" infrastructure for per-document settings.
- Any backend persistence beyond `UserDefaults`.

## Design

### Domain — lift the enum and key constants

Move `ReaderViewModel.LayoutMode` out of the Reader feature into Domain as a
top-level `ReaderLayoutMode` enum (`String, CaseIterable, Sendable, Hashable`).
This lets Settings reference the same type without an illegal Feature →
Feature dependency. Settings already imports Domain.

Co-locate the two `@AppStorage` key constants in the same Domain file so the
keys are not duplicated as string literals across packages:

```swift
public enum ReaderGlobalSettingsKey {
    public static let metronomeEnabled = "readerMetronomeEnabled"
    public static let layoutMode = "readerLayoutMode"
}
```

(Key string for metronome is unchanged from the existing AppStorage to
preserve user state across this refactor.)

### Reader — switch layoutMode to @AppStorage, fold metronome push into the screen

- Delete `ReaderViewModel.layoutMode` and `Packages/Features/Reader/Sources/Reader/ReaderLayoutMode.swift`.
- `ReaderView` (screen root): own
  `@AppStorage(ReaderGlobalSettingsKey.layoutMode) layoutModeRaw: String`
  and translate to `ReaderLayoutMode`. Drive the existing
  `switch viewModel.layoutMode { … }` rendering branch from this storage
  instead.
- `ReaderView`: own
  `@AppStorage(ReaderGlobalSettingsKey.metronomeEnabled) isMetronomeEnabled: Bool`.
  On `.onChange(of: isMetronomeEnabled)` and once in `.task`, call
  `viewModel.setMetronomeEnabled(_:)`. This is the critical iPad fix: when
  the user toggles metronome from the Settings sheet while a Reader detail
  pane is alive in the same scene, the running playback engine still picks
  up the change.
- `InspectorView`: keep the metronome icon button and the layout picker, but
  bind both to the same `@AppStorage` keys (no longer through the view
  model). Drop the `.task { setMetronomeEnabled }` bootstrap (now lives on
  `ReaderView`).

### Settings — new "Reader" section

Add a `Section { … } header: { Text("Reader", …) }` above Storage in
`SettingsSheet`:

- Toggle bound to `@AppStorage(ReaderGlobalSettingsKey.metronomeEnabled)`.
- Picker bound to `@AppStorage(ReaderGlobalSettingsKey.layoutMode)`,
  presenting `ReaderLayoutMode.allCases` with the same SF Symbol icons
  (`arrow.up.and.down`, `arrow.left.and.right`) the Inspector uses.

Localize new labels in `Packages/Features/Settings/.../Localizable.xcstrings`:
"Reader", "Metronome", "Layout direction".

### iPad concurrent-screen behavior

- Both Reader and Settings observe the same `UserDefaults` keys via
  `@AppStorage`; SwiftUI re-renders both when either writes.
- Layout direction is pure View-state, so re-render is the only side effect
  needed.
- Metronome has an engine side effect; the new `ReaderView.onChange` ensures
  the playback engine is reconfigured even when the user toggled from
  Settings rather than the Inspector.

## Verification

- Open Settings from Library, toggle metronome off → open a score → press
  play → no metronome click.
- Open a score, open Inspector, switch layout to horizontal → close Reader
  → open Settings → picker shows horizontal. Force-quit and relaunch →
  Settings still shows horizontal, Reader opens horizontal.
- iPad split view: open Reader on the right, tap gear on the left, change
  layout direction in Settings → Reader pane re-flows immediately.
- iPad split view + playing: change metronome in Settings → click starts /
  stops on the running playback without dismissing the sheet.

## Non-goals

- No new "preferences" Domain protocol — current scope is two values, both
  trivially representable in `UserDefaults`. Do not introduce an
  abstraction we do not yet need.
- No migration of metronome's existing AppStorage key.
