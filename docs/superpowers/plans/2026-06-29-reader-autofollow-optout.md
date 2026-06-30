# Reader auto-follow & page-turn-button opt-out — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add two opt-out preferences to the Reader visual inspector — playback auto-follow (auto-scroll / auto-page-turn) and page-mode tap-zone visibility — without changing default behavior.

**Architecture:** Two new global `@AppStorage` keys (Domain). A pure, parity-shared gate function in Domain decides whether a cursor change should drive the follow. `ReaderRootScreen` reads the keys and threads them into the score containers (follow gate) and the shared paged surface (tap-zone visibility). The visual inspector(s) expose the toggles, with the auto-follow label switching by layout mode.

**Tech Stack:** Swift 6.3, SwiftUI, Swift Testing, `@AppStorage` / `UserDefaults`, xcstrings localization.

## Global Constraints

- Swift 6.3, iOS 26+ target. Universal (iPad + iPhone).
- New tests use **Swift Testing** (`import Testing`, `@Test`, `#expect`).
- **Package tests / builds run via xcodebuild on an iOS Simulator** (`swift test` is broken by the SwiftLint plugin in this repo). Destination: `platform=iOS Simulator,name=iPhone 17 Pro Max`. Add `-skipPackagePluginValidation`.
- Verify a Feature package by building **its own package scheme** (`Packages/Features/Reader`), not the app — the app build incrementally skips the edited package and can falsely report success.
- **No simulator launch.** Stop at build success + tests passing + preview render; the user performs the manual clean-build smoke.
- SwiftLint `line_length.warning: 120`; reflow touched comments to 120. Match American spelling except where mirroring Apple API names.
- Access modifiers: only the Domain gate function and the settings-key constants are `public` (they cross the module boundary). All new container parameters stay `internal` (default).
- Defaults: both new settings default **ON** (`true`) at every `@AppStorage` site so existing behavior and user state are preserved (no migration).

---

## File Structure

**Domain**
- `Packages/Domain/Sources/Domain/Models/ReaderLayoutMode.swift` — add two `ReaderGlobalSettingsKey` constants.
- `Packages/Domain/Sources/Domain/ScrollFollow.swift` — add the pure `readerShouldFollowPlayback` gate (co-located with the other parity-shared follow helpers).
- `Packages/Domain/Tests/DomainTests/ScrollFollowTests.swift` — add the gate's tests.

**Reader — follow gating**
- `Packages/Features/Reader/Sources/Reader/Screens/Vertical/VerticalScoreContainer.swift`
- `Packages/Features/Reader/Sources/Reader/Screens/Horizontal/HorizontalScoreContainer.swift`
- `Packages/Features/Reader/Sources/Reader/Screens/Paged/PagedScoreContainer.swift`
- `Packages/Features/Reader/Sources/Reader/Screens/Paged/PagedScoreContainer+PageNavigation.swift`
- `Packages/Features/Reader/Sources/Reader/Screens/ReaderRootScreen.swift`

**Reader — tap-zone visibility**
- `Packages/Features/Reader/Sources/Reader/Screens/Shared/PagedReaderSurface.swift`
- `Packages/Features/Reader/Sources/Reader/Screens/Paged/PagedZoomedSurface.swift`
- `Packages/Features/Reader/Sources/Reader/Screens/Paged/PagedScoreContainer.swift`
- `Packages/Features/Reader/Sources/Reader/Screens/PDF/PagedPDFContainer.swift`
- `Packages/Features/Reader/Sources/Reader/Screens/ReaderRootScreen.swift`

**Reader — inspector UI + localization**
- `Packages/Features/Reader/Sources/Reader/Screens/VisualInspectorScreen.swift`
- `Packages/Features/Reader/Sources/Reader/Screens/PDF/PDFLayoutInspectorScreen.swift`
- `Packages/Features/Reader/Sources/Reader/Resources/Localizable.xcstrings`

---

## Task 1: Domain — settings keys + follow gate (TDD)

**Files:**
- Modify: `Packages/Domain/Sources/Domain/Models/ReaderLayoutMode.swift` (append two constants to `ReaderGlobalSettingsKey`)
- Modify: `Packages/Domain/Sources/Domain/ScrollFollow.swift` (append `readerShouldFollowPlayback`)
- Test: `Packages/Domain/Tests/DomainTests/ScrollFollowTests.swift` (append a test suite)

