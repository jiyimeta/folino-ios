# macOS Library and Window Redesign — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Take the library out of the score window — a Mac window is a score, or it is the library browser — so that no `NavigationStack` ever sits in a `NavigationSplitView` sidebar and no click ever doubles as "open".

**Architecture:** The existing `WindowGroup(for: MacWindowScore.self)` keeps presenting scores, but its content becomes the reader alone. A new single-instance `Window` scene hosts a library browser: a flat, selection-driven source sidebar plus a content pane that reuses the Library package's existing screens unchanged. Click selects; double-click / Return / a button / a context-menu item open, and opening always targets a score window (a new tab of the frontmost one when possible).

**Tech Stack:** SwiftUI (macOS 15 floor), AppKit for window tabbing (`NSWindow.tabbingMode`, `addTabbedWindow`), Swift Testing for the platform-neutral logic.

**Spec:** `docs/superpowers/specs/2026-09-01-macos-library-window-redesign-design.md`

## Global Constraints

- **iOS and iPadOS behavior does not change.** `LibraryRootScreen` and its push navigation remain the iOS shape. No iOS file may change behavior; iOS chrome (`isSelecting`, `BulkActionBar`, the Select toolbar button) stays byte-identical.
- **Deployment floors:** iOS 18.0, macOS 15.0. iOS-26/macOS-26-only API must be written `if #available(iOS 26, macOS 26, *)` — a bare `*` does **not** guard macOS.
- **No SwiftUI tap gesture on any macOS row.** A gesture leaves `List(selection:)` permanently empty (measurement table in `RowOpenAffordance.swift`). This is law.
- **No `NavigationStack` inside any `NavigationSplitView` sidebar.** A push there renders bottom-anchored on macOS 26.4.1.
- **Never put `#if` inside a SwiftUI modifier chain.** SwiftFormat's `--ifdef no-indent` fights it every commit. Use a compat helper (`UtilityUI/PlatformViewCompat.swift`, `Library/Views/RowOpenAffordance.swift`).
- **Mac-only code cannot be unit-tested by this repo.** Package tests run on an iOS Simulator destination, so `#if os(macOS)` bodies are never compiled for them. Therefore: **any logic worth testing must be platform-neutral**, with `#if os(macOS)` reserved for views and AppKit. `Scripts/build-macos-packages.sh` is the compile gate for the Mac halves.
- **Layering:** Library depends on Domain, ScoreUI and Utility only. No Feature → Feature, no Feature → Infrastructure.
- **User-facing brand is lowercase `folino`.** Internal feature names (`Reader`, `Library`) never appear in user-visible copy.
- **Localization:** new user-facing strings go in `Packages/Features/Library/Sources/Library/Resources/Localizable.xcstrings` (Library) or `App/Resources/Localizable.xcstrings` (App), following the keys already there.
- **Build commands:** app/Mac — `xcodebuild build -project Folino.xcodeproj -scheme FolinoMac -destination 'platform=macOS' -skipPackagePluginValidation`. Package tests — from the package directory, `xcodebuild test -scheme <Library|Reader|Infrastructure-Package|ImportExport-Package> -destination 'platform=iOS Simulator,id=513F3B9E-891E-44CB-9DD3-BFCF5EEE3394' -skipPackagePluginValidation`. Pass is the line `✔ Test run with N tests in M suites passed`; `Test Case … passed` never appears (Swift Testing) and grepping for it always yields 0.
- **Two mechanisms are unmeasured and must not be presented as verified:** `contextMenu(forSelectionType:primaryAction:)` coexisting with `List(selection:)`, and open-lands-as-a-tab. Both ship with fallbacks; both go on the QA list.

---

## File structure

**New — platform-neutral (tested):**
- `Packages/Features/Library/Sources/Library/LibrarySource.swift` — what the browser's sidebar can show, and how the row list is derived from repository state. No SwiftUI beyond `Identifiable`.

**New — macOS views:**
- `Packages/Features/Library/Sources/Library/Screens/Mac/MacLibraryBrowser.swift` — the browser's split view; owns the source selection and swaps the content pane.
- `Packages/Features/Library/Sources/Library/Screens/Mac/MacLibrarySidebar.swift` — the flat source list.
- `App/Mac/MacWindowTabAssist.swift` — the `NSWindow` probe, the tab-placement assist, and the playback takeover hook.

