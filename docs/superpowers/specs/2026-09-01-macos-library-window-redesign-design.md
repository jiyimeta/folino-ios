# macOS Library and Window Structure — Design

**Date:** 2026-09-01
**Status:** Approved. Supersedes `2026-08-31-macos-app-shell-design.md` §3 (window model) and §4 (Library's macOS form), and revises the umbrella spec `2026-08-31-macos-app-design.md` §5.3. Everything else in both documents stands.
**Scope:** macOS only. No iOS or iPadOS behavior changes.

---

## 1. Why this exists

Sub-project Ⅲb shipped a `NavigationSplitView` shell: the sidebar hosted `LibraryRootScreen` — the iOS root screen, `NavigationStack` and all — and the detail column hosted the reader. Two measured facts and one user report broke it.

**Fact 1 — a macOS sidebar cannot push.** On macOS 26.4.1, pushing a destination onto a `NavigationStack` that lives inside `NavigationSplitView`'s sidebar column lays the destination out bottom-anchored: the area is correct, the content is drawn below the visible region, so the column reads as blank. Minimal reproduction, no app code involved:

```swift
NavigationSplitView {
    NavigationStack(path: .constant(["x"])) {
        List { Text("root") }
            .listStyle(.sidebar)
            .navigationDestination(for: String.self) { _ in
                VStack(alignment: .leading) { Text("PUSHED CONTENT"); Spacer() }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.blue.opacity(0.4))
            }
    }
} detail: { Color.gray }
```

renders the blue background filling the column with `PUSHED CONTENT` at the **bottom**. Removing the `NavigationSplitView` wrapper renders the same push correctly at the top; root-of-stack content in a sidebar also renders correctly. So: sidebar + push is broken, sidebar without push is fine. Every Library screen the Mac reached — All Scores, Favorites, a playlist, a tag, Recently Deleted — was a push inside that sidebar, so every one of them was blank.

**Fact 2 — a SwiftUI tap gesture and `List(selection:)` cannot coexist on macOS.** Measured in Ⅲb; the table lives in `RowOpenAffordance.swift`'s doc comment. Every gesture form leaves the selection permanently empty. Ⅲb therefore made *selecting one row* the open action, which produced:

**Fact 3 — selection-as-open is confusing.** Re-clicking a selected row does not re-open it; clicking to select opens instead. For scores it is worse: opening restamps `lastOpenedAt`, which re-sorts the very list under the pointer.

These are one problem in two costumes: **the library was a resident column of the working window, and selection did double duty as "open".** A resident column needs in-place navigation (which the sidebar cannot render) and leaves selection as the only click vocabulary (which forces select-means-open).

The product framing points at the same root. In the user's words:

> folino の場合は一つのファイルを開いて集中的に閲覧・作業するのがメイン。どちらかといえば Numbers や Keynote に近い。

Mail and Notes suit apps where you hop between items constantly; Music's sidebar exists to list, not to work. folino's Mac session is: pick a score, then live in it. The library is a place you **visit**, not chrome that frames every minute of score work.

Two workflows any design must keep serving: **bulk actions need ⌘/⇧-click multi-selection**, and **several scores open at once is first-class** — copy/paste between scores, and parking one score to work on another.

---

## 2. The design

### 2.1 A window is a score, or it is the library

**Score windows.** The existing `WindowGroup(for: MacWindowScore.self)`. A window whose value names a score **is** that score: `MacReaderRootScreen` plus the transport, filling the window; title is the score title; no library column, no split view. This is what Ⅲb's detail column already renders — it simply stops sharing the window with a sidebar. Several scores are several windows of this one group. The group keeps a minimal empty fallback for the score-deleted-while-open case.

**The library browser.** A dedicated **single-instance `Window` scene** — folino's equivalent of Keynote's document manager, filling its own window. Inside the browser, and only there, a split view is right:

- **Source sidebar** — Recents, All Scores, Favorites, then every playlist and every tag as rows, Recently Deleted at the bottom. A flat `List(selection: MacLibrarySource?)`. Source rows are **not** `NavigationLink`s: selecting a source swaps the content pane. **No `NavigationStack` exists in any sidebar**, which is what kills Fact 1.
- **Content pane** — the selected source's scores, reusing the existing screens (`AllScoresScreen`, `FavoritesScreen`, `TagDetailScreen`, `PlaylistDetailScreen`, `RecentlyDeletedScreen`), which already take `LibraryViewModel` plus callbacks and do not care what container they sit in.

The "See all" pushes are **deleted, not relocated**: a browser sidebar scrolls, so every playlist and tag is simply listed. The five-row cap and the `LibraryRoute.playlists` / `.tags` management screens are an iPhone-height concession and have no place here. Rename and delete live on the source rows' context menus.

The user's objection was never to a sidebar in a *chooser* — Keynote's open panel has one. It was to a sidebar framing the *work*.

### 2.2 Click selects. Double-click opens.

In the content pane, **click selects, and selection means nothing but selection.** Opening is explicit and has four paths:

1. **Double-click** — `.contextMenu(forSelectionType:menu:primaryAction:)` (macOS 13.3+, floor is 15). This is a `List` API, not a gesture overlay, so Fact 2's table does not condemn it.
2. **Return** — `onKeyPress`.
3. **Open** in the row / selection context menu.
4. An **Open** toolbar button.

`primaryAction`'s coexistence with `List(selection:)` is documented but **unmeasured in this codebase** — the Fact 2 table predates it and never tried it, and there is no other use in the repo. Paths 2–4 are therefore not garnish: they are the design's fallback, and they ship whether or not the double-click works. If it does not, double-click becomes a named, deliberate gap and a new row in the `RowOpenAffordance` table. **Opening never falls back to selection.**

Fact 3 falls out: clicking never opens, so it never restamps `lastOpenedAt`, so the list never re-sorts under the pointer.

### 2.3 Opening never consumes a window

The default: the score lands as a **new tab of the frontmost score window**, or a new standalone window when none exists. ⌥-double-click and a context-menu item give **Open in New Window**.

The browser **stays open and recedes** behind the newly keyed score window — deliberately unlike Keynote's panel, which closes, because folino's browser is also the organize surface. ⌘W dismisses it.

### 2.4 Several scores at once

**"Window = one score" and "MuseScore's tab strip" are the same shape, not a trade-off.** macOS merges same-group windows into native window tabs; that *is* MuseScore 3's tab strip, supplied by the system — plus tear-off (drag a tab out) for genuine side-by-side, which an in-window tab strip cannot do, and which is exactly the two-scores-visible arrangement copy/paste wants.

What is verified, and what is not:

- **Verified in this repo: nothing yet.** `App/Mac` contains no tabbing code. Ⅲb's "⌘T opens a tab" pass condition was never run — the screen was locked for that whole session. The old spec's "tabs come for free" is an unchecked assumption and this design stops leaning on it.
- **Documented AppKit behavior**, runtime-unverified here: windows sharing a tabbing identifier merge via Window ▸ Merge All Windows and tear off by dragging; SwiftUI windows from one `WindowGroup` share an identifier; distinct scene types get distinct identifiers.
- **The catch:** whether a *newly opened* window lands as a tab is governed by the System Settings "Prefer tabs when opening documents" preference, which defaults to *In Full Screen Only*. At default settings `openWindow(value:)` opens a **standalone window, not a tab** — so today's menu item labeled "Open in New Tab" is most likely mislabeled on a default-configured Mac. Making open-as-tab the *app's* default needs a small AppKit assist: `tabbingMode = .preferred` before the window is shown, or `addTabbedWindow(_:ordered:)` after. Both need an `NSWindow` handle from inside a SwiftUI window; `App/Mac/EffectiveWindowWidthProbe.swift` is the in-repo precedent.
- **Graceful degradation:** if the assist fights SwiftUI's window presentation, scores open as standalone windows and tabs are reached through Merge All Windows or the system preference — Keynote's own out-of-the-box behavior. The shape survives; only the MuseScore-style default is lost.

### 2.5 What several windows cost, and the policies chosen

- **Playback: one score plays at a time.** `bootstrap.playbackController` is one shared instance handed to every window. Starting playback in window B stops A — the Music-app rule, and what rehearsal actually wants. The takeover is made **explicit**, not left to whatever the shared controller does by accident. Independent per-window playback would mean per-window audio engines; that is not this design.
- **Display mode stays global.** `ReaderGlobalSettingsKey.layoutMode` is a global `@AppStorage` read by every window and by the View menu, so switching mode in one window switches all. This is today's cross-device semantics made locally visible. Accepted for v1 and recorded here so it is a decision rather than a surprise; per-window mode is Ⅳ polish if wanted.

Beyond those two, nothing couples windows: each has its own view model, scroll state, magnification and transport.

### 2.6 Cross-score copy/paste — what the shell must not break

The clipboard format and paste semantics belong to sub-projects Ⅰ and Ⅳ. The window model imposes three constraints on them:

1. The musical clipboard rides the system-wide `NSPasteboard.general` with a **self-contained payload** — a serialized fragment carrying no reference to the source window, session or view model — so the source score can be closed without invalidating a later paste.
2. Edit-menu commands resolve their target through **key-window focus** (the responder chain / `@FocusedValue`, the mechanism `MacCommands` already uses for `macCurrentScoreID`), never through an app-global "the open score", which this design abolishes.
3. Two concurrent edit sessions must remain structurally possible. They already are — each window builds its own `ReaderViewModel`, keyed `.id(item.id)`. Nothing added to the shell may assume a single active session. `MacWindowScore.tabInstance` deliberately lets the same score open twice, which is useful read-only (page 3 beside page 7); two live *edit* sessions on one score is Ⅳ's problem to serialize.

### 2.7 Getting back to the library

- **⌘O** (File ▸ Open…) summons the browser — `openWindow(id:)` on a `Window` scene focuses the existing instance or creates the one instance. folino's open panel *is* its library, which is the whole not-document-based-but-document-shaped story.
- **File ▸ Import (⌘⇧I)** stays what it is: an `NSOpenPanel` bringing outside files in.
- Every score window carries a **leading "library" toolbar button** (grid icon) doing the same as ⌘O. It is the Mac's analog of the iOS back chevron and the only discoverable path back for a mouse-first user.
- The browser's **default source is Recents**.

### 2.8 Launch and restoration

A `Window` scene's restoration behavior is runtime-unverified. macOS 15's `defaultLaunchBehavior` / `restorationBehavior` scene modifiers exist to steer exactly this. Target behavior: a fresh launch with nothing restored presents the browser; restored score windows present without the browser unless it was open at quit. **Fallback if the modifiers do not cooperate: the browser always presents at launch** — dumb, but sound.

---

## 3. Multi-selection and bulk actions

Entirely inside the browser's content pane: a plain `List(selection: Set<ScoreItemID>)` with no row gestures, ⌘/⇧-click, the existing `bulkActionsContextMenuItems` on the selection, and the existing `deleteCommandCompat` for ⌫. The menu-bar surface is Ⅳ's.

Because the selection no longer drives any reader, three things **dissolve structurally** rather than being fixed: the "N selected" detail state, the `libraryBulkSelectionCount` focused-value plumbing, and the Ⅲb defect where ⌘-clicking a second row tore down the reader and stopped playback. Selection lives in the browser; readers live in score windows; they cannot fight.

iOS keeps its explicit Select mode and bottom `BulkActionBar` unchanged — the `isSelecting` fork from the superseded §4 stays exactly as built.

---

## 4. Rejected alternatives

**Three-column split view** (flat source list, content column, reader detail). Avoids Fact 1 the same way and fixes Fact 3 the same way, and is the smallest diff — but three columns eat width from the score, "the score fills the window" needs two collapses, the shell carries split-view state forever, and every new Library surface must be designed twice. It is the Mail/Music shape with better plumbing: precisely what the user rejected.

**Summoned library overlay** over a permanent score window. Maximum "the score is the window", no second window kind — but the overlay must host search, multi-select, bulk sheets, playlist reorder and Recently Deleted inside a modal layer, which is a poor home for a long organize session, and sheets-from-an-overlay stack badly. It also forfeits standard window management for the library (no library on a second display, no keeping it open while working). A quick-open switcher is a fine Ⅳ *supplement*, not a primary library.

---

## 5. Risks this design commits to handling

1. **`primaryAction` is unmeasured.** Gate: measure it the way the Fact 2 table was measured, and record the result in that table. Fallback (Return / button / context menu) ships regardless, so a failure costs the double-click, not the design.
2. **Tab placement is unmeasured.** Gate: verify that two opens land as two tabs of one window, at default system settings. Fallback: standalone windows plus Merge All Windows.
3. **The `NavigationRequestObserver` fault.** The shell loses its `NavigationSplitView`, so the measured write topology changes — in the direction of safety, since opens now fire from an event handler rather than from a selection `onChange` inside an update pass. The standing rule is *do not extend a measurement by reasoning*: re-run the five-step console check on the new shape, keeping the positive-control detector.
4. **Losing the resident library.** If the visit-cost proves real in use, the recovery is additive: a read-only "open another score" popover, or a Ⅳ quick-open switcher. Neither reintroduces a pushing sidebar.

---

## 6. Blast radius

**New, all macOS-only:**

- `Packages/Features/Library/Sources/Library/Screens/Mac/` — `MacLibraryBrowser.swift` (the split view), `MacLibrarySource.swift` (the selection-shaped sibling of `LibraryRoute`), `MacLibrarySidebar.swift` (source rows, counts, rename/delete menus). In the Library package, mirroring `Reader/Screens/Mac/`, because it composes Library's own screens and view model. No architecture change: Library still depends on Domain, ScoreUI and Utility only.
- `App/Mac/MacWindowTabAssist.swift` — the `NSWindow` probe, the tab-placement mechanism of §2.4, and the playback-takeover hook of §2.5.

**Rewritten:**

- `App/Mac/FolinoMacApp.swift` — gains the single-instance library `Window` scene and the §2.8 launch pins; the score `WindowGroup` and `MacWindowScore` are unchanged.
- `App/Mac/MacShellView.swift` — from split-view host to the score window's content: reader plus empty fallback. The adapter unwrapping and focused-value publishing survive; the sidebar/detail split, the selection count and the "N selected" view go. `LibraryViewModel` construction and the drop-target / import plumbing move to the browser window. Net smaller.
- `RowOpenAffordance.swift` — `macSelectionOpensScore`, `macSingleSelectionOpensScore` and the `libraryBulkSelectionCount` focused value are deleted; the measurement table stays and gains the `primaryAction` row.
- `ScoreListView.swift`, `PlaylistDetailView.swift` — the `macSelectionOpensScore` call sites become the new open affordance; the selection set, `effectiveRowMenu` and ⌫ are untouched.
- `MacCommands.swift` — ⌘0 toggle-library becomes ⌘O show-library; "Open in New Tab" is reworked onto the tab assist and joined by "Open in New Window".

**Untouched:** everything under `Reader/Screens/Mac/`, the audio work, `AppBootstrap`, import plumbing, and **all iOS code**. `LibraryRootScreen` and its push navigation remain the iOS shape; they keep compiling on macOS but are no longer instantiated there, and their now-dead macOS selection branch is stripped in a cleanup pass.

---

## 7. Documents this revises

- `2026-08-31-macos-app-shell-design.md` §3 and §4 — superseded by this document. A pointer is added at the head of each.
- `2026-08-31-macos-app-design.md` §5.3 — the sentence "One window = library sidebar (collapsible) + score tabs" is replaced by this document's §2.1 and §2.4.