**Interfaces:**
- Produces: `ReaderGlobalSettingsKey.autoFollowEnabled: String` (= `"readerAutoFollowEnabled"`), `ReaderGlobalSettingsKey.pageTurnButtonsVisible: String` (= `"readerPageTurnButtonsVisible"`).
- Produces: `func readerShouldFollowPlayback(autoFollowEnabled: Bool, isPlaybackDriven: Bool) -> Bool` (public, Domain).

- [ ] **Step 1: Write the failing tests**

Append to `Packages/Domain/Tests/DomainTests/ScrollFollowTests.swift`:

```swift
struct ReaderShouldFollowPlaybackTests {
    @Test func `follows everything while enabled`() {
        #expect(readerShouldFollowPlayback(autoFollowEnabled: true, isPlaybackDriven: true))
        #expect(readerShouldFollowPlayback(autoFollowEnabled: true, isPlaybackDriven: false))
    }

    @Test func `suppresses only playback-driven follow when disabled`() {
        #expect(readerShouldFollowPlayback(autoFollowEnabled: false, isPlaybackDriven: true) == false)
    }

    @Test func `keeps manual navigation in view when disabled`() {
        // Manual seek / scrub (anchor nil → not playback-driven) still follows so the target stays on screen.
        #expect(readerShouldFollowPlayback(autoFollowEnabled: false, isPlaybackDriven: false))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run (from `Packages/Domain`):
```bash
xcodebuild test -scheme Domain -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation -only-testing:DomainTests/ReaderShouldFollowPlaybackTests
```
Expected: FAIL — `cannot find 'readerShouldFollowPlayback' in scope`.
(If the `Domain` scheme is not found, run `xcodebuild -list` in `Packages/Domain` and use the listed scheme, e.g. `Domain-Package`.)

- [ ] **Step 3: Add the gate function**

Append to `Packages/Domain/Sources/Domain/ScrollFollow.swift`:

```swift
/// Whether the Reader should run its playback-cursor follow (auto-scroll in vertical/horizontal, auto-page-turn in
/// page mode) for the current cursor change. `autoFollowEnabled` is the user's opt-out toggle; `isPlaybackDriven` is
/// true when the change comes from continuous playback — i.e. the lookahead anchor cursor is non-nil — rather than a
/// manual seek / scrub / measure-step.
///
/// When the toggle is on, always follow. When off, follow only manual navigation (`!isPlaybackDriven`) so a tap-seek,
/// measure-step, or scrub still brings the target on screen while continuous playback no longer scrolls or turns the
/// page. Shared by iOS and the Android Reader (parity: one implementation).
public func readerShouldFollowPlayback(autoFollowEnabled: Bool, isPlaybackDriven: Bool) -> Bool {
    autoFollowEnabled || !isPlaybackDriven
}
```

- [ ] **Step 4: Add the settings keys**

In `Packages/Domain/Sources/Domain/Models/ReaderLayoutMode.swift`, append inside `ReaderGlobalSettingsKey` (after `a4ReferenceHz`, before the closing brace):

```swift
    /// Bool. When true (the default at each `@AppStorage` site), the Reader follows the playhead during playback —
    /// auto-scroll in `.vertical` / `.horizontal`, auto-page-turn in `.page`. When false, continuous playback no
    /// longer moves the score; manual navigation (tap-seek, measure-step, scrub) still keeps its target in view.
    /// Score only — PDFs have no playback cursor.
    public static let autoFollowEnabled = "readerAutoFollowEnabled"

    /// Bool. When true (the default at each `@AppStorage` site), the `.page`-mode tap-zone navigation overlay
    /// (`TapOverlay`) is shown. When false it is hidden; swipe-to-turn and auto-page-turn still work. Read by the
    /// shared `PagedReaderSurface`, so it applies to both the score and PDF paged readers.
    public static let pageTurnButtonsVisible = "readerPageTurnButtonsVisible"