**Rewritten:**
- `App/Mac/FolinoMacApp.swift`, `App/Mac/MacShellView.swift`, `App/Mac/MacCommands.swift`
- `Packages/Features/Library/Sources/Library/Views/RowOpenAffordance.swift`
- Call sites in `ScoreListView.swift`, `PlaylistDetailView.swift`, `RecentlyDeletedView.swift`

---

### Task 1: `LibrarySource` — the browser's source list, platform-neutral

**Files:**
- Create: `Packages/Features/Library/Sources/Library/LibrarySource.swift`
- Test: `Packages/Features/Library/Tests/LibraryTests/LibrarySourceTests.swift`

**Interfaces:**
- Consumes: `ScoreLibraryRepository` (`Domain`), `Playlist`, `Tag`, `ScoreItem`.
- Produces: `enum LibrarySource: Hashable, Identifiable` with cases `recents`, `allScores`, `favorites`, `playlist(PlaylistID)`, `tag(TagID)`, `recentlyDeleted`; `struct LibrarySourceRow: Identifiable, Equatable { let source: LibrarySource; let title: String; let count: Int }`; `enum LibrarySourceList { static func rows(scoreItems: [ScoreItem], deletedScoreItems: [ScoreItem], playlists: [Playlist], tags: [Tag]) -> [LibrarySourceRow] }`.

The ordering `LibrarySourceList.rows` returns is the sidebar's order, top to bottom: `recents`, `allScores`, `favorites`, then one row per playlist in `playlists` order, then one row per tag in `tags` order, then `recentlyDeleted`. `title` for the fixed sources is the localization key's resolved string; for a playlist or tag it is that entity's name. `count` is: recents = number of items with a non-nil `lastOpenedAt`; allScores = `scoreItems.count`; favorites = number favorited; playlist = number of its member ids that are still live rows; tag = number of live rows carrying it; recentlyDeleted = `deletedScoreItems.count`. **Playlist and tag counts must exclude soft-deleted items** — `PlaylistsListView`'s `memberCount` doc comment states this contract and the Mac must not diverge from it.

- [ ] **Step 1: Write the failing test**

```swift
import Domain
import Testing
@testable import Library

@Suite("LibrarySourceList")
struct LibrarySourceTests {
    private func item(title: String, favorite: Bool = false, opened: Date? = nil) -> ScoreItem {
        var made = ScoreItem(
            title: title, composer: nil, instrumentationSummary: "Piano",
            localFileName: "\(UUID().uuidString).musicxml",
        )
        made.isFavorite = favorite
        made.lastOpenedAt = opened
        return made
    }

    @Test("the fixed sources come first, Recently Deleted last")
    func ordering() {
        let rows = LibrarySourceList.rows(
            scoreItems: [], deletedScoreItems: [], playlists: [], tags: [],
        )
        #expect(rows.map(\.source) == [.recents, .allScores, .favorites, .recentlyDeleted])
    }

    @Test("counts read the live rows")
    func counts() {
        let opened = item(title: "A", favorite: true, opened: Date())
        let plain = item(title: "B")
        let rows = LibrarySourceList.rows(
            scoreItems: [opened, plain], deletedScoreItems: [item(title: "C")],
            playlists: [], tags: [],
        )
        #expect(rows.first { $0.source == .allScores }?.count == 2)
        #expect(rows.first { $0.source == .favorites }?.count == 1)
        #expect(rows.first { $0.source == .recents }?.count == 1)
        #expect(rows.first { $0.source == .recentlyDeleted }?.count == 1)
    }

    @Test("a playlist row counts only live members")
    func playlistExcludesDeleted() {
        let live = item(title: "live")
        let gone = item(title: "gone")
        let playlist = Playlist(name: "Set", scoreItemIDs: [live.id, gone.id])
        let rows = LibrarySourceList.rows(
            scoreItems: [live], deletedScoreItems: [gone], playlists: [playlist], tags: [],
        )
        #expect(rows.first { $0.source == .playlist(playlist.id) }?.count == 1)
        #expect(rows.first { $0.source == .playlist(playlist.id) }?.title == "Set")
    }
}
```

- [ ] **Step 2: Run the test and confirm it fails**

From `Packages/Features/Library`:
`xcodebuild test -scheme Library -destination 'platform=iOS Simulator,id=513F3B9E-891E-44CB-9DD3-BFCF5EEE3394' -skipPackagePluginValidation -only-testing:Library/LibrarySourceTests`
Expected: build failure, `cannot find 'LibrarySourceList' in scope`.

**Check the real initializers first.** `ScoreItem`, `Playlist` and `Tag` are Domain value types; open `Packages/Domain/Sources/Domain/` and use their actual member names and initializers rather than the ones sketched above if they differ — adjust the test, not the model.

