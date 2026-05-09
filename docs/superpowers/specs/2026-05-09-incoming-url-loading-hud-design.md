# Incoming URL — pop early and show loading HUD

## Problem

When a user opens a score from Files.app (or any other source that
delivers a URL via `.onOpenURL`) while a Reader is already on screen,
the app currently:

1. Receives the URL into `bootstrap.pendingIncomingURL`.
2. Awaits `LibraryViewModel.startImport(from:)`, which runs
   `prepareImport` (file parse + duplicate-hash) then `commitImport`
   (write file + persist DB). For a non-trivial MusicXML file this is
   several seconds.
3. Only **after** the import resolves does the app set
   `pendingScoreToOpen`, which triggers the existing handler that pops
   `compactPath` to root and pushes the new Reader (or, on iPad, sets
   `detailScoreItem`).

The visible result: the **previous score's Reader stays on screen**
during the entire import. There is no indication that the user's tap
was received, and the user may tap again or assume the app is stuck.

We want the navigation reset to happen at the **start** of the import,
and a loading indicator to cover the screen until the import resolves
(success → push Reader, duplicate → prompt, failure → alert).

## Scope

In scope:

- Move the navigation reset (pop to library root on iPhone, clear
  `detailScoreItem` on iPad) from the post-import handler to the
  URL-arrival handler.
- Add an `isImporting` flag to `LibraryViewModel`, managed by
  `startImport(from:)` and `commit(plan:decision:)` via `defer`.
- Add a fullscreen HUD overlay on `AppShellView` that displays while
  `libraryVM.isImporting` is true.
- Apply the same early-pop to the cold-launch path
  (`AppShellView.task` consuming `bootstrap.consumePendingIncomingURL`).
  In practice this is a no-op since cold launch starts at root, but
  keeping the two paths symmetric prevents regressions.

Out of scope:

- Reader's own score-parse loading state (already handled by
  `ReaderRootScreen.content` `.loading` case — unchanged).
- Multi-URL queueing (last-wins behaviour preserved).
- Cancellation of an in-flight import.
- Showing the HUD during un-related repository or playback activity.

## Design

### `LibraryViewModel` — `isImporting` flag

Add a new published property:

```swift
public var isImporting: Bool = false
```

Wrap both `startImport(from:)` and `commit(plan:decision:)` with
`defer`-based set/clear:

```swift
public func startImport(from sourceURL: URL) async {
    isImporting = true
    defer { isImporting = false }
    // existing body…
}

public func commit(plan: ImportPlan, decision: ImportDecision) async {
    isImporting = true
    defer { isImporting = false }
    // existing body…
}
```

`startImport` may call `commit` internally; nested set→defer works
correctly because both ultimately settle to `false` once both scopes
exit.

Wrapping `commit` separately covers the post-duplicate-prompt path
(`LibraryRootScreen` calls `commit` directly when the user picks
"Import as new" / "Replace existing" from the alert).

### `AppShellView` — early navigation reset

Today the URL handler is:

```swift
.onChange(of: bootstrap.pendingIncomingURL) { _, newValue in
    guard newValue != nil,
          let url = bootstrap.consumePendingIncomingURL() else { return }
    Task { await libraryVM.startImport(from: url) }
}
```

Change it to reset navigation **before** kicking off the task:

```swift
.onChange(of: bootstrap.pendingIncomingURL) { _, newValue in
    guard newValue != nil,
          let url = bootstrap.consumePendingIncomingURL() else { return }
    resetNavigationForIncomingURL()
    Task { await libraryVM.startImport(from: url) }
}
```

Where `resetNavigationForIncomingURL()` is a new private method:

```swift
private func resetNavigationForIncomingURL() {
    if horizontalSizeClass == .regular {
        sidebarPath = NavigationPath()
        detailScoreItem = nil
        columnVisibility = .doubleColumn
    } else {
        compactPath = NavigationPath()
    }
}
```

The cold-launch `.task` block also calls this method before
`startImport`, for symmetry.

The existing post-import handler
(`onChange(of: libraryVM.pendingScoreToOpen?.id)`) is **kept as-is**.
On the success path the navigation reset there becomes redundant but
harmless (path is already empty), and the `compactPath.append(item)` /
`detailScoreItem = item` push is still needed to show the new Reader.