```

- [ ] **Step 5: Run the tests to verify they pass**

Run (from `Packages/Domain`):
```bash
xcodebuild test -scheme Domain -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation -only-testing:DomainTests/ReaderShouldFollowPlaybackTests
```
Expected: PASS (3 tests).

- [ ] **Step 6: Commit**

```bash
git add Packages/Domain/Sources/Domain/Models/ReaderLayoutMode.swift Packages/Domain/Sources/Domain/ScrollFollow.swift Packages/Domain/Tests/DomainTests/ScrollFollowTests.swift
git commit -m "feat(reader): add auto-follow / page-turn-button settings keys + follow gate"
```

---

## Task 2: Localization keys

**Files:**
- Modify: `Packages/Features/Reader/Sources/Reader/Resources/Localizable.xcstrings` (add 3 keys × 5 languages)

**Interfaces:**
- Produces: localized strings for `reader.inspector.autoScroll`, `reader.inspector.autoPageTurn`, `reader.inspector.showPageTurnButtons` (en, ja, ko, zh-Hans, zh-Hant).

- [ ] **Step 1: Write the insertion script**

Write to `<SCRATCHPAD>/add-xcstrings-keys.py` (replace `<SCRATCHPAD>` with the session scratchpad dir):

```python
import json

PATH = "/Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/reader-autofollow-optout/Packages/Features/Reader/Sources/Reader/Resources/Localizable.xcstrings"

NEW = {
    "reader.inspector.autoScroll": {
        "en": "Auto-scroll", "ja": "自動スクロール", "ko": "자동 스크롤",
        "zh-Hans": "自动滚动", "zh-Hant": "自動捲動",
    },
    "reader.inspector.autoPageTurn": {
        "en": "Auto page turn", "ja": "自動ページめくり", "ko": "자동 페이지 넘김",
        "zh-Hans": "自动翻页", "zh-Hant": "自動翻頁",
    },
    "reader.inspector.showPageTurnButtons": {
        "en": "Page-turn buttons", "ja": "ページめくりボタン", "ko": "페이지 넘김 버튼",
        "zh-Hans": "翻页按钮", "zh-Hant": "翻頁按鈕",
    },
}

with open(PATH) as f:
    doc = json.load(f)

for key, langs in NEW.items():
    doc["strings"][key] = {
        "localizations": {
            lang: {"stringUnit": {"state": "translated", "value": value}}
            for lang, value in langs.items()
        }
    }

with open(PATH, "w") as f:
    json.dump(doc, f, ensure_ascii=False, indent=2, sort_keys=True)
    f.write("\n")

print("added", list(NEW))
```

- [ ] **Step 2: Run the script**

Run:
```bash
python3 <SCRATCHPAD>/add-xcstrings-keys.py
```
Expected: `added ['reader.inspector.autoScroll', 'reader.inspector.autoPageTurn', 'reader.inspector.showPageTurnButtons']`

- [ ] **Step 3: Verify the JSON is valid and the keys are present**

Run:
```bash
python3 -c "import json; d=json.load(open('/Users/kiichi/Developer/Personal/ios-apps/Folino-iOS/.claude/worktrees/reader-autofollow-optout/Packages/Features/Reader/Sources/Reader/Resources/Localizable.xcstrings')); print(sorted(k for k in d['strings'] if k.startswith('reader.inspector.auto') or k=='reader.inspector.showPageTurnButtons'))"
```
Expected: `['reader.inspector.autoPageTurn', 'reader.inspector.autoScroll', 'reader.inspector.showPageTurnButtons']`

- [ ] **Step 4: Commit**

```bash
git add Packages/Features/Reader/Sources/Reader/Resources/Localizable.xcstrings
git commit -m "feat(reader): localize auto-follow / page-turn-button inspector labels"
```

---

## Task 3: Score-container follow gating

**Files:**
- Modify: `Packages/Features/Reader/Sources/Reader/Screens/Vertical/VerticalScoreContainer.swift`
- Modify: `Packages/Features/Reader/Sources/Reader/Screens/Horizontal/HorizontalScoreContainer.swift`
- Modify: `Packages/Features/Reader/Sources/Reader/Screens/Paged/PagedScoreContainer.swift`
- Modify: `Packages/Features/Reader/Sources/Reader/Screens/Paged/PagedScoreContainer+PageNavigation.swift`
- Modify: `Packages/Features/Reader/Sources/Reader/Screens/ReaderRootScreen.swift`

**Interfaces:**
- Consumes: `readerShouldFollowPlayback(autoFollowEnabled:isPlaybackDriven:)` (Task 1); `ReaderGlobalSettingsKey.autoFollowEnabled` (Task 1).
- Produces: stored `let autoFollowEnabled: Bool` on `VerticalScoreContainer`, `HorizontalScoreContainer`, `PagedScoreContainer`.

- [ ] **Step 1: Add the param + gate to `VerticalScoreContainer`**

In `VerticalScoreContainer.swift`, add the stored property immediately after the `scrollAnchorCursor` declaration block (after line 39):

```swift
    /// User opt-out: when false, continuous playback no longer auto-scrolls. Manual navigation still keeps its
    /// target in view (see `readerShouldFollowPlayback`).
    let autoFollowEnabled: Bool