- [ ] **Step 3: Implement `LibrarySource.swift`**

Write the enum, the row struct, and `LibrarySourceList.rows(...)` as described above. Localized titles come from `Text("library.allScores", bundle: .module)`-style keys already present in Library's `Localizable.xcstrings`; resolve them with `String(localized:bundle: .module)`. Add `library.recents` if it is not already a key (check first — `LibraryRootRecentsSection` uses `library.recentlyOpened`; reuse that key rather than minting a duplicate).

No `#if os(macOS)` in this file. It compiles on both platforms and is tested on iOS.

- [ ] **Step 4: Run the test and confirm it passes**

Same command. Expected: `✔ Test run with N tests in M suites passed`, N ≥ 3.

- [ ] **Step 5: Commit**

```bash
git add Packages/Features/Library/Sources/Library/LibrarySource.swift Packages/Features/Library/Tests/LibraryTests/LibrarySourceTests.swift
git commit -m "feat(library): the Mac browser's source list, as a tested value type"
```

---

### Task 2: The macOS open affordance replaces selection-as-open

**Files:**
- Modify: `Packages/Features/Library/Sources/Library/Views/RowOpenAffordance.swift`
- Modify: `Packages/Features/Library/Sources/Library/Views/ScoreListView.swift` (the `.macSelectionOpensScore(...)` call in `listWithChrome`)
- Modify: `Packages/Features/Library/Sources/Library/Views/PlaylistDetailView.swift`, `Packages/Features/Library/Sources/Library/Views/RecentlyDeletedView.swift` (same call, if present — grep first)

**Interfaces:**
- Produces: `func macScoreOpenAffordance(_ selectedIDs: Set<ScoreItemID>, in items: [ScoreItem], onOpen: @escaping (ScoreItem) -> Void, onOpenInNewWindow: @escaping (ScoreItem) -> Void) -> some View` — a no-op on iOS.
- Removes: `macSelectionOpensScore`, `macSingleSelectionOpensScore`, and `FocusedValues.libraryBulkSelectionCount`.

- [ ] **Step 1: Delete selection-as-open and its focused value**

Remove `macSelectionOpensScore`, `macSingleSelectionOpensScore` and the whole `#if os(macOS) extension FocusedValues { … libraryBulkSelectionCount … }` block. **Keep the file's doc comment and its measurement table** — it is the record of Fact 2 and this file exists to hold it. Add a paragraph under the table saying selection no longer opens anything, and why (spec §2.2), and add a table row for `contextMenu(forSelectionType:primaryAction:)` marked `unmeasured` until QA fills it in.

- [ ] **Step 2: Add the open affordance**

```swift
extension View {
    /// **macOS only**: how a score row is opened, now that selecting it does not.
    ///
    /// Four paths, and the last three are not garnish — they are the fallback that ships whether or not the first
    /// one works. `contextMenu(forSelectionType:primaryAction:)` is a `List` API rather than a gesture overlay, so
    /// the measurement table above does not condemn it, but that table never tested it and nothing else in this
    /// repo uses it. If double-click turns out to be dead, opening still has Return, the toolbar button and the
    /// context menu, and the table gains a row. Opening never falls back to selection.
    @ViewBuilder
    func macScoreOpenAffordance(
        _ selectedIDs: Set<ScoreItemID>,
        in items: [ScoreItem],
        onOpen: @escaping (ScoreItem) -> Void,
        onOpenInNewWindow: @escaping (ScoreItem) -> Void,
    ) -> some View {
        #if os(macOS)
        contextMenu(forSelectionType: ScoreItemID.self) { ids in
            if let item = Self.singleItem(ids, in: items) {
                Button { onOpen(item) } label: { L10n.Common.open }
                Button { onOpenInNewWindow(item) } label: { Text("library.open.newWindow", bundle: .module) }
            }
        } primaryAction: { ids in
            guard let item = Self.singleItem(ids, in: items) else { return }
            onOpen(item)
        }
        .onKeyPress(.return) {
            guard let item = Self.singleItem(selectedIDs, in: items) else { return .ignored }
            onOpen(item)
            return .handled
        }
        #else
        self
        #endif
    }

    private static func singleItem(_ ids: Set<ScoreItemID>, in items: [ScoreItem]) -> ScoreItem? {
        guard ids.count == 1, let id = ids.first else { return nil }
        return items.first { $0.id == id }
    }
}
```