### HUD overlay on `AppShellView`

Add an `.overlay` on the `AppShellView.body`:

```swift
.overlay {
    if libraryVM.isImporting {
        ImportLoadingHUD()
    }
}
```

`ImportLoadingHUD` is a small private `View` defined in
`AppShellView.swift`:

```swift
private struct ImportLoadingHUD: View {
    var body: some View {
        ZStack {
            Color.black.opacity(0.001) // capture taps
            VStack(spacing: 16) {
                ProgressView().controlSize(.large)
                Text("app.import.loading.label")
            }
            .padding(24)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        }
        .ignoresSafeArea()
        .transition(.opacity)
    }
}
```

Behaviour:

- Background tap-capture layer (`Color.black.opacity(0.001)`) blocks
  interaction with the underlying library while the import runs.
- Centered card with `ProgressView` + label using
  `.regularMaterial` for chrome.
- `.transition(.opacity)` for a soft fade in/out, paired with an
  `withAnimation` wrap of the `isImporting` toggle if needed (start
  with default animation; reassess if it feels jarring).

The `ImportLoadingHUD` is App-shell-private rather than Library-feature
since the use case (early-pop + HUD on URL arrival) is composed at the
App layer, not driven from inside the Library feature.

### Localization

New key `app.import.loading.label`:

- English: `Opening…`
- Japanese: `開いています…`

Add to App's existing `.xcstrings` (or create a new app-level catalog
if one does not yet exist for non-`Info.plist` strings; reuse the
existing `App/Resources/InfoPlist.xcstrings` only if it already mixes
runtime UI strings — likely it does not, so a new
`App/Resources/Localizable.xcstrings` is appropriate).

The HUD `Text("app.import.loading.label")` resolves against the App
target's main bundle (no `bundle:` argument needed).

## Behavioural matrix

| Trigger | Pre-import | During import | Post-import |
|---|---|---|---|
| URL while Reader open | Reader visible | Library root + HUD | Reader pushed (own loading state) |
| URL while in playlist detail | Playlist detail visible | Library root + HUD | Reader pushed |
| URL at cold launch | (no UI yet) | Library root + HUD | Reader pushed |
| URL → import fails | Reader visible | Library root + HUD | Library root + error alert |
| URL → duplicate detected | Reader visible | Library root + HUD | Library root + duplicate prompt |
| `.fileImporter` (manual pick from Library) | Library root | Library root + HUD | Reader pushed (success) / alert |

The manual `.fileImporter` flow showing the HUD is incidental but
desirable: the same "import in flight" UX applies regardless of how
the import was triggered.

## Testing

- `LibraryViewModelTests` (Swift Testing): add a test that drives
  `startImport` against a fake `ScoreFileImporter` whose
  `prepareImport` and `commitImport` are gated on continuations,
  asserting `isImporting` transitions `false → true → false` across
  the gate.
- Same shape for `commit(plan:decision:)` driven from a stubbed
  `ImportPlan`.
- App-layer integration of the HUD overlay is verified manually
  (SwiftUI preview of `ImportLoadingHUD` + simulator smoke test).

No UI test for the navigation-reset behaviour; the existing
`pendingScoreToOpen` handler tests cover the post-import push, and the
new pre-import reset is a one-liner that's easier to verify by
inspection than by an XCUITest of the Files-app handoff.

## Risks / open questions

- **HUD blocking duration** — if the user's chosen file is huge, the
  HUD could be visible for many seconds with no progress feedback.
  Acceptable for v1; revisit only if real users hit it.
- **Tap-capture layer accessibility** — `Color.black.opacity(0.001)`
  is a known pattern for blocking touches but unlocalized to assistive
  tech. Consider `.accessibilityHidden(true)` on the background and
  exposing the HUD card as the accessibility element. (Apply now,
  cheap.)
- **Animation jank** — `withAnimation(.easeInOut(duration: 0.15))`
  around the `isImporting = true/false` flips inside the AppShellView
  handlers, since `LibraryViewModel.isImporting` is mutated from
  background async contexts that don't carry SwiftUI animation
  intent. Decide during implementation; default to no animation if
  it's smooth enough.