```

Replace the `.onChange` handler (currently lines 173-175):

```swift
        .onChange(of: [playbackCursor, scrollAnchorCursor]) { _, _ in
            autoScroll(realCursor: playbackCursor, lookaheadCursor: scrollAnchorCursor, viewport: viewport)
        }
```

with:

```swift
        .onChange(of: [playbackCursor, scrollAnchorCursor]) { _, _ in
            guard readerShouldFollowPlayback(
                autoFollowEnabled: autoFollowEnabled,
                isPlaybackDriven: scrollAnchorCursor != nil,
            ) else { return }
            autoScroll(realCursor: playbackCursor, lookaheadCursor: scrollAnchorCursor, viewport: viewport)
        }
```

- [ ] **Step 2: Add the param + gate to `HorizontalScoreContainer`**

In `HorizontalScoreContainer.swift`, add the stored property after the `scrollAnchorCursor` block (after line 19):

```swift
    /// User opt-out: when false, continuous playback no longer auto-scrolls. Manual navigation still keeps its
    /// target in view (see `readerShouldFollowPlayback`).
    let autoFollowEnabled: Bool
```

Replace the `.onChange` handler (currently lines 114-116):

```swift
        .onChange(of: [playbackCursor, scrollAnchorCursor]) { _, _ in
            autoScroll(realCursor: playbackCursor, lookaheadCursor: scrollAnchorCursor, viewport: viewport)
        }
```

with:

```swift
        .onChange(of: [playbackCursor, scrollAnchorCursor]) { _, _ in
            guard readerShouldFollowPlayback(
                autoFollowEnabled: autoFollowEnabled,
                isPlaybackDriven: scrollAnchorCursor != nil,
            ) else { return }
            autoScroll(realCursor: playbackCursor, lookaheadCursor: scrollAnchorCursor, viewport: viewport)
        }
```

- [ ] **Step 3: Add the param + gate to `PagedScoreContainer`**

In `PagedScoreContainer.swift`, add the stored property after the `pageAnchorCursor` block (after line 28):

```swift
    /// User opt-out: when false, continuous playback no longer auto-turns the page. Manual navigation (tap-seek,
    /// measure-step) still turns to keep its target visible (see `readerShouldFollowPlayback`).
    let autoFollowEnabled: Bool
```

Replace the `.onChange` handler (currently lines 202-204):

```swift
        .onChange(of: [playbackCursor, pageAnchorCursor]) { _, _ in
            followCursor(pageAnchorCursor ?? playbackCursor)
        }
```

with:

```swift
        .onChange(of: [playbackCursor, pageAnchorCursor]) { _, _ in
            guard readerShouldFollowPlayback(
                autoFollowEnabled: autoFollowEnabled,
                isPlaybackDriven: pageAnchorCursor != nil,
            ) else { return }
            followCursor(pageAnchorCursor ?? playbackCursor)
        }
```

- [ ] **Step 4: Gate the post-swipe catch-up**

In `PagedScoreContainer+PageNavigation.swift`, in `onSwipeEnded`, replace (currently lines 175-177):

```swift
        if cursorAdvancedDuringSwipe {
            followCursor(playbackCursor)
        }
```

with:

```swift
        // The catch-up only chases active playback; honor the opt-out so a manual swipe is not yanked back.
        if cursorAdvancedDuringSwipe, autoFollowEnabled {
            followCursor(playbackCursor)
        }
```

- [ ] **Step 5: Wire `autoFollowEnabled` in `ReaderRootScreen`**

In `ReaderRootScreen.swift`, add the `@AppStorage` read after the `showSeekBar` declaration (after line 34):

```swift
    @AppStorage(ReaderGlobalSettingsKey.autoFollowEnabled)
    private var autoFollowEnabled = true