`singleItem` cannot be a `static` on `View` (a protocol extension cannot add static members usable this way) — if the compiler rejects it, lift it to a `private func macSingleItem(...)` free function in the same file and call that. Do not silently drop the guard.

**The existing selection context menu stays.** `ScoreListView.effectiveRowMenu` already switches to bulk actions when more than one row is selected; the `contextMenu(forSelectionType:)` above is a *second* menu and they will fight. Resolve it by moving Open / Open in New Window **into the existing `effectiveRowMenu`'s single-row branch** and keeping `contextMenu(forSelectionType:primaryAction:)` only for its `primaryAction` (pass an empty `menu:` closure). Verify in the built app which menu appears; record the answer in the file's doc comment.

- [ ] **Step 3: Update the call sites**

In `ScoreListView.listWithChrome`, replace `.macSelectionOpensScore(selectedIDs, in: items, onOpen: onTap)` with `.macScoreOpenAffordance(selectedIDs, in: items, onOpen: onTap, onOpenInNewWindow: onOpenInNewWindow)`. Add `let onOpenInNewWindow: (ScoreItem) -> Void` to `ScoreListView`'s stored properties and thread it from `ScoreListScreen` (`onOpenInNewWindow` parameter, defaulting to the same closure as `onOpen` on iOS so no iOS call site changes meaning). Do the same in `PlaylistDetailView` and `RecentlyDeletedView` wherever `macSelectionOpensScore` was called.

Every `ScoreListView` / `ScoreListScreen` construction site must be updated, including the `#Preview`s at the bottom of `ScoreListView.swift`.

- [ ] **Step 4: Build both platforms**

`xcodebuild build -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,id=513F3B9E-891E-44CB-9DD3-BFCF5EEE3394' -skipPackagePluginValidation` and `Scripts/build-macos-packages.sh`. Both must succeed.

- [ ] **Step 5: Run the Library tests**

From `Packages/Features/Library`: the command in Global Constraints. Expected: the suite that passed 129 tests still passes, count unchanged or higher.

- [ ] **Step 6: Commit**

```bash
git add Packages/Features/Library
git commit -m "refactor(library): opening a score is its own action, not a selection"
```

---

### Task 3: `MacLibrarySidebar` — the flat source list

**Files:**
- Create: `Packages/Features/Library/Sources/Library/Screens/Mac/MacLibrarySidebar.swift`

**Interfaces:**
- Consumes: `LibrarySourceRow`, `LibrarySourceList` (Task 1); `LibraryViewModel`.
- Produces: `struct MacLibrarySidebar: View` with `init(viewModel: LibraryViewModel, selection: Binding<LibrarySource?>)`.

- [ ] **Step 1: Write the view**

The whole file is wrapped in `#if os(macOS) … #endif`. Body:

```swift
List(selection: selection) {
    ForEach(rows) { row in
        Label { Text(row.title) } icon: { Image(systemName: icon(for: row.source)) }
            .badge(row.count)
            .tag(row.source)
    }
}
.listStyle(.sidebar)
```

`rows` is `LibrarySourceList.rows(scoreItems: viewModel.repository.scoreItems, deletedScoreItems: viewModel.repository.deletedScoreItems, playlists: viewModel.repository.playlists, tags: viewModel.repository.tags)`.

**No `NavigationLink`, no `NavigationStack`, no tap gesture** — a tag and the selection binding are the whole vocabulary. This is the constraint that keeps Fact 1 and Fact 2 out of the browser.

Icons: `recents` → `clock`, `allScores` → `music.note.list`, `favorites` → `star`, `playlist(_)` → `music.note.list`, `tag(_)` → `tag`, `recentlyDeleted` → `trash`.

Context menus on playlist and tag rows: Rename and Delete, calling the same `LibraryViewModel` methods `PlaylistsListView` / `TagsListView` use — read those files and reuse their calls rather than inventing new ones.

- [ ] **Step 2: Add a `#Preview`**

```swift
#Preview("Sidebar") {
    MacLibrarySidebar(viewModel: .preview, selection: .constant(.allScores))
        .frame(width: 260, height: 480)
}
```

If `LibraryViewModel` has no `.preview`, build one from the fakes the Library tests already use and put it behind `#if DEBUG` in the preview file — do not add a preview-only member to the production type.

- [ ] **Step 3: Build for macOS**

`Scripts/build-macos-packages.sh`. Expected: exit 0.

- [ ] **Step 4: Render the preview and look at it**

