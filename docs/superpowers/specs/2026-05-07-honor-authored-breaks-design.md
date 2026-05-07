# Per-score "honor authored layout breaks" toggle

## Problem

`.mscx` files can carry `<LayoutBreak>line` / `<LayoutBreak>page` markup that
forces the engraver's chosen system / page boundaries. `swift-sheet-music`
already supports three policies via `LayoutBreakPolicy`
(`.honor` / `.ignoreSystemBreaks` / `.ignoreAll`), but Folino currently never
sets this field — both score containers default to `.honor`, so users always
see whatever breaks the original engraver picked, even when those breaks were
authored for a different page size and waste horizontal space on iPad.

We want a per-score user choice: respect the authored breaks, or let the
layout engine pack measures purely by available width.

## Scope

- Per-score persisted setting (lives on `ReaderPreferences`).
- Two-state toggle exposed in the Inspector's **Visual** section.
- Default ON (`.honor`) so existing scores look identical until the user opts
  in.

Out of scope:

- The middle policy (`.ignoreSystemBreaks`). The user-stated motivation is a
  binary "守るか / engine任せか"; the page-break-only middle ground is
  engraving-nerd territory and can be added later.
- A global default in Settings — Inspector is the only entry point for this
  feature in v1.
- Touching `showBreakIndicators` — both containers already pass `false`; this
  spec is about engine behavior, not the badge overlay.

## Design

### Engine mapping

| Toggle | `LayoutBreakPolicy` | Effect |
| --- | --- | --- |
| ON  (default) | `.honor`     | line + page breaks both force a new system; page breaks also close the page (current behavior) |
| OFF           | `.ignoreAll` | engine wraps purely on available width; paginator only closes pages on vertical overflow |

### Storage

Add a `Bool` field on `ReaderPreferences`:

```swift
public var honorLayoutBreaks: Bool      // default true
```

The init gains a defaulted parameter so existing call sites compile
unchanged.

### Persistence (GRDB, v4 migration)

```sql
ALTER TABLE reader_preferences
  ADD COLUMN honor_layout_breaks INTEGER NOT NULL DEFAULT 1;
```

Default `1` means rows written under v3 (and earlier) decode as
`honorLayoutBreaks = true` — preserves current behavior on first run after
upgrade.

`ReaderPreferencesRecord` gains:

```swift
var honorLayoutBreaks: Bool

enum CodingKeys: String, CodingKey {
    // …existing keys…
    case honorLayoutBreaks = "honor_layout_breaks"
}
```

Round-tripped through `init(domain:)` / `toDomain()` like the other scalar
fields.

### View model

`ReaderViewModel` already centralises preference mutation through
`mutatePreferences { … }`. Add one setter:

```swift
public func setHonorLayoutBreaks(_ value: Bool) async {
    await mutatePreferences { $0.honorLayoutBreaks = value }
}
```

No invalidation logic beyond what `mutatePreferences` already does — the
score containers re-trigger layout via `.task(id: TaskKey(...))` (see below).

### Score containers

Both `VerticalScoreContainer` and `HorizontalScoreContainer`:

1. Accept `honorLayoutBreaks: Bool` (read from
   `viewModel.preferences.honorLayoutBreaks` at the `ReaderView` call site,
   the same place `staffSize` is currently read).
2. In `rebuildLayout(...)`, set
   `breakPolicy: honorLayoutBreaks ? .honor : .ignoreAll` on
   `ScoreViewOptions`.
3. Add `honorLayoutBreaks` to the `TaskKey` struct so toggling the value
   invalidates the layout task and rebuilds against the new policy.

`ReaderView.content` passes the value into both containers alongside
`staffSize`.

### Inspector UI

`InspectorView.visualContent` currently has `layoutRow` and `staffSizeRow`.
Add a third row:

```swift
Toggle(
    "Honor authored breaks",
    isOn: Binding(
        get: { viewModel.preferences.honorLayoutBreaks },
        set: { newValue in
            Task { await viewModel.setHonorLayoutBreaks(newValue) }
        }
    )
)
.listRowBackground(Color.clear)
.listRowSeparator(.hidden)
```

Localized via `Localizable.xcstrings` (English + Japanese — "楽譜の改行を尊重"
or similar; final ja string TBD by user during implementation).

## Test plan

**Domain:** `ReaderPreferences` doesn't ship its own tests; coverage is via
the persistence and view-model layers below.

**Infrastructure**

- Extend `ReaderPreferencesRecordTests` to set `honorLayoutBreaks` to both
  `true` and `false` and verify round-trip through `ReaderPreferencesRecord`.
- New migration test: insert a row at v3 schema, run v4 migration, decode the
  row, expect `honorLayoutBreaks == true`.

**Reader (view model)**

- `ReaderViewModelTests` (Swift Testing): seed a viewmodel, call
  `setHonorLayoutBreaks(false)`, assert (a) `preferences.honorLayoutBreaks`
  flipped, (b) the fake repository's `saveReaderPreferences` saw the new
  value.

**Reader (UI)**

- `InspectorView` SwiftUI preview already in place — verify the new row
  renders next to layout buttons and staff-size stepper, both in compact (tab
  picker) and regular (sectioned list) layouts.
- No new UI test; XCUITest tap on a toggle has poor signal-to-noise.

## Risks / open questions

- **Layout cost.** Toggling re-runs the layout engine. The engine is fast
  enough for typical scores (`LayoutCacheBenchmark` covers this in
  swift-sheet-music) but a very large score may briefly stutter on toggle.
  Acceptable — same cost as a staff-size step.
- **Auto-scroll position.** When the layout changes shape (number of
  systems, total height), the existing playback-cursor scroll-tracking will
  reposition on the next cursor tick. No special handling needed beyond
  what's already there for staff-size changes.
- **CloudKit sync.** `ReaderPreferences` rows aren't currently mirrored to
  CloudKit (only `score_items` and tags are; see `Migrations.swift`). This
  field inherits that — local-only for now, which matches the existing
  surface.

## Files touched

- `Packages/Domain/Sources/Domain/Models/ReaderPreferences.swift`
- `Packages/Infrastructure/Sources/Persistence/Database/Migrations.swift`
- `Packages/Infrastructure/Sources/Persistence/Records/ReaderPreferencesRecord.swift`
- `Packages/Infrastructure/Tests/InfrastructureTests/Persistence/ReaderPreferencesRecordTests.swift`
- `Packages/Features/Reader/Sources/Reader/ReaderViewModel.swift`
- `Packages/Features/Reader/Sources/Reader/ReaderView.swift`
- `Packages/Features/Reader/Sources/Reader/VerticalScoreContainer.swift`
- `Packages/Features/Reader/Sources/Reader/HorizontalScoreContainer.swift`
- `Packages/Features/Reader/Sources/Reader/InspectorView.swift`
- `Packages/Features/Reader/Tests/ReaderTests/ReaderViewModelTests.swift`
- `App/Resources/Localizable.xcstrings` (toggle label, en + ja)