```

Add `autoFollowEnabled: autoFollowEnabled,` to each of the three score containers in `content` — insert it immediately after the `scrollAnchorCursor:` / `pageAnchorCursor:` argument:

- `VerticalScoreContainer(...)` — after `scrollAnchorCursor: viewModel.playbackSession.scrollAnchorCursor,` (line 220).
- `HorizontalScoreContainer(...)` — after `scrollAnchorCursor: viewModel.playbackSession.scrollAnchorCursor,` (line 233).
- `PagedScoreContainer(...)` — after `pageAnchorCursor: viewModel.playbackSession.pageAnchorCursor,` (line 245).

Each becomes, e.g.:

```swift
                    VerticalScoreContainer(
                        score: visible,
                        staffSize: viewModel.layoutModel.staffSize,
                        honorLayoutBreaks: viewModel.layoutModel.honorLayoutBreaks,
                        collapseMultiMeasureRests: collapseMultiMeasureRests,
                        showInvisibleElements: showInvisibleElements,
                        playbackCursor: viewModel.playbackSession.displayCursor,
                        scrollAnchorCursor: viewModel.playbackSession.scrollAnchorCursor,
                        autoFollowEnabled: autoFollowEnabled,
                        transposeSemitones: viewModel.transposeModel.semitones,
                        bottomControlClearance: bottomControlContentHeight,
                        viewModel: viewModel,
                    )
```

- [ ] **Step 6: Build the Reader package to verify it compiles**

Run (from `Packages/Features/Reader`):
```bash
xcodebuild build -scheme Reader -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation
```
Expected: `BUILD SUCCEEDED`, with the modified files shown `Compiling`. Fix any compile errors before continuing.

- [ ] **Step 7: Commit**

```bash
git add Packages/Features/Reader/Sources/Reader/Screens/Vertical/VerticalScoreContainer.swift Packages/Features/Reader/Sources/Reader/Screens/Horizontal/HorizontalScoreContainer.swift Packages/Features/Reader/Sources/Reader/Screens/Paged/PagedScoreContainer.swift Packages/Features/Reader/Sources/Reader/Screens/Paged/PagedScoreContainer+PageNavigation.swift Packages/Features/Reader/Sources/Reader/Screens/ReaderRootScreen.swift
git commit -m "feat(reader): gate playback auto-follow on the autoFollowEnabled setting"
```

---

## Task 4: Tap-zone visibility (shared surface + paged containers)

**Files:**
- Modify: `Packages/Features/Reader/Sources/Reader/Screens/Shared/PagedReaderSurface.swift`
- Modify: `Packages/Features/Reader/Sources/Reader/Screens/Paged/PagedZoomedSurface.swift`
- Modify: `Packages/Features/Reader/Sources/Reader/Screens/Paged/PagedScoreContainer.swift`
- Modify: `Packages/Features/Reader/Sources/Reader/Screens/PDF/PagedPDFContainer.swift`
- Modify: `Packages/Features/Reader/Sources/Reader/Screens/ReaderRootScreen.swift`

**Interfaces:**
- Consumes: `ReaderGlobalSettingsKey.pageTurnButtonsVisible` (Task 1).
- Produces: `let showsTapZones: Bool` on `PagedReaderSurface` and `PagedZoomedSurface`; `let showsPageTurnButtons: Bool` on `PagedScoreContainer` and `PagedPDFContainer`.

- [ ] **Step 1: Add `showsTapZones` to `PagedReaderSurface` and gate the overlay**

In `PagedReaderSurface.swift`, add the stored property after `let showsHint: Bool` (after line 38):

```swift
    /// When false, the page-turn tap-zone overlay is not rendered. Swipe-to-turn (the band gesture) is unaffected.
    let showsTapZones: Bool
```

In `body`, replace the tap-overlay call inside the `ZStack` (currently lines 78-80):

```swift
                tapOverlay()
                    .padding(.top, pageInsets.top)
                    .padding(.bottom, pageInsets.bottom)
```

with:

```swift
                if showsTapZones {
                    tapOverlay()
                        .padding(.top, pageInsets.top)
                        .padding(.bottom, pageInsets.bottom)
                }
```

- [ ] **Step 2: Thread `showsTapZones` through `PagedZoomedSurface`**

In `PagedZoomedSurface.swift`, add the stored property after `let onAnyZoneTouchDown: () -> Void` (after line 40):

```swift
    let showsTapZones: Bool
```

In `body`, add `showsTapZones: showsTapZones,` to the `PagedReaderSurface(...)` call — immediately after `onAnyZoneTouchDown: onAnyZoneTouchDown,` (line 57):

```swift
            showsHint: showsHint,
            onAnyZoneTouchDown: onAnyZoneTouchDown,
            showsTapZones: showsTapZones,
            pageContent: { idx in scorePage(forPage: idx) },