Open `Packages/Features/Library/Package.swift` in Xcode with the run destination set to **My Mac**, then render the preview via the Xcode MCP `RenderPreview` (`sourceFilePath: Library/Sources/Library/Screens/Mac/MacLibrarySidebar.swift`). Read the PNG. Expected: the fixed rows with badges, selection highlight on All Scores. A macOS destination is confirmed by the absence of an `Orientation` entry in `supportedPreviewVariantOverrides`.

- [ ] **Step 5: Commit**

```bash
git add Packages/Features/Library/Sources/Library/Screens/Mac
git commit -m "feat(library): the Mac browser's source sidebar"
```

---

### Task 4: `MacLibraryBrowser` — the browser window's content

**Files:**
- Create: `Packages/Features/Library/Sources/Library/Screens/Mac/MacLibraryBrowser.swift`

**Interfaces:**
- Consumes: `MacLibrarySidebar` (Task 3), `LibrarySource` (Task 1), and the existing screens `AllScoresScreen`, `FavoritesScreen`, `TagDetailScreen`, `PlaylistDetailScreen`, `RecentlyDeletedScreen`.
- Produces: `public struct MacLibraryBrowser: View` with
  `public init(viewModel: LibraryViewModel, onOpenScore: @escaping (ScoreItem) -> Void, onOpenScoreInNewWindow: @escaping (ScoreItem) -> Void, onOpenInPlaylist: @escaping (ScoreItem, PlaylistID) -> Void, licenseContent: …)`.
  `public` because `App/Mac` composes it — that is the composition root's privilege, and the only `public` this plan adds.

- [ ] **Step 1: Write the view**

Whole file inside `#if os(macOS)`. Body:

```swift
NavigationSplitView {
    MacLibrarySidebar(viewModel: viewModel, selection: $selection)
        .navigationSplitViewColumnWidth(min: 220, ideal: 260)
} detail: {
    content
}
.frame(minWidth: 820, minHeight: 520)
```

`@State private var selection: LibrarySource? = .recents` — the spec's default source.

`content` switches on `selection` and returns the matching existing screen, passing `onOpenScore` as its `onOpen`. Wrap each in nothing — these screens carry their own `navigationTitle` and toolbar and are designed to be the detail column's content. For `.recents`, show `AllScoresScreen` filtered to recently-opened; if no existing screen does that, use `ScoreListScreen` with a `ScoreListViewModel(source: .all, …)` and sort by most-recently-opened, matching `LibraryRootRecentsSection`'s `mostRecentlyOpened()`. Read `ScoreListViewModel`'s `source` enum before choosing — if it already has a recents case, use it.

For `nil` selection, `ContentUnavailableView` with the key `library.browser.noSource` (add to Library's xcstrings; English "Choose a source", Japanese 「表示する項目を選んでください」).

The drop destination for imported files moves here from `MacShellView`: `.dropDestination(for: URL.self)` around the whole split view, same body as the one in `MacShellView.sidebar` today.

- [ ] **Step 2: Add a `#Preview`**

A `#Preview("Browser")` wrapping `MacLibraryBrowser` at `.frame(width: 1000, height: 640)` with the same fake view model as Task 3.

- [ ] **Step 3: Build for macOS**

`Scripts/build-macos-packages.sh`. Expected: exit 0.

- [ ] **Step 4: Render the preview**

Same mechanism as Task 3, `sourceFilePath: Library/Sources/Library/Screens/Mac/MacLibraryBrowser.swift`. Read the PNG. **Expected: rows visible in the content pane.** If the content pane is blank, the arrangement has re-entered the Fact 1 configuration — check that no screen in the content pane wraps itself in a `NavigationStack`, and say so in the report rather than working around it.

- [ ] **Step 5: Commit**

```bash
git add Packages/Features/Library/Sources/Library/Screens/Mac/MacLibraryBrowser.swift
git commit -m "feat(library): the Mac library browser"
```

---

### Task 5: `MacWindowTabAssist` — open lands as a tab, and one score plays at a time

**Files:**
- Create: `App/Mac/MacWindowTabAssist.swift`

**Interfaces:**
- Produces: `struct MacWindowTabAssist: NSViewRepresentable` (a zero-size probe placed in a score window's content, which sets its own window's `tabbingMode = .preferred` and `tabbingIdentifier` to a shared constant), and `@MainActor enum MacScorePlayback { static func takeOver(from controller: any PlaybackControlling) }`.

- [ ] **Step 1: Write the tab assist**

Model it on `App/Mac/EffectiveWindowWidthProbe.swift` for AppKit access and on `Reader/Screens/Mac/MacScrollViewAppearance.swift` for the probe pattern — in particular, **that file's measured rule: writing AppKit window state from inside `updateNSView` re-enters the split view's navigation observer in the same frame.** Defer the write with `DispatchQueue.main.async` and make it idempotent, exactly as `MacScrollViewAppearanceProbe.apply` does. Read that file before writing this one.

```swift
private final class MacWindowTabProbe: NSView {
    static let tabbingIdentifier = NSWindow.TabbingIdentifier("com.KeyNumber.Folino.score")
    private var applied = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, !applied else { return }
        applied = true
        DispatchQueue.main.async { [weak window] in
            window?.tabbingIdentifier = Self.tabbingIdentifier
            window?.tabbingMode = .preferred
        }
    }
}
```

- [ ] **Step 2: Write the playback takeover**

`MacScorePlayback.takeOver` stops whatever the shared `bootstrap.playbackController` is currently playing before a new window starts it. Read `Packages/Domain/Sources/Domain/Protocols/` for the playback protocol's actual name and its stop/pause member before writing this; do not invent a method. Call it from `MacReaderRootScreen`'s play path only if a seam already exists there — **if there is none, do not add one in this task**; report it and leave the takeover unwired, because inventing a seam inside the reader is Ⅳ's business and a silent partial wiring is worse than a named gap.

- [ ] **Step 3: Build the Mac app**

`xcodebuild build -project Folino.xcodeproj -scheme FolinoMac -destination 'platform=macOS' -skipPackagePluginValidation`. Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add App/Mac/MacWindowTabAssist.swift
git commit -m "feat(macos): windows tab together, and one score plays at a time"
```

---

### Task 6: The scene graph — a window is a score, or it is the library

**Files:**
- Modify: `App/Mac/FolinoMacApp.swift`
- Modify: `App/Mac/MacShellView.swift`

**Interfaces:**
- Consumes: `MacLibraryBrowser` (Task 4), `MacWindowTabAssist` (Task 5).
- Produces: window id constant `MacWindowID.library = "library"`; `MacShellView(bootstrap:window:)` — the `columnVisibility` parameter is gone.

- [ ] **Step 1: Add the library `Window` scene**

In `FolinoMacApp.body`, after the score `WindowGroup`:

```swift
Window("folino", id: MacWindowID.library) {
    Group {
        if bootstrap.isReady {
            MacLibraryBrowser(
                viewModel: libraryVM,
                onOpenScore: { item in openWindow(value: MacWindowScore(scoreID: item.id)) },
                onOpenScoreInNewWindow: { item in openWindow(value: MacWindowScore(scoreID: item.id)) },
                onOpenInPlaylist: { item, _ in openWindow(value: MacWindowScore(scoreID: item.id)) },
                licenseContent: { LicenseListView() },
            )
        } else if let failure = bootstrap.failure {
            // same ContentUnavailableView the score group uses
        } else {
            ProgressView()
        }
    }
    .task { bootstrap.start() }
}
```

The window's user-visible title is lowercase `folino` — the brand rule. The `LibraryViewModel` moves here from `MacShellView`: build it in `FolinoMacApp` as `@State`, with the same construction `MacShellView.init` performs today (copy it verbatim, including the `guard`'s reasoning comment), so exactly one instance exists per process rather than one per score window.

`onOpenScore` and `onOpenScoreInNewWindow` differ only once Task 5's assist is proven: both call `openWindow(value:)`, and whether the result is a tab or a standalone window is decided by the probe. Wire them as two closures anyway so the distinction has a home; note in a comment that they are currently identical and why.

The post-import watcher (`libraryVM.pendingScoreToOpen`) moves here too, opening the imported score in a score window. **Keep it to one state write per handler** — `MacShellView.openImportedScore`'s doc comment records the measurements that rule comes from; read it before touching this.

- [ ] **Step 2: Pin launch and restoration**

Add `.defaultLaunchBehavior(.presented)` to the library `Window` scene if the modifier is available on the macOS 15 floor (check; it is macOS 15+). If it does not compile or does not behave, fall back to presenting the browser at launch unconditionally and say so in the report — the spec names that fallback as acceptable.

- [ ] **Step 3: Reduce `MacShellView` to the score window's content**

Delete: the `NavigationSplitView`, the `sidebar` property, `columnVisibility`, `librarySelectionCount` and the `@FocusedValue` reading it, the "N selected" `ContentUnavailableView` branch, `libraryVM` and its construction, `sidebarPath`, and the drop destination (it moved to the browser). Keep: the adapter unwrapping in `init`, `scoreID`, `openScoreItem`, the reader branch, the empty-detail branch, `focusedCurrentScoreID`, and the `macLibraryImportAction` focused value **only if** File ▸ Import should still work from a score window — it should, so keep it and point it at the app-level `libraryVM`.

Add `MacWindowTabAssist()` to the view's background so every score window gets the tabbing identity.

Delete the two `PARITY(macos)` markers in the old `sidebar` property along with the code they annotate (`Scripts/parity-report.py` regenerates `docs/engineering/ios-android-parity.md`; the pre-commit hook fails if it drifts, so let the hook regenerate it rather than editing that file by hand).

- [ ] **Step 4: Build the Mac app and the iOS app**

Mac: `xcodebuild build -project Folino.xcodeproj -scheme FolinoMac -destination 'platform=macOS' -skipPackagePluginValidation`.
iOS: `xcodebuild build -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,id=513F3B9E-891E-44CB-9DD3-BFCF5EEE3394' -skipPackagePluginValidation`.
Both must print `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Launch the Mac app and capture the window**

```
xcodebuild build … ; open the built app from
~/Library/Developer/Xcode/DerivedData/Folino-*/Build/Products/Debug/folino.app/Contents/MacOS/folino
```
Run it with stderr redirected to a file (`> log 2>&1`, run in background). **Use stderr, not `print`** — a redirected stdout is fully buffered and an empty log would look like "this never ran".

Then capture the window without any UI automation: list windows with a small `CGWindowListCopyWindowInfo` script (`xcrun swift`), and `screencapture -o -x -l<id> out.png`. Read the PNG.

Expected: the browser window appears at launch, its sidebar lists the sources, and its content pane shows rows. Report what you actually see.

- [ ] **Step 6: Commit**

```bash
git add App/Mac docs/engineering/ios-android-parity.md
git commit -m "feat(macos): a window is a score, or it is the library"
```

---

### Task 7: The menu bar and the way back

**Files:**
- Modify: `App/Mac/MacCommands.swift`
- Modify: `App/Mac/MacShellView.swift` (toolbar button)

- [ ] **Step 1: Replace ⌘0 with ⌘O**

Delete the `columnVisibility` binding and the `mac.menu.toggleLibrary` button entirely (there is no sidebar to toggle). Add, in `CommandGroup(after: .newItem)`, above Import:

```swift
Button {
    openWindow(id: MacWindowID.library)
} label: {
    Text("mac.menu.showLibrary")
}
.keyboardShortcut("o", modifiers: .command)
```

Add `mac.menu.showLibrary` to `App/Resources/Localizable.xcstrings` — English "Open…", Japanese 「開く…」. **Not "Library"**: internal feature names never appear in user-facing copy, and this item is the Mac's Open command.

- [ ] **Step 2: Rework "Open in New Tab"**

Rename the existing item to `mac.menu.openInNewWindow` ("Open in New Window" / 「新しいウインドウで開く」) and keep its `openWindow(value: MacWindowScore(scoreID:))` body. Its old label was a claim the app could not keep at default system settings.

- [ ] **Step 3: Add the library toolbar button to score windows**

In `MacShellView`, on the reader branch:

```swift
.toolbar {
    ToolbarItem(placement: .navigation) {
        Button {
            openWindow(id: MacWindowID.library)
        } label: {
            Label {
                Text("mac.toolbar.showLibrary")
            } icon: {
                Image(systemName: "square.grid.2x2")
            }
        }
    }
}
```

with `@Environment(\.openWindow) private var openWindow`. Add `mac.toolbar.showLibrary` to `App/Resources/Localizable.xcstrings` (English "Open…", Japanese 「開く…」 — same copy as the menu item).

- [ ] **Step 4: Build the Mac app**

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Relaunch and capture**

Same capture method as Task 6 Step 5. Expected: a score window (if one restores) carries the button; the menu bar's File menu shows Open… ⌘O and Open in New Window.

- [ ] **Step 6: Commit**

```bash
git add App/Mac App/Resources/Localizable.xcstrings
git commit -m "feat(macos): the Open command and the way back to the library"
```

---

### Task 8: Strip the dead macOS branches and close the gate

**Files:**
- Modify: `Packages/Features/Library/Sources/Library/Screens/LibraryRootScreen.swift`, `LibraryRootRecentsSection.swift`, `LibraryRootDestinations.swift` — remove anything that existed only to serve the Mac sidebar.
- Modify: `Scripts/build-macos-packages.sh` if a package's macOS membership changed (it should not have).

- [ ] **Step 1: Find what is now dead**

`grep -rn 'os(macOS)' Packages/Features/Library/Sources/Library` and check each hit against the new design. `LibraryRootScreen` is no longer instantiated on macOS but must keep compiling there (the macOS build floor exists for the Android host tests — see the project memory; **do not remove `.macOS` from any `Package.swift`**). Remove macOS-only *behavior* that no longer has a caller; keep macOS *compilability*.

- [ ] **Step 2: Verify no `NavigationStack`-in-sidebar remains**

`grep -rn 'NavigationSplitView' App Packages` and confirm the only one left is `MacLibraryBrowser`'s, whose sidebar is a flat `List(selection:)`.

- [ ] **Step 3: Run every gate**

- `Scripts/build-macos-packages.sh` → exit 0, zero `error:` lines
- Mac app build → `** BUILD SUCCEEDED **`
- iOS app build → `** BUILD SUCCEEDED **`
- Library tests, Reader tests, Infrastructure tests, ImportExport tests → each `✔ Test run with N tests in M suites passed`, reporting N for each

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "chore(macos): remove the sidebar-era branches"
```

---

### Task 9: The QA sheet

**Files:**
- Create: `docs/superpowers/plans/2026-09-01-macos-library-window-redesign-qa.md`

- [ ] **Step 1: Write the sheet**

One checklist the user works through on a real Mac, each item saying what to do and what to look for. It must include, at minimum:

1. **Double-click opens a score** — the `primaryAction` question. If it does nothing, that is the measured failure; Return, the Open menu item and the toolbar button must all still work, and the result gets recorded in `RowOpenAffordance.swift`'s table.
2. **Click only selects** — clicking a row highlights it and opens nothing; the list does not re-sort under the pointer.
3. **⌘-click and ⇧-click multi-select**, the selection's context menu offers the bulk actions, and ⌫ deletes the selection.
4. **Opening a second score lands as a tab** of the first score's window (the unmeasured tab assist). If it opens a standalone window, that is the named fallback — Window ▸ Merge All Windows must still group them, and a tab must tear off by dragging.
5. **`NavigationRequestObserver` fault** — with the app launched from a terminal so stderr is captured, do: open the browser, click a row, double-click a row, ⌘-click a second row, ⌫. Any `NavigationRequestObserver tried to update multiple times per frame` line is a regression. Note the detector's positive control from the Ⅲb report.
6. **Two windows, one plays** — start playback in one score window, then in another; the first must stop.
7. **⌘O** summons the browser from a score window, and the toolbar button does the same.
8. **Every source renders** — Recents, All Scores, Favorites, each playlist, each tag, Recently Deleted; none is blank.
9. **Playlist reorder** — inside a playlist, drag a score row to reorder it (the Ⅲb item the harness could never reach).
10. **Dark mode** — browser and score window both.

- [ ] **Step 2: Commit**

```bash
git add docs/superpowers/plans/2026-09-01-macos-library-window-redesign-qa.md
git commit -m "docs(macos): the QA sheet for the library redesign"
```

---

## Self-review

**Spec coverage.** §2.1 → Tasks 4, 6. §2.2 → Task 2. §2.3 → Tasks 5, 6. §2.4 → Task 5, verified in Task 9 item 4. §2.5 playback → Task 5 (with a named bail-out if no seam exists); display mode is explicitly unchanged. §2.6 → constraints only, nothing to build here. §2.7 → Task 7. §2.8 → Task 6 Step 2. §3 → Task 2 plus the untouched existing bulk machinery. §5 risks → Task 9 items 1, 4, 5. §6 blast radius → Tasks 2–8.

**Gap accepted deliberately:** the spec's `MacLibrarySource.swift` naming became `LibrarySource.swift` because the type is platform-neutral so that it can be tested — the constraint that Mac-only code is untestable in this repo outranks the file name in the spec.

**Placeholders:** none. Two tasks (5 Step 2, 6 Step 2) instruct the implementer to *check an API and report* rather than guess, which is deliberate: inventing a playback seam or a restoration modifier that does not exist is worse than a named gap.

**Type consistency:** `LibrarySource` / `LibrarySourceRow` / `LibrarySourceList` (Task 1) are used under those names in Tasks 3 and 4. `macScoreOpenAffordance` (Task 2) is the only open helper after Task 2 deletes the two old ones. `MacWindowID.library` (Task 6) is the id Task 7's commands open.