```

- [ ] **Step 3: Add `showsPageTurnButtons` to `PagedScoreContainer` and pass it down**

In `PagedScoreContainer.swift`, add the stored property after the `autoFollowEnabled` declaration added in Task 3:

```swift
    /// User opt-out: when false, the page-turn tap zones are hidden (swipe + auto-page-turn still work).
    let showsPageTurnButtons: Bool
```

In `scrollContent`, add `showsTapZones: showsPageTurnButtons,` to the `PagedZoomedSurface(...)` call — immediately after `onAnyZoneTouchDown: { pageTapHintDismissed = true },` (line 196):

```swift
                showsHint: !pageTapHintDismissed,
                onAnyZoneTouchDown: { pageTapHintDismissed = true },
                showsTapZones: showsPageTurnButtons,
            )
```

- [ ] **Step 4: Add `showsPageTurnButtons` to `PagedPDFContainer` and pass it down**

In `PagedPDFContainer.swift`, add the stored property **between** `let document: PDFDocument` and `@Bindable var viewModel: ReaderViewModel` (so the memberwise-init order is `document, showsPageTurnButtons, viewModel` — matching the call site in Step 5):

```swift
    let document: PDFDocument
    /// User opt-out: when false, the page-turn tap zones are hidden (swipe still works).
    let showsPageTurnButtons: Bool
    @Bindable var viewModel: ReaderViewModel
```

In `scrollContent`, add `showsTapZones: showsPageTurnButtons,` to the `PagedReaderSurface(...)` call — immediately after `onAnyZoneTouchDown: { pageTapHintDismissed = true },` (line 132):

```swift
                showsHint: !pageTapHintDismissed,
                onAnyZoneTouchDown: { pageTapHintDismissed = true },
                showsTapZones: showsPageTurnButtons,
                pageContent: { idx in pdfPage(idx, viewport: viewport) },
```

- [ ] **Step 5: Wire `pageTurnButtonsVisible` in `ReaderRootScreen`**

In `ReaderRootScreen.swift`, add the `@AppStorage` read after the `autoFollowEnabled` declaration added in Task 3:

```swift
    @AppStorage(ReaderGlobalSettingsKey.pageTurnButtonsVisible)
    private var pageTurnButtonsVisible = true
```

In `content`:
- Add `showsPageTurnButtons: pageTurnButtonsVisible,` to the `PagedScoreContainer(...)` call **immediately after** `autoFollowEnabled: autoFollowEnabled,` (so the argument order matches the property order `pageAnchorCursor, autoFollowEnabled, showsPageTurnButtons, transposeSemitones, viewModel`):

```swift
                    PagedScoreContainer(
                        score: visible,
                        staffSize: viewModel.layoutModel.staffSize,
                        honorLayoutBreaks: viewModel.layoutModel.honorLayoutBreaks,
                        collapseMultiMeasureRests: collapseMultiMeasureRests,
                        showInvisibleElements: showInvisibleElements,
                        playbackCursor: viewModel.playbackSession.displayCursor,
                        pageAnchorCursor: viewModel.playbackSession.pageAnchorCursor,
                        autoFollowEnabled: autoFollowEnabled,
                        showsPageTurnButtons: pageTurnButtonsVisible,
                        transposeSemitones: viewModel.transposeModel.semitones,
                        viewModel: viewModel,
                    )
```

- Add the same argument to the `PagedPDFContainer(...)` call in the `.loadedPDF` branch:

```swift
            case .page, .horizontal:
                PagedPDFContainer(
                    document: document,
                    showsPageTurnButtons: pageTurnButtonsVisible,
                    viewModel: viewModel,
                )
```

- [ ] **Step 6: Build the Reader package to verify it compiles**

Run (from `Packages/Features/Reader`):
```bash
xcodebuild build -scheme Reader -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation
```
Expected: `BUILD SUCCEEDED` with the modified files `Compiling`. Fix any compile errors before continuing.

- [ ] **Step 7: Commit**

```bash
git add Packages/Features/Reader/Sources/Reader/Screens/Shared/PagedReaderSurface.swift Packages/Features/Reader/Sources/Reader/Screens/Paged/PagedZoomedSurface.swift Packages/Features/Reader/Sources/Reader/Screens/Paged/PagedScoreContainer.swift Packages/Features/Reader/Sources/Reader/Screens/PDF/PagedPDFContainer.swift Packages/Features/Reader/Sources/Reader/Screens/ReaderRootScreen.swift
git commit -m "feat(reader): gate page-mode tap zones on the pageTurnButtonsVisible setting"
```

---

## Task 5: Visual inspector UI (score + PDF)

**Files:**
- Modify: `Packages/Features/Reader/Sources/Reader/Screens/VisualInspectorScreen.swift`
- Modify: `Packages/Features/Reader/Sources/Reader/Screens/PDF/PDFLayoutInspectorScreen.swift`

**Interfaces:**
- Consumes: `ReaderGlobalSettingsKey.autoFollowEnabled`, `ReaderGlobalSettingsKey.pageTurnButtonsVisible` (Task 1); the three localization keys (Task 2).

- [ ] **Step 1: Add `@AppStorage` + a `layoutMode` accessor to `VisualInspectorScreen`**

In `VisualInspectorScreen.swift`, add after the `showSeekBar` declaration (after line 22):

```swift
    @AppStorage(ReaderGlobalSettingsKey.autoFollowEnabled)
    private var autoFollowEnabled = true

    @AppStorage(ReaderGlobalSettingsKey.pageTurnButtonsVisible)
    private var pageTurnButtonsVisible = true
```

Add a computed accessor (place it just above `var body`):

```swift
    private var layoutMode: ReaderLayoutMode {
        ReaderLayoutMode(rawValue: layoutModeRaw) ?? .page
    }
```

- [ ] **Step 2: Add the rows to the General section**

In `body`, the General `CollapsibleSection` content currently ends with `seekBarRow` (line 36). Add the two new rows after it:

```swift
                showInvisibleRow
                seekBarRow
                autoFollowRow
                if layoutMode == .page {
                    pageTurnButtonsRow
                }
```

- [ ] **Step 3: Define the new rows**

Add these row builders to `VisualInspectorScreen` (e.g. after `seekBarRow`, before `staffSizeRow`):

```swift
    /// Playback auto-follow opt-out. The label tracks the layout mode: scrolling modes read "auto-scroll", page mode
    /// reads "auto page turn".
    private var autoFollowRow: some View {
        Toggle(isOn: $autoFollowEnabled) {
            Text(
                layoutMode == .page
                    ? "reader.inspector.autoPageTurn"
                    : "reader.inspector.autoScroll",
                bundle: .module,
            )
        }
    }

    /// Page-mode tap-zone visibility opt-out. Only meaningful in `.page`, so the caller gates its presence on the mode.
    private var pageTurnButtonsRow: some View {
        Toggle(isOn: $pageTurnButtonsVisible) {
            Text("reader.inspector.showPageTurnButtons", bundle: .module)
        }
    }
```

- [ ] **Step 4: Add the PDF page-turn-buttons row**

In `PDFLayoutInspectorScreen.swift`, add the `@AppStorage` after the existing `layoutModeRaw` (after line 9):

```swift
    @AppStorage(ReaderGlobalSettingsKey.pageTurnButtonsVisible)
    private var pageTurnButtonsVisible = true

    /// For PDFs every non-`vertical` selection resolves to page (mirrors `ReaderRootScreen.pdfLayoutMode`), so the
    /// tap-zone toggle shows whenever the layout is not vertical.
    private var isPageLayout: Bool {
        (ReaderLayoutMode(rawValue: layoutModeRaw) ?? .page) != .vertical
    }
```

In `body`, add a second `Section` after the existing one (inside the `List`, after the closing of the first `Section { … } footer: { … }`):

```swift
            if isPageLayout {
                Section {
                    Toggle(isOn: $pageTurnButtonsVisible) {
                        Text("reader.inspector.showPageTurnButtons", bundle: .module)
                    }
                }
            }
```

- [ ] **Step 5: Add previews for the dynamic label (score inspector)**

In `VisualInspectorScreen.swift`, add a `#if DEBUG` preview block at the end of the file so the dynamic label and the conditional row can be snapshotted:

```swift
#if DEBUG
import SheetMusicCore

private func visualInspectorPreviewScore() -> Score {
    Score(division: 480, parts: [], metaTags: ["workTitle": "Sample"])
}

#Preview("Visual inspector · page") {
    UserDefaults.standard.set(ReaderLayoutMode.page.rawValue, forKey: ReaderGlobalSettingsKey.layoutMode)
    return VisualInspectorScreen(
        layoutModel: LayoutSettingsModel(),
        transposeModel: TransposeModel(),
        score: visualInspectorPreviewScore(),
    )
}

#Preview("Visual inspector · vertical") {
    UserDefaults.standard.set(ReaderLayoutMode.vertical.rawValue, forKey: ReaderGlobalSettingsKey.layoutMode)
    return VisualInspectorScreen(
        layoutModel: LayoutSettingsModel(),
        transposeModel: TransposeModel(),
        score: visualInspectorPreviewScore(),
    )
}
#endif
```

(If `Score` / the models are already imported at file top, drop the duplicate `import`. Adjust the model initializers if their signatures differ — they are constructed no-arg in `ReaderViewModel`.)

- [ ] **Step 6: Build the Reader package**

Run (from `Packages/Features/Reader`):
```bash
xcodebuild build -scheme Reader -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation
```
Expected: `BUILD SUCCEEDED` with the inspector files `Compiling`.

- [ ] **Step 7: Render the previews and confirm the label switches**

Use `mcp__xcode__RenderPreview` on `VisualInspectorScreen.swift` for both previews and `Read` the PNGs. Confirm:
- "page" preview: the auto-follow row reads **"自動ページめくり"** and the **"ページめくりボタン"** row is present.
- "vertical" preview: the auto-follow row reads **"自動スクロール"** and there is **no** page-turn-buttons row.

(If the preview plugin can't build, fall back to confirming the label logic by reading the code; do not switch to a simulator launch.)

- [ ] **Step 8: Commit**

```bash
git add Packages/Features/Reader/Sources/Reader/Screens/VisualInspectorScreen.swift Packages/Features/Reader/Sources/Reader/Screens/PDF/PDFLayoutInspectorScreen.swift
git commit -m "feat(reader): surface auto-follow & page-turn-button toggles in the visual inspector"
```

---

## Task 6: Whole-package verification

**Files:** none (verification only).

- [ ] **Step 1: Build the Reader package clean**

Run (from `Packages/Features/Reader`):
```bash
xcodebuild build -scheme Reader -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation
```
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 2: Run the Domain test suite**

Run (from `Packages/Domain`):
```bash
xcodebuild test -scheme Domain -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation -only-testing:DomainTests/ReaderShouldFollowPlaybackTests -only-testing:DomainTests/ScrollFollowTests
```
Expected: PASS.

- [ ] **Step 3: Run any existing Reader tests to confirm no regression**

Run (from `Packages/Features/Reader`):
```bash
xcodebuild test -scheme Reader -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation
```
Expected: PASS (no behavioral tests cover the new view gating; this confirms nothing else broke).

- [ ] **Step 4: Hand off for manual smoke**

Report to the user: build + tests green; previews confirm the dynamic label. Ask them to clean-build on device and confirm:
- Auto-follow OFF: playback no longer scrolls / turns pages; tap-seek + measure-step + scrub still recenter; swipe still turns pages.
- Page-turn-buttons OFF (page mode): tap zones hidden; swipe still turns pages; toggle hidden in non-page modes; PDF page mode honors the same flag.

---

## Self-Review

**Spec coverage:**
- Two settings keys (default ON) → Task 1. ✓
- Auto-follow gate, manual-seek preserved → Task 1 (gate) + Task 3 (wiring, incl. swipe catch-up). ✓
- Page-turn-button visibility, score + PDF via shared surface → Task 4. ✓
- Score inspector: auto-follow row (dynamic label) + page-turn-buttons row (page-only) → Task 5. ✓
- PDF inspector: page-turn-buttons row (page-only) → Task 5. ✓
- Localization (3 keys) → Task 2. ✓
- Non-goals (no per-score, no math change, no Settings mirror, no Android) → respected; no tasks added. ✓

**Placeholder scan:** No TBD/TODO; every code step shows full code. ✓

**Type consistency:** `readerShouldFollowPlayback(autoFollowEnabled:isPlaybackDriven:)` used identically in Tasks 1/3. `showsTapZones` (surface params) vs `showsPageTurnButtons` (container params / setting) used consistently — the container's `showsPageTurnButtons` maps to the surface's `showsTapZones` at each call site. `ReaderGlobalSettingsKey.autoFollowEnabled` / `.pageTurnButtonsVisible` consistent across Tasks 1/3/4/5. ✓
